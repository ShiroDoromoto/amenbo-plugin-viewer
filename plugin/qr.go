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
type pairing struct {
	V   int    `json:"v"`
	URL string `json:"url"`
	T   string `json:"t"`
	K   string `json:"k"`
}

// codeScale is how many image pixels one module of the code becomes. The code carries about 150
// characters, so it lands around version 7 — some 45 modules a side, which at this scale is an
// image a phone reads from a comfortable distance without filling the screen.
const codeScale = 10

// phonesName is where the labels are kept, in the plugin's own directory beside the sync state.
//
// **The tokens themselves are not here.** Revoking a phone needs only the ability to say which
// one, and the value exists on the phone that photographed it and nowhere else. Keeping it would
// put every paired phone's credential in one file, to be taken all at once.
const phonesName = "paired-phones.json"

// phones is that record: a label and the day it was issued, per phone.
type phones struct {
	V      int     `json:"v"`
	Paired []phone `json:"paired"`
}

type phone struct {
	Label    string `json:"label"`
	IssuedAt string `json:"issued_at"`
}

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

	carried, err := json.Marshal(pairing{V: specVersion, URL: where.url, T: token, K: key})
	if err != nil {
		return err
	}
	shown, left, err := present(carried, *inTerminal)
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
func (s store) issue(label, hash string) (string, error) {
	body, err := json.Marshal(map[string]string{"label": label, "hash": hash})
	if err != nil {
		return "", err
	}
	request, err := http.NewRequest(http.MethodPut, s.url+"/tokens", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	request.Header.Set("Authorization", "Bearer "+s.token)
	request.Header.Set("Content-Type", "application/json")

	answer, err := (&http.Client{Timeout: sendTimeout}).Do(request)
	if err != nil {
		return "", fmt.Errorf("/tokens did not answer: %w", err)
	}
	defer answer.Body.Close()

	var said struct {
		IssuedAt string `json:"issued_at"`
		Error    string `json:"error"`
	}
	decoded := json.NewDecoder(answer.Body).Decode(&said)
	if answer.StatusCode < 200 || answer.StatusCode > 299 {
		if decoded == nil && said.Error != "" {
			return "", fmt.Errorf("/tokens answered %d: %s", answer.StatusCode, said.Error)
		}
		return "", fmt.Errorf("/tokens answered %d", answer.StatusCode)
	}
	if decoded != nil {
		return "", fmt.Errorf("/tokens answered %d with something this build cannot read: %w", answer.StatusCode, decoded)
	}
	return said.IssuedAt, nil
}

// hashOf is how a read token is written down: SHA-256, lower-case hex, which is what the Worker
// compares an offered token against.
func hashOf(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// rememberThePhone adds the label to the local record, or moves its date if that name was paired
// before — re-pairing one phone replaces its token at the store, so a second row here would name
// a token that no longer exists.
//
// **A record that cannot be written is a failed pairing**, even though the token is already
// issued: a phone that can read and cannot be named is one nobody can cut off.
func rememberThePhone(label, issuedAt string) error {
	known, err := readPhones()
	if err != nil {
		return err
	}
	for i, paired := range known.Paired {
		if paired.Label == label {
			known.Paired[i].IssuedAt = issuedAt
			return writePhones(known)
		}
	}
	known.Paired = append(known.Paired, phone{Label: label, IssuedAt: issuedAt})
	return writePhones(known)
}

func readPhones() (phones, error) {
	dir, err := pluginDir()
	if err != nil {
		return phones{}, err
	}
	raw, err := os.ReadFile(filepath.Join(dir, phonesName))
	if os.IsNotExist(err) {
		return phones{V: stateVersion}, nil
	}
	if err != nil {
		return phones{}, fmt.Errorf("the paired phones cannot be read: %w", err)
	}
	var known phones
	if err := json.Unmarshal(raw, &known); err != nil || known.V != stateVersion {
		return phones{}, errors.New("the record of paired phones is in a shape this build cannot read")
	}
	return known, nil
}

func writePhones(known phones) error {
	known.V = stateVersion
	dir, err := pluginDir()
	if err != nil {
		return err
	}
	raw, err := json.Marshal(known)
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, phonesName), raw, 0o600); err != nil {
		return fmt.Errorf("the paired phones cannot be written: %w", err)
	}
	return nil
}

// present encodes what the phone is to read and puts it in front of the camera.
//
// It is a variable so a test can read what was about to be shown. The token on the code is the
// one thing that has to match the hash the store was given, and once it has been drawn as a code
// there is no reading it back out.
var present = func(carried []byte, inTerminal bool) (shown, left string, err error) {
	code, err := qrcode.Encode(string(carried), qrcode.M)
	if err != nil {
		return "", "", err
	}
	code.Scale = codeScale
	return show(code, inTerminal)
}

// show puts the code where the camera can see it, and says how it did and what it left behind.
//
// **The image is the way it is meant to be seen.** How large it is, how bright, and how square
// its pixels are then belong to the operating system's own viewer rather than to whatever the
// user's terminal is set to — and a code that reads only on some terminals is not one to hang the
// whole of pairing on. The terminal is what is left when there is no screen to open it on.
func show(code *qrcode.Code, inTerminal bool) (shown, left string, err error) {
	if !inTerminal && thereIsAScreen() {
		left, err := openAsAnImage(code)
		if err == nil {
			return "image", left, nil
		}
		logf("%s: the image could not be opened (%v) — drawing it here instead", pluginName, err)
	}
	if err := drawInTheTerminal(code); err != nil {
		return "", "", err
	}
	return "terminal", "", nil
}

// openAsAnImage writes the code out and hands it to whatever opens images, then waits to be told
// it has been read so the file can go.
//
// **What is on disk is the key.** It is written where only this user can reach it and taken away
// as soon as the phone has had it — and when there is nobody to ask, it is left with its path
// said out loud rather than removed from under a viewer that is still showing it.
func openAsAnImage(code *qrcode.Code) (left string, err error) {
	dir, err := os.MkdirTemp("", "amenbo-viewer-pairing-")
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, "pairing.png")
	if err := os.WriteFile(path, code.PNG(), 0o600); err != nil {
		os.RemoveAll(dir)
		return "", err
	}
	if err := openInTheViewer(path); err != nil {
		os.RemoveAll(dir)
		return "", err
	}

	terminal, err := os.OpenFile(terminalPath, os.O_RDWR, 0)
	if err != nil {
		logf("%s: the code is at %s, and it carries the key — delete it once the phone has read it.", pluginName, path)
		return path, nil
	}
	defer terminal.Close()
	fmt.Fprint(terminal, "\nthe pairing code is on screen. Press return once the phone has read it: ")
	bufio.NewReader(terminal).ReadString('\n')
	os.RemoveAll(dir)
	return "", nil
}

// thereIsAScreen says whether opening an image is worth trying. Everywhere but Linux there is a
// windowing system by definition; on Linux a machine with no display would hand the run to an
// opener that has nowhere to put it.
func thereIsAScreen() bool {
	if runtime.GOOS != "linux" {
		return true
	}
	return os.Getenv("DISPLAY") != "" || os.Getenv("WAYLAND_DISPLAY") != ""
}

// openInTheViewer hands the file to whatever the system opens images with. Each of these returns
// as soon as the viewer has been handed the file, which is what lets the run carry on and wait
// for the person instead of for the window.
var openInTheViewer = func(path string) error {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", path).Run()
	case "windows":
		return exec.Command("cmd", "/c", "start", "", path).Run()
	default:
		return exec.Command("xdg-open", path).Run()
	}
}

// drawInTheTerminal writes the code out in half-blocks: one column per module, one row per two,
// which is what keeps a code that is 45 modules across inside 80 columns.
//
// It goes to the terminal itself rather than to stderr, because amenbo holds a plugin's stderr
// until the run is over — and a code nobody can see while the run is waiting on them is no code
// at all.
func drawInTheTerminal(code *qrcode.Code) error {
	drawn := blocksFor(code)
	terminal, err := os.OpenFile(terminalPath, os.O_RDWR, 0)
	if err != nil {
		logf("%s: %s", pluginName, drawn)
		logf("%s: that code carries the key, and it stays in this terminal's scrollback.", pluginName)
		return nil
	}
	defer terminal.Close()
	fmt.Fprint(terminal, "\n"+drawn+"\n")
	fmt.Fprintln(terminal, "that code carries the key, and it stays in this terminal's scrollback.")
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
// **A name is asked for rather than made up.** Issuing under a name that is already there
// replaces that phone's token, so a default would silently unpair the phone somebody paired
// yesterday — and the name is what they will have to recognise when they cut one off.
func askForALabel() (string, error) {
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
