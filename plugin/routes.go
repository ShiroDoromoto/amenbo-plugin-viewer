package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"
)

// Which places this plugin may carry to.
//
// **The declaration is an upper bound, not a switch.** What the user ticks is the set of places
// this is allowed to use; whether anything reaches one of them is still the place's own answer —
// the iCloud folder exists only once the app has been opened on a phone, and the Cloudflare one
// only once `setup` has stood it up. What carries is the product of the two.
//
// A plain on/off would let the settings say "on" over a place that is not there, and the user
// could not put that right: the folder is made by the OS, on a trigger this plugin cannot pull.
// Read as a bound, the declaration can only take a place away, so the two can never disagree.

// routesDeclared is how many of the places the user may tick, in the order they read them. The
// values are the names the routes answer to, which is also what they are remembered under.
var routesDeclared = []string{routeICloud, routeCloudflare}

// routeStanding is one route and what stands between it and carrying: whether the user's
// declaration reaches it, and whether the place it needs is there.
type routeStanding struct {
	// called is the route in the words the answer names it with — the phrase rather than the
	// sentence, since the same standing is read out on two faces and only one of them is
	// translated.
	called phrase
	// declared says the user's tick reaches this route.
	declared bool
	// open is the route when the place it needs is there, and nil when it is not.
	open route
	// missing is what the place is waiting for, when it is not there. It is a phrase and what
	// fills it in, worded by whoever is about to show it.
	missing said
	// stalled says the place itself is there and the send still cannot use it. A place that is
	// merely not set up yet is not stalled — it is a waiting install.
	stalled bool
	// notHere says this machine has no such place at all, whatever anybody ticks. It is not the
	// same fact as a place that has not appeared yet: one is waited for, and the other never
	// comes.
	notHere bool
}

// said is one sentence that has not been worded yet: the phrase, and the values that go into it.
// A standing is read out on two faces — the settings screen in the user's own language, and the
// execution log in English — so what is carried here is what both of them word from.
type said struct {
	key  phrase
	args []any
}

// carrying says whether records are reaching this place right now.
func (s routeStanding) carrying() bool { return s.declared && s.open != nil }

// routesStanding is where every route stands: what the declaration allows, and what is actually
// there. It is the one reading of that question — the send takes the routes that are carrying,
// and `check` says the same thing in words, so the two cannot drift.
func routesStanding(in input) []routeStanding {
	allowed := routesAllowed(in)
	where := make([]routeStanding, 0, len(routesDeclared))

	there := routeStanding{called: phICloudFolder, declared: allowed[routeICloud]}
	switch folder, err := dropFor(); {
	case err == nil:
		there.open = folder
	case !icloudIsARoadHere():
		// The candidates are the same list on every OS, so this is a place a Windows user can
		// tick. Nothing breaks when they do — it simply never carries — and being told so is the
		// difference between a choice that did nothing and a choice that did nothing visibly.
		there.notHere = true
	default:
		// **Where to get it, not only what to do with it.** This is the one line the settings
		// screen shows about a route nobody has yet, and telling someone to open an app they
		// have never heard of sends them looking for it with nothing to look for. The address
		// is what answers on both faces — the screen has the button beside it, and a terminal
		// has neither.
		//
		// The address rides in brackets rather than after a dash, and what it displaces is
		// "and it appears": the clause already opens with "Waiting on the iCloud folder", so
		// what appears was said, and the line has a budget the address spends most of.
		there.missing = said{key: phOpenTheAppOnce, args: []any{appStoreLink}}
	}
	where = append(where, there)

	worker := routeStanding{called: phCloudflareWorker, declared: allowed[routeCloudflare]}
	switch shop, err := storeFor(in); {
	case err != nil:
		worker.missing = said{key: phStandTheWorkerUp, args: []any{pluginName}}
	default:
		// The key is what the Worker route is allowed to send with, and only it: the folder is
		// this machine's own. A route standing without one is worth saying — the send goes on to
		// the other one, and silence here would read as the Worker being up to date.
		seal, err := newSealer(secret(envEncryptionKey))
		if err != nil {
			// **Two sentences for four errors.** What a reader of the settings screen can do
			// about it is the same either way — run `setup` — and the line has 200 bytes to
			// say it in; how the key was wrong is the execution log's to carry, where `push`
			// reports it whole.
			wrong := phStandingBadKey
			if errors.Is(err, errNoKey) {
				wrong = phStandingWithNoKey
			}
			worker.missing, worker.stalled = said{key: wrong}, true
		} else {
			shop.seal = seal
			worker.open = shop
		}
	}
	where = append(where, worker)

	return where
}

// routesAllowed reads the declaration into the set of routes it reaches.
//
// **The empty answer is "none", and a missing one is "everywhere".** Amenbo fills a setting nobody
// has touched in from the manifest's default, so the key arrives on every send — which is what
// makes the empty string mean something rather than nothing: it is how ticking every place off
// reaches here. A key that is not there at all is a different fact, an Amenbo older than the
// setting, and a plugin must not go quiet under one.
func routesAllowed(in input) map[string]bool {
	declared, said := in.declared(configRoutes)
	if !said {
		allowed := make(map[string]bool, len(routesDeclared))
		for _, name := range routesDeclared {
			allowed[name] = true
		}
		return allowed
	}
	allowed := map[string]bool{}
	for _, name := range strings.Split(declared, ",") {
		if name = strings.TrimSpace(name); name != "" {
			allowed[name] = true
		}
	}
	return allowed
}

// routesFor names every route that is carrying. None is not a failure: a plugin that is installed
// and enabled, with no Worker stood up and no folder yet, is waiting rather than broken — and so
// is one whose every place has been ticked off.
func routesFor(in input) []route {
	var open []route
	for _, where := range routesStanding(in) {
		if where.carrying() {
			open = append(open, where.open)
			continue
		}
		// A place that is ticked, and there, and still cannot be carried to is worth a line: the
		// send goes on to the other one, and silence would read as this one being up to date. A
		// place that is simply not set up yet is not that — it is a waiting install, and saying
		// so on every write would fill the log with a line nobody asked for.
		if where.declared && where.stalled {
			// The execution log, read by whoever is working out why a phone is behind: English,
			// like every other line the observation face leaves.
			logf("%s: nothing is reaching %s — %s", pluginName,
				english.say(where.called), english.say(where.missing.key, where.missing.args...))
		}
	}
	return open
}

// checkAnswerBytes is as long as the settings screen's one line may be. It is a line in a form,
// not a report: past this it is not read, it is scrolled.
const checkAnswerBytes = 200

// check is what the settings screen raises to ask the one question a form full of readonly boxes
// cannot answer: **is anything actually reaching a phone right now?**
//
// The three boxes being filled says only that a Worker was stood up once. The folder being ticked
// says only that it is allowed. What a person wants is the product, and the message is the one
// line that gives it.
//
// **`ok` is not that answer.** Amenbo puts this question at the door: a check that says no is a
// check refusing the settings, and the plugin cannot be enabled. Carrying nowhere is not a wrong
// setting — a fresh install carries nowhere by definition, and the folder it will use appears
// only after the app has been opened on a phone, which nobody can do from a plugin that will not
// enable. Ticking every place off is not a wrong setting either; it is a pause, asked for. So
// `ok` says only what it can honestly say no to: a place that is ticked, and standing, and whose
// settings still cannot be carried with.
//
// **It reads nothing over the network.** The question is about this machine's own two answers —
// what is declared, and what is there — and a check that could hang on a network is one the form
// waits on.
func check(in input, _ []string) error {
	where := routesStanding(in)
	usable := true
	for _, one := range where {
		usable = usable && !(one.declared && one.stalled)
	}
	return json.NewEncoder(out).Encode(map[string]any{
		"v":       contractVersion,
		"ok":      usable,
		"message": whatIsReaching(screen, where),
	})
}

// whatIsReaching is that line: where records are reaching, and — for a place that is ticked and
// not there — what it is waiting for.
//
// A place nobody ticked is not mentioned. It was turned off on purpose, and a form that repeats
// every choice back reads as a list of faults.
func whatIsReaching(words wording, where []routeStanding) string {
	var reaching, waiting, absent []string
	for _, one := range where {
		switch {
		case one.carrying():
			reaching = append(reaching, words.say(one.called))
		case !one.declared:
			// Turned off on purpose, and not mentioned: a form that reads every choice back
			// sounds like a list of faults. Being left out of the line is how it reads as off,
			// which is the one of the three states that needs no words.
		case one.notHere:
			absent = append(absent, words.say(one.called))
		default:
			waiting = append(waiting, words.say(one.called)+" — "+words.say(one.missing.key, one.missing.args...))
		}
	}

	line := words.say(phCarryingTo, inWords(words, reaching))
	if len(reaching) == 0 {
		if len(waiting) == 0 && len(absent) == 0 {
			return words.say(phNothingIsTicked)
		}
		line = words.say(phCarryingNowhere)
	}
	if len(waiting) > 0 {
		// The waiting ones each carry a clause of their own, so they are separated rather than
		// joined into a sentence — an "and" between two dashed clauses reads as one long one.
		line += words.say(phWaitingOn, strings.Join(waiting, "; "))
	}
	if len(absent) > 0 {
		// **Not the same words as waiting.** Waiting is a place that will appear; this is one
		// that will not, so a sentence about what to do next would be a sentence about nothing.
		//
		// One place can be absent and no more — the Cloudflare route is every OS's — so this is
		// written in the singular.
		line += words.say(phNoSuchPlaceHere, inWords(words, absent))
	}
	return trimmedToTheLine(line)
}

// inWords joins names the way a sentence does.
func inWords(words wording, names []string) string {
	switch len(names) {
	case 0:
		return words.say(phNowhere)
	case 1:
		return names[0]
	}
	return strings.Join(names[:len(names)-1], words.say(phComma)) + words.say(phAnd) + names[len(names)-1]
}

// trimmedToTheLine keeps the answer to what the form will show, cutting on a rune so a cut never
// lands inside a character.
func trimmedToTheLine(said string) string {
	if len(said) <= checkAnswerBytes {
		return said
	}
	cut := checkAnswerBytes - len("…")
	for cut > 0 && !utf8.RuneStart(said[cut]) {
		cut--
	}
	return said[:cut] + "…"
}

// nothingIsReaching says why a send had nowhere to go, which is two different facts wearing one
// face: nothing is set up yet, or everything that is set up has been ticked off.
//
// **The second is not a fault**, and a sentence sending someone to `setup` over a choice they
// made on purpose would have them undo it looking for a problem that is not there.
func nothingIsReaching(in input) error {
	for _, where := range routesStanding(in) {
		if where.declared {
			return fmt.Errorf("%w — %s", errNoRoute, theWayInFromHere())
		}
	}
	return errNothingTicked
}

// theWayInFromHere is what to do about having nowhere to carry to, on the machine this is running
// on.
//
// **Only the roads this machine has.** The iCloud folder is a mac's app container and nothing
// else has one, so telling a Windows user to open the app on an iPhone and wait for a folder
// names a road that will never appear for them — and it is the first thing they read, ahead of
// the one road they do have.
func theWayInFromHere() string {
	if icloudIsARoadHere() {
		return fmt.Sprintf("run `%s setup` for the Cloudflare route,"+
			" or open Amenbo Viewer once on a phone for this mac's iCloud folder to appear"+
			" — the app is at %s", pluginName, appStoreLink)
	}
	// **The app is named here too, on the machine that has only the one road.** What is a mac's
	// own is the folder, not the phone: whichever route carries, the thing that reads at the far
	// end is the same app, and a reader told to stand a Worker up still has to get it.
	return fmt.Sprintf("run `%s setup` to stand the Cloudflare route up"+
		" (the other one, the app's iCloud folder, is a mac's own — this machine has no such thing)"+
		" — the app the phone reads with is at %s", pluginName, appStoreLink)
}

// errNothingTicked is every place having been ticked off. The plugin stays enabled and carries
// nowhere, which is what a pause is — and what it leaves behind differs from disabling the plugin.
var errNothingTicked = errors.New(`no place is ticked under "Where to carry", so nothing is being carried — tick one to start again`)
