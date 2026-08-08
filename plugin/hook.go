package main

import (
	"os"
	"strings"
)

// hook is the observation face: amenbo fired an event and moved on.
//
// What an event means to this plugin is narrow and the same for all of them — **the project
// changed, so what the phone holds is now behind.** It is a trigger, never an audience: the
// snapshot carries the backlog itself, so which record moved and who moved it are of no
// interest here. That is why every event amenbo fires is subscribed to and none is treated
// specially.
//
// It never fails. Nobody is waiting on the answer, and a non-zero exit would only put a warning
// in amenbo's execution log for a run that had nothing to say.
func hook(in input) {
	if in.V != contractVersion || in.Event == "" {
		return
	}
	// No route configured is not a fault: the plugin is installed and enabled, and the user has
	// simply not pointed it anywhere yet. Saying so on every write would fill the execution log
	// with a line nobody asked for.
	live := routesFor(in)
	if len(live) == 0 {
		return
	}
	// A route IS pointed somewhere, and nothing is arriving at the other end. That is worth one
	// line, because the user's question in that state — "why is my phone not updating?" — is
	// answered in `amenbo plugin log viewer` and nowhere else.
	logf("%s: %s — %s is configured, but the send is not built yet (it waits on the contract in spec/).",
		pluginName, in.Event, strings.Join(live, " and "))
}

// routesFor names the routes the user has actually pointed somewhere. Both may be live at once:
// they are two places to put the same bytes, not two modes to choose between, and a mac user
// with a phone in the family and an Android one at work wants both.
//
// The setting is the switch. There is no on/off of its own to disagree with it — a folder that
// is filled in is a route that is on, and clearing it is how it goes off.
func routesFor(in input) []string {
	var live []string
	if in.setting(configICloudFolder) != "" {
		live = append(live, "the iCloud Drive folder")
	}
	// The Cloudflare route needs both halves: where to put it, and what lets it in. Half of a
	// route is not a route — a URL with no token would fail at the door on every send, which is
	// a state to report as unconfigured rather than to keep retrying.
	if in.setting(configWorkerURL) != "" && os.Getenv(envAuthToken) != "" {
		live = append(live, "the Cloudflare Worker")
	}
	return live
}
