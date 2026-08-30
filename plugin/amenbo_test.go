package main

import (
	"encoding/json"
	"testing"
)

// The gap has to be recognised as itself. Reported as a failed call it would look like a network
// that is down — something to wait out — when the answer is the opposite: stop reading the
// ledger and place the whole store again.
func TestARefusalIsReadAsAmenboWroteIt(t *testing.T) {
	code, message, refused := refusedWith([]byte(`{"error":{"code":"sync_gap","message":"that cursor is outside the stretch it still speaks for"}}`))

	if !refused {
		t.Fatal("Amenbo's own account of a failure was not recognised as one")
	}
	if code != "sync_gap" {
		t.Errorf("code = %q", code)
	}
	if message == "" {
		t.Error("the sentence for whoever has to fix it went missing")
	}
}

// Anything that is not that account is reported as it came. A binary that is not there and a
// crash both arrive this way, and neither is a code to branch on.
func TestWhatIsNotARefusalIsNotReadAsOne(t *testing.T) {
	for name, wrote := range map[string]string{
		"nothing at all":          "",
		"a sentence":              "Amenbo: command not found",
		"a document with no code": `{"error":{"message":"something"}}`,
		"another document":        `{"project_id":1,"version":7}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, _, refused := refusedWith([]byte(wrote)); refused {
				t.Errorf("%q was taken for Amenbo refusing", wrote)
			}
		})
	}
}

// The id is the one field of a row this plugin reads, and it is what the phone matches on. A row
// without one is refused rather than filed under a key that names nothing.
func TestARowIsReadForItsIdAndNothingElse(t *testing.T) {
	id, err := rowID(json.RawMessage(`{"id":2812,"title":"レコード単位の暗号","notes":""}`))
	if err != nil {
		t.Fatal(err)
	}
	if id != 2812 {
		t.Errorf("id = %d", id)
	}

	if _, err := rowID(json.RawMessage(`{"title":"no id"}`)); err == nil {
		t.Error("a row with no id was accepted")
	}
	if _, err := rowID(json.RawMessage(`not a row`)); err == nil {
		t.Error("something that is not a row was accepted")
	}
}

// The name a record is filed under is the answer's, not the question's. `sync changes` says
// `dependency` and the read-back road answers under `task_dependency`; reading the answer back
// under the asked name found nothing there and called it "no rows" — three months of dependency
// edits never left the machine that way.
func TestRecordsAreReadUnderTheNameTheAnswerFilesThemUnder(t *testing.T) {
	table, rows, err := rowsRead("dependency", []byte(`{"amenbo_sync":{"cursor":9},"tables":{"task_dependency":[{"id":1,"task_id":2}]}}`))
	if err != nil {
		t.Fatal(err)
	}
	if table != "task_dependency" {
		t.Errorf("table = %q, want the one the answer named", table)
	}
	if len(rows) != 1 {
		t.Errorf("rows = %v", rows)
	}
}

// An answer that carries no rows still names its table, which is what lets a delete — the one op
// with nothing to read back — be filed under the same name as the write before it.
func TestAnAnswerWithNoRowsStillNamesItsTable(t *testing.T) {
	table, rows, err := rowsRead("dependency", []byte(`{"tables":{"task_dependency":[]}}`))
	if err != nil {
		t.Fatal(err)
	}
	if table != "task_dependency" || len(rows) != 0 {
		t.Errorf("table = %q, rows = %v", table, rows)
	}
}

// One question is answered by one table. Anything else is a road this build does not read, and
// picking one of them would file half a dataset under a name the phone never sees again.
func TestAnAnswerThatIsNotOneTableIsRefused(t *testing.T) {
	for name, answered := range map[string]string{
		"no table at all": `{"tables":{}}`,
		"two tables":      `{"tables":{"task_dependency":[],"task":[]}}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, _, err := rowsRead("dependency", []byte(answered)); err == nil {
				t.Errorf("%s was read as an answer to one question", name)
			}
		})
	}
}
