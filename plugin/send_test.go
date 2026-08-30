package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

// aStoreTaking is a door that takes every part and answers the way a real store does: its
// ordering stands one further on for every record it was handed. What it was sent is written into
// `seen`, in the order it arrived.
func aStoreTaking(seen *[]placement) *httptest.Server {
	standing := int64(0)
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body placement
		json.NewDecoder(r.Body).Decode(&body)
		*seen = append(*seen, body)
		standing += int64(len(body.Records))
		w.Write([]byte(`{"seq":` + strconv.FormatInt(standing, 10) + `}`))
	}))
}

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
	if got := dropped["task"]; len(got) != 1 || got[0] != 2 {
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
	if got := dropped["decision"]; len(got) != 1 || got[0] != 7 {
		t.Errorf("a drop went missing: %v", dropped)
	}
	if got := dropped["task"]; len(got) != 1 || got[0] != 2 {
		t.Errorf("a drop went missing: %v", dropped)
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

// A record is filed under the name the answer came back with, not the one the ledger asked by.
// The two part company at least once — `dependency` is answered as `task_dependency` — and
// filing under the question's name put the same record in the store under two keys, so the phone
// kept a copy no later write could reach.
func TestARecordIsFiledUnderTheNameTheAnswerCameBackWith(t *testing.T) {
	rows := func(dataset string, ids []int64) (string, []json.RawMessage, error) {
		if dataset != "dependency" {
			t.Errorf("the road was asked by %q rather than the name the ledger gave", dataset)
		}
		return "task_dependency", []json.RawMessage{json.RawMessage(`{"id":3}`)}, nil
	}

	records, err := changedRecords([]change{{Dataset: "dependency", RecordID: 3, Op: "insert"}}, rows)
	if err != nil {
		t.Fatal(err)
	}
	if got := keysOf(records); len(got) != 1 || got[0] != "task_dependency/3:put" {
		t.Errorf("records = %v", got)
	}
}

// A delete carries no row, so there is nothing to read back for it — but what it is filed under
// is still the road's to say, or the phone is told to drop a key it was never given. The name is
// asked for once per dataset, and a dataset that was read as well as dropped from asks no more
// than a dataset that was only read.
func TestADeleteIsFiledUnderTheSameNameAWriteWouldBe(t *testing.T) {
	for name, changes := range map[string][]change{
		"nothing but deletes": {
			{Dataset: "dependency", RecordID: 3, Op: "delete"},
			{Dataset: "dependency", RecordID: 4, Op: "delete"},
		},
		"a delete beside a write": {
			{Dataset: "dependency", RecordID: 3, Op: "delete"},
			{Dataset: "dependency", RecordID: 9, Op: "insert"},
			{Dataset: "dependency", RecordID: 4, Op: "delete"},
		},
	} {
		t.Run(name, func(t *testing.T) {
			asked := 0
			rows := func(dataset string, ids []int64) (string, []json.RawMessage, error) {
				asked++
				var back []json.RawMessage
				for _, id := range ids {
					if id == 9 {
						back = append(back, json.RawMessage(`{"id":9}`))
					}
				}
				return "task_dependency", back, nil
			}

			records, err := changedRecords(changes, rows)
			if err != nil {
				t.Fatal(err)
			}
			if asked != 1 {
				t.Errorf("the road was asked %d times for one dataset", asked)
			}
			for _, key := range keysOf(records) {
				if !strings.HasPrefix(key, "task_dependency/") {
					t.Errorf("a record travelled as %q, under a name the phone does not file it by", key)
				}
			}
			if got := keysOf(records); got[len(got)-1] != "task_dependency/4:del" {
				t.Errorf("the drops did not come last and sorted: %v", got)
			}
		})
	}
}

// A dataset the road will not answer for cannot be dropped either: without a name from the road
// there is no key to name, and one guessed from the ledger is the very copy this fix removes.
func TestADeleteInADatasetThatDoesNotTravelIsLeftBehindToo(t *testing.T) {
	rows := func(dataset string, ids []int64) (string, []json.RawMessage, error) {
		return "", nil, refused{call: "records", code: codeNotCarried, message: "`attachment` is not a dataset this road carries"}
	}

	var records []outgoing
	_, stderr := capture(t, func() {
		var err error
		records, err = changedRecords([]change{{Dataset: "attachment", RecordID: 1, Op: "delete"}}, rows)
		if err != nil {
			t.Error(err)
		}
	})

	if len(records) != 0 {
		t.Errorf("records = %v — a key was guessed from the ledger's own word", keysOf(records))
	}
	if !strings.Contains(stderr, "attachment") {
		t.Errorf("what was left behind went unsaid: %q", stderr)
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
	rows := func(dataset string, ids []int64) (string, []json.RawMessage, error) {
		if dataset == "attachment" {
			return "", nil, refused{call: "records", code: codeNotCarried, message: "`attachment` is not a dataset this road carries"}
		}
		return dataset, []json.RawMessage{json.RawMessage(`{"id":1}`)}, nil
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
	rows := func(dataset string, ids []int64) (string, []json.RawMessage, error) {
		return "", nil, refused{call: "records", code: "store_unreadable", message: "the store cannot be opened"}
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

	took, err := store{url: answering.URL, token: "a-throwaway-token"}.put("/records", placement{
		SpecV:   specVersion,
		Version: 12345,
		Records: []outgoing{{Key: "task/1", Op: "del"}},
	})
	if err != nil {
		t.Fatal(err)
	}

	if took.seq != 42 {
		t.Errorf("seq = %d", took.seq)
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
	called string
}

func (r refusing) name() string       { return r.called }
func (r refusing) String() string     { return r.called }
func (r refusing) holdsNothing() bool { return false }
func (r refusing) place(placement) (written, error) {
	return written{}, errors.New("it did not take it")
}

// A route that fails does not stop the others: they are two places holding the same records, and
// a phone reading one of them is not waiting on the other. What comes back names every route that
// did not take the records, because a line naming one of two would send the user to the wrong end.
func TestARouteThatFailsDoesNotStopTheOthers(t *testing.T) {
	taking := &stub{called: "a place that takes anything"}
	routes := []route{refusing{called: "the first place"}, taking, refusing{called: "the second place"}}

	_, _, err := carryTurn(routes, 2, false, levelAt(1, 7, routes...), oneChange(t))

	if taking.placed != 1 {
		t.Errorf("a route in between two that failed was carried to %d time(s)", taking.placed)
	}
	if err == nil {
		t.Fatal("routes that took nothing read as a send that landed")
	}
	if !strings.Contains(err.Error(), "the first place") || !strings.Contains(err.Error(), "the second place") {
		t.Errorf("%v names only one of the two that failed", err)
	}
}

// stub is a route that takes whatever it is given, and counts what it was handed. It answers an
// ordering that moves the way a store's does — one per record — so a turn checked against the
// answer reads as one that landed.
type stub struct {
	called string
	empty  bool
	placed int
	// seq is where this place's ordering stands. A test that hands the send a memory saying the
	// place was left at a number seeds it here too, since the check the send makes is between the
	// two — a stub standing somewhere else would read as a store that dropped the turn.
	seq  int64
	sent []placement
}

func (s *stub) name() string       { return s.called }
func (s *stub) String() string     { return s.called }
func (s *stub) holdsNothing() bool { return s.empty }
func (s *stub) place(body placement) (written, error) {
	s.placed++
	s.sent = append(s.sent, body)
	s.seq += int64(len(body.Records))
	// **Three rows a record is the shape, not the number.** What a write costs is the database's
	// to say and it varies by key; what a test needs is a cost that is not zero, so the budget
	// this fills can be watched filling.
	return written{seq: s.seq, rows: int64(len(body.Records)) * 3}, nil
}

// levelAt is a memory that has every named route reading on from the same place.
func levelAt(version, cursor int64, routes ...route) state {
	left := state{Routes: map[string]carried{}}
	for _, where := range routes {
		left.Routes[where.name()] = carried{Version: version, Cursor: cursor}
	}
	return left
}

// oneChange is a ledger holding one record that moved, and a whole picture holding the same one.
func oneChange(t *testing.T) ledger {
	t.Helper()
	return ledger{
		changed: func(cursor int64) ([]change, int64, error) {
			return []change{{Dataset: "task", RecordID: 1, Op: "update"}}, cursor + 1, nil
		},
		rows: func(dataset string, _ []int64) (string, []json.RawMessage, error) {
			return dataset, []json.RawMessage{json.RawMessage(`{"id":1}`)}, nil
		},
		whole: func() (window, error) {
			picture := window{Tables: map[string][]json.RawMessage{"task": {json.RawMessage(`{"id":1}`)}}}
			picture.Header.Cursor = 99
			return picture, nil
		},
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

// A queue that outgrows one request is what a whole store is on any real backlog, so the drain
// has to split it rather than hand the door more than it takes and read back a 413 it can do
// nothing with.
func TestAQueueTooBigForOneRequestIsSentInParts(t *testing.T) {
	var seen []placement
	answering := aStoreTaking(&seen)
	defer answering.Close()

	where := store{url: answering.URL, token: "a-throwaway-token", seal: sealerForTest(t)}

	left, _, err := drainTo(where, carried{Pending: keysToDrop(recordsPerWrite + 1)}, 12345, rightNow())

	if err != nil {
		t.Fatal(err)
	}
	if len(left.Pending) != 0 {
		t.Errorf("%d record(s) were left queued after a drain that landed", len(left.Pending))
	}

	if len(seen) != 2 {
		t.Fatalf("%d request(s) for %d records, want two", len(seen), recordsPerWrite+1)
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

	if _, _, err := drainTo(where, carried{Pending: keysToDrop(1)}, 1, rightNow()); err != nil {
		t.Fatal(err)
	}

	if seen.Part != 1 || seen.Parts != 1 {
		t.Errorf("a turn that fits said it was part %d of %d", seen.Part, seen.Parts)
	}
}

// **There is one door, and every record goes through it.** The other emptied the store before
// taking the whole of it, and both ends have let it go — a store emptied to be filled again is one
// a phone cannot read for as long as the filling takes, and a filling nobody finished shuts it for
// good. Nothing here reaches for it any more, whatever it is carrying.
func TestEveryRequestGoesToTheDoorThatPlacesOverWhatIsThere(t *testing.T) {
	var paths []string
	answering := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		w.Write([]byte(`{"seq":0}`))
	}))
	defer answering.Close()

	where := store{url: answering.URL, token: "a-throwaway-token", seal: sealerForTest(t)}

	if _, err := where.place(placement{SpecV: specVersion, Version: 1}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := drainTo(where, carried{Pending: keysToDrop(1)}, 2, rightNow()); err != nil {
		t.Fatal(err)
	}

	if len(paths) != 2 || paths[0] != "/records" || paths[1] != "/records" {
		t.Errorf("the requests went to %v, want the one door that places over what is there", paths)
	}
}

// The store is told which key opens what it is being handed, so a phone can find out that its own
// key does not fit without fetching a backlog it cannot open a row of.
func TestEveryPlacementNamesTheKeyItWasSealedWith(t *testing.T) {
	var seen []placement
	answering := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body placement
		json.NewDecoder(r.Body).Decode(&body)
		seen = append(seen, body)
		w.Write([]byte(`{"seq":0}`))
	}))
	defer answering.Close()

	seal := sealerForTest(t)
	where := store{url: answering.URL, token: "a-throwaway-token", seal: seal}

	if _, err := where.place(placement{SpecV: specVersion, Version: 1, Records: []outgoing{{Key: "task/1", Op: opDeleted}}}); err != nil {
		t.Fatal(err)
	}
	// A turn carrying nothing names it too: what the store is told sealed these records is the
	// key that sealed them, and there being none of them does not make the answer a different one.
	if _, err := where.place(placement{SpecV: specVersion, Version: 2}); err != nil {
		t.Fatal(err)
	}

	if len(seen) != 2 {
		t.Fatalf("%d request(s), want both of them", len(seen))
	}
	for at, body := range seen {
		if body.KeyFingerprint != seal.fingerprint {
			t.Errorf("request %d named %q, want the key it was sealed with", at+1, body.KeyFingerprint)
		}
	}
}

// It travels on every part for the reason the version does: the store writes it down with the
// last one, and a part that named nothing would settle a store as sealed with no key at all.
func TestTheKeyIsNamedOnEveryPartOfATurn(t *testing.T) {
	var seen []placement
	answering := aStoreTaking(&seen)
	defer answering.Close()

	seal := sealerForTest(t)
	where := store{url: answering.URL, token: "a-throwaway-token", seal: seal}

	if _, _, err := drainTo(where, carried{Pending: keysToDrop(recordsPerWrite + 1)}, 1, rightNow()); err != nil {
		t.Fatal(err)
	}

	if len(seen) != 2 {
		t.Fatalf("%d request(s) for %d records, want two", len(seen), recordsPerWrite+1)
	}
	for at, part := range seen {
		if part.KeyFingerprint != seal.fingerprint {
			t.Errorf("part %d named %q, want the key the turn was sealed with", at+1, part.KeyFingerprint)
		}
	}
}

// **What the door took is dropped and what it would not take is kept.** The parts after the one
// that failed are not sent on top of a door that is not taking them, and everything from it
// onwards stays queued for the next turn — a refusal costs the turn and no records.
func TestAPartThatFailsStopsTheRestAndKeepsWhatItCouldNotSend(t *testing.T) {
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

	where := store{url: refusing.URL, token: "a-throwaway-token", seal: sealerForTest(t)}

	left, landed, err := drainTo(where, carried{Pending: keysToDrop(recordsPerWrite*2 + 1)}, 1, rightNow())

	if err == nil {
		t.Fatal("a drain whose second part was refused read as a successful one")
	}
	if taken != 2 {
		t.Errorf("%d part(s) were sent, want the send to stop at the one that failed", taken)
	}
	if landed != recordsPerWrite {
		t.Errorf("%d record(s) were reported as landed, want the one part that did", landed)
	}
	if len(left.Pending) != recordsPerWrite+1 {
		t.Errorf("%d record(s) were left queued, want everything from the part that failed onwards", len(left.Pending))
	}
	if left.Pending[0].Key != recordKey("task", recordsPerWrite) {
		t.Errorf("the queue starts at %q, want the first record the door would not take", left.Pending[0].Key)
	}
}

// keysToDrop is a queue of that many deletes, which is the cheapest record to make a lot of: what
// these tests are about is how a queue is cut up and what happens to the pieces, not what is in
// them.
func keysToDrop(many int) []outgoing {
	queued := make([]outgoing, many)
	for at := range queued {
		queued[at] = outgoing{Key: recordKey("task", int64(at)), Op: opDeleted}
	}
	return queued
}

// **A whole store that could not be sent is kept, not forgotten.** The place holds part of a
// backlog and the rest is still queued, so the next turn offers the rest of the same records
// rather than reading the whole store out a second time. What the old shape did here — throw the
// route's place away so a first run would build it again — cost a whole placement for every
// refusal, and a place refusing everything for a day cost one a minute.
func TestAWholeStoreThatCouldNotBeSentIsKeptQueued(t *testing.T) {
	failing := refusing{called: "a place that will not take it"}
	beside := &stub{called: "a place that takes anything"}
	routes := []route{failing, beside}

	_, settled, err := carryTurn(routes, 2, false, state{Routes: map[string]carried{
		failing.name(): {Version: 1, Cursor: 7},
		beside.name():  {Version: 1, Cursor: 7},
	}}, gapping(t))

	if err == nil {
		t.Fatal("a whole placement that was refused read as one that landed")
	}
	left, remembered := settled.Routes[failing.name()]
	if !remembered {
		t.Fatal("a route that would not take the whole store lost its place, and the whole store would be read out again")
	}
	if len(left.Pending) == 0 {
		t.Error("the whole store it would not take was dropped rather than kept for the next turn")
	}
	if left.Cursor != 99 {
		t.Errorf("the route that failed was left at %+v, want the picture's cursor — it was read out, whatever the place did", left)
	}
	if beside := settled.Routes[beside.name()]; beside.Cursor != 99 || len(beside.Pending) != 0 {
		t.Errorf("the route beside it was left at %+v, want it read out and sent", beside)
	}
}

// gapping is a ledger that no longer reaches back to where the routes left off, which is what
// sends a turn to the whole picture instead.
func gapping(t *testing.T) ledger {
	t.Helper()
	from := oneChange(t)
	from.changed = func(int64) ([]change, int64, error) { return nil, 0, errSyncGap }
	return from
}

// asking is a ledger that remembers which stretches it was asked for, so a turn can be checked
// for reading one stretch once however many routes are waiting on it.
func asking(t *testing.T, asked *[]int64) ledger {
	t.Helper()
	from := oneChange(t)
	from.changed = func(cursor int64) ([]change, int64, error) {
		*asked = append(*asked, cursor)
		return []change{{Dataset: "task", RecordID: 1, Op: "update"}}, cursor + 1, nil
	}
	return from
}

// The whole point of keeping a place per route: a route that will not take anything must not hold
// the one beside it where it stands. A user whose Worker is gone still has a folder that takes
// every record, and its memory has to move with it.
func TestARouteThatFailsKeepsItsPlaceAndTheOthersMoveOn(t *testing.T) {
	failing := refusing{called: "cloudflare"}
	beside := &stub{called: "icloud"}
	routes := []route{failing, beside}

	_, settled, err := carryTurn(routes, 2, false, levelAt(1, 7, routes...), oneChange(t))

	if err == nil {
		t.Fatal("a route that took nothing read as a send that landed")
	}
	// **Both were read out**, because reading is answerable to the ledger's window and not to a
	// door: the one that failed keeps the records in its queue instead of keeping the cursor.
	if left := settled.Routes["cloudflare"]; left.Cursor != 8 || len(left.Pending) != 1 {
		t.Errorf("the route that failed was left at %+v, want the stretch read out and still queued", left)
	}
	if left := settled.Routes["icloud"]; left.Cursor != 8 || left.Version != 2 || len(left.Pending) != 0 {
		t.Errorf("the route that took it was left at %+v, want it moved on and its queue empty", left)
	}
}

// And on the turn after that, the two are reading from different places — which is the state the
// old one-cursor-for-everything memory could not hold at all.
func TestTwoRoutesThatHaveDriftedApartAreEachReadFromWhereTheyAre(t *testing.T) {
	var asked []int64
	behind := &stub{called: "cloudflare"}
	ahead := &stub{called: "icloud"}

	_, settled, err := carryTurn([]route{behind, ahead}, 3, false, state{Routes: map[string]carried{
		"cloudflare": {Version: 1, Cursor: 7},
		"icloud":     {Version: 2, Cursor: 8},
	}}, asking(t, &asked))

	if err != nil {
		t.Fatal(err)
	}
	if len(asked) != 2 || asked[0] != 7 || asked[1] != 8 {
		t.Errorf("the ledger was asked for %v, want each route's own stretch, in order", asked)
	}
	if settled.Routes["cloudflare"].Cursor != 8 || settled.Routes["icloud"].Cursor != 9 {
		t.Errorf("settled at %+v", settled.Routes)
	}
}

// Two routes standing in the same place is the ordinary case, and it costs one read, not two —
// reading the ledger is the expensive half of a turn and the hook fires on every write.
func TestOneStretchIsReadOnceHoweverManyRoutesAreWaitingOnIt(t *testing.T) {
	var asked []int64
	first := &stub{called: "cloudflare"}
	second := &stub{called: "icloud"}
	routes := []route{first, second}

	placed, _, err := carryTurn(routes, 2, false, levelAt(1, 7, routes...), asking(t, &asked))

	if err != nil {
		t.Fatal(err)
	}
	if len(asked) != 1 {
		t.Errorf("the ledger was asked %d times for one stretch: %v", len(asked), asked)
	}
	if first.placed != 1 || second.placed != 1 {
		t.Errorf("placed %d and %d times", first.placed, second.placed)
	}
	// What is reported is what reached a place, counted per place: the two drains are separate,
	// and one that landed while the other was refused is a turn that did put a record somewhere.
	if placed != 2 {
		t.Errorf("one record carried to two routes was reported as %d", placed)
	}
}

// A route that has just appeared is placed whole while the one beside it takes only what moved.
// The folder comes into being when the user first opens the app on their phone, which can be any
// number of sends after this plugin started counting.
func TestARouteThatHoldsNothingIsPlacedWholeWhileTheOtherTakesTheDifference(t *testing.T) {
	fresh := &stub{called: "icloud", empty: true}
	going := &stub{called: "cloudflare"}
	routes := []route{fresh, going}

	_, settled, err := carryTurn(routes, 2, false, levelAt(1, 7, routes...), oneChange(t))

	if err != nil {
		t.Fatal(err)
	}
	// **Both go through the one door that places over what is there.** A store emptied to be
	// filled again is one a phone cannot read for as long as the filling takes, and the filling
	// is the slow half.
	if fresh.placed != 1 || going.placed != 1 {
		t.Errorf("the route holding nothing was sent to %d times and the one already going %d", fresh.placed, going.placed)
	}
	if len(fresh.sent) != 1 || fresh.sent[0].Records[0].Key != recordKey("task", 1) {
		t.Errorf("the route holding nothing was handed %+v, want the whole picture", fresh.sent)
	}
	if settled.Routes["icloud"].Cursor != 99 {
		t.Errorf("the whole placement was remembered at %+v, want the picture's own cursor", settled.Routes["icloud"])
	}
	if settled.Routes["cloudflare"].Cursor != 8 {
		t.Errorf("the difference was remembered at %+v", settled.Routes["cloudflare"])
	}
}

// A route already level with the version is not read for and not written to. Saying so costs
// nothing, and the hook fires on every write.
func TestARouteThatIsLevelIsLeftAlone(t *testing.T) {
	var asked []int64
	level := &stub{called: "icloud"}

	placed, _, err := carryTurn([]route{level}, 1, false, levelAt(1, 7, level), asking(t, &asked))

	if err != nil || placed != 0 {
		t.Fatalf("placed %d, err %v", placed, err)
	}
	if len(asked) != 0 || level.placed != 0 {
		t.Errorf("a level route cost %v reads and %d sends", asked, level.placed)
	}
}

// Asked out loud, a level route is read for anyway — that is what `push` is: the way to shift
// something the version guard cannot see.
func TestALevelRouteIsCarriedToWhenItIsAskedForOutLoud(t *testing.T) {
	level := &stub{called: "icloud"}

	placed, _, err := carryTurn([]route{level}, 1, true, levelAt(1, 7, level), oneChange(t))

	if err != nil {
		t.Fatal(err)
	}
	if placed != 1 || level.placed != 1 {
		t.Errorf("push placed %d record(s) over %d send(s)", placed, level.placed)
	}
}

// The size of a real backlog, as the store that went to iCloud held it — the count of files that
// landed in that folder, to the record. It is the number this route has never been run at: every
// part of the split is tested at two records, and what broke on the other route broke only once
// there were twenty thousand.
//
// **It is not a round one on purpose.** A backlog that divides evenly into writes never sends a
// part that is short, and the last part of a real turn always is.
const aRealBacklog = 20202

// wholeOf is a ledger whose picture is a backlog of the given size, spread over the datasets a
// store actually has. The rows are the smallest thing that carries an id, because what is inside
// them never leaves this plugin unread.
func wholeOf(t *testing.T, records int) ledger {
	t.Helper()
	datasets := []string{"task", "task_comment", "task_dimension_value", "decision"}
	tables := map[string][]json.RawMessage{}
	for at := range records {
		dataset := datasets[at%len(datasets)]
		tables[dataset] = append(tables[dataset], json.RawMessage(`{"id":`+strconv.Itoa(at)+`}`))
	}
	from := oneChange(t)
	// The ledger no longer reaches back to where any route left off, which is one of the three
	// ways a whole placement is asked for — the other two being a first run and a reset. A route
	// that had a place would otherwise be carried the difference, which is not what this is about.
	from.changed = func(int64) ([]change, int64, error) { return nil, 0, errSyncGap }
	from.whole = func() (window, error) {
		picture := window{Tables: tables}
		picture.Header.Cursor = 99
		return picture, nil
	}
	return from
}

// aStoreAtVolume answers the way the Worker does for a whole placement, and refuses everything the
// Worker refuses. A stand-in that took anything would let a turn pass here and fail in the user's
// own account, which is the one place nobody is watching.
type aStoreAtVolume struct {
	t     *testing.T
	took  map[string]int
	parts []placement
	// wentToAnotherDoor counts the requests that arrived anywhere but the one door records go
	// through. There is only one now, and a turn reaching for another would be a turn asking a
	// store to close itself.
	wentToAnotherDoor int
	// seq is where its ordering stands, which the Worker moves on by one per record it writes and
	// answers with. Emptying does not wind it back there, so it does not here either.
	seq int64
}

func (s *aStoreAtVolume) handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var body placement
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, `{"error":"unreadable"}`, http.StatusBadRequest)
			return
		}
		// The Worker's own cap. Sending more is a 413 there, and a turn that split wrongly would
		// find that out in the user's account rather than here.
		if len(body.Records) > recordsPerWrite {
			http.Error(w, `{"error":"too many records"}`, http.StatusRequestEntityTooLarge)
			return
		}
		if r.URL.Path != "/records" {
			s.wentToAnotherDoor++
		}
		for _, record := range body.Records {
			s.took[record.Key]++
		}
		s.parts = append(s.parts, body)
		s.seq += int64(len(body.Records))
		w.Write([]byte(`{"seq":` + strconv.FormatInt(s.seq, 10) + `}`))
	}
}

// The whole of a real backlog reaches the store, once each, in parts the store will take.
//
// **This is the run that was never made on the other route.** Twenty thousand records went into
// the iCloud folder in four seconds and 8883 of them were never picked up, while the plugin
// recorded the send as done — because writing was taken for arriving. This route answers, so the
// same question has an answer here: every key the picture held is one the store said it took.
func TestAWholeBacklogReachesTheStoreOnceEach(t *testing.T) {
	answered := &aStoreAtVolume{t: t, took: map[string]int{}}
	answering := httptest.NewServer(answered.handler())
	defer answering.Close()

	where := store{url: answering.URL, token: "a-throwaway-token", seal: sealerForTest(t)}
	placed, settled, err := carryTurn([]route{where}, 7, false, state{}, wholeOf(t, aRealBacklog))
	if err != nil {
		t.Fatal(err)
	}

	if placed != aRealBacklog {
		t.Errorf("the turn placed %d records, want the whole backlog of %d", placed, aRealBacklog)
	}
	if len(answered.took) != aRealBacklog {
		t.Errorf("the store holds %d keys, want %d — records were lost between the picture and the door", len(answered.took), aRealBacklog)
	}
	for key, times := range answered.took {
		if times != 1 {
			t.Fatalf("%s reached the store %d times, want once", key, times)
		}
	}
	// **Nothing is emptied.** The whole store goes through the door that places over what is
	// there, so the door a phone reads through never closes — which is what a store emptied to be
	// filled again does for as long as the filling takes.
	if answered.wentToAnotherDoor != 0 {
		t.Errorf("%d request(s) went somewhere other than the one door records go through", answered.wentToAnotherDoor)
	}
	if want := (aRealBacklog + recordsPerWrite - 1) / recordsPerWrite; len(answered.parts) != want {
		t.Errorf("the turn went in %d parts, want %d of at most %d records", len(answered.parts), want, recordsPerWrite)
	}
	for at, part := range answered.parts {
		if part.Part != at+1 || part.Parts != len(answered.parts) {
			t.Errorf("part %d says it is %d of %d", at+1, part.Part, part.Parts)
		}
		if part.Version != 7 || part.SpecV != specVersion {
			t.Errorf("part %d = version %d spec %d, want the turn's own", at+1, part.Version, part.SpecV)
		}
	}
	if left := settled.Routes[where.name()]; left.Cursor != 99 || left.Version != 7 {
		t.Errorf("the route was left at %+v, want the whole picture's own cursor and version", left)
	}
}

// A backlog that stops part way through leaves the rest of it queued, so the next turn carries
// the quarter that did not land rather than the whole store a second time.
//
// **This is what the queue is for.** The old shape had to throw the route's place away here — the
// store held three quarters of a backlog and the cursor pointed past the hole — which cost a
// whole placement for every refusal. What did not land never left the queue, so there is no hole
// to place over.
func TestABacklogCutOffPartWayKeepsTheRestQueued(t *testing.T) {
	answered := &aStoreAtVolume{t: t, took: map[string]int{}}
	takes := answered.handler()
	stopAfter := 30
	answering := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if len(answered.parts) >= stopAfter {
			http.Error(w, `{"error":"this store could not answer: D1_ERROR: Exceeded maximum DB size"}`,
				http.StatusServiceUnavailable)
			return
		}
		takes(w, r)
	}))
	defer answering.Close()

	where := store{url: answering.URL, token: "a-throwaway-token", seal: sealerForTest(t)}
	_, settled, err := carryTurn([]route{where}, 7, false, state{Routes: map[string]carried{
		where.name(): {Version: 1, Cursor: 7},
	}}, wholeOf(t, aRealBacklog))

	if err == nil {
		t.Fatal("a backlog that was refused part way through read as one that landed")
	}
	left, remembered := settled.Routes[where.name()]
	if !remembered {
		t.Fatal("a route holding three quarters of a backlog lost its place, and the whole store would be read out again")
	}
	if want := aRealBacklog - stopAfter*recordsPerWrite; len(left.Pending) != want {
		t.Errorf("%d record(s) were left queued, want the %d that never left", len(left.Pending), want)
	}
	if len(answered.parts) != stopAfter {
		t.Errorf("the turn went on to %d parts, want it to stop at the refusal on %d", len(answered.parts), stopAfter)
	}
}

// A turn carries the backlog's own version, which is what tells the store one turn from the next.
func TestATurnCarriesTheBacklogsOwnVersion(t *testing.T) {
	where := &stub{called: "cloudflare"}

	where.seq = 40
	_, settled, err := carryTurn([]route{where}, 9, false, state{Routes: map[string]carried{
		where.name(): {Version: 1, Cursor: 7, Placed: 1, Seq: 40},
	}}, oneChange(t))

	if err != nil {
		t.Fatal(err)
	}
	if len(where.sent) != 1 || where.sent[0].Version != 9 {
		t.Errorf("the turn carried %+v, want the backlog's own version", where.sent)
	}
	if left := settled.Routes[where.name()]; left.Placed != 9 || left.Seq != 41 {
		t.Errorf("the route was left at %+v, want the number it placed and the ordering the store answered", left)
	}
}

// **The number the store is already standing at is the one number a turn may not carry.** The
// store drops a turn whose version it already holds and answers `200` to it, so a turn sent under
// that number is a turn that writes nothing and reads as one that landed — which is how a record
// went missing for three months, and what kills every `push` sent while the backlog has not moved.
func TestATurnTheStoreIsAlreadyStandingAtCarriesTheNextNumber(t *testing.T) {
	where := &stub{called: "cloudflare"}

	// Asked for by hand, with nothing having moved in the backlog since the last send: the
	// version to carry and the number the store is standing at are the same one.
	where.seq = 5
	_, settled, err := carryTurn([]route{where}, 49460, true, state{Routes: map[string]carried{
		where.name(): {Version: 49460, Cursor: 7, Placed: 49460, Seq: 5},
	}}, oneChange(t))

	if err != nil {
		t.Fatal(err)
	}
	if len(where.sent) != 1 || where.sent[0].Version != 49461 {
		t.Errorf("the turn carried %+v, want one past the number the store is standing at", where.sent)
	}
	// The backlog's own version is remembered beside it: it is what says whether there is
	// anything to do, and the number sent is what says what the store is standing at.
	if left := settled.Routes[where.name()]; left.Version != 49460 || left.Placed != 49461 {
		t.Errorf("the route was left at %+v, want the backlog's version and the number placed", left)
	}
}

// And the turn after that goes back to the backlog's own number, which the store is no longer
// standing at — so the two never settle on one number and neither is ever dropped.
func TestTheTurnAfterThatCarriesTheBacklogsNumberAgain(t *testing.T) {
	where := &stub{called: "cloudflare"}

	where.seq = 6
	_, settled, err := carryTurn([]route{where}, 49460, true, state{Routes: map[string]carried{
		where.name(): {Version: 49460, Cursor: 7, Placed: 49461, Seq: 6},
	}}, oneChange(t))

	if err != nil {
		t.Fatal(err)
	}
	if len(where.sent) != 1 || where.sent[0].Version != 49460 {
		t.Errorf("the turn carried %+v, want the backlog's own number back", where.sent)
	}
	if left := settled.Routes[where.name()]; left.Placed != 49460 {
		t.Errorf("the route was left at %+v", left)
	}
}

// A turn that was refused is not remembered, so the one sent in its place carries the same number
// — which is the repeat the store's guard is there to recognise, and it still recognises it.
func TestATurnSentAgainAfterARefusalCarriesTheSameNumber(t *testing.T) {
	refused := refusing{called: "cloudflare"}

	_, settled, err := carryTurn([]route{refused}, 9, false, state{Routes: map[string]carried{
		refused.name(): {Version: 1, Cursor: 7, Placed: 1, Seq: 40},
	}}, oneChange(t))

	if err == nil {
		t.Fatal("a route that took nothing read as a send that landed")
	}
	if left := settled.Routes[refused.name()]; left.Placed != 1 || left.Seq != 40 {
		t.Errorf("a turn that landed nowhere was remembered as placed: %+v", left)
	}
}

// A stretch holding nothing to carry sends no request, so it leaves nothing standing anywhere —
// the cursor moves and what the store was left at is carried over untouched.
func TestAStretchWithNothingToCarryLeavesTheStoreWhereItStands(t *testing.T) {
	where := &stub{called: "cloudflare"}
	empty := oneChange(t)
	empty.changed = func(cursor int64) ([]change, int64, error) { return nil, cursor + 5, nil }

	_, settled, err := carryTurn([]route{where}, 9, false, state{Routes: map[string]carried{
		where.name(): {Version: 1, Cursor: 7, Placed: 1, Seq: 40},
	}}, empty)

	if err != nil {
		t.Fatal(err)
	}
	if len(where.sent) != 0 {
		t.Errorf("a stretch holding nothing sent %d request(s)", len(where.sent))
	}
	if left := settled.Routes[where.name()]; left.Cursor != 12 || left.Placed != 1 || left.Seq != 40 {
		t.Errorf("the route was left at %+v, want the cursor moved and the store's own place kept", left)
	}
}

// **A store that answers `200` and wrote nothing is the failure this send has to see.** The
// ordering it answers with stands one further on per record it wrote, so a turn that was taken in
// and dropped is one whose answer did not move — and calling that a send is how a backlog loses
// records nobody comes looking for.
func TestAStoreThatAnsweredWithoutWritingIsNotTakenAsASend(t *testing.T) {
	dropping := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"seq":500}`))
	}))
	defer dropping.Close()

	where := store{url: dropping.URL, token: "a-throwaway-token", seal: sealerForTest(t)}
	_, settled, err := carryTurn([]route{where}, 9, false, state{Routes: map[string]carried{
		where.name(): {Version: 1, Cursor: 7, Placed: 1, Seq: 500},
	}}, oneChange(t))

	if err == nil {
		t.Fatal("a store that wrote nothing read as one that took the turn")
	}
	if !strings.Contains(err.Error(), "did not write it") {
		t.Errorf("%v does not say what happened", err)
	}
	// The stretch was read out, so the cursor moved; what the store would not write is still in
	// the queue, which is where the next turn gets it from.
	if left := settled.Routes[where.name()]; len(left.Pending) != 1 || left.Placed != 1 {
		t.Errorf("the route was left at %+v, want the record still queued and the place unmoved", left)
	}
}

// The same check inside one turn: the parts after the first are read against the answer the first
// came back with, so a turn dropped half way through is seen without anything being remembered.
func TestAPartThatWasNotWrittenIsSeenPartWayThroughATurn(t *testing.T) {
	taken := 0
	dropping := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		taken++
		w.Write([]byte(`{"seq":500}`))
	}))
	defer dropping.Close()

	where := store{url: dropping.URL, token: "a-throwaway-token", seal: sealerForTest(t)}

	left, _, err := drainTo(where, carried{Pending: keysToDrop(recordsPerWrite * 3)}, 1, rightNow())

	if err == nil {
		t.Fatal("a drain whose parts were dropped read as one that landed")
	}
	if taken != 2 {
		t.Errorf("%d part(s) were sent, want the drain to stop at the one that was not written", taken)
	}
	// The first part's answer is what made the second one checkable, so only that first part is
	// taken as landed and everything after it stays queued.
	if len(left.Pending) != recordsPerWrite*2 {
		t.Errorf("%d record(s) were left queued, want everything from the part that was dropped onwards", len(left.Pending))
	}
}

// A store nothing has ever been written into stands at nothing, and there is no telling that from
// a place this machine has not been told about. Neither has anything behind it to have been
// dropped, and the answer either of them comes back with is what makes the next turn checkable.
func TestAPlaceWhoseOrderingIsNotKnownIsStillSentTo(t *testing.T) {
	var seen []placement
	answering := aStoreTaking(&seen)
	defer answering.Close()

	where := store{url: answering.URL, token: "a-throwaway-token", seal: sealerForTest(t)}
	left, _, err := drainTo(where, carried{Seq: orderingUnknown, Pending: keysToDrop(1)}, 1, rightNow())

	if err != nil {
		t.Fatal(err)
	}
	if left.Seq != 1 {
		t.Errorf("the store was left standing at %d, want where its answer put it", left.Seq)
	}
}

// A memory written before this build names no number of its own, and the first turn after an
// upgrade is exactly the one that must not be dropped: what that build placed was the backlog's
// version, so that is what the store is standing at.
func TestAMemoryFromBeforeThisBuildStillSaysWhatTheStoreIsStandingAt(t *testing.T) {
	where := &stub{called: "cloudflare"}

	// Placed and Seq are what an older build never wrote, so they come back as nothing.
	_, _, err := carryTurn([]route{where}, 49460, true, state{Routes: map[string]carried{
		where.name(): {Version: 49460, Cursor: 7},
	}}, oneChange(t))

	if err != nil {
		t.Fatal(err)
	}
	if len(where.sent) != 1 || where.sent[0].Version != 49461 {
		t.Errorf("the turn carried %+v, want one past the number that build placed", where.sent)
	}
}

// A place nothing has been put into from here is not one the store can be standing at on our
// account, so the first turn carries the backlog's own version and names it truthfully.
func TestAFirstTurnCarriesTheBacklogsVersionAsItIs(t *testing.T) {
	if got := theNumberToSend(49460, carried{}); got != 49460 {
		t.Errorf("a first turn carried %d, want the backlog's own version", got)
	}
}

// **A queue left over from a refusal is offered again even when nothing has moved since.** The
// version guard is about reading, not sending: a route the backlog has nothing new for may still
// be holding everything the last turn could not land, and a turn that skipped it over the version
// would leave those records where they are until somebody edits something.
func TestAQueueLeftFromARefusalIsOfferedAgainWithNothingNewToRead(t *testing.T) {
	var asked []int64
	where := &stub{called: "cloudflare"}

	placed, settled, err := carryTurn([]route{where}, 1, false, state{Routes: map[string]carried{
		where.name(): {Version: 1, Cursor: 7, Pending: keysToDrop(2)},
	}}, asking(t, &asked))

	if err != nil {
		t.Fatal(err)
	}
	if len(asked) != 0 {
		t.Errorf("a route level with the backlog was read for: %v", asked)
	}
	if placed != 2 || len(where.sent) != 1 {
		t.Errorf("the queue was sent as %d record(s) in %d request(s), want both in one", placed, len(where.sent))
	}
	if left := settled.Routes[where.name()]; len(left.Pending) != 0 {
		t.Errorf("%d record(s) were left queued after a turn that landed", len(left.Pending))
	}
}

// **What is copied out goes behind what is already queued, and the whole of it goes in one
// order.** The place is addressed by key and a later write lands on top of an earlier one, so the
// order the records are offered in is the order the store ends up agreeing with.
func TestWhatIsCopiedOutGoesBehindWhatIsAlreadyQueued(t *testing.T) {
	where := &stub{called: "cloudflare"}

	_, _, err := carryTurn([]route{where}, 2, false, state{Routes: map[string]carried{
		where.name(): {Version: 1, Cursor: 7, Pending: []outgoing{{Key: "task/9", Op: opDeleted}}},
	}}, oneChange(t))

	if err != nil {
		t.Fatal(err)
	}
	if len(where.sent) != 1 {
		t.Fatalf("the queue went in %d request(s), want one", len(where.sent))
	}
	sent := where.sent[0].Records
	if len(sent) != 2 || sent[0].Key != "task/9" || sent[1].Key != recordKey("task", 1) {
		t.Errorf("the queue was sent as %+v, want what was already there first", sent)
	}
}

// **A whole picture goes behind the queue too, and does not replace it.** The picture says what
// the store holds now, so a record it does not name is one the backlog no longer has — but the
// place still does, and the only thing that will say so is a delete already in the queue.
func TestAWholePictureDoesNotThrowAwayTheDeletesAlreadyQueued(t *testing.T) {
	where := &stub{called: "cloudflare"}

	_, _, err := carryTurn([]route{where}, 2, false, state{Routes: map[string]carried{
		where.name(): {Version: 1, Cursor: 7, Pending: []outgoing{{Key: "task/9", Op: opDeleted}}},
	}}, gapping(t))

	if err != nil {
		t.Fatal(err)
	}
	if len(where.sent) != 1 {
		t.Fatalf("the queue went in %d request(s), want one", len(where.sent))
	}
	sent := where.sent[0].Records
	if len(sent) != 2 || sent[0].Key != "task/9" {
		t.Errorf("the queue was sent as %+v, want the delete the picture cannot express kept in front", sent)
	}
}

// **The cursor moves whether or not the place took anything.** That is the whole of what the two
// halves are for: the ledger's window turns, so what is not read out of it in time is not read at
// all, and a place refusing everything must not hold the reading where it stands.
func TestTheCursorMovesEvenWhenNothingCouldBeSent(t *testing.T) {
	where := refusing{called: "cloudflare"}

	_, settled, err := carryTurn([]route{where}, 2, false, levelAt(1, 7, where), oneChange(t))

	if err == nil {
		t.Fatal("a route that took nothing read as a send that landed")
	}
	left := settled.Routes[where.name()]
	if left.Cursor != 8 || left.Version != 2 {
		t.Errorf("the route was left at %+v, want the stretch read out however the door answered", left)
	}
	if len(left.Pending) != 1 {
		t.Errorf("%d record(s) were queued, want the stretch nobody took", len(left.Pending))
	}
}

// **A queue that emptied part way leaves the place standing where it already was.** The store
// writes the version down with the last part alone, so a turn that stopped before it left the
// store at the number it was at — and remembering the number this turn carried would be a note
// about a write that never happened.
func TestAQueueThatEmptiedPartWayDoesNotMoveWhereThePlaceStands(t *testing.T) {
	taken := 0
	refusingAfterOne := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		taken++
		if taken == 1 {
			w.Write([]byte(`{"seq":500}`))
			return
		}
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer refusingAfterOne.Close()

	where := store{url: refusingAfterOne.URL, token: "a-throwaway-token", seal: sealerForTest(t)}

	left, _, err := drainTo(where, carried{Placed: 3, Seq: 0, Pending: keysToDrop(recordsPerWrite + 1)}, 9, rightNow())

	if err == nil {
		t.Fatal("a drain that stopped part way read as one that landed")
	}
	if left.Placed != 3 {
		t.Errorf("the place was left standing at %d, want the number it was already at", left.Placed)
	}
	if left.Seq != 500 {
		t.Errorf("the ordering was left at %d, want where the part that landed put it", left.Seq)
	}
}

// A route with nothing queued costs no request at all: the hook fires on every write, and a turn
// that found nothing to say should say nothing.
func TestARouteWithAnEmptyQueueIsNotSentTo(t *testing.T) {
	where := &stub{called: "cloudflare"}

	left, landed, err := drainTo(where, carried{Version: 1, Cursor: 7}, 1, rightNow())

	if err != nil || landed != 0 {
		t.Fatalf("landed %d, err %v", landed, err)
	}
	if where.placed != 0 {
		t.Errorf("an empty queue cost %d request(s)", where.placed)
	}
	if left.Placed != 0 {
		t.Errorf("an empty queue moved where the place stands to %d", left.Placed)
	}
}
