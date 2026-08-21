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
	"path/filepath"
	"runtime"
	"strings"
	"time"

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

// forgetTheCodeCommand is the word this binary calls itself back with, and it is on neither the
// manifest nor the usage: nobody is meant to type it. It is how the image lets go of itself once
// the phone has had its moment with it.
const forgetTheCodeCommand = "forget-the-code"

// codeDirPrefix names the directory each code is written in, and it is also the guard on the word
// above: forgetting a code removes a directory this one wrote, and nothing else the user has.
//
// It says code rather than pairing because more than one thing is drawn as one — the pairing code
// and the app's address both come through here, and a window titled after pairing would be the
// wrong word on the one that is only a link.
const codeDirPrefix = "amenbo-viewer-code-"

// codeLifetime is how long the image stays before it takes itself away. It is a window rather
// than a prompt because the button on the settings screen has no terminal to answer at — long
// enough to unlock a phone and point it, short enough that the key is not left lying about.
const codeLifetime = 2 * time.Minute

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
	if err != nil {
		return err
	}
	key := secret(envEncryptionKey)
	if key == "" {
		return errNoKey
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
	shown, left, err := present(carried, *inTerminal, carriesTheKey)
	if err != nil {
		return err
	}

	logf("%s: %q may read from now on. Cut it off later by that name.", pluginName, named)
	return json.NewEncoder(out).Encode(map[string]any{
		"label":     named,
		"issued_at": issuedAt,
		"shown":     shown,
		"png":       left,
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
		return "", fmt.Errorf("a phone is already paired as %q — cut it off with `%s revoke %s`, then pair it again",
			label, pluginName, label)
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
// carry the address across by hand — and the settings screen cannot write the address either,
// since its labels and help are drawn as plain text.
//
// Nothing on this code is a secret, so it is the same image with the warnings off. It still goes
// away on pairing's two minutes: the window is no shorter than a person needs to point a phone at
// it, and a public link left on disk is still a file that piles up in the temporary directory.
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

	// Nothing to open an image on and nothing to draw blocks in: the address in words is what is
	// left, and writing it out costs nothing when the page it names is public.
	if !thereIsAScreen() && !thereIsATerminal() {
		logf("%s: there is nothing here to draw a code on. Amenbo Viewer is at %s", pluginName, appStoreLink)
		return nil
	}
	if _, _, err := present([]byte(appStoreLink), *inTerminal, carriesNoSecret); err != nil {
		return fmt.Errorf("the code could not be drawn (%w) — Amenbo Viewer is at %s", err, appStoreLink)
	}
	logf("%s: point the phone's camera at the code. Amenbo Viewer is also at %s", pluginName, appStoreLink)
	return nil
}

// What a code is carrying, named rather than spelled as a bare true and false at the call. What
// turns on it is only what is said about the code once it is drawn: pairing puts the encryption
// key in front of a camera, and getting the app puts a public address there — so one of the two
// leaves something behind worth warning about, and the other leaves a link.
const (
	carriesTheKey   = true
	carriesNoSecret = false
)

// present encodes what the phone is to read and puts it in front of the camera.
//
// It is a variable so a test can read what was about to be shown. The token on the code is the
// one thing that has to match the hash the store was given, and once it has been drawn as a code
// there is no reading it back out.
var present = func(carried []byte, inTerminal, carriesASecret bool) (shown, left string, err error) {
	code, err := qrcode.Encode(string(carried), qrcode.M)
	if err != nil {
		return "", "", err
	}
	code.Scale = codeScale
	return show(code, inTerminal, carriesASecret)
}

// show puts the code where the camera can see it, and says how it did and what it left behind.
//
// **The image is the way it is meant to be seen.** How large it is, how bright, and how square
// its pixels are then belong to the operating system's own viewer rather than to whatever the
// user's terminal is set to — and a code that reads only on some terminals is not one to hang the
// whole of pairing on. The terminal is what is left when there is no screen to open it on.
func show(code *qrcode.Code, inTerminal, carriesASecret bool) (shown, left string, err error) {
	if !inTerminal && thereIsAScreen() {
		left, err := openAsAnImage(code, carriesASecret)
		if err == nil {
			return "image", left, nil
		}
		logf("%s: the image could not be opened (%v) — drawing it here instead", pluginName, err)
	}
	if err := drawInTheTerminal(code, carriesASecret); err != nil {
		return "", "", err
	}
	return "terminal", "", nil
}

// openAsAnImage writes the code out, hands it to whatever opens images, and sets its removal
// going.
//
// **What is on disk is the key.** It is written where only this user can reach it and taken away
// again by a run of this binary that outlives this one — nobody is asked to say when the phone is
// done, because the button on the settings screen has no terminal to be asked at, and a file
// waiting on a person who is not there waits for good.
func openAsAnImage(code *qrcode.Code, carriesASecret bool) (left string, err error) {
	dir, err := os.MkdirTemp("", codeDirPrefix)
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, "code.png")
	if err := os.WriteFile(path, code.PNG(), 0o600); err != nil {
		os.RemoveAll(dir)
		return "", err
	}
	if err := openInTheSystem(path); err != nil {
		os.RemoveAll(dir)
		return "", err
	}

	if err := eraseLater(dir); err != nil {
		if carriesASecret {
			logf("%s: the code is at %s, and it carries the key — delete it once the phone has read it (%v).", pluginName, path, err)
		} else {
			logf("%s: the code is at %s, and nothing was started to take it away again (%v).", pluginName, path, err)
		}
		return path, nil
	}
	logf("%s: the code is on screen, and the image goes in %d minutes — read it with the phone before then.",
		pluginName, int(codeLifetime/time.Minute))
	return "", nil
}

// eraseLater sets the code's own removal going, in a run of this binary that outlives this one.
//
// It is a variable so a test can see what was scheduled without starting anything: under a test
// the executable is the test binary, and handing it these arguments would run the tests again
// rather than sleep through a code's life.
var eraseLater = func(dir string) error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	child := exec.Command(self, forgetTheCodeCommand, dir)
	// It is given nothing: no channels, so Amenbo is not left holding a pipe open on a run that
	// has already answered, and no environment, so the key this run was handed does not sit in a
	// process listing for as long as the image lasts.
	child.Env = []string{}
	detached(child)
	return child.Start()
}

// forgetTheCode is the far side of that: it waits out the code's life and takes the image away.
//
// The directory it is given has to be one of ours by name. The word is on no manifest, but it is
// still a word this binary answers to, and one that removed whatever it was pointed at would be
// a delete anybody on the machine could aim.
func forgetTheCode(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("%s takes the one directory a code was written in", forgetTheCodeCommand)
	}
	dir := args[0]
	if !strings.HasPrefix(filepath.Base(dir), codeDirPrefix) {
		return fmt.Errorf("%q is not a pairing code this wrote", dir)
	}
	time.Sleep(codeLifetime)
	return os.RemoveAll(dir)
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
		return "", errors.New("the phone was not named, and a name is what revoking one gives")
	}
	return named, nil
}
