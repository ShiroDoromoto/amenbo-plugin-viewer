package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"testing"
)

// inJapanese speaks the settings face in one language for the length of a test, and puts it back
// afterwards. **The zero value is English**, so this is the only way a test reads anything else —
// and a test that forgot to put it back would move a language into the test that runs next.
func inJapanese(t *testing.T) {
	t.Helper()
	was := screen
	screen = wordsIn("ja")
	t.Cleanup(func() { screen = was })
}

// Every language Amenbo offers has a row, spelled the way the store spells it. A
// code that drifted — `pt-br` for `pt-BR` — is a row nothing ever reads, and what the user would
// see is English, quietly.
func TestEveryLanguageAmenboOffersHasARow(t *testing.T) {
	offered := []string{
		"de", "en", "es", "fr", "hi", "id", "it", "ja", "ko", "nl",
		"pl", "pt-BR", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
	}
	for _, code := range offered {
		if _, has := wordings[code]; !has {
			t.Errorf("no row for %q", code)
		}
	}
	if len(wordings) != len(offered) {
		t.Errorf("got %d rows for %d languages — one of them is spelled wrong", len(wordings), len(offered))
	}
}

// everyPhrase is every sentence the settings face says, which is what the coverage below is
// measured against. It is written out rather than derived, so a phrase added to the code and
// forgotten in the languages shows up here as a line nobody added.
var everyPhrase = []phrase{
	phCloudflareWorker, phStandTheWorkerUp, phTheSetupButton, phThePairButton,
	phStandingWithNoKey, phStandingBadKey, phCarryingTo, phCarryingNowhere,
	phNothingIsTicked, phWaitingOn, phNowhere, phAnd, phComma,
	phCodeNotDrawn, phPointTheCamera, phReadThisWithTheCamera,
	phNoScreenForTheTokenPage, phTokenPageNotOpened, phTokenPageIsOpen,
	phBuildingInAccount, phDatabaseCreated, phDatabaseAlreadyThere, phWorkerDeployed,
	phNoWorkersDevName, phTheRouteIsUp, phTheKeyWasKept, phANewKeyWasGenerated,
	phTheWorkerIsYours, phNoTokenWasPasted, phTokenReachesNoAccount,
	phWorkerHasNoWriteToken, phEndpointNotAnsweringYet,
	phPhoneMayReadFromNowOn, phPhoneAlreadyPaired, phNoEncryptionKey,
	phNoCloudflareRouteYet, phThePhoneWasNotNamed,
}

// Every language carries every sentence, and carries no sentence this build has stopped saying.
// English is what a gap falls back to, so a gap would not show as a blank line — it would show as
// one language quietly said in another, which is the kind of thing a test has to catch rather
// than a reader.
func TestEveryLanguageSaysEverything(t *testing.T) {
	known := map[phrase]bool{}
	for _, p := range everyPhrase {
		known[p] = true
	}
	for language, words := range wordings {
		for _, p := range everyPhrase {
			if strings.TrimSpace(words[p]) == "" {
				t.Errorf("%s: nothing to say for %q", language, p)
			}
		}
		for p := range words {
			if !known[p] {
				t.Errorf("%s: says %q, which nothing asks for any more", language, p)
			}
		}
	}
}

// verbs is what a sentence has to be handed before it can be said.
var verbs = regexp.MustCompile(`%[a-zA-Z]`)

// **A translation spends what the English spends, in the order it spends it.** Go fills a format
// from left to right, so a row that dropped a `%s` would print the sentence with `%!(EXTRA …)`
// trailing it, and one that swapped `%w` for `%s` would quietly stop wrapping the error a caller
// reaches for with `errors.Is`.
func TestEverySentenceSpendsWhatTheEnglishSpends(t *testing.T) {
	english := wordings[fallbackLanguage]
	for language, words := range wordings {
		for _, p := range everyPhrase {
			want, got := verbs.FindAllString(english[p], -1), verbs.FindAllString(words[p], -1)
			if strings.Join(want, "") != strings.Join(got, "") {
				t.Errorf("%s: %q spends %v, and the English spends %v", language, p, got, want)
			}
		}
	}
}

// A language this build has never heard of — one Amenbo has grown and this plugin has not — falls
// back whole rather than being guessed at, and a row that is simply short falls back phrase by
// phrase, so a translation may arrive in pieces.
func TestALanguageThisBuildHasNotHeardOfFallsBackToEnglish(t *testing.T) {
	if got, want := wordsIn("sv").say(phCarryingNowhere), wordings["en"][phCarryingNowhere]; got != want {
		t.Errorf("got %q, want the English %q", got, want)
	}
	half := wording{phCarryingNowhere: "Nirgendwohin."}
	if got, want := half.say(phNothingIsTicked), wordings["en"][phNothingIsTicked]; got != want {
		t.Errorf("a phrase nobody filled in: got %q, want the English %q", got, want)
	}
}

// The check answers in the language the store is set to, and what it names is untouched: an
// address is an address in every one of them.
func TestTheCheckAnswersInTheStoresLanguage(t *testing.T) {
	inJapanese(t)
	in := thePlaceStanding(t, ticked("cloudflare"))

	said := whatIsReaching(screen, routesStanding(in))

	if !strings.Contains(said, "届いている先") {
		t.Errorf("the check did not answer in Japanese: %q", said)
	}
	if strings.Contains(said, "Carrying") {
		t.Errorf("the check answered in two languages at once: %q", said)
	}
}

// The observation face is the execution log's material and stays English whatever the store is
// set to — a line nobody is waiting on, read by whoever is working out why a phone
// is behind.
func TestTheLogASendLeavesIsEnglishWhateverTheStoreReadsIn(t *testing.T) {
	inJapanese(t)
	t.Setenv(envAuthToken, "a-throwaway-token")
	t.Setenv(envEncryptionKey, "not-a-key")
	in := fired("task.done", map[string]any{
		configWorkerURL: "https://viewer.example.workers.dev",
		configRoutes:    routeCloudflare,
	})

	_, said := capture(t, func() { routesFor(in) })

	if !strings.Contains(said, "nothing is reaching your server on Cloudflare") {
		t.Errorf("the log line is not the English one: %q", said)
	}
}

// The buttons answer in that language too — they are the settings screen's own, and the first
// line one of them writes is what the screen draws under the form.
func TestAButtonAnswersInTheStoresLanguage(t *testing.T) {
	inJapanese(t)
	openInTheSystem = func(string) error { return nil }
	t.Cleanup(func() {
		openInTheSystem = func(target string) error {
			return fmt.Errorf("a test reached for the machine's screen with %q", target)
		}
	})
	inATerminal(t)

	_, said := capture(t, func() {
		if err := token(input{}, nil); err != nil {
			t.Fatalf("the token page would not open: %v", err)
		}
	})

	if !strings.Contains(said, "トークンのページを開きました") {
		t.Errorf("the button did not answer in Japanese: %q", said)
	}
}

// **Every language has to fit the same 200 bytes**, and they do not spend them alike: the App
// Store address is 45 of them in all nineteen, and a Devanagari or Thai character costs three
// where a Latin one costs one. The worst case is a fresh install — the place ticked, nothing
// standing — which is the line that pays for the address as well as the waiting.
//
// Cut, what goes is the tail, which is what to do next. That is the half a reader would have to
// guess at, and guessing is what this line exists to stop.
func TestEveryLanguageFitsTheLineAFreshInstallReads(t *testing.T) {
	t.Setenv(envAuthToken, "")
	t.Setenv(envEncryptionKey, "")
	standing := routesStanding(fired("", map[string]any{configRoutes: routeCloudflare}))

	for language := range wordings {
		said := whatIsReaching(wordsIn(language), standing)
		if strings.HasSuffix(said, "…") {
			t.Errorf("%s is cut at %d bytes: %q", language, checkAnswerBytes, said)
		}
		// **The number is what every language shares.** What to do next is a button, and the
		// button is named in the reader's own words — but it is the third one in all nineteen,
		// so the number is what says the tail survived the cut.
		if !strings.Contains(said, "3.") {
			t.Errorf("%s has lost what to do next: %q", language, said)
		}
	}
}

// The store is asked what language it reads in, and a store that will not answer costs the
// sentences their language and nothing else — the settings screen shows English rather than
// nothing at all.
func TestAStoreThatWillNotAnswerLeavesTheSentencesInEnglish(t *testing.T) {
	was := languageInTheStore
	languageInTheStore = func() string { return fallbackLanguage }
	t.Cleanup(func() { languageInTheStore = was })

	stdout, _ := capture(t, func() { run(input{}, []string{"check"}) })

	var answered struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal([]byte(stdout), &answered); err != nil {
		t.Fatalf("the check did not answer with a document: %v", err)
	}
	if !strings.Contains(answered.Message, "Carrying") {
		t.Errorf("the fallback is not English: %q", answered.Message)
	}
}
