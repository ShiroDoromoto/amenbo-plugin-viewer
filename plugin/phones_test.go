package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// pretendTokens is the far end of a revoke: it remembers which names it holds, and what it was
// asked to forget.
type pretendTokens struct {
	holds  map[string]bool
	asked  string
	path   string
	offer  string
	refuse bool
}

// cuttingAgainst points the plugin at a store that holds the named phones, with the record here
// saying the same.
func cuttingAgainst(t *testing.T, tokens *pretendTokens, paired ...string) input {
	t.Helper()

	road := http.NewServeMux()
	road.HandleFunc("DELETE /tokens/{label}", func(w http.ResponseWriter, r *http.Request) {
		tokens.offer = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		tokens.path = r.URL.EscapedPath()
		tokens.asked = r.PathValue("label")
		if tokens.refuse {
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{"error": "the database is not there"})
			return
		}
		if !tokens.holds[tokens.asked] {
			w.WriteHeader(http.StatusNotFound)
			json.NewEncoder(w).Encode(map[string]string{"error": "no token is labelled " + tokens.asked})
			return
		}
		delete(tokens.holds, tokens.asked)
		json.NewEncoder(w).Encode(map[string]string{"label": tokens.asked})
	})
	server := httptest.NewServer(road)
	t.Cleanup(server.Close)

	t.Setenv(envAuthToken, "the-write-token")
	remembering(t)
	for _, label := range paired {
		if err := rememberThePhone(label, "2026-08-09T09:00:00.000Z"); err != nil {
			t.Fatal(err)
		}
	}
	return input{Config: map[string]any{configWorkerURL: server.URL}}
}

// The listing is what somebody chooses from before cutting one off, so it has to name every phone
// that was paired and say when.
func TestThePhonesListedAreTheOnesThatWerePaired(t *testing.T) {
	in := cuttingAgainst(t, &pretendTokens{holds: map[string]bool{}}, "iPhone", "Pixel")

	var code int
	stdout, stderr := capture(t, func() { code = run(in, []string{"phones"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	var answer struct {
		Show   []shownPart `json:"show"`
		Paired []phone     `json:"paired"`
	}
	if err := json.Unmarshal([]byte(stdout), &answer); err != nil {
		t.Fatalf("stdout is the return value and it does not parse: %q", stdout)
	}
	listed := answer.Paired
	if len(listed) != 2 || listed[0].Label != "iPhone" || listed[1].Label != "Pixel" {
		t.Errorf("%+v", listed)
	}
	if listed[0].IssuedAt == "" {
		t.Error("a phone is listed with no day, and the day is half of what tells two of them apart")
	}
	if !strings.Contains(stderr, "iPhone") || !strings.Contains(stderr, "Pixel") {
		t.Errorf("nothing a person can read came out: %q", stderr)
	}
	// The settings screen has no log to read, so the same two names have to be drawn on it —
	// they are what the box that unpairs one takes typed.
	drawn := drawnText(answer.Show)
	if !strings.Contains(drawn, "iPhone") || !strings.Contains(drawn, "Pixel") {
		t.Errorf("the settings screen was handed %q", drawn)
	}
}

// drawnText flattens what a run asked the settings screen to draw, so a test can ask whether a
// name reached the form without caring which part carried it.
func drawnText(shown []shownPart) string {
	var said []string
	for _, part := range shown {
		said = append(said, part.Text, part.Heading)
		said = append(said, part.List...)
	}
	return strings.Join(said, "\n")
}

// Nothing paired is not a fault — it is what every install looks like until somebody runs qr —
// so it answers with an empty list and says what to do about it.
func TestNoPhonePairedIsAnAnswerRatherThanAFailure(t *testing.T) {
	in := cuttingAgainst(t, &pretendTokens{holds: map[string]bool{}})

	var code int
	stdout, stderr := capture(t, func() { code = run(in, []string{"phones"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	var answer struct {
		Show   []shownPart `json:"show"`
		Paired []phone     `json:"paired"`
	}
	if err := json.Unmarshal([]byte(stdout), &answer); err != nil {
		t.Fatalf("stdout is the return value and it does not parse: %q", stdout)
	}
	if len(answer.Paired) != 0 {
		t.Errorf("the return value is not an empty list: %q", stdout)
	}
	// How to pair one is a button, and it is said on both faces — the log for whoever typed
	// this, the form for whoever pressed it.
	pairing := wordings["en"][phThePairButton]
	if !strings.Contains(stderr, pairing) {
		t.Errorf("it does not say how to pair one: %q", stderr)
	}
	if !strings.Contains(drawnText(answer.Show), pairing) {
		t.Errorf("the settings screen was not told how to pair one: %q", stdout)
	}
}

// Cutting one phone off leaves the others reading, which is the whole reason they do not share a
// token — and the store is told before the record here forgets, so a failure cannot leave a phone
// reading under a name nobody can see.
func TestRevokeCutsOnePhoneOffAndLeavesTheRest(t *testing.T) {
	tokens := &pretendTokens{holds: map[string]bool{"iPhone": true, "Pixel": true}}
	in := cuttingAgainst(t, tokens, "iPhone", "Pixel")

	var code int
	stdout, _ := capture(t, func() { code = run(in, []string{"revoke", "iPhone"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if tokens.offer != "the-write-token" {
		t.Errorf("cutting one off is the write token's door, and %q was offered", tokens.offer)
	}
	if tokens.asked != "iPhone" || tokens.holds["iPhone"] {
		t.Error("the store was not told to forget it")
	}
	if !tokens.holds["Pixel"] {
		t.Error("the other phone was cut off too")
	}
	if paired := pairedPhones(t); len(paired) != 1 || paired[0].Label != "Pixel" {
		t.Errorf("the record here does not match what the store holds: %+v", paired)
	}
	if !strings.Contains(stdout, `"cut":true`) {
		t.Errorf("the return value does not say it was cut: %q", stdout)
	}
}

// A store that would not answer means a phone that is still reading. Forgetting the row here
// would leave it reading under a name nobody can see any more — the one state with no way back
// but re-keying everything.
func TestARevokeTheStoreRefusesKeepsTheRow(t *testing.T) {
	tokens := &pretendTokens{holds: map[string]bool{"iPhone": true}, refuse: true}
	in := cuttingAgainst(t, tokens, "iPhone")

	var code int
	_, stderr := capture(t, func() { code = run(in, []string{"revoke", "iPhone"}) })

	if code != 1 {
		t.Fatalf("exit %d — the phone was reported as cut off", code)
	}
	if paired := pairedPhones(t); len(paired) != 1 {
		t.Errorf("the row went while the phone is still reading: %+v", paired)
	}
	if !strings.Contains(stderr, "/tokens") {
		t.Errorf("the refusal does not say what would not answer: %q", stderr)
	}
}

// A name the store does not hold is nothing reading, so what is left is a row here that says
// otherwise. Tidying it is the honest end — and saying so is what keeps it from reading as a
// phone that was cut off just now.
func TestRevokeTidiesARowTheStoreDoesNotHold(t *testing.T) {
	tokens := &pretendTokens{holds: map[string]bool{}}
	in := cuttingAgainst(t, tokens, "iPhone")

	var code int
	stdout, stderr := capture(t, func() { code = run(in, []string{"revoke", "iPhone"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if paired := pairedPhones(t); len(paired) != 0 {
		t.Errorf("the stale row is still here: %+v", paired)
	}
	if !strings.Contains(stdout, `"cut":false`) {
		t.Errorf("the return value claims something was cut: %q", stdout)
	}
	if !strings.Contains(stderr, "tidied") {
		t.Errorf("it does not say what actually happened: %q", stderr)
	}
}

// A name nobody has is a typo, and answering "done" to one would leave somebody believing they
// had cut off a phone that is still reading.
func TestRevokeRefusesANameNobodyHas(t *testing.T) {
	in := cuttingAgainst(t, &pretendTokens{holds: map[string]bool{}}, "iPhone")

	var code int
	_, stderr := capture(t, func() { code = run(in, []string{"revoke", "iPhon"}) })

	if code != 1 {
		t.Fatalf("exit %d — a typo was answered as done", code)
	}
	if paired := pairedPhones(t); len(paired) != 1 {
		t.Errorf("the phone that is reading was forgotten: %+v", paired)
	}
	if !strings.Contains(stderr, "iPhon") || !strings.Contains(stderr, "phones") {
		t.Errorf("the refusal does not name it or say where to look: %q", stderr)
	}
}

// A label is whatever the person typed, so it goes into the path escaped. Left raw, a name with a
// slash in it would name another endpoint and a name with a space would not be a request at all.
func TestALabelIsEscapedIntoThePath(t *testing.T) {
	tokens := &pretendTokens{holds: map[string]bool{"my phone/2": true}}
	in := cuttingAgainst(t, tokens, "my phone/2")

	var code int
	capture(t, func() { code = run(in, []string{"revoke", "my phone/2"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if strings.Contains(tokens.path, " ") || strings.Contains(strings.TrimPrefix(tokens.path, "/tokens/"), "/") {
		t.Errorf("the label went into the path raw: %q", tokens.path)
	}
	if tokens.asked != "my phone/2" {
		t.Errorf("the store read the name as %q", tokens.asked)
	}
}

// The settings screen has no command line: the name of the phone to cut off arrives in the box
// the button declares, the way the phone's name does when one is paired.
func TestTheNameToUnpairIsTakenFromTheSettingsScreensBox(t *testing.T) {
	tokens := &pretendTokens{holds: map[string]bool{"iPhone": true, "Pixel": true}}
	in := cuttingAgainst(t, tokens, "iPhone", "Pixel")
	t.Setenv(envAskPhone, "iPhone")

	var code int
	stdout, _ := capture(t, func() { code = run(in, []string{"revoke"}) })

	if code != 0 {
		t.Fatalf("exit %d — the button was pressed with a name in its box", code)
	}
	if tokens.asked != "iPhone" {
		t.Errorf("the store was asked to cut %q", tokens.asked)
	}
	if paired := pairedPhones(t); len(paired) != 1 || paired[0].Label != "Pixel" {
		t.Errorf("the other phone did not stay: %+v", paired)
	}
	// The form draws what happened; there is no log in front of whoever pressed the button.
	var answer struct {
		Show []shownPart `json:"show"`
	}
	if err := json.Unmarshal([]byte(stdout), &answer); err != nil {
		t.Fatalf("stdout does not parse: %q", stdout)
	}
	if !strings.Contains(drawnText(answer.Show), "iPhone") {
		t.Errorf("the settings screen was handed %q", stdout)
	}
}

// A name typed after the command wins over the box: someone at a terminal said which one out
// loud, and an answer left in the environment from a form is not that.
func TestANameTypedWinsOverTheBox(t *testing.T) {
	tokens := &pretendTokens{holds: map[string]bool{"iPhone": true, "Pixel": true}}
	in := cuttingAgainst(t, tokens, "iPhone", "Pixel")
	t.Setenv(envAskPhone, "iPhone")

	capture(t, func() { run(in, []string{"revoke", "Pixel"}) })

	if tokens.asked != "Pixel" {
		t.Errorf("the store was asked to cut %q", tokens.asked)
	}
}

// Pressing the button with nothing in the box is the ordinary mistake, and what to do about it is
// the other button — the one that shows the names there are to type.
func TestUnpairingWithNoNameSaysWhereTheNamesAre(t *testing.T) {
	in := cuttingAgainst(t, &pretendTokens{holds: map[string]bool{}}, "iPhone")

	var code int
	_, stderr := capture(t, func() { code = run(in, []string{"revoke"}) })

	if code != 1 {
		t.Fatalf("exit %d — nothing was named", code)
	}
	if !strings.Contains(stderr, wordings["en"][phTheSeePhonesButton]) {
		t.Errorf("the refusal does not say where the names are: %q", stderr)
	}
}

// **An answer too heavy for the form is dropped whole by Amenbo**, not trimmed — so a list long
// enough to reach that weight is cut here, where there is still something to say about what was
// cut. The log keeps every one of them.
func TestALongListIsCutToWhatTheFormWillTakeAndSaysSo(t *testing.T) {
	long := strings.Repeat("a-phone-with-a-very-long-name", 8)
	paired := make([]phone, 0, 40)
	for at := range 40 {
		paired = append(paired, phone{Label: fmt.Sprintf("%s-%d", long, at), IssuedAt: "2026-08-09T09:00:00.000Z"})
	}

	shown := whatIsPaired(paired)

	lines := 0
	for _, part := range shown {
		lines += len(part.List)
	}
	if lines == 0 || lines >= len(paired) {
		t.Fatalf("%d of %d phones were drawn, want the list cut to fit", lines, len(paired))
	}
	if weighs(linesOf(shown)) > showBytes {
		t.Errorf("what is drawn weighs %d, and Amenbo drops an answer over %d whole", weighs(linesOf(shown)), showBytes)
	}
	if !strings.Contains(drawnText(shown), fmt.Sprint(len(paired)-lines)) {
		t.Errorf("nothing says how many were left out: %q", drawnText(shown))
	}
}

func linesOf(shown []shownPart) []string {
	var lines []string
	for _, part := range shown {
		lines = append(lines, part.List...)
	}
	return lines
}

// Revoking names exactly one phone. Nothing after `phones` means anything either, and taking a
// word nobody meant would answer a question that was not asked.
func TestTheTwoCommandsTakeWhatTheyTake(t *testing.T) {
	in := cuttingAgainst(t, &pretendTokens{holds: map[string]bool{}}, "iPhone")

	for what, args := range map[string][]string{
		"revoke with no name": {"revoke"},
		"revoke with two":     {"revoke", "iPhone", "Pixel"},
		"phones with a word":  {"phones", "iPhone"},
		"revoke with a blank": {"revoke", "  "},
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
