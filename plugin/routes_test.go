package main

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// bothPlacesStanding stands both places up — a folder a test may write in, and the three settings
// the Cloudflare route needs — so that what a declaration does can be read on its own.
//
// The declaration is a pointer because **the empty string is an answer**: it is how a form with
// every place ticked off reaches the plugin, and nil is the different fact of Amenbo not sending
// the setting at all.
func bothPlacesStanding(t *testing.T, declared *string) input {
	t.Helper()
	withICloud(t, true)
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
		{"an Amenbo that does not send the setting", nil, []string{"the iCloud Drive folder", "the Cloudflare Worker"}},
		{"both ticked", ticked("icloud,cloudflare"), []string{"the iCloud Drive folder", "the Cloudflare Worker"}},
		{"only the folder", ticked("icloud"), []string{"the iCloud Drive folder"}},
		{"only the Worker", ticked("cloudflare"), []string{"the Cloudflare Worker"}},
		{"every one of them ticked off", ticked(""), nil},
	} {
		t.Run(declared.what, func(t *testing.T) {
			in := bothPlacesStanding(t, declared.says)

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
// The folder is made by the OS on a trigger this plugin cannot pull, so a tick that could turn it
// on would be a setting the user cannot make true.
func TestTickingAPlaceOnDoesNotMakeItExist(t *testing.T) {
	withICloud(t, false)
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")

	open := routesFor(fired("task.done", map[string]any{configRoutes: "icloud,cloudflare"}))

	if len(open) != 0 {
		t.Errorf("%d route(s) carrying to places that are not there", len(open))
	}
}

// Ticking none is an answer and it is honoured — and it is not the same fact as nothing being set
// up. A sentence sending someone to `setup` over a choice they made on purpose would have them
// undo it looking for a problem that is not there.
func TestTickingNoneIsNotReadAsNothingBeingSetUp(t *testing.T) {
	in := bothPlacesStanding(t, ticked(""))

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
	withICloud(t, false)
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

// **Only the roads this machine has.** The iCloud folder is a mac's app container and nothing
// else has one, so a line telling a Windows user to open the app on a phone and wait for a folder
// names a road that will never appear for them — ahead of the one road they do have.
func TestTheWayInNamesOnlyTheRoadsThisMachineHas(t *testing.T) {
	for _, machine := range []struct {
		what string
		mac  bool
	}{{"a mac", true}, {"anything else", false}} {
		t.Run(machine.what, func(t *testing.T) {
			was := icloudIsARoadHere
			icloudIsARoadHere = func() bool { return machine.mac }
			t.Cleanup(func() { icloudIsARoadHere = was })

			said := theWayInFromHere()

			if !strings.Contains(said, "setup") {
				t.Errorf("%q does not name the road every machine has", said)
			}
			if waits := strings.Contains(said, "open Amenbo Viewer"); waits != machine.mac {
				t.Errorf("%q tells a machine to wait for a folder it %v have", said, map[bool]string{true: "does", false: "does not"}[machine.mac])
			}
		})
	}
}

// The same on the page: a paragraph about a mac's folder, printed first on a machine that has no
// such thing, is a paragraph about somebody else's computer.
func TestTheUsageNamesOnlyTheRoutesThisMachineHas(t *testing.T) {
	was := icloudIsARoadHere
	icloudIsARoadHere = func() bool { return false }
	t.Cleanup(func() { icloudIsARoadHere = was })

	_, page := capture(t, usage)

	if strings.Contains(page, "Two routes carry") {
		t.Error("a machine with one route is told it has two")
	}
	if !strings.Contains(page, "Cloudflare Worker") {
		t.Error("the page does not name the route this machine does have")
	}
	if !strings.Contains(page, "mac") {
		t.Error("the page never says why there is only one — a reader who has heard of the other is left guessing")
	}
}

// Pairing and cutting a phone off are the Worker's alone, so what they say when there is no
// Worker is about that one route — on every OS, and never about a folder that holds no tokens.
func TestTheCloudflareOnlyCommandsSayTheCloudflareThing(t *testing.T) {
	for _, mac := range []bool{true, false} {
		was := icloudIsARoadHere
		icloudIsARoadHere = func() bool { return mac }

		_, err := storeFor(fired("", nil))

		icloudIsARoadHere = was
		if !errors.Is(err, errNoCloudflareRoute) {
			t.Fatalf("%v is not the Cloudflare route's own answer", err)
		}
		if strings.Contains(err.Error(), "iCloud") {
			t.Errorf("%v sends someone pairing a phone to a folder that holds no tokens", err)
		}
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
	ok, said := answeredCheck(t, bothPlacesStanding(t, ticked("icloud,cloudflare")))

	if !ok {
		t.Errorf("both places standing and ticked read as nothing reaching: %q", said)
	}
	if !strings.Contains(said, "iCloud") || !strings.Contains(said, "Cloudflare") {
		t.Errorf("%q does not name both places", said)
	}
}

// A place ticked and not there is what a person most needs told: the form said nothing was wrong,
// and nothing has been reaching a phone.
func TestTheCheckSaysWhatATickedPlaceIsWaitingOn(t *testing.T) {
	withICloud(t, true)
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")

	ok, said := answeredCheck(t, fired("", map[string]any{configRoutes: "icloud,cloudflare"}))

	if !ok {
		t.Errorf("the folder is standing and ticked, so something is reaching: %q", said)
	}
	if !strings.Contains(said, "Waiting on") || !strings.Contains(said, "setup") {
		t.Errorf("%q does not say what the Cloudflare route is waiting on", said)
	}
}

// A place nobody ticked is not mentioned. It was turned off on purpose, and a form that repeats
// every choice back reads as a list of faults.
func TestTheCheckDoesNotReportAPlaceNobodyTicked(t *testing.T) {
	withICloud(t, true)
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")

	_, said := answeredCheck(t, fired("", map[string]any{configRoutes: "icloud"}))

	if strings.Contains(said, "Cloudflare") {
		t.Errorf("%q reports a place the user ticked off", said)
	}
}

// Nothing ticked is its own answer, and not a wrong setting. Amenbo puts this question at the
// door, so a check that says no over a pause somebody asked for would refuse to enable the plugin
// they were pausing.
func TestTheCheckSaysSoWhenNothingIsTickedWithoutCallingItWrong(t *testing.T) {
	ok, said := answeredCheck(t, bothPlacesStanding(t, ticked("")))

	if !ok {
		t.Errorf("a pause the user asked for was refused as a wrong setting: %q", said)
	}
	if !strings.Contains(said, "Where to carry") {
		t.Errorf("%q does not point at the choice that stopped it", said)
	}
}

// A fresh install carries nowhere by definition, and the folder it will use appears only after
// the app has been opened on a phone — which nobody can do from a plugin that will not enable.
func TestTheCheckLetsAFreshInstallBeEnabled(t *testing.T) {
	withICloud(t, false)
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")

	ok, said := answeredCheck(t, fired("", nil))

	if !ok {
		t.Errorf("a plugin with nothing set up yet could not be enabled: %q", said)
	}
}

// What it can honestly refuse: a place ticked on, standing, and still impossible to carry with.
func TestTheCheckRefusesSettingsThatCannotBeCarriedWith(t *testing.T) {
	withICloud(t, false)
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

// **Three states, and a line that tells them apart.** A place that is carrying, a place that is
// ticked and waiting, and a place this machine does not have at all — the third is the one that
// used to wear the second's words, telling a Windows user to open the app on a phone and wait for
// a folder that never comes.
func TestTheCheckTellsAPlaceThatIsNotHereFromOneThatIsWaiting(t *testing.T) {
	was := icloudIsARoadHere
	icloudIsARoadHere = func() bool { return false }
	t.Cleanup(func() { icloudIsARoadHere = was })
	withICloud(t, false)
	t.Setenv(envAuthToken, "a-throwaway-token")
	t.Setenv(envEncryptionKey, throwawayKey)

	_, said := answeredCheck(t, fired("", map[string]any{
		configRoutes:    "icloud,cloudflare",
		configWorkerURL: "https://viewer.example.workers.dev",
	}))

	if strings.Contains(said, "Waiting on the iCloud") {
		t.Errorf("%q tells this machine to wait for a place it will never have", said)
	}
	if !strings.Contains(said, "no such place") {
		t.Errorf("%q does not say the folder is not on this machine at all", said)
	}
	if strings.Contains(said, "Carrying to the iCloud folder") {
		t.Errorf("%q says a place that is not here is carrying", said)
	}
}

// And a place nobody ticked stays out of the line, whichever machine this is — that absence is
// how "turned off" reads, and it is the one of the three states that needs no words.
func TestAPlaceThatIsNotHereAndNotTickedIsStillNotMentioned(t *testing.T) {
	was := icloudIsARoadHere
	icloudIsARoadHere = func() bool { return false }
	t.Cleanup(func() { icloudIsARoadHere = was })
	withICloud(t, false)
	t.Setenv(envAuthToken, "a-throwaway-token")
	t.Setenv(envEncryptionKey, throwawayKey)

	_, said := answeredCheck(t, fired("", map[string]any{
		configRoutes:    "cloudflare",
		configWorkerURL: "https://viewer.example.workers.dev",
	}))

	if strings.Contains(said, "iCloud") {
		t.Errorf("%q reports a place the user ticked off as though it were a fault", said)
	}
}

// On a mac the folder is a place that will appear, so it keeps the words that say how.
func TestOnAMacTheFolderIsStillSomethingToWaitFor(t *testing.T) {
	was := icloudIsARoadHere
	icloudIsARoadHere = func() bool { return true }
	t.Cleanup(func() { icloudIsARoadHere = was })
	withICloud(t, false)
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")

	_, said := answeredCheck(t, fired("", map[string]any{configRoutes: "icloud"}))

	if !strings.Contains(said, "open Amenbo Viewer") {
		t.Errorf("%q does not say how the folder appears", said)
	}
	if strings.Contains(said, "no such place") {
		t.Errorf("%q writes a mac's own folder off", said)
	}
}
