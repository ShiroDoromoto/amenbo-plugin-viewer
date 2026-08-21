package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
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
// behind here rather than on Amenbo's promise to keep them back.
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

	records, err := carryWindow(window{Tables: map[string][]json.RawMessage{
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

// The ledger names every dataset Amenbo holds and the read-back road carries fewer, so a stretch
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
		records, err = changedRecords(changes, rows)
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

	if _, err := changedRecords([]change{{Dataset: "task", RecordID: 1, Op: "insert"}}, rows); err == nil {
		t.Error("a failed read was taken for a record that does not travel")
	}
}

// A whole window becomes one record per row, filed under the dataset and the id — the only two
// things about a row this plugin reads. What is built carries the row as it is; the envelope is
// put on at the door of the route that needs one.
func TestCarryingAWholeWindowMakesOneRecordPerRow(t *testing.T) {
	whole := window{Tables: map[string][]json.RawMessage{
		"task":     {json.RawMessage(`{"id":2,"title":"二件目"}`), json.RawMessage(`{"id":1,"title":"最初の一件"}`)},
		"decision": {json.RawMessage(`{"id":5}`)},
	}}

	records, err := carryWindow(whole)
	if err != nil {
		t.Fatal(err)
	}

	want := []string{"decision/5:put", "task/2:put", "task/1:put"}
	got := keysOf(records)
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("records = %v, want %v", got, want)
	}
	for _, record := range records {
		if len(record.Row) == 0 {
			t.Errorf("%s was built without its row", record.Key)
		}
		if record.Nonce != "" || record.Cipher != "" {
			t.Errorf("%s was sealed before any route asked for it", record.Key)
		}
	}
}

// The Worker is somewhere the user merely rents, so nothing reaches it that it could read. The
// sealing happens at that door and nowhere earlier, which is what lets the folder on this machine
// hold the same records open.
func TestTheCloudflareDoorSealsEveryRowOnItsWayOut(t *testing.T) {
	body := placement{SpecV: specVersion, Version: 1, Records: []outgoing{
		{Key: "task/1", Op: opPlaced, Row: json.RawMessage(`{"id":1,"title":"ひみつ"}`)},
		{Key: "task/2", Op: opDeleted},
	}}

	sent, err := store{url: "https://example.invalid", token: "a-throwaway-token", seal: sealerForTest(t)}.sealed(body)
	if err != nil {
		t.Fatal(err)
	}

	if len(sent.Records) != 2 {
		t.Fatalf("records = %d", len(sent.Records))
	}
	placed := sent.Records[0]
	if placed.Nonce == "" || placed.Cipher == "" {
		t.Error("a row went to the Worker without an envelope")
	}
	if len(placed.Row) != 0 {
		t.Error("the row itself went along with the envelope")
	}
	if raw, _ := json.Marshal(sent); strings.Contains(string(raw), "ひみつ") {
		t.Error("what the row said is readable in what was sent")
	}
	// A deletion is the key and no more, so there is nothing there to seal.
	gone := sent.Records[1]
	if gone.Key != "task/2" || gone.Op != opDeleted || gone.Nonce != "" || gone.Cipher != "" {
		t.Errorf("a deletion came out as %+v", gone)
	}
}

// A row with nothing to file it under is dropped rather than sent under a key that names
// nothing — the phone matches on that key, so a wrong one is worse than an absent record.
func TestARowWithNoIdIsRefused(t *testing.T) {
	whole := window{Tables: map[string][]json.RawMessage{"task": {json.RawMessage(`{"title":"no id"}`)}}}

	if _, err := carryWindow(whole); err == nil {
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

// refusing is a route that takes nothing, so what a send does with a route that failed can be
// exercised without standing either real one up.
type refusing struct {
	name string
}

func (r refusing) String() string          { return r.name }
func (r refusing) holdsNothing() bool      { return false }
func (r refusing) place(placement) error   { return errors.New("it did not take it") }
func (r refusing) replace(placement) error { return errors.New("it did not take it") }

// A route that fails does not stop the others: they are two places holding the same records, and
// a phone reading one of them is not waiting on the other. What comes back names every route that
// did not take the records, because a line naming one of two would send the user to the wrong end.
func TestARouteThatFailsDoesNotStopTheOthers(t *testing.T) {
	taken := 0
	taking := stub{took: func() { taken++ }}

	err := carryTo([]route{refusing{name: "the first place"}, taking, refusing{name: "the second place"}}, placement{}, false)

	if taken != 1 {
		t.Error("a route in between two that failed was never carried to")
	}
	if err == nil {
		t.Fatal("routes that took nothing read as a send that landed")
	}
	if !strings.Contains(err.Error(), "the first place") || !strings.Contains(err.Error(), "the second place") {
		t.Errorf("%v names only one of the two that failed", err)
	}
}

// stub is a route that takes whatever it is given.
type stub struct {
	took func()
}

func (s stub) String() string          { return "a place that takes anything" }
func (s stub) holdsNothing() bool      { return false }
func (s stub) place(placement) error   { s.took(); return nil }
func (s stub) replace(placement) error { s.took(); return nil }

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

// A turn that outgrows one request is what a whole placement of any real backlog is, so the send
// has to split it rather than hand the door more than it takes and read back a 413 it can do
// nothing with.
func TestATurnTooBigForOneRequestIsSentInParts(t *testing.T) {
	var seen []placement
	answering := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body placement
		json.NewDecoder(r.Body).Decode(&body)
		seen = append(seen, body)
		w.Write([]byte(`{"seq":0}`))
	}))
	defer answering.Close()

	records := make([]outgoing, recordsPerWrite+1)
	for at := range records {
		records[at] = outgoing{Key: recordKey("task", int64(at)), Op: opDeleted}
	}
	where := store{url: answering.URL, token: "a-throwaway-token", seal: sealerForTest(t)}

	if err := where.place(placement{SpecV: specVersion, Version: 12345, Records: records}); err != nil {
		t.Fatal(err)
	}

	if len(seen) != 2 {
		t.Fatalf("%d request(s) for %d records, want two", len(seen), len(records))
	}
	if got := len(seen[0].Records); got != recordsPerWrite {
		t.Errorf("the first part carried %d records, want a full %d", got, recordsPerWrite)
	}
	if got := len(seen[1].Records); got != 1 {
		t.Errorf("the last part carried %d records, want the one left over", got)
	}
	for at, part := range seen {
		if part.Part != at+1 || part.Parts != len(seen) {
			t.Errorf("part %d of %d says it is %d of %d", at+1, len(seen), part.Part, part.Parts)
		}
		// The version travels on every part: the store writes it down on the last one, and reads
		// a turn carrying a different one as a different turn.
		if part.Version != 12345 || part.SpecV != specVersion {
			t.Errorf("part %d = %+v, want the turn's own version and contract", at+1, part)
		}
	}
}

// The store does not have to know how a turn was split to answer for it: a turn small enough for
// one request is one part of one, and says so rather than saying nothing.
func TestATurnThatFitsIsOnePartOfOne(t *testing.T) {
	var seen placement
	answering := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewDecoder(r.Body).Decode(&seen)
		w.Write([]byte(`{"seq":1}`))
	}))
	defer answering.Close()

	where := store{url: answering.URL, token: "a-throwaway-token", seal: sealerForTest(t)}

	if err := where.place(placement{SpecV: specVersion, Version: 1, Records: []outgoing{{Key: "task/1", Op: opDeleted}}}); err != nil {
		t.Fatal(err)
	}

	if seen.Part != 1 || seen.Parts != 1 {
		t.Errorf("a turn that fits said it was part %d of %d", seen.Part, seen.Parts)
	}
}

// A whole placement of a store that holds nothing is what says the store holds nothing. Sending
// no request at all would leave whatever is there standing, and the phone reading it.
func TestAWholePlacementOfNothingIsStillSent(t *testing.T) {
	var paths []string
	answering := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		w.Write([]byte(`{"seq":0}`))
	}))
	defer answering.Close()

	where := store{url: answering.URL, token: "a-throwaway-token", seal: sealerForTest(t)}

	if err := where.replace(placement{SpecV: specVersion, Version: 1}); err != nil {
		t.Fatal(err)
	}

	if len(paths) != 1 || paths[0] != "/reset" {
		t.Errorf("an empty whole placement sent %v, want the one request that empties", paths)
	}
}

// What has landed stays landed, and the parts after the one that failed are not sent on top of a
// door that is not taking them.
func TestAPartThatFailsStopsTheRestOfTheTurn(t *testing.T) {
	taken := 0
	refusing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		taken++
		if taken == 1 {
			w.Write([]byte(`{"seq":500}`))
			return
		}
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer refusing.Close()

	records := make([]outgoing, recordsPerWrite*2+1)
	for at := range records {
		records[at] = outgoing{Key: recordKey("task", int64(at)), Op: opDeleted}
	}
	where := store{url: refusing.URL, token: "a-throwaway-token", seal: sealerForTest(t)}

	err := where.place(placement{SpecV: specVersion, Version: 1, Records: records})

	if err == nil {
		t.Fatal("a turn whose second part was refused read as a successful one")
	}
	if taken != 2 {
		t.Errorf("%d part(s) were sent, want the send to stop at the one that failed", taken)
	}
}

// A whole placement stops part way through the store, not before it: the routes hold part of a
// backlog, and the cursor remembered from an older send points far beyond the hole. Carrying what
// moved since then would lay this week's edits on top of a store missing its middle, so what a
// failed whole placement leaves behind is nothing — which is the state a first run is in, and a
// first run places the whole store again.
func TestAWholePlacementThatFailedLeavesNothingRemembered(t *testing.T) {
	remembering(t)
	if err := writeState(state{Version: 12345, Cursor: 42}); err != nil {
		t.Fatal(err)
	}

	forgetWhatWasNotPlaced()

	remembered, found, err := readState()
	if err != nil {
		t.Fatal(err)
	}
	if found {
		t.Errorf("a failed whole placement left %+v behind, and the next turn would carry only what moved", remembered)
	}
}
