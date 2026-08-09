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

// icloudDrop is the directory a mac writes into, or "" where there is no such thing — every OS
// but macOS, and a machine whose home directory cannot be found.
func icloudDrop() string {
	if runtime.GOOS != "darwin" {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return icloudDropIn(home)
}

// icloudDropIn is where the drop sits under a given home directory.
func icloudDropIn(home string) string {
	return filepath.Join(home, "Library", "Mobile Documents", icloudContainer, "Documents")
}

// icloudRouteIsLive says whether the mac route has somewhere to write.
//
// **The directory's existence is the switch.** There is no setting to disagree with it: the
// route turns itself on when the user first opens the app, which is the same moment the phone
// becomes able to read anything.
//
// It is a variable because the directory it looks for is one no test is allowed to create.
var icloudRouteIsLive = func() bool {
	return dropIsThere(icloudDrop())
}

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
