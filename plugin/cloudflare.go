package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"net/url"
	"os"
	"strings"
	"time"
)

// Standing the Cloudflare route up is five things in the user's own account, and every one of
// them goes through the same REST API: find which account this is, make the database, put the
// schema in it, upload the Worker with the database bound to it and the write token sealed into
// it, and turn on the name it answers under.
//
// **The API token the user pastes is never kept.** It stands the route up and goes when the
// command ends. What is written back into the settings — the endpoint, the write token, the
// encryption key — cannot create anything in their account, which is the point: the credential
// that could is held for one run and by one process.

// cloudflareAPI is the road.
const cloudflareAPI = "https://api.cloudflare.com/client/v4"

// envStandIn is how something else is put in front of that road. Nobody has a Cloudflare account
// to try this against in a test, and a command whose only rehearsal was being read is one that
// runs for the first time in somebody's account — so `setup` can be pointed at a server that
// answers the way the API is documented to, with the Worker it deploys answering there too.
//
// It is one variable for both because they are one pretence. It is read from the environment
// rather than taken as a flag so that nothing about it is on the face a user types.
const envStandIn = "AMENBO_VIEWER_STAND_IN"

// standingIn is where that pretence lives, or empty when this is the real thing.
func standingIn() string {
	return strings.TrimRight(strings.TrimSpace(os.Getenv(envStandIn)), "/")
}

// setupTimeout bounds one API call. Standing the route up is a handful of calls in a row with a
// person waiting on them, so a call that is not going to answer has to give the run back rather
// than hold the terminal.
const setupTimeout = 60 * time.Second

// sky is the Cloudflare API, holding the token for one run of setup.
type sky struct {
	token  string
	base   string
	client *http.Client
}

func reachCloudflare(token string) sky {
	base := cloudflareAPI
	if where := standingIn(); where != "" {
		base = where + "/client/v4"
	}
	return sky{token: token, base: base, client: &http.Client{Timeout: setupTimeout}}
}

// refusedByCloudflare is the API turning a call down. Cloudflare answers every call in one
// envelope, refusals included, so what a caller reads is the code and the sentence it put there
// rather than an HTTP status with nothing behind it.
type refusedByCloudflare struct {
	call    string
	code    int
	message string
}

func (r refusedByCloudflare) Error() string {
	return fmt.Sprintf("Cloudflare refused %s: %s (%d)", r.call, r.message, r.code)
}

// ask makes one API call and hands back what the envelope carried as its result.
//
// **No error here quotes the token.** These sentences reach Amenbo's execution log, and one that
// echoed the credential would put it somewhere it outlives the run that needed it.
func (s sky) ask(method, path, contentType string, body io.Reader, result any) error {
	request, err := http.NewRequest(method, s.base+path, body)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+s.token)
	request.Header.Set("Accept", "application/json")
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}

	answer, err := s.client.Do(request)
	if err != nil {
		return fmt.Errorf("Cloudflare did not answer %s: %w", path, err)
	}
	defer answer.Body.Close()

	var said struct {
		Success bool `json:"success"`
		Errors  []struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"errors"`
		Result json.RawMessage `json:"result"`
	}
	if err := json.NewDecoder(answer.Body).Decode(&said); err != nil {
		return fmt.Errorf("Cloudflare answered %s with %d and something this build cannot read: %w", path, answer.StatusCode, err)
	}
	if !said.Success {
		if len(said.Errors) == 0 {
			return fmt.Errorf("Cloudflare refused %s with %d and gave no reason", path, answer.StatusCode)
		}
		return refusedByCloudflare{call: path, code: said.Errors[0].Code, message: said.Errors[0].Message}
	}
	if result == nil {
		return nil
	}
	if err := json.Unmarshal(said.Result, result); err != nil {
		return fmt.Errorf("Cloudflare answered %s in a shape this build cannot read: %w", path, err)
	}
	return nil
}

// askWith is ask for the calls that send JSON, which is all of them but the upload.
func (s sky) askWith(method, path string, body, result any) error {
	raw, err := json.Marshal(body)
	if err != nil {
		return err
	}
	return s.ask(method, path, "application/json", bytes.NewReader(raw), result)
}

// theAccount works out which account to build in.
//
// One account is the ordinary answer and needs nothing from the user. Several is the case worth
// refusing over rather than guessing at: building in the wrong one leaves a Worker and a database
// somewhere they were not meant to be, and the user would have no reason to look there.
func (s sky) theAccount(chosen string) (string, error) {
	var accounts []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if err := s.ask(http.MethodGet, "/accounts", "", nil, &accounts); err != nil {
		return "", err
	}
	if len(accounts) == 0 {
		return "", errors.New("this token reaches no Cloudflare account — it may be missing the Account Settings (read) permission")
	}
	if chosen != "" {
		for _, account := range accounts {
			if account.ID == chosen {
				return account.ID, nil
			}
		}
		return "", fmt.Errorf("this token does not reach the account %s", chosen)
	}
	if len(accounts) == 1 {
		return accounts[0].ID, nil
	}
	named := make([]string, len(accounts))
	for i, account := range accounts {
		named[i] = fmt.Sprintf("  %s  %s", account.ID, account.Name)
	}
	return "", fmt.Errorf("this token reaches %d accounts, so say which one to build in with --account:\n%s",
		len(accounts), strings.Join(named, "\n"))
}

// theDatabase finds the database by name, or makes it, and says which of the two happened — the
// schema is only laid down in one that was not there a moment ago.
func (s sky) theDatabase(account, name string) (id string, fresh bool, err error) {
	var found []struct {
		UUID string `json:"uuid"`
		Name string `json:"name"`
	}
	path := fmt.Sprintf("/accounts/%s/d1/database?name=%s", account, url.QueryEscape(name))
	if err := s.ask(http.MethodGet, path, "", nil, &found); err != nil {
		return "", false, err
	}
	for _, database := range found {
		if database.Name == name {
			return database.UUID, false, nil
		}
	}

	var made struct {
		UUID string `json:"uuid"`
	}
	if err := s.askWith(http.MethodPost, "/accounts/"+account+"/d1/database", map[string]any{"name": name}, &made); err != nil {
		return "", false, err
	}
	if made.UUID == "" {
		return "", false, errors.New("Cloudflare made a database and did not say which one")
	}
	return made.UUID, true, nil
}

// queried is one statement's outcome, as D1 answers a query: several of them, one per statement.
type queried struct {
	Success bool             `json:"success"`
	Results []map[string]any `json:"results"`
}

// query runs SQL against the database. The whole schema goes through in one call — D1 takes the
// statements together, which is what keeps a half-applied schema from being a state anyone has
// to reason about.
func (s sky) query(account, database, sql string) ([]queried, error) {
	var outcomes []queried
	path := fmt.Sprintf("/accounts/%s/d1/database/%s/query", account, database)
	if err := s.askWith(http.MethodPost, path, map[string]any{"sql": sql}, &outcomes); err != nil {
		return nil, err
	}
	for _, outcome := range outcomes {
		if !outcome.Success {
			return nil, errors.New("the database refused a statement of the schema")
		}
	}
	return outcomes, nil
}

// scriptEntry is the module the uploaded Worker starts at. It is a name inside the upload and
// nothing else — the file it came from is the plugin's own copy of the built script.
const scriptEntry = "index.js"

// deploy uploads the Worker, with the database bound to it and the write token set on it in the
// same breath.
//
// **The secret travels as a binding rather than as a second call.** An upload replaces the
// bindings it does not carry, so a token set separately afterwards is one an ordinary redeploy
// would quietly drop — and a Worker with no write token takes no writes.
func (s sky) deploy(account, script string, source []byte, database, writeToken string) error {
	metadata, err := json.Marshal(map[string]any{
		"main_module":        scriptEntry,
		"compatibility_date": compatibilityDate,
		"bindings": []any{
			map[string]any{"type": "d1", "name": databaseBinding, "id": database},
			map[string]any{"type": "secret_text", "name": writeTokenBinding, "text": writeToken},
		},
		"observability": map[string]any{"enabled": true},
	})
	if err != nil {
		return err
	}

	var body bytes.Buffer
	form := multipart.NewWriter(&body)
	if err := writePart(form, "metadata", "metadata.json", "application/json", metadata); err != nil {
		return err
	}
	if err := writePart(form, scriptEntry, scriptEntry, "application/javascript+module", source); err != nil {
		return err
	}
	if err := form.Close(); err != nil {
		return err
	}

	path := fmt.Sprintf("/accounts/%s/workers/scripts/%s", account, script)
	return s.ask(http.MethodPut, path, form.FormDataContentType(), &body, nil)
}

// writePart puts one part into the upload with its own content type. The parts are named and
// typed rather than just written, because the API reads the metadata part as JSON and the module
// part as a module, and tells them apart by exactly this.
func writePart(form *multipart.Writer, name, filename, contentType string, content []byte) error {
	header := make(textproto.MIMEHeader)
	header.Set("Content-Disposition", fmt.Sprintf("form-data; name=%q; filename=%q", name, filename))
	header.Set("Content-Type", contentType)
	part, err := form.CreatePart(header)
	if err != nil {
		return err
	}
	_, err = part.Write(content)
	return err
}

// errNoSubdomain is the account not having a workers.dev name yet. It is a sentinel because it is
// the one refusal in the whole of setup that the user themselves has to answer — the name is
// theirs to choose and is taken account-wide, so nothing here may pick one for them.
var errNoSubdomain = errors.New("this account has no workers.dev subdomain yet")

// codeNoSubdomain is what Cloudflare puts in the envelope when that is what happened. The same
// call is also turned down for a token that is missing the permission, for a rate limit, and for
// the API's own bad days — none of which a user can do anything about by choosing a name — so
// this code, and nothing else, is what becomes errNoSubdomain.
const codeNoSubdomain = 10007

// theSubdomain reads the account's workers.dev name, which is the middle of every URL a Worker
// in it answers on.
func (s sky) theSubdomain(account string) (string, error) {
	var said struct {
		Subdomain string `json:"subdomain"`
	}
	if err := s.ask(http.MethodGet, "/accounts/"+account+"/workers/subdomain", "", nil, &said); err != nil {
		var refused refusedByCloudflare
		if errors.As(err, &refused) && refused.code == codeNoSubdomain {
			return "", errNoSubdomain
		}
		return "", err
	}
	if said.Subdomain == "" {
		return "", errNoSubdomain
	}
	return said.Subdomain, nil
}

// answerOnTheSubdomain gives the Worker its workers.dev URL. An uploaded Worker sits there
// answering nothing until this is done, so it is part of standing the route up rather than
// something the user is left to find in the dashboard.
func (s sky) answerOnTheSubdomain(account, script string) error {
	path := fmt.Sprintf("/accounts/%s/workers/scripts/%s/subdomain", account, script)
	return s.askWith(http.MethodPost, path, map[string]any{"enabled": true, "previews_enabled": false}, nil)
}
