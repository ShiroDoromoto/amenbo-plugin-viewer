package main

// hook is the observation face: amenbo fired an event and moved on.
//
// What an event means to this plugin is narrow and the same for all of them — **the project
// changed, so what the phone holds is now behind.** It is a trigger, never an audience: the
// records carry the backlog itself, so which one moved and who moved it are of no interest
// here. That is why every event amenbo fires is subscribed to and none is treated specially.
//
// It never fails. Nobody is waiting on the answer, and a non-zero exit would only put a warning
// in amenbo's execution log for a run that had nothing to say.
func hook(in input) {
	if in.V != contractVersion || in.Event == "" {
		return
	}
	// The iCloud route is a setting the user filled in and nothing arriving at the other end.
	// That is worth one line, because their question in that state — "why is my phone not
	// updating?" — is answered in `amenbo plugin log viewer` and nowhere else.
	if in.setting(configICloudFolder) != "" {
		logf("%s: %s — the iCloud Drive folder is configured, but writing to it is not built yet.", pluginName, in.Event)
	}
	// No Cloudflare route is not a fault: the plugin is installed and enabled, and the user has
	// simply not run setup. Saying so on every write would fill the execution log with a line
	// nobody asked for.
	if _, err := storeFor(in); err != nil {
		return
	}
	// A send that got nowhere is the opposite — the route is pointed somewhere, and the phone is
	// falling further behind with every write. One line, with what the far end said.
	if _, err := carry(in, false); err != nil {
		logf("%s: %s — nothing reached the Cloudflare Worker: %v", pluginName, in.Event, err)
	}
}
