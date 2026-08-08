// Command viewer is amenbo's official viewer plugin: it carries an encrypted snapshot of the
// project out to a place the user owns, so amenbo Viewer on their phone can read the backlog
// while they are away from the PC.
//
// It has both faces a plugin can have.
//
//   - The observation face. amenbo fires the plugin with NO arguments and the event's JSON on
//     stdin. Nobody is waiting for it. What an event says here is that what the phone holds is
//     now behind — the trigger for a send, never the send's audience.
//   - The command face. A person or an AI invokes it on purpose
//     (`amenbo plugin run viewer setup`) and waits for an answer. Arguments arrive on argv;
//     stdout is the machine return value amenbo relays back verbatim; stderr is the human
//     diagnostics; the exit code is the verdict.
//
// Two routes carry the same bytes, and which one a user gets is decided by what they have
// rather than by a setting:
//
//	mac      → a folder in the user's iCloud Drive. No account, no key handover, no setup.
//	anywhere → the user's own Cloudflare Worker + KV, over HTTPS.
//
// **The plugin encrypts, and nothing downstream decrypts.** The key reaches the phone by QR,
// off the network, so the Worker never sees it — which is what makes a place the user merely
// rents safe to leave a snapshot in.
//
// # Skeleton
//
// The frame is here; the payload is not. Taking the snapshot, encrypting it and sending it all
// stand on the shared contract in `spec/`, which is not written yet — the four parts have to
// agree on the snapshot format, the cipher, what the QR carries and what the endpoints answer,
// and guessing any of it here would be a guess three other parts have to live with. So each
// command is dispatched, refuses honestly, and says what it waits on.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// contractVersion is the payload contract this plugin reads. amenbo leads every document it
// writes with `v` and raises it only on a breaking change — new fields are added silently — so
// a document announcing a different version is one this plugin must not guess at.
const contractVersion = 1

// pluginName is what amenbo knows this plugin as: its manifest's name, its installed directory,
// and the word a user types after `plugin`. One spelling, so what is written under it is found
// again. It is `viewer` and not `amenbo-plugin-viewer`: the repository names the thing that is
// built, the manifest names the thing that is installed.
const pluginName = "viewer"

// The settings this plugin keeps. The user fills in at most one of them by hand — where in
// their iCloud Drive the snapshot should land. The other three are what `setup` generates and
// writes back, and they are declared secret, so amenbo hands them over in the environment
// rather than in the `config` object on stdin.
const (
	configICloudFolder = "icloud_folder"
	configWorkerURL    = "worker_url"
	envAuthToken       = "AMENBO_CONFIG_AUTH_TOKEN"
	envEncryptionKey   = "AMENBO_CONFIG_ENCRYPTION_KEY"
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

// input is the JSON document amenbo writes to the plugin's stdin. Both faces receive one, and
// they overlap: `v` and `config` are always there, while the event fields are filled in only
// when an event fired. Unknown keys are ignored — the contract grows by addition, so a plugin
// that refused them would break on the next amenbo.
type input struct {
	// V is the contract version the document is written to.
	V int `json:"v"`
	// Event is the event's namespace name, e.g. "task.done". Empty on the command face, where
	// nothing fired.
	Event string `json:"event"`
	// ID is the affected record's conversational number — the id a person knows it by.
	ID int64 `json:"id"`
	// Actor is who drove the write: "human" or "ai". This plugin reports neither — a snapshot
	// carries the backlog, not who moved it — but the field is read so the shape amenbo writes
	// is visible here in full.
	Actor string `json:"actor"`
	// At is when the event fired, as "2026-07-22T09:00:00Z". Redelivery of one event carries
	// the same moment, which is what tells a replay from the user acting twice.
	At string `json:"at"`
	// New is the record's state after the change, for the events whose name does not already
	// say it.
	New string `json:"new"`
	// Config holds the plugin's own non-secret settings, as the user filled them in. Secrets
	// never appear here: amenbo puts those in the environment instead.
	Config map[string]any `json:"config"`
}

// setting reads one non-secret setting as text. A value that is not a string is not one this
// plugin can use, and reads as absent rather than being coerced.
func (in input) setting(key string) string {
	text, _ := in.Config[key].(string)
	return strings.TrimSpace(text)
}

// readInput reads the document amenbo feeds on stdin.
//
// amenbo always writes one and closes the pipe, so the read finishes promptly. A hand run from
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
	// No arguments is the observation face — amenbo fired us for an event and is not waiting.
	// A word means someone invoked us on purpose.
	if len(args) == 0 {
		hook(in)
		return 0
	}

	switch args[0] {
	case "setup":
		return do(setup(in, args[1:]))
	case "push":
		return do(push(in, args[1:]))
	case "qr":
		return do(qr(in, args[1:]))
	case "help", "-h", "--help":
		usage()
		return 0
	default:
		logf("%s: unknown command %q", pluginName, args[0])
		usage()
		return 2
	}
}

// do ends the command face on the verdict the exit code carries.
func do(err error) int {
	if err != nil {
		logf("%s: %v", pluginName, err)
		return 1
	}
	return 0
}

// errUnbuilt is the sentinel every unbuilt command wraps, so a caller can tell "this is not
// written yet" from "this ran and failed" without reading the sentence.
var errUnbuilt = errors.New("not built yet")

// errWaitingOnSpec is what every command answers with while the shared contract is unwritten.
//
// Refusing is the honest answer, and the exit code is the point: a command that printed a
// friendly note and exited 0 would be indistinguishable, to anything that calls it, from one
// that had sent the snapshot. Nothing should be able to build on this and believe it worked.
func errWaitingOnSpec(what string) error {
	return fmt.Errorf("%s: %w — it waits on the shared contract in spec/ (the snapshot format, the cipher, what the QR carries, what the endpoints answer). See the repository README", what, errUnbuilt)
}

// setup stands up the Cloudflare route in the user's own account: a KV namespace, the Worker,
// and the two secrets that are generated rather than chosen. What is left for the user is to
// press and to paste — never to judge which permissions a token should carry.
//
// The iCloud route has no setup at all, which is the whole reason it is the default one on mac.
func setup(input, []string) error {
	return errWaitingOnSpec("setup")
}

// push takes the snapshot as it stands, encrypts it, and puts it wherever the routes in play
// say: the iCloud Drive folder, the Worker, or both. It overwrites in full, every time — the
// same key, the same file — so what the user deleted is absent from the next snapshot rather
// than lingering as a tombstone.
func push(input, []string) error {
	return errWaitingOnSpec("push")
}

// qr puts the endpoint URL, the auth token and the encryption key on screen as a QR code, for
// the phone's camera to take.
//
// **The key must not travel through the Worker.** Route it through the server and the server
// becomes able to read what it is storing, and the end-to-end encryption stops meaning
// anything. A screen and a camera are the one path with no network on it.
func qr(input, []string) error {
	return errWaitingOnSpec("qr")
}

func usage() {
	logf(`%s — amenbo's official plugin: read your backlog on your phone

The plugin encrypts a snapshot of the project and carries it to a place YOU own. amenbo Viewer
on the phone reads it there. Nothing is hosted by anyone else, and nothing is written back.

Two routes carry the same bytes:

  mac      a folder in your iCloud Drive. Nothing to set up, no account, no key to hand over.
  anywhere your own Cloudflare Worker + KV, over HTTPS.

Usage (through amenbo, from the project the plugin is enabled for):
  amenbo plugin run %s setup     stand up the Worker and KV in your own Cloudflare account
  amenbo plugin run %s push      encrypt the snapshot as it stands and send it
  amenbo plugin run %s qr        show the pairing QR for the phone's camera to read

With no arguments the plugin is an observation hook: amenbo fires it when the project changed,
which is what tells it the phone is now behind.

Settings:
  %s   where in your iCloud Drive to write (mac only; the route is off while it is empty)
  %s       the endpoint 'setup' deployed
  auth_token      the token 'setup' generated (secret)
  encryption_key  the key 'setup' generated (secret). It reaches the phone by QR, never by network

Only the first is yours to fill in. 'setup' writes the rest.

**None of the three commands is built yet.** They wait on the shared contract in spec/, which
the plugin, the Worker and the app all read. Until it is written they refuse rather than
pretend, so nothing can be built on top believing it worked.`,
		pluginName, pluginName, pluginName, pluginName, configICloudFolder, configWorkerURL)
}
