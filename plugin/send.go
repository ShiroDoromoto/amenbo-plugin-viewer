package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

// The send: work out what the phone is missing, and put it where the phone reads.
//
// The ordinary turn carries only what moved. Every write moves the store version, so one cheap
// question answers "is there anything to do", and the ledger answers "what" — which is why the
// whole window is taken only on a first run, on a reset, and after a gap.
//
// **What is placed is what the store holds, one record per row, encrypted here.** The store the
// records land in is one the user rents, so it is treated as somewhere that can read what it is
// given: it gets ciphertext and an ordering, and nothing that says what any of it means.

// specVersion is the version of the shared contract these records are written to. It is not
// amenbo's format version: this one moves when the four parts change what they say to each
// other, and the phone refuses a version it does not read rather than guessing.
const specVersion = 1

// idsPerRead is how many records are asked for at once. A read answers a page of changes at
// most, and a page is 500.
const idsPerRead = 500

// sendTimeout bounds one call to the store. A hook nobody is waiting on must still end: amenbo
// fires the plugin per write, so one call left hanging on a network that is not answering would
// be joined by the next write's, and the next.
const sendTimeout = 30 * time.Second

// errNoRoute is the Cloudflare route not being pointed anywhere. It is a sentinel because the
// two faces answer it differently: the hook stays quiet (a user who has not set it up is not
// failing at anything), and `push` says so (someone asked for a send out loud).
var errNoRoute = errors.New("the Cloudflare route is not configured — run setup")

// outgoing is one record as it travels: the key it is filed under, what happened to it, and —
// for everything but a delete — the envelope holding it.
type outgoing struct {
	Key    string `json:"k"`
	Op     string `json:"op"`
	Nonce  string `json:"n,omitempty"`
	Cipher string `json:"c,omitempty"`
}

// placement is the body of a send. The version travels with it so the store can recognise a
// repeat of what it already holds, and refuse an ordering that went backwards.
type placement struct {
	SpecV   int        `json:"spec_v"`
	Version int64      `json:"version"`
	Records []outgoing `json:"records"`
}

// recordKey is what a row is filed under: its dataset and its id, as one string. The store is
// told nothing about what either half means — to it this is a key and no more, which is what
// keeps amenbo's schema out of a place the user merely rents.
func recordKey(dataset string, id int64) string {
	return dataset + "/" + strconv.FormatInt(id, 10)
}

// neverCarried names what does not leave this machine whatever amenbo hands over.
//
// A plugin's secrets are the Cloudflare token and the encryption key themselves. Carrying them
// would put the key inside the thing it encrypts, in a place the user merely rents — so this
// plugin refuses them on its own account, rather than resting on amenbo keeping them back.
var neverCarried = map[string]bool{"plugin_secret": true}

// sealRows turns the rows of one dataset into records to place. A row with no id is dropped
// rather than filed under a key that names nothing.
func sealRows(seal *sealer, dataset string, rows []json.RawMessage) ([]outgoing, error) {
	placed := make([]outgoing, 0, len(rows))
	for _, raw := range rows {
		id, err := rowID(raw)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", dataset, err)
		}
		nonce, cipher := seal.seal(raw)
		placed = append(placed, outgoing{Key: recordKey(dataset, id), Op: "put", Nonce: nonce, Cipher: cipher})
	}
	return placed, nil
}

// sealWindow turns a whole picture of the store into the records that replace what is there.
// The datasets are walked in name order so that two runs over one window place the same thing.
func sealWindow(seal *sealer, whole window) ([]outgoing, error) {
	datasets := make([]string, 0, len(whole.Tables))
	for dataset := range whole.Tables {
		datasets = append(datasets, dataset)
	}
	sort.Strings(datasets)

	var placed []outgoing
	for _, dataset := range datasets {
		if neverCarried[dataset] {
			continue
		}
		sealed, err := sealRows(seal, dataset, whole.Tables[dataset])
		if err != nil {
			return nil, err
		}
		placed = append(placed, sealed...)
	}
	return placed, nil
}

// collapse reduces a stretch of the ledger to what has to be carried.
//
// One record can move several times inside one stretch, and the phone needs where it ended up,
// not how it got there — so the last word about a record is the only one kept. A record deleted
// after being written is a delete; one written after being deleted is a write.
//
// What comes back is the ids to read back per dataset, and the keys to drop, both in a settled
// order so one stretch always produces one body.
func collapse(changes []change) (read map[string][]int64, dropped []string) {
	last := make(map[string]string)
	for _, moved := range changes {
		last[recordKey(moved.Dataset, moved.RecordID)] = moved.Op
	}

	read = make(map[string][]int64)
	for _, moved := range changes {
		if neverCarried[moved.Dataset] {
			continue
		}
		key := recordKey(moved.Dataset, moved.RecordID)
		op, unsettled := last[key]
		if !unsettled {
			continue
		}
		delete(last, key)
		if op == opDelete {
			dropped = append(dropped, key)
			continue
		}
		read[moved.Dataset] = append(read[moved.Dataset], moved.RecordID)
	}
	for dataset := range read {
		sort.Slice(read[dataset], func(a, b int) bool { return read[dataset][a] < read[dataset][b] })
	}
	sort.Strings(dropped)
	return read, dropped
}

// readBack is how the rows behind a stretch of the ledger are fetched. It is a parameter so the
// walk over a stretch can be exercised without a store standing behind it — what it stands for
// in a running plugin is always rowsIn.
type readBack func(dataset string, ids []int64) ([]json.RawMessage, error)

// sealChanged reads back what moved and seals it, alongside the deletes that need no read.
//
// An id that comes back absent is one that went away between the ledger naming it and this read
// — it is left out rather than guessed at, because the change that says so is still ahead of the
// cursor and will carry the delete on the next turn.
//
// **A dataset the road cannot answer for is left behind, not fatal.** The ledger names every
// dataset amenbo holds and the read-back road carries fewer, so a stretch touching one of the
// others would otherwise stop every send after it — the phone would fall behind for good over a
// row it was never going to receive.
func sealChanged(seal *sealer, changes []change, rows readBack) ([]outgoing, error) {
	read, dropped := collapse(changes)

	datasets := make([]string, 0, len(read))
	for dataset := range read {
		datasets = append(datasets, dataset)
	}
	sort.Strings(datasets)

	var placed []outgoing
	for _, dataset := range datasets {
		ids := read[dataset]
		for start := 0; start < len(ids); start += idsPerRead {
			end := min(start+idsPerRead, len(ids))
			read, err := rows(dataset, ids[start:end])
			var turnedDown refused
			if errors.As(err, &turnedDown) && turnedDown.code == codeNotCarried {
				logf("%s: %s does not travel, so it is being left behind — %s", pluginName, dataset, turnedDown.message)
				break
			}
			if err != nil {
				return nil, err
			}
			sealed, err := sealRows(seal, dataset, read)
			if err != nil {
				return nil, err
			}
			placed = append(placed, sealed...)
		}
	}
	for _, key := range dropped {
		placed = append(placed, outgoing{Key: key, Op: "del"})
	}
	return placed, nil
}

// store is the place the records are put: the user's own Worker, and the token that opens its
// writing door.
type store struct {
	url   string
	token string
}

// storeFor names the Cloudflare route, or says it is not one. Half a route is not a route — a
// URL with no token is refused at the door on every send, so it is nothing to keep retrying.
func storeFor(in input) (store, error) {
	url := strings.TrimRight(in.setting(configWorkerURL), "/")
	token := secret(envAuthToken)
	if url == "" || token == "" {
		return store{}, errNoRoute
	}
	return store{url: url, token: token}, nil
}

// put sends one body to one door and reads the ordering the store answered with.
//
// **No diagnostic here carries the token or anything the body held.** What comes back from a
// refusal is the store's own sentence, which is written for whoever has to fix it.
func (s store) put(path string, body placement) (int64, error) {
	raw, err := json.Marshal(body)
	if err != nil {
		return 0, err
	}
	request, err := http.NewRequest(http.MethodPut, s.url+path, bytes.NewReader(raw))
	if err != nil {
		return 0, err
	}
	request.Header.Set("Authorization", "Bearer "+s.token)
	request.Header.Set("Content-Type", "application/json")

	answer, err := (&http.Client{Timeout: sendTimeout}).Do(request)
	if err != nil {
		return 0, fmt.Errorf("%s did not answer: %w", path, err)
	}
	defer answer.Body.Close()

	var said struct {
		Seq   int64  `json:"seq"`
		Error string `json:"error"`
	}
	decoded := json.NewDecoder(answer.Body).Decode(&said)
	if answer.StatusCode < 200 || answer.StatusCode > 299 {
		if decoded == nil && said.Error != "" {
			return 0, fmt.Errorf("%s answered %d: %s", path, answer.StatusCode, said.Error)
		}
		return 0, fmt.Errorf("%s answered %d", path, answer.StatusCode)
	}
	if decoded != nil {
		return 0, fmt.Errorf("%s answered %d with something this build cannot read: %w", path, answer.StatusCode, decoded)
	}
	return said.Seq, nil
}

// carry runs one turn of the send and says how many records it placed.
//
// The turn is guarded by the version: nothing moved means nothing to do, and saying so costs one
// question. `force` is what `push` passes — someone asked out loud, so the guard is skipped and
// the ledger is read even when the version says the phone is level.
func carry(in input, force bool) (int, error) {
	where, err := storeFor(in)
	if err != nil {
		return 0, err
	}
	seal, err := newSealer(secret(envEncryptionKey))
	if err != nil {
		return 0, err
	}

	version := in.Version
	if version == nil {
		asked, err := storeVersion()
		if err != nil {
			return 0, err
		}
		version = &asked
	}

	remembered, found, err := readState()
	if err != nil {
		return 0, err
	}
	if found && !force && remembered.Version == *version {
		return 0, nil
	}

	if found {
		placed, cursor, err := carryChanged(where, seal, remembered.Cursor, *version)
		if !errors.Is(err, errSyncGap) {
			if err != nil {
				return 0, err
			}
			return placed, writeState(state{Version: *version, Cursor: cursor})
		}
		logf("%s: the ledger no longer reaches back to where this plugin left off — placing the whole store again", pluginName)
	}

	placed, cursor, err := carryWhole(where, seal, *version)
	if err != nil {
		return 0, err
	}
	return placed, writeState(state{Version: *version, Cursor: cursor})
}

// carryChanged places what moved since the cursor, and hands back the cursor to remember.
//
// A stretch that turns out to hold nothing to carry is still a turn: the cursor moves, so the
// next one does not read it again.
func carryChanged(where store, seal *sealer, cursor, version int64) (int, int64, error) {
	changes, moved, err := changesSince(cursor)
	if err != nil {
		return 0, 0, err
	}
	records, err := sealChanged(seal, changes, rowsIn)
	if err != nil {
		return 0, 0, err
	}
	if len(records) == 0 {
		return 0, moved, nil
	}
	if _, err := where.put("/records", placement{SpecV: specVersion, Version: version, Records: records}); err != nil {
		return 0, 0, err
	}
	return len(records), moved, nil
}

// carryWhole empties the store and places everything, which is what a first run, a reset and a
// gap all come down to.
//
// The version is read before the picture is taken, never after: a write landing in between makes
// the remembered version one turn stale, which costs a turn that finds nothing. Remembering a
// version newer than the picture would instead skip whatever landed in that gap, and the phone
// would never learn of it.
func carryWhole(where store, seal *sealer, version int64) (int, int64, error) {
	whole, err := wholeWindow()
	if err != nil {
		return 0, 0, err
	}
	records, err := sealWindow(seal, whole)
	if err != nil {
		return 0, 0, err
	}
	if _, err := where.put("/reset", placement{SpecV: specVersion, Version: version, Records: records}); err != nil {
		return 0, 0, err
	}
	return len(records), whole.Header.Cursor, nil
}
