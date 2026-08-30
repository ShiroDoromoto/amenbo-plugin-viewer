package main

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// at is a moment to stand at, so what turns on the clock can be exercised without waiting for it.
func at(said string) time.Time {
	when, err := time.Parse(time.RFC3339, said)
	if err != nil {
		panic(err)
	}
	return when
}

// standingAt points the clock at one moment for the length of a test.
func standingAt(t *testing.T, when time.Time) {
	t.Helper()
	was := rightNow
	rightNow = func() time.Time { return when }
	t.Cleanup(func() { rightNow = was })
}

// **`Retry-After` is written two ways and both have to be read.** A build that read only the
// seconds put the date itself into a sentence about seconds.
func TestAWaitIsReadWhicheverWayItIsWritten(t *testing.T) {
	now := at("2026-08-30T06:00:00Z")

	for _, said := range []struct {
		header string
		want   time.Duration
	}{
		{header: "60", want: time.Minute},
		{header: " 90 ", want: 90 * time.Second},
		{header: "Sun, 30 Aug 2026 06:05:00 GMT", want: 5 * time.Minute},
		// A moment already past asks for no wait at all, and is still an answer that named one.
		{header: "Sun, 30 Aug 2026 05:00:00 GMT", want: 0},
		{header: "0", want: 0},
	} {
		wait, asked := theWaitAsked(said.header, now)
		if !asked {
			t.Errorf("%q was not read as a wait", said.header)
			continue
		}
		if wait != said.want {
			t.Errorf("%q asks for %s, want %s", said.header, wait, said.want)
		}
	}

	for _, header := range []string{"", "   ", "soon"} {
		if _, asked := theWaitAsked(header, now); asked {
			t.Errorf("%q was read as a wait", header)
		}
	}
}

// A number nothing here produced must not be able to hold the sending for a week.
func TestAWaitLongerThanThisPluginWillHonourIsCappedRatherThanRefused(t *testing.T) {
	now := at("2026-08-30T06:00:00Z")

	left := beQuietFor(carried{}, 30*24*time.Hour, now)

	wait, quietly := quiet(left, now)
	if !quietly {
		t.Fatal("a wait that was asked for is not being kept")
	}
	if wait != longestQuiet {
		t.Errorf("the route is quiet for %s, and this build honours at most %s", wait, longestQuiet)
	}
}

// A store that would not take anything is asked again once the moment it named has come, and not
// before. The whole point of writing it down is that the process ends with the hook.
func TestARouteAsksAgainOnlyAfterTheMomentItWasGiven(t *testing.T) {
	asked := at("2026-08-30T06:00:00Z")
	left := beQuietFor(carried{}, time.Minute, asked)

	if _, quietly := quiet(left, asked.Add(30*time.Second)); !quietly {
		t.Error("the wait was over before the moment it named")
	}
	if _, quietly := quiet(left, asked.Add(2*time.Minute)); quietly {
		t.Error("the wait is still standing after the moment it named")
	}
	// A mark this build cannot read is no mark: the sending goes ahead and the store says so
	// again if it meant it.
	if _, quietly := quiet(carried{QuietUntil: "not a moment"}, asked); quietly {
		t.Error("something unreadable was honoured as a wait")
	}
}

// The day's count is the day's, and nothing has to run at midnight for that to be true.
func TestTheDaysCountIsTheDaysAndRollsOverOnItsOwn(t *testing.T) {
	morning := at("2026-08-30T06:00:00Z")
	left := spend(carried{}, 40_000, morning)

	if got := spentToday(left, morning.Add(6*time.Hour)); got != 40_000 {
		t.Errorf("spent %d later the same day, want 40000", got)
	}
	if got := spentToday(left, morning.Add(24*time.Hour)); got != 0 {
		t.Errorf("spent %d the next day, want nothing carried over", got)
	}
	// The day is UTC because the allowance is: counting against a local one would reset this in
	// the middle of the store's day.
	if theDay(at("2026-08-30T23:30:00Z")) == theDay(at("2026-08-31T00:30:00Z")) {
		t.Error("midnight UTC is not where the day turns over")
	}
}

// **The queue keeps what the budget would not let through.** Being out of budget is a pause and
// never a loss, and it must not be reported as a refusal — a red line on every write for the rest
// of the day is how a pause reads as a fault.
func TestASpentDayHoldsTheQueueRatherThanLosingIt(t *testing.T) {
	now := at("2026-08-30T06:00:00Z")
	where := &stub{called: "a place that takes anything"}
	full := carried{Spent: rowsWeMaySpendADay, SpentOn: theDay(now), Pending: keysToDrop(3)}

	left, landed, err := drainTo(where, full, 1, now)

	if err != nil {
		t.Fatalf("a spent budget was reported as a failure: %v", err)
	}
	if landed != 0 {
		t.Errorf("%d record(s) went out on a day whose rows are spent", landed)
	}
	if len(left.Pending) != 3 {
		t.Errorf("%d record(s) are left, and none of them should have gone anywhere", len(left.Pending))
	}
	if where.placed != 0 {
		t.Errorf("the store was written to %d time(s)", where.placed)
	}

	// The next day it goes, and nothing had to happen at midnight for that.
	left, landed, err = drainTo(where, left, 1, now.Add(24*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if landed != 3 || len(left.Pending) != 0 {
		t.Errorf("the next day carried %d record(s) and left %d", landed, len(left.Pending))
	}
}

// What a write cost is the store's answer, and it is what the day is counted in.
func TestWhatTheStoreSaysItWroteIsWhatIsCountedAgainstTheDay(t *testing.T) {
	now := at("2026-08-30T06:00:00Z")
	where := &stub{called: "a place that takes anything"}

	left, _, err := drainTo(where, carried{Pending: keysToDrop(4)}, 1, now)

	if err != nil {
		t.Fatal(err)
	}
	// The stub answers three rows a record, which is the store's number rather than a count of
	// records — the two differ, and it is the store's that the limit is written in.
	if got := spentToday(left, now); got != 12 {
		t.Errorf("counted %d rows against today, and the store said it wrote 12", got)
	}
}

// A refusal that names a moment is honoured, and honoured across runs — the process ends with the
// hook, so a wait held anywhere but the memory lasts no time at all.
func TestARefusalThatAsksForTimeIsWrittenDown(t *testing.T) {
	now := at("2026-08-30T06:00:00Z")
	answering := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "60")
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte(`{"error":"this store could not answer: something threw"}`))
	}))
	defer answering.Close()
	where := store{url: answering.URL, token: "a-throwaway-token", seal: sealerForTest(t)}

	left, landed, err := drainTo(where, carried{Pending: keysToDrop(1)}, 1, now)

	if err == nil {
		t.Fatal("a refusal came back as a send")
	}
	if landed != 0 || len(left.Pending) != 1 {
		t.Errorf("landed %d and left %d queued", landed, len(left.Pending))
	}
	wait, quietly := quiet(left, now)
	if !quietly || wait != time.Minute {
		t.Errorf("the route is quiet for %s (%v), and the store asked for a minute", wait, quietly)
	}

	// And while it stands, nothing is sent and nothing is called a failure.
	quiet := &stub{called: "a place that takes anything"}
	if _, landed, err := drainTo(quiet, left, 1, now.Add(30*time.Second)); err != nil || landed != 0 {
		t.Errorf("landed %d during the wait (%v)", landed, err)
	}
	if quiet.placed != 0 {
		t.Errorf("the store was written to %d time(s) during the wait", quiet.placed)
	}
}

// A place that took something is not asking to be left alone any more.
func TestASendThatLandsClearsTheWait(t *testing.T) {
	now := at("2026-08-30T06:00:00Z")
	where := &stub{called: "a place that takes anything"}
	waiting := beQuietFor(carried{Pending: keysToDrop(1)}, time.Minute, now)

	left, _, err := drainTo(where, waiting, 1, now.Add(2*time.Minute))

	if err != nil {
		t.Fatal(err)
	}
	if left.QuietUntil != "" {
		t.Errorf("the wait outlived the send that landed: %q", left.QuietUntil)
	}
}

// **A full database wears a wait, and it is not one.** Every exception comes back as a 503 with a
// `Retry-After` on it now, so a reader that led with the wait would tell someone whose 500 MB is
// gone to come back in a minute — forever.
func TestAFullStoreIsNotReadAsSomethingThatClearsItself(t *testing.T) {
	standingAt(t, at("2026-08-30T06:00:00Z"))
	turnedDown := storeRefused{
		path:    "/records",
		status:  http.StatusServiceUnavailable,
		said:    "this store could not answer: D1_ERROR: Exceeded maximum DB size",
		waitFor: "60",
	}

	got := turnedDown.Error()

	if !strings.Contains(got, "full") || !strings.Contains(got, "raised to a larger plan") {
		t.Errorf("a full store was not named as one: %q", got)
	}
	if strings.Contains(got, "clears itself") {
		t.Errorf("a full store was called something that clears itself: %q", got)
	}
}

// Everything else that throws does clear itself, and the number is read rather than repeated.
func TestAnExceptionThatIsNotAFullStoreIsStillAWait(t *testing.T) {
	standingAt(t, at("2026-08-30T06:00:00Z"))
	turnedDown := storeRefused{
		path:    "/records",
		status:  http.StatusServiceUnavailable,
		said:    "this store could not answer: Network connection lost",
		waitFor: "Sun, 30 Aug 2026 06:05:00 GMT",
	}

	got := turnedDown.Error()

	if !strings.Contains(got, "clears itself") {
		t.Errorf("a passing fault was not read as one: %q", got)
	}
	// The header is a date, and what the sentence says is how long that is.
	if !strings.Contains(got, "5m0s") {
		t.Errorf("the wait was repeated rather than read: %q", got)
	}
}

// A store older than `rows_written` answers nothing for it, and a budget that never fills is
// exactly the behaviour before there was one.
func TestAStoreThatSaysNothingAboutRowsFillsNoBudget(t *testing.T) {
	now := at("2026-08-30T06:00:00Z")
	answering := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte(`{"seq":1}`))
	}))
	defer answering.Close()
	where := store{url: answering.URL, token: "a-throwaway-token", seal: sealerForTest(t)}

	left, landed, err := drainTo(where, carried{Pending: keysToDrop(1)}, 1, now)

	if err != nil || landed != 1 {
		t.Fatalf("landed %d (%v)", landed, err)
	}
	if got := spentToday(left, now); got != 0 {
		t.Errorf("counted %d rows against a store that reported none", got)
	}
}

// The refusal a store hands back is passed on whole, and errors.As still reaches it after the
// wait has been read out of it.
func TestTheRefusalIsStillTheStoresOwn(t *testing.T) {
	standingAt(t, at("2026-08-30T06:00:00Z"))
	answering := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "60")
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte(`{"error":"this store could not answer: D1_ERROR: Exceeded maximum DB size"}`))
	}))
	defer answering.Close()
	where := store{url: answering.URL, token: "a-throwaway-token", seal: sealerForTest(t)}

	_, err := where.place(placement{SpecV: specVersion, Version: 1})

	var turnedDown storeRefused
	if !errors.As(err, &turnedDown) {
		t.Fatalf("the store's own refusal did not come back: %v", err)
	}
	if turnedDown.status != http.StatusServiceUnavailable || turnedDown.waitFor != "60" {
		t.Errorf("refusal = %+v", turnedDown)
	}
}
