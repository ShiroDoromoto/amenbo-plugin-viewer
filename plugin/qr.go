package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"

	qrcode "rsc.io/qr"
)

// Pairing is the one piece of setting up a phone does, and the whole of it happens off the
// network: the PC draws a code, the phone's camera reads it, and nothing in between is asked to
// carry the key.
//
// **The key must not travel through the Worker.** Route it through the server and the server can
// read what it is storing, and the encryption stops meaning anything. A screen and a camera are
// the one path with no network on it — which is also why the code is issued rather than
// redisplayed: what is on the screen is a token that did not exist a moment ago.
//
// What each phone gets is its own read token, so losing one phone is one token to cut rather than
// every phone to pair again. The Worker is told only the hash of it, so what it holds is not a
// set of credentials.

// pairing is what the code carries, and nothing else is on it. The keys are one letter each: not
// for the code's capacity, which is ample, but for the camera — fewer modules is a read that
// catches sooner.
//
// The name rides along with the three secrets because this is the only moment the phone can be
// told it. Cutting a phone off is done here by that name, and a phone that cannot show the name
// it was paired under leaves the person guessing which of the rows on the PC is the one in their
// hand.
type pairing struct {
	V   int    `json:"v"`
	URL string `json:"url"`
	T   string `json:"t"`
	K   string `json:"k"`
	L   string `json:"l"`
}

// codeScale is how many image pixels one module of the code becomes. The code carries about 180
// characters, so it lands around version 9 — some 53 modules a side, which at this scale is an
// image a phone reads from a comfortable distance without filling the screen. A name written in
// something other than ASCII costs one version more, and that is the whole of how this grows:
// what is on the code is four short fields and a name, not anything that gets longer with use.
const codeScale = 10

// The two ways the phone's name reaches this run, before the terminal is asked at all.
//
// askLabel is what the manifest declares the settings screen to ask for when the button that runs
// this is pressed: Amenbo hands the answer over in envAskLabel for that one run and saves nothing.
// **It is not declared secret.** The name is what the person will be looking for when they cut
// this phone off, so a box that hid what was typed into it would hide the one thing they have to
// remember.
const (
	askLabel    = "label"
	envAskLabel = "AMENBO_ASK_LABEL"
)

// A part of the answer the settings screen draws. What travels is a string; the
// drawing is Amenbo's, which is what keeps this plugin a child process rather than something
// shipping a window per platform.
//
// **The code is the text, not a picture.** Before this, a code went out as a PNG written into a
// temporary directory and handed to whatever the system opens images with — which on a machine
// with no such thing, or a session that cannot reach the screen, failed with nobody watching.
// **Exactly one field per part.** Amenbo reads a part as the one key it carries, so a part with
// two of them is one it refuses — which is why every field is `omitempty` and every part is built
// with one of them set.
type shownPart struct {
	Text    string   `json:"text,omitempty"`
	Heading string   `json:"heading,omitempty"`
	List    []string `json:"list,omitempty"`
	QR      string   `json:"qr,omitempty"`
}

// answered is what a run puts on stdout for the settings screen to draw beneath the button that
// started it. `ok` is the run's own verdict; anything else the caller wants back rides alongside.
type answered struct {
	V    int         `json:"v"`
	OK   bool        `json:"ok"`
	Show []shownPart `json:"show,omitempty"`
}

// drawnHere says whether the code goes into this terminal rather than back to the form.
//
// **A terminal is where a person is looking.** The settings screen has none, so a run started
// from it gets the code as a part to draw; a run typed into a shell gets it where it was typed.
// `--terminal` forces the second, for the shell that is a window onto somebody else's machine.
func drawnHere(forced bool) bool { return forced || thereIsATerminal() }

func qr(in input, args []string) error {
	options := flag.NewFlagSet("qr", flag.ContinueOnError)
	options.SetOutput(errOut)
	label := options.String("label", "", "what to call this phone — it is the name revoking one gives")
	inTerminal := options.Bool("terminal", false, "draw the code in the terminal instead of opening it as an image")
	if err := options.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}

	// The route and the key are read before anything is asked of the user: a pairing that cannot
	// work is one to refuse now, not after they have named a phone.
	where, err := storeFor(in)
	if errors.Is(err, errNoCloudflareRoute) {
		// The two sentinels below are the ones a person actually meets on the settings screen:
		// pairing is the fourth button, and pressing it before the third has run is the ordinary
		// way to arrive here. They are worded rather than passed on so that the answer to "why
		// did nothing happen" is in the language the rest of the form is in.
		return refuse(phNoCloudflareRouteYet, phTheSetupButton)
	}
	if err != nil {
		return err
	}
	key := secret(envEncryptionKey)
	if key == "" {
		return refuse(phNoEncryptionKey, phTheSetupButton)
	}

	named := strings.TrimSpace(*label)
	if named == "" {
		named, err = askForALabel()
		if err != nil {
			return err
		}
	}

	// The token is drawn here and sent nowhere: the Worker is told its hash, the phone reads the
	// value off the screen, and this process forgets it when it ends.
	token := generated()
	issuedAt, err := where.issue(named, hashOf(token))
	if err != nil {
		return err
	}
	if err := rememberThePhone(named, issuedAt); err != nil {
		return err
	}

	carried, err := json.Marshal(pairing{V: specVersion, URL: where.url, T: token, K: key, L: named})
	if err != nil {
		return err
	}
	if drawnHere(*inTerminal) {
		if err := present(carried, carriesTheKey); err != nil {
			return err
		}
	}

	logf("%s: %s", pluginName, say(phPhoneMayReadFromNowOn, named))
	return json.NewEncoder(out).Encode(struct {
		answered
		Label    string `json:"label"`
		IssuedAt string `json:"issued_at"`
	}{
		answered: answered{V: specVersion, OK: true, Show: []shownPart{
			{Text: say(phReadThisWithTheCamera)},
			{QR: string(carried)},
		}},
		Label:    named,
		IssuedAt: issuedAt,
	})
}

// issue tells the store one more phone may read, by the hash of the token it will offer.
//
// **A name that is taken is refused there**, and what comes back here is the move that frees it:
// the store will not issue over a phone that is reading, so re-pairing one is cutting it off and
// pairing again. Passing the store's own sentence on would say what happened and not what to do.
func (s store) issue(label, hash string) (string, error) {
	body, err := json.Marshal(map[string]string{"label": label, "hash": hash})
	if err != nil {
		return "", err
	}
	request, err := http.NewRequest(http.MethodPut, s.url+"/tokens", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	request.Header.Set("Content-Type", "application/json")

	answered, err := s.askTheStore(request)
	var turnedDown storeRefused
	if errors.As(err, &turnedDown) && turnedDown.status == http.StatusConflict {
		// **What to do about it is a button, not a command.** Someone who only ever opens the
		// settings screen meets this refusal the second time they pair a phone they re-installed
		// the app on, and a sentence pointing at a terminal leaves them with nowhere to go.
		return "", refuse(phPhoneAlreadyPaired, label, phTheUnpairButton)
	}
	if err != nil {
		return "", err
	}
	var said struct {
		IssuedAt string `json:"issued_at"`
	}
	if err := json.Unmarshal(answered, &said); err != nil {
		return "", fmt.Errorf("/tokens answered with something this build cannot read: %w", err)
	}
	return said.IssuedAt, nil
}

// hashOf is how a read token is written down: SHA-256, lower-case hex, which is what the Worker
// compares an offered token against.
func hashOf(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// appStoreLink is where the phone's half of this is got. It is the id form and carries no
// country: an App Store address that names one sends everybody else's phone to a page that is
// not for their store.
const appStoreLink = "https://apps.apple.com/app/id6800196224"

// getTheApp puts the App Store page on a code, for the camera that is going to install it.
//
// **The link's reader is a phone, and the screen it is drawn on is a PC.** Opening the page in
// the browser here would land it on the machine that cannot install it, leaving the person to
// carry the address across by hand.
//
// Nothing on this code is a secret, and the address goes out in words as well as on the code:
// somebody reading a log, or a terminal that cannot draw, still has the one thing they came for.
func getTheApp(_ input, args []string) error {
	options := flag.NewFlagSet("app", flag.ContinueOnError)
	options.SetOutput(errOut)
	// The same escape `qr` has, for the same machine: over SSH to a mac the image opens on the
	// console user's screen, which is not the screen the person asking is sitting at.
	inTerminal := options.Bool("terminal", false, "draw the code in the terminal instead of opening it as an image")
	if err := options.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}

	if drawnHere(*inTerminal) {
		if err := present([]byte(appStoreLink), carriesNoSecret); err != nil {
			return refuse(phCodeNotDrawn, err, appStoreLink)
		}
	}
	logf("%s: %s", pluginName, say(phPointTheCamera, appStoreLink))
	return json.NewEncoder(out).Encode(answered{V: specVersion, OK: true, Show: []shownPart{
		{Text: say(phReadThisWithTheCamera)},
		{QR: appStoreLink},
	}})
}

// What a code is carrying, named rather than spelled as a bare true and false at the call. What
// turns on it is only what is said about the code once it is drawn: pairing puts the encryption
// key in front of a camera, and getting the app puts a public address there — so one of the two
// leaves something behind worth warning about, and the other leaves a link.
const (
	carriesTheKey   = true
	carriesNoSecret = false
)

// present encodes what the phone is to read and draws it where the person typing is looking.
//
// It is a variable so a test can read what was about to be drawn. The token on the code is the
// one thing that has to match the hash the store was given, and once it has been drawn as a code
// there is no reading it back out.
var present = func(carried []byte, carriesASecret bool) error {
	code, err := qrcode.Encode(string(carried), qrcode.M)
	if err != nil {
		return err
	}
	code.Scale = codeScale
	return drawInTheTerminal(code, carriesASecret)
}

// thereIsAScreen says whether opening something on screen is worth trying. Everywhere but Linux
// there is a windowing system by definition; on Linux a machine with no display would hand the
// run to an opener that has nowhere to put it.
var thereIsAScreen = func() bool {
	if runtime.GOOS != "linux" {
		return true
	}
	return os.Getenv("DISPLAY") != "" || os.Getenv("WAYLAND_DISPLAY") != ""
}

// thereIsATerminal says whether there is one here to draw a code in. It is asked before the
// drawing rather than after, because what a failed draw falls back to is a screenful of blocks in
// a log — and a log is not something a camera can be pointed at.
var thereIsATerminal = func() bool {
	terminal, err := os.OpenFile(terminalPath, os.O_RDWR, 0)
	if err != nil {
		return false
	}
	terminal.Close()
	return true
}

// openInTheSystem hands what it is given to whatever the system opens that with — the pairing
// image to an image viewer, a link to the browser. Each of these returns as soon as the handover
// is done, which is what lets the run carry on and wait for the person instead of for the window.
var openInTheSystem = func(target string) error {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", target).Run()
	case "windows":
		return exec.Command("cmd", "/c", "start", "", target).Run()
	default:
		return exec.Command("xdg-open", target).Run()
	}
}

// drawInTheTerminal writes the code out in half-blocks: one column per module, one row per two,
// which is what keeps a code that is 45 modules across inside 80 columns.
//
// It goes to the terminal itself rather than to stderr, because Amenbo holds a plugin's stderr
// until the run is over — and a code nobody can see while the run is waiting on them is no code
// at all.
func drawInTheTerminal(code *qrcode.Code, carriesASecret bool) error {
	drawn := blocksFor(code)
	terminal, err := os.OpenFile(terminalPath, os.O_RDWR, 0)
	if err != nil {
		logf("%s: %s", pluginName, drawn)
		if carriesASecret {
			logf("%s: that code carries the key, and it stays in this terminal's scrollback.", pluginName)
		}
		return nil
	}
	defer terminal.Close()
	fmt.Fprint(terminal, "\n"+drawn+"\n")
	if carriesASecret {
		fmt.Fprintln(terminal, "that code carries the key, and it stays in this terminal's scrollback.")
	}
	return nil
}

// The quiet zone is four modules of white on every side. A reader needs it to find the code's
// edges, and a terminal gives it nothing to find without one.
const quietZone = 4

// blocksFor renders the code as text. Two rows of modules share one line of characters — the
// upper half of the character and the lower half — because a terminal cell is about twice as tall
// as it is wide, and one character per module would come out stretched.
func blocksFor(code *qrcode.Code) string {
	const (
		both  = "█"
		upper = "▀"
		lower = "▄"
		none  = " "
	)
	side := code.Size + quietZone*2
	var drawn strings.Builder
	for y := 0; y < side; y += 2 {
		for x := 0; x < side; x++ {
			top := code.Black(x-quietZone, y-quietZone)
			bottom := code.Black(x-quietZone, y+1-quietZone)
			switch {
			case top && bottom:
				drawn.WriteString(both)
			case top:
				drawn.WriteString(upper)
			case bottom:
				drawn.WriteString(lower)
			default:
				drawn.WriteString(none)
			}
		}
		drawn.WriteString("\n")
	}
	return drawn.String()
}

// askForALabel gets the phone's name from the person running this, when they did not say it on
// the command line.
//
// **A name is asked for rather than made up.** The store refuses a name that is already there, so
// a default would pair the first phone and turn away every one after it — and the name is what
// they will have to recognise when they cut one off.
//
// The settings screen asks its own box before the button runs, so an answer waiting in the
// environment is this run's and there is nothing left to ask. A terminal is what is left when
// nobody came in that way.
func askForALabel() (string, error) {
	if named := strings.TrimSpace(os.Getenv(envAskLabel)); named != "" {
		return named, nil
	}

	terminal, err := os.OpenFile(terminalPath, os.O_RDWR, 0)
	if err != nil {
		return "", fmt.Errorf("there is no terminal here to ask on — name the phone with --label: %w", err)
	}
	defer terminal.Close()

	fmt.Fprint(terminal, "\nwhat should this phone be called? (it is the name you would cut it off by) ")
	named, err := bufio.NewReader(terminal).ReadString('\n')
	if err != nil && strings.TrimSpace(named) == "" {
		return "", fmt.Errorf("nothing could be read from the terminal — name the phone with --label: %w", err)
	}
	named = strings.TrimSpace(named)
	if named == "" {
		return "", refuse(phThePhoneWasNotNamed)
	}
	return named, nil
}
