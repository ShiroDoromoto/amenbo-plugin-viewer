package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// The path is the app's container id with its dots turned into tildes, and no team id in front.
// Both halves are easy to get wrong and neither fails loudly: a wrong path is a route that
// quietly writes where nothing reads.
func TestTheDropIsTheAppsOwnContainer(t *testing.T) {
	drop := icloudDropIn("/home/someone")

	if drop != "/home/someone/Library/Mobile Documents/iCloud~work~amenbo~viewer/Documents" {
		t.Errorf("drop = %q", drop)
	}
	if strings.Contains(drop, ".") {
		t.Errorf("the container id keeps a dot where the disk has a tilde: %q", drop)
	}
}

// The directory being there is the whole switch, so what counts as "there" is worth pinning: a
// directory yes, a path with nothing at it no, and a file standing in its place no.
func TestTheRouteIsLiveOnlyWhereADirectoryStands(t *testing.T) {
	standing := t.TempDir()

	file := filepath.Join(standing, "Documents")
	if err := os.WriteFile(file, []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}

	for name, test := range map[string]struct {
		path string
		want bool
	}{
		"a directory":              {path: standing, want: true},
		"nothing at all":           {path: filepath.Join(standing, "not-there")},
		"a file in its place":      {path: file},
		"no such thing on this OS": {path: ""},
	} {
		t.Run(name, func(t *testing.T) {
			if got := dropIsThere(test.path); got != test.want {
				t.Errorf("dropIsThere(%q) = %v", test.path, got)
			}
		})
	}
}

// Which home the drop is counted from is what keeps a rehearsal off somebody's phone, and it is
// decided by the store Amenbo says it fired this run for. Getting it wrong is silent either way:
// too eager and the user's own sends stop reaching their phone, too shy and a throwaway store
// writes into the container the phone reads.
func TestTheDropFollowsTheStoreItWasFiredFor(t *testing.T) {
	home := "/Users/someone"

	for name, test := range map[string]struct {
		store string
		want  string
	}{
		"no store named": {store: "", want: home},
		"the store they work in": {
			store: "/Users/someone/Library/Application Support/work.amenbo.amenbo",
			want:  home,
		},
		"the same one, spelled loosely": {
			store: "/Users/someone/Library/Application Support/work.amenbo.amenbo/",
			want:  home,
		},
		"a throwaway store": {
			store: "/tmp/base",
			want:  "/tmp/base/machine",
		},
	} {
		t.Run(name, func(t *testing.T) {
			if got := dropHome(home, test.store); got != test.want {
				t.Errorf("dropHome(%q, %q) = %q, want %q", home, test.store, got, test.want)
			}
		})
	}
}

// The home reached through a symlink is the same home. macOS puts a throwaway directory under
// /var, which is itself a link to /private/var, so a comparison that only read the spelling would
// be answering this question with a coin toss on paths that matter.
func TestAHomeReachedThroughALinkIsTheSameHome(t *testing.T) {
	standing := t.TempDir()

	standingHome := filepath.Join(standing, "home")
	if err := os.MkdirAll(standingHome, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(standing, "link")
	if err := os.Symlink(standingHome, link); err != nil {
		t.Fatal(err)
	}

	if !sameDirectory(link, standingHome) {
		t.Errorf("sameDirectory(%q, %q) = false", link, standingHome)
	}
	if sameDirectory(standingHome, filepath.Join(standing, "elsewhere")) {
		t.Error("a path that is not there reads as the same directory")
	}
}

// The whole run, from the variable Amenbo fills in to the directory written into: a throwaway
// store lands beside itself, and the store the user works in lands in the container.
func TestTheDropPathIsReadFromTheEnvironment(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("the mac route is macOS only")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}

	t.Setenv(envAmenboHome, "/tmp/base")
	if got, want := icloudDrop(), icloudDropIn("/tmp/base/machine"); got != want {
		t.Errorf("icloudDrop() = %q, want %q", got, want)
	}

	t.Setenv(envAmenboHome, defaultStoreIn(home))
	if got, want := icloudDrop(), icloudDropIn(home); got != want {
		t.Errorf("icloudDrop() = %q, want %q", got, want)
	}
}
