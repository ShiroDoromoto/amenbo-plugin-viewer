package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
	"testing"

	"golang.org/x/crypto/chacha20poly1305"
)

// A key of the right length, written the way it is configured. The bytes are made up rather than
// random so a failure reads the same twice.
func testKey(t *testing.T) string {
	t.Helper()
	raw := make([]byte, keySize)
	for i := range raw {
		raw[i] = byte(i)
	}
	return base64.RawURLEncoding.EncodeToString(raw)
}

// unseal opens an envelope the way the phone has to: with the cipher, the key the record is
// filed under, and the two base64url values. It deliberately does not call back into this
// package — what is being checked is that the envelope is openable by an implementation that has
// only been told which cipher it is, which is the whole of what the app on the other end will
// have.
func unseal(t *testing.T, encodedKey, filedUnder, nonce, ciphertext string) []byte {
	t.Helper()
	key, err := base64.RawURLEncoding.DecodeString(encodedKey)
	if err != nil {
		t.Fatalf("key: %v", err)
	}
	raw, err := base64.RawURLEncoding.DecodeString(nonce)
	if err != nil {
		t.Fatalf("nonce: %v", err)
	}
	sealed, err := base64.RawURLEncoding.DecodeString(ciphertext)
	if err != nil {
		t.Fatalf("ciphertext: %v", err)
	}
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		t.Fatalf("cipher: %v", err)
	}
	record, err := aead.Open(nil, raw, sealed, []byte(filedUnder))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	return record
}

func TestASealedRecordOpensAgainOnTheOtherSide(t *testing.T) {
	key := testKey(t)
	sealer, err := newSealer(key)
	if err != nil {
		t.Fatal(err)
	}
	record := []byte(`{"id":2812,"title":"レコード単位の暗号"}`)

	nonce, ciphertext := sealer.seal("task/2812", record)

	if got := unseal(t, key, "task/2812", nonce, ciphertext); !bytes.Equal(got, record) {
		t.Errorf("opened %q, sealed %q", got, record)
	}
}

// The envelope's shape is the part the phone is written against, so it is asserted rather than
// left to the round trip: a 192-bit nonce of its own, and a ciphertext that is the record's
// length plus the 16-byte tag the cipher appends.
func TestTheEnvelopeIsANonceAndTheCiphertextWithItsTag(t *testing.T) {
	sealer, err := newSealer(testKey(t))
	if err != nil {
		t.Fatal(err)
	}
	record := []byte("a record")

	nonce, ciphertext := sealer.seal("task/1", record)

	raw, err := base64.RawURLEncoding.DecodeString(nonce)
	if err != nil {
		t.Fatalf("the nonce is not unpadded base64url: %v", err)
	}
	if len(raw) != chacha20poly1305.NonceSizeX {
		t.Errorf("nonce is %d bytes, XChaCha20 takes %d", len(raw), chacha20poly1305.NonceSizeX)
	}
	sealed, err := base64.RawURLEncoding.DecodeString(ciphertext)
	if err != nil {
		t.Fatalf("the ciphertext is not unpadded base64url: %v", err)
	}
	// The record's length plus the tag, and nothing more — which is also what says the nonce
	// travels beside the ciphertext rather than glued to the front of it.
	if want := len(record) + chacha20poly1305.Overhead; len(sealed) != want {
		t.Errorf("ciphertext is %d bytes, want %d — the tag is not where the far end looks for it", len(sealed), want)
	}
}

// Every record gets its own nonce. A repeat under one key gives away both plaintexts, so this is
// the property the choice of cipher was made for.
func TestEveryRecordIsSealedUnderItsOwnNonce(t *testing.T) {
	sealer, err := newSealer(testKey(t))
	if err != nil {
		t.Fatal(err)
	}
	record := []byte("the same record twice")

	firstNonce, firstCiphertext := sealer.seal("task/1", record)
	secondNonce, secondCiphertext := sealer.seal("task/1", record)

	if firstNonce == secondNonce {
		t.Error("two records were sealed under one nonce")
	}
	if firstCiphertext == secondCiphertext {
		t.Error("one record sealed twice came out identical — the nonce is not reaching the cipher")
	}
}

// A record that was altered on the way does not open. The tag is what says so, and it is the
// reason a place the user does not control is safe to write into.
func TestATamperedRecordDoesNotOpen(t *testing.T) {
	key := testKey(t)
	sealer, err := newSealer(key)
	if err != nil {
		t.Fatal(err)
	}

	nonce, ciphertext := sealer.seal("task/1", []byte("a record"))

	sealed, err := base64.RawURLEncoding.DecodeString(ciphertext)
	if err != nil {
		t.Fatal(err)
	}
	sealed[0] ^= 0xff
	raw, err := base64.RawURLEncoding.DecodeString(nonce)
	if err != nil {
		t.Fatal(err)
	}
	aead, err := chacha20poly1305.NewX(mustDecodeKey(t, key))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := aead.Open(nil, raw, sealed, []byte("task/1")); err == nil {
		t.Error("an altered record opened")
	}
}

// A record moved to another key does not open, though nothing about it was altered. The key is
// in the clear beside the ciphertext so the store can update a row by it — binding it into the
// tag is what stops whoever can write to that store from serving one task's contents under
// another task's key.
func TestARecordMovedToAnotherKeyDoesNotOpen(t *testing.T) {
	key := testKey(t)
	sealer, err := newSealer(key)
	if err != nil {
		t.Fatal(err)
	}
	record := []byte(`{"id":2812,"title":"レコード単位の暗号"}`)

	nonce, ciphertext := sealer.seal("task/2812", record)

	aead, err := chacha20poly1305.NewX(mustDecodeKey(t, key))
	if err != nil {
		t.Fatal(err)
	}
	raw, sealed := mustDecode(t, nonce), mustDecode(t, ciphertext)
	if _, err := aead.Open(nil, raw, sealed, []byte("task/2799")); err == nil {
		t.Error("a record filed under one key opened under another")
	}
	if _, err := aead.Open(nil, raw, sealed, nil); err == nil {
		t.Error("a record opened with the key left out — nothing is bound into the tag")
	}
	if opened, err := aead.Open(nil, raw, sealed, []byte("task/2812")); err != nil || !bytes.Equal(opened, record) {
		t.Errorf("the record does not open under its own key: %v", err)
	}
}

func mustDecode(t *testing.T, text string) []byte {
	t.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(text)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func mustDecodeKey(t *testing.T, encodedKey string) []byte {
	t.Helper()
	key, err := base64.RawURLEncoding.DecodeString(encodedKey)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

// The key is copied between a QR, a settings store and an environment variable, and base64url is
// written both with and without its padding. Both spellings are the same key.
func TestTheKeyIsTakenPaddedOrNot(t *testing.T) {
	unpadded := testKey(t)
	padded := base64.URLEncoding.EncodeToString(mustDecodeKey(t, unpadded))
	if padded == unpadded {
		t.Fatal("the fixture key needs a length that base64 pads, or this asserts nothing")
	}

	for name, spelling := range map[string]string{"unpadded": unpadded, "padded": padded, "with whitespace": "  " + unpadded + "\n"} {
		t.Run(name, func(t *testing.T) {
			sealer, err := newSealer(spelling)
			if err != nil {
				t.Fatal(err)
			}
			record := []byte("a record")
			nonce, ciphertext := sealer.seal("task/1", record)
			if got := unseal(t, unpadded, "task/1", nonce, ciphertext); !bytes.Equal(got, record) {
				t.Errorf("opened %q, sealed %q", got, record)
			}
		})
	}
}

// The fingerprint names a key so the store can say which one its records were sealed with — so
// it has to be the same on this machine and on a phone that was handed the key by QR. It is taken
// over the bytes, and the spellings of one key are the same key.
func TestTheFingerprintIsOfTheKeyAndNotOfHowItIsWritten(t *testing.T) {
	unpadded := testKey(t)
	padded := base64.URLEncoding.EncodeToString(mustDecodeKey(t, unpadded))

	named := map[string]string{}
	for name, spelling := range map[string]string{"unpadded": unpadded, "padded": padded, "with whitespace": "  " + unpadded + "\n"} {
		sealer, err := newSealer(spelling)
		if err != nil {
			t.Fatal(err)
		}
		named[name] = sealer.fingerprint
	}

	for name, fingerprint := range named {
		if fingerprint != named["unpadded"] {
			t.Errorf("%s named the key %q, and the same key is one name", name, fingerprint)
		}
	}
	// A phone holding the key computes this from the bytes it decoded, with nothing to read out
	// of this build — so what it is is asserted here rather than taken from the code under test.
	want := sha256.Sum256(mustDecodeKey(t, unpadded))
	if named["unpadded"] != hex.EncodeToString(want[:]) {
		t.Errorf("the key is named %q, want its SHA-256 as lower-case hex", named["unpadded"])
	}
}

// It is what may be said out loud: the store's answer is served to anyone holding a read token,
// so a name that carried any of the key would hand the backlog over with it.
func TestTheFingerprintIsNotTheKey(t *testing.T) {
	key := testKey(t)
	sealer, err := newSealer(key)
	if err != nil {
		t.Fatal(err)
	}

	if len(sealer.fingerprint) != sha256.Size*2 {
		t.Errorf("the name is %d characters, want a SHA-256 as %d", len(sealer.fingerprint), sha256.Size*2)
	}
	if strings.ContainsAny(sealer.fingerprint, "ABCDEFGHIJKLMNOPQRSTUVWXYZ") {
		t.Errorf("the name is not in lower case: %q", sealer.fingerprint)
	}
	if strings.Contains(sealer.fingerprint, key) || strings.Contains(sealer.fingerprint, hex.EncodeToString(mustDecodeKey(t, key))) {
		t.Error("the name carries the key it names")
	}
	// Two keys that differ by one byte are two different names, which is the whole of what the
	// phone's comparison rests on.
	other := make([]byte, keySize)
	copy(other, mustDecodeKey(t, key))
	other[0]++
	another, err := newSealer(base64.RawURLEncoding.EncodeToString(other))
	if err != nil {
		t.Fatal(err)
	}
	if another.fingerprint == sealer.fingerprint {
		t.Error("two different keys are named the same, so a phone comparing them learns nothing")
	}
}

// A key that is not one is refused rather than stretched or truncated into shape, and the refusal
// never quotes the key — these errors land in Amenbo's execution log.
func TestAKeyThatIsNotAKeyIsRefused(t *testing.T) {
	short := base64.RawURLEncoding.EncodeToString(make([]byte, keySize-1))
	for name, spelling := range map[string]string{
		"empty":            "",
		"blank":            "   ",
		"not base64url":    "not a key!!",
		"standard base64":  "+/" + strings.Repeat("A", 42),
		"too few bytes":    short,
		"a passphrase":     "correct-horse-battery-staple",
		"the word secret":  "secret",
		"32 bytes of text": strings.Repeat("k", keySize),
	} {
		t.Run(name, func(t *testing.T) {
			sealer, err := newSealer(spelling)

			if err == nil {
				t.Fatalf("%q was accepted as a key", spelling)
			}
			if sealer != nil {
				t.Error("a refused key handed back a sealer")
			}
			if trimmed := strings.TrimSpace(spelling); trimmed != "" && strings.Contains(err.Error(), trimmed) {
				t.Errorf("the refusal quotes the key: %v", err)
			}
		})
	}
}

// Nothing configured yet is its own answer, not a malformed key: the user has not run setup, and
// that is a sentence to say to them rather than a fault to report.
func TestAnAbsentKeyIsRecognisable(t *testing.T) {
	for _, spelling := range []string{"", "  \n"} {
		if _, err := newSealer(spelling); !errors.Is(err, errNoKey) {
			t.Errorf("%q: %v does not carry the sentinel", spelling, err)
		}
	}
}
