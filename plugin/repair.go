package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"time"
)

// Putting right what the phone's server holds, when it has drifted from what this PC holds.
//
// **Nothing here reads the ledger.** The ordinary send carries what moved, and it is right
// whenever the two ends started level; what it cannot do is notice that they never were. A key
// written under a name the far end files differently, a turn that was answered and never written,
// a store stood up beside an older one — each leaves a gap no later change points at, so no
// stretch of the ledger will ever carry it.
//
// So this asks the other question: **what is over there, and what is here?** The store answers
// with its keys, the snapshot answers with this machine's, and the difference is put on the same
// queue every other record travels on. Nothing is emptied and nothing is reset — a phone reading
// while this runs sees records arrive, and no more.
//
// **It is two presses, not one.** The comparison is cheap and the sending is not: a backlog that
// has drifted whole is tens of thousands of writes, which is a day's worth of a free Cloudflare
// plan. So the first press counts and says the number, and the second sends it — which is the
// only shape in which a person is told what it costs before they spend it.

// repairAskedName is where that first press is written down, beside the sync state it will move.
const repairAskedName = "repair-asked.json"

// repairAskWindow is how long a count that was shown stands for. Past it the next press counts
// again rather than sending: the number a person consented to is the number they were shown, and
// a store that has moved on since is one they were shown nothing about.
const repairAskWindow = 10 * time.Minute

// repairAsked is that record: when a count was last shown, and what it was.
type repairAsked struct {
	V       int    `json:"v"`
	AskedAt string `json:"asked_at"`
	Put     int    `json:"put"`
	Del     int    `json:"del"`
}

// theRepairAsked reads back whether a count has been shown recently enough to be what a press
// consents to. Anything unreadable, anything older, and anything absent is "nobody has been told
// yet" — the safe answer, since being asked twice costs a comparison and being asked never costs
// the writes.
func theRepairAsked() bool {
	dir, err := pluginDir()
	if err != nil {
		return false
	}
	raw, err := os.ReadFile(filepath.Join(dir, repairAskedName))
	if err != nil {
		return false
	}
	var asked repairAsked
	if json.Unmarshal(raw, &asked) != nil || asked.V != stateVersion {
		return false
	}
	shown, err := time.Parse(time.RFC3339, asked.AskedAt)
	if err != nil {
		return false
	}
	return time.Since(shown) <= repairAskWindow
}

// rememberTheRepairAsked writes down that a count was shown, so the next press is the one that
// spends it.
func rememberTheRepairAsked(put, del int) error {
	dir, err := pluginDir()
	if err != nil {
		return err
	}
	raw, err := json.Marshal(repairAsked{
		V:       stateVersion,
		AskedAt: time.Now().UTC().Format(time.RFC3339),
		Put:     put,
		Del:     del,
	})
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, repairAskedName), raw, 0o600); err != nil {
		return fmt.Errorf("what the repair asked cannot be written: %w", err)
	}
	return nil
}

// forgetTheRepairAsked takes that record away, so a press after the sending counts again rather
// than sending a second time on the strength of a number that has already been spent.
func forgetTheRepairAsked() {
	dir, err := pluginDir()
	if err != nil {
		return
	}
	if err := os.Remove(filepath.Join(dir, repairAskedName)); err != nil && !os.IsNotExist(err) {
		logf("%s: what the repair asked cannot be cleared: %v", pluginName, err)
	}
}

// repair compares the store with this machine and queues the difference.
//
// The comparison is read-only and costs one read token's worth of reading; only the second press
// writes anything. `--send` is that second press for whoever typed the first one — the person is
// standing at the terminal that printed the count, so there is nobody left to ask.
func repair(in input, args []string) error {
	options := flag.NewFlagSet("repair", flag.ContinueOnError)
	options.SetOutput(errOut)
	send := options.Bool("send", false, "send the difference rather than only counting it")
	if err := options.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}

	shop, err := storeFor(in)
	if errors.Is(err, errNoCloudflareRoute) {
		// The button is pressed before the one that stands the Worker up as often as not, and a
		// reader with no terminal has to be told which button that is rather than which command.
		return refuse(phNoCloudflareRouteYet, phTheSetupButton)
	}
	if err != nil {
		return err
	}

	holds, err := shop.whatItHolds()
	if err != nil {
		return err
	}

	sending := *send || theRepairAsked()
	put, del, err := comparedWith(theLedger(), holds, sending)
	if err != nil {
		return err
	}

	if put+del == 0 {
		forgetTheRepairAsked()
		return repairAnswered(say(phRepairFoundNothing))
	}
	if !sending {
		if err := rememberTheRepairAsked(put, del); err != nil {
			return err
		}
		logf("%s: %d record(s) to place and %d to drop — `%s repair --send` carries them, and so does pressing the button again",
			pluginName, put, del, pluginName)
		return repairAnswered(say(phRepairWillSend, put, del, phTheRepairButton))
	}

	// The queue is on disk now, and the send is let go of, so this is the ordinary carrying — it
	// takes the hold again and empties as much of the queue as the store will take.
	forgetTheRepairAsked()
	if _, err := carry(in, true); err != nil && !errors.Is(err, errSendingElsewhere) {
		return err
	}
	logf("%s: %d record(s) placed and %d dropped", pluginName, put, del)
	return repairAnswered(say(phRepairIsOnItsWay, put+del))
}

// repairAnswered is what the settings screen draws under the button, and what a caller reads off
// stdout.
func repairAnswered(said string) error {
	return json.NewEncoder(out).Encode(answered{
		V: specVersion, OK: true, Show: []shownPart{{Text: said}},
	})
}

// comparedWith takes this machine's picture, works out what the store is missing and what it is
// holding that is gone, and — when this is the press that spends it — puts both on the back of
// the Cloudflare route's queue.
//
// **The hold is taken before the picture.** What is queued here is compared against a picture,
// and a stretch of the ledger copied out between the two would sit behind records that answer to
// an older reading of the same rows — so a delete worked out here could land on top of a write
// that had already been queued. Under the hold there is no between.
//
// **The cursor is not moved.** Nothing was read out of the ledger, so nothing has been dealt
// with: what this adds is beside the ordinary send's work, never instead of it.
func comparedWith(from ledger, holds holding, queue bool) (put, del int, err error) {
	letGo, err := holdTheSend()
	if err != nil {
		return 0, 0, err
	}
	defer letGo()

	picture, err := from.whole()
	if err != nil {
		return 0, 0, err
	}
	here, err := carryWindow(picture)
	if err != nil {
		return 0, 0, err
	}
	missing, gone := theDifference(here, holds.keys)
	if !queue || len(missing)+len(gone) == 0 {
		return len(missing), len(gone), nil
	}

	remembered, _, err := readState()
	if err != nil {
		return 0, 0, err
	}
	if remembered.Routes == nil {
		remembered.Routes = map[string]carried{}
	}
	left := remembered.Routes[routeCloudflare]
	left.Pending = append(append(left.Pending[:len(left.Pending):len(left.Pending)], missing...), gone...)
	// **Where the store stands is taken from the store**, which nothing else here can do. The
	// ordering a send checks its answer against is remembered from the last answer, and a store
	// that has been written by something else — a second machine, a hand-run curl, a placement
	// that was taken and never answered for — stands somewhere that memory does not name. Every
	// send after that fails the check and nothing lands again, so a comparison that did not
	// re-anchor this would report a drift it had just made permanent.
	left.Seq = holds.seq
	remembered.Routes[routeCloudflare] = left
	if err := writeState(remembered); err != nil {
		return 0, 0, err
	}
	return len(missing), len(gone), nil
}

// theDifference is the two halves of a drift: the records this machine holds that the store is
// not holding, and the keys the store is holding that this machine no longer has.
//
// **A key the store has already been told is gone counts as missing.** A `del` row is the phone
// being told to forget it, so a record that is here and filed there as deleted is one the phone
// has thrown away — the same gap as a record that never arrived, and the same cure.
func theDifference(here []outgoing, held map[string]string) (missing, gone []outgoing) {
	mine := make(map[string]bool, len(here))
	for _, record := range here {
		mine[record.Key] = true
		if held[record.Key] != opPlaced {
			missing = append(missing, record)
		}
	}
	// The keys are gathered and sorted rather than walked out of the map, so one drift produces
	// one queue however many times it is worked out.
	keys := make([]string, 0, len(held))
	for key, op := range held {
		if op == opPlaced && !mine[key] {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	for _, key := range keys {
		gone = append(gone, outgoing{Key: key, Op: opDeleted})
	}
	return missing, gone
}

// holding is what the store answered about itself: the keys it is holding with what it last
// heard about each, and the point its ordering stands at.
type holding struct {
	keys map[string]string
	seq  int64
}

// whatItHolds reads every key the store is holding, what it last heard about each, and where its
// ordering stands.
//
// **It issues itself a read token to do it.** The write token this plugin keeps is refused at the
// reading door on purpose — the two kinds are what let one phone be cut off without touching the
// rest — so the only way to read is to be one more reader for as long as this takes. The token is
// registered by its hash like any other, used, and cut off again, and it is never written into
// the paired phones: nothing is holding it, so there is nothing for a person to choose to cut.
//
// **The envelopes come back and are thrown away.** `?keys=1` asks the store for the keys alone;
// a store deployed before that asks was answered ignores it and sends the ciphertext too, which
// costs the bandwidth and reads exactly the same, so this works against either.
func (s store) whatItHolds() (holding, error) {
	label := "amenbo-repair-" + generated()[:16]
	token := generated()
	if _, err := s.issue(label, hashOf(token)); err != nil {
		return holding{}, err
	}
	defer func() {
		if _, err := s.cutOff(label); err != nil {
			// A token left standing reads the store until somebody cuts it, so the name it is
			// standing under is worth having: `revoke` takes it.
			logf("%s: the read token this comparison issued could not be cut off — `%s revoke %s` does it: %v",
				pluginName, pluginName, label, err)
		}
	}()

	reading := store{url: s.url, token: token}
	standing, err := reading.whereItStands()
	if err != nil {
		return holding{}, err
	}
	held := map[string]string{}
	for since := int64(0); ; {
		page, err := reading.keysFrom(since)
		if err != nil {
			return holding{}, err
		}
		for _, record := range page.Records {
			held[record.Key] = record.Op
		}
		if !page.More {
			return holding{keys: held, seq: standing}, nil
		}
		if page.Seq <= since {
			return holding{}, fmt.Errorf("the store claims another page of records and its ordering did not move past %d", since)
		}
		since = page.Seq
	}
}

// whereItStands asks the store the cheap question: the point its ordering has reached. It is
// asked before the pages rather than read off the last of them, because an empty store answers
// no page at all and still stands somewhere.
func (s store) whereItStands() (int64, error) {
	request, err := http.NewRequest(http.MethodGet, s.url+"/meta", nil)
	if err != nil {
		return 0, err
	}
	answered, err := s.askTheStore(request)
	if err != nil {
		return 0, err
	}
	var said struct {
		Seq int64 `json:"seq"`
	}
	if err := json.Unmarshal(answered, &said); err != nil {
		return 0, fmt.Errorf("/meta answered with something this build cannot read: %w", err)
	}
	return said.Seq, nil
}

// keysHeld is one page of what the store holds. Only the key and what happened to it are read:
// the envelope is the phone's business, and this is not reading the backlog, it is counting it.
type keysHeld struct {
	Seq     int64 `json:"seq"`
	More    bool  `json:"more"`
	Records []struct {
		Key string `json:"k"`
		Op  string `json:"op"`
	} `json:"records"`
}

// keysFrom asks for one page of what the store holds, reading on from a point in its ordering.
func (s store) keysFrom(since int64) (keysHeld, error) {
	request, err := http.NewRequest(http.MethodGet,
		s.url+"/records?since="+strconv.FormatInt(since, 10)+"&keys=1", nil)
	if err != nil {
		return keysHeld{}, err
	}
	answered, err := s.askTheStore(request)
	if err != nil {
		return keysHeld{}, err
	}
	var page keysHeld
	if err := json.Unmarshal(answered, &page); err != nil {
		return keysHeld{}, fmt.Errorf("/records answered with something this build cannot read: %w", err)
	}
	return page, nil
}
