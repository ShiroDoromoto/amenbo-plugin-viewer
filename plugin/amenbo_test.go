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
		t.Fatal("amenbo's own account of a failure was not recognised as one")
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
		"a sentence":              "amenbo: command not found",
		"a document with no code": `{"error":{"message":"something"}}`,
		"another document":        `{"project_id":1,"version":7}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, _, refused := refusedWith([]byte(wrote)); refused {
				t.Errorf("%q was taken for amenbo refusing", wrote)
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
