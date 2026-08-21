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
// caller with a reading of its own — a label already taken, a phone that was not there — can
// take the answers it knows and leave the rest to the words here.
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
	next := whatToDoAbout(r.status, r.waitFor)
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
func whatToDoAbout(status int, waitFor string) string {
	// An answer that says when to come back is a wait, whatever else it says. That is HTTP's own
	// reading of it, and it is the one case where doing nothing is the right move.
	if waitFor != "" {
		return fmt.Sprintf("this one clears itself — the store asked to be left for %s seconds", waitFor)
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

// bodyOfOneLine is as much of a non-JSON answer as is worth repeating: one line, bounded, and
// nothing of the request that produced it. Cloudflare's pages are the reason it exists — they
// carry a fault number and a lot of markup around it.
const bodyOfOneLine = 200

// askTheStore sends one request to the user's own Worker and hands back the body of a good
// answer. A refusal comes back as a storeRefused, so every door reads one the same way.
//
// **No diagnostic it produces carries the token or anything the body held.** What travels is the
// door's name, what it answered, and the Worker's own sentence — which is written for whoever has
// to fix it.
func (s store) askTheStore(request *http.Request) ([]byte, error) {
	request.Header.Set("Authorization", "Bearer "+s.token)

	answer, err := (&http.Client{Timeout: sendTimeout}).Do(request)
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
