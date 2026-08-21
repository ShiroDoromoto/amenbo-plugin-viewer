package main

import (
	"bytes"
	"crypto/rand"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"time"

	"golang.org/x/term"
)

// `setup` stands the Cloudflare route up in the user's own account, and the whole of what it asks
// of them is one press and one paste.
//
// **They are never asked to judge anything.** Which permissions a token needs, what the database
// is called, how long a key is, where the Worker answers — every one of those is a decision this
// plugin has already made, and a setup that handed any of them over would be asking the user to
// get right something they have no way of checking.
//
// What is left on their machine afterwards is three settings: the endpoint, the write token and
// the encryption key. What is left in their account is a Worker and a database that are theirs —
// uninstalling the plugin does not take them away, and nothing here can reach them again without
// a token they would have to paste a second time.

// The Worker deployed into the user's account carries these names. They are the same ones the
// Worker's own config names it by, so a user who later reaches for wrangler in that directory is
// pointed at the thing this put there rather than at a second copy of it.
const (
	setupName         = "amenbo-viewer"
	databaseBinding   = "RECORDS"
	writeTokenBinding = "WRITE_TOKEN"
	compatibilityDate = "2026-08-01"
)

// The built Worker, baked in at build time. The user's PC has no Node on it and no copy of this
// repository, so what stands the route up carries what it deploys. The migrations its database is
// brought up to are baked in the same way — see migrate.go.
//
// **It is generated.** The Worker's own source is what it is built from, and the Worker's build
// is what writes it here.
//
//go:embed worker.js
var workerScript []byte

// The three ways the Cloudflare API token reaches this run, and not one of them keeps it.
//
// askAPIToken is what the manifest declares the settings screen to ask for when the user presses
// the button that runs this: Amenbo hands the answer over in envAskAPIToken for that one run and
// saves nothing. envCloudflareToken is spelled the way wrangler spells it, so a machine that
// already has one set is already set up for this. A terminal is the third, and the only one that
// asks a person while the run waits.
const (
	askAPIToken        = "api_token"
	envAskAPIToken     = "AMENBO_ASK_API_TOKEN"
	envCloudflareToken = "CLOUDFLARE_API_TOKEN"
)

// The permissions the token has to carry, and nothing besides. They are put into the link that
// opens the token screen with the boxes already ticked — the user presses Create, and is never
// asked which of Cloudflare's permission groups a drop box takes.
var tokenPermissions = []map[string]string{
	{"key": "workers_scripts", "type": "edit"},  // to deploy the Worker
	{"key": "d1", "type": "edit"},               // to make the database and write to it
	{"key": "account_settings", "type": "read"}, // to learn which account this is
}

// What the check after the deploy is willing to wait through. A workers.dev name that was turned
// on a second ago is not answering everywhere yet, and that is not a failure to report — it is a
// wait to sit through once.
const (
	checkAttempts = 6
	checkPause    = 3 * time.Second
)

func setup(_ input, args []string) error {
	options := flag.NewFlagSet("setup", flag.ContinueOnError)
	options.SetOutput(errOut)
	account := options.String("account", "", "the Cloudflare account to build in, when the token reaches more than one")
	if err := options.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}

	token, err := pastedToken()
	if err != nil {
		return err
	}
	air := reachCloudflare(token)

	where, err := air.theAccount(*account)
	if err != nil {
		return err
	}
	logf("%s: building in account %s", pluginName, where)

	database, fresh, err := air.theDatabase(where, setupName)
	if err != nil {
		return err
	}
	logf("%s: database %s (%s)", pluginName, setupName, describe(fresh))
	if err := layTheSchemaDown(air, where, database, fresh); err != nil {
		return err
	}

	writeToken, keptToken := secret(envAuthToken), true
	if writeToken == "" {
		writeToken, keptToken = generated(), false
	}
	key, keptKey := secret(envEncryptionKey), true
	if key == "" {
		key, keptKey = generated(), false
	}

	if err := air.deploy(where, setupName, workerScript, database, writeToken); err != nil {
		return err
	}
	logf("%s: Worker %s deployed", pluginName, setupName)

	subdomain, err := air.theSubdomain(where)
	if errors.Is(err, errNoSubdomain) {
		return fmt.Errorf("the Worker is deployed, but this account has no workers.dev name for it to answer on yet."+
			" Choose one at https://dash.cloudflare.com/%s/workers/subdomain and run setup again", where)
	}
	if err != nil {
		return err
	}
	if err := air.answerOnTheSubdomain(where, setupName); err != nil {
		return err
	}
	endpoint := endpointOn(subdomain)

	// The endpoint is written last on purpose. Half a route is not a route — the send reads the
	// URL and the token together — so a run interrupted between these three leaves the plugin
	// where it was rather than pointing it at somewhere it cannot get into.
	if !keptKey {
		if err := settle(configEncryptionKey, key); err != nil {
			return err
		}
	}
	if !keptToken {
		if err := settle(configAuthToken, writeToken); err != nil {
			return err
		}
	}
	if err := settle(configWorkerURL, endpoint); err != nil {
		return err
	}

	if err := awaitTheWorker(endpoint); err != nil {
		return err
	}

	// A route that has just been stood up is one nothing has been sent to, whatever this plugin
	// remembers sending to the last one. Forgetting here is what makes the next send place the
	// whole store rather than the next edit alone — and it is the only place it can be settled,
	// since the write token is refused at the store's reading door.
	//
	// **This route and no other.** Standing a Worker up says nothing about the folder on this
	// machine, and forgetting that too would cost it a whole placement for something that did
	// not happen to it.
	if err := forgetRoute(routeCloudflare); err != nil {
		return err
	}

	logf("%s: the Cloudflare route is up at %s", pluginName, endpoint)
	if keptKey {
		logf("%s: the encryption key already in the settings was kept, so the phones paired with it still read.", pluginName)
	} else {
		logf("%s: a new encryption key was generated — pair a phone with `amenbo plugin run %s qr`.", pluginName, pluginName)
	}
	logf("%s: the Worker and the database are yours. Uninstalling this plugin leaves them where they are;\n"+
		"  delete them in the Cloudflare dashboard when you want them gone.", pluginName)

	return json.NewEncoder(out).Encode(map[string]any{
		"url":      endpoint,
		"account":  where,
		"database": database,
		"keys":     kept(keptKey && keptToken),
	})
}

// endpointOn is where the Worker answers once it has been turned on: its own name under the
// account's workers.dev name.
func endpointOn(subdomain string) string {
	if where := standingIn(); where != "" {
		return where + "/worker"
	}
	return fmt.Sprintf("https://%s.%s.workers.dev", setupName, subdomain)
}

func describe(fresh bool) string {
	if fresh {
		return "created"
	}
	return "already there"
}

func kept(everything bool) string {
	if everything {
		return "kept"
	}
	return "generated"
}

// pastedToken gets the Cloudflare API token from the person running this.
//
// **It is not taken on argv.** A token typed after a command is in the shell's history and in
// every process listing on the machine for as long as the call runs, and a credential that can
// deploy into someone's account is not one to leave in either. So it is read from the terminal,
// with the echo off, which is also what makes it a paste rather than something to read back.
//
// What the user just typed comes first. The settings screen asks only when its button was
// pressed, so an answer there is this run's; a variable the machine happens to carry is ambient,
// and standing up someone's account with a token they did not mean to use this time is the one
// mistake here nobody can undo from a prompt.
func pastedToken() (string, error) {
	if token := strings.TrimSpace(os.Getenv(envAskAPIToken)); token != "" {
		return token, nil
	}
	if token := strings.TrimSpace(os.Getenv(envCloudflareToken)); token != "" {
		logf("%s: using the token in %s", pluginName, envCloudflareToken)
		return token, nil
	}

	terminal, err := os.OpenFile(terminalPath, os.O_RDWR, 0)
	if err != nil {
		return "", fmt.Errorf("there is no terminal here to paste into — put the token in %s instead: %w", envCloudflareToken, err)
	}
	defer terminal.Close()

	// **What to do goes to the terminal, not to stderr.** Amenbo holds a plugin's stderr until
	// the run is over and prints it then, which is right for a record of what happened and wrong
	// for the one thing here that is asked before anything can carry on: a person waiting at a
	// prompt with the link still unprinted has nothing to paste.
	fmt.Fprintf(terminal, `
%s needs an API token for your own Cloudflare account.

  1. open this — the permissions it needs are already ticked:

     %s

  2. press Continue to summary, then Create Token
  3. copy the token it shows you, and paste it below

The token is used once, to stand the Worker and its database up, and is not kept.
`, pluginName, tokenLink())

	fmt.Fprint(terminal, "\npaste the token (it will not be shown), then press return: ")
	raw, err := term.ReadPassword(int(terminal.Fd()))
	fmt.Fprintln(terminal)
	if err != nil {
		return "", fmt.Errorf("nothing could be read from the terminal — put the token in %s instead: %w", envCloudflareToken, err)
	}
	token := strings.TrimSpace(string(raw))
	if token == "" {
		return "", errors.New("no token was pasted")
	}
	return token, nil
}

// token puts Cloudflare's token screen on screen, with the permissions `setup` needs already
// ticked, and ends there. It asks nothing, keeps nothing, and writes nothing back — what happens
// on that page is the user making a token, which they then paste into the box behind the setup
// button.
//
// **It is a button of its own because the link had nowhere else to be shown.** `setup` prints it
// to the terminal, and only on the run where nothing was pasted — so the user who came to the
// settings screen, with a token box in front of them and no terminal at all, is the one who
// never sees it. The screen draws labels and help as plain text, so the link
// cannot be written into the form either. A button that opens the page is what is left.
func token(_ input, _ []string) error {
	link := tokenLink()

	// A machine with no screen has nothing to open a page on, and handing the run to an opener
	// that has nowhere to put it would fail for a reason the user can do nothing about. The link
	// itself is the answer there — someone over SSH pastes it into the browser they are sitting
	// in front of.
	if !thereIsAScreen() {
		logf("%s: there is no screen here to open it on. The token page is at %s", pluginName, link)
		return nil
	}
	if err := openInTheSystem(link); err != nil {
		return fmt.Errorf("the token page could not be opened (%w) — it is at %s", err, link)
	}
	logf("%s: the token page is open, with the permissions it needs already ticked. Press Continue to summary, then Create Token, and paste what it shows you into the box behind the setup button.", pluginName)
	return nil
}

// tokenLink opens Cloudflare's token screen with this plugin's permissions already chosen.
//
// **The account form of the link, not the user form.** A user-token link
// (`/profile/api-tokens?…`) loses its query the moment an unsigned-in visitor signs in, and lands
// them on the account home with nothing ticked — and someone making a Cloudflare account for this
// is signed out by definition.
func tokenLink() string {
	permissions, err := json.Marshal(tokenPermissions)
	if err != nil {
		return "https://dash.cloudflare.com/?to=/:account/api-tokens"
	}
	asked := url.Values{}
	asked.Set("to", "/:account/api-tokens")
	asked.Set("permissionGroupKeys", string(permissions))
	asked.Set("name", "Amenbo")
	return "https://dash.cloudflare.com/?" + asked.Encode()
}

// generated draws one of the two secrets this plugin keeps: 32 bytes of randomness, written the
// way everything that leaves here is written.
//
// Both are the same length because the cipher fixes one of them — a key is 256 bits — and there
// is no reason for the token that opens the writing door to be shorter than the key that opens
// the records.
func generated() string {
	// crypto/rand does not report failure: it panics rather than hand back a buffer it could not
	// fill, which is the right end for a value whose whole worth is being unguessable.
	raw := make([]byte, keySize)
	rand.Read(raw)
	return base64.RawURLEncoding.EncodeToString(raw)
}

// settle writes one setting back through Amenbo, with the value on stdin rather than on the
// command line — which is what keeps the two secrets out of the shell's history and out of the
// machine's process listing.
//
// **No --actor is passed**, for the same reason the sync calls pass none: Amenbo puts the
// plugin's own reach in the environment when it fires it, and that reach is the facet.
//
// It is a variable so a test can watch what a run writes back without a store standing behind it
// — the one thing a test of this must not do is reach an Amenbo that somebody's work is in.
var settle = func(key, value string) error {
	command := exec.Command(amenboProgram, "plugin", "config", "set", pluginName, key, "-")
	command.Stdin = strings.NewReader(value)
	var diagnostics bytes.Buffer
	command.Stderr = &diagnostics
	if err := command.Run(); err != nil {
		return fmt.Errorf("Amenbo would not keep the %s setting: %w: %s", key, err, strings.TrimSpace(diagnostics.String()))
	}
	return nil
}

// awaitTheWorker waits for the deployed Worker to turn a stranger away.
//
// **Being refused is the answer that means everything landed.** A 401 says the script is running,
// the database it looks tokens up in is bound, and the write token it compares against is set —
// there is no other single call that says all three, since reading a record needs a token no
// phone has been given yet.
func awaitTheWorker(endpoint string) error {
	client := &http.Client{Timeout: setupTimeout}
	var last error
	for attempt := 1; attempt <= checkAttempts; attempt++ {
		answer, err := client.Get(endpoint + "/meta")
		if err == nil {
			answer.Body.Close()
			switch answer.StatusCode {
			case http.StatusUnauthorized:
				return nil
			case http.StatusServiceUnavailable:
				return errors.New("the Worker is answering but has no write token set, which is a deploy that did not fully land — run setup again")
			}
			last = fmt.Errorf("%s answered %d, where a caller with no token should be turned away with 401", endpoint, answer.StatusCode)
		} else {
			last = err
		}
		if attempt < checkAttempts {
			time.Sleep(checkPause)
		}
	}
	return fmt.Errorf("everything was created, but the endpoint is not answering the way it should yet: %w", last)
}
