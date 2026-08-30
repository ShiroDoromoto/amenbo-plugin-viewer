package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

// The send: work out what the phone is missing, and put it where the phone reads.
//
// **It is in two halves, and they are not the same speed.** One copies what moved out of the
// ledger into a queue the route keeps; the other empties that queue into the place, oldest first.
// The ledger's window turns — five thousand rows and then the oldest go — so the copying has to
// keep up with the backlog whatever the network is doing, and the sending has to be free to fall
// behind without dragging the copying back to where it stands.
//
// The ordinary turn copies only what moved. Every write moves the store version, so one cheap
// question answers "is there anything to do", and the ledger answers "what" — which is why the
// whole window is taken only on a first run, on a route just stood up, and after a gap.
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

// moving is one record inside a stretch of the ledger: the dataset the ledger named it by, and
// its id. It is how a record is recognised while a stretch is being reduced — deliberately not
// the key it will travel under, which is the read-back road's answer rather than the ledger's
// word.
type moving struct {
	dataset string
	id      int64
}

// collapse reduces a stretch of the ledger to what has to be carried.
//
// One record can move several times inside one stretch, and the phone needs where it ended up,
// not how it got there — so the last word about a record is the only one kept. A record deleted
// after being written is a delete; one written after being deleted is a write.
//
// What comes back is the ids to read back and the ids to drop, both gathered by dataset and both
// in a settled order so one stretch always produces one body. **The drops are ids and not keys**:
// what a record is filed under is not known here, only what the ledger called it.
func collapse(changes []change) (read, dropped map[string][]int64) {
	last := make(map[moving]string)
	for _, moved := range changes {
		last[moving{moved.Dataset, moved.RecordID}] = moved.Op
	}

	read, dropped = make(map[string][]int64), make(map[string][]int64)
	for _, moved := range changes {
		if neverCarried[moved.Dataset] {
			continue
		}
		which := moving{moved.Dataset, moved.RecordID}
		op, unsettled := last[which]
		if !unsettled {
			continue
		}
		delete(last, which)
		if op == opDelete {
			dropped[moved.Dataset] = append(dropped[moved.Dataset], moved.RecordID)
			continue
		}
		read[moved.Dataset] = append(read[moved.Dataset], moved.RecordID)
	}
	for _, gathered := range []map[string][]int64{read, dropped} {
		for dataset := range gathered {
			ids := gathered[dataset]
			sort.Slice(ids, func(a, b int) bool { return ids[a] < ids[b] })
		}
	}
	return read, dropped
}

// readBack is how the rows behind a stretch of the ledger are fetched, and what the answer files
// them under. It is a parameter so the walk over a stretch can be exercised without a store
// standing behind it — what it stands for in a running plugin is always rowsIn.
type readBack func(dataset string, ids []int64) (string, []json.RawMessage, error)

// leftBehind says whether a read was turned down because that dataset does not travel, saying so
// on the way past.
//
// The ledger names every dataset Amenbo holds and the read-back road carries fewer, so a stretch
// touching one of the others would otherwise stop every send after it — the phone would fall
// behind for good over a row it was never going to receive.
func leftBehind(dataset string, err error) bool {
	var turnedDown refused
	if errors.As(err, &turnedDown) && turnedDown.code == codeNotCarried {
		logf("%s: %s does not travel, so it is being left behind — %s", pluginName, dataset, turnedDown.message)
		return true
	}
	return false
}

// changedRecords reads back what moved, alongside the deletes that need no read.
//
// **A record is filed under the name the read-back road answered with, not the one the ledger
// asked by**. The two part company at least once — the ledger says `dependency` and the answer
// comes back as `task_dependency` — and filing under the question's name put the same record in
// the store under two keys, so the phone kept a copy no later write could reach.
//
// A delete carries no row, so there is nothing to read back for it — but what it is filed under
// is still the road's to say. A dataset holding nothing but deletes therefore costs one call,
// whose answer names the table and carries no rows.
//
// An id that comes back absent is one that went away between the ledger naming it and this read
// — it is left out rather than guessed at, because the change that says so is still ahead of the
// cursor and will carry the delete on the next turn.
func changedRecords(changes []change, rows readBack) ([]outgoing, error) {
	read, dropped := collapse(changes)

	datasets := make([]string, 0, len(read)+len(dropped))
	for dataset := range read {
		datasets = append(datasets, dataset)
	}
	for dataset := range dropped {
		if _, alreadyNamed := read[dataset]; !alreadyNamed {
			datasets = append(datasets, dataset)
		}
	}
	sort.Strings(datasets)

	var placed, drops []outgoing
	for _, dataset := range datasets {
		var table string
		var stayed bool
		ids := read[dataset]
		for start := 0; start < len(ids); start += idsPerRead {
			end := min(start+idsPerRead, len(ids))
			answered, back, err := rows(dataset, ids[start:end])
			if leftBehind(dataset, err) {
				stayed = true
				break
			}
			if err != nil {
				return nil, err
			}
			table = answered
			carried, err := carryRows(table, back)
			if err != nil {
				return nil, err
			}
			placed = append(placed, carried...)
		}

		gone := dropped[dataset]
		if stayed || len(gone) == 0 {
			continue
		}
		if table == "" {
			answered, _, err := rows(dataset, gone[:min(len(gone), idsPerRead)])
			if leftBehind(dataset, err) {
				continue
			}
			if err != nil {
				return nil, err
			}
			table = answered
		}
		for _, id := range gone {
			drops = append(drops, outgoing{Key: recordKey(table, id), Op: opDeleted})
		}
	}
	sort.Slice(drops, func(a, b int) bool { return drops[a].Key < drops[b].Key })
	return append(placed, drops...), nil
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
	// place puts one request's worth of a queue, and answers what the place did with it — where
	// its ordering stands afterwards, which is how the turn finds out whether what it sent was
	// written, and what the write cost, which is what the budget is kept in.
	//
	// **One request, not one turn.** Cutting a queue into requests is the send's business, since
	// the send is what drops what landed and keeps what did not; a route that swallowed a whole
	// turn could only say "some of it" when a part of it failed.
	place(body placement) (written, error)
}

// written is what one request answered: where the place's ordering stands afterwards, and how
// many rows its database actually wrote.
//
// **The second is measured and not worked out.** An upsert onto a key already there costs a
// different number of rows from one onto a key that is not, so a sender counting for itself would
// hold a model of the database, to go stale the day the database changes. The store hands the
// number over, so it is taken (see `pace.go`).
//
// A store older than that field answers nothing for it, which reads as zero — a budget that never
// fills, which is exactly the behaviour before there was one.
type written struct {
	seq  int64
	rows int64
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

// place puts one request's worth of a queue into the store, sealed on its way out.
//
// **It is the only door records go through.** There was a second that emptied the store before
// taking the whole of it, and both this plugin and the Worker have let it go: emptying shuts the
// door a phone reads through for as long as the filling takes, and a filling nobody finished shut
// it for good. Placing over what is here closes nothing.
//
// **The answer is read as well as sent.** The store answers with where its ordering stands, and a
// store that wrote what it was handed stands exactly the record count further on — so a request
// that was taken in and dropped is one whose answer did not move. Saying "sent" of one of those is
// the quiet way a backlog loses a record for good, and it is how three months of edits went
// missing: the send believed a `200`, dropped the records, and nothing was ever written. Checking
// that answer is the caller's, since the caller is what holds the records until it is satisfied.
func (s store) place(body placement) (written, error) {
	sealed, err := s.sealed(body)
	if err != nil {
		return written{}, err
	}
	return s.put("/records", sealed)
}

// theNumberToSend is the version one turn travels under: the backlog's own, except where that is
// already the number the store was left standing at — in which case it is one past it.
//
// **A store drops a turn whose version it is already standing at, and answers as though it took
// it** (`worker/src/index.ts`). The guard is there to recognise a turn that finished and arrived
// twice, and it recognises it by that number alone — so two different turns carrying one number
// are one turn to it. The backlog's version is too coarse a name for a turn: a `push` asked for by
// hand, a whole placement sent again, and every send made while the backlog itself has not moved
// all carry the number the store is already standing at.
//
// **Only a turn that landed is remembered**, so a turn sent again after a refusal carries the same
// number as it did before and is still recognised as the repeat it is — which is the whole of what
// the guard was for. And nothing else writes that number, so a number differing from the one this
// machine left there is a number the store cannot be standing at.
func theNumberToSend(version int64, left carried) int64 {
	placed := left.Placed
	if placed == 0 {
		// **A memory written before this build kept no number of its own, and needs none**: what
		// that build placed was the backlog's version, which is the field it did keep. Reading it
		// here is what keeps the first turn after an upgrade from being the one that is dropped —
		// and it costs no migration, so nothing is placed whole for it.
		placed = left.Version
	}
	// Nothing placed from here is nothing the store can be standing at on our account, and a
	// first turn carries the backlog's own version rather than one past it.
	if placed != 0 && version == placed {
		return version + 1
	}
	return version
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
func (s store) put(path string, body placement) (written, error) {
	raw, err := json.Marshal(body)
	if err != nil {
		return written{}, err
	}
	request, err := http.NewRequest(http.MethodPut, s.url+path, bytes.NewReader(raw))
	if err != nil {
		return written{}, err
	}
	request.Header.Set("Content-Type", "application/json")

	answered, err := s.askTheStore(request)
	if err != nil {
		return written{}, err
	}
	var said struct {
		Seq         int64 `json:"seq"`
		RowsWritten int64 `json:"rows_written"`
	}
	if err := json.Unmarshal(answered, &said); err != nil {
		return written{}, fmt.Errorf("%s answered with something this build cannot read: %w", path, err)
	}
	return written{seq: said.Seq, rows: said.RowsWritten}, nil
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

// errSendingElsewhere is what a turn says when another run already holds the send. **It is not a
// failure — it is this working**, so both faces answer it as the ordinary thing it is rather than
// as a fault to be logged and worried over.
var errSendingElsewhere = errors.New("another send is already running")

// holdTheSend takes the hold that lets one send run at a time, and hands back the way to let it
// go. A hold that is already taken comes back as errSendingElsewhere.
//
// **It does not wait for its turn.** Waiting would be the wrong answer to the shape this is for:
// reading the ledger runs Amenbo as a child, and Amenbo delivers events, so the child can fire
// this plugin again underneath the run that is already reading. That grandchild has nothing of
// its own to carry — the run above it is carrying it — so what it should do is stop, which is
// what "no, and do not queue" makes it do. Waiting would hold a process open for a turn that had
// already been taken.
//
// **The other reason is the one that started this.** A machine that sleeps hands the same stretch
// to two runs at once, because a lease expires by the wall clock while the heartbeat counts a
// clock that does not run while the machine is asleep. Two runs in the send at once put an older
// picture of a record on top of a newer one; one run in the send at a time cannot.
func holdTheSend() (func(), error) {
	path, err := sendingLockPath()
	if err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("the sending lock cannot be opened: %w", err)
	}
	taken, err := takeSendingLock(file)
	if err != nil {
		file.Close()
		return nil, fmt.Errorf("the sending lock cannot be taken: %w", err)
	}
	if !taken {
		file.Close()
		return nil, errSendingElsewhere
	}
	return func() {
		dropSendingLock(file)
		file.Close()
	}, nil
}

// carry runs one turn of the send and says how many records it placed.
//
// The turn is guarded by the version: nothing moved means nothing to do, and saying so costs one
// question. `force` is what `push` passes — someone asked out loud, so the guard is skipped and
// the ledger is read even when the version says the phone is level.
//
// **One turn runs at a time, machine-wide.** The hold is taken before the first question rather
// than before the first record, because the reading is where the children are raised and where a
// second run of this would be started; and it is let go only when the turn is over, because what
// must not overlap is the whole of it — the reading, the placing, and the writing down of where
// it got to.
func carry(in input, force bool) (int, error) {
	routes := routesFor(in)
	if len(routes) == 0 {
		return 0, nothingIsReaching(in)
	}
	letGo, err := holdTheSend()
	if err != nil {
		return 0, err
	}
	defer letGo()
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

// carryTurn is one turn: what each route has yet to be told, the reading it takes to copy that
// into the route's queue, and as much of that queue as the place will take.
//
// **The two halves are apart on purpose.** Copying is answerable to this machine — the ledger's
// window turns, so what is not read out of it in time is not read at all — and sending is
// answerable to a network and a place that may be refusing everything. Held together, the slow
// one drags the fast one: a route that would not take anything for a day kept the reading where
// it stood, and the window turned over what was never read. Apart, the reading keeps up with the
// backlog whatever the sending is doing, and the sending catches up whenever it can.
//
// **Every route is asked its own question, and answered on its own.** One may have never been
// written into while the other is level; one may refuse everything while the other takes it all.
// A route that fails keeps its queue — the next turn offers the same records again, which the
// place takes twice as well as once, being addressed by key — and the routes beside it move on.
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

	// The stretches are walked in cursor order so that one turn always reads the same way, and
	// each stretch is read once however many routes are waiting on it.
	for _, cursor := range inOrder(changed) {
		records, moved, err := from.since(cursor)
		if errors.Is(err, errSyncGap) {
			logf("%s: the ledger no longer reaches back to where a route left off — copying the whole store out again", pluginName)
			whole = append(whole, changed[cursor]...)
			continue
		}
		if err != nil {
			return 0, settled, err
		}
		for _, where := range changed[cursor] {
			settled.Routes[where.name()] = queued(settled.Routes[where.name()], records, version, moved)
		}
	}

	if len(whole) > 0 {
		picture, err := from.whole()
		if err != nil {
			return 0, settled, err
		}
		records, err := carryWindow(picture)
		if err != nil {
			return 0, settled, err
		}
		// **What was already queued stays in front of it.** The picture says what the store holds
		// now, and a record it does not name is one the store no longer has — but the place does,
		// and only a delete already in the queue will say so. Dropping the queue for the picture
		// would leave those behind for good.
		for _, where := range whole {
			settled.Routes[where.name()] = queued(settled.Routes[where.name()], records, version, picture.Header.Cursor)
		}
	}

	placed := 0
	var refusals []error
	for _, where := range routes {
		// The number to carry is read off what was remembered rather than off what this turn has
		// just written down: copying a stretch out moves the version field, and the number turns
		// on where the place was left standing before any of that.
		sending := theNumberToSend(version, remembered.Routes[where.name()])
		left, landed, err := drainTo(where, settled.Routes[where.name()], sending, rightNow())
		settled.Routes[where.name()] = left
		placed += landed
		if err != nil {
			refusals = append(refusals, fmt.Errorf("nothing reached %s: %w", where, err))
		}
	}
	return placed, settled, errors.Join(refusals...)
}

// queued puts a stretch of records on the back of one route's queue and writes down how far the
// ledger has now been copied out.
//
// **The two go together and that is the whole of the rule.** A cursor written on its own says a
// stretch was dealt with when it was not, and nothing goes back for it; a queue written on its
// own costs the same stretch being read a second time, which is a duplicate and not a hole. They
// are fields of one struct written by one call for exactly that reason.
//
// A stretch that turns out to hold nothing is still copied out: the cursor moves, so the next
// turn does not read it again.
func queued(left carried, records []outgoing, version, cursor int64) carried {
	left.Pending = append(left.Pending[:len(left.Pending):len(left.Pending)], records...)
	left.Version, left.Cursor = version, cursor
	return left
}

// drainTo sends the front of one route's queue, in as many requests as it takes, and answers what
// is left of it.
//
// **What the place took is dropped, and what it did not is kept.** A request that fails stops the
// rest and leaves everything from it onwards where it is, so nothing is offered as sent that was
// not — a refusal costs the turn and no records. This is why there is no send position: the queue
// is the position, and there is nothing for a second number to disagree with.
//
// **The version is settled by the last request alone.** The store writes the version down with
// the part that says it is the last of its turn, so a queue emptied to the end is the only thing
// that leaves the place standing at the number this turn carried — and only then is that number
// remembered as where the place stands.
//
// `sending` is that number, worked out before anything was read out — see `theNumberToSend`, and
// the reason it is not worked out here: what it turns on is where the place was left standing,
// and copying a stretch out moves the fields it would read that from.
func drainTo(where route, left carried, sending int64, now time.Time) (carried, int, error) {
	if len(left.Pending) == 0 {
		return left, 0, nil
	}
	// **Being asked to wait is not a failure, and neither is being out of budget.** Both leave the
	// queue where it is and cost nothing, and both are answered by doing nothing until the moment
	// comes — so neither is reported as a refusal, which would put a red line in the log on every
	// write for as long as it lasted.
	if wait, quietly := quiet(left, now); quietly {
		logf("%s: %s asked to be left for a while — %d record(s) wait another %s",
			pluginName, where, len(left.Pending), theWaitInWords(wait))
		return left, 0, nil
	}
	if outOfBudget(left, now) {
		logf("%s: today's %d rows for %s are spent — %d record(s) go on after midnight UTC",
			pluginName, rowsWeMaySpendADay, where, len(left.Pending))
		return left, 0, nil
	}

	parts := inParts(left.Pending, recordsPerWrite)
	landed, emptied := 0, true
	for at, records := range parts {
		// The budget is read between requests rather than inside one: what a write costs is the
		// store's answer, so the count only moves once the write has happened. What that buys is
		// an overshoot of at most one request, against a ceiling that already holds a tenth of
		// the day back.
		if outOfBudget(left, now) {
			logf("%s: today's %d rows for %s are spent — %d record(s) go on after midnight UTC",
				pluginName, rowsWeMaySpendADay, where, len(left.Pending))
			emptied = false
			break
		}
		answered, err := where.place(placement{
			SpecV:   specVersion,
			Version: sending,
			Part:    at + 1,
			Parts:   len(parts),
			Records: records,
		})
		if err != nil {
			// A refusal that names a moment to come back at is honoured, and remembered: the
			// process ends with this run, so a wait held anywhere else lasts no time at all.
			var turnedDown storeRefused
			if errors.As(err, &turnedDown) {
				if wait, asked := theWaitAsked(turnedDown.waitFor, now); asked {
					left = beQuietFor(left, wait, now)
				}
			}
			return left, landed, err
		}
		left = spend(left, answered.rows, now)
		if expected := left.Seq + int64(len(records)); left.Seq != orderingUnknown && answered.seq != expected {
			return left, landed, fmt.Errorf("the store took part %d of %d and did not write it:"+
				" %d records should have carried the ordering to %d, and the store answered %d"+
				" — what it did not write is still queued",
				at+1, len(parts), len(records), expected, answered.seq)
		}
		left.Seq = answered.seq
		left.Pending = left.Pending[len(records):]
		landed += len(records)
		// A place that took something is a place that is not asking to be left alone any more.
		left.QuietUntil = ""
	}
	if emptied {
		left.Placed = sending
	}
	return left, landed, nil
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

// whatEachRouteIsOwed sorts the open routes into the ones to copy the whole store out for and the
// ones to copy a stretch out for, the latter gathered by where each is reading on from.
//
// **It says nothing about sending**, which is the other half and answers to nothing here: a route
// this leaves out because the backlog has not moved may still have a queue behind it from a turn
// that could not land, and that queue is offered again whether or not there is anything new to
// put on the back of it.
//
// **What this plugin remembers is what it read, not what a place holds.** A route stood up anew
// is empty behind a memory that says the phone is level, and handing it only what has moved since
// would leave a phone reading this week's edits with no backlog behind them.
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
