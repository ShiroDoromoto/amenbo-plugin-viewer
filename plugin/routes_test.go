package main

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// thePlaceStanding stands the one place up — the three settings the Cloudflare route needs — so
// that what a declaration does can be read on its own.
//
// The declaration is a pointer because **the empty string is an answer**: it is how a form with
// every place ticked off reaches the plugin, and nil is the different fact of Amenbo not sending
// the setting at all.
func thePlaceStanding(t *testing.T, declared *string) input {
	t.Helper()
	t.Setenv(envAuthToken, "a-throwaway-token")
	t.Setenv(envEncryptionKey, throwawayKey)
	settings := map[string]any{configWorkerURL: "https://viewer.example.workers.dev"}
	if declared != nil {
		settings[configRoutes] = *declared
	}
	return fired("task.done", settings)
}

// ticked is a declaration as the settings form sends one.
func ticked(places string) *string { return &places }

// The declaration can only take a place away. What carries is the product of what the user ticked
// and what is actually there, so a place ticked off stops even though everything it needs stands.
func TestTickingAPlaceOffStopsItEvenThoughItStands(t *testing.T) {
	for _, declared := range []struct {
		what    string
		says    *string
		carries []string
	}{
		{"an Amenbo that does not send the setting", nil, []string{"the Cloudflare Worker"}},
		{"the Worker ticked", ticked("cloudflare"), []string{"the Cloudflare Worker"}},
		{"a place this build no longer has", ticked("icloud"), nil},
		{"every one of them ticked off", ticked(""), nil},
	} {
		t.Run(declared.what, func(t *testing.T) {
			in := thePlaceStanding(t, declared.says)

			open := routesFor(in)

			if len(open) != len(declared.carries) {
				t.Fatalf("%d route(s) carrying, want %v", len(open), declared.carries)
			}
			for at, where := range open {
				if where.String() != declared.carries[at] {
					t.Errorf("carrying to %q, want %q", where, declared.carries[at])
				}
			}
		})
	}
}

// The other half of the bound: a place ticked on is still not carried to when it is not there.
// What makes the Worker there is `setup` having stood it up, which no tick can do.
func TestTickingAPlaceOnDoesNotMakeItExist(t *testing.T) {
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")

	open := routesFor(fired("task.done", map[string]any{configRoutes: "cloudflare"}))

	if len(open) != 0 {
		t.Errorf("%d route(s) carrying to places that are not there", len(open))
	}
}

// Ticking none is an answer and it is honoured — and it is not the same fact as nothing being set
// up. A sentence sending someone to `setup` over a choice they made on purpose would have them
// undo it looking for a problem that is not there.
func TestTickingNoneIsNotReadAsNothingBeingSetUp(t *testing.T) {
	in := thePlaceStanding(t, ticked(""))

	err := nothingIsReaching(in)

	if err != errNothingTicked {
		t.Fatalf("%v — want the sentence about the choice, not the one about setting up", err)
	}
	if strings.Contains(err.Error(), "setup") {
		t.Errorf("%v sends the user to undo a choice they made", err)
	}
}

// And with nothing ticked off, nowhere to carry is the ordinary waiting install.
func TestNothingSetUpIsStillTheSentenceAboutSettingUp(t *testing.T) {
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")

	err := nothingIsReaching(fired("task.done", nil))

	if !errors.Is(err, errNoRoute) {
		t.Fatalf("%v — want the sentence about setting up", err)
	}
	if !strings.Contains(err.Error(), "setup") {
		t.Errorf("%v does not say what to do about it", err)
	}
}

// Pairing and cutting a phone off are the Worker's alone, so what they say when there is no
// Worker is about standing one up — and never about a place that holds no tokens.
func TestTheCloudflareOnlyCommandsSayTheCloudflareThing(t *testing.T) {
	_, err := storeFor(fired("", nil))

	if !errors.Is(err, errNoCloudflareRoute) {
		t.Fatalf("%v is not the Cloudflare route's own answer", err)
	}
	if strings.Contains(err.Error(), "iCloud") {
		t.Errorf("%v sends someone pairing a phone to a place this build no longer has", err)
	}
}

// answeredCheck runs the settings screen's question and reads the answer back.
func answeredCheck(t *testing.T, in input) (ok bool, message string) {
	t.Helper()
	stdout, _ := capture(t, func() {
		if err := check(in, nil); err != nil {
			t.Fatal(err)
		}
	})
	var said struct {
		V       int    `json:"v"`
		OK      bool   `json:"ok"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal([]byte(stdout), &said); err != nil {
		t.Fatalf("the answer is not one the form can read: %q", stdout)
	}
	if said.V != contractVersion {
		t.Errorf("the answer is written to contract %d", said.V)
	}
	if len(said.Message) > checkAnswerBytes {
		t.Errorf("the answer runs to %d bytes, and the form shows %d: %q", len(said.Message), checkAnswerBytes, said.Message)
	}
	return said.OK, said.Message
}

// The form is three readonly boxes and a set of ticks, and none of it answers the one question a
// person has: is anything reaching a phone right now. This is that answer.
func TestTheCheckSaysWhereRecordsAreReaching(t *testing.T) {
	ok, said := answeredCheck(t, thePlaceStanding(t, ticked("cloudflare")))

	if !ok {
		t.Errorf("the place standing and ticked read as nothing reaching: %q", said)
	}
	if !strings.Contains(said, "Cloudflare") {
		t.Errorf("%q does not name the place it is reaching", said)
	}
}

// A place ticked and not there is what a person most needs told: the form said nothing was wrong,
// and nothing has been reaching a phone.
func TestTheCheckSaysWhatATickedPlaceIsWaitingOn(t *testing.T) {
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")

	_, said := answeredCheck(t, fired("", map[string]any{configRoutes: "cloudflare"}))

	if !strings.Contains(said, "Waiting on") || !strings.Contains(said, "3.") {
		t.Errorf("%q does not say what the Cloudflare route is waiting on", said)
	}
}

// A place nobody ticked is not mentioned. It was turned off on purpose, and a form that repeats
// every choice back reads as a list of faults.
func TestTheCheckDoesNotReportAPlaceNobodyTicked(t *testing.T) {
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")

	_, said := answeredCheck(t, fired("", map[string]any{configRoutes: ""}))

	if strings.Contains(said, "Cloudflare") {
		t.Errorf("%q reports a place the user ticked off", said)
	}
}

// Nothing ticked is its own answer, and not a wrong setting. Amenbo puts this question at the
// door, so a check that says no over a pause somebody asked for would refuse to enable the plugin
// they were pausing.
func TestTheCheckSaysSoWhenNothingIsTickedWithoutCallingItWrong(t *testing.T) {
	ok, said := answeredCheck(t, thePlaceStanding(t, ticked("")))

	if !ok {
		t.Errorf("a pause the user asked for was refused as a wrong setting: %q", said)
	}
	if !strings.Contains(said, "Where to carry") {
		t.Errorf("%q does not point at the choice that stopped it", said)
	}
}

// A fresh install carries nowhere by definition: `setup` is what stands the route up, and nobody
// runs it from a plugin that will not enable.
func TestTheCheckLetsAFreshInstallBeEnabled(t *testing.T) {
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")

	ok, said := answeredCheck(t, fired("", nil))

	if !ok {
		t.Errorf("a plugin with nothing set up yet could not be enabled: %q", said)
	}
}

// What it can honestly refuse: a place ticked on, standing, and still impossible to carry with.
func TestTheCheckRefusesSettingsThatCannotBeCarriedWith(t *testing.T) {
	t.Setenv(envAuthToken, "a-throwaway-token")
	t.Setenv(envEncryptionKey, "not-a-key")

	ok, said := answeredCheck(t, fired("", map[string]any{
		configRoutes:    "cloudflare",
		configWorkerURL: "https://viewer.example.workers.dev",
	}))

	if ok {
		t.Errorf("settings nothing can be carried with read as usable: %q", said)
	}
}

// The answer is a line in a form, not a report: past the cap it is not read, it is scrolled — and
// a cut that landed inside a character would put a broken rune on the screen.
func TestALongAnswerIsCutToTheLineAndNotThroughACharacter(t *testing.T) {
	said := trimmedToTheLine("わ" + strings.Repeat("あ", checkAnswerBytes))

	if len(said) > checkAnswerBytes {
		t.Errorf("the answer runs to %d bytes", len(said))
	}
	if !strings.HasSuffix(said, "…") {
		t.Errorf("a cut answer does not say it was cut: %q", said)
	}
	for _, letter := range said {
		if letter == '�' {
			t.Errorf("the cut landed inside a character: %q", said)
		}
	}
}

// **Ticking every place off arrives as an empty string, and a setting Amenbo never sent does not
// arrive at all.** Reading the two as one thing turns "none of them" into "all of them" — the
// user ticks everything off, and the plugin carries on carrying everywhere.
func TestEveryPlaceTickedOffIsNotTheSameAsASettingThatNeverCame(t *testing.T) {
	off := routesAllowed(fired("", map[string]any{configRoutes: ""}))
	if len(off) != 0 {
		t.Errorf("ticking every place off allowed %v", off)
	}

	older := routesAllowed(fired("", map[string]any{}))
	for _, name := range routesDeclared {
		if !older[name] {
			t.Errorf("under an Amenbo that does not send the setting, %s went quiet", name)
		}
	}
}

// **Where to get it, and not only what to do with it.** Every sentence that asks for the app to
// be opened on a phone is read by somebody who may not have it, and one that names no place to
// get it sends them off to look with nothing to look for.
func TestEverySentenceThatAsksForTheAppSaysWhereToGetIt(t *testing.T) {
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")

	_, wayIn := capture(t, func() { usage() })

	for what, said := range map[string]string{
		"the way in from here": theWayInFromHere(),
		"the usage":            wayIn,
	} {
		for _, store := range theStores {
			if !strings.Contains(said, store.link) {
				t.Errorf("%s does not say where the app is for %s: %q", what, store.phone, said)
			}
		}
	}
}

// **The line has a budget.** The worst case is the one a fresh install reads — the place ticked
// and not standing — so it is the case that must fit whole.
//
// The App Store address used to ride in this line, on the sentence that asked for the app to be
// opened once so a mac's iCloud folder would appear. That route is gone and so is that sentence:
// what stands the Cloudflare route up is `setup`, and the settings screen puts the app's own page
// on a code rather than spelling an address into 200 bytes.
func TestTheLineAFreshInstallReadsFitsWhole(t *testing.T) {
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")

	_, said := answeredCheck(t, fired("", map[string]any{configRoutes: "cloudflare"}))

	if strings.HasSuffix(said, "…") {
		t.Errorf("the line a fresh install reads is cut at %d bytes: %q", checkAnswerBytes, said)
	}
	// What to do next is a button now, and the number is the half of its name every language
	// spells the same way.
	if !strings.Contains(said, "3.") {
		t.Errorf("%q has lost what to do next", said)
	}
}

// theWorkerThatTookTheRecords is a memory saying the Cloudflare route last wrote to a Worker of
// that build — the only place the settings screen can learn it from.
func theWorkerThatTookTheRecords(t *testing.T, build int64) {
	t.Helper()
	remembering(t)
	if err := writeState(state{Routes: map[string]carried{
		routeCloudflare: {Version: 1, Cursor: 1, Build: build},
	}}); err != nil {
		t.Fatal(err)
	}
}

// **A Worker older than the one this plugin carries is what the line says**, because it is the
// fault a person can neither see nor be told about anywhere else: everything reads as working,
// and only they can put it right — by pressing the button this names.
func TestTheCheckSaysTheWorkerIsBehindAndNamesTheButton(t *testing.T) {
	theWorkerThatTookTheRecords(t, workerBuild-1)

	ok, said := answeredCheck(t, thePlaceStanding(t, ticked("cloudflare")))

	if !strings.Contains(said, "out of date") {
		t.Errorf("%q does not say the server is behind", said)
	}
	if !strings.Contains(said, "3.") {
		t.Errorf("%q does not name the button to press", said)
	}
	// The settings are the ones that stood that Worker up, so nothing here is wrong to fix — and
	// a check that said no would refuse to enable the plugin whose button is the way out.
	if !ok {
		t.Errorf("an old Worker was refused as a wrong setting: %q", said)
	}
}

// The line goes back to where records are reaching once the Worker is the one this plugin
// carries — the sentence is a fault to clear, not a badge the form keeps wearing.
func TestTheCheckSaysNothingAboutAWorkerItIsLevelWith(t *testing.T) {
	theWorkerThatTookTheRecords(t, workerBuild)

	_, said := answeredCheck(t, thePlaceStanding(t, ticked("cloudflare")))

	if strings.Contains(said, "out of date") {
		t.Errorf("%q calls the Worker this plugin carries an old one", said)
	}
	if !strings.Contains(said, "Cloudflare") {
		t.Errorf("%q does not name the place it is reaching", said)
	}
}

// A place ticked off is a pause somebody asked for, and nothing is being sent to that Worker to
// be behind. Sending them to `setup` over it would have them undo the pause looking for a fault.
func TestAPausedRouteIsNotToldItsWorkerIsBehind(t *testing.T) {
	theWorkerThatTookTheRecords(t, workerBuild-1)

	_, said := answeredCheck(t, thePlaceStanding(t, ticked("")))

	if strings.Contains(said, "out of date") {
		t.Errorf("%q reports the Worker behind a place the user ticked off", said)
	}
}
