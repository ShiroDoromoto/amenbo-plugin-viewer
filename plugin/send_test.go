package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func sealerForTest(t *testing.T) *sealer {
	t.Helper()
	seal, err := newSealer(base64.RawURLEncoding.EncodeToString(make([]byte, keySize)))
	if err != nil {
		t.Fatal(err)
	}
	return seal
}

func keysOf(records []outgoing) []string {
	keys := make([]string, len(records))
	for i, record := range records {
		keys[i] = record.Key + ":" + record.Op
	}
	return keys
}

// One record can move several times inside one stretch of the ledger, and the phone needs where
// it ended up rather than how it got there.
func TestCollapseKeepsOnlyTheLastWordAboutEachRecord(t *testing.T) {
	read, dropped := collapse([]change{
		{Dataset: "task", RecordID: 1, Op: "insert"},
		{Dataset: "task", RecordID: 1, Op: "update"},
		{Dataset: "task", RecordID: 2, Op: "insert"},
		{Dataset: "task", RecordID: 2, Op: "delete"},
		{Dataset: "task_comment", RecordID: 9, Op: "delete"},
		{Dataset: "task_comment", RecordID: 9, Op: "insert"},
	})

	if got := read["task"]; len(got) != 1 || got[0] != 1 {
		t.Errorf("task ids to read back = %v, want just the one that was not deleted", got)
	}
	if got := read["task_comment"]; len(got) != 1 || got[0] != 9 {
		t.Errorf("a record written after being deleted has to be read back: %v", got)
	}
	if len(dropped) != 1 || dropped[0] != "task/2" {
		t.Errorf("dropped = %v", dropped)
	}
}

// One stretch of the ledger has to produce one body, whatever order the map iteration takes, or
// two runs over the same window would look like two different sends to whatever reads them.
func TestCollapseSettlesOnOneOrder(t *testing.T) {
	changes := []change{
		{Dataset: "task", RecordID: 3, Op: "update"},
		{Dataset: "task", RecordID: 1, Op: "update"},
		{Dataset: "decision", RecordID: 7, Op: "delete"},
		{Dataset: "task", RecordID: 2, Op: "delete"},
	}

	read, dropped := collapse(changes)

	if got := read["task"]; len(got) != 2 || got[0] != 1 || got[1] != 3 {
		t.Errorf("ids came back unsorted: %v", got)
	}
	if len(dropped) != 2 || dropped[0] != "decision/7" || dropped[1] != "task/2" {
		t.Errorf("drops came back unsorted: %v", dropped)
	}
}

// A plugin's secrets are the token and the encryption key themselves. Carrying them would put
// the key inside the thing it encrypts, in a place the user merely rents — so they are left
// behind here rather than on amenbo's promise to keep them back.
func TestASecretIsNeverCarried(t *testing.T) {
	read, dropped := collapse([]change{
		{Dataset: "plugin_secret", RecordID: 1, Op: "insert"},
		{Dataset: "plugin_secret", RecordID: 2, Op: "delete"},
		{Dataset: "task", RecordID: 1, Op: "insert"},
	})

	if _, asked := read["plugin_secret"]; asked {
		t.Error("the plugin's own secrets were queued to be read back and sent")
	}
	if len(dropped) != 0 {
		t.Errorf("a secret was named to the store even as a deletion: %v", dropped)
	}
	if len(read["task"]) != 1 {
		t.Errorf("the rest of the stretch went with it: %v", read)
	}

	records, err := sealWindow(sealerForTest(t), window{Tables: map[string][]json.RawMessage{
		"plugin_secret": {json.RawMessage(`{"id":1,"value":"a-throwaway-token"}`)},
		"task":          {json.RawMessage(`{"id":1}`)},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if got := keysOf(records); len(got) != 1 || got[0] != "task/1:put" {
		t.Errorf("a whole placement carried %v", got)
	}
}

// The ledger names every dataset amenbo holds and the read-back road carries fewer, so a stretch
// touching one of the others must not stop the send: the phone would fall behind for good over a
// row it was never going to receive.
func TestADatasetThatDoesNotTravelIsLeftBehindRatherThanFatal(t *testing.T) {
	changes := []change{
		{Dataset: "attachment", RecordID: 1, Op: "insert"},
		{Dataset: "task", RecordID: 1, Op: "insert"},
	}
	rows := func(dataset string, ids []int64) ([]json.RawMessage, error) {
		if dataset == "attachment" {
			return nil, refused{call: "records", code: codeNotCarried, message: "`attachment` is not a dataset this road carries"}
		}
		return []json.RawMessage{json.RawMessage(`{"id":1}`)}, nil
	}

	var records []outgoing
	_, stderr := capture(t, func() {
		var err error
		records, err = sealChanged(sealerForTest(t), changes, rows)
		if err != nil {
			t.Error(err)
		}
	})

	if got := keysOf(records); len(got) != 1 || got[0] != "task/1:put" {
		t.Errorf("records = %v — the rest of the stretch did not survive", got)
	}
	if !strings.Contains(stderr, "attachment") {
		t.Errorf("what was left behind went unsaid: %q", stderr)
	}
}

// Anything else that goes wrong reading a record back is a failed send, not a record to skip:
// advancing the cursor over it would lose it for good.
func TestAReadThatFailsForAnyOtherReasonStopsTheSend(t *testing.T) {
	rows := func(dataset string, ids []int64) ([]json.RawMessage, error) {
		return nil, refused{call: "records", code: "store_unreadable", message: "the store cannot be opened"}
	}

	if _, err := sealChanged(sealerForTest(t), []change{{Dataset: "task", RecordID: 1, Op: "insert"}}, rows); err == nil {
		t.Error("a failed read was taken for a record that does not travel")
	}
}

// A whole window becomes one record per row, filed under the dataset and the id — the only two
// things about a row this plugin reads.
func TestSealingAWholeWindowMakesOneRecordPerRow(t *testing.T) {
	whole := window{Tables: map[string][]json.RawMessage{
		"task":     {json.RawMessage(`{"id":2,"title":"二件目"}`), json.RawMessage(`{"id":1,"title":"最初の一件"}`)},
		"decision": {json.RawMessage(`{"id":5}`)},
	}}

	records, err := sealWindow(sealerForTest(t), whole)
	if err != nil {
		t.Fatal(err)
	}

	want := []string{"decision/5:put", "task/2:put", "task/1:put"}
	got := keysOf(records)
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("records = %v, want %v", got, want)
	}
	for _, record := range records {
		if record.Nonce == "" || record.Cipher == "" {
			t.Errorf("%s went out without an envelope", record.Key)
		}
	}
}

// A row with nothing to file it under is dropped rather than sent under a key that names
// nothing — the phone matches on that key, so a wrong one is worse than an absent record.
func TestARowWithNoIdIsRefused(t *testing.T) {
	whole := window{Tables: map[string][]json.RawMessage{"task": {json.RawMessage(`{"title":"no id"}`)}}}

	if _, err := sealWindow(sealerForTest(t), whole); err == nil {
		t.Error("a row with no id was filed anyway")
	}
}

// What leaves is the contract's shape, and the token opens the door rather than travelling in
// the body.
func TestAPlacementCarriesTheContractAndTheToken(t *testing.T) {
	var seen struct {
		path   string
		auth   string
		method string
		body   placement
	}
	answering := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen.path, seen.auth, seen.method = r.URL.Path, r.Header.Get("Authorization"), r.Method
		json.NewDecoder(r.Body).Decode(&seen.body)
		w.Write([]byte(`{"seq":42}`))
	}))
	defer answering.Close()

	seq, err := store{url: answering.URL, token: "a-throwaway-token"}.put("/records", placement{
		SpecV:   specVersion,
		Version: 12345,
		Records: []outgoing{{Key: "task/1", Op: "del"}},
	})
	if err != nil {
		t.Fatal(err)
	}

	if seq != 42 {
		t.Errorf("seq = %d", seq)
	}
	if seen.method != http.MethodPut || seen.path != "/records" {
		t.Errorf("%s %s", seen.method, seen.path)
	}
	if seen.auth != "Bearer a-throwaway-token" {
		t.Errorf("Authorization = %q", seen.auth)
	}
	if seen.body.SpecV != specVersion || seen.body.Version != 12345 || len(seen.body.Records) != 1 {
		t.Errorf("body = %+v", seen.body)
	}
}

// A door that refused says why in one sentence, written for whoever has to fix it, and that
// sentence is what reaches the execution log.
func TestARefusalFromTheStoreIsCarriedBack(t *testing.T) {
	refusing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		w.Write([]byte(`{"error":"seq went backwards"}`))
	}))
	defer refusing.Close()

	_, err := store{url: refusing.URL, token: "a-throwaway-token"}.put("/records", placement{})

	if err == nil {
		t.Fatal("a refused send read as a successful one")
	}
	if !strings.Contains(err.Error(), "409") || !strings.Contains(err.Error(), "seq went backwards") {
		t.Errorf("%v says neither what the door answered nor why", err)
	}
}

// A refusal with nothing readable in it is still a refusal. The status is the verdict; the body
// is only there to help.
func TestASilentRefusalIsStillOne(t *testing.T) {
	refusing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer refusing.Close()

	where := store{url: refusing.URL, token: "a-throwaway-token"}

	if _, err := where.put("/records", placement{}); err == nil {
		t.Error("a 401 read as a successful send")
	}
}

// The trailing slash a user leaves on a pasted URL must not become a doubled one in the path.
func TestATrailingSlashOnTheUrlIsNotCarriedIntoThePath(t *testing.T) {
	t.Setenv(envAuthToken, "a-throwaway-token")

	where, err := storeFor(fired("task.done", map[string]any{configWorkerURL: "https://viewer.example.workers.dev/"}))
	if err != nil {
		t.Fatal(err)
	}

	if where.url != "https://viewer.example.workers.dev" {
		t.Errorf("url = %q", where.url)
	}
}
