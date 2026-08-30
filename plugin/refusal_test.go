package main

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// answering stands a door up that turns everything down the way the test asks it to, and hands
// back a store pointed at it.
func answering(t *testing.T, status int, body string, headers map[string]string) store {
	t.Helper()
	door := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		for name, value := range headers {
			w.Header().Set(name, value)
		}
		w.WriteHeader(status)
		w.Write([]byte(body))
	}))
	t.Cleanup(door.Close)
	return store{url: door.URL, token: "a-throwaway-token"}
}

// refusalFor drives one refusal through the door every send goes out of.
func refusalFor(t *testing.T, where store) error {
	t.Helper()
	_, err := where.put("/records", placement{SpecV: specVersion})
	if err == nil {
		t.Fatal("a refused send read as a successful one")
	}
	return err
}

// A store with no room left is the Worker's own to explain, and it does — the next move is in its
// own sentence, which is the whole point of not showing how much room is left. Adding a second
// next move here would talk over it.
func TestARefusalThatAlreadySaysWhatToDoIsPassedOnAsItIs(t *testing.T) {
	where := answering(t, http.StatusInsufficientStorage,
		`{"error":"there is no room left in this store — raising the account it lives in is what makes room"}`, nil)

	err := refusalFor(t, where)

	if !strings.Contains(err.Error(), "no room left") || !strings.Contains(err.Error(), "makes room") {
		t.Errorf("%v does not carry the store's own sentence", err)
	}
	if strings.Contains(err.Error(), "setup") {
		t.Errorf("%v sends the user somewhere the store did not", err)
	}
}

// What is wrong is on this side, and the Worker cannot know the fix — so the sentence has to
// carry it, or the user is left with a number.
func TestARefusalThePluginCausedSaysWhatToDoAboutIt(t *testing.T) {
	for _, refusal := range []struct {
		what   string
		status int
		says   string
	}{
		{"a token the Worker does not take", http.StatusUnauthorized, "setup"},
		{"a token of the wrong kind", http.StatusForbidden, "setup"},
		{"a Worker standing without its Secret", http.StatusServiceUnavailable, "setup"},
		{"a route that Worker does not have", http.StatusNotFound, "another version"},
		{"a body that Worker will not read", http.StatusBadRequest, "another version"},
		{"more records than that Worker takes", http.StatusRequestEntityTooLarge, "another version"},
	} {
		t.Run(refusal.what, func(t *testing.T) {
			err := refusalFor(t, answering(t, refusal.status, `{"error":"no"}`, nil))

			if !strings.Contains(err.Error(), refusal.says) {
				t.Errorf("%v does not say what to do about it", err)
			}
		})
	}
}

// An answer that says when to come back is a wait, and the one thing not to do about it is to
// stand the route up again.
func TestAnAnswerThatSaysWhenToComeBackIsAWait(t *testing.T) {
	where := answering(t, http.StatusServiceUnavailable,
		`{"error":"the whole of this store is being placed again"}`, map[string]string{"Retry-After": "5"})

	err := refusalFor(t, where)

	if !strings.Contains(err.Error(), "clears itself") || !strings.Contains(err.Error(), "5") {
		t.Errorf("%v does not read as a wait", err)
	}
	if strings.Contains(err.Error(), "setup") {
		t.Errorf("%v sends the user to stand the route up over something that fixes itself", err)
	}
}

// An exception the Worker did not catch is answered by Cloudflare in front of it, as a plain page
// rather than the Worker's JSON. The number on that page is the one thing worth having, so it is
// not dropped for not being the shape this build expected.
func TestAnAnswerThatIsNotTheWorkersIsSaidToBeCloudflares(t *testing.T) {
	where := answering(t, http.StatusInternalServerError, "error code: 1101", nil)

	err := refusalFor(t, where)

	if !strings.Contains(err.Error(), "1101") {
		t.Errorf("%v drops the one number on Cloudflare's page", err)
	}
	if !strings.Contains(err.Error(), "Cloudflare") {
		t.Errorf("%v reads as the Worker having said this", err)
	}
}

// A page is not a sentence: whatever markup came back, what reaches the log is one bounded line.
func TestAPageThatCameBackInsteadOfASentenceIsCutToALine(t *testing.T) {
	where := answering(t, http.StatusBadGateway, "<html>\n  <body>"+strings.Repeat("very long ", 100)+"</body>\n</html>", nil)

	err := refusalFor(t, where)

	if strings.Contains(err.Error(), "\n") {
		t.Errorf("a refusal broke across lines: %q", err)
	}
	if len(err.Error()) > 2*bodyOfOneLine {
		t.Errorf("a refusal ran to %d characters", len(err.Error()))
	}
}

// The one thing a diagnostic must never carry. It travels on every request, so every refusal is
// a chance to write it somewhere a person can read.
func TestARefusalNeverCarriesTheToken(t *testing.T) {
	where := answering(t, http.StatusUnauthorized, `{"error":"a bearer token is required"}`, nil)

	err := refusalFor(t, where)

	if strings.Contains(err.Error(), where.token) {
		t.Errorf("a refusal carried the write token: %v", err)
	}
}

// The doors with a reading of their own keep it: a label already taken is not a refusal to relay
// but a move to name, and a label that was not there is not a refusal at all.
func TestADoorWithItsOwnReadingOfAnAnswerKeepsIt(t *testing.T) {
	taken := answering(t, http.StatusConflict, `{"error":"a phone is already paired"}`, nil)

	_, err := taken.issue("iPhone", strings.Repeat("a", 64))

	if err == nil || !strings.Contains(err.Error(), wordings["en"][phTheUnpairButton]) {
		t.Errorf("issuing over a paired phone said %v, want the move that frees the name", err)
	}

	gone := answering(t, http.StatusNotFound, `{"error":"no token is labelled"}`, nil)

	cut, err := gone.cutOff("iPhone")

	if err != nil || cut {
		t.Errorf("cutting off a phone that was not there = %v, %v; want it read as nothing to cut", cut, err)
	}
}

// A refusal is a value, so a door can ask what it was before deciding whether the words here are
// the ones the user should read.
func TestARefusalCanBeAskedWhatItWas(t *testing.T) {
	err := refusalFor(t, answering(t, http.StatusConflict, `{"error":"no"}`, nil))

	var turnedDown storeRefused
	if !errors.As(err, &turnedDown) {
		t.Fatalf("%v is not a refusal a door can read", err)
	}
	if turnedDown.status != http.StatusConflict || turnedDown.path != "/records" {
		t.Errorf("the refusal says %d at %q", turnedDown.status, turnedDown.path)
	}
}

// The connection is what a send is slow without, so the reuse is worth a test rather than a
// reading of the code: three sends in one run leave from one socket.
func TestEverySendInOneRunGoesOutOnOneConnection(t *testing.T) {
	var callers []string
	door := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callers = append(callers, r.RemoteAddr)
		w.Write([]byte(`{"seq":1}`))
	}))
	t.Cleanup(door.Close)
	where := store{url: door.URL, token: "a-throwaway-token"}

	for range 3 {
		if _, err := where.put("/records", placement{SpecV: specVersion}); err != nil {
			t.Fatalf("a send the door answered read as a failure: %v", err)
		}
	}

	if len(callers) != 3 {
		t.Fatalf("the door was asked %d times, where three sends were made", len(callers))
	}
	for _, caller := range callers[1:] {
		if caller != callers[0] {
			t.Errorf("the sends came from %v — a second connection means the first was not kept", callers)
			break
		}
	}
}

// Holding the client must not lose what it was carrying: a hook nobody is waiting on still has to
// end, so a door that never answers has to give the run back rather than hold it.
func TestACallToTheStoreIsStillGivenBack(t *testing.T) {
	silence := make(chan struct{})
	door := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		<-silence
	}))
	t.Cleanup(func() { close(silence); door.Close() })

	if overTheWire.Timeout != sendTimeout {
		t.Fatalf("the held client waits %v, where a send is bounded at %v", overTheWire.Timeout, sendTimeout)
	}
	held := overTheWire
	overTheWire = &http.Client{Timeout: 50 * time.Millisecond}
	t.Cleanup(func() { overTheWire = held })

	_, err := store{url: door.URL, token: "a-throwaway-token"}.put("/records", placement{SpecV: specVersion})

	if err == nil {
		t.Fatal("a door that never answered read as a send that landed")
	}
	if !strings.Contains(err.Error(), "did not answer") {
		t.Errorf("%v does not say the door left the call hanging", err)
	}
}
