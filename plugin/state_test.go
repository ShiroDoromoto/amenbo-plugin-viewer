package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// rememberedAt is one route's place, for the tests that only need there to be a memory.
func rememberedAt(version, cursor int64) state {
	return state{Routes: map[string]carried{routeCloudflare: {Version: version, Cursor: cursor}}}
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
		"cloudflare": {Version: 900, Cursor: 7, Placed: 901, Seq: 5006},
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
	// What the place itself was left standing at is remembered beside where the ledger was read
	// to: without it the next turn cannot tell one turn from the same turn sent twice, nor tell a
	// store that wrote from one that answered and did not.
	if left := remembered.Routes["cloudflare"]; left.Placed != 901 || left.Seq != 5006 {
		t.Errorf("cloudflare was read back at %+v, want the number it placed and the ordering it was left at", left)
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

// Forgetting is per route: standing one up says nothing about any other, and forgetting those too
// would cost each of them a whole placement for something that did not happen to it. There is one
// route today, so the route beside it here is a name from a file an older build wrote — which is
// also the case this has to hold for.
func TestForgettingOneRouteLeavesTheOthersWhereTheyStand(t *testing.T) {
	remembering(t)
	if err := writeState(state{Routes: map[string]carried{
		routeCloudflare:                    {Version: 1, Cursor: 7},
		"a-route-this-build-does-not-have": {Version: 2, Cursor: 42},
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
	if left := remembered.Routes["a-route-this-build-does-not-have"]; left.Cursor != 42 {
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

	if err := forgetRoute(routeCloudflare); err != nil {
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

// **The queue and the cursor come back together or not at all.** The cursor says the ledger was
// read that far, so a queue that did not survive the write is a stretch of the backlog nothing
// will go back for — which is why they are fields of one file written whole and moved into place,
// rather than two things written one after the other.
func TestTheQueueComesBackWithTheCursorItWasWrittenWith(t *testing.T) {
	remembering(t)

	queued := []outgoing{
		{Key: "task/1", Op: opPlaced, Row: json.RawMessage(`{"id":1}`)},
		{Key: "task/2", Op: opDeleted},
	}
	if err := writeState(state{Routes: map[string]carried{
		routeCloudflare: {Version: 5, Cursor: 12, Placed: 5, Seq: 40, Pending: queued},
	}}); err != nil {
		t.Fatal(err)
	}

	back, found, err := readState()
	if err != nil || !found {
		t.Fatalf("found %v, err %v", found, err)
	}
	left := back.Routes[routeCloudflare]
	if left.Cursor != 12 || len(left.Pending) != 2 {
		t.Fatalf("read back %+v, want the cursor and the queue it was written with", left)
	}
	if left.Pending[0].Key != "task/1" || string(left.Pending[0].Row) != `{"id":1}` {
		t.Errorf("the first record came back as %+v, want the row it went in with", left.Pending[0])
	}
	if left.Pending[1].Key != "task/2" || left.Pending[1].Op != opDeleted || left.Pending[1].Row != nil {
		t.Errorf("the delete came back as %+v, want a key and no row", left.Pending[1])
	}
}

// An empty queue is not written at all, so a memory from before this build and one this build
// wrote with nothing waiting are the same bytes — there is nothing to tell apart and no migration
// to run.
func TestAnEmptyQueueIsNotWrittenDown(t *testing.T) {
	dir := remembering(t)

	if err := writeState(state{Routes: map[string]carried{
		routeCloudflare: {Version: 5, Cursor: 12},
	}}); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(filepath.Join(dir, stateName))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "pending") {
		t.Errorf("a memory with nothing queued was written as %s", raw)
	}
}
