package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// pretendTokens is the far end of the two buttons that ask about the read code: whether it is
// holding one, and what it was asked to do with it.
type pretendTokens struct {
	holds    bool
	issuedAt string
	asked    string
	path     string
	offer    string
	refuse   bool
}

// askingAgainst points the plugin at a store that is holding a code, or is not.
func askingAgainst(t *testing.T, tokens *pretendTokens) input {
	t.Helper()
	if tokens.issuedAt == "" {
		tokens.issuedAt = "2026-08-09T09:00:00.000Z"
	}

	road := http.NewServeMux()
	road.HandleFunc("/tokens", func(w http.ResponseWriter, r *http.Request) {
		tokens.offer = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		tokens.path = r.URL.EscapedPath()
		tokens.asked = r.Method
		if tokens.refuse {
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{"error": "the database is not there"})
			return
		}
		switch r.Method {
		case http.MethodDelete:
			cut := tokens.holds
			tokens.holds = false
			json.NewEncoder(w).Encode(map[string]bool{"cut": cut})
		default:
			answer := map[string]any{"paired": tokens.holds, "issued_at": nil}
			if tokens.holds {
				answer["issued_at"] = tokens.issuedAt
			}
			json.NewEncoder(w).Encode(answer)
		}
	})
	server := httptest.NewServer(road)
	t.Cleanup(server.Close)

	t.Setenv(envAuthToken, "the-write-token")
	remembering(t)
	return input{Config: map[string]any{configWorkerURL: server.URL}}
}

// Whether a phone may read is the store's answer, not a list kept here — so what comes back says
// so, and says since when.
func TestWhetherAPhoneMayReadComesFromTheStore(t *testing.T) {
	tokens := &pretendTokens{holds: true}
	in := askingAgainst(t, tokens)

	var code int
	stdout, stderr := capture(t, func() { code = run(in, []string{"phones"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if tokens.offer != "the-write-token" {
		t.Errorf("asking is the write token's door, and %q was offered", tokens.offer)
	}
	if tokens.path != "/tokens" || tokens.asked != http.MethodGet {
		t.Errorf("the store was asked %s %s", tokens.asked, tokens.path)
	}
	var answer struct {
		Show     []shownPart `json:"show"`
		Paired   bool        `json:"paired"`
		IssuedAt string      `json:"issued_at"`
	}
	if err := json.Unmarshal([]byte(stdout), &answer); err != nil {
		t.Fatalf("stdout is the return value and it does not parse: %q", stdout)
	}
	if !answer.Paired || answer.IssuedAt != tokens.issuedAt {
		t.Errorf("%+v", answer)
	}
	// Both faces say it: the log for whoever typed this, the form for whoever pressed it.
	if !strings.Contains(stderr, tokens.issuedAt) {
		t.Errorf("nothing a person can read came out: %q", stderr)
	}
	if !strings.Contains(drawnText(answer.Show), tokens.issuedAt) {
		t.Errorf("the settings screen was handed %q", drawnText(answer.Show))
	}
}

// drawnText flattens what a run asked the settings screen to draw, so a test can ask whether
// something reached the form without caring which part carried it.
func drawnText(shown []shownPart) string {
	var said []string
	for _, part := range shown {
		said = append(said, part.Text, part.Heading)
		said = append(said, part.List...)
	}
	return strings.Join(said, "\n")
}

// Nothing paired is not a fault — it is what every install looks like until somebody runs qr —
// so it is answered, and says what to press.
func TestNoPhonePairedIsAnAnswerRatherThanAFailure(t *testing.T) {
	in := askingAgainst(t, &pretendTokens{holds: false})

	var code int
	stdout, stderr := capture(t, func() { code = run(in, []string{"phones"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	var answer struct {
		Show   []shownPart `json:"show"`
		Paired bool        `json:"paired"`
	}
	if err := json.Unmarshal([]byte(stdout), &answer); err != nil {
		t.Fatalf("stdout is the return value and it does not parse: %q", stdout)
	}
	if answer.Paired {
		t.Errorf("the return value says a phone is paired: %q", stdout)
	}
	pairing := wordings["en"][phThePairButton]
	if !strings.Contains(stderr, pairing) {
		t.Errorf("it does not say how to pair one: %q", stderr)
	}
	if !strings.Contains(drawnText(answer.Show), pairing) {
		t.Errorf("the settings screen was not told how to pair one: %q", stdout)
	}
}

// Undoing the pairing takes the code away at the store, and the phone that was holding it stops
// reading. There is nothing to name, so there is nothing on the request but the method.
func TestRevokeTakesTheCodeAway(t *testing.T) {
	tokens := &pretendTokens{holds: true}
	in := askingAgainst(t, tokens)

	var code int
	stdout, _ := capture(t, func() { code = run(in, []string{"revoke"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if tokens.offer != "the-write-token" {
		t.Errorf("taking it away is the write token's door, and %q was offered", tokens.offer)
	}
	if tokens.path != "/tokens" || tokens.asked != http.MethodDelete {
		t.Errorf("the store was asked %s %s", tokens.asked, tokens.path)
	}
	if tokens.holds {
		t.Error("the store was not told to forget the code")
	}
	if !strings.Contains(stdout, `"cut":true`) {
		t.Errorf("the return value does not say it was cut: %q", stdout)
	}
}

// A store that would not answer means a phone that may still be reading, so the run fails rather
// than reporting a cut that did not happen.
func TestARevokeTheStoreRefusesIsAFailure(t *testing.T) {
	in := askingAgainst(t, &pretendTokens{holds: true, refuse: true})

	var code int
	_, stderr := capture(t, func() { code = run(in, []string{"revoke"}) })

	if code != 1 {
		t.Fatalf("exit %d — the phone was reported as cut off", code)
	}
	if !strings.Contains(stderr, "/tokens") {
		t.Errorf("the refusal does not say what would not answer: %q", stderr)
	}
}

// Pressing it on a store with no code asks for the state it is already in. That is answered, not
// refused — there is no name to mistype any more, so there is nothing for a refusal to catch.
func TestRevokeOnAStoreWithNoCodeIsAnsweredRatherThanRefused(t *testing.T) {
	in := askingAgainst(t, &pretendTokens{holds: false})

	var code int
	stdout, stderr := capture(t, func() { code = run(in, []string{"revoke"}) })

	if code != 0 {
		t.Fatalf("exit %d — having none was treated as a fault", code)
	}
	if !strings.Contains(stdout, `"cut":false`) {
		t.Errorf("the return value claims something was cut: %q", stdout)
	}
	if !strings.Contains(stderr, wordings["en"][phNothingWasReadingAsThat]) {
		t.Errorf("it does not say what actually happened: %q", stderr)
	}
}

// The list of paired phones used to be a file here, and a machine that upgraded still has one.
// Nothing reads it, so it is taken away rather than left to puzzle whoever finds it.
func TestTheOldListOfPhonesIsTakenAway(t *testing.T) {
	tokens := &pretendTokens{holds: true}
	in := askingAgainst(t, tokens)
	dir, err := pluginDir()
	if err != nil {
		t.Fatal(err)
	}
	left := filepath.Join(dir, phonesName)
	if err := os.WriteFile(left, []byte(`{"v":1,"paired":[{"label":"iPhone"}]}`), 0o600); err != nil {
		t.Fatal(err)
	}

	capture(t, func() { run(in, []string{"phones"}) })

	if _, err := os.Stat(left); !os.IsNotExist(err) {
		t.Errorf("the old list is still here: %v", err)
	}
}

// Neither takes anything after it, and a word nobody meant would answer a question that was not
// asked.
func TestTheTwoCommandsTakeNothing(t *testing.T) {
	in := askingAgainst(t, &pretendTokens{holds: true})

	for what, args := range map[string][]string{
		"revoke with a name": {"revoke", "iPhone"},
		"phones with a word": {"phones", "iPhone"},
	} {
		t.Run(what, func(t *testing.T) {
			var code int
			capture(t, func() { code = run(in, args) })

			if code != 1 {
				t.Errorf("exit %d", code)
			}
		})
	}
}
