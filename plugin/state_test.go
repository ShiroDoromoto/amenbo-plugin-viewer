package main

import (
	"os"
	"path/filepath"
	"testing"
)

// rememberedAt is one route's place, for the tests that only need there to be a memory.
func rememberedAt(version, cursor int64) state {
	return state{Routes: map[string]carried{"icloud": {Version: version, Cursor: cursor}}}
}

// remembering points the plugin's memory at a directory a test is allowed to write in.
func remembering(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	was := pluginDir
	pluginDir = func() (string, error) { return dir, nil }
	t.Cleanup(func() { pluginDir = was })
	return dir
}

// A first run has nothing remembered, and that is not a fault: it is the state every install
// starts in, and the answer to it is to place the whole store.
func TestAFirstRunRemembersNothing(t *testing.T) {
	remembering(t)

	remembered, found, err := readState()

	if err != nil {
		t.Fatal(err)
	}
	if found {
		t.Errorf("something was remembered on a first run: %+v", remembered)
	}
}

// Each route is read back where it was left, and one route's place says nothing about another's:
// the whole point of keeping them apart is that a dead route cannot hold a live one back.
func TestEachRouteIsReadBackWhereItWasLeft(t *testing.T) {
	remembering(t)

	if err := writeState(state{Routes: map[string]carried{
		"icloud":     {Version: 12345, Cursor: 42},
		"cloudflare": {Version: 900, Cursor: 7},
	}}); err != nil {
		t.Fatal(err)
	}

	remembered, found, err := readState()
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("nothing was remembered")
	}
	if left := remembered.Routes["icloud"]; left.Version != 12345 || left.Cursor != 42 {
		t.Errorf("icloud = %+v", left)
	}
	if left := remembered.Routes["cloudflare"]; left.Version != 900 || left.Cursor != 7 {
		t.Errorf("cloudflare = %+v", left)
	}
}

// Forgetting puts the plugin back where a first run stands. It is asked for when a store is
// stood up anew, and what it costs is one whole placement.
func TestForgettingLeavesNothingRemembered(t *testing.T) {
	remembering(t)
	if err := writeState(rememberedAt(12345, 42)); err != nil {
		t.Fatal(err)
	}

	if err := forgetState(); err != nil {
		t.Fatal(err)
	}

	if _, found, err := readState(); err != nil || found {
		t.Errorf("found %v, err %v", found, err)
	}
}

// Forgetting what was never remembered is not a fault: a first setup has nothing to clear, and
// refusing there would fail a run that did everything right.
func TestForgettingWhatWasNeverRememberedIsNotAFailure(t *testing.T) {
	remembering(t)

	if err := forgetState(); err != nil {
		t.Errorf("clearing a memory that was not there failed: %v", err)
	}
}

// A file this build does not read is treated as nothing remembered. Placing the whole store
// again is always correct; guessing at a shape written by something else is not.
func TestAMemoryThisBuildCannotReadIsNoMemory(t *testing.T) {
	for name, written := range map[string]string{
		"not a document":    "{{{",
		"another shape":     `{"v":99,"version":1,"cursor":1}`,
		"nothing declaring": `{"version":1,"cursor":1}`,
	} {
		t.Run(name, func(t *testing.T) {
			dir := remembering(t)
			if err := os.WriteFile(filepath.Join(dir, stateName), []byte(written), 0o600); err != nil {
				t.Fatal(err)
			}

			_, found, err := readState()

			if err != nil {
				t.Fatal(err)
			}
			if found {
				t.Error("a memory this build cannot read was taken for one it can")
			}
		})
	}
}

// The cursor is only true alongside what was actually placed, so it lands whole or not at all —
// a half-written file would be read back as a cursor pointing past records nobody carried.
func TestTheMemoryLandsWholeAndLeavesNothingBehind(t *testing.T) {
	dir := remembering(t)

	if err := writeState(rememberedAt(1, 1)); err != nil {
		t.Fatal(err)
	}
	if err := writeState(rememberedAt(2, 2)); err != nil {
		t.Fatal(err)
	}

	left, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 1 || left[0].Name() != stateName {
		names := make([]string, len(left))
		for i, entry := range left {
			names[i] = entry.Name()
		}
		t.Errorf("the plugin's directory holds %v — a half-written memory was left behind", names)
	}
}

// Forgetting is per route: standing a Worker up says nothing about the folder on this machine,
// and forgetting that too would cost it a whole placement for something that did not happen to it.
func TestForgettingOneRouteLeavesTheOthersWhereTheyStand(t *testing.T) {
	remembering(t)
	if err := writeState(state{Routes: map[string]carried{
		routeCloudflare: {Version: 1, Cursor: 7},
		routeICloud:     {Version: 2, Cursor: 42},
	}}); err != nil {
		t.Fatal(err)
	}

	if err := forgetRoute(routeCloudflare); err != nil {
		t.Fatal(err)
	}

	remembered, found, err := readState()
	if err != nil || !found {
		t.Fatalf("found %v, err %v", found, err)
	}
	if _, known := remembered.Routes[routeCloudflare]; known {
		t.Error("the route that was stood up anew is still remembered")
	}
	if left := remembered.Routes[routeICloud]; left.Cursor != 42 {
		t.Errorf("the route beside it was left at %+v", left)
	}
}

// The last route forgotten takes the file with it, so what is left on disk is the state a first
// run finds — nothing, rather than an empty shell to be read back and reasoned about.
func TestForgettingTheLastRouteLeavesNothingAtAll(t *testing.T) {
	remembering(t)
	if err := writeState(rememberedAt(1, 7)); err != nil {
		t.Fatal(err)
	}

	if err := forgetRoute(routeICloud); err != nil {
		t.Fatal(err)
	}

	if _, found, err := readState(); err != nil || found {
		t.Errorf("found %v, err %v", found, err)
	}
}

// Forgetting a route that was never remembered is not a fault: a first setup has nothing to clear.
func TestForgettingARouteThatWasNeverRememberedIsNotAFault(t *testing.T) {
	remembering(t)

	if err := forgetRoute(routeCloudflare); err != nil {
		t.Errorf("forgetting a route with nothing to forget failed: %v", err)
	}
}
