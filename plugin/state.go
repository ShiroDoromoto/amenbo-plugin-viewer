package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// What the plugin remembers between runs: how far each route was left. Two integers per route,
// and neither of them means anything without the other.
//
// **It is per route because routes fail apart.** There is one today and there were two, and what
// the shape is for is the case where one of them will not take anything while the next does: a
// single memory for all of them would let the dead one hold the live one's place, so the next turn
// carries the same stretch again and the one after that carries a longer one. Nothing about that
// is visible — the hook is fired and forgotten, so the only place it shows is a log nobody has
// reason to open.
//
// It lives in the plugin's own directory rather than in Amenbo's settings. Settings are what the
// user fills in, and this is bookkeeping nobody types — putting it there would show them a
// number they cannot answer and must not edit.
//
// **Losing it is not damage.** A route that comes back with no memory is placed whole, which is
// exactly what a first run does, so a wiped directory costs one large send and nothing else.

// stateName is the file, inside the plugin's own directory.
const stateName = "sync-state.json"

// sendingLockName is the file two runs contend for while one of them is sending. It lies beside
// the memory it guards, so an uninstall takes it away with everything else.
//
// **Nothing is ever written into it.** What says a send is in flight is the kernel's hold on the
// open file, not anything in it: a run that dies leaves its bytes behind saying "in flight"
// forever, while the hold goes with the process however the process ends.
const sendingLockName = "sending.lock"

// The names the routes are remembered under. They are written into a file that outlives the
// process, so they are spelled once here rather than at each route — a route renamed in two
// places and not the third would silently start again from nothing.
//
// **A name this build does not know is left where it lies.** A file written when there were two
// routes still names the other one; nothing looks it up, so it costs a few bytes and no
// correctness, and rewriting the file to drop it would be a migration for nothing.
const (
	routeCloudflare = "cloudflare"
)

// state is that memory, on disk.
type state struct {
	// V is the shape of this file, so a later build can tell a file it wrote from one it did not.
	V int `json:"v"`
	// Routes is how far each route was left, under the name that route answers to. A route with
	// no entry has never been placed to, and is placed whole.
	Routes map[string]carried `json:"routes"`
}

// carried is how far one route was left.
type carried struct {
	// Version is the store version last placed there. Compared for inequality only — a restore
	// winds the store back and the version with it.
	Version int64 `json:"version"`
	// Cursor is where to read changes on from. It is the ledger's, not ours: it comes from the
	// snapshot header on a whole placement and from each changes answer after that.
	Cursor int64 `json:"cursor"`
}

// stateVersion is the shape written today. A file written to an older one is not read: the shapes
// before this one held a single cursor for every route at once, and there is no honest way to say
// which route that cursor belonged to.
const stateVersion = 2

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

// sendingLockPath is where that file lies, which is wherever the memory lies — the same
// directory, found the same way, so a test that redirects one redirects both.
func sendingLockPath() (string, error) {
	dir, err := pluginDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, sendingLockName), nil
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

// forgetRoute throws away what one route was left holding, so the next turn places the whole
// store there again — and leaves every other route where it stands.
//
// **What this plugin remembers is what it sent, not what a place holds**, and the two part company
// whenever that place is stood up anew: an empty store behind a memory that says "level" would be
// handed the next edit and nothing else. Nothing can ask the store which it is — the write token
// is refused at the reading door on purpose — so the moment of standing one up is the only place
// this can be settled.
//
// **Only that route.** Standing a Worker up says nothing about the folder on this machine, and
// forgetting both would cost the folder a whole placement for something that did not happen to it.
//
// Nothing remembered is the state a first run is in, so this costs one whole placement and no
// correctness.
func forgetRoute(name string) error {
	remembered, found, err := readState()
	if err != nil {
		return err
	}
	if _, known := remembered.Routes[name]; !found || !known {
		return nil
	}
	delete(remembered.Routes, name)
	if len(remembered.Routes) == 0 {
		return forgetState()
	}
	return writeState(remembered)
}

// forgetState throws away the memory whole, which is what is left when no route has a place in it.
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
