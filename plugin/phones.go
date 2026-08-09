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

// rememberThePhone adds the label to the local record, or moves its date if that name was paired
// before — re-pairing one phone replaces its token at the store, so a second row here would name
// a token that no longer exists.
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
func listPhones(_ input, args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("phones takes nothing after it, and %q was given", args[0])
	}
	known, err := readPhones()
	if err != nil {
		return err
	}
	if len(known.Paired) == 0 {
		logf("%s: no phone is paired. `%s qr` pairs one.", pluginName, pluginName)
	}
	for _, paired := range known.Paired {
		logf("  %-20s %s", paired.Label, paired.IssuedAt)
	}
	return json.NewEncoder(out).Encode(known.Paired)
}

// revoke cuts one phone off, by the name it was paired under.
//
// **The store is told first.** Dropping the row here and failing at the store would leave a phone
// still reading under a name nobody can see any more — the one state from which there is no way
// back but re-keying everything.
func revoke(in input, args []string) error {
	if len(args) != 1 || strings.TrimSpace(args[0]) == "" {
		return errors.New("revoke takes the name of one phone — `phones` lists them")
	}
	label := strings.TrimSpace(args[0])

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
		return fmt.Errorf("no phone is called %q — `%s phones` lists the ones that are", label, pluginName)
	}
	if !cut {
		// The store never had it, so nothing was reading under that name. What is left is a row
		// here that says otherwise, and tidying it is the honest end.
		logf("%s: the store had no %q, so nothing was reading with it — the record here is tidied.", pluginName, label)
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
		logf("%s: %q reads nothing from now on.", pluginName, label)
	}
	return json.NewEncoder(out).Encode(map[string]any{"label": label, "cut": cut})
}

// cutOff asks the store to forget one read token. It says whether there was one to forget: the
// store answers a name it does not hold as not found rather than shrugging, so a typo cannot come
// back as "done".
func (s store) cutOff(label string) (bool, error) {
	request, err := http.NewRequest(http.MethodDelete, s.url+"/tokens/"+url.PathEscape(label), nil)
	if err != nil {
		return false, err
	}
	request.Header.Set("Authorization", "Bearer "+s.token)

	answer, err := (&http.Client{Timeout: sendTimeout}).Do(request)
	if err != nil {
		return false, fmt.Errorf("/tokens did not answer: %w", err)
	}
	defer answer.Body.Close()

	var said struct {
		Error string `json:"error"`
	}
	decoded := json.NewDecoder(answer.Body).Decode(&said)
	switch {
	case answer.StatusCode == http.StatusNotFound:
		return false, nil
	case answer.StatusCode < 200 || answer.StatusCode > 299:
		if decoded == nil && said.Error != "" {
			return false, fmt.Errorf("/tokens answered %d: %s", answer.StatusCode, said.Error)
		}
		return false, fmt.Errorf("/tokens answered %d", answer.StatusCode)
	}
	return true, nil
}
