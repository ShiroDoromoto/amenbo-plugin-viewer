package main

import (
	"encoding/base64"
	"strings"
	"testing"
)

// fired builds the document Amenbo writes when an event fires, with the settings a test wants
// standing on it.
func fired(event string, settings map[string]any) input {
	return input{V: contractVersion, Event: event, ID: 42, Actor: "ai", Config: settings}
}

// A send that got nowhere is the state the user most needs written down: a route IS open, so the
// phone falls further behind with every write.
func TestTheHookSaysWhatStoppedTheSend(t *testing.T) {
	t.Setenv(envAuthToken, "a-throwaway-token")
	t.Setenv(envEncryptionKey, "")

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

// Every route this plugin has now ends somewhere its owner merely rents, so a send with no key
// is a send with nowhere to go. There was one that needed none — the app's own iCloud folder, on
// the user's own machine — and it went with the route.
func TestARouteWithNoKeyCarriesNothing(t *testing.T) {
	t.Setenv(envAuthToken, "a-throwaway-token")
	t.Setenv(envEncryptionKey, "")

	open := routesFor(fired("task.done", map[string]any{configWorkerURL: "https://viewer.example.workers.dev"}))

	if len(open) != 0 {
		t.Errorf("routes = %v, want none — the key is what the records leave in", open)
	}
}

// Everything else is silence. A hook that wrote a line on every write would fill the execution
// log with something nobody asked for — and none of these is a fault to report.
func TestTheHookIsQuietWhenThereIsNothingToSay(t *testing.T) {
	for name, test := range map[string]struct {
		in    input
		token string
	}{
		// Every install starts here: no Worker stood up. That is not a fault, and a line about
		// it would be a complaint about the user not having got to it.
		"nothing has been set up yet": {
			in: fired("task.done", nil),
		},
		"the Worker has a URL but no token": {
			in: fired("task.done", map[string]any{configWorkerURL: "https://viewer.example.workers.dev"}),
		},
		"the document announces a contract this build does not read": {
			in:    input{V: contractVersion + 1, Event: "task.done"},
			token: "a-throwaway-token",
		},
		"nothing fired at all": {
			in:    input{V: contractVersion},
			token: "a-throwaway-token",
		},
	} {
		t.Run(name, func(t *testing.T) {
			t.Setenv(envAuthToken, test.token)
			t.Setenv(envEncryptionKey, "")

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

// A route that is set up whole is one the records reach. The shape still holds a list because
// there was more than one and could be again — what a route has to answer for is where it ends,
// not how many of them there are.
func TestEveryRouteThatIsOpenIsCarriedTo(t *testing.T) {
	t.Setenv(envAuthToken, "a-throwaway-token")
	t.Setenv(envEncryptionKey, base64.RawURLEncoding.EncodeToString(make([]byte, keySize)))

	open := routesFor(fired("task.done", map[string]any{configWorkerURL: "https://viewer.example.workers.dev"}))

	named := make([]string, len(open))
	for i, where := range open {
		named[i] = where.String()
	}
	if len(open) != 1 || !strings.Contains(named[0], "Cloudflare") {
		t.Fatalf("routes = %v, want the Worker", named)
	}
}
