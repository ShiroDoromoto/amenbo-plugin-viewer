package main

// hook is the observation face: amenbo fired an event and moved on.
//
// What an event means to this plugin is narrow and the same for all of them — **the store
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
	// Nowhere to put anything is not a fault: the plugin is installed and enabled, and the user
	// has neither run setup nor opened the app on a phone yet. Saying so on every write would
	// fill the execution log with a line nobody asked for.
	if len(routesFor(in)) == 0 {
		return
	}
	// A send that got nowhere is the opposite — a route is pointed somewhere, and the phone is
	// falling further behind with every write. One line, naming the route and what it said,
	// because the user's question in that state — "why is my phone not updating?" — is answered
	// in `amenbo plugin log viewer` and nowhere else.
	if _, err := carry(in, false); err != nil {
		logf("%s: %s — %v", pluginName, in.Event, err)
	}
}
