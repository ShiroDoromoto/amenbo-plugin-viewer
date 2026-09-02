package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// Reading what the user's own Worker said when it would not do the thing.
//
// **A refusal is the only thing this plugin can tell the user about their store.** Nothing here
// can look inside their Cloudflare account, and the plugin's own log is the one place their
// question — "why is my phone not updating?" — is answered. So a refusal has to leave with two
// things on it: what happened, and what to do about it.
//
// The Worker writes its own sentence for the first of those, and for some answers that sentence
// is the whole of it: a store with no room left already says that raising the account is what
// makes room. For the rest — a token that no longer opens the door, a route the Worker does not
// have — the Worker cannot know what the person should do, because what is wrong is on this side.
// That half is `whatToDoAbout`.
//
// And some answers are not the Worker's at all: an exception it did not catch is answered by
// Cloudflare in front of it, as a plain page rather than the Worker's JSON. Reading that as
// "the Worker said nothing" would lose the one number on it worth having.

// storeRefused is a door answering that it would not. It is a type rather than a sentence so a
// caller with a reading of its own — a send honouring the moment it was told to come back at —
// can take the answers it knows and leave the rest to the words here.
type storeRefused struct {
	// path is the door, named the way the Worker's own routes are.
	path string
	// status is what it answered.
	status int
	// said is the Worker's own sentence, or empty when what came back was not its JSON.
	said string
	// page is what came back when it was not the Worker's JSON, trimmed to a line. Cloudflare's
	// own error pages carry a number that says which fault it was, and that is worth keeping.
	page string
	// waitFor is the Retry-After the answer carried, if it carried one.
	waitFor string
}

// Error says what happened and what to do about it.
//
// **Which of the two leads depends on whose side the fault is.** When the Worker's own sentence
// carries the move, it is the sentence, and nothing is put in front of it. When the fault is
// here, the move leads and the Worker's words follow in quotes — they describe a shape mismatch
// in its terms, which is worth having and is not what the person should act on.
func (r storeRefused) Error() string {
	said := r.said
	if said == "" && r.page != "" {
		said = fmt.Sprintf("the Worker itself did not answer — this came from Cloudflare in front of it: %s", r.page)
	}
	next := whatToDoAbout(r.status, r.waitFor, said)
	switch {
	case next != "" && said != "":
		return fmt.Sprintf("%s answered %d — %s (it said: %q)", r.path, r.status, next, said)
	case next != "":
		return fmt.Sprintf("%s answered %d — %s", r.path, r.status, next)
	case said != "":
		return fmt.Sprintf("%s answered %d: %s", r.path, r.status, said)
	}
	return fmt.Sprintf("%s answered %d", r.path, r.status)
}

// whatToDoAbout is the move a refusal calls for, or nothing when the Worker's own sentence is
// already the whole of it.
//
// **The refusals worth adding to are the ones whose cause is on this side.** A store with no room
// left is the Worker's to explain and it does; a token that no longer opens its door is not
// something the Worker can know the fix for, because the fix is here.
func whatToDoAbout(status int, waitFor, said string) string {
	// **A full database is read before the wait, because it wears one.** Every exception the
	// Worker meets now comes back as a 503 with a `Retry-After` on it — the Worker stopped reading
	// D1's sentence on purpose, since it is the one part of this that cannot be corrected when a
	// reading turns out wrong. So the reading lives here, where a new build can fix it, and it has
	// to come first: a store that has used its 500 MB is not going to be different in a minute,
	// and telling someone to wait for one is telling them to wait forever.
	if theStoreIsFull(said) {
		return "the store's database is full — waiting will not change that, and nothing more" +
			" will fit until the Cloudflare account it is in is raised to a larger plan"
	}
	// An answer that says when to come back is a wait, whatever else it says. That is HTTP's own
	// reading of it, and it is the one case where doing nothing is the right move.
	if wait, asked := theWaitAsked(waitFor, rightNow()); asked {
		// **The number is read rather than repeated.** `Retry-After` is written as seconds or as
		// a date, and a build that pasted the header into a sentence about seconds said things
		// like "left for Wed, 30 Aug 2026 06:00:00 GMT seconds".
		return fmt.Sprintf("this one clears itself — the store asked to be left for %s", theWaitInWords(wait))
	}
	switch status {
	case http.StatusUnauthorized, http.StatusForbidden:
		return fmt.Sprintf("the token this plugin writes with is not the one that Worker takes"+
			" — `%s setup` stands the route up again and writes a new one", pluginName)
	case http.StatusServiceUnavailable:
		return fmt.Sprintf("the Worker is standing but its write token was never set on it"+
			" — `%s setup` finishes what a deploy left half done", pluginName)
	case http.StatusBadRequest, http.StatusNotFound, http.StatusMethodNotAllowed, http.StatusRequestEntityTooLarge:
		return fmt.Sprintf("this build and that Worker do not agree on the route"+
			" — the one in your account came from another version, and `%s setup` deploys the one this build carries",
			pluginName)
	}
	return ""
}

// whatD1SaysWhenItIsFull is the sentence D1 throws when the database has no room left, and the
// only thing that says it: the binding throws a plain `Error` with no code and no status, and the
// `7500` its REST API answers with never reaches a Worker.
//
// **Everything else has to fall through.** A database that was briefly unreachable, read as "buy
// more storage", sends someone to pay for nothing.
const whatD1SaysWhenItIsFull = "Exceeded maximum DB size"

// theStoreIsFull reads that sentence out of whatever the store passed on.
func theStoreIsFull(said string) bool {
	return strings.Contains(said, whatD1SaysWhenItIsFull)
}

// bodyOfOneLine is as much of a non-JSON answer as is worth repeating: one line, bounded, and
// nothing of the request that produced it. Cloudflare's pages are the reason it exists — they
// carry a fault number and a lot of markup around it.
const bodyOfOneLine = 200

// overTheWire is the one client every call to the store goes out on.
//
// **It is held so that the pooling is stated rather than inherited.** A client built per call
// keeps a connection open just as well — its `Transport` is nil, so it borrows the process-wide
// `http.DefaultTransport` and the pool that hangs off it — but that reuse is a side effect of a
// field nobody set, and the day one of these clients is given a `Transport` of its own it goes
// away without a word. One client named here is the thing to give that `Transport` to.
//
// **What it does not buy is the first handshake.** Amenbo starts the plugin once per write and
// the process ends with the hook, so the pool it filled goes with it: a hook that sends once pays
// the TLS setup every time, and no client held in here can carry a connection across two runs.
// What amortises that is sending more per run, which is the queue's business, not this one's.
var overTheWire = &http.Client{Timeout: sendTimeout}

// askTheStore sends one request to the user's own Worker and hands back the body of a good
// answer. A refusal comes back as a storeRefused, so every door reads one the same way.
//
// **No diagnostic it produces carries the token or anything the body held.** What travels is the
// door's name, what it answered, and the Worker's own sentence — which is written for whoever has
// to fix it.
func (s store) askTheStore(request *http.Request) ([]byte, error) {
	request.Header.Set("Authorization", "Bearer "+s.token)

	answer, err := overTheWire.Do(request)
	if err != nil {
		return nil, fmt.Errorf("%s did not answer: %w", request.URL.Path, err)
	}
	defer answer.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(answer.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("%s answered %d, and the answer could not be read: %w", request.URL.Path, answer.StatusCode, err)
	}
	if answer.StatusCode >= 200 && answer.StatusCode <= 299 {
		return raw, nil
	}

	turnedDown := storeRefused{
		path:    request.URL.Path,
		status:  answer.StatusCode,
		waitFor: strings.TrimSpace(answer.Header.Get("Retry-After")),
	}
	var said struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(raw, &said); err == nil && said.Error != "" {
		turnedDown.said = said.Error
	} else {
		turnedDown.page = oneLineOf(raw)
	}
	return nil, turnedDown
}

// oneLineOf flattens an answer that was not the Worker's JSON into something a log line can
// hold: the whitespace collapsed, and cut where it stops being worth reading.
func oneLineOf(raw []byte) string {
	flat := strings.Join(strings.Fields(string(raw)), " ")
	if len(flat) > bodyOfOneLine {
		return flat[:bodyOfOneLine] + "…"
	}
	return flat
}
