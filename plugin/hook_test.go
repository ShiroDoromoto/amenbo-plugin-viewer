package main

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fired builds the document Amenbo writes when an event fires, with the settings a test wants
// standing on it.
func fired(event string, settings map[string]any) input {
	return input{V: contractVersion, Event: event, ID: 42, Actor: "ai", Config: settings}
}

// withICloud answers for the mac route, whose real drop is a directory no test may create: the
// route is stood up somewhere a test is allowed to write, or pointed at a path with nothing at
// it. It hands back the drop either way.
func withICloud(t *testing.T, live bool) string {
	t.Helper()
	drop := filepath.Join(t.TempDir(), "Documents")
	if live {
		if err := os.MkdirAll(drop, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	was := icloudDropPath
	icloudDropPath = func() string { return drop }
	t.Cleanup(func() { icloudDropPath = was })
	return drop
}

// A send that got nowhere is the state the user most needs written down: a route IS open, so the
// phone falls further behind with every write.
func TestTheHookSaysWhatStoppedTheSend(t *testing.T) {
	t.Setenv(envAuthToken, "a-throwaway-token")
	t.Setenv(envEncryptionKey, "")
	withICloud(t, false)

	stdout, stderr := capture(t, func() {
		hook(fired("task.done", map[string]any{configWorkerURL: "https://viewer.example.workers.dev"}))
	})

	if stdout != "" {
		t.Errorf("a hook's stdout is not a return value and nothing belongs on it: %q", stdout)
	}
	if !strings.Contains(stderr, "encryption key") {
		t.Errorf("the line does not say what stopped the send: %q", stderr)
	}
}

// The folder is on the user's own machine, in their own account, so nothing placed there is put
// in an envelope — and a mac with no Worker, which is where the key comes from, is a mac that can
// still feed a phone.
func TestTheFolderIsARouteWithNoKey(t *testing.T) {
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")
	withICloud(t, true)

	open := routesFor(fired("task.done", nil))

	if len(open) != 1 || !strings.Contains(open[0].String(), "iCloud") {
		t.Errorf("routes = %v, want the folder alone", open)
	}
}

// Everything else is silence. A hook that wrote a line on every write would fill the execution
// log with something nobody asked for — and none of these is a fault to report.
func TestTheHookIsQuietWhenThereIsNothingToSay(t *testing.T) {
	for name, test := range map[string]struct {
		in     input
		token  string
		icloud bool
	}{
		// Every install starts here: no Worker stood up, and no iCloud folder because the app
		// has not been opened on a phone yet. Neither is a fault, and a line about either would
		// be a complaint about the user not having got to it.
		"nothing has been set up yet": {
			in: fired("task.done", nil),
		},
		"the Worker has a URL but no token": {
			in: fired("task.done", map[string]any{configWorkerURL: "https://viewer.example.workers.dev"}),
		},
		"the document announces a contract this build does not read": {
			in:     input{V: contractVersion + 1, Event: "task.done"},
			token:  "a-throwaway-token",
			icloud: true,
		},
		"nothing fired at all": {
			in:     input{V: contractVersion},
			token:  "a-throwaway-token",
			icloud: true,
		},
	} {
		t.Run(name, func(t *testing.T) {
			t.Setenv(envAuthToken, test.token)
			t.Setenv(envEncryptionKey, "")
			withICloud(t, test.icloud)

			stdout, stderr := capture(t, func() { hook(test.in) })

			if stdout != "" || stderr != "" {
				t.Errorf("stdout %q, stderr %q", stdout, stderr)
			}
		})
	}
}

// Half a route is not a route. A URL with no token would be refused at the Worker's door on
// every send, so it is a state to report as unconfigured rather than to keep retrying.
func TestHalfOfTheCloudflareRouteIsNotARoute(t *testing.T) {
	t.Setenv(envAuthToken, "")

	if _, err := storeFor(fired("task.done", map[string]any{configWorkerURL: "https://viewer.example.workers.dev"})); err == nil {
		t.Error("a URL with no token was taken for a route")
	}

	t.Setenv(envAuthToken, "a-throwaway-token")

	if _, err := storeFor(fired("task.done", map[string]any{configWorkerURL: ""})); err == nil {
		t.Error("a token with no URL was taken for a route")
	}
}

// Both routes carry the same records to two places, so they are not modes to choose between: a
// mac user with an iPhone at home and an Android phone at work wants them in both.
func TestEveryRouteThatIsOpenIsCarriedTo(t *testing.T) {
	t.Setenv(envAuthToken, "a-throwaway-token")
	t.Setenv(envEncryptionKey, base64.RawURLEncoding.EncodeToString(make([]byte, keySize)))
	withICloud(t, true)

	open := routesFor(fired("task.done", map[string]any{configWorkerURL: "https://viewer.example.workers.dev"}))

	named := make([]string, len(open))
	for i, where := range open {
		named[i] = where.String()
	}
	if len(open) != 2 {
		t.Fatalf("routes = %v, want both of them", named)
	}
	if !strings.Contains(strings.Join(named, " "), "iCloud") || !strings.Contains(strings.Join(named, " "), "Cloudflare") {
		t.Errorf("routes = %v", named)
	}
}
