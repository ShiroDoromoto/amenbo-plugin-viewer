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
// # What is built
//
// Standing the Cloudflare route up (`setup`) and the send are: `push` and the hook both carry
// what the store holds to that route, encrypted a record at a time. Handing the key to a phone
// (`qr`) is not written yet, and it refuses rather than pretending, so nothing can be built on
// top of it believing it worked.
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

// The settings this plugin keeps. **There is nothing for the user to fill in**: all three are
// what `setup` generates and writes back. Two of them are declared secret, so amenbo hands those
// over in the environment rather than in the `config` object on stdin — which is why those two
// are spelled twice, once as the key `setup` writes them under and once as the variable they come
// back in.
//
// The mac route has no setting at all — it writes into the app's own container, and the
// directory being there is what turns it on.
const (
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
	// Version is what the store was at when the event fired, on the events that carry it. It is
	// a pointer because 0 is a version like any other: absent and zero have to stay apart, or a
	// store legitimately sitting at 0 would be asked what version it is at on every write.
	Version *int64 `json:"version"`
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

// secret reads one of the settings amenbo declares secret. Those never reach the document on
// stdin — they arrive in the environment instead, which is the whole reason for the second way
// of reading a setting.
func secret(name string) string {
	return strings.TrimSpace(os.Getenv(name))
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

// errNotBuilt is what a command that has not been written yet answers with.
//
// Refusing is the honest answer, and the exit code is the point: a command that printed a
// friendly note and exited 0 would be indistinguishable, to anything that calls it, from one
// that had done the work. Nothing should be able to build on this and believe it worked.
func errNotBuilt(what string) error {
	return fmt.Errorf("%s: %w. See the repository README for what is", what, errUnbuilt)
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

// qr puts the endpoint URL, the read token and the encryption key on screen as a QR code, for
// the phone's camera to take.
//
// **The key must not travel through the Worker.** Route it through the server and the server
// becomes able to read what it is storing, and the end-to-end encryption stops meaning
// anything. A screen and a camera are the one path with no network on it.
func qr(input, []string) error {
	return errNotBuilt("qr")
}

func usage() {
	logf(`%s — amenbo's official plugin: read your backlog on your phone

The plugin encrypts your backlog a record at a time and carries it to a place YOU own. amenbo
Viewer on the phone reads it there. Nothing is hosted by anyone else, and nothing is written back.

Two routes carry the same records:

  mac      the app's own iCloud folder. Nothing to set up, no account, no key to hand over.
           It turns itself on once you have opened the app on your phone — that is what makes
           the folder exist, and until then there is nothing to do here.
  anywhere your own Cloudflare Worker, over HTTPS. 'setup' stands it up in your account.

Usage (through amenbo, from the project the plugin is enabled for):
  amenbo plugin run %s setup     stand up the Worker and its database in your own account
                                      --account <id>  when your token reaches more than one
  amenbo plugin run %s push      carry what has not reached the phone yet, by hand
  amenbo plugin run %s qr        show the pairing QR for the phone's camera to read

'setup' asks you to press and to paste, and nothing else: it opens a Cloudflare token screen with
the permissions already ticked, and you paste back the token it gives you. That token stands the
Worker and the database up and is not kept. What it leaves in your account is yours — uninstalling
this plugin does not take it away.

With no arguments the plugin is an observation hook: amenbo fires it when the project changed,
which is what tells it the phone is now behind. It carries what moved on its own, so 'push' is
for what was left behind — a send that failed while the network was down, or a phone that has
fallen behind for a reason nobody can see.

Settings — **none of them is yours to fill in.** 'setup' writes all three:
  %s       the endpoint it deployed
  %s      the token it generated (secret)
  %s  the key it generated (secret). It reaches the phone by QR, never by network

**'qr' is not built yet**, and neither is writing to the iCloud folder. They refuse rather than
pretend, so nothing can be built on top believing it worked.`,
		pluginName, pluginName, pluginName, pluginName, configWorkerURL, configAuthToken, configEncryptionKey)
}
