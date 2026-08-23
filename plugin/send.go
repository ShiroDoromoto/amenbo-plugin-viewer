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
//
// **What to do about it is not in here**, because the answer is not the same on every machine —
// see `theWayInFromHere`, which wraps this one.
var errNoRoute = errors.New("there is nowhere to put anything yet")

// errNoCloudflareRoute is that one route not being there, which is a narrower thing to say and
// the right thing to say to whoever asked. Pairing a phone and cutting one off are the Worker's
// alone — the folder holds no tokens — so those never turn on which OS this is.
var errNoCloudflareRoute = fmt.Errorf("there is no Cloudflare route yet — run `%s setup` to stand one up", pluginName)

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
	SpecV   int   `json:"spec_v"`
	Version int64 `json:"version"`
	Part    int   `json:"part,omitempty"`
	Parts   int   `json:"parts,omitempty"`
	// KeyFingerprint names the key these records were sealed with, so a phone can find out that
	// its own key does not fit without fetching a store it cannot open a row of. It is filled in
	// by the route that seals — the folder holds rows as they are — and it travels on every part
	// of a turn, the store writing it down with the last one.
	KeyFingerprint string     `json:"key_fingerprint,omitempty"`
	Records        []outgoing `json:"records"`
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
//
// **Where each of them has got to is its own**, though — which is why a route is named as well as
// described. The two fail apart, and one that is failing must not hold the other where it stands.
type route interface {
	// name is what this route is remembered under, and nothing else. It is not the diagnostic
	// one: that is written for a person and may be reworded, and rewording it would lose every
	// route's place in the order at once.
	name() string
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

// store is the place the records are put: the user's own Worker, the token that opens its writing
// door, and the key nothing there is written without.
type store struct {
	url   string
	token string
	seal  *sealer
}

// name is what the Cloudflare route is remembered under.
func (s store) name() string { return routeCloudflare }

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
// machine, and names the key it did that with.
//
// **This is the last thing done before the bytes go out**, and it is done here rather than where
// the records are built, because the folder on this same device has no reason to be handed a
// ciphertext it would need a key to read.
//
// **The name goes on beside the sealing, not somewhere else**, so the two cannot drift: what the
// store is told sealed these records is the key that sealed them in this same call.
func (s store) sealed(body placement) (placement, error) {
	if s.seal == nil {
		return placement{}, errNoKey
	}
	body.KeyFingerprint = s.seal.fingerprint
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
		return store{}, errNoCloudflareRoute
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

// ledger is what a turn reads the store through. It is a set of functions rather than direct
// calls so that a whole turn — which route is owed what, and what is remembered afterwards — can
// be exercised without Amenbo standing behind it. What they stand for in a running plugin is
// always the three below.
type ledger struct {
	whole   func() (window, error)
	changed func(cursor int64) ([]change, int64, error)
	rows    readBack
}

// theLedger is that set as a running plugin has it.
func theLedger() ledger {
	return ledger{whole: wholeWindow, changed: changesSince, rows: rowsIn}
}

// carry runs one turn of the send and says how many records it placed.
//
// The turn is guarded by the version: nothing moved means nothing to do, and saying so costs one
// question. `force` is what `push` passes — someone asked out loud, so the guard is skipped and
// the ledger is read even when the version says the phone is level.
func carry(in input, force bool) (int, error) {
	routes := routesFor(in)
	if len(routes) == 0 {
		return 0, nothingIsReaching(in)
	}
	version := in.Version
	if version == nil {
		asked, err := storeVersion()
		if err != nil {
			return 0, err
		}
		version = &asked
	}
	remembered, _, err := readState()
	if err != nil {
		return 0, err
	}
	placed, settled, err := carryTurn(routes, *version, force, remembered, theLedger())
	if wrote := writeState(settled); wrote != nil && err == nil {
		err = wrote
	}
	return placed, err
}

// carryTurn is one turn: what each route is owed, the reading it takes to answer that, and what
// is remembered when it is over.
//
// **Every route is asked its own question, and answered on its own.** One may have never been
// written into while the other is level; one may refuse everything while the other takes it all.
// A route that fails keeps the place it had — the next turn carries the same stretch to it again,
// which it takes twice as well as once, being addressed by key — and the routes beside it move on.
//
// The version is read before the picture is taken, never after: a write landing in between makes
// a remembered version one turn stale, which costs a turn that finds nothing. Remembering a
// version newer than the picture would instead skip whatever landed in that gap, and the phone
// would never learn of it.
func carryTurn(routes []route, version int64, force bool, remembered state, from ledger) (int, state, error) {
	settled := state{Routes: map[string]carried{}}
	for name, left := range remembered.Routes {
		settled.Routes[name] = left
	}

	whole, changed := whatEachRouteIsOwed(routes, version, force, remembered)
	placed := 0
	var refusals []error

	// The stretches are walked in cursor order so that one turn always reads the same way, and
	// each stretch is read once however many routes are waiting on it.
	for _, cursor := range inOrder(changed) {
		records, moved, err := from.since(cursor)
		if errors.Is(err, errSyncGap) {
			logf("%s: the ledger no longer reaches back to where a route left off — placing the whole store there again", pluginName)
			whole = append(whole, changed[cursor]...)
			continue
		}
		if err != nil {
			return placed, settled, err
		}
		took := false
		for _, where := range changed[cursor] {
			if len(records) > 0 {
				if err := where.place(placement{SpecV: specVersion, Version: version, Records: records}); err != nil {
					refusals = append(refusals, fmt.Errorf("nothing reached %s: %w", where, err))
					continue
				}
			}
			// A stretch that turns out to hold nothing to carry is still a turn: the cursor
			// moves, so the next one does not read it again.
			settled.Routes[where.name()] = carried{Version: version, Cursor: moved}
			took = true
		}
		if took {
			placed += len(records)
		}
	}

	if len(whole) == 0 {
		return placed, settled, errors.Join(refusals...)
	}
	picture, err := from.whole()
	if err != nil {
		return placed, settled, err
	}
	records, err := carryWindow(picture)
	if err != nil {
		return placed, settled, err
	}
	took := false
	for _, where := range whole {
		if err := where.replace(placement{SpecV: specVersion, Version: version, Records: records}); err != nil {
			refusals = append(refusals, fmt.Errorf("nothing reached %s: %w", where, err))
			// **A whole placement stops part way through the store, not before it.** That route
			// is left holding a fraction of a backlog, and any place it had points well past the
			// hole — so carrying what moved since then would leave the middle missing for good.
			// Forgetting puts it back where a first run is, and a first run is placed whole.
			delete(settled.Routes, where.name())
			continue
		}
		settled.Routes[where.name()] = carried{Version: version, Cursor: picture.Header.Cursor}
		took = true
	}
	if took {
		placed += len(records)
	}
	return placed, settled, errors.Join(refusals...)
}

// since reads one stretch of the ledger into the records it comes to.
func (l ledger) since(cursor int64) ([]outgoing, int64, error) {
	changes, moved, err := l.changed(cursor)
	if err != nil {
		return nil, 0, err
	}
	records, err := changedRecords(changes, l.rows)
	if err != nil {
		return nil, 0, err
	}
	return records, moved, nil
}

// whatEachRouteIsOwed sorts the open routes into the ones to place whole and the ones to carry a
// stretch to, the latter gathered by where each is reading on from.
//
// **What this plugin remembers is what it sent, not what a place holds.** The iCloud folder comes
// into being when the user first opens the app on their phone, which can be any number of sends
// later, and handing that folder only what has moved since would leave a phone reading this
// week's edits with no backlog behind them.
func whatEachRouteIsOwed(routes []route, version int64, force bool, remembered state) ([]route, map[int64][]route) {
	var whole []route
	changed := map[int64][]route{}
	for _, where := range routes {
		left, known := remembered.Routes[where.name()]
		switch {
		case !known, where.holdsNothing():
			whole = append(whole, where)
		case !force && left.Version == version:
			// Level, and saying so costs nothing.
		default:
			changed[left.Cursor] = append(changed[left.Cursor], where)
		}
	}
	return whole, changed
}

// inOrder is the cursors of a turn, settled so that two runs over one turn read the same way.
func inOrder(changed map[int64][]route) []int64 {
	cursors := make([]int64, 0, len(changed))
	for cursor := range changed {
		cursors = append(cursors, cursor)
	}
	sort.Slice(cursors, func(a, b int) bool { return cursors[a] < cursors[b] })
	return cursors
}
