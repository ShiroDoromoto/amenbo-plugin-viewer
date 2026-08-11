package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// What the plugin remembers between runs: the version it last placed, and the cursor it has read
// up to. Two integers, and neither means anything without the other.
//
// It lives in the plugin's own directory rather than in Amenbo's settings. Settings are what the
// user fills in, and this is bookkeeping nobody types — putting it there would show them a
// number they cannot answer and must not edit.
//
// **Losing it is not damage.** A plugin that comes back with no memory places the whole window
// again, which is exactly what a first run does, so a wiped directory costs one large send and
// nothing else.

// stateName is the file, inside the plugin's own directory.
const stateName = "sync-state.json"

// state is that memory, on disk.
type state struct {
	// V is the shape of this file, so a later build can tell a file it wrote from one it did not.
	V int `json:"v"`
	// Version is the store version last placed. Compared for inequality only — a restore winds
	// the store back and the version with it.
	Version int64 `json:"version"`
	// Cursor is where to read changes on from. It is the ledger's, not ours: it comes from the
	// snapshot header on a full send and from each changes answer after that.
	Cursor int64 `json:"cursor"`
}

// stateVersion is the shape written today.
const stateVersion = 1

// pluginDir is the directory the plugin was laid down in — its binary's own, which is where
// Amenbo installs it and where an uninstall takes everything away again. It is a variable so a
// test can write somewhere it is allowed to.
var pluginDir = func() (string, error) {
	program, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("the plugin cannot find its own directory: %w", err)
	}
	return filepath.Dir(program), nil
}

// readState reads what was left last time. A file that is not there is the first run and not a
// fault, so it is reported as "nothing remembered" rather than as an error.
//
// A file this build does not read is treated the same way: placing the whole window again is
// always correct, and guessing at a shape written by something else is not.
func readState() (state, bool, error) {
	dir, err := pluginDir()
	if err != nil {
		return state{}, false, err
	}
	raw, err := os.ReadFile(filepath.Join(dir, stateName))
	if os.IsNotExist(err) {
		return state{}, false, nil
	}
	if err != nil {
		return state{}, false, fmt.Errorf("the sync state cannot be read: %w", err)
	}
	var remembered state
	if err := json.Unmarshal(raw, &remembered); err != nil || remembered.V != stateVersion {
		return state{}, false, nil
	}
	return remembered, true, nil
}

// forgetState throws away what was remembered, so the next send places the whole store again.
//
// **What this plugin remembers is what it sent, not what a store holds**, and the two part company
// whenever the store is stood up anew: an empty one behind a memory that says "level" would be
// handed the next edit and nothing else. Nothing can ask the store which it is — the write token
// is refused at the reading door on purpose — so the moment of standing one up is the only place
// this can be settled.
//
// Nothing remembered is the state a first run is in, so this costs one whole placement and no
// correctness.
func forgetState() error {
	dir, err := pluginDir()
	if err != nil {
		return err
	}
	if err := os.Remove(filepath.Join(dir, stateName)); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("the sync state cannot be cleared: %w", err)
	}
	return nil
}

// writeState records what was placed, by writing a whole new file and moving it into place. A
// half-written state would be read back as a cursor pointing where nothing was sent, and the
// records between there and the truth would never be carried.
func writeState(placed state) error {
	placed.V = stateVersion
	dir, err := pluginDir()
	if err != nil {
		return err
	}
	raw, err := json.Marshal(placed)
	if err != nil {
		return err
	}
	beside, err := os.CreateTemp(dir, stateName+".*")
	if err != nil {
		return fmt.Errorf("the sync state cannot be written: %w", err)
	}
	defer os.Remove(beside.Name())
	if _, err := beside.Write(raw); err != nil {
		beside.Close()
		return fmt.Errorf("the sync state cannot be written: %w", err)
	}
	if err := beside.Close(); err != nil {
		return fmt.Errorf("the sync state cannot be written: %w", err)
	}
	if err := os.Chmod(beside.Name(), 0o600); err != nil {
		return fmt.Errorf("the sync state cannot be written: %w", err)
	}
	if err := os.Rename(beside.Name(), filepath.Join(dir, stateName)); err != nil {
		return fmt.Errorf("the sync state cannot be moved into place: %w", err)
	}
	return nil
}
