package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// capture redirects the plugin's two channels for one invocation and hands back what each got.
// The split is the contract, so a test that only looked at one of them would miss the failure
// that matters most here — a diagnostic written where a caller reads its return value.
func capture(t *testing.T, invoke func()) (stdout, stderr string) {
	t.Helper()
	var o, e bytes.Buffer
	outWas, errWas := out, errOut
	out, errOut = &o, &e
	t.Cleanup(func() { out, errOut = outWas, errWas })
	invoke()
	return o.String(), e.String()
}

// fed writes text into a real file and hands back the open handle, standing in for the pipe
// amenbo feeds a plugin on stdin.
func fed(t *testing.T, text string) *os.File {
	t.Helper()
	path := filepath.Join(t.TempDir(), "stdin")
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	return f
}

// The commands the plugin dispatches. Each is unbuilt, and the exit code is what says so — the
// point of refusing rather than printing a note and exiting 0.
var unbuiltCommands = []string{"setup", "push", "qr"}

// An unbuilt command fails, and fails visibly. A caller that reads only the exit code has to be
// able to tell this from a send that went through.
func TestAnUnbuiltCommandFailsAndSaysWhatItWaitsOn(t *testing.T) {
	for _, command := range unbuiltCommands {
		t.Run(command, func(t *testing.T) {
			var code int
			stdout, stderr := capture(t, func() { code = run(input{}, []string{command}) })

			if code != 1 {
				t.Errorf("exit %d — an unbuilt command has no return value, so it is a failed run", code)
			}
			if stdout != "" {
				t.Errorf("stdout is the return value and there is none: %q", stdout)
			}
			if !strings.Contains(stderr, "not built yet") || !strings.Contains(stderr, "spec/") {
				t.Errorf("a refusal has to say what it waits on: %q", stderr)
			}
		})
	}
}

// The refusals are one sentinel, so a caller can branch on "unbuilt" without matching prose.
func TestTheRefusalIsRecognisable(t *testing.T) {
	for _, command := range unbuiltCommands {
		if err := errWaitingOnSpec(command); !strings.Contains(err.Error(), errUnbuilt.Error()) {
			t.Errorf("%s: %v does not carry the sentinel", command, err)
		}
	}
}

// A word this plugin does not know is a usage error, not a failed run — exit 2, and the usage
// so the caller can see what it should have typed.
func TestAnUnknownCommandIsAUsageError(t *testing.T) {
	var code int
	_, stderr := capture(t, func() { code = run(input{}, []string{"send-it"}) })

	if code != 2 {
		t.Errorf("exit %d — a word that is not a command was never a run", code)
	}
	if !strings.Contains(stderr, `unknown command "send-it"`) {
		t.Errorf("the refusal has to name what was typed: %q", stderr)
	}
	if !strings.Contains(stderr, "Usage") {
		t.Errorf("a usage error has to show the usage: %q", stderr)
	}
}

// Help is something the caller asked for, so it succeeds — and it goes to stderr like every
// other thing a person reads, leaving stdout clean.
func TestHelpSucceedsAndStaysOffStdout(t *testing.T) {
	for _, word := range []string{"help", "-h", "--help"} {
		var code int
		stdout, stderr := capture(t, func() { code = run(input{}, []string{word}) })

		if code != 0 {
			t.Errorf("%s: exit %d", word, code)
		}
		if stdout != "" {
			t.Errorf("%s: usage belongs on stderr, got %q on stdout", word, stdout)
		}
		if !strings.Contains(stderr, "amenbo Viewer") && !strings.Contains(stderr, "phone") {
			t.Errorf("%s: %q does not read like the usage", word, stderr)
		}
	}
}

// No arguments is the observation face, and it never fails: nobody is waiting on the answer, so
// a non-zero exit would only put a warning in the execution log for a run with nothing to say.
func TestNoArgumentsIsTheHookAndAlwaysSucceeds(t *testing.T) {
	var code int
	capture(t, func() { code = run(input{V: contractVersion, Event: "task.done", ID: 42}, nil) })

	if code != 0 {
		t.Errorf("exit %d — the hook has no one to fail to", code)
	}
}

func TestReadInputTakesTheDocumentAmenboWrites(t *testing.T) {
	in := readInput(fed(t, `{"v":1,"event":"task.done","id":42,"actor":"ai","config":{"icloud_folder":"/tmp/x"}}`))

	if in.V != 1 || in.Event != "task.done" || in.ID != 42 || in.Actor != "ai" {
		t.Fatalf("%+v", in)
	}
	if got := in.setting(configICloudFolder); got != "/tmp/x" {
		t.Errorf("setting %s = %q", configICloudFolder, got)
	}
}

// A field amenbo adds later arrives here rather than being refused: the contract grows by
// addition, so a plugin that rejected unknown keys would break on the next amenbo.
func TestReadInputIgnoresKeysItDoesNotKnow(t *testing.T) {
	in := readInput(fed(t, `{"v":1,"event":"task.done","something_new":{"deep":true}}`))

	if in.V != 1 || in.Event != "task.done" {
		t.Fatalf("%+v", in)
	}
}

// Nothing to read, and text that is not a document, are both dropped rather than raised: on the
// hook face nobody is waiting, and on the command face the settings are optional.
func TestReadInputDropsWhatItCannotUse(t *testing.T) {
	for name, text := range map[string]string{"empty": "", "blank": "  \n", "not json": "hello"} {
		t.Run(name, func(t *testing.T) {
			var in input
			capture(t, func() { in = readInput(fed(t, text)) })

			// input holds a map, so it is not comparable — what is being asserted is that
			// nothing was taken from it, and every field standing at its zero says that.
			if in.V != 0 || in.Event != "" || in.ID != 0 || in.Actor != "" || in.Config != nil {
				t.Errorf("%+v", in)
			}
		})
	}
}

// A setting whose value is not text is not one this plugin can use. Reading it as absent is what
// keeps a mistyped setting from becoming a path or a URL built out of a coerced number.
func TestASettingThatIsNotTextReadsAsAbsent(t *testing.T) {
	in := input{Config: map[string]any{configWorkerURL: 42}}

	if got := in.setting(configWorkerURL); got != "" {
		t.Errorf("setting %s = %q", configWorkerURL, got)
	}
}
