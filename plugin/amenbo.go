package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// What this plugin carries comes out of amenbo's sync face, and it is reached by running the CLI
// rather than by opening the store file. The store's shape is amenbo's to change; these four
// calls are the contract it publishes, and a plugin that read the tables underneath would be
// broken by a migration nobody thought concerned it.
//
// **No --actor is passed.** amenbo puts the plugin's own reach in the environment when it fires
// it, and that reach *is* the facet. Claiming to be the person, or their AI, would be untrue and
// would also narrow the window to a single project.
const amenboProgram = "amenbo"

// errSyncGap is amenbo saying the cursor has fallen out of the stretch the ledger still speaks
// for. It is not a failure to report — it is the signal to stop reading changes and place the
// whole window again.
var errSyncGap = errors.New("the cursor has fallen outside the ledger")

// refused is amenbo turning a call down: the document it writes on stderr when a call fails and
// --json was asked for, carried as an error so a caller can branch on the code rather than on
// the sentence. The sentence is amenbo's and is passed on as written — it is for whoever has to
// fix the thing.
type refused struct {
	call    string
	code    string
	message string
}

func (r refused) Error() string {
	return fmt.Sprintf("amenbo sync %s: %s (%s)", r.call, r.message, r.code)
}

// codeNotCarried is amenbo saying the road cannot answer for that name. The ledger names every
// dataset it holds, and the read-back road carries a narrower set, so a change can name one that
// cannot be read — which is a dataset to leave behind, not a send to abandon.
const codeNotCarried = "sync_error"

// window is what a sync answer carries: rows by dataset, each left in the JSON amenbo wrote it
// as.
//
// **The rows are never decoded past their id.** What a task or a comment holds is the phone's
// business, and a plugin that parsed it would need a change every time amenbo grows a column —
// while the phone, which does need to know, would be reading a copy this plugin had re-encoded.
type window struct {
	Header struct {
		Cursor int64 `json:"cursor"`
	} `json:"amenbo_sync"`
	Tables map[string][]json.RawMessage `json:"tables"`
}

// change is one record having moved, as `sync changes` names it. The value is not here: a record
// that moved is read back by name afterwards, and a deleted one is not read back at all.
type change struct {
	Dataset  string `json:"dataset"`
	RecordID int64  `json:"record_id"`
	Op       string `json:"op"`
}

// opDelete is the one op that needs no read-back. The others — insert and update — are both
// "this record now holds something else", which is one question to the store either way.
const opDelete = "delete"

// amenboSync runs one `amenbo sync …` call and hands back its stdout.
//
// stdout is the answer and stderr is everything else, so only the first is read on the way
// through — the snapshot, for one, comes with a note on stderr about the attachment bytes it
// left behind. **A refusal goes the other way**: amenbo writes it to stderr, and it is a
// document rather than a sentence, which is what lets the gap be recognised as itself instead of
// being reported as a failed call.
func amenboSync(args ...string) ([]byte, error) {
	command := exec.Command(amenboProgram, append([]string{"sync"}, args...)...)
	var answer, diagnostics bytes.Buffer
	command.Stdout, command.Stderr = &answer, &diagnostics
	err := command.Run()
	if err == nil {
		return answer.Bytes(), nil
	}
	if code, message, said := refusedWith(diagnostics.Bytes()); said {
		if code == "sync_gap" {
			return nil, errSyncGap
		}
		return nil, refused{call: strings.Join(args, " "), code: code, message: message}
	}
	return nil, fmt.Errorf("amenbo sync %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(diagnostics.String()))
}

// refusedWith reads amenbo's own account of why a call failed. Anything else — a binary that is
// not there, a crash, a sentence written for a person — is not one, and is reported as it came.
func refusedWith(diagnostics []byte) (code, message string, isRefusal bool) {
	var said struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(diagnostics, &said) != nil || said.Error.Code == "" {
		return "", "", false
	}
	return said.Error.Code, said.Error.Message, true
}

// storeVersion asks what the window is at — one number, and the only question worth asking
// often. It moves whenever anything in the window is written and stays put when nothing is.
//
// **Compare it for inequality, never for order.** A restore winds the store back and brings the
// version back with it, so lower is still changed. It is also allowed to be 0, which says
// nothing about whether the store is empty.
func storeVersion() (int64, error) {
	answer, err := amenboSync("version", "--json")
	if err != nil {
		return 0, err
	}
	var said struct {
		Version int64 `json:"version"`
	}
	if err := json.Unmarshal(answer, &said); err != nil {
		return 0, fmt.Errorf("amenbo sync version answered with something this build cannot read: %w", err)
	}
	return said.Version, nil
}

// changesSince reads every change after the cursor, following the pages to the end, and hands
// back the cursor to come back with.
//
// A page is bounded and says when it cut one short, so the loop is amenbo's to end. The cursor
// standing still while more pages are claimed would be an endless one, so it is stopped here
// rather than spun on.
func changesSince(cursor int64) ([]change, int64, error) {
	var all []change
	for {
		answer, err := amenboSync("changes", "--since", strconv.FormatInt(cursor, 10), "--json")
		if err != nil {
			return nil, 0, err
		}
		var page struct {
			Changes []change `json:"changes"`
			Cursor  int64    `json:"cursor"`
			More    bool     `json:"more"`
		}
		if err := json.Unmarshal(answer, &page); err != nil {
			return nil, 0, fmt.Errorf("amenbo sync changes answered with something this build cannot read: %w", err)
		}
		all = append(all, page.Changes...)
		if !page.More {
			return all, page.Cursor, nil
		}
		if page.Cursor <= cursor {
			return nil, 0, fmt.Errorf("amenbo sync changes claims another page but its cursor did not move past %d", cursor)
		}
		cursor = page.Cursor
	}
}

// wholeWindow takes one picture of everything the plugin may see, with the cursor to read on
// from in its header. Every table comes from one instant, so nothing in it points at something
// that is not in it.
func wholeWindow() (window, error) {
	answer, err := amenboSync("snapshot", "--json")
	if err != nil {
		return window{}, err
	}
	var whole window
	if err := json.Unmarshal(answer, &whole); err != nil {
		return window{}, fmt.Errorf("amenbo sync snapshot answered with something this build cannot read: %w", err)
	}
	return whole, nil
}

// rowsIn reads named records back, in the shape the whole window carries them in.
//
// An id this window does not reach, and an id that is no longer there, both simply come back
// absent — which of the two it was, the change that named it has already said.
func rowsIn(dataset string, ids []int64) ([]json.RawMessage, error) {
	named := make([]string, len(ids))
	for i, id := range ids {
		named[i] = strconv.FormatInt(id, 10)
	}
	answer, err := amenboSync("records", "--dataset", dataset, "--ids", strings.Join(named, ","), "--json")
	if err != nil {
		return nil, err
	}
	var read window
	if err := json.Unmarshal(answer, &read); err != nil {
		return nil, fmt.Errorf("amenbo sync records answered with something this build cannot read: %w", err)
	}
	return read.Tables[dataset], nil
}

// rowID reads the one field of a row this plugin needs: the id it is filed under.
func rowID(raw json.RawMessage) (int64, error) {
	var named struct {
		ID *int64 `json:"id"`
	}
	if err := json.Unmarshal(raw, &named); err != nil {
		return 0, fmt.Errorf("a row came back in a shape this build cannot read: %w", err)
	}
	if named.ID == nil {
		return 0, errors.New("a row came back with no id to file it under")
	}
	return *named.ID, nil
}
