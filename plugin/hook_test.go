package main

import (
	"strings"
	"testing"
)

// fired builds the document amenbo writes when an event fires, with the settings a test wants
// standing on it.
func fired(event string, settings map[string]any) input {
	return input{V: contractVersion, Event: event, ID: 42, Actor: "ai", Config: settings}
}

// withICloud answers for the mac route, whose real switch is a directory no test may create.
func withICloud(t *testing.T, live bool) {
	t.Helper()
	was := icloudRouteIsLive
	icloudRouteIsLive = func() bool { return live }
	t.Cleanup(func() { icloudRouteIsLive = was })
}

// The iCloud folder is there and nothing is arriving at the other end. That is the one state
// worth a line: the user's question is "why is my phone not updating?", and the execution log is
// where it gets answered.
func TestTheHookSaysWhyNothingIsReachingTheICloudFolder(t *testing.T) {
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")
	withICloud(t, true)

	stdout, stderr := capture(t, func() {
		hook(fired("task.done", nil))
	})

	if stdout != "" {
		t.Errorf("a hook's stdout is not a return value and nothing belongs on it: %q", stdout)
	}
	if !strings.Contains(stderr, "iCloud Drive folder") || !strings.Contains(stderr, "not built yet") {
		t.Errorf("the line does not say what is not arriving, or why: %q", stderr)
	}
}

// A send that got nowhere is the state the user most needs written down: the route IS pointed
// somewhere, so the phone falls further behind with every write.
func TestTheHookSaysWhyTheSendToTheWorkerFailed(t *testing.T) {
	t.Setenv(envAuthToken, "a-throwaway-token")
	t.Setenv(envEncryptionKey, "")
	withICloud(t, false)

	stdout, stderr := capture(t, func() {
		hook(fired("task.done", map[string]any{configWorkerURL: "https://viewer.example.workers.dev"}))
	})

	if stdout != "" {
		t.Errorf("a hook's stdout is not a return value and nothing belongs on it: %q", stdout)
	}
	if !strings.Contains(stderr, "Cloudflare Worker") || !strings.Contains(stderr, "encryption key") {
		t.Errorf("the line does not say what stopped the send: %q", stderr)
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
func TestBothRoutesAreReportedOnIndependently(t *testing.T) {
	t.Setenv(envAuthToken, "a-throwaway-token")
	t.Setenv(envEncryptionKey, "")
	withICloud(t, true)

	_, stderr := capture(t, func() {
		hook(fired("task.done", map[string]any{configWorkerURL: "https://viewer.example.workers.dev"}))
	})

	if !strings.Contains(stderr, "iCloud Drive folder") {
		t.Errorf("the iCloud route went unmentioned: %q", stderr)
	}
	if !strings.Contains(stderr, "Cloudflare Worker") {
		t.Errorf("the Cloudflare route went unmentioned: %q", stderr)
	}
}
