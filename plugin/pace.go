package main

import (
	"net/http"
	"strconv"
	"strings"
	"time"
)

// How fast the send may go, and when it may not go at all.
//
// **Both answers come from the far end, and both are remembered.** The store says "come back in
// N seconds" when it cannot answer, and says how many rows each write actually cost; a hook that
// forgot either between runs would learn the same lesson on every write, since Amenbo starts this
// plugin once per write and the process ends with it.
//
// **Neither one stops the copying.** What is read out of the ledger has to keep up with the
// backlog whatever the network is doing — the window turns, and what is not copied out in time is
// not copied out at all. Waiting and being out of budget are the sending's business, and the
// sending is free to fall behind (see `send.go`).

// rowsADay is what a Cloudflare account on the free plan may write to D1 in a day. It is the
// number this is measured against, and the one the pause is worked out from.
const rowsADay = 100_000

// rowsWeMaySpendADay is where this stops. **The room left over is not slack — it is everything
// else in the account**: a second store, the same store's own reads-with-writes, whatever the
// user runs beside this. A plugin that spent the whole allowance would be the reason the rest of
// their account stopped working, which is not a trade it is entitled to make on their behalf.
//
// **A paid account is bounded by the same number here**, and this cannot see which plan it is.
// What that costs is a pause, not a loss: the queue keeps what it could not send, and midnight
// UTC lifts it. What it buys is that the free plan — where the wall is real — never reaches it.
const rowsWeMaySpendADay = rowsADay * 9 / 10

// longestQuiet caps how long one refusal may hold a route. The wait is the store's to name and it
// is honoured, but a number nothing here produced must not be able to wedge the sending for a
// week — and an hour is already far past any refusal that clears itself.
const longestQuiet = time.Hour

// rightNow is the clock, indirected so a test can stand somewhere other than today.
var rightNow = time.Now

// theDay names the day a spend is counted against. **It is UTC because the limit is**: D1's
// allowance turns over at midnight UTC, so counting against a local day would reset this in the
// middle of the store's, or hold it past the store's own turnover.
func theDay(now time.Time) string {
	return now.UTC().Format(time.DateOnly)
}

// spentToday is how many rows this route has cost today. A count carrying another day's date is
// not this day's, and reads as nothing spent — which is the whole of the rollover.
func spentToday(left carried, now time.Time) int64 {
	if left.SpentOn != theDay(now) {
		return 0
	}
	return left.Spent
}

// spend adds what one write cost to today's count.
func spend(left carried, rows int64, now time.Time) carried {
	left.Spent, left.SpentOn = spentToday(left, now)+rows, theDay(now)
	return left
}

// outOfBudget says today's allowance is gone.
//
// **It is asked before a write and never during one.** What a write will cost is not knowable
// from this side — an upsert onto a key already there costs a different number from one onto a
// key that is not — so the count can only be read after the fact, and this can overshoot by at
// most one request's worth. Guessing the cost instead would put a model of the database in here,
// to go stale the day the database changes.
func outOfBudget(left carried, now time.Time) bool {
	return spentToday(left, now) >= rowsWeMaySpendADay
}

// quiet says this route asked to be left alone and the moment it named has not come, with how
// much of it is left.
//
// A mark this build cannot read is no mark: the sending goes ahead, and the store says so again
// if it meant it.
func quiet(left carried, now time.Time) (time.Duration, bool) {
	if left.QuietUntil == "" {
		return 0, false
	}
	until, err := time.Parse(time.RFC3339, left.QuietUntil)
	if err != nil || !now.Before(until) {
		return 0, false
	}
	return until.Sub(now), true
}

// beQuietFor writes down that this route is not to be sent to for a while.
func beQuietFor(left carried, wait time.Duration, now time.Time) carried {
	if wait <= 0 {
		return left
	}
	if wait > longestQuiet {
		wait = longestQuiet
	}
	left.QuietUntil = now.Add(wait).UTC().Format(time.RFC3339)
	return left
}

// theWaitAsked reads a `Retry-After` into how long it asks for.
//
// **HTTP writes it two ways and both arrive here.** A number is seconds from now; a date is the
// moment to come back at — and a build that read only the first put the date itself into a
// sentence, which is how a refusal came out saying it had been asked to wait for
// `Wed, 30 Aug 2026 06:00:00 GMT seconds`.
//
// A date already past is a wait of nothing, which is still a wait that was asked for: the caller
// learns that the answer named one, and waits for no time at all.
func theWaitAsked(header string, now time.Time) (time.Duration, bool) {
	header = strings.TrimSpace(header)
	if header == "" {
		return 0, false
	}
	if seconds, err := strconv.Atoi(header); err == nil {
		if seconds <= 0 {
			return 0, true
		}
		return time.Duration(seconds) * time.Second, true
	}
	if when, err := http.ParseTime(header); err == nil {
		if wait := when.Sub(now); wait > 0 {
			return wait, true
		}
		return 0, true
	}
	return 0, false
}

// theWaitInWords is a wait as a log line says it, rounded to the second — nobody reading one acts
// on the milliseconds, and a raw duration puts nine digits in the middle of a sentence.
func theWaitInWords(wait time.Duration) string {
	return wait.Round(time.Second).String()
}
