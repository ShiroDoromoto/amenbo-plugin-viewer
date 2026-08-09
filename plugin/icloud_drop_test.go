package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// standingDrop is a drop somewhere a test may write.
func standingDrop(t *testing.T) drop {
	t.Helper()
	return drop{dir: t.TempDir()}
}

// filesIn lists what a drop holds, as paths relative to it, so a test can say what the folder
// looks like rather than where the temporary directory landed.
func filesIn(t *testing.T, where drop) []string {
	t.Helper()
	var held []string
	err := filepath.Walk(where.dir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		at, err := filepath.Rel(where.dir, path)
		if err != nil {
			return err
		}
		held = append(held, filepath.ToSlash(at))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(held)
	return held
}

func placed(key string) outgoing {
	return outgoing{Key: key, Op: opPlaced, Nonce: "a-nonce", Cipher: "a-ciphertext"}
}

// One record is one file, filed under the key the contract gives it. iCloud syncs a file at a
// time, so the unit the records are placed in is the unit that travels.
func TestARecordIsOneFileUnderItsKey(t *testing.T) {
	where := standingDrop(t)

	if err := where.place(placement{SpecV: specVersion, Version: 7, Records: []outgoing{
		placed("task/12"), placed("task_comment/3"),
	}}); err != nil {
		t.Fatal(err)
	}

	want := []string{"meta.json", "records/task/12.json", "records/task_comment/3.json"}
	if got := filesIn(t, where); strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("the drop holds %v, want %v", got, want)
	}
}

// What lands in the file is the record as it travels — the same document the other route carries,
// so the phone opens one shape whichever route it read from.
func TestTheFileHoldsTheRecordAsItTravels(t *testing.T) {
	where := standingDrop(t)

	if err := where.place(placement{SpecV: specVersion, Version: 7, Records: []outgoing{placed("task/12")}}); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(filepath.Join(where.dir, "records", "task", "12.json"))
	if err != nil {
		t.Fatal(err)
	}
	var read outgoing
	if err := json.Unmarshal(raw, &read); err != nil {
		t.Fatal(err)
	}
	if read != placed("task/12") {
		t.Errorf("the file holds %+v", read)
	}
}

// The meta says what the drop as a whole holds. The phone reads a version out of it, so it is
// written after the records — never claiming more than the files beside it carry.
func TestTheMetaNamesTheContractAndTheVersion(t *testing.T) {
	where := standingDrop(t)

	if err := where.place(placement{SpecV: specVersion, Version: 12345, Records: []outgoing{placed("task/1")}}); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(filepath.Join(where.dir, dropMetaName))
	if err != nil {
		t.Fatal(err)
	}
	var read dropMeta
	if err := json.Unmarshal(raw, &read); err != nil {
		t.Fatal(err)
	}
	if read.SpecV != specVersion || read.Version != 12345 || read.PlacedAt == "" {
		t.Errorf("meta = %+v", read)
	}
}

// A deletion is the file going away. There is nobody keeping a ledger on this route, so a record
// the phone should forget is one it stops finding — a tombstone would be a row nobody could ever
// come back and collect.
func TestADeletedRecordIsAFileThatGoesAway(t *testing.T) {
	where := standingDrop(t)

	if err := where.place(placement{SpecV: specVersion, Version: 1, Records: []outgoing{placed("task/12"), placed("task/13")}}); err != nil {
		t.Fatal(err)
	}
	if err := where.place(placement{SpecV: specVersion, Version: 2, Records: []outgoing{{Key: "task/12", Op: opDeleted}}}); err != nil {
		t.Fatal(err)
	}

	want := []string{"meta.json", "records/task/13.json"}
	if got := filesIn(t, where); strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("the drop holds %v, want %v", got, want)
	}
}

// A record deleted between two sends can be one this drop never held. Nothing is wrong with that
// — the phone is being told to forget something it may never have had.
func TestDeletingARecordTheDropNeverHeldIsNotAFailure(t *testing.T) {
	where := standingDrop(t)

	if err := where.place(placement{SpecV: specVersion, Version: 1, Records: []outgoing{{Key: "task/99", Op: opDeleted}}}); err != nil {
		t.Errorf("a delete with nothing to delete failed: %v", err)
	}
}

// A whole placement is the drop's new truth: what it held before and is not in the placement is
// gone, or the phone would keep holding a record with nothing left to say it went away.
func TestAWholePlacementSweepsWhatWasThereBefore(t *testing.T) {
	where := standingDrop(t)

	if err := where.place(placement{SpecV: specVersion, Version: 1, Records: []outgoing{
		placed("task/1"), placed("task/2"), placed("decision/9"),
	}}); err != nil {
		t.Fatal(err)
	}
	if err := where.replace(placement{SpecV: specVersion, Version: 2, Records: []outgoing{placed("task/2")}}); err != nil {
		t.Fatal(err)
	}

	want := []string{"meta.json", "records/task/2.json"}
	if got := filesIn(t, where); strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("the drop holds %v, want %v", got, want)
	}
}

// The folder appears when the user first opens the app on their phone, which is any number of
// sends after this plugin started counting. Until it has been written into, it needs the whole
// window rather than what moved this week.
func TestADropWithNoMetaHasNeverBeenWrittenInto(t *testing.T) {
	where := standingDrop(t)

	if !where.holdsNothing() {
		t.Error("an empty folder claimed to hold the backlog")
	}

	if err := where.place(placement{SpecV: specVersion, Version: 1, Records: []outgoing{placed("task/1")}}); err != nil {
		t.Fatal(err)
	}

	if where.holdsNothing() {
		t.Error("a folder that has been placed into claimed to hold nothing")
	}
}

// The key becomes a path, so it is checked rather than trusted. A record that cannot be filed is
// refused: one silently left out is one the phone never learns it is missing.
func TestAKeyThatWouldWriteOutsideTheDropIsRefused(t *testing.T) {
	where := standingDrop(t)

	for _, key := range []string{"../escape/1", "task/../../1", "task", "task/not-a-number", "/1"} {
		if _, err := where.pathFor(key); err == nil {
			t.Errorf("%q was taken for a place to write", key)
		}
	}
}

// Nothing half-written may appear in a folder that syncs: the phone reads whatever is there, and
// a truncated record would be one it cannot open with no way to know why.
func TestAFileAppearsOnlyOnceAllOfItIsThere(t *testing.T) {
	where := standingDrop(t)

	if err := where.place(placement{SpecV: specVersion, Version: 1, Records: []outgoing{placed("task/1")}}); err != nil {
		t.Fatal(err)
	}

	for _, held := range filesIn(t, where) {
		if strings.Contains(held, ".json.") {
			t.Errorf("a file being written was left behind: %q", held)
		}
	}
}
