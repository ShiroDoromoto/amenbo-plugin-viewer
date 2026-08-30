package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
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

	// What the database says it has had. `ledger` is nil for one that keeps none at all — which
	// is every database a release older than the ledger stood up.
	ledger []string

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

	// What reached the Worker itself once it was standing, in the order it landed. **Nothing
	// should**: standing a route up settles its settings and forgets its place, and the next send
	// is what writes. Anything in here is a write that should not have happened.
	landed []landing
}

// landing is one write that reached the deployed Worker.
type landing struct {
	path  string
	token string
	body  placement
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
		switch {
		case strings.Contains(asked.SQL, "sqlite_master"):
			if account.laidOut {
				rows = append(rows, map[string]any{"name": "records"})
			}
			if account.ledger != nil {
				rows = append(rows, map[string]any{"name": ledgerTable})
			}
		case strings.HasPrefix(strings.TrimSpace(asked.SQL), readTheLedger):
			for _, name := range account.ledger {
				rows = append(rows, map[string]any{"name": name})
			}
		default:
			// The run that applies migrations. What it lays down is the tables, and what it
			// writes into the ledger is the names it recorded — so the database that comes out
			// of it answers the next run the way a real one would.
			if strings.Contains(asked.SQL, "CREATE TABLE records") {
				account.laidOut = true
			}
			if account.ledger == nil {
				account.ledger = []string{}
			}
			account.ledger = append(account.ledger, whatItRecorded(asked.SQL)...)
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

	// Writes to the Worker. Nothing this run does should reach here — the door is open so that a
	// write which should not have happened is caught rather than refused into a diagnostic.
	road.HandleFunc("PUT /worker/{rest...}", func(w http.ResponseWriter, r *http.Request) {
		var body placement
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		account.landed = append(account.landed, landing{
			path:  "/" + r.PathValue("rest"),
			token: strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "),
			body:  body,
		})
		json.NewEncoder(w).Encode(map[string]any{"seq": len(account.landed)})
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

// whatItRecorded reads back the migration names a run wrote into the ledger — the stand-in's way
// of remembering what the database has had, without a database.
func whatItRecorded(sql string) []string {
	var names []string
	for _, line := range strings.Split(sql, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "INSERT INTO "+ledgerTable) {
			continue
		}
		open, close := strings.Index(line, "'"), strings.LastIndex(line, "'")
		if open >= 0 && close > open {
			names = append(names, line[open+1:close])
		}
	}
	return names
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

// watched replaces the write-back with one that only remembers, so no test can reach an Amenbo
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
	if !sameNames(account.ledger, everyMigration(t)) {
		t.Errorf("the database does not say what it was given: %v", account.ledger)
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

// Pressing the button on the settings screen is a person handing over a token for this run, and
// it is that token the account is built with — not one the machine happens to be carrying from
// some other piece of work. Nor is it written down: what is asked for at the button is used once,
// and the three values left behind afterwards can build nothing in anybody's account.
func TestTheTokenTypedOnTheSettingsScreenIsTheOneUsedAndIsKeptNowhere(t *testing.T) {
	account := oneAccount()
	written := watched(t, account)
	t.Setenv(envAskAPIToken, "the-token-just-typed")

	var code int
	capture(t, func() { code = run(input{}, []string{"setup"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if account.offered != "the-token-just-typed" {
		t.Errorf("Cloudflare was reached with %q", account.offered)
	}
	for _, setting := range *written {
		if setting.value == "the-token-just-typed" {
			t.Errorf("the API token was written back as the %s setting", setting.key)
		}
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
//
// **The folder beside it is left where it stands.** Nothing happened to it, and forgetting it too
// would cost it a whole placement for a Worker it has nothing to do with.
func TestSetupForgetsWhatWasSentToTheStoreBeforeItAndNothingElse(t *testing.T) {
	account := oneAccount()
	watched(t, account)
	remembering(t)
	if err := writeState(state{Routes: map[string]carried{
		routeCloudflare:                    {Version: 12345, Cursor: 42},
		"a-route-this-build-does-not-have": {Version: 12345, Cursor: 42},
	}}); err != nil {
		t.Fatal(err)
	}

	var code int
	capture(t, func() { code = run(input{}, []string{"setup"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	remembered, _, err := readState()
	if err != nil {
		t.Fatal(err)
	}
	if _, known := remembered.Routes[routeCloudflare]; known {
		t.Error("the send still remembers a store that is not there any more")
	}
	if left := remembered.Routes["a-route-this-build-does-not-have"]; left.Cursor != 42 {
		t.Errorf("the route beside it was left at %+v, and it is owed a whole placement it has no reason for", left)
	}
}

// **Standing a route up writes nothing into the store.** A key drawn afresh leaves whatever the
// last one sealed unopenable by anyone, and setup used to clear those rows on the spot — through
// the door that emptied the store, which is gone from both ends. What took its place makes the
// clearing unnecessary rather than impossible: the route has just been forgotten, so the next
// send carries the whole store, and every row the backlog still holds is written again under the
// new key.
func TestSetupWritesNothingIntoTheStore(t *testing.T) {
	account := oneAccount()
	watched(t, account)

	var code int
	capture(t, func() { code = run(input{}, []string{"setup"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if len(account.landed) != 0 {
		t.Errorf("standing the route up wrote %d time(s) into the store: %+v", len(account.landed), account.landed)
	}
}

// A database that already has its tables is not laid out a second time. Laying the schema down
// twice fails on the first table, and a setup that could only ever be run once would be no use
// for repairing one.
//
// What it does get is a ledger saying what it has had — because a database from before the ledger
// existed says nothing, and something has to, or the next migration has no way of telling this
// database apart from one that is up to date.
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
		if strings.Contains(statement, "CREATE TABLE records") {
			t.Errorf("the schema was laid down over one that was already there: %q", statement)
		}
	}
	// What it had is written down first, and whatever was added after that is applied on top —
	// so it ends up saying it has had them all.
	if !sameNames(account.ledger[:len(laidDownBeforeTheLedger)], laidDownBeforeTheLedger) {
		t.Errorf("the ledger does not open with what it already had: %v", account.ledger)
	}
	if !sameNames(account.ledger, everyMigration(t)) {
		t.Errorf("it did not go on to apply what it had not had: %v", account.ledger)
	}
}

// A migration added after a user's database was stood up has to reach it, and the run that
// reaches it must not touch the migrations that database has already had.
func TestSetupAppliesOnlyWhatTheDatabaseHasNotHad(t *testing.T) {
	all := everyMigration(t)
	if len(all) < 2 {
		t.Skip("there is only one migration, so there is nothing to be behind on")
	}
	account := oneAccount()
	account.databases[setupName] = "db-already-there"
	account.laidOut = true
	account.ledger = append([]string{}, all[:len(all)-1]...)
	behind := all[len(all)-1]
	watched(t, account)

	var code int
	capture(t, func() { code = run(input{}, []string{"setup"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	applied := ""
	for _, statement := range account.statements {
		if strings.Contains(statement, "INSERT INTO "+ledgerTable) {
			applied = statement
		}
	}
	if applied == "" {
		t.Fatalf("%s was never applied", behind)
	}
	if strings.Contains(applied, "CREATE TABLE records") {
		t.Error("a migration the database had already had was applied again")
	}
	if !sameNames(account.ledger, all) {
		t.Errorf("the ledger does not name every migration now: %v", account.ledger)
	}
}

// Run again with nothing new to apply, it applies nothing — and says so rather than sending a
// schema at a database that is already up to date.
func TestSetupAppliesNothingToADatabaseThatIsUpToDate(t *testing.T) {
	account := oneAccount()
	account.databases[setupName] = "db-already-there"
	account.laidOut = true
	account.ledger = everyMigration(t)
	watched(t, account)

	var code int
	capture(t, func() { code = run(input{}, []string{"setup"}) })

	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	for _, statement := range account.statements {
		if strings.Contains(statement, "CREATE TABLE") || strings.Contains(statement, "INSERT INTO") {
			t.Errorf("something was applied to a database that has had it all: %q", statement)
		}
	}
}

// everyMigration is what this build carries, by name and in order.
func everyMigration(t *testing.T) []string {
	t.Helper()
	migrations, err := theMigrations()
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, len(migrations))
	for i, one := range migrations {
		names[i] = one.name
	}
	return names
}

func sameNames(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range got {
		if got[i] != want[i] {
			return false
		}
	}
	return true
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
	} else if !strings.Contains(err.Error(), "API token for writing") {
		t.Errorf("the reason is not the one that is true: %v", err)
	}
}

// The button hands the browser the same link `setup` would have printed. Anything else on it —
// a bare token page, a link that lost its permissions — puts the user in front of Cloudflare's
// several dozen permission groups, which is the one judgement this plugin promises never to ask
// for.
func TestTheButtonOpensTheLinkWithThePermissionsOnIt(t *testing.T) {
	opened, _, err := pressed(t, onAScreen, opensFine)
	if err != nil {
		t.Fatal(err)
	}

	if opened != tokenLink() {
		t.Errorf("the button opened %q, and the link is %q", opened, tokenLink())
	}
}

// **A page that would not open still has to say where it was.** The link is the whole point of
// the press, and a failure that swallowed it would leave the user with no terminal — the only
// user this button exists for — with nowhere to go.
func TestAPageThatWillNotOpenStillSaysWhereItIs(t *testing.T) {
	refused := errors.New("no opener here")

	_, _, err := pressed(t, onAScreen, func(string) error { return refused })

	if err == nil {
		t.Fatal("a page that never opened was reported as opened")
	}
	if !strings.Contains(err.Error(), tokenLink()) {
		t.Errorf("the link is not in what the user is told: %v", err)
	}
	if !errors.Is(err, refused) {
		t.Errorf("why it would not open is lost: %v", err)
	}
}

// A machine with no screen is not a failure to report: nothing there could have opened the page,
// and the person pressing this from an SSH session has a browser in front of them elsewhere. So
// the link is written out instead, and the run ends as a run that did what it could.
func TestAMachineWithNoScreenIsGivenTheLinkInsteadOfAPage(t *testing.T) {
	opened, stderr, err := pressed(t, withNoScreen, opensFine)
	if err != nil {
		t.Fatal(err)
	}

	if opened != "" {
		t.Errorf("a page was handed to an opener with nowhere to put it: %q", opened)
	}
	if !strings.Contains(stderr, tokenLink()) {
		t.Errorf("the link the user has to go to by hand was not written out: %q", stderr)
	}
}

// Nothing is asked and nothing is saved, so the press leaves the settings exactly as it found
// them. The token itself is pasted into the next button, and this one never sees it.
func TestTheButtonWritesNothingBack(t *testing.T) {
	stdout, stderr := capture(t, func() {
		was, wasScreen := openInTheSystem, thereIsAScreen
		openInTheSystem, thereIsAScreen = opensFine, onAScreen
		defer func() { openInTheSystem, thereIsAScreen = was, wasScreen }()
		if err := token(input{}, nil); err != nil {
			t.Fatal(err)
		}
	})

	if strings.TrimSpace(stdout) != "" {
		t.Errorf("the button returned %q, and a page being opened has no return value", stdout)
	}
	if strings.Contains(stderr, envAskAPIToken) || strings.Contains(stderr, envCloudflareToken) {
		t.Errorf("the press went looking for a token, and it has none of its own to want: %q", stderr)
	}
}

// The two screens a press can happen on, named rather than spelled out at each call.
var (
	onAScreen    = func() bool { return true }
	withNoScreen = func() bool { return false }
	opensFine    = func(string) error { return nil }
)

// pressed runs the button as the settings screen would, with the machine's screen and its opener
// both stood in for, and answers with what was opened, what the user was told, and the verdict.
func pressed(t *testing.T, screen func() bool, open func(string) error) (opened, stderr string, err error) {
	t.Helper()
	wasOpen, wasScreen := openInTheSystem, thereIsAScreen
	openInTheSystem = func(target string) error { opened = target; return open(target) }
	thereIsAScreen = screen
	t.Cleanup(func() { openInTheSystem, thereIsAScreen = wasOpen, wasScreen })

	_, stderr = capture(t, func() { err = token(input{}, nil) })
	return opened, stderr, err
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

// What the plugin carries has to be the built Worker and the migrations that go under it, or a
// setup deploys something that cannot answer.
func TestWhatIsBakedInIsTheWorkerAndItsMigrations(t *testing.T) {
	if !strings.Contains(string(workerScript), "export {") {
		t.Error("the baked script is not a module")
	}
	if !strings.Contains(string(workerScript), "WRITE_TOKEN") {
		t.Error("the baked script does not gate on the write token")
	}
	migrations, err := theMigrations()
	if err != nil {
		t.Fatal(err)
	}
	var schema strings.Builder
	for _, one := range migrations {
		schema.WriteString(one.sql)
	}
	for _, table := range []string{"records", "tokens", "store"} {
		if !strings.Contains(schema.String(), "CREATE TABLE "+table) {
			t.Errorf("the baked migrations have no %s table", table)
		}
	}

	// The frozen list is what a database from before the ledger is told it has had, so a name in
	// it that no longer names a migration would leave that migration unapplied forever.
	for _, name := range laidDownBeforeTheLedger {
		if !slices.ContainsFunc(migrations, func(one migration) bool { return one.name == name }) {
			t.Errorf("%s is on the before-the-ledger list and is not a migration this build carries", name)
		}
	}
}
