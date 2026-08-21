// Command viewer is Amenbo's official viewer plugin: it carries an encrypted snapshot of the
// project out to a place the user owns, so Amenbo Viewer on their phone can read the backlog
// while they are away from the PC.
//
// It has both faces a plugin can have.
//
//   - The observation face. Amenbo fires the plugin with NO arguments and the event's JSON on
//     stdin. Nobody is waiting for it. What an event says here is that what the phone holds is
//     now behind — the trigger for a send, never the send's audience.
//   - The command face. A person or an AI invokes it on purpose
//     (`amenbo plugin run viewer setup`) and waits for an answer. Arguments arrive on argv;
//     stdout is the machine return value Amenbo relays back verbatim; stderr is the human
//     diagnostics; the exit code is the verdict.
//
// One route carries the bytes:
//
//	anywhere → the user's own Cloudflare Worker and its database, over HTTPS.
//
// **There were two.** The other was a folder in the user's iCloud Drive, which needed nothing set
// up — and never said whether it had carried anything. A cursor cannot move over a route that
// gives no answer, so it went (see README.md).
//
// **The plugin encrypts, and nothing downstream decrypts.** The key reaches the phone by QR,
// off the network, so the Worker never sees it — which is what makes a place the user merely
// rents safe to leave a snapshot in.
//
// # What is built
//
// Both routes carry. The Cloudflare one is stood up by `setup` and handed a phone's key by `qr`;
// the mac one needs neither, being a folder the OS grows once the app has been opened on a phone.
// `push` and the hook place the same encrypted records on every route that is open.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

// contractVersion is the payload contract this plugin reads. Amenbo leads every document it
// writes with `v` and raises it only on a breaking change — new fields are added silently — so
// a document announcing a different version is one this plugin must not guess at.
const contractVersion = 1

// pluginName is what Amenbo knows this plugin as: its manifest's name, its installed directory,
// and the word a user types after `plugin`. One spelling, so what is written under it is found
// again. It is `viewer` and not `amenbo-plugin-viewer`: the repository names the thing that is
// built, the manifest names the thing that is installed.
const pluginName = "viewer"

// The settings this plugin keeps. **One of them is the user's, and three are not**: the three the
// Cloudflare route needs are what `setup` generates and writes back, and `routes` is the only
// answer a person is asked for — which places this may carry to, read as a bound rather than a
// switch (see `routes.go`). Two of the three are declared secret, so Amenbo hands those over in
// the environment rather than in the `config` object on stdin — which is why those two are
// spelled twice, once as the key `setup` writes them under and once as the variable they come
// back in.
//
// Neither route has a setting saying *where*: the mac one writes into the app's own container,
// and the Cloudflare one into the endpoint `setup` deployed.
const (
	configRoutes        = "routes"
	configWorkerURL     = "worker_url"
	configAuthToken     = "auth_token"
	configEncryptionKey = "encryption_key"
	envAuthToken        = "AMENBO_CONFIG_AUTH_TOKEN"
	envEncryptionKey    = "AMENBO_CONFIG_ENCRYPTION_KEY"
)

// out and errOut are the plugin's two channels, indirected so the tests can read what was
// written to each. The split IS the contract: whatever a caller consumes goes to out, whatever
// a human reads goes to errOut, and mixing them corrupts the return value.
var (
	out    io.Writer = os.Stdout
	errOut io.Writer = os.Stderr
)

// logf writes one diagnostic line to stderr, keeping stdout reserved for the return value.
func logf(format string, a ...any) {
	fmt.Fprintf(errOut, format+"\n", a...)
}

// input is the JSON document Amenbo writes to the plugin's stdin. Both faces receive one, and
// they overlap: `v` and `config` are always there, while the event fields are filled in only
// when an event fired. Unknown keys are ignored — the contract grows by addition, so a plugin
// that refused them would break on the next Amenbo.
type input struct {
	// V is the contract version the document is written to.
	V int `json:"v"`
	// Event is the event's namespace name, e.g. "task.done". Empty on the command face, where
	// nothing fired.
	Event string `json:"event"`
	// ID is the affected record's conversational number — the id a person knows it by.
	ID int64 `json:"id"`
	// Actor is who drove the write: "human" or "ai". This plugin reports neither — a snapshot
	// carries the backlog, not who moved it — but the field is read so the shape Amenbo writes
	// is visible here in full.
	Actor string `json:"actor"`
	// At is when the event fired, as "2026-07-22T09:00:00Z". Redelivery of one event carries
	// the same moment, which is what tells a replay from the user acting twice.
	At string `json:"at"`
	// Version is what the store was at when the event fired, on the events that carry it. It is
	// a pointer because 0 is a version like any other: absent and zero have to stay apart, or a
	// store legitimately sitting at 0 would be asked what version it is at on every write.
	Version *int64 `json:"version"`
	// New is the record's state after the change, for the events whose name does not already
	// say it.
	New string `json:"new"`
	// Config holds the plugin's own non-secret settings, as the user filled them in. Secrets
	// never appear here: Amenbo puts those in the environment instead.
	Config map[string]any `json:"config"`
}

// setting reads one non-secret setting as text. A value that is not a string is not one this
// plugin can use, and reads as absent rather than being coerced.
func (in input) setting(key string) string {
	text, _ := in.declared(key)
	return text
}

// declared reads one non-secret setting and says whether Amenbo sent it at all.
//
// **Empty and absent are different answers**, and one setting turns on the difference: a set of
// candidates with every one of them ticked off arrives as an empty string, while a key Amenbo
// never sent is one this build knows about and that Amenbo does not. Reading them as the same
// thing makes "none of them" mean "all of them".
func (in input) declared(key string) (string, bool) {
	value, sent := in.Config[key]
	text, isText := value.(string)
	return strings.TrimSpace(text), sent && isText
}

// secret reads one of the settings Amenbo declares secret. Those never reach the document on
// stdin — they arrive in the environment instead, which is the whole reason for the second way
// of reading a setting.
func secret(name string) string {
	return strings.TrimSpace(os.Getenv(name))
}

// readInput reads the document Amenbo feeds on stdin.
//
// Amenbo always writes one and closes the pipe, so the read finishes promptly. A hand run from
// a terminal is fed nothing at all, and waiting for a person to type JSON would hang the plugin
// on `viewer help` — so an interactive stdin is skipped rather than read. A document that will
// not parse is reported and dropped: on the hook face nobody is waiting for it, and on the
// command face the settings it carries are optional, so neither is worth refusing to run over.
func readInput(f *os.File) input {
	if info, err := f.Stat(); err == nil && info.Mode()&os.ModeCharDevice != 0 {
		return input{}
	}
	raw, err := io.ReadAll(f)
	if err != nil || len(bytes.TrimSpace(raw)) == 0 {
		return input{}
	}
	var in input
	if err := json.Unmarshal(raw, &in); err != nil {
		logf("%s: ignoring an input document that will not parse: %v", pluginName, err)
		return input{}
	}
	return in
}

func main() {
	in := readInput(os.Stdin)
	os.Exit(run(in, os.Args[1:]))
}

// run is main with the process left out, so a test can drive a whole invocation and read both
// channels back. It answers with the exit code rather than taking it: 0 for a run that produced
// its return value, 1 for one that failed and has none, 2 for an invocation that was never a
// run at all.
func run(in input, args []string) int {
	// No arguments is the observation face — Amenbo fired us for an event and is not waiting.
	// A word means someone invoked us on purpose.
	if len(args) == 0 {
		hook(in)
		return 0
	}

	// The five calls the settings screen raises are the ones a person reads on a screen, so they
	// are said in the language that person reads Amenbo in (see `wording.go`). The read costs one
	// run of Amenbo, and it is paid here — by those five, and by nothing else: the observation
	// face is fired on every write, and what is typed is answered in English.
	if settingsFace[args[0]] {
		screen = wordsIn(languageInTheStore())
	}

	switch args[0] {
	case "app":
		return do(getTheApp(in, args[1:]))
	case "token":
		return do(token(in, args[1:]))
	case "setup":
		return do(setup(in, args[1:]))
	case "push":
		return do(push(in, args[1:]))
	case "check":
		return do(check(in, args[1:]))
	case "qr":
		return do(qr(in, args[1:]))
	case "phones":
		return do(listPhones(in, args[1:]))
	case "revoke":
		return do(revoke(in, args[1:]))
	case "help", "-h", "--help":
		usage()
		return 0
	default:
		logf("%s: unknown command %q", pluginName, args[0])
		usage()
		return 2
	}
}

// settingsFace is the calls the settings screen raises: the line it asks for on its own
// (`settings.check`) and the four buttons it offers (`settings.actions`), as `dev/manifest.json`
// declares them. They are the plugin's only face a person reads without having typed anything,
// which is what makes them the ones worth translating.
var settingsFace = map[string]bool{
	"check": true,
	"app":   true,
	"token": true,
	"setup": true,
	"qr":    true,
}

// do ends the command face on the verdict the exit code carries.
func do(err error) int {
	if err != nil {
		logf("%s: %v", pluginName, err)
		return 1
	}
	return 0
}

// push carries what the store holds to the Cloudflare route, by hand.
//
// The hook does this on its own whenever a write moves the store version, so this is the way to
// push what was left behind — a send that failed while the network was down, a store that was
// restored, a phone that has fallen behind for a reason nobody can see. Being asked out loud is
// what makes it skip the version guard and read the ledger regardless.
func push(in input, _ []string) error {
	placed, err := carry(in, true)
	if err != nil {
		return err
	}
	if placed == 0 {
		logf("%s: nothing had moved — the phone is level with the store", pluginName)
		return nil
	}
	logf("%s: placed %d record(s)", pluginName, placed)
	return nil
}

// theRouteFromHere is the paragraph of the usage that names where the records go.
//
// **There is one route, and it is the same on every machine.** There were two: the other was the
// app's own iCloud folder, which needed nothing set up and told nobody whether it had carried
// anything. It went with the version this text belongs to (see plugin/README.md), and with it went
// the paragraph that differed by OS.
func theRouteFromHere() string {
	return `One route carries the records:

  your own Cloudflare Worker, over HTTPS. 'setup' stands it up in your account.`
}

func usage() {
	logf(`%s — Amenbo's official plugin: read your backlog on your phone

The plugin encrypts your backlog a record at a time and carries it to a place YOU own. Amenbo
Viewer on the phone reads it there. Nothing is hosted by anyone else, and nothing is written back.

The app is at %s. 'app' puts that page on a code, since the
screen you are reading this on is not the one that installs it.

%s

Usage (through Amenbo, from the project the plugin is enabled for):
  amenbo plugin run %s app       put the app's App Store page on a code the phone reads
                                      --terminal      draw the code here instead of opening it
  amenbo plugin run %s token     open Cloudflare's token screen, with the permissions
                                      'setup' needs already ticked
  amenbo plugin run %s setup     stand up the Worker and its database in your own account
                                      --account <id>  when your token reaches more than one
  amenbo plugin run %s check     where records are reaching right now, in one line
  amenbo plugin run %s push      carry what has not reached the phone yet, by hand
  amenbo plugin run %s qr        pair one phone: issue its read token and put it on screen
                                      --label <name>  what to call it, since cutting it off
                                                      later names it
                                      --terminal      draw the code here instead of opening it
  amenbo plugin run %s phones    the phones that may read, and when each was paired
  amenbo plugin run %s revoke <name>
                                    cut one of them off. The others carry on reading

Setting the Cloudflare route up asks you to press and to paste, and nothing else. 'token' opens a
Cloudflare token screen with the permissions already ticked, and 'setup' takes back the token that
page gives you. That token stands the Worker and the database up and is not kept. What it leaves
in your account is yours — uninstalling this plugin does not take it away.

Those two, 'app' and 'qr' are on the settings screen as buttons, numbered in the order they are
pressed, which is the only route for someone who has no terminal to type any of this into. 'app'
is the first of them: the phone is what reads all this, and nothing here is worth standing up
until there is one to read it.

With no arguments the plugin is an observation hook: Amenbo fires it when the project changed,
which is what tells it the phone is now behind. It carries what moved on its own, so 'push' is
for what was left behind — a send that failed while the network was down, or a phone that has
fallen behind for a reason nobody can see.

Settings — **one of them is yours, and three are not.**

  %s          whether this may carry to the place above. It can only take it away: ticking
                  it still needs the Worker to exist before anything reaches it, so the
                  setting is never at odds with what is actually there. Tick nothing and the
                  plugin stays on and carries nowhere. 'check' says where it is reaching
                  right now

'setup' writes the other three, and there is nothing to type in any of them:
  %s      the endpoint it deployed
  %s      the token it generated (secret)
  %s  the key it generated (secret). It reaches the phone by QR, never by network

Every phone gets its own read token, issued when you pair it, so losing one is one token to cut
rather than every phone to pair again. 'qr' is how one is issued: the code it puts on screen is
read by the camera and never goes over the network, which is what keeps the key out of the Worker.
'revoke' is the other end of that — one phone stops reading and the rest never notice.
`,
		pluginName, appStoreLink, theRouteFromHere(),
		pluginName, pluginName, pluginName, pluginName, pluginName, pluginName, pluginName, pluginName,
		configRoutes, configWorkerURL, configAuthToken, configEncryptionKey)
}
