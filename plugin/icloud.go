package main

import (
	"os"
	"path/filepath"
	"runtime"
)

// The mac route writes into the **app's own iCloud container**, and the user does not choose it.
//
// Letting them pick a folder cost a setting here, a folder picker on the phone, and a way for
// the two to disagree — all of it in service of a choice nobody wanted to make. The container is
// the one place both ends already know how to find.
//
// It also cannot be created from here. `~/Library/Mobile Documents` is not writable even by its
// owner, and the file provider refuses a mkdir through it. **The OS grows the directory, and
// what makes it do so is the app being opened once on a phone** — the mac needs no app of its
// own. So the directory being absent is not a fault to report: it is the state every install
// starts in, and it ends the first time the user opens the app.
//
// Once it is there, an ordinary process outside any sandbox writes to it — no entitlement, no
// signature. (`brctl` calls the container `SYNC DISABLED (app not installed)` on a mac with no
// app of that name; it syncs anyway, so that line is not something to read a verdict out of.)

// icloudContainer is the container id with its dots turned into tildes, which is how it appears
// on disk. No team id goes in front of it.
const icloudContainer = "iCloud~work~amenbo~viewer"

// The drop is counted from a home directory, and **which home that is depends on the store the
// plugin was fired for**. Amenbo names that store in the environment when it launches a plugin,
// the same way git hands a hook its `GIT_DIR`, so a run for a throwaway store can be told apart
// from a run for the store the user actually works in — and only the second one has any business
// writing into the container the phone reads.
//
// A throwaway store is not written off, it is written **beside**: the drop moves under the base
// directory the store itself sits in, which is the same place a hand-run loop already points
// `HOME` at. The route stays whole, so the work that is verified against it is verified for real
// — what changes is that forgetting to point it away no longer lands a rehearsal on somebody's
// phone. It is a fence and not the destination: a folder outside iCloud cannot say whether the
// phone would have read it.

// envAmenboHome is where Amenbo writes the base directory of the store it is running.
const envAmenboHome = "AMENBO_HOME"

// amenboAppData is the directory Amenbo keeps a store in when nobody has pointed it elsewhere —
// its bundle id, under the user's application support. A store there is the user's own.
const amenboAppData = "work.amenbo.amenbo"

// besideTheStore is the folder a throwaway store's drop is counted from, next to the store file.
// It stands for the machine that store is pretending to be.
const besideTheStore = "machine"

// icloudIsARoadHere says whether this OS has an app-container folder at all.
//
// **It is a different question from whether the folder is there.** A mac with no folder yet is a
// mac waiting for the app to be opened once; a Windows machine has nothing to wait for, and
// telling its user to open the app on an iPhone points at a road their machine does not have.
// The behaviour has always split on this; only the words had not.
//
// It is a variable for the same reason the drop path is: the gate runs on every OS, and both
// sides of this answer have to be walkable wherever it runs.
var icloudIsARoadHere = func() bool { return runtime.GOOS == "darwin" }

// icloudDrop is the directory a mac writes into, or "" where there is no such thing — every OS
// but macOS, and a machine whose home directory cannot be found.
func icloudDrop() string {
	if !icloudIsARoadHere() {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return icloudDropIn(dropHome(home, os.Getenv(envAmenboHome)))
}

// dropHome is the home directory the drop is counted from: the user's own when the store is the
// one they work in, and a folder beside the store when it is anywhere else.
//
// **An unnamed store is the user's own.** The variable is Amenbo's to fill in, and a build that
// does not fill it in leaves this exactly where it has always been rather than diverting the one
// route that reaches a phone.
func dropHome(home, store string) string {
	if store == "" || sameDirectory(store, defaultStoreIn(home)) {
		return home
	}
	return filepath.Join(store, besideTheStore)
}

// defaultStoreIn is where Amenbo keeps its store under a given home directory, on macOS.
func defaultStoreIn(home string) string {
	return filepath.Join(home, "Library", "Application Support", amenboAppData)
}

// sameDirectory says whether two paths name one directory. The spelling is compared first, and
// the resolved path only when that disagrees — a home reached through a symlink is the same home,
// and reading it as a different one would divert the user's own store into a corner of itself.
func sameDirectory(one, other string) bool {
	if filepath.Clean(one) == filepath.Clean(other) {
		return true
	}
	resolvedOne, err := filepath.EvalSymlinks(one)
	if err != nil {
		return false
	}
	resolvedOther, err := filepath.EvalSymlinks(other)
	if err != nil {
		return false
	}
	return resolvedOne == resolvedOther
}

// icloudDropIn is where the drop sits under a given home directory.
func icloudDropIn(home string) string {
	return filepath.Join(home, "Library", "Mobile Documents", icloudContainer, "Documents")
}

// icloudDropPath is where this machine's drop is.
//
// **The directory's existence is the switch.** There is no setting to disagree with it: the route
// turns itself on when the user first opens the app, which is the same moment the phone becomes
// able to read anything.
//
// It is a variable because the real directory is one no test is allowed to create, and every test
// that has a route stands one somewhere it may write.
var icloudDropPath = icloudDrop

// dropIsThere says whether a path is a directory that can be written into. A path that is not
// there, and a file standing where the directory should be, are both "no route" rather than
// faults to raise: neither is something this plugin can fix, and the user's own next step is the
// same either way.
func dropIsThere(path string) bool {
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
