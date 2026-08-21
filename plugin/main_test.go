package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestMain fills in what no test may be allowed to reach for.
//
// `setup` reads the pasted token from the terminal, so a test that let it get that far would sit
// waiting for somebody to type — on a machine that has a terminal to wait on, which is most of
// them. A token in the environment is read first, and a stand-in pointed at a door nothing is
// listening behind turns any run of it into a quick failure. A test that wants a real answer
// points the stand-in somewhere of its own.
func TestMain(m *testing.M) {
	os.Setenv(envCloudflareToken, "a-throwaway-api-token")
	os.Setenv(envStandIn, "http://127.0.0.1:1")
	// **The machine's screen is the other thing no test may reach.** `token` and `qr` hand a
	// link or an image to whatever the system opens those with, and a suite that got that far
	// would put a browser window in front of whoever ran it. The opener is refused here by
	// default, so a path nobody thought to hold refuses instead of opening; the tests that are
	// about the opening swap in one of their own.
	openInTheSystem = func(target string) error {
		return fmt.Errorf("a test reached for the machine's screen with %q", target)
	}
	// **The store's language is the third.** A whole invocation runs `amenbo config --json` for
	// the five calls the settings screen raises, and a suite that let it would read the language
	// of whoever is running the tests — so the same run would pass on one machine and fail on
	// the next. A test about the language says so by swapping this back.
	languageInTheStore = func() string { return fallbackLanguage }
	os.Exit(m.Run())
}

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
// Amenbo feeds a plugin on stdin.
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

// Every command on this face is written now, and what one refuses over is a route that was never
// stood up — an answer the user can act on, and a different thing from a command that does not
// exist yet.
func TestPushSaysWhenThereIsNowhereToSendTo(t *testing.T) {
	t.Setenv(envAuthToken, "")
	withICloud(t, false)

	var code int
	stdout, stderr := capture(t, func() { code = run(input{}, []string{"push"}) })

	if code != 1 {
		t.Errorf("exit %d — a send with nowhere to go did not happen", code)
	}
	if stdout != "" {
		t.Errorf("stdout is the return value and there is none: %q", stdout)
	}
	if !strings.Contains(stderr, "setup") {
		t.Errorf("the refusal does not say what to do about it: %q", stderr)
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
		if !strings.Contains(stderr, "Amenbo Viewer") && !strings.Contains(stderr, "phone") {
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
	in := readInput(fed(t, `{"v":1,"event":"task.done","id":42,"actor":"ai","config":{"worker_url":"https://viewer.example.workers.dev"}}`))

	if in.V != 1 || in.Event != "task.done" || in.ID != 42 || in.Actor != "ai" {
		t.Fatalf("%+v", in)
	}
	if got := in.setting(configWorkerURL); got != "https://viewer.example.workers.dev" {
		t.Errorf("setting %s = %q", configWorkerURL, got)
	}
}

// A field Amenbo adds later arrives here rather than being refused: the contract grows by
// addition, so a plugin that rejected unknown keys would break on the next Amenbo.
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
