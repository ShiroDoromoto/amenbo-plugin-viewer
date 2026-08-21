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
// Here: what `check` answers, and what the four buttons — `app`, `token`, `setup`, `qr` — write
// for a person to read. Those five are the settings face: the screen draws the
// check's line at the head of the form and the first line an operation wrote underneath it, and
// for a user with no terminal they are the only way any of this is reached.
//
// Not here, and English on purpose:
//
//   - The observation face. Nobody is waiting on it; its lines are the execution log's material
//     read by whoever is working out why a phone is behind.
//   - `push`, `phones`, `revoke` and the usage. They are typed, and what is typed is English:
//     Amenbo splits its languages by who is reading, and a face reached by typing is not one a
//     settings screen ever draws.
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
	phICloudFolder      phrase = "icloud_folder"
	phCloudflareWorker  phrase = "cloudflare_worker"
	phOpenTheAppOnce    phrase = "open_the_app_once"
	phStandTheWorkerUp  phrase = "stand_the_worker_up"
	phStandingWithNoKey phrase = "standing_with_no_key"
	phStandingBadKey    phrase = "standing_bad_key"
	phCarryingTo        phrase = "carrying_to"
	phCarryingNowhere   phrase = "carrying_nowhere"
	phNothingIsTicked   phrase = "nothing_is_ticked"
	phWaitingOn         phrase = "waiting_on"
	phNoSuchPlaceHere   phrase = "no_such_place_here"
	phNowhere           phrase = "nowhere"
	phAnd               phrase = "and"
	phComma             phrase = "comma"

	// `app` — putting the App Store page in front of a camera.
	phNothingToDrawOn phrase = "nothing_to_draw_on"
	phCodeNotDrawn    phrase = "code_not_drawn"
	phPointTheCamera  phrase = "point_the_camera"

	// Showing a code, which `app` and `qr` both do.
	phImageNotOpened  phrase = "image_not_opened"
	phCodeLeftWithKey phrase = "code_left_with_key"
	phCodeLeftBehind  phrase = "code_left_behind"
	phCodeIsOnScreen  phrase = "code_is_on_screen"

	// `token` — opening Cloudflare's token page.
	phNoScreenForTheTokenPage phrase = "no_screen_for_the_token_page"
	phTokenPageNotOpened      phrase = "token_page_not_opened"
	phTokenPageIsOpen         phrase = "token_page_is_open"

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

	// `qr` — pairing one phone.
	phPhoneMayReadFromNowOn phrase = "phone_may_read_from_now_on"
	phPhoneAlreadyPaired    phrase = "phone_already_paired"
	phNoEncryptionKey       phrase = "no_encryption_key"
	phNoCloudflareRouteYet  phrase = "no_cloudflare_route_yet"
	phThePhoneWasNotNamed   phrase = "the_phone_was_not_named"
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
	return fmt.Sprintf(w.form(p), a...)
}

// say is that, in the language the settings face is being spoken in.
func say(p phrase, a ...any) string { return screen.say(p, a...) }

// refuse is a sentence handed back as the error that ends a call. The format is the language's,
// so a `%w` in it wraps whatever the caller passes — which is what keeps the wrapped error
// reachable by `errors.Is` after it has been said in another language.
func refuse(p phrase, a ...any) error { return fmt.Errorf(screen.form(p), a...) }

// english is the row the faces that are not the settings screen speak from — the observation
// hook, and the commands that are typed.
var english = wordings[fallbackLanguage]
