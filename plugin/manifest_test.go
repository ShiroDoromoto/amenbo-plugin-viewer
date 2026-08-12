package main

import (
	"encoding/json"
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
	Name   string           `json:"name"`
	Repo   string           `json:"repo"`
	OS     []string         `json:"os"`
	Scope  string           `json:"scope"`
	Assets map[string]asset `json:"assets"`
	Events []string         `json:"events"`
	Config []field          `json:"config"`
	Agent  struct {
		Commands []struct {
			Cmd  string `json:"cmd"`
			Does string `json:"does"`
		} `json:"commands"`
	} `json:"agent"`
}

type field struct {
	Key    string `json:"key"`
	Label  string `json:"label"`
	Secret bool   `json:"secret"`
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

// **Every command the manifest advertises must be dispatched.** The manifest is what an AI
// reads to learn this plugin's command face, so one the binary does not know is a line that
// sends a caller to a usage error.
func TestEveryAdvertisedCommandIsDispatched(t *testing.T) {
	commands := read(t).Agent.Commands

	if len(commands) == 0 {
		t.Fatal("the manifest advertises no command at all")
	}
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
