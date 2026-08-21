package main

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strings"
	"testing"
)

// The manifest as this test asks about it — the fields that have to agree with the code and the
// build beside it, not the whole schema `amenbo plugin validate` checks (the Makefile runs that).
// What no test here can see is whether the release it quotes is the newest one; that is the
// release procedure's.
type manifest struct {
	Name     string           `json:"name"`
	Repo     string           `json:"repo"`
	OS       []string         `json:"os"`
	Scope    string           `json:"scope"`
	Assets   map[string]asset `json:"assets"`
	Events   []string         `json:"events"`
	Config   []field          `json:"config"`
	Settings struct {
		Check   string   `json:"check"`
		Actions []action `json:"actions"`
	} `json:"settings"`
	Agent struct {
		Commands []struct {
			Cmd  string `json:"cmd"`
			Does string `json:"does"`
		} `json:"commands"`
	} `json:"agent"`
}

type field struct {
	Key      string   `json:"key"`
	Label    string   `json:"label"`
	Secret   bool     `json:"secret"`
	Readonly bool     `json:"readonly"`
	Type     string   `json:"type"`
	Options  []option `json:"options"`
	Default  string   `json:"default"`
}

// option is one of the candidates a setting offers. The value is what reaches the plugin, so it
// is the half that has to agree with the code.
type option struct {
	Value string `json:"value"`
	Label string `json:"label"`
}

// action is one button the settings screen offers, and what it asks for before pressing it. The
// asked fields are shaped like the saved ones, which is the point of the difference: the same
// declaration, handed over for one run instead of written down.
type action struct {
	Cmd   string  `json:"cmd"`
	Label string  `json:"label"`
	Ask   []field `json:"ask"`
}

type asset struct {
	URL      string `json:"url"`
	Checksum string `json:"checksum"`
}

func read(t *testing.T) manifest {
	t.Helper()
	raw, err := os.ReadFile("dev/manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	var m manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

// platforms reads the one list a release bakes from, the Makefile's PLATFORMS, rather than
// keeping a second copy of it here. A platform is added in one place, and what these tests then
// catch is the manifest that did not follow it.
func platforms(t *testing.T) []string {
	t.Helper()
	raw, err := os.ReadFile("Makefile")
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(raw), "\n") {
		if rest, found := strings.CutPrefix(line, "PLATFORMS :="); found {
			return strings.Fields(rest)
		}
	}
	t.Fatal("the Makefile no longer declares PLATFORMS — these tests read the platform list from it")
	return nil
}

// setting is the declared field under key.
func setting(t *testing.T, key string) field {
	t.Helper()
	for _, declared := range read(t).Config {
		if declared.Key == key {
			return declared
		}
	}
	t.Fatalf("no setting %q is declared", key)
	return field{}
}

// The name decides what Amenbo runs, what directory it is laid down in, and the word a user
// types. One spelling on both sides, or what is written under it is not found again.
func TestTheManifestAndTheCodeAgreeOnTheName(t *testing.T) {
	if name := read(t).Name; name != pluginName {
		t.Errorf("the manifest says %q, the code says %q", name, pluginName)
	}
}

// nothingOpens holds the ways a run reaches the machine's screen, for as long as the test lasts.
//
// **Walking the manifest means running the commands on it**, and two of them are a screen and
// nothing else: `token` opens Cloudflare's token screen and ends there, and `app` draws a code
// and ends there. Held like this, the suite still sees each command dispatched, and the person
// running it gets neither a browser window nor an image viewer in front of whatever they were
// doing — nor, since the drawing is held too, the run that outlives this one and would be the
// test binary handed a directory to sleep over.
func nothingOpens(t *testing.T) {
	t.Helper()
	wasOpen, wasScreen, wasShown := openInTheSystem, thereIsAScreen, present
	openInTheSystem, thereIsAScreen = opensFine, onAScreen
	present = func([]byte, bool, bool) (string, string, error) { return "image", "", nil }
	t.Cleanup(func() { openInTheSystem, thereIsAScreen, present = wasOpen, wasScreen, wasShown })
}

// **Every command the manifest advertises must be dispatched.** The manifest is what an AI
// reads to learn this plugin's command face, so one the binary does not know is a line that
// sends a caller to a usage error.
func TestEveryAdvertisedCommandIsDispatched(t *testing.T) {
	commands := read(t).Agent.Commands

	if len(commands) == 0 {
		t.Fatal("the manifest advertises no command at all")
	}
	nothingOpens(t)
	for _, command := range commands {
		t.Run(command.Cmd, func(t *testing.T) {
			var code int
			capture(t, func() { code = run(input{}, strings.Fields(command.Cmd)) })

			if code == 2 {
				t.Errorf("%q is advertised but not dispatched", command.Cmd)
			}
			if command.Does == "" {
				t.Errorf("%q says nothing about what it does", command.Cmd)
			}
		})
	}
}

// **A button the settings screen offers has to be a command the binary knows**, the same way an
// advertised one does — and it is the harder half to notice, since nobody types it: a user who
// only ever opens the settings screen would press it and be told the plugin does not know the
// word its own manifest put on the button.
func TestEveryButtonTheSettingsScreenOffersIsDispatched(t *testing.T) {
	actions := read(t).Settings.Actions

	if len(actions) == 0 {
		t.Fatal("the settings screen offers nothing to press, so setup is still terminal-only")
	}
	nothingOpens(t)
	for _, offered := range actions {
		t.Run(offered.Cmd, func(t *testing.T) {
			var code int
			capture(t, func() { code = run(input{}, strings.Fields(offered.Cmd)) })

			if code == 2 {
				t.Errorf("%q is on a button but not dispatched", offered.Cmd)
			}
			if offered.Label == "" {
				t.Errorf("%q is offered on a button with nothing written on it", offered.Cmd)
			}
		})
	}
}

// The API token reaches the run under the name its declared key becomes, the way a secret setting
// does — one spelling on both sides, or the button hands the token over into a variable nothing
// reads and `setup` goes looking for a terminal that a settings screen does not have.
func TestTheAskedTokenReachesTheCodeUnderTheNameItsKeyBecomes(t *testing.T) {
	asked := whatIsAskedFor(t, "setup")

	if len(asked) != 1 || asked[0].Key != askAPIToken {
		t.Fatalf("setup asks for %v, and the code reads %q", asked, askAPIToken)
	}
	if !asked[0].Secret {
		t.Error("the API token is not declared secret, so the screen would show it as it is typed")
	}
	if asked[0].Label == "" {
		t.Error("the box has no label, so nobody knows what to paste into it")
	}
	if want := "AMENBO_ASK_" + strings.ToUpper(asked[0].Key); want != envAskAPIToken {
		t.Errorf("the answer reaches the plugin as %q, and it is read from %q", want, envAskAPIToken)
	}
}

// The phone's name reaches the run under the name its declared key becomes, the same way the API
// token does — and unlike it, the box is open: what is typed there is the name the person will be
// looking for when they cut this phone off, so hiding it hides the one thing to remember.
func TestTheAskedLabelReachesTheCodeUnderTheNameItsKeyBecomes(t *testing.T) {
	asked := whatIsAskedFor(t, "qr")

	if len(asked) != 1 || asked[0].Key != askLabel {
		t.Fatalf("qr asks for %v, and the code reads %q", asked, askLabel)
	}
	if asked[0].Secret {
		t.Error("the phone's name is declared secret, so nobody could read back what they had typed")
	}
	if asked[0].Label == "" {
		t.Error("the box has no label, so nobody knows what to type into it")
	}
	if want := "AMENBO_ASK_" + strings.ToUpper(asked[0].Key); want != envAskLabel {
		t.Errorf("the answer reaches the plugin as %q, and it is read from %q", want, envAskLabel)
	}
}

// **What is asked for is not one of the saved settings.** The whole worth of asking is that the
// answer is used once and kept nowhere, so a key that collided with a declared setting would put
// a Cloudflare API token — the one credential here that can build in someone's account — into the
// three values `setup` writes back and leaves behind.
func TestWhatTheButtonsAskForIsKeptNowhere(t *testing.T) {
	declared := read(t).Config

	for _, offered := range read(t).Settings.Actions {
		for _, asked := range offered.Ask {
			for _, saved := range declared {
				if asked.Key == saved.Key {
					t.Errorf("%q is asked for at the %q button and saved as a setting", asked.Key, offered.Cmd)
				}
			}
		}
	}
}

// whatIsAskedFor is the boxes the settings screen puts up before it runs one of its buttons.
func whatIsAskedFor(t *testing.T, cmd string) []field {
	t.Helper()
	for _, offered := range read(t).Settings.Actions {
		if offered.Cmd == cmd {
			return offered.Ask
		}
	}
	t.Fatalf("the settings screen offers no button that runs %s", cmd)
	return nil
}

// The setting the code reads off the stdin document is declared, and declared open: a secret
// never appears there, so marking it would put it in the environment and leave the read looking
// at an empty config.
func TestTheOpenSettingTheCodeReadsIsDeclaredOpen(t *testing.T) {
	declared := setting(t, configWorkerURL)

	if declared.Secret {
		t.Errorf("%s is read off the stdin document, which never carries a secret", configWorkerURL)
	}
	if declared.Label == "" {
		t.Errorf("%s has nothing for the user to read", configWorkerURL)
	}
}

// **The three the Cloudflare route needs are not the user's to type.** `setup` generates all of
// them and writes them back through `plugin config set`, so a box offered for any one of them is
// a box whose only use is to break a working route. Declaring them readonly is what takes the box
// and the clear button off the form; the write-back path is untouched by it.
//
// **`routes` is the one answer a person is asked for**, so it is the one that must not be
// readonly — a bound nobody can move is not a bound.
func TestOnlyTheChoiceIsTheUsersToMake(t *testing.T) {
	declared := read(t).Config
	if len(declared) == 0 {
		t.Fatal("the manifest declares no settings at all")
	}
	for _, one := range declared {
		if one.Key == configRoutes {
			if one.Readonly {
				t.Errorf("%s is the one thing the user chooses, and the form offers no way to change it", one.Key)
			}
			continue
		}
		if !one.Readonly {
			t.Errorf("%s is offered as a box to type in, and setup is what writes it", one.Key)
		}
	}
}

// The mac route is not a setting, and declaring one would put a folder picker back in front of a
// user who has nothing to choose: the app's container is the one place both ends already know
// how to find, and the directory being there is the switch.
func TestTheMacRouteIsNotOfferedAsASetting(t *testing.T) {
	for _, declared := range read(t).Config {
		if declared.Key == "icloud_folder" {
			t.Error("the manifest still asks the user where in iCloud Drive to write")
		}
	}
}

// The token and the key are secret, which is what puts them in the environment rather than on
// stdin. The variable's name follows from the key mechanically, so the one the code reads has
// to be the one the declared key becomes — not a second spelling free to drift from it.
func TestTheSecretsReachTheCodeUnderTheNamesTheirKeysBecome(t *testing.T) {
	for env, key := range map[string]string{
		envAuthToken:     "auth_token",
		envEncryptionKey: "encryption_key",
	} {
		declared := setting(t, key)

		if !declared.Secret {
			t.Errorf("%s is not declared secret, so it would arrive on stdin in the clear", key)
		}
		if want := "AMENBO_CONFIG_" + strings.ToUpper(key); want != env {
			t.Errorf("the setting reaches the plugin as %q, and it is read from %q", want, env)
		}
	}
}

// The plugin runs wherever Amenbo does. The iCloud route is mac-only, but the Cloudflare one is
// not, so dropping an OS here would strip a user of the route that was theirs.
func TestItRunsOnEveryOSAmenboDoes(t *testing.T) {
	declared := strings.Join(read(t).OS, " ")

	for _, system := range []string{"macos", "windows", "linux"} {
		if !strings.Contains(declared, system) {
			t.Errorf("%s is missing from %q", system, declared)
		}
	}
}

// Any write leaves the phone behind, so there is no event that can be left out as uninteresting.
// A subscription narrower than what Amenbo fires would be a window the viewer silently misses.
//
// `store.changed` is the one that cannot be dropped for being redundant: it fires on every write,
// and the other eleven name things that happen to a record rather than the record being edited —
// so a note or a title changed on its own reaches the phone through this event and no other.
func TestItSubscribesToEveryEventBecauseEveryWriteLeavesThePhoneBehind(t *testing.T) {
	events := read(t).Events

	for _, event := range []string{
		"task.created", "task.status_changed", "task.done", "task.rejected",
		"task.assigned", "task.moved", "task.deleted",
		"decision.accepted", "decision.rejected",
		"comment.added", "comment.removed",
		"store.changed",
	} {
		if !strings.Contains(strings.Join(events, " "), event) {
			t.Errorf("%s is not subscribed to: %v", event, events)
		}
	}
}

// One machine, one plugin. The default scope is per project, and taking it would stand up a
// Worker, a key and a round of pairing for every project on the machine — the phone would then
// read as many backlogs as the user has projects, each behind its own QR code.
func TestItIsEnabledForTheMachineRatherThanForEachProject(t *testing.T) {
	if scope := read(t).Scope; scope != "machine" {
		t.Errorf("the manifest declares scope %q, so the user pays for the whole setup per project", scope)
	}
}

// Every platform a release bakes has to be published under a key, and nothing may be published
// that no run bakes: a key with no build behind it is an install that 404s on the machine it was
// offered to, and a build nobody publishes is a platform the plugin never reaches.
func TestEveryPlatformTheBuildBakesIsPublished(t *testing.T) {
	assets := read(t).Assets

	for _, platform := range platforms(t) {
		if _, published := assets[platform]; !published {
			t.Errorf("the build bakes %q, the manifest publishes no asset under it", platform)
		}
	}
	if len(assets) != len(platforms(t)) {
		t.Errorf("the manifest publishes %d asset(s) for %d baked platform(s)", len(assets), len(platforms(t)))
	}
}

// One release, quoted the same way by every key. The version is written twice in each url — once
// in the path and once in the filename — and every asset has to agree with every other, since a
// single line left behind at the previous release serves that one platform an old binary whose
// digest still checks out, so nothing anywhere fails.
//
// The digest itself is only shaped here. Whether it is the digest of the file it names is for the
// release procedure to settle, against the bytes it downloaded from the release.
func TestEveryAssetQuotesOneRelease(t *testing.T) {
	m := read(t)
	url := regexp.MustCompile(`^https://github\.com/(.+)/releases/download/(v\d+)/` +
		regexp.QuoteMeta(pluginName) + `-(v\d+)-([a-z0-9-]+)\.tar\.gz$`)
	digest := regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

	releases := map[string]string{}
	for _, platform := range platforms(t) {
		published, ok := m.Assets[platform]
		if !ok {
			continue // already reported, by the test that asks for the key at all
		}
		parts := url.FindStringSubmatch(published.URL)
		if parts == nil {
			t.Errorf("%s: %q is not a release asset of this repository", platform, published.URL)
			continue
		}
		repo, inPath, inName, named := parts[1], parts[2], parts[3], parts[4]
		if repo != m.Repo {
			t.Errorf("%s: the url names %q, the manifest names %q", platform, repo, m.Repo)
		}
		if inPath != inName {
			t.Errorf("%s: the url is under %s and the file says %s", platform, inPath, inName)
		}
		if named != platform {
			t.Errorf("%s: the url points at the %s build", platform, named)
		}
		if !digest.MatchString(published.Checksum) {
			t.Errorf("%s: %q is not a sha256 digest", platform, published.Checksum)
		}
		releases[inPath] = platform
	}

	if len(releases) > 1 {
		t.Errorf("the assets are spread over %d releases: %v", len(releases), releases)
	}
}

// **The line the settings screen asks for has to be a command the binary knows**, the same as a
// button — and it is asked without anybody pressing anything, so a name that drifted would show
// as a form that has stopped answering rather than as an error somebody set off.
func TestTheLineTheSettingsScreenAsksForIsDispatched(t *testing.T) {
	asked := read(t).Settings.Check

	if asked == "" {
		t.Fatal("the settings screen asks nothing, so a form of readonly boxes says nothing about whether anything is reaching")
	}
	nothingOpens(t)
	var code int
	capture(t, func() { code = run(input{}, strings.Fields(asked)) })

	if code == 2 {
		t.Errorf("%q is what the form asks and the binary does not know it", asked)
	}
}

// **The values the form offers are the names the code carries to.** They travel through a settings
// file and back, so a value renamed on one side and not the other reads as a place nobody ticked —
// and what stops is the carrying, silently.
func TestTheChoicesOfferedAreThePlacesTheCodeKnows(t *testing.T) {
	declared := setting(t, configRoutes)

	if declared.Type != "multi" {
		t.Errorf("%s is declared %q, and it is a set of places rather than a line of text", configRoutes, declared.Type)
	}
	offered := make([]string, len(declared.Options))
	for at, one := range declared.Options {
		offered[at] = one.Value
		if one.Label == "" {
			t.Errorf("%q is offered with nothing written beside it", one.Value)
		}
	}
	if strings.Join(offered, ",") != strings.Join(routesDeclared, ",") {
		t.Errorf("the form offers %v and the code carries to %v", offered, routesDeclared)
	}
	// The default is what a plugin nobody has been to the settings screen for carries with, so it
	// has to be every place — the bound only ever takes one away.
	if declared.Default != strings.Join(routesDeclared, ",") {
		t.Errorf("the default is %q, and a plugin that was never configured would carry to less than everywhere", declared.Default)
	}
}

// **The numbers on the buttons are the order they are pressed in**, and they are written into the
// labels by hand. A button added at the front renumbers every one after it, so a run that added
// one and stopped there leaves the settings screen telling the user to press 1, 1, 2, 3.
func TestTheButtonsAreNumberedInTheOrderTheyArePressed(t *testing.T) {
	for at, offered := range read(t).Settings.Actions {
		if want := fmt.Sprintf("%d. ", at+1); !strings.HasPrefix(offered.Label, want) {
			t.Errorf("the %s button reads %q, and it is the one to press %s", offered.Cmd, offered.Label, want)
		}
	}
}
