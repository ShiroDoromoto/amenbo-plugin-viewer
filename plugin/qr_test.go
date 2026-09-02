package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	qrcode "rsc.io/qr"
)

// throwawayKey is a key of the right shape and no worth: pairing puts the configured key on the
// code, so a test that watches for it has to configure one.
var throwawayKey = base64.RawURLEncoding.EncodeToString(make([]byte, keySize))

// pretendStore is the far end of the pairing call: it takes the hash of a read code and says when
// it took it — and, like the real one, replaces whatever it was holding.
type pretendStore struct {
	offered  string
	hash     string
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
		var asked struct{ Hash string }
		json.NewDecoder(r.Body).Decode(&asked)
		store.hash = asked.Hash
		if store.refuse {
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{"error": "the database is not there"})
			return
		}
		store.issuedAt = "2026-08-09T09:00:00.000Z"
		json.NewEncoder(w).Encode(map[string]string{"issued_at": store.issuedAt})
	})
	server := httptest.NewServer(road)
	t.Cleanup(server.Close)

	t.Setenv(envAuthToken, "the-write-token")
	t.Setenv(envEncryptionKey, throwawayKey)
	remembering(t)

	inATerminal(t)
	shown := &pairing{}
	was := present
	present = func(_ string, what []byte, _ bool) error {
		if err := json.Unmarshal(what, shown); err != nil {
			t.Errorf("what was about to be shown does not parse: %q", what)
		}
		return nil
	}
	t.Cleanup(func() { present = was })

	return input{Config: map[string]any{configWorkerURL: server.URL}}, shown
}

// Pairing issues a token that did not exist a moment ago, tells the store only its hash, and puts
// the value itself on the code — which is the whole of why the key never reaches the Worker.
func TestPairingIssuesATokenAndTellsTheStoreOnlyItsHash(t *testing.T) {
	store := &pretendStore{}
	in, shown := pairingAgainst(t, store)

	var code int
	stdout, stderr := capture(t, func() { code = run(in, []string{"qr"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if store.offered != "the-write-token" {
		t.Errorf("the store was opened with %q, and issuing is the write token's door", store.offered)
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

	// **The pairing rides back on the answer, because that is what the form draws**:
	// Amenbo is handed the string and makes the code out of it. It is not a secret reaching
	// somewhere new — the key is Amenbo's own setting, handed to this run in the environment —
	// and the execution log keeps stderr rather than the answer.
	var said answered
	if err := json.Unmarshal([]byte(stdout), &said); err != nil {
		t.Fatalf("the answer is not one the form can read: %q", stdout)
	}
	if len(said.Show) != 2 || said.Show[1].QR == "" {
		t.Fatalf("the answer carries no code for the form to draw: %+v", said.Show)
	}
	var handed pairing
	if err := json.Unmarshal([]byte(said.Show[1].QR), &handed); err != nil {
		t.Fatalf("what the form would draw is not a pairing: %q", said.Show[1].QR)
	}
	if handed != *shown {
		t.Errorf("the form would draw %+v and the terminal drew %+v", handed, *shown)
	}
	if !strings.Contains(stdout, `"issued_at":"`+store.issuedAt+`"`) {
		t.Errorf("the return value does not say when the code was issued: %q", stdout)
	}
	if strings.Contains(stderr, shown.T) || strings.Contains(stderr, shown.K) {
		t.Error("a secret reached the execution log, which is what stderr becomes")
	}
}

// The code is issued, never redisplayed: pairing twice gives out two different tokens, so a
// second phone cannot read with the first one's.
func TestEachPairingDrawsItsOwnToken(t *testing.T) {
	store := &pretendStore{}
	in, shown := pairingAgainst(t, store)

	capture(t, func() { run(in, []string{"qr"}) })
	first := shown.T
	capture(t, func() { run(in, []string{"qr"}) })

	if first == shown.T {
		t.Error("the same token was drawn twice")
	}
	if store.hash != hashOf(shown.T) {
		t.Error("the store was left holding the hash of the code that was replaced")
	}
}

// Issuing again is not refused any more: there is one code, so pressing pair a second time draws
// a new one and the store is left holding that one's hash alone.
func TestPairingAgainReplacesTheCodeTheStoreHolds(t *testing.T) {
	store := &pretendStore{}
	in, shown := pairingAgainst(t, store)

	capture(t, func() { run(in, []string{"qr"}) })
	first := shown.T
	var code int
	capture(t, func() { code = run(in, []string{"qr"}) })

	if code != 0 {
		t.Fatalf("exit %d — pairing again was refused", code)
	}
	if shown.T == first {
		t.Error("the second pairing drew the code the first one drew")
	}
	if store.hash != hashOf(shown.T) {
		t.Error("the store holds the hash of the first code, so the second phone could not read")
	}
}

// A store that would not take the hash means a phone that cannot read, so nothing is written down
// and nothing is put on screen — a code that pairs nobody is worse than no code.
func TestAPairingTheStoreRefusesLeavesNothingBehind(t *testing.T) {
	store := &pretendStore{refuse: true}
	in, shown := pairingAgainst(t, store)

	var code int
	_, stderr := capture(t, func() { code = run(in, []string{"qr"}) })

	if code != 1 {
		t.Fatalf("exit %d — the pairing did not happen", code)
	}
	if shown.T != "" {
		t.Error("a code was shown for a token the store never took")
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
		_, stderr := capture(t, func() { code = run(input{}, []string{"qr"}) })

		if code != 1 || !strings.Contains(stderr, "3.") {
			t.Errorf("exit %d: %q", code, stderr)
		}
	})
	t.Run("no key", func(t *testing.T) {
		t.Setenv(envAuthToken, "the-write-token")
		t.Setenv(envEncryptionKey, "")

		var code int
		_, stderr := capture(t, func() {
			code = run(input{Config: map[string]any{configWorkerURL: "https://viewer.example.workers.dev"}}, []string{"qr"})
		})

		if code != 1 || !strings.Contains(stderr, "3.") {
			t.Errorf("exit %d: %q", code, stderr)
		}
	})
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
	was := openInTheSystem
	openInTheSystem = func(target string) error { opened = target; return nil }
	t.Cleanup(func() { openInTheSystem = was })
	return &opened
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

// **The page is for a phone, and the screen it is drawn on belongs to a PC.** Opening it in the
// browser here would land the App Store on the one machine that cannot install from it, leaving
// the person to carry the address across by hand — which is the gap the button exists to close.
func TestTheAppButtonDrawsTheStorePageRatherThanOpeningItHere(t *testing.T) {
	drawn, secret := drawingIsHeld(t)
	opened := watchTheViewer(t)
	inATerminal(t)

	var code int
	_, stderr := capture(t, func() { code = run(input{}, []string{"app"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if len(*drawn) != len(theStores) {
		t.Fatalf("%d code(s) drawn for %d store(s): %+v", len(*drawn), len(theStores), *drawn)
	}
	for at, store := range theStores {
		if got := (*drawn)[at]; got.carried != store.link {
			t.Errorf("the %s code carries %q, and the app is at %q", store.phone, got.carried, store.link)
		}
		// **Two codes side by side need a word each.** Without the name above it, the one a
		// person points a camera at is whichever they guessed.
		if got := (*drawn)[at]; got.titled != store.phone {
			t.Errorf("a code was drawn under %q rather than %q, so nothing says which phone it is for",
				got.titled, store.phone)
		}
		if !strings.Contains(stderr, store.link) {
			t.Errorf("the %s address is nowhere for someone who would rather type it: %q", store.phone, stderr)
		}
	}
	if *secret {
		t.Error("a public page was drawn as a code carrying a secret")
	}
	if *opened != "" {
		t.Errorf("the page was opened here, on the machine that cannot install it: %q", *opened)
	}
}

// A machine with neither a screen to open an image on nor a terminal to draw blocks in has
// nowhere to put a code — and that is not a failure to report, because the address in words is
// the whole of what the code was carrying. Drawing it anyway would leave a screenful of blocks
// in a log nobody can point a camera at.
func TestAMachineWithNothingToDrawOnIsGivenTheAddressInWords(t *testing.T) {
	drawn, _ := drawingIsHeld(t)
	nothingToDrawOn(t)

	var code int
	_, stderr := capture(t, func() { code = run(input{}, []string{"app"}) })

	if code != 0 {
		t.Fatalf("exit %d — a machine with nothing to draw on is not a failure to report", code)
	}
	if len(*drawn) != 0 {
		t.Errorf("a code was drawn where nothing could put it in front of a camera: %+v", *drawn)
	}
	for _, store := range theStores {
		if !strings.Contains(stderr, store.link) {
			t.Errorf("the %s address the person has to reach by hand was not written out: %q", store.phone, stderr)
		}
	}
}

// The settings screen has no terminal, so what it draws is what rides back on the answer — and
// with two stores that is a heading and a code each. A code with nothing above it is one a person
// holding one phone has to guess at.
func TestTheFormIsHandedAHeadedCodeForEachStore(t *testing.T) {
	drawn, _ := drawingIsHeld(t)
	fromTheSettingsScreen(t)

	var code int
	stdout, _ := capture(t, func() { code = run(input{}, []string{"app"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if len(*drawn) != 0 {
		t.Errorf("a code was drawn into a terminal the settings screen does not have: %+v", *drawn)
	}
	var said answered
	if err := json.Unmarshal([]byte(stdout), &said); err != nil {
		t.Fatalf("the answer is not one the form can read: %q", stdout)
	}
	// The line telling the reader what to do with the codes, then the codes themselves.
	if want := 1 + 2*len(theStores); len(said.Show) != want {
		t.Fatalf("the answer carries %d part(s), and %d store(s) want %d: %+v",
			len(said.Show), len(theStores), want, said.Show)
	}
	if said.Show[0].Text == "" {
		t.Errorf("nothing tells the reader what the codes are for: %+v", said.Show[0])
	}
	for at, store := range theStores {
		heading, drawn := said.Show[1+at*2], said.Show[2+at*2]
		if heading.Heading != store.phone {
			t.Errorf("the code for %s is headed %q", store.phone, heading.Heading)
		}
		if drawn.QR != store.link {
			t.Errorf("the %s code carries %q, and the app is at %q", store.phone, drawn.QR, store.link)
		}
	}
}

// fromTheSettingsScreen is the run nobody typed: there is a display, and no terminal to draw
// into — so what the person is shown is whatever rides back on the answer.
func fromTheSettingsScreen(t *testing.T) {
	t.Helper()
	wasScreen, wasTerminal := thereIsAScreen, thereIsATerminal
	thereIsAScreen, thereIsATerminal = onAScreen, func() bool { return false }
	t.Cleanup(func() { thereIsAScreen, thereIsATerminal = wasScreen, wasTerminal })
}

// aDrawnCode is one code a run was about to put in front of a camera: the name it was drawn
// under, and the text it carried.
type aDrawnCode struct{ titled, carried string }

// drawingIsHeld stands in for putting codes in front of a camera, and hands back the ones that
// were going to be drawn, in order, along with whether any of them carried a secret. What comes
// back empty is a run that drew nothing.
func drawingIsHeld(t *testing.T) (drawn *[]aDrawnCode, secret *bool) {
	t.Helper()
	var codes []aDrawnCode
	var hidden bool
	was := present
	present = func(titled string, bytes []byte, carriesASecret bool) error {
		codes = append(codes, aDrawnCode{titled: titled, carried: string(bytes)})
		hidden = hidden || carriesASecret
		return nil
	}
	t.Cleanup(func() { present = was })
	return &codes, &hidden
}

// inATerminal is the machine somebody typed this into: there is a display, and
// asking after a terminal would reach for the one a GUI does not have.
func inATerminal(t *testing.T) {
	t.Helper()
	wasScreen, wasTerminal := thereIsAScreen, thereIsATerminal
	thereIsAScreen, thereIsATerminal = onAScreen, func() bool { return true }
	t.Cleanup(func() { thereIsAScreen, thereIsATerminal = wasScreen, wasTerminal })
}

// nothingToDrawOn is the machine with no display and no terminal either — a run under something
// that started it with neither.
func nothingToDrawOn(t *testing.T) {
	t.Helper()
	wasScreen, wasTerminal := thereIsAScreen, thereIsATerminal
	thereIsAScreen, thereIsATerminal = withNoScreen, func() bool { return false }
	t.Cleanup(func() { thereIsAScreen, thereIsATerminal = wasScreen, wasTerminal })
}
