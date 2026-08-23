package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

// Who may read is a list of labels, and cutting one off is the whole point of there being a
// token per phone rather than one shared between them.
//
// **The list is kept here, not asked of the store.** The store compares hashes and does not
// answer questions about what it holds, which is what keeps a copy of its rows from being a set
// of credentials. What is written down is a label and the day it was issued — enough to choose
// which one to cut, and nothing anyone could read the backlog with.

// phonesName is where the labels are kept, in the plugin's own directory beside the sync state.
//
// **The tokens themselves are not here.** Revoking a phone needs only the ability to say which
// one, and the value exists on the phone that photographed it and nowhere else. Keeping it would
// put every paired phone's credential in one file, to be taken all at once.
const phonesName = "paired-phones.json"

// phones is that record: a label and the day it was issued, per phone.
type phones struct {
	V      int     `json:"v"`
	Paired []phone `json:"paired"`
}

type phone struct {
	Label    string `json:"label"`
	IssuedAt string `json:"issued_at"`
}

// rememberThePhone adds the label to the local record, or moves its date if that name is already
// written down. The store refuses a name it holds, so what gets here twice is a name this record
// kept and the store did not — a store stood up again, or a row written when the pairing itself
// failed — and a second row for it would name a phone nobody could cut off by name.
//
// **A record that cannot be written is a failed pairing**, even though the token is already
// issued: a phone that can read and cannot be named is one nobody can cut off.
func rememberThePhone(label, issuedAt string) error {
	known, err := readPhones()
	if err != nil {
		return err
	}
	for i, paired := range known.Paired {
		if paired.Label == label {
			known.Paired[i].IssuedAt = issuedAt
			return writePhones(known)
		}
	}
	known.Paired = append(known.Paired, phone{Label: label, IssuedAt: issuedAt})
	return writePhones(known)
}

func readPhones() (phones, error) {
	dir, err := pluginDir()
	if err != nil {
		return phones{}, err
	}
	raw, err := os.ReadFile(filepath.Join(dir, phonesName))
	if os.IsNotExist(err) {
		return phones{V: stateVersion, Paired: []phone{}}, nil
	}
	if err != nil {
		return phones{}, fmt.Errorf("the paired phones cannot be read: %w", err)
	}
	var known phones
	if err := json.Unmarshal(raw, &known); err != nil || known.V != stateVersion {
		return phones{}, errors.New("the record of paired phones is in a shape this build cannot read")
	}
	// Nothing paired is a list of none rather than no list: the return value is read by whatever
	// called this, and a null where an array was promised is a shape nobody asked for.
	if known.Paired == nil {
		known.Paired = []phone{}
	}
	return known, nil
}

func writePhones(known phones) error {
	known.V = stateVersion
	dir, err := pluginDir()
	if err != nil {
		return err
	}
	raw, err := json.Marshal(known)
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, phonesName), raw, 0o600); err != nil {
		return fmt.Errorf("the paired phones cannot be written: %w", err)
	}
	return nil
}

// phones lists what has been paired: the labels, and when each one was issued.
//
// It asks nothing of the network. The store has no door that answers "who may read" — it
// compares a hash and says yes or no — so what can be listed is what was written down here when
// the code was issued.
//
// **The list is drawn on the settings screen as well as written to the log.** Naming a phone is
// the PC's job, so by the time someone wants to cut one off they have long stopped remembering
// what they called it — and the button that unpairs takes that name typed. Seeing the names is
// the half that makes typing one possible.
func listPhones(_ input, args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("phones takes nothing after it, and %q was given", args[0])
	}
	known, err := readPhones()
	if err != nil {
		return err
	}
	if len(known.Paired) == 0 {
		logf("%s: %s", pluginName, say(phNoPhoneIsPairedYet, phThePairButton))
	}
	for _, paired := range known.Paired {
		logf("  %-20s %s", paired.Label, paired.IssuedAt)
	}
	// **The answer is an object now, where it was the bare list.** A run that draws on the
	// settings screen has to say what to draw, and there is nowhere on an array to say it; the
	// list it used to be is still here, under a name.
	return json.NewEncoder(out).Encode(struct {
		answered
		Paired []phone `json:"paired"`
	}{
		answered: answered{V: specVersion, OK: true, Show: whatIsPaired(known.Paired)},
		Paired:   known.Paired,
	})
}

// showBytes is what one answer's parts may weigh, and it is Amenbo's number rather than ours: an
// answer heavier than this is not trimmed at the far end, it is **dropped whole**. So a long list
// is cut here, where there is still something to say about what was cut.
const showBytes = 4096

// whatIsPaired draws the phones for the settings screen: a heading, and one line per phone.
//
// **A name and a day, in that order**, because the name is what the unpairing box takes and the
// day is what tells two phones with similar names apart.
func whatIsPaired(paired []phone) []shownPart {
	if len(paired) == 0 {
		return []shownPart{{Text: say(phNoPhoneIsPairedYet, phThePairButton)}}
	}
	lines := make([]string, 0, len(paired))
	for _, one := range paired {
		lines = append(lines, say(phPairedOn, one.Label, one.IssuedAt))
	}
	// A label is whatever somebody typed, so the weight of this is not something to reason about
	// — it is something to measure. What will not fit is dropped, and the log still holds all of
	// it (that is what the lines above are written there for).
	for len(lines) > 1 && weighs(lines) > showBytes {
		lines = lines[:len(lines)-1]
	}
	shown := []shownPart{{Heading: say(phPhonesThatMayRead)}, {List: lines}}
	if len(lines) < len(paired) {
		shown = append(shown, shownPart{Text: say(phTheRestAreInTheLog, len(paired)-len(lines))})
	}
	return shown
}

// weighs is what those lines cost as the JSON they travel as, which is the measure Amenbo holds
// the answer to.
func weighs(lines []string) int {
	raw, err := json.Marshal(lines)
	if err != nil {
		return showBytes + 1
	}
	return len(raw)
}

// The box the settings screen asks before it runs the unpairing, and the variable Amenbo hands
// the answer over in for that one run.
//
// **It is named for the phone rather than for a label**, so the two boxes on the form read apart:
// pairing asks what to call a phone, and this asks which one to cut off.
const (
	askPhone    = "phone"
	envAskPhone = "AMENBO_ASK_PHONE"
)

// revoke cuts one phone off, by the name it was paired under.
//
// **The store is told first.** Dropping the row here and failing at the store would leave a phone
// still reading under a name nobody can see any more — the one state from which there is no way
// back but re-keying everything.
//
// The name comes off the command line when there is one, and out of the settings screen's box
// when the button was pressed — the same two ways pairing takes one.
func revoke(in input, args []string) error {
	if len(args) > 1 {
		return errors.New("revoke takes the name of one phone — `phones` lists them")
	}
	label := ""
	if len(args) == 1 {
		label = strings.TrimSpace(args[0])
	}
	if label == "" {
		label = strings.TrimSpace(os.Getenv(envAskPhone))
	}
	if label == "" {
		return refuse(phWhichPhoneToUnpair, phTheSeePhonesButton)
	}

	where, err := storeFor(in)
	if err != nil {
		return err
	}
	known, err := readPhones()
	if err != nil {
		return err
	}
	held := false
	for _, paired := range known.Paired {
		if paired.Label == label {
			held = true
		}
	}

	cut, err := where.cutOff(label)
	if err != nil {
		return err
	}
	if !cut && !held {
		return refuse(phNoPhoneByThatName, label, phTheSeePhonesButton)
	}
	if !cut {
		// The store never had it, so nothing was reading under that name. What is left is a row
		// here that says otherwise, and tidying it is the honest end.
		logf("%s: %s", pluginName, say(phNothingWasReadingAsThat, label))
	}

	kept := make([]phone, 0, len(known.Paired))
	for _, paired := range known.Paired {
		if paired.Label != label {
			kept = append(kept, paired)
		}
	}
	known.Paired = kept
	if err := writePhones(known); err != nil {
		return err
	}

	if cut {
		logf("%s: %s", pluginName, say(phPhoneReadsNothingFromNowOn, label))
	}
	return json.NewEncoder(out).Encode(struct {
		answered
		Label string `json:"label"`
		Cut   bool   `json:"cut"`
	}{
		answered: answered{V: specVersion, OK: true, Show: []shownPart{{Text: whatTheCutLeft(label, cut)}}},
		Label:    label,
		Cut:      cut,
	})
}

// whatTheCutLeft is the line the settings screen draws under the button: a phone that was reading
// and is not, or a name that named nothing and has been tidied away.
func whatTheCutLeft(label string, cut bool) string {
	if cut {
		return say(phPhoneReadsNothingFromNowOn, label)
	}
	return say(phNothingWasReadingAsThat, label)
}

// cutOff asks the store to forget one read token. It says whether there was one to forget: the
// store answers a name it does not hold as not found rather than shrugging, so a typo cannot come
// back as "done".
func (s store) cutOff(label string) (bool, error) {
	request, err := http.NewRequest(http.MethodDelete, s.url+"/tokens/"+url.PathEscape(label), nil)
	if err != nil {
		return false, err
	}

	_, err = s.askTheStore(request)
	var turnedDown storeRefused
	if errors.As(err, &turnedDown) && turnedDown.status == http.StatusNotFound {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}
