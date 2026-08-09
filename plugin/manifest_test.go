package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// The manifest as this test asks about it — the fields that have to agree with the code beside
// it, not the whole schema `amenbo plugin validate` checks (the Makefile runs that).
type manifest struct {
	Name   string   `json:"name"`
	OS     []string `json:"os"`
	Scope  string   `json:"scope"`
	Events []string `json:"events"`
	Config []field  `json:"config"`
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

// The name decides what amenbo runs, what directory it is laid down in, and the word a user
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

// The plugin runs wherever amenbo does. The iCloud route is mac-only, but the Cloudflare one is
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
// A subscription narrower than what amenbo fires would be a window the viewer silently misses.
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
