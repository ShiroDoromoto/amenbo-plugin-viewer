package main

import "fmt"

// This file is what the settings screen says, and the only place it is spelled.
//
// **The line is drawn by Amenbo's own window, beside labels Amenbo has already translated.** The
// manifest's `desc`, the field labels and the button labels are carried in the catalogue's
// overlay files the catalogue carries, so a reader whose Amenbo is in Japanese sees a form
// in Japanese — and then the author's own sentences, the ones this plugin composes while it runs,
// arrive underneath in English. There is no overlay for those: they do not exist until the code
// has run. So the plugin carries them, the way the mail plugin carries its message wording.
//
// # Which sentences are here, and which are not
//
// Here: what `check` answers, and what the seven buttons — `app`, `token`, `setup`, `qr`,
// `phones`, `revoke`, `repair` — write for a person to read. Those eight are the settings face: the screen draws the
// check's line at the head of the form and the first line an operation wrote underneath it, and
// for a user with no terminal they are the only way any of this is reached.
//
// Not here, and English on purpose:
//
//   - The observation face. Nobody is waiting on it; its lines are the execution log's material
//     read by whoever is working out why a phone is behind.
//   - `push` and the usage. They are typed, and what is typed is English: Amenbo splits its
//     languages by who is reading, and a face reached by typing is not one a settings screen ever
//     draws. **`phones` and `revoke` used to be here** and are not any more — unpairing had to be
//     reachable without a terminal, so the screen raises them too, and a call cannot answer in two
//     languages at once.
//   - The paths that only a terminal reaches — being asked to paste, being warned about
//     scrollback. A settings screen never takes them.
//   - What another machine said. A Cloudflare refusal and an HTTP status are quoted, not worded.
//   - What says this build cannot read something. That sentence is for whoever fixes the build.

// fallbackLanguage is the row every other one is read against: the one that must be complete. A
// language this build has never heard of falls back to it whole, and a phrase nobody has filled
// in yet falls back to it on its own — so a translation can arrive in pieces without one of them
// being the piece that leaves a sentence blank.
const fallbackLanguage = "en"

// phrase names one sentence. The name is what the code says; the sentence is what a language
// says, and no caller ever holds one of those.
type phrase string

// Every sentence the settings face says. They are grouped by the call that says them, which is
// also the order a person meets them in: the check at the head of the form, then the four buttons
// in the order they are numbered.
const (
	// What `check` answers with — the places, what each is waiting for, and the sentence they
	// are set into.
	phCloudflareWorker  phrase = "cloudflare_worker"
	phStandTheWorkerUp  phrase = "stand_the_worker_up"
	phStandingWithNoKey phrase = "standing_with_no_key"
	phStandingBadKey    phrase = "standing_bad_key"
	phCarryingTo        phrase = "carrying_to"
	phCarryingNowhere   phrase = "carrying_nowhere"
	phNothingIsTicked   phrase = "nothing_is_ticked"
	phWaitingOn         phrase = "waiting_on"
	phNowhere           phrase = "nowhere"
	phAnd               phrase = "and"
	phComma             phrase = "comma"

	// `app` — putting the App Store page in front of a camera.
	phCodeNotDrawn   phrase = "code_not_drawn"
	phPointTheCamera phrase = "point_the_camera"

	// The line drawn beside a code on the settings screen, which `app` and `qr` both put there.
	phReadThisWithTheCamera phrase = "read_this_with_the_camera"

	// `token` — opening Cloudflare's token page.
	phNoScreenForTheTokenPage phrase = "no_screen_for_the_token_page"
	phTokenPageNotOpened      phrase = "token_page_not_opened"
	phTokenPageIsOpen         phrase = "token_page_is_open"

	// The buttons a sentence has to name, because what to do next is press one of them.
	//
	// **The label itself is the catalogue's**, carried in the overlay files beside the manifest,
	// and this is the plugin's own copy of it. There is nowhere else for it to be: a sentence
	// composed while the plugin runs cannot be translated in an overlay, and a sentence that says
	// "press the third button" instead of naming it is the mismatch this wording exists to end
	// (a form whose buttons read one way and whose sentences point somewhere else). So the two
	// are kept level by hand — **a button renamed in the catalogue is renamed here**.
	//
	// **A label weighs 40 bytes at most, per language** — Amenbo's cap on what a button may
	// carry, and the door the catalogue is held to. A Devanagari or Thai character spends three
	// of them where a Latin one spends one, so what four languages call these buttons is shorter
	// than the English reads: a name that will not fit is a name no button can wear, and a
	// sentence naming it would point at nothing. `TestEveryButtonNameFitsOnAButton` measures it.
	phTheSetupButton     phrase = "the_setup_button"
	phThePairButton      phrase = "the_pair_button"
	phTheSeePhonesButton phrase = "the_see_phones_button"
	phTheUnpairButton    phrase = "the_unpair_button"
	phTheRepairButton    phrase = "the_repair_button"

	// `setup` — standing the Worker and its database up.
	phBuildingInAccount       phrase = "building_in_account"
	phDatabaseCreated         phrase = "database_created"
	phDatabaseAlreadyThere    phrase = "database_already_there"
	phWorkerDeployed          phrase = "worker_deployed"
	phNoWorkersDevName        phrase = "no_workers_dev_name"
	phTheRouteIsUp            phrase = "the_route_is_up"
	phTheKeyWasKept           phrase = "the_key_was_kept"
	phANewKeyWasGenerated     phrase = "a_new_key_was_generated"
	phTheWorkerIsYours        phrase = "the_worker_is_yours"
	phNoTokenWasPasted        phrase = "no_token_was_pasted"
	phTokenReachesNoAccount   phrase = "token_reaches_no_account"
	phWorkerHasNoWriteToken   phrase = "worker_has_no_write_token"
	phEndpointNotAnsweringYet phrase = "endpoint_not_answering_yet"

	// `phones` and `revoke` — seeing which phones may read, and cutting one off.
	phPhonesThatMayRead          phrase = "phones_that_may_read"
	phPairedOn                   phrase = "paired_on"
	phNoPhoneIsPairedYet         phrase = "no_phone_is_paired_yet"
	phTheRestAreInTheLog         phrase = "the_rest_are_in_the_log"
	phWhichPhoneToUnpair         phrase = "which_phone_to_unpair"
	phNoPhoneByThatName          phrase = "no_phone_by_that_name"
	phNothingWasReadingAsThat    phrase = "nothing_was_reading_as_that"
	phPhoneReadsNothingFromNowOn phrase = "phone_reads_nothing_from_now_on"

	// `qr` — pairing one phone.
	phPhoneMayReadFromNowOn phrase = "phone_may_read_from_now_on"
	phPhoneAlreadyPaired    phrase = "phone_already_paired"
	phNoEncryptionKey       phrase = "no_encryption_key"
	phNoCloudflareRouteYet  phrase = "no_cloudflare_route_yet"
	phThePhoneWasNotNamed   phrase = "the_phone_was_not_named"

	// `repair` — comparing what the server holds with what is here, and carrying the difference.
	// The count is said first and the sending happens on the second press, so the two answers are
	// two sentences rather than one with a number that means different things.
	phRepairWillSend     phrase = "repair_will_send"
	phRepairFoundNothing phrase = "repair_found_nothing"
	phRepairIsOnItsWay   phrase = "repair_is_on_its_way"
)

// wording is one language's side of every sentence, keyed by the name the code says.
type wording map[phrase]string

// screen is the language the settings face is spoken in. **Its zero value is English**, which is
// what makes it safe to leave alone: a call that is not the settings face never sets it, and a
// test that drives one of those calls directly reads the English it was written against.
//
// It is set once, in `run`, and only for the five calls the settings screen raises — so nothing
// else in this plugin pays for the read, least of all the observation face, which is fired on
// every write.
var screen wording

// wordsIn is the row a language reads from. A code this build has never heard of — a language
// Amenbo has grown and this plugin has not — falls back whole rather than being guessed at.
func wordsIn(language string) wording {
	if words, has := wordings[language]; has {
		return words
	}
	return wordings[fallbackLanguage]
}

// form is one sentence as its language writes it, falling back phrase by phrase. It is the raw
// format rather than a finished line, for the callers that have to wrap an error with `%w`.
func (w wording) form(p phrase) string {
	if said, has := w[p]; has && said != "" {
		return said
	}
	return wordings[fallbackLanguage][p]
}

// say words one sentence. A phrase with nothing to fill in is handed back as it is, so a sentence
// that happens to carry a percent sign is not read as a format.
func (w wording) say(p phrase, a ...any) string {
	if len(a) == 0 {
		return w.form(p)
	}
	return fmt.Sprintf(w.form(p), w.wordedToo(a)...)
}

// wordedToo words the phrases handed in as values, in this same language, and leaves everything
// else as it came.
//
// **A sentence that names a button has to name it the way its reader sees it labelled.** The same
// standing is read out on two faces — the settings screen in the user's language, and the
// execution log in English — so what a caller carries is the phrase rather than a finished name,
// and it is worded here, once per face, rather than at the place it was picked.
func (w wording) wordedToo(a []any) []any {
	worded := make([]any, len(a))
	for at, one := range a {
		if named, is := one.(phrase); is {
			worded[at] = w.form(named)
			continue
		}
		worded[at] = one
	}
	return worded
}

// say is that, in the language the settings face is being spoken in.
func say(p phrase, a ...any) string { return screen.say(p, a...) }

// refuse is a sentence handed back as the error that ends a call. The format is the language's,
// so a `%w` in it wraps whatever the caller passes — which is what keeps the wrapped error
// reachable by `errors.Is` after it has been said in another language.
func refuse(p phrase, a ...any) error { return fmt.Errorf(screen.form(p), screen.wordedToo(a)...) }

// english is the row the faces that are not the settings screen speak from — the observation
// hook, and the commands that are typed.
var english = wordings[fallbackLanguage]
