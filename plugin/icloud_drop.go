package main

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Placing records into the iCloud drop.
//
// **On this route the directory is the store.** There is no server keeping a ledger, so what the
// folder holds at any moment has to be the whole current truth — a record that is there is one
// the phone should hold, and one that is gone is one it should forget.
//
//	Documents/
//	  meta.json                    {"spec_v":1,"version":12345,"placed_at":"…"}
//	  records/<dataset>/<id>.json  {"k":"task/12","op":"put","r":{the row}}
//
// **One file per record**, which is the same unit the Cloudflare route places and the same one
// Amenbo's ledger names. iCloud syncs a file at a time, so an ordinary turn — a record or two
// having moved — sends a file or two. Holding everything in one file instead would re-upload the
// whole backlog every time a title is edited, and would leave the phone unable to tell which part
// of it had changed.
//
// It also settles what a deletion is: the file goes away. The phone learns of it by finding the
// key gone, so nothing has to keep tombstones on a route where nobody could ever collect them.
//
// **iCloud is a second writer, and it never asks.** Two machines writing the same file leaves one
// of them beside the other under a number — `meta 2.json`, `records 2` — with the write it holds
// gone from everywhere else. Nothing on either end reads those names, so a send says what it
// found rather than tidying it away (see tellOfCopies).
//
// **`meta.json` is written last**, so it never claims a version the files beside it do not yet
// carry. It is also how a drop says it has never been written into: the folder appears when the
// user first opens the app on their phone, which is long after this plugin started counting its
// sends, and an empty one has to be filled whatever the plugin remembers.

const (
	// dropMetaName is the file naming what the drop as a whole holds.
	dropMetaName = "meta.json"
	// dropRecordsDir is the directory the records live under, one per file.
	dropRecordsDir = "records"
	// dropSuffix is what a record's file is called after its id.
	dropSuffix = ".json"
	// copiesNamed is how many conflict copies one line names before it counts the rest. The
	// point of the line is that the user go and look, and a name or three is enough to find
	// the folder by.
	copiesNamed = 3
)

// dropMeta is what meta.json holds: which contract the files are written to, which store version
// they are a picture of, and when they were placed.
type dropMeta struct {
	SpecV    int    `json:"spec_v"`
	Version  int64  `json:"version"`
	PlacedAt string `json:"placed_at"`
}

// drop is the iCloud route: a directory, and nothing else. There is no token and no URL, because
// there is nobody in between — the folder is reached by the phone through iCloud itself.
type drop struct {
	dir string
}

// name is what the iCloud route is remembered under.
func (d drop) name() string { return routeICloud }

// String names the route in a diagnostic, in the words the user's own question is asked in.
func (d drop) String() string { return "the iCloud Drive folder" }

// dropFor names the iCloud route, or says there is not one. A drop that is not there is not a
// fault to report: it is what every install looks like until the app is opened once.
func dropFor() (drop, error) {
	dir := icloudDropPath()
	if !dropIsThere(dir) {
		return drop{}, errNoRoute
	}
	return drop{dir: dir}, nil
}

// holdsNothing says the drop has never been written into.
//
// A folder that appeared after the last send would otherwise be handed the records that moved
// since then and nothing else — a phone reading it would see whatever was edited this week, with
// no backlog behind it.
func (d drop) holdsNothing() bool {
	_, err := os.Stat(filepath.Join(d.dir, dropMetaName))
	return err != nil
}

// place puts what moved into the drop: a file per record written, a file per record deleted taken
// away, and the meta written once at the end.
func (d drop) place(body placement) error {
	d.tellOfCopies()
	for _, record := range body.Records {
		path, err := d.pathFor(record.Key)
		if err != nil {
			return err
		}
		if record.Op == opDeleted {
			if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
				return fmt.Errorf("%s cannot be taken out of the drop: %w", record.Key, err)
			}
			continue
		}
		if err := writeRecordFile(path, record); err != nil {
			return err
		}
	}
	return d.writeMeta(body)
}

// replace makes the drop hold exactly what it is given — the whole window, and nothing that was
// there before it.
//
// The sweep is the half that matters: a first run, a reset and a gap all mean "forget what you
// thought you knew", and a file left standing from before would be a record the phone keeps
// holding with nothing to say it is gone.
func (d drop) replace(body placement) error {
	d.tellOfCopies()
	placed := make(map[string]bool, len(body.Records))
	for _, record := range body.Records {
		path, err := d.pathFor(record.Key)
		if err != nil {
			return err
		}
		if record.Op == opDeleted {
			continue
		}
		if err := writeRecordFile(path, record); err != nil {
			return err
		}
		placed[path] = true
	}
	if err := d.sweep(placed); err != nil {
		return err
	}
	return d.writeMeta(body)
}

// pathFor is where one record's key files it.
//
// The key is the contract's `<dataset>/<id>`, and it becomes a path, so it is checked rather than
// trusted: a dataset holding a separator or a dot would write outside the drop. A key that cannot
// be filed is refused instead of skipped — a record silently left out is one the phone never
// learns it is missing.
func (d drop) pathFor(key string) (string, error) {
	dataset, id, split := strings.Cut(key, "/")
	if !split || !isPlainName(dataset) || !isNumber(id) {
		return "", fmt.Errorf("%q is not a key this route can file", key)
	}
	return filepath.Join(d.dir, dropRecordsDir, dataset, id+dropSuffix), nil
}

// isPlainName says whether a dataset name is one that can stand as a directory: letters, digits
// and underscores, which is every table Amenbo has.
func isPlainName(name string) bool {
	if name == "" {
		return false
	}
	for _, letter := range name {
		switch {
		case letter >= 'a' && letter <= 'z', letter >= 'A' && letter <= 'Z':
		case letter >= '0' && letter <= '9', letter == '_':
		default:
			return false
		}
	}
	return true
}

// isNumber says whether a record id is one, which is what keeps `..` from becoming a file name.
func isNumber(id string) bool {
	_, err := strconv.ParseInt(id, 10, 64)
	return err == nil
}

// sweep takes away every record file the placement did not write, conflict copies included: the
// phone reads this tree, and a copy left in it arrives as a record filed under a key naming
// nothing. What the copy was evidence of is said before the sweep runs (see tellOfCopies), so the
// file goes without the fact going with it.
func (d drop) sweep(placed map[string]bool) error {
	records := filepath.Join(d.dir, dropRecordsDir)
	err := filepath.WalkDir(records, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || placed[path] {
			return nil
		}
		return os.Remove(path)
	})
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("what the drop held before cannot be cleared: %w", err)
	}
	return nil
}

// tellOfCopies says what iCloud left beside what this route writes.
//
// **A copy means the folder was written from two places at once, and one of those writes is
// gone.** iCloud does not merge and does not ask: it keeps one of the two and puts the other
// next to it under a number — `meta 2.json` beside `meta.json`, `records 2` beside `records`.
// Nothing on either end reads those names, so they sit there for good, and the write they hold
// is the only place that write still exists.
//
// So it is said out loud rather than tidied away. The copies under `records/` do go, but they go
// through the sweep, whose reason is a different one — the phone reads that tree, and a copy left
// in it is filed under a key naming no record. Saying so first is what keeps the sweep from
// taking the fact along with the file.
//
// It costs a walk of the folder per send, which is what the sweep already costs on the turns that
// take the whole window.
func (d drop) tellOfCopies() {
	copies := d.copiesLeftBehind()
	if len(copies) == 0 {
		return
	}
	named, rest := copies, ""
	if len(named) > copiesNamed {
		named, rest = named[:copiesNamed], fmt.Sprintf(", and %d more", len(copies)-copiesNamed)
	}
	logf("%s: iCloud made %d copy(ies) in the drop because it was written from two places at once — %s%s. One of the two writes was lost, and the copy is the only thing still holding it: read it before you take it away.",
		pluginName, len(copies), strings.Join(named, ", "), rest)
}

// copiesLeftBehind names every conflict copy in the drop, relative to it. A copied directory is
// named once rather than once per file below it: what the user has to open is the directory.
func (d drop) copiesLeftBehind() []string {
	var copies []string
	err := filepath.WalkDir(d.dir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || path == d.dir || !isConflictCopy(entry.Name()) {
			// A folder that cannot be read is not this line's to raise: whatever the send is
			// doing at the time will fail on its own, with the reason it failed for.
			return nil
		}
		if at, err := filepath.Rel(d.dir, path); err == nil {
			copies = append(copies, filepath.ToSlash(at))
		}
		if entry.IsDir() {
			return fs.SkipDir
		}
		return nil
	})
	if err != nil {
		return nil
	}
	return copies
}

// isConflictCopy says whether a name is one iCloud made rather than one this route wrote. Every
// name written here is a bare word or a number, so a number put after a space is not a name that
// could have come from this side.
func isConflictCopy(name string) bool {
	base := strings.TrimSuffix(name, filepath.Ext(name))
	space := strings.LastIndex(base, " ")
	if space <= 0 {
		return false
	}
	return isCopyNumber(base[space+1:])
}

// isCopyNumber says whether what follows the space is the number iCloud counts copies with. The
// count starts at the second copy, so a name ending in "0" or "1" — or in a number written with
// a zero in front of it — is somebody's own.
func isCopyNumber(number string) bool {
	if number == "" || number == "0" || number == "1" || number[0] == '0' {
		return false
	}
	for _, digit := range number {
		if digit < '0' || digit > '9' {
			return false
		}
	}
	return true
}

// writeMeta says what the drop as a whole now holds. It goes in last, so a turn that is cut short
// leaves a version that is behind the files rather than ahead of them.
func (d drop) writeMeta(body placement) error {
	return writeIntoDrop(filepath.Join(d.dir, dropMetaName), dropMeta{
		SpecV:    body.SpecV,
		Version:  body.Version,
		PlacedAt: time.Now().UTC().Format(time.RFC3339),
	})
}

// writeRecordFile writes one record where its key files it.
//
// **What lands is the row as it is.** This folder is the reader's own iCloud container, guarded the
// way their phone's own files are, so there is nothing to put an envelope between — and a key that
// never has to reach the phone is a key a mac-only user never has to be given. The envelope belongs
// to the other route, which ends up somewhere its owner merely rents.
func writeRecordFile(path string, record outgoing) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("the drop cannot be laid out: %w", err)
	}
	return writeIntoDrop(path, record)
}

// writeIntoDrop writes one JSON document whole, by writing it beside its place and moving it in.
// A half-written file in a folder that syncs is one the phone would read as a record: the rename
// is what makes the file appear only once all of it is there.
func writeIntoDrop(path string, document any) error {
	raw, err := json.Marshal(document)
	if err != nil {
		return err
	}
	beside, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*")
	if err != nil {
		return fmt.Errorf("nothing can be written into the drop: %w", err)
	}
	defer os.Remove(beside.Name())

	if _, err := beside.Write(raw); err != nil {
		beside.Close()
		return fmt.Errorf("%s cannot be written: %w", filepath.Base(path), err)
	}
	if err := beside.Close(); err != nil {
		return fmt.Errorf("%s cannot be written: %w", filepath.Base(path), err)
	}
	if err := os.Chmod(beside.Name(), 0o600); err != nil {
		return err
	}
	if err := os.Rename(beside.Name(), path); err != nil {
		return fmt.Errorf("%s cannot be moved into place: %w", filepath.Base(path), err)
	}
	return nil
}
