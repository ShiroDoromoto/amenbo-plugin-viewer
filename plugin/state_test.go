package main

import (
	"os"
	"path/filepath"
	"testing"
)

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

func TestWhatWasPlacedIsReadBack(t *testing.T) {
	remembering(t)

	if err := writeState(state{Version: 12345, Cursor: 42}); err != nil {
		t.Fatal(err)
	}

	remembered, found, err := readState()
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("nothing was remembered")
	}
	if remembered.Version != 12345 || remembered.Cursor != 42 {
		t.Errorf("%+v", remembered)
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

	if err := writeState(state{Version: 1, Cursor: 1}); err != nil {
		t.Fatal(err)
	}
	if err := writeState(state{Version: 2, Cursor: 2}); err != nil {
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
