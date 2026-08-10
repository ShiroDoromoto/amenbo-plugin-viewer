package main

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Nobody has a Cloudflare account to try `setup` against, and the one thing it must not do is run
// for the first time in somebody's. So what it is run against here is a stand-in: a server
// answering the way the API is documented to, holding the state a real account would, and
// remembering what landed — which is what the tests below assert on.

// pretendCloudflare is that account, as much of it as standing one drop box up touches.
type pretendCloudflare struct {
	accounts  []map[string]string
	databases map[string]string
	laidOut   bool
	subdomain string

	// The subdomain call turned down for a reason of its own — a token missing the permission, a
	// limit, a bad day. Left at zero, the only refusal it has is the account not having
	// registered a name, which is the one refusal the run may hand back to the user.
	subdomainRefusedWith struct {
		code    int
		message string
	}

	// What the run did to it.
	statements []string
	deployed   struct {
		script    string
		metadata  map[string]any
		happened  bool
		writeGate string
	}
	turnedOn bool
	offered  string
}

// answers stands the stand-in up and points setup at it. The URL it is reachable on stands in for
// both the API and the Worker that gets deployed, because to the run they are one pretence.
func answers(t *testing.T, account *pretendCloudflare) {
	t.Helper()

	road := http.NewServeMux()
	said := func(w http.ResponseWriter, result any) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"success": true, "errors": []any{}, "result": result})
	}
	refused := func(w http.ResponseWriter, code int, message string) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]any{
			"success": false,
			"errors":  []any{map[string]any{"code": code, "message": message}},
		})
	}

	road.HandleFunc("GET /client/v4/accounts", func(w http.ResponseWriter, r *http.Request) {
		account.offered = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		said(w, account.accounts)
	})
	road.HandleFunc("GET /client/v4/accounts/{account}/d1/database", func(w http.ResponseWriter, r *http.Request) {
		found := []map[string]string{}
		if uuid, there := account.databases[r.URL.Query().Get("name")]; there {
			found = append(found, map[string]string{"uuid": uuid, "name": r.URL.Query().Get("name")})
		}
		said(w, found)
	})
	road.HandleFunc("POST /client/v4/accounts/{account}/d1/database", func(w http.ResponseWriter, r *http.Request) {
		var asked struct {
			Name string `json:"name"`
		}
		json.NewDecoder(r.Body).Decode(&asked)
		account.databases[asked.Name] = "db-" + asked.Name
		said(w, map[string]string{"uuid": account.databases[asked.Name]})
	})
	road.HandleFunc("POST /client/v4/accounts/{account}/d1/database/{db}/query", func(w http.ResponseWriter, r *http.Request) {
		var asked struct {
			SQL string `json:"sql"`
		}
		json.NewDecoder(r.Body).Decode(&asked)
		account.statements = append(account.statements, asked.SQL)

		rows := []map[string]any{}
		if strings.Contains(asked.SQL, "sqlite_master") {
			if account.laidOut {
				rows = append(rows, map[string]any{"name": "records"})
			}
		} else {
			account.laidOut = true
		}
		said(w, []map[string]any{{"success": true, "results": rows}})
	})
	road.HandleFunc("PUT /client/v4/accounts/{account}/workers/scripts/{script}", func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			refused(w, 10001, "the upload is not a form")
			return
		}
		account.deployed.happened = true
		account.deployed.script = formPart(t, r, scriptEntry)
		json.Unmarshal([]byte(formPart(t, r, "metadata")), &account.deployed.metadata)
		for _, binding := range bindingsOf(account.deployed.metadata) {
			if binding["name"] == writeTokenBinding {
				account.deployed.writeGate, _ = binding["text"].(string)
			}
		}
		said(w, map[string]any{"id": r.PathValue("script")})
	})
	road.HandleFunc("GET /client/v4/accounts/{account}/workers/subdomain", func(w http.ResponseWriter, r *http.Request) {
		if account.subdomainRefusedWith.code != 0 {
			refused(w, account.subdomainRefusedWith.code, account.subdomainRefusedWith.message)
			return
		}
		if account.subdomain == "" {
			refused(w, 10007, "this account has not registered a workers.dev subdomain")
			return
		}
		said(w, map[string]string{"subdomain": account.subdomain})
	})
	road.HandleFunc("POST /client/v4/accounts/{account}/workers/scripts/{script}/subdomain", func(w http.ResponseWriter, r *http.Request) {
		account.turnedOn = true
		said(w, map[string]any{"enabled": true})
	})
	// The Worker itself, once it has been deployed: a caller with no token is turned away, which
	// is the one answer that says the script, its database and its secret all landed.
	road.HandleFunc("GET /worker/{rest...}", func(w http.ResponseWriter, r *http.Request) {
		if !account.deployed.happened {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if account.deployed.writeGate == "" {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusUnauthorized)
	})

	server := httptest.NewServer(road)
	t.Cleanup(server.Close)
	t.Setenv(envStandIn, server.URL)
}

func formPart(t *testing.T, r *http.Request, name string) string {
	t.Helper()
	file, _, err := r.FormFile(name)
	if err != nil {
		t.Fatalf("the upload has no %s part: %v", name, err)
	}
	defer file.Close()
	read, err := io.ReadAll(file)
	if err != nil {
		t.Fatal(err)
	}
	return string(read)
}

func bindingsOf(metadata map[string]any) []map[string]any {
	declared, _ := metadata["bindings"].([]any)
	bindings := make([]map[string]any, 0, len(declared))
	for _, one := range declared {
		if binding, ok := one.(map[string]any); ok {
			bindings = append(bindings, binding)
		}
	}
	return bindings
}

// oneAccount is the ordinary case: a person with one Cloudflare account and nothing in it yet.
func oneAccount() *pretendCloudflare {
	return &pretendCloudflare{
		accounts:  []map[string]string{{"id": "acc-1", "name": "Personal"}},
		databases: map[string]string{},
		subdomain: "someone",
	}
}

// kept is what the run wrote back into the settings, in the order it wrote them.
type keptSetting struct {
	key, value string
}

// watched replaces the write-back with one that only remembers, so no test can reach an amenbo
// store, and points the plugin at a stand-in account with nothing configured yet.
func watched(t *testing.T, account *pretendCloudflare) *[]keptSetting {
	t.Helper()
	answers(t, account)
	t.Setenv(envCloudflareToken, "a-throwaway-api-token")
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")

	var written []keptSetting
	was := settle
	settle = func(key, value string) error {
		written = append(written, keptSetting{key, value})
		return nil
	}
	t.Cleanup(func() { settle = was })
	return &written
}

func valueOf(written []keptSetting, key string) (string, bool) {
	for _, setting := range written {
		if setting.key == key {
			return setting.value, true
		}
	}
	return "", false
}

// The whole of setup, on an account with nothing in it: the database, its schema, the Worker with
// both bindings, the name it answers on, and the three settings that point the send at it.
func TestSetupStandsTheWholeRouteUp(t *testing.T) {
	account := oneAccount()
	written := watched(t, account)

	var code int
	stdout, _ := capture(t, func() { code = run(input{}, []string{"setup"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if account.offered != "a-throwaway-api-token" {
		t.Errorf("the API token did not reach Cloudflare: %q", account.offered)
	}
	if account.databases[setupName] == "" {
		t.Fatal("no database was made")
	}
	if len(account.statements) != 1 || !strings.Contains(account.statements[0], "CREATE TABLE records") {
		t.Errorf("the schema did not go in: %v", account.statements)
	}
	if !account.deployed.happened {
		t.Fatal("the Worker was not deployed")
	}
	if !strings.Contains(account.deployed.script, "export {") {
		t.Errorf("what was uploaded does not look like the built Worker: %.80q", account.deployed.script)
	}
	if got := account.deployed.metadata["main_module"]; got != scriptEntry {
		t.Errorf("main_module = %v", got)
	}
	if got := account.deployed.metadata["compatibility_date"]; got != compatibilityDate {
		t.Errorf("compatibility_date = %v", got)
	}
	if !account.turnedOn {
		t.Error("the Worker was never turned on, so it answers nowhere")
	}

	bound := map[string]string{}
	for _, binding := range bindingsOf(account.deployed.metadata) {
		name, _ := binding["name"].(string)
		kind, _ := binding["type"].(string)
		bound[name] = kind
	}
	if bound[databaseBinding] != "d1" {
		t.Errorf("the database is not bound to the Worker: %v", bound)
	}
	if bound[writeTokenBinding] != "secret_text" {
		t.Errorf("the write token is not set on the Worker: %v", bound)
	}

	// The endpoint is written last: half a route is not a route, so an interrupted run has to
	// leave the plugin pointing nowhere rather than at a door it has no token for.
	keys := []string{}
	for _, setting := range *written {
		keys = append(keys, setting.key)
	}
	want := []string{configEncryptionKey, configAuthToken, configWorkerURL}
	if strings.Join(keys, ",") != strings.Join(want, ",") {
		t.Errorf("settings written = %v, want %v", keys, want)
	}

	token, _ := valueOf(*written, configAuthToken)
	if token != account.deployed.writeGate {
		t.Error("the token kept here and the one set on the Worker are not the same")
	}

	var returned struct {
		URL      string `json:"url"`
		Account  string `json:"account"`
		Database string `json:"database"`
		Keys     string `json:"keys"`
	}
	if err := json.Unmarshal([]byte(stdout), &returned); err != nil {
		t.Fatalf("stdout is the return value and it does not parse: %q", stdout)
	}
	if url, _ := valueOf(*written, configWorkerURL); returned.URL != url {
		t.Errorf("the URL returned (%q) is not the one kept (%q)", returned.URL, url)
	}
	if returned.Account != "acc-1" || returned.Database == "" || returned.Keys != "generated" {
		t.Errorf("%+v", returned)
	}
}

// The secrets it generates are the whole of what this design has, and the place they leak from is
// a diagnostic. Neither may appear on either channel, ever.
func TestNothingSetupPrintsCarriesASecret(t *testing.T) {
	account := oneAccount()
	written := watched(t, account)

	stdout, stderr := capture(t, func() { run(input{}, []string{"setup"}) })

	for _, setting := range *written {
		if setting.key == configWorkerURL {
			continue
		}
		if strings.Contains(stdout, setting.value) || strings.Contains(stderr, setting.value) {
			t.Errorf("%s reached the output", setting.key)
		}
	}
}

// A phone is paired with the key, not with the account. Re-running setup — to repair a Worker
// somebody deleted, say — must not quietly re-key everything that is already reading.
func TestSetupKeepsTheKeyThePhonesAreAlreadyPairedWith(t *testing.T) {
	account := oneAccount()
	written := watched(t, account)
	key := base64.RawURLEncoding.EncodeToString(make([]byte, keySize))
	t.Setenv(envEncryptionKey, key)
	t.Setenv(envAuthToken, "the-token-already-on-the-worker")

	var code int
	stdout, _ := capture(t, func() { code = run(input{}, []string{"setup"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	for _, setting := range *written {
		if setting.key == configEncryptionKey || setting.key == configAuthToken {
			t.Errorf("%s was written again, which unpairs every phone that is reading", setting.key)
		}
	}
	if account.deployed.writeGate != "the-token-already-on-the-worker" {
		t.Errorf("the deploy did not carry the token that is already configured: %q", account.deployed.writeGate)
	}
	if !strings.Contains(stdout, `"keys":"kept"`) {
		t.Errorf("the return value does not say the keys were kept: %q", stdout)
	}
}

// A store that has just been stood up holds nothing, whatever this plugin remembers sending to
// the last one. Left remembered, the memory would say "the phone is level" over an empty store,
// and the next edit would be all that ever reached it.
func TestSetupForgetsWhatWasSentToTheStoreBeforeIt(t *testing.T) {
	account := oneAccount()
	watched(t, account)
	remembering(t)
	if err := writeState(state{Version: 12345, Cursor: 42}); err != nil {
		t.Fatal(err)
	}

	var code int
	capture(t, func() { code = run(input{}, []string{"setup"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if _, found, err := readState(); err != nil || found {
		t.Errorf("the send still remembers a store that is not there any more (found %v, err %v)", found, err)
	}
}

// A database that is already laid out is left alone. Laying the schema down twice fails on the
// first table, and a setup that could only ever be run once would be no use for repairing one.
func TestSetupLeavesADatabaseThatAlreadyHasItsTables(t *testing.T) {
	account := oneAccount()
	account.databases[setupName] = "db-already-there"
	account.laidOut = true
	watched(t, account)

	var code int
	capture(t, func() { code = run(input{}, []string{"setup"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	for _, statement := range account.statements {
		if strings.Contains(statement, "CREATE TABLE") {
			t.Errorf("the schema was laid down over one that was already there: %q", statement)
		}
	}
}

// Which account to build in is not a thing to guess at: a Worker and a database put somewhere the
// user did not mean are somewhere they have no reason to look.
func TestSetupRefusesToGuessBetweenAccounts(t *testing.T) {
	account := oneAccount()
	account.accounts = append(account.accounts, map[string]string{"id": "acc-2", "name": "Work"})
	watched(t, account)

	var code int
	_, stderr := capture(t, func() { code = run(input{}, []string{"setup"}) })

	if code != 1 {
		t.Fatalf("exit %d — it built something without being told where", code)
	}
	if account.deployed.happened {
		t.Error("something was deployed anyway")
	}
	if !strings.Contains(stderr, "--account") || !strings.Contains(stderr, "acc-2") {
		t.Errorf("the refusal has to say how to answer it: %q", stderr)
	}
}

// Named an account, it builds there and asks nothing.
func TestSetupBuildsInTheAccountItIsNamed(t *testing.T) {
	account := oneAccount()
	account.accounts = append(account.accounts, map[string]string{"id": "acc-2", "name": "Work"})
	watched(t, account)

	var code int
	stdout, _ := capture(t, func() { code = run(input{}, []string{"setup", "--account", "acc-2"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(stdout, `"account":"acc-2"`) {
		t.Errorf("it built somewhere else: %q", stdout)
	}
}

// The workers.dev name is account-wide and the user's to choose, so this is the one thing in the
// whole of setup that is handed back to them — with the place to do it.
func TestSetupSaysWhenTheAccountHasNoNameToAnswerOn(t *testing.T) {
	account := oneAccount()
	account.subdomain = ""
	written := watched(t, account)

	var code int
	_, stderr := capture(t, func() { code = run(input{}, []string{"setup"}) })

	if code != 1 {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(stderr, "workers.dev") || !strings.Contains(stderr, "dash.cloudflare.com") {
		t.Errorf("the refusal does not say what to do about it: %q", stderr)
	}
	if _, kept := valueOf(*written, configWorkerURL); kept {
		t.Error("an endpoint was kept for a Worker that answers nowhere")
	}
}

// Every other refusal of that same call is something else entirely — a token short of a
// permission, a limit, an outage. Told to go and choose a name they chose long ago, the user
// opens the dashboard, finds nothing there to do, and stops.
func TestSetupDoesNotBlameTheNameForEveryRefusal(t *testing.T) {
	account := oneAccount()
	account.subdomainRefusedWith.code = 10000
	account.subdomainRefusedWith.message = "Authentication error"
	written := watched(t, account)

	var code int
	_, stderr := capture(t, func() { code = run(input{}, []string{"setup"}) })

	if code != 1 {
		t.Fatalf("exit %d", code)
	}
	if strings.Contains(stderr, "dash.cloudflare.com") {
		t.Errorf("the user is sent to choose a name, which is not what went wrong: %q", stderr)
	}
	if !strings.Contains(stderr, "Authentication error") || !strings.Contains(stderr, "10000") {
		t.Errorf("what Cloudflare actually said did not reach the user: %q", stderr)
	}
	if _, kept := valueOf(*written, configWorkerURL); kept {
		t.Error("an endpoint was kept for a Worker that answers nowhere")
	}
}

// A Worker answering without its write token is a deploy that half landed, and it takes no
// writes. Reporting it as done would leave the user with a phone that never updates and nothing
// saying why.
func TestAWorkerWithNoWriteTokenIsNotReportedAsUp(t *testing.T) {
	account := oneAccount()
	watched(t, account)
	account.deployed.happened = true

	if err := awaitTheWorker(endpointOn("someone")); err == nil {
		t.Fatal("a Worker with no write token was taken for one that is up")
	} else if !strings.Contains(err.Error(), "write token") {
		t.Errorf("the reason is not the one that is true: %v", err)
	}
}

// The link is the whole of what the user is asked to judge — which is nothing, as long as it
// carries the three permissions already ticked.
func TestTheTokenLinkAsksForWhatSetupNeeds(t *testing.T) {
	link := tokenLink()

	if !strings.Contains(link, "to=%2F%3Aaccount%2Fapi-tokens") {
		t.Errorf("not the account form of the link, which is the one that survives a sign-in: %q", link)
	}
	for _, permission := range []string{"workers_scripts", "d1", "account_settings"} {
		if !strings.Contains(link, permission) {
			t.Errorf("%s is not asked for: %q", permission, link)
		}
	}
}

// Both secrets are drawn fresh and are the length the cipher takes — the key has to be, and the
// token has no reason to be shorter.
func TestASecretIsDrawnFreshAndIsLongEnough(t *testing.T) {
	first, second := generated(), generated()

	if first == second {
		t.Fatal("two draws came out the same")
	}
	for _, drawn := range []string{first, second} {
		raw, err := base64.RawURLEncoding.DecodeString(drawn)
		if err != nil {
			t.Fatalf("%q is not base64url: %v", drawn, err)
		}
		if len(raw) != keySize {
			t.Errorf("%d bytes, and the cipher takes %d", len(raw), keySize)
		}
	}
}

// What the plugin carries has to be the built Worker and the schema that goes under it, or a
// setup deploys something that cannot answer.
func TestWhatIsBakedInIsTheWorkerAndItsSchema(t *testing.T) {
	if !strings.Contains(string(workerScript), "export {") {
		t.Error("the baked script is not a module")
	}
	if !strings.Contains(string(workerScript), "WRITE_TOKEN") {
		t.Error("the baked script does not gate on the write token")
	}
	for _, table := range []string{"records", "tokens", "store"} {
		if !strings.Contains(workerSchema, "CREATE TABLE "+table) {
			t.Errorf("the baked schema has no %s table", table)
		}
	}
}
