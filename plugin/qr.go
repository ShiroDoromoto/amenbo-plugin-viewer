package main

import (
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
// **There is one read code, not one per phone.** The Worker compares a hash and never learns
// which phone offered it, so a code per phone was a name kept on this side and nothing in the
// store. Issuing draws a new code and the one before it stops working — which is also what makes
// re-pairing one press rather than two.

// pairing is what the code carries, and nothing else is on it. The keys are one letter each: not
// for the code's capacity, which is ample, but for the camera — fewer modules is a read that
// catches sooner.
type pairing struct {
	V   int    `json:"v"`
	URL string `json:"url"`
	T   string `json:"t"`
	K   string `json:"k"`
}

// codeScale is how many image pixels one module of the code becomes. The code carries about 160
// characters, so it lands around version 9 — some 53 modules a side, which at this scale is an
// image a phone reads from a comfortable distance without filling the screen. What is on the code
// is four short fields, none of which gets longer with use.
const codeScale = 10

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

	// The token is drawn here and sent nowhere: the Worker is told its hash, the phone reads the
	// value off the screen, and this process forgets it when it ends.
	token := generated()
	issuedAt, err := where.issue(hashOf(token))
	if err != nil {
		return err
	}
	forgetTheOldList()

	carried, err := json.Marshal(pairing{V: specVersion, URL: where.url, T: token, K: key})
	if err != nil {
		return err
	}
	if drawnHere(*inTerminal) {
		// One code and nothing to tell it from, so it is drawn under no name at all.
		if err := present("", carried, carriesTheKey); err != nil {
			return err
		}
	}

	logf("%s: %s", pluginName, say(phPhoneMayReadFromNowOn))
	return json.NewEncoder(out).Encode(struct {
		answered
		IssuedAt string `json:"issued_at"`
	}{
		answered: answered{V: specVersion, OK: true, Show: []shownPart{
			{Text: say(phReadThisWithTheCamera)},
			{QR: string(carried)},
		}},
		IssuedAt: issuedAt,
	})
}

// issue hands the store the hash of the code the phone will offer, and gets back when it was
// issued.
//
// **It replaces whatever the store was holding.** There is one code, so pressing this a second
// time is not refused — it draws a new one and the phone that had the old one stops reading. That
// used to be two moves, cut then pair, because the code was named and the name had to be freed.
func (s store) issue(hash string) (string, error) {
	body, err := json.Marshal(map[string]string{"hash": hash})
	if err != nil {
		return "", err
	}
	request, err := http.NewRequest(http.MethodPut, s.url+"/tokens", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	request.Header.Set("Content-Type", "application/json")

	answered, err := s.askTheStore(request)
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

// Where the phone's half of this is got. Both are the store's own id form and neither carries a
// country: a store address that names one sends everybody else's phone to a page that is not for
// their store.
const (
	appStoreLink  = "https://apps.apple.com/app/id6800196224"
	playStoreLink = "https://play.google.com/store/apps/details?id=work.amenbo.viewer"
)

// theStores is one row per kind of phone, in the order the codes are drawn.
//
// **The name is a brand and is never translated.** It is the whole of what tells the two codes
// apart — beside each code on the settings screen, above each one in the terminal, and after
// each address in the line that reaches the log — and it is the word a reader matches against
// the phone in their hand.
var theStores = []struct {
	phone string
	link  string
}{
	{phone: "iPhone", link: appStoreLink},
	{phone: "Android", link: playStoreLink},
}

// getTheApp puts each store's page on a code, for the camera that is going to install from it.
//
// **The link's reader is a phone, and the screen it is drawn on is a PC.** Opening the page in
// the browser here would land it on the machine that cannot install it, leaving the person to
// carry the address across by hand.
//
// **One button, two codes.** The buttons are numbered in the order they are pressed, and the
// eighteen translations of those labels live in the catalogue, so a second button here would
// renumber every one after it — while the person pressing this is holding one phone and reads
// one of the codes either way.
//
// Nothing on these codes is a secret, and the addresses go out in words as well: somebody
// reading a log, or a terminal that cannot draw, still has the one thing they came for.
func getTheApp(_ input, args []string) error {
	options := flag.NewFlagSet("app", flag.ContinueOnError)
	options.SetOutput(errOut)
	// The same escape `qr` has, for the same machine: over SSH to a mac the image opens on the
	// console user's screen, which is not the screen the person asking is sitting at.
	inTerminal := options.Bool("terminal", false, "draw the codes in the terminal instead of opening them as images")
	if err := options.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}

	if drawnHere(*inTerminal) {
		for _, store := range theStores {
			if err := present(store.phone, []byte(store.link), carriesNoSecret); err != nil {
				return refuse(phCodeNotDrawn, err, store.link)
			}
		}
	}
	logf("%s: %s", pluginName, say(phPointTheCamera, addressesInWords(screen)))

	shown := []shownPart{{Text: say(phReadThisWithTheCamera)}}
	for _, store := range theStores {
		shown = append(shown, shownPart{Heading: store.phone}, shownPart{QR: store.link})
	}
	return json.NewEncoder(out).Encode(answered{V: specVersion, OK: true, Show: shown})
}

// addressesInWords is where the app is, written out for whoever cannot point a camera at a code:
// each address followed by the phone it is for, joined the way the reader's own language joins a
// list.
//
// **The sentence around it is translated and this is not.** An address is an address in all
// nineteen, and so is the name of a phone — which is what lets the one sentence carry a second
// store without every language being rewritten to hold it.
func addressesInWords(words wording) string {
	named := make([]string, 0, len(theStores))
	for _, store := range theStores {
		named = append(named, fmt.Sprintf("%s (%s)", store.link, store.phone))
	}
	return inWords(words, named)
}

// addressesListed is the same addresses one to a line, for the usage. A terminal wraps a line
// that runs long, and a wrapped address is one nobody can select in a single go.
func addressesListed() string {
	listed := make([]string, 0, len(theStores))
	for _, store := range theStores {
		listed = append(listed, fmt.Sprintf("  %s (%s)", store.link, store.phone))
	}
	return strings.Join(listed, "\n")
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
// `titled` is the name the code is drawn under, and is empty for a run that draws only one.
//
// It is a variable so a test can read what was about to be drawn. The token on the code is the
// one thing that has to match the hash the store was given, and once it has been drawn as a code
// there is no reading it back out.
var present = func(titled string, carried []byte, carriesASecret bool) error {
	code, err := qrcode.Encode(string(carried), qrcode.M)
	if err != nil {
		return err
	}
	code.Scale = codeScale
	return drawInTheTerminal(titled, code, carriesASecret)
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
func drawInTheTerminal(titled string, code *qrcode.Code, carriesASecret bool) error {
	drawn := blocksFor(code)
	// **A code drawn under no name is one there is nothing to confuse it with.** Where two are
	// drawn one after the other, the name above each is the only thing saying which phone the
	// one below is for.
	if titled != "" {
		drawn = titled + "\n" + drawn
	}
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
