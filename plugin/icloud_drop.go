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
//	  records/<dataset>/<id>.json  the record exactly as the other route carries it
//
// **One file per record**, which is the same unit the Cloudflare route places and the same one
// amenbo's ledger names. iCloud syncs a file at a time, so an ordinary turn — a record or two
// having moved — sends a file or two. Holding everything in one file instead would re-upload the
// whole backlog every time a title is edited, and would leave the phone unable to tell which part
// of it had changed.
//
// It also settles what a deletion is: the file goes away. The phone learns of it by finding the
// key gone, so nothing has to keep tombstones on a route where nobody could ever collect them.
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
// and underscores, which is every table amenbo has.
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

// sweep takes away every record file the placement did not write.
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
// **What lands is the record as it travels**, envelope and all — the same document the Cloudflare
// route carries, so the phone opens one shape whichever route it read from.
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
