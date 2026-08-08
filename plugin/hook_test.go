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

// A route the user has pointed somewhere, and nothing arriving at the other end, is the one
// state worth a line: their question is "why is my phone not updating?", and the execution log
// is where it gets answered.
func TestTheHookSaysWhyNothingIsArrivingOnceARouteIsConfigured(t *testing.T) {
	for name, test := range map[string]struct {
		settings map[string]any
		token    string
		says     string
	}{
		"the iCloud folder": {
			settings: map[string]any{configICloudFolder: "/Users/x/Library/Mobile Documents/…"},
			says:     "iCloud Drive folder",
		},
		"the Cloudflare Worker": {
			settings: map[string]any{configWorkerURL: "https://viewer.example.workers.dev"},
			token:    "t0ken",
			says:     "Cloudflare Worker",
		},
		"both at once": {
			settings: map[string]any{
				configICloudFolder: "/Users/x/Library/Mobile Documents/…",
				configWorkerURL:    "https://viewer.example.workers.dev",
			},
			token: "t0ken",
			says:  "and",
		},
	} {
		t.Run(name, func(t *testing.T) {
			t.Setenv(envAuthToken, test.token)

			stdout, stderr := capture(t, func() { hook(fired("task.done", test.settings)) })

			if stdout != "" {
				t.Errorf("a hook's stdout is not a return value and nothing belongs on it: %q", stdout)
			}
			if !strings.Contains(stderr, test.says) {
				t.Errorf("the line does not name the route: %q", stderr)
			}
			if !strings.Contains(stderr, "not built yet") {
				t.Errorf("the line has to say why nothing arrived: %q", stderr)
			}
		})
	}
}

// Everything else is silence. A hook that wrote a line on every write would fill the execution
// log with something nobody asked for — and none of these is a fault to report.
func TestTheHookIsQuietWhenThereIsNothingToSay(t *testing.T) {
	for name, test := range map[string]struct {
		in    input
		token string
	}{
		"no route is pointed anywhere": {
			in: fired("task.done", nil),
		},
		"the Worker has a URL but no token": {
			in: fired("task.done", map[string]any{configWorkerURL: "https://viewer.example.workers.dev"}),
		},
		"the document announces a contract this build does not read": {
			in:    input{V: contractVersion + 1, Event: "task.done", Config: map[string]any{configICloudFolder: "/tmp/x"}},
			token: "t0ken",
		},
		"nothing fired at all": {
			in:    input{V: contractVersion, Config: map[string]any{configICloudFolder: "/tmp/x"}},
			token: "t0ken",
		},
	} {
		t.Run(name, func(t *testing.T) {
			t.Setenv(envAuthToken, test.token)

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

	if live := routesFor(fired("task.done", map[string]any{configWorkerURL: "https://viewer.example.workers.dev"})); len(live) != 0 {
		t.Errorf("routes = %v", live)
	}

	t.Setenv(envAuthToken, "t0ken")

	if live := routesFor(fired("task.done", map[string]any{configWorkerURL: ""})); len(live) != 0 {
		t.Errorf("routes = %v", live)
	}
}

// Both routes carry the same bytes to two places, so they are not modes to choose between: a
// mac user with an iPhone at home and an Android phone at work wants the snapshot in both.
func TestBothRoutesCanBeLiveAtOnce(t *testing.T) {
	t.Setenv(envAuthToken, "t0ken")

	live := routesFor(fired("task.done", map[string]any{
		configICloudFolder: "/Users/x/Library/Mobile Documents/…",
		configWorkerURL:    "https://viewer.example.workers.dev",
	}))

	if len(live) != 2 {
		t.Errorf("routes = %v", live)
	}
}
