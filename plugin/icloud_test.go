package main

import (
	"os"
	"path/filepath"
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
