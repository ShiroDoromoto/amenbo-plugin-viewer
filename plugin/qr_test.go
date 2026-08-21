package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	qrcode "rsc.io/qr"
)

// throwawayKey is a key of the right shape and no worth: pairing puts the configured key on the
// code, so a test that watches for it has to configure one.
var throwawayKey = base64.RawURLEncoding.EncodeToString(make([]byte, keySize))

// pretendStore is the far end of the pairing call: it takes the hash of a read token and says
// when it took it — and, like the real one, turns away a name it is already holding.
type pretendStore struct {
	offered  string
	label    string
	hash     string
	holds    map[string]bool
	refuse   bool
	issuedAt string
}

// pairingAgainst points the plugin at a stand-in store with a key configured, and replaces the
// display with one that hands back what was going to be drawn.
func pairingAgainst(t *testing.T, store *pretendStore) (in input, carried *pairing) {
	t.Helper()

	road := http.NewServeMux()
	road.HandleFunc("PUT /tokens", func(w http.ResponseWriter, r *http.Request) {
		store.offered = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		var asked struct{ Label, Hash string }
		json.NewDecoder(r.Body).Decode(&asked)
		store.label, store.hash = asked.Label, asked.Hash
		if store.refuse {
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{"error": "the database is not there"})
			return
		}
		if store.holds[asked.Label] {
			w.WriteHeader(http.StatusConflict)
			json.NewEncoder(w).Encode(map[string]string{"error": "a phone is already paired as " + asked.Label})
			return
		}
		if store.holds == nil {
			store.holds = map[string]bool{}
		}
		store.holds[asked.Label] = true
		store.issuedAt = "2026-08-09T09:00:00.000Z"
		json.NewEncoder(w).Encode(map[string]string{"label": asked.Label, "issued_at": store.issuedAt})
	})
	server := httptest.NewServer(road)
	t.Cleanup(server.Close)

	t.Setenv(envAuthToken, "the-write-token")
	t.Setenv(envEncryptionKey, throwawayKey)
	remembering(t)

	shown := &pairing{}
	was := present
	present = func(what []byte, _ bool) (string, string, error) {
		if err := json.Unmarshal(what, shown); err != nil {
			t.Errorf("what was about to be shown does not parse: %q", what)
		}
		return "image", "", nil
	}
	t.Cleanup(func() { present = was })

	return input{Config: map[string]any{configWorkerURL: server.URL}}, shown
}

func pairedPhones(t *testing.T) []phone {
	t.Helper()
	known, err := readPhones()
	if err != nil {
		t.Fatal(err)
	}
	return known.Paired
}

// Pairing issues a token that did not exist a moment ago, tells the store only its hash, and puts
// the value itself on the code — which is the whole of why the key never reaches the Worker.
func TestPairingIssuesATokenAndTellsTheStoreOnlyItsHash(t *testing.T) {
	store := &pretendStore{}
	in, shown := pairingAgainst(t, store)

	var code int
	stdout, _ := capture(t, func() { code = run(in, []string{"qr", "--label", "iPhone"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if store.offered != "the-write-token" {
		t.Errorf("the store was opened with %q, and issuing is the write token's door", store.offered)
	}
	if store.label != "iPhone" {
		t.Errorf("label = %q", store.label)
	}
	if shown.T == "" {
		t.Fatal("nothing was put on the code")
	}
	if store.hash != hashOf(shown.T) {
		t.Error("the hash the store was given is not of the token on the code")
	}
	if strings.Contains(store.hash, shown.T) || store.hash == shown.T {
		t.Error("the token itself reached the store")
	}
	if shown.K != throwawayKey {
		t.Error("the code does not carry the encryption key, so the phone could not read anything")
	}
	if shown.V != specVersion || shown.URL != in.setting(configWorkerURL) {
		t.Errorf("%+v", shown)
	}
	if shown.L != "iPhone" {
		t.Errorf("the code does not name the phone, so it cannot say which row on the PC is itself: %q", shown.L)
	}

	if paired := pairedPhones(t); len(paired) != 1 || paired[0].Label != "iPhone" || paired[0].IssuedAt != store.issuedAt {
		t.Errorf("the phone was not written down, so nobody can cut it off: %+v", paired)
	}
	if strings.Contains(stdout, shown.T) || strings.Contains(stdout, shown.K) {
		t.Error("the return value carries a secret")
	}
	if !strings.Contains(stdout, `"label":"iPhone"`) {
		t.Errorf("the return value does not name the phone: %q", stdout)
	}
}

// The code is issued, never redisplayed: pairing twice gives out two different tokens, so a
// second phone cannot read with the first one's.
func TestEachPairingDrawsItsOwnToken(t *testing.T) {
	store := &pretendStore{}
	in, shown := pairingAgainst(t, store)

	capture(t, func() { run(in, []string{"qr", "--label", "iPhone"}) })
	first := shown.T
	capture(t, func() { run(in, []string{"qr", "--label", "Android"}) })

	if first == shown.T {
		t.Error("the same token was handed to two phones")
	}
	if paired := pairedPhones(t); len(paired) != 2 {
		t.Errorf("both phones should be written down: %+v", paired)
	}
}

// A name that is taken is refused at the store, so the phone reading under it goes on reading.
// What the person is told has to carry the way out, since the store's own sentence says what
// happened and not what to do about it.
func TestPairingUnderANameThatIsTakenIsRefusedAndSaysHowToFreeIt(t *testing.T) {
	store := &pretendStore{}
	in, shown := pairingAgainst(t, store)

	capture(t, func() { run(in, []string{"qr", "--label", "iPhone"}) })
	first := shown.T
	var code int
	_, stderr := capture(t, func() { code = run(in, []string{"qr", "--label", "iPhone"}) })

	if code != 1 {
		t.Fatalf("exit %d — the second pairing was not refused", code)
	}
	if shown.T != first {
		t.Error("a code was shown for a token the store never took")
	}
	if !strings.Contains(stderr, "revoke iPhone") {
		t.Errorf("the refusal does not say how to free the name: %q", stderr)
	}
	if paired := pairedPhones(t); len(paired) != 1 || paired[0].Label != "iPhone" {
		t.Errorf("the phone that was reading did not stay written down as it was: %+v", paired)
	}
}

// A store that would not take the hash means a phone that cannot read, so nothing is written down
// and nothing is put on screen — a code that pairs nobody is worse than no code.
func TestAPairingTheStoreRefusesLeavesNothingBehind(t *testing.T) {
	store := &pretendStore{refuse: true}
	in, shown := pairingAgainst(t, store)

	var code int
	_, stderr := capture(t, func() { code = run(in, []string{"qr", "--label", "iPhone"}) })

	if code != 1 {
		t.Fatalf("exit %d — the pairing did not happen", code)
	}
	if shown.T != "" {
		t.Error("a code was shown for a token the store never took")
	}
	if paired := pairedPhones(t); len(paired) != 0 {
		t.Errorf("a phone was written down that cannot read: %+v", paired)
	}
	if !strings.Contains(stderr, "/tokens") {
		t.Errorf("the refusal does not say what would not answer: %q", stderr)
	}
}

// With no route there is nothing to pair against, and with no key the phone would read ciphertext
// it cannot open. Both are refused before anything is asked of the user or issued at the store.
func TestPairingRefusesBeforeItAsksForAnything(t *testing.T) {
	t.Run("no route", func(t *testing.T) {
		t.Setenv(envAuthToken, "")
		t.Setenv(envEncryptionKey, throwawayKey)

		var code int
		_, stderr := capture(t, func() { code = run(input{}, []string{"qr", "--label", "iPhone"}) })

		if code != 1 || !strings.Contains(stderr, "setup") {
			t.Errorf("exit %d: %q", code, stderr)
		}
	})
	t.Run("no key", func(t *testing.T) {
		t.Setenv(envAuthToken, "the-write-token")
		t.Setenv(envEncryptionKey, "")

		var code int
		_, stderr := capture(t, func() {
			code = run(input{Config: map[string]any{configWorkerURL: "https://viewer.example.workers.dev"}}, []string{"qr", "--label", "iPhone"})
		})

		if code != 1 || !strings.Contains(stderr, "setup") {
			t.Errorf("exit %d: %q", code, stderr)
		}
	})
}

// The image is what a phone is meant to read, so it has to be a real one, written where only
// this user can reach it — it carries the key, and a file anyone on the machine could open would
// hand over what the QR exists to keep off the network.
//
// It is also not left behind: what says so is that its removal was set going for the directory it
// was written in, with nothing said to the caller about a file to go and delete.
func TestTheImageIsWrittenWhereOnlyThisUserCanReadItAndThenTakesItselfAway(t *testing.T) {
	code := codeForATest(t)
	opened := watchTheViewer(t)
	scheduled := watchTheErasing(t, nil)

	left, err := capturedOpen(t, code)
	if err != nil {
		t.Fatal(err)
	}

	if *opened == "" {
		t.Fatal("nothing was handed to a viewer")
	}
	if left != "" {
		t.Errorf("the run says it left %q behind, and the image takes itself away", left)
	}
	if *scheduled != filepath.Dir(*opened) {
		t.Errorf("the removal was set going for %q, and the image is in %q", *scheduled, filepath.Dir(*opened))
	}
	written, err := os.Stat(*opened)
	if err != nil {
		t.Fatal(err)
	}
	if mode := written.Mode().Perm(); mode != 0o600 {
		t.Errorf("the code is written %o, and it carries the key", mode)
	}
	raw, err := os.ReadFile(*opened)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := png.Decode(bytes.NewReader(raw)); err != nil {
		t.Errorf("what was opened is not an image: %v", err)
	}
	os.RemoveAll(filepath.Dir(*opened))
}

// When the removal could not be set going, the file is still there and the key is still on it —
// so it is said out loud and handed back, rather than pulled out from under a viewer that is
// showing it or left somewhere nobody was told about.
func TestAnImageThatCannotTakeItselfAwayIsSaidOutLoud(t *testing.T) {
	code := codeForATest(t)
	opened := watchTheViewer(t)
	watchTheErasing(t, errors.New("nothing could be started"))

	var left string
	var err error
	_, stderr := capture(t, func() { left, err = openAsAnImage(code) })
	if err != nil {
		t.Fatal(err)
	}

	if left != *opened {
		t.Errorf("the run left %q and opened %q", left, *opened)
	}
	if !strings.Contains(stderr, left) {
		t.Errorf("nobody was told where the file with the key on it is: %q", stderr)
	}
	os.RemoveAll(filepath.Dir(left))
}

// **The word the image calls this binary back with removes what this binary wrote, and nothing
// else.** It answers to that word like any other, so one that took whatever it was pointed at
// would be a delete anybody on the machine could aim at anything of the user's.
func TestForgettingACodeRefusesADirectoryItDidNotWrite(t *testing.T) {
	mine := t.TempDir()

	var code int
	_, stderr := capture(t, func() { code = run(input{}, []string{forgetTheCodeCommand, mine}) })

	if code != 1 {
		t.Fatalf("exit %d — a directory this never wrote was accepted for removal", code)
	}
	if _, err := os.Stat(mine); err != nil {
		t.Errorf("it was removed anyway: %v", err)
	}
	if !strings.Contains(stderr, mine) {
		t.Errorf("the refusal does not say what it was pointed at: %q", stderr)
	}
}

// The settings screen has its own box for the phone's name, and the answer arrives the way a
// secret setting does. Without it read here, the button would run with no name and go looking for
// a terminal that a settings screen does not have.
func TestTheNameTypedAtTheButtonNamesThePhone(t *testing.T) {
	store := &pretendStore{}
	in, shown := pairingAgainst(t, store)
	t.Setenv(envAskLabel, "  iPhone  ")

	var code int
	capture(t, func() { code = run(in, []string{"qr"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if store.label != "iPhone" || shown.L != "iPhone" {
		t.Errorf("the store was told %q and the code carries %q", store.label, shown.L)
	}
}

// codeForATest is a code of the right shape to write out and open.
func codeForATest(t *testing.T) *qrcode.Code {
	t.Helper()
	code, err := qrcode.Encode(`{"v":1,"url":"https://viewer.example.workers.dev","t":"a","k":"b"}`, qrcode.M)
	if err != nil {
		t.Fatal(err)
	}
	return code
}

// watchTheViewer stands in for whatever opens images and hands back where to read what it was
// given.
func watchTheViewer(t *testing.T) *string {
	t.Helper()
	var opened string
	was := openInTheViewer
	openInTheViewer = func(path string) error { opened = path; return nil }
	t.Cleanup(func() { openInTheViewer = was })
	return &opened
}

// watchTheErasing stands in for the run that outlives this one, answering as told and handing
// back the directory it was asked about. A test must not start the real one: the executable under
// a test is the test binary.
func watchTheErasing(t *testing.T, answer error) *string {
	t.Helper()
	var scheduled string
	was := eraseLater
	eraseLater = func(dir string) error { scheduled = dir; return answer }
	t.Cleanup(func() { eraseLater = was })
	return &scheduled
}

// capturedOpen runs the image path with the diagnostics held, and hands back what it said it left
// behind.
func capturedOpen(t *testing.T, code *qrcode.Code) (string, error) {
	t.Helper()
	var left string
	var err error
	capture(t, func() { left, err = openAsAnImage(code) })
	return left, err
}

// The drawing needs its quiet zone: without four modules of white on every side a reader has no
// edges to find, and the code on a terminal is the one nobody can adjust afterwards.
func TestTheDrawnCodeKeepsItsQuietZone(t *testing.T) {
	code, err := qrcode.Encode(`{"v":1,"url":"https://viewer.example.workers.dev","t":"a","k":"b"}`, qrcode.M)
	if err != nil {
		t.Fatal(err)
	}

	lines := strings.Split(strings.TrimRight(blocksFor(code), "\n"), "\n")
	side := code.Size + quietZone*2

	if len(lines) != (side+1)/2 {
		t.Errorf("%d lines for %d modules a side, at two modules per line", len(lines), side)
	}
	for _, at := range []int{0, len(lines) - 1} {
		if strings.TrimSpace(lines[at]) != "" {
			t.Errorf("line %d is not quiet: %q", at, lines[at])
		}
	}
	for _, line := range lines {
		if got := len([]rune(line)); got != side {
			t.Fatalf("a line is %d wide and the code is %d modules across", got, side)
		}
		if !strings.HasPrefix(line, strings.Repeat(" ", quietZone)) || !strings.HasSuffix(line, strings.Repeat(" ", quietZone)) {
			t.Fatalf("a line has no quiet zone on both sides: %q", line)
		}
	}
}
