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
// **What is placed is what the store holds, one record per row.** How much of it a route may read
// is the route's own answer, and the two differ because the places do: the Worker runs somewhere
// the user merely rents, so it is handed ciphertext and an ordering and nothing that says what any
// of it means. The iCloud folder is the user's own device and their own account, guarded the way
// the desktop store is — so it holds the rows as they are, and needs no key to be issued before a
// mac and an iPhone can talk.

// specVersion is the version of the shared contract these records are written to. It is not
// Amenbo's format version: this one moves when the four parts change what they say to each
// other, and the phone refuses a version it does not read rather than guessing.
const specVersion = 1

// idsPerRead is how many records are asked for at once. A read answers a page of changes at
// most, and a page is 500.
const idsPerRead = 500

// recordsPerWrite is how many records one write to the Worker may carry. It is the Worker's own
// limit, kept here so that too much is split before it is sent rather than refused at the door —
// a `413` is nothing the send can do anything with once the bytes are already on the wire.
//
// **The two ends have to agree on this number.** They are built together and deployed together
// (the Worker's script is baked into this binary), so the place to keep them level is the gate,
// which sends a body of exactly this size and reads the refusal back.
const recordsPerWrite = 500

// sendTimeout bounds one call to the store. A hook nobody is waiting on must still end: Amenbo
// fires the plugin per write, so one call left hanging on a network that is not answering would
// be joined by the next write's, and the next.
const sendTimeout = 30 * time.Second

// errNoRoute is there being nowhere to put anything: no Worker stood up, and no iCloud folder.
// It is a sentinel because the two faces answer it differently: the hook stays quiet (a user who
// has not set anything up is not failing at anything), and `push` says so (someone asked for a
// send out loud).
var errNoRoute = errors.New("there is nowhere to put anything yet — run setup for the Cloudflare route, or open Amenbo Viewer once on an iPhone for the mac's iCloud folder to appear")

// What can happen to a record on its way out: it now holds something, or it is gone. These are
// the contract's words, and both routes write them — the Worker into a row, the drop into a file.
const (
	opPlaced  = "put"
	opDeleted = "del"
)

// outgoing is one record as it travels: the key it is filed under, what happened to it, and — for
// everything but a delete — the row itself, either sealed in an envelope or written as it is.
//
// A record is built open and stays that way until a route that cannot be trusted with it puts it
// in an envelope (see `store.sealed`). Exactly one of `Row` and the `Nonce`/`Cipher` pair is ever
// on the wire.
type outgoing struct {
	Key    string          `json:"k"`
	Op     string          `json:"op"`
	Row    json.RawMessage `json:"r,omitempty"`
	Nonce  string          `json:"n,omitempty"`
	Cipher string          `json:"c,omitempty"`
}

// placement is the body of a send. The version travels with it so the store can recognise a
// repeat of what it already holds, and refuse an ordering that went backwards.
//
// A send that does not fit in one request is split, and `Part` of `Parts` is how the store is told
// which piece of one turn it is holding — which part empties, which part settles the version, and
// which parts are neither. They are only filled in by the route that has a limit; the folder is
// handed the whole of a turn at once and has no use for them.
type placement struct {
	SpecV   int        `json:"spec_v"`
	Version int64      `json:"version"`
	Part    int        `json:"part,omitempty"`
	Parts   int        `json:"parts,omitempty"`
	Records []outgoing `json:"records"`
}

// recordKey is what a row is filed under: its dataset and its id, as one string. The store is
// told nothing about what either half means — to it this is a key and no more, which is what
// keeps Amenbo's schema out of a place the user merely rents.
func recordKey(dataset string, id int64) string {
	return dataset + "/" + strconv.FormatInt(id, 10)
}

// neverCarried names what does not leave this machine whatever Amenbo hands over.
//
// A plugin's secrets are the Cloudflare token and the encryption key themselves. Carrying them
// would put the key inside the thing it encrypts, in a place the user merely rents — so this
// plugin refuses them on its own account, rather than resting on Amenbo keeping them back.
var neverCarried = map[string]bool{"plugin_secret": true}

// carryRows turns the rows of one dataset into records to place. A row with no id is dropped
// rather than filed under a key that names nothing.
func carryRows(dataset string, rows []json.RawMessage) ([]outgoing, error) {
	placed := make([]outgoing, 0, len(rows))
	for _, raw := range rows {
		id, err := rowID(raw)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", dataset, err)
		}
		placed = append(placed, outgoing{Key: recordKey(dataset, id), Op: opPlaced, Row: raw})
	}
	return placed, nil
}

// carryWindow turns a whole picture of the store into the records that replace what is there.
// The datasets are walked in name order so that two runs over one window place the same thing.
func carryWindow(whole window) ([]outgoing, error) {
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
		carried, err := carryRows(dataset, whole.Tables[dataset])
		if err != nil {
			return nil, err
		}
		placed = append(placed, carried...)
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

// changedRecords reads back what moved, alongside the deletes that need no read.
//
// An id that comes back absent is one that went away between the ledger naming it and this read
// — it is left out rather than guessed at, because the change that says so is still ahead of the
// cursor and will carry the delete on the next turn.
//
// **A dataset the road cannot answer for is left behind, not fatal.** The ledger names every
// dataset Amenbo holds and the read-back road carries fewer, so a stretch touching one of the
// others would otherwise stop every send after it — the phone would fall behind for good over a
// row it was never going to receive.
func changedRecords(changes []change, rows readBack) ([]outgoing, error) {
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
			carried, err := carryRows(dataset, read)
			if err != nil {
				return nil, err
			}
			placed = append(placed, carried...)
		}
	}
	for _, key := range dropped {
		placed = append(placed, outgoing{Key: key, Op: opDeleted})
	}
	return placed, nil
}

// route is a place the records are put. There are two, and they are not modes to choose between:
// the same records go to both, so a mac user with an iPhone at home and an Android phone at work
// is reading one backlog through two doors.
//
// **The keys and the version are the send's, not the route's**, which is what keeps the two ends
// from drifting into two contracts. What each route adds is only what its destination demands: the
// Cloudflare one seals the rows on the way out, because that place is rented rather than owned.
type route interface {
	// String names the route in a diagnostic, in the user's own words for it.
	String() string
	// holdsNothing says the place has never been written into, so it needs the whole window
	// rather than what moved since the last send.
	holdsNothing() bool
	// place puts what moved.
	place(placement) error
	// replace makes the place hold exactly what it is given, and nothing that was there before.
	replace(placement) error
}

// routesFor names every route that is open. None is not a failure: a plugin that is installed and
// enabled, with no Worker stood up and no folder yet, is waiting rather than broken.
func routesFor(in input) []route {
	var open []route
	if there, err := dropFor(); err == nil {
		open = append(open, there)
	}
	if where, err := storeFor(in); err == nil {
		// The key is what the Worker route is allowed to send with, and only it: the folder is
		// this machine's own. A route standing without one is worth a line — the send goes on to
		// the other one, and silence here would read as the Worker being up to date.
		seal, err := newSealer(secret(envEncryptionKey))
		if err != nil {
			logf("%s: the Cloudflare route is standing but nothing can be sent to it — %s", pluginName, err)
		} else {
			where.seal = seal
			open = append(open, where)
		}
	}
	return open
}

// carryTo puts one body on every route, and says which of them did not take it.
//
// **A route that fails does not stop the others.** They are two places holding the same records,
// and a phone reading one of them is not waiting on the other. What a failure does stop is the
// state: nothing is remembered until every route has it, so the next turn carries the same
// records again — which both routes take twice as well as once, being addressed by key.
func carryTo(routes []route, body placement, whole bool) error {
	var refusals []error
	for _, where := range routes {
		place := where.place
		if whole {
			place = where.replace
		}
		if err := place(body); err != nil {
			refusals = append(refusals, fmt.Errorf("nothing reached %s: %w", where, err))
		}
	}
	return errors.Join(refusals...)
}

// store is the place the records are put: the user's own Worker, the token that opens its writing
// door, and the key nothing there is written without.
type store struct {
	url   string
	token string
	seal  *sealer
}

// String names the route in a diagnostic.
func (s store) String() string { return "the Cloudflare Worker" }

// holdsNothing is answered no: asking what the Worker holds costs a call over the network, and
// the hook fires on every write. The drop answers it for free, the answer being a file lying
// beside the records.
func (s store) holdsNothing() bool { return false }

// place puts what moved into the store.
func (s store) place(body placement) error { return s.putInParts("/records", body) }

// replace empties the store and places everything.
func (s store) replace(body placement) error { return s.putInParts("/reset", body) }

// putInParts sends one turn, in as many requests as it takes.
//
// **One turn, however many requests.** The store is told how many parts are coming and which one
// each is, so it knows which part empties and which part settles the version — and so a turn that
// stops half way is one the store can tell from a finished one, rather than one it has already
// written the version of.
//
// A turn carrying nothing is still a turn: a whole placement of an empty store is what says the
// store holds nothing, and skipping the request would leave whatever is there standing.
//
// **A part that fails stops the rest.** What has landed stays landed, which is why nothing is
// remembered until the whole turn is through — the next turn sends the same records again, and a
// replacement re-empties before it does.
func (s store) putInParts(path string, body placement) error {
	sealed, err := s.sealed(body)
	if err != nil {
		return err
	}
	parts := inParts(sealed.Records, recordsPerWrite)
	for at, records := range parts {
		part := sealed
		part.Part, part.Parts, part.Records = at+1, len(parts), records
		if _, err := s.put(path, part); err != nil {
			return err
		}
	}
	return nil
}

// inParts cuts a turn's records into the pieces one request each may carry. An empty turn comes
// back as one empty piece, because a turn is a thing to send whether or not it carries anything.
func inParts(records []outgoing, most int) [][]outgoing {
	if len(records) == 0 {
		return [][]outgoing{{}}
	}
	parts := make([][]outgoing, 0, (len(records)+most-1)/most)
	for start := 0; start < len(records); start += most {
		parts = append(parts, records[start:min(start+most, len(records))])
	}
	return parts
}

// sealed puts every row in this body into an envelope, which is what makes it fit to leave the
// machine.
//
// **This is the last thing done before the bytes go out**, and it is done here rather than where
// the records are built, because the folder on this same device has no reason to be handed a
// ciphertext it would need a key to read.
func (s store) sealed(body placement) (placement, error) {
	if s.seal == nil {
		return placement{}, errNoKey
	}
	records := make([]outgoing, 0, len(body.Records))
	for _, record := range body.Records {
		if record.Row != nil {
			nonce, cipher := s.seal.seal(record.Key, record.Row)
			record = outgoing{Key: record.Key, Op: record.Op, Nonce: nonce, Cipher: cipher}
		}
		records = append(records, record)
	}
	body.Records = records
	return body, nil
}

// storeFor names the Cloudflare door, or says there is not one. Half a route is not a route — a
// URL with no token is refused at the door on every send, so it is nothing to keep retrying.
//
// What comes back can be spoken to but not sent to: the key belongs to the sending, and revoking a
// phone or issuing a token needs none.
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
// A refusal is read where every door's is (see `askTheStore`), so what reaches the user's log
// says what happened and what to do about it, whichever door turned them down.
func (s store) put(path string, body placement) (int64, error) {
	raw, err := json.Marshal(body)
	if err != nil {
		return 0, err
	}
	request, err := http.NewRequest(http.MethodPut, s.url+path, bytes.NewReader(raw))
	if err != nil {
		return 0, err
	}
	request.Header.Set("Content-Type", "application/json")

	answered, err := s.askTheStore(request)
	if err != nil {
		return 0, err
	}
	var said struct {
		Seq int64 `json:"seq"`
	}
	if err := json.Unmarshal(answered, &said); err != nil {
		return 0, fmt.Errorf("%s answered with something this build cannot read: %w", path, err)
	}
	return said.Seq, nil
}

// carry runs one turn of the send and says how many records it placed.
//
// The turn is guarded by the version: nothing moved means nothing to do, and saying so costs one
// question. `force` is what `push` passes — someone asked out loud, so the guard is skipped and
// the ledger is read even when the version says the phone is level.
func carry(in input, force bool) (int, error) {
	routes := routesFor(in)
	if len(routes) == 0 {
		return 0, errNoRoute
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

	if found && !anyRouteHoldsNothing(routes) {
		if !force && remembered.Version == *version {
			return 0, nil
		}
		placed, cursor, err := carryChanged(routes, remembered.Cursor, *version)
		if !errors.Is(err, errSyncGap) {
			if err != nil {
				return 0, err
			}
			return placed, writeState(state{Version: *version, Cursor: cursor})
		}
		logf("%s: the ledger no longer reaches back to where this plugin left off — placing the whole store again", pluginName)
	}

	placed, cursor, err := carryWhole(routes, *version)
	if err != nil {
		forgetWhatWasNotPlaced()
		return 0, err
	}
	return placed, writeState(state{Version: *version, Cursor: cursor})
}

// forgetWhatWasNotPlaced throws away the memory of an older send, after a whole placement failed.
//
// **A whole placement stops part way through the store, not before it.** A route emptied and
// half filled is a place holding part of a backlog, and what was remembered from before points at
// a cursor much further on — so the next turn would carry what moved since then and lay it on top,
// leaving the missing middle missing for good.
//
// Forgetting puts the next turn back where a first run is: it places the whole store again, which
// is the only thing that puts a half-placed one right. It costs one large send and no correctness.
func forgetWhatWasNotPlaced() {
	if err := forgetState(); err != nil {
		logf("%s: %s", pluginName, err)
	}
}

// anyRouteHoldsNothing says whether one of the open routes is starting from nothing.
//
// **What this plugin remembers is what it sent, not what a place holds.** The iCloud folder comes
// into being when the user first opens the app on their phone, which can be any number of sends
// later, and handing that folder only what has moved since would leave a phone reading this
// week's edits with no backlog behind them.
func anyRouteHoldsNothing(routes []route) bool {
	for _, where := range routes {
		if where.holdsNothing() {
			return true
		}
	}
	return false
}

// carryChanged places what moved since the cursor, and hands back the cursor to remember.
//
// A stretch that turns out to hold nothing to carry is still a turn: the cursor moves, so the
// next one does not read it again.
func carryChanged(routes []route, cursor, version int64) (int, int64, error) {
	changes, moved, err := changesSince(cursor)
	if err != nil {
		return 0, 0, err
	}
	records, err := changedRecords(changes, rowsIn)
	if err != nil {
		return 0, 0, err
	}
	if len(records) == 0 {
		return 0, moved, nil
	}
	if err := carryTo(routes, placement{SpecV: specVersion, Version: version, Records: records}, false); err != nil {
		return 0, 0, err
	}
	return len(records), moved, nil
}

// carryWhole empties every route and places everything, which is what a first run, a reset, a gap
// and a route that has just appeared all come down to.
//
// The version is read before the picture is taken, never after: a write landing in between makes
// the remembered version one turn stale, which costs a turn that finds nothing. Remembering a
// version newer than the picture would instead skip whatever landed in that gap, and the phone
// would never learn of it.
func carryWhole(routes []route, version int64) (int, int64, error) {
	whole, err := wholeWindow()
	if err != nil {
		return 0, 0, err
	}
	records, err := carryWindow(whole)
	if err != nil {
		return 0, 0, err
	}
	if err := carryTo(routes, placement{SpecV: specVersion, Version: version, Records: records}, true); err != nil {
		return 0, 0, err
	}
	return len(records), whole.Header.Cursor, nil
}
