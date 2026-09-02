package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
)

// Whether a phone may read is one bit, and the store is what holds it.
//
// **It used to be a list kept here.** The store was keyed by a name per phone and answered no
// question about what it held, so the PC wrote down what it had issued and drew that back. What it
// drew was what the PC believed: a store stood up again underneath the file left every row in it
// naming a phone that reads nothing, and there was no way from here to find out.
//
// The store holds one code now and answers whether it is there, so the two buttons ask it. Nothing
// about who may read is written down on this side any more.

// phonesName is the file that list was kept in. Nothing writes it, and a machine that still has
// one is carrying a record nobody reads — so it is taken away the next time either button runs.
const phonesName = "paired-phones.json"

// forgetTheOldList removes it, and says nothing when there is none. **A failure here is not a
// failed run**: the file is a leftover either way, and refusing to pair a phone over one that
// could not be deleted would be the tidying getting in the way of the work.
func forgetTheOldList() {
	dir, err := pluginDir()
	if err != nil {
		return
	}
	_ = os.Remove(filepath.Join(dir, phonesName))
}

// listPhones says whether a phone can read at all, and since when.
//
// **It asks the store rather than answering from here.** The one thing worth knowing is whether
// the code that was issued is still the code the store holds, and that is a question only the
// store can answer.
func listPhones(in input, args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("phones takes nothing after it, and %q was given", args[0])
	}
	where, err := storeFor(in)
	if errors.Is(err, errNoCloudflareRoute) {
		return refuse(phNoCloudflareRouteYet, phTheSetupButton)
	}
	if err != nil {
		return err
	}

	paired, issuedAt, err := where.whoMayRead()
	if err != nil {
		return err
	}
	forgetTheOldList()

	said := whatIsPaired(paired, issuedAt)
	logf("%s: %s", pluginName, said)
	return json.NewEncoder(out).Encode(struct {
		answered
		Paired   bool   `json:"paired"`
		IssuedAt string `json:"issued_at,omitempty"`
	}{
		answered: answered{V: specVersion, OK: true, Show: []shownPart{{Text: said}}},
		Paired:   paired,
		IssuedAt: issuedAt,
	})
}

// whatIsPaired is the line the settings screen draws under the button: a phone can read, since
// when — or none can, and which button issues a code.
func whatIsPaired(paired bool, issuedAt string) string {
	if !paired {
		return say(phNoPhoneIsPairedYet, phThePairButton)
	}
	return say(phPairedOn, issuedAt)
}

// whoMayRead asks the store whether it is holding a read code, and when that code was issued.
//
// **The hash does not come back**, and there is nothing else to come back: the store answers
// present or absent, which is the whole of what it knows about who is reading.
func (s store) whoMayRead() (bool, string, error) {
	request, err := http.NewRequest(http.MethodGet, s.url+"/tokens", nil)
	if err != nil {
		return false, "", err
	}

	answered, err := s.askTheStore(request)
	if err != nil {
		return false, "", err
	}
	var said struct {
		Paired   bool   `json:"paired"`
		IssuedAt string `json:"issued_at"`
	}
	if err := json.Unmarshal(answered, &said); err != nil {
		return false, "", fmt.Errorf("/tokens answered with something this build cannot read: %w", err)
	}
	return said.Paired, said.IssuedAt, nil
}

// revoke undoes the pairing: the code goes, and whatever was holding it stops reading.
//
// **It takes nothing.** There is one code, so there is nothing to name — and nothing to mistype
// either, which is what the box that used to ask for a name was there to survive.
func revoke(in input, args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("revoke takes nothing after it, and %q was given", args[0])
	}
	where, err := storeFor(in)
	if errors.Is(err, errNoCloudflareRoute) {
		return refuse(phNoCloudflareRouteYet, phTheSetupButton)
	}
	if err != nil {
		return err
	}

	cut, err := where.cutOff()
	if err != nil {
		return err
	}
	forgetTheOldList()

	said := whatTheCutLeft(cut)
	logf("%s: %s", pluginName, said)
	return json.NewEncoder(out).Encode(struct {
		answered
		Cut bool `json:"cut"`
	}{
		answered: answered{V: specVersion, OK: true, Show: []shownPart{{Text: said}}},
		Cut:      cut,
	})
}

// whatTheCutLeft is the line drawn under the button: a phone that was reading and is not, or a
// store that had no code to take away.
//
// **Having none is not a refusal.** Pressing this on a store nobody is paired with asks for the
// state it is already in, so it is answered rather than turned down.
func whatTheCutLeft(cut bool) string {
	if cut {
		return say(phPhoneReadsNothingFromNowOn)
	}
	return say(phNothingWasReadingAsThat)
}

// cutOff asks the store to forget the read code, and says whether there was one to forget.
func (s store) cutOff() (bool, error) {
	request, err := http.NewRequest(http.MethodDelete, s.url+"/tokens", nil)
	if err != nil {
		return false, err
	}

	answered, err := s.askTheStore(request)
	if err != nil {
		return false, err
	}
	var said struct {
		Cut bool `json:"cut"`
	}
	if err := json.Unmarshal(answered, &said); err != nil {
		return false, fmt.Errorf("/tokens answered with something this build cannot read: %w", err)
	}
	return said.Cut, nil
}
