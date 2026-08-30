package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// aStoreHolding is a door that answers the reading side: it hands out a read token, pages back
// the keys it is holding, and takes that token away again. What it was asked with is written into
// `asked`, so a test can see that the reading did not go out under the writing token.
func aStoreHolding(held []outgoing, perPage int, asked *[]string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*asked = append(*asked, r.Method+" "+r.URL.Path+"?"+r.URL.RawQuery+
			" as "+strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
		switch {
		case r.Method == http.MethodPut && r.URL.Path == "/tokens":
			w.Write([]byte(`{"issued_at":"2026-08-30"}`))
		case r.Method == http.MethodGet && r.URL.Path == "/meta":
			w.Write([]byte(`{"seq":` + strconv.Itoa(len(held)) + `}`))
		case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/tokens/"):
			w.WriteHeader(http.StatusOK)
		case r.Method == http.MethodGet && r.URL.Path == "/records":
			since, _ := strconv.Atoi(r.URL.Query().Get("since"))
			page := held[min(since, len(held)):min(since+perPage, len(held))]
			records := make([]map[string]string, 0, len(page))
			for _, record := range page {
				records = append(records, map[string]string{"k": record.Key, "op": record.Op})
			}
			json.NewEncoder(w).Encode(map[string]any{
				"seq":     since + len(page),
				"more":    since+len(page) < len(held),
				"records": records,
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

func placedAt(keys ...string) []outgoing {
	held := make([]outgoing, len(keys))
	for at, key := range keys {
		held[at] = outgoing{Key: key, Op: opPlaced}
	}
	return held
}

// **What is missing is what the store is not holding as a record**, and a key it is holding as a
// deletion is one of those: a `del` row is the phone having been told to throw the record away,
// so a record that is here and filed there as gone has fallen out of the phone's copy exactly the
// way one that never arrived has.
func TestTheDifferenceCountsADeletedKeyAsMissing(t *testing.T) {
	here := []outgoing{
		{Key: "task/1", Op: opPlaced, Row: json.RawMessage(`{"id":1}`)},
		{Key: "task/2", Op: opPlaced, Row: json.RawMessage(`{"id":2}`)},
	}
	held := map[string]string{"task/1": opPlaced, "task/2": opDeleted}

	missing, gone := theDifference(here, held)

	if got := keysOf(missing); len(got) != 1 || got[0] != "task/2:put" {
		t.Errorf("missing = %v, want the one the store has filed as deleted", got)
	}
	if len(gone) != 0 {
		t.Errorf("nothing is left over here, and %v came back", keysOf(gone))
	}
}

// A key the store holds that this machine no longer has is a deletion nobody carried, and the
// cure is the deletion — not a reset, which would shut the door the phone reads through.
func TestTheDifferenceDropsWhatIsNoLongerHere(t *testing.T) {
	here := []outgoing{{Key: "task/1", Op: opPlaced, Row: json.RawMessage(`{"id":1}`)}}
	held := map[string]string{"task/1": opPlaced, "task/9": opPlaced, "task/4": opPlaced}

	missing, gone := theDifference(here, held)

	if len(missing) != 0 {
		t.Errorf("nothing is missing here, and %v came back", keysOf(missing))
	}
	// Settled rather than walked out of the map, so one drift produces one queue however many
	// times it is worked out.
	if got := keysOf(gone); strings.Join(got, ",") != "task/4:del,task/9:del" {
		t.Errorf("gone = %v, want both in one settled order", got)
	}
}

// The reading goes out under a token this run issued and gave up again, because the token this
// plugin writes with is refused at the reading door — that refusal is what lets one phone be cut
// off without touching the rest, and this must not be the thing that erodes it.
func TestTheKeysAreReadUnderATokenThatIsIssuedAndCutOffAgain(t *testing.T) {
	var asked []string
	shop := aStoreHolding(placedAt("task/1", "task/2", "task/3", "task/4", "task/5"), 2, &asked)
	defer shop.Close()

	holds, err := store{url: shop.URL, token: "the-write-token"}.whatItHolds()

	if err != nil {
		t.Fatal(err)
	}
	if len(holds.keys) != 5 {
		t.Errorf("held %d keys, and the store was holding 5 over three pages: %v", len(holds.keys), holds.keys)
	}
	if holds.seq != 5 {
		t.Errorf("the store stands at %d, and it answered 5", holds.seq)
	}
	if !strings.HasPrefix(asked[0], "PUT /tokens?") {
		t.Errorf("the first call was %q, and a read has to be issued a token first", asked[0])
	}
	if last := asked[len(asked)-1]; !strings.HasPrefix(last, "DELETE /tokens/amenbo-repair-") {
		t.Errorf("the last call was %q, and the token this issued has to be cut off again", last)
	}
	for _, call := range asked {
		if strings.HasPrefix(call, "GET ") && strings.HasSuffix(call, "as the-write-token") {
			t.Errorf("%q read under the writing token", call)
		}
		if strings.HasPrefix(call, "GET /records") && !strings.Contains(call, "keys=1") {
			t.Errorf("%q asked for the envelopes as well as the keys", call)
		}
	}
}

// aLedgerHolding is this machine's picture, without an Amenbo behind it.
func aLedgerHolding(keys ...string) ledger {
	tables := map[string][]json.RawMessage{}
	for _, key := range keys {
		dataset, id, _ := strings.Cut(key, "/")
		tables[dataset] = append(tables[dataset], json.RawMessage(`{"id":`+id+`}`))
	}
	return ledger{whole: func() (window, error) {
		whole := window{Tables: tables}
		whole.Header.Cursor = 77
		return whole, nil
	}}
}

// **Counting writes nothing.** The first press is the one that says what the second will spend,
// and a count that queued would have spent it before anybody was told the number.
func TestCountingTheDriftQueuesNothing(t *testing.T) {
	remembering(t)
	if err := writeState(rememberedAt(12, 34)); err != nil {
		t.Fatal(err)
	}

	put, del, err := comparedWith(aLedgerHolding("task/1", "task/2"),
		holding{keys: map[string]string{"task/3": opPlaced}, seq: 40}, false)

	if err != nil {
		t.Fatal(err)
	}
	if put != 2 || del != 1 {
		t.Errorf("counted %d to place and %d to drop, want 2 and 1", put, del)
	}
	left, _, err := readState()
	if err != nil {
		t.Fatal(err)
	}
	if queued := left.Routes[routeCloudflare].Pending; len(queued) != 0 {
		t.Errorf("counting queued %v", keysOf(queued))
	}
}

// **The cursor is not moved and the queue is not replaced.** Nothing was read out of the ledger,
// so no stretch has been dealt with; and what was already queued is what an earlier turn could
// not land, which this has no business dropping.
func TestQueueingTheDriftLeavesTheCursorAndWhatWasAlreadyQueued(t *testing.T) {
	remembering(t)
	before := rememberedAt(12, 34)
	before.Routes[routeCloudflare] = carried{Version: 12, Cursor: 34, Placed: 12, Seq: 9,
		Pending: []outgoing{{Key: "task/8", Op: opPlaced}}}
	if err := writeState(before); err != nil {
		t.Fatal(err)
	}

	put, del, err := comparedWith(aLedgerHolding("task/1"),
		holding{keys: map[string]string{"task/5": opPlaced}, seq: 40}, true)

	if err != nil {
		t.Fatal(err)
	}
	if put != 1 || del != 1 {
		t.Errorf("queued %d to place and %d to drop, want 1 and 1", put, del)
	}
	left, _, err := readState()
	if err != nil {
		t.Fatal(err)
	}
	one := left.Routes[routeCloudflare]
	if one.Cursor != 34 || one.Version != 12 || one.Placed != 12 {
		t.Errorf("the comparison moved where the ledger had been read to: %+v", one)
	}
	// **Where the store stands is the store's answer, not the memory's.** A store something else
	// wrote into stands past what was remembered, and every send after that fails the check its
	// own answer is measured by — so a comparison that left the old number would report a drift
	// it had just made permanent.
	if one.Seq != 40 {
		t.Errorf("the ordering was left at %d, and the store answered it stands at 40", one.Seq)
	}
	if got := keysOf(one.Pending); strings.Join(got, ",") != "task/8:put,task/1:put,task/5:del" {
		t.Errorf("queue = %v, want what was already there in front of what the drift found", got)
	}
}

// A press is answered by the number it was shown, and the number stands only as long as the store
// it was counted from is still the store that would be written to.
func TestACountShownStandsForAWhileAndThenIsCountedAgain(t *testing.T) {
	dir := remembering(t)

	if theRepairAsked() {
		t.Error("nothing has been shown, and the next press is being read as the one that spends it")
	}
	if err := rememberTheRepairAsked(3, 1); err != nil {
		t.Fatal(err)
	}
	if !theRepairAsked() {
		t.Error("a count was shown a moment ago and the next press is not the one that sends it")
	}

	stale, err := json.Marshal(repairAsked{V: stateVersion, Put: 3, Del: 1,
		AskedAt: time.Now().Add(-repairAskWindow - time.Minute).UTC().Format(time.RFC3339)})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, repairAskedName), stale, 0o600); err != nil {
		t.Fatal(err)
	}
	if theRepairAsked() {
		t.Error("a count shown long ago is still being spent, and the store has moved on since")
	}

	forgetTheRepairAsked()
	if theRepairAsked() {
		t.Error("the record survived being forgotten, so one press would send twice")
	}
}

// Pressing it before the Worker exists is the ordinary way to arrive here, and what a reader with
// no terminal needs is the button to press rather than the command to type.
func TestRepairSaysWhichButtonStandsTheRouteUp(t *testing.T) {
	remembering(t)

	err := repair(input{}, nil)

	if err == nil {
		t.Fatal("a repair with no route to compare against came back as done")
	}
	if !strings.Contains(err.Error(), english[phTheSetupButton]) {
		t.Errorf("%q does not name the button that makes one", err)
	}
}
