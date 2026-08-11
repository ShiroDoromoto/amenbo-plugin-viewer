package main

import (
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"

	"golang.org/x/crypto/chacha20poly1305"
)

// Records are encrypted here and opened on the phone, and nothing in between holds the key —
// which is what makes a place the user merely rents safe to leave the backlog in.
//
// The cipher is XChaCha20-Poly1305 with a 256-bit key, and **one record is one ciphertext**.
// Per record rather than one blob for the lot: the store updates a row at a time and the phone
// decrypts only the rows that moved, neither of which a single ciphertext allows.
//
// XChaCha20 rather than AES-GCM, for the nonce. Sealing happens once per record, so the count
// climbs without bound, and AES-GCM's 96-bit nonce is narrow enough that a random one eventually
// repeats — which breaks the cipher outright. XChaCha20's is 192 bits: draw it at random every
// time and a repeat is not something to keep a counter against.
//
// The envelope is what this file settles, because the phone has to open what it seals:
//
//   - **the nonce and the ciphertext travel side by side**, as two values, never concatenated
//     into one. The record that carries them already names them apart, so a blob would only be
//     something to split again at the far end.
//   - **both are base64url, unpadded.** The records are JSON and the pairing QR writes the key
//     the same way, so one alphabet covers everything that leaves here.
//   - **the ciphertext ends with its 16-byte Poly1305 tag**, exactly as the cipher emits it.
//     Nothing is stripped, added or reordered, so any implementation of XChaCha20-Poly1305 opens
//     it without being told about this file.
//   - **the key the record is filed under goes into the tag**, as additional data — its own
//     bytes, as it is written. It stays in the clear beside the ciphertext, but a record moved
//     to another key no longer opens. Leave it out and whoever can write to the store can serve
//     one task's contents under another task's key: still unable to read either, and still able
//     to make the phone show the wrong thing.

// keySize is the key the cipher takes and `setup` generates: 256 bits.
const keySize = chacha20poly1305.KeySize

// errNoKey is what a sealer asked for before `setup` has run answers with. It is a sentinel so a
// caller can tell "not configured yet" — a state to explain to the user — from a key that is
// configured and wrong.
var errNoKey = errors.New("no encryption key is configured — run setup")

// sealer holds the configured key in the form the cipher wants, so a run that seals hundreds of
// records decodes and schedules the key once.
type sealer struct {
	aead cipher.AEAD
}

// newSealer turns the key as it is configured — 32 bytes written as base64url — into something
// that can seal records. Padding is optional on the way in: the key is copied between a QR, a
// settings store and an environment variable, and refusing one of the two spellings would fail a
// key that is correct.
//
// **No error here quotes the key, or any part of it.** These errors land in Amenbo's execution
// log, and a log that echoes the key hands over the one secret this design has.
func newSealer(encodedKey string) (*sealer, error) {
	encodedKey = strings.TrimSpace(encodedKey)
	if encodedKey == "" {
		return nil, errNoKey
	}
	key, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(encodedKey, "="))
	if err != nil {
		return nil, errors.New("the encryption key is not base64url")
	}
	if len(key) != keySize {
		return nil, fmt.Errorf("the encryption key is %d bytes and the cipher takes %d", len(key), keySize)
	}
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, fmt.Errorf("the encryption key was refused by the cipher: %w", err)
	}
	return &sealer{aead: aead}, nil
}

// seal encrypts one record and hands back the two halves of its envelope, ready to be written as
// they are. `filedUnder` is the key the record travels under, and it is bound into the tag rather
// than encrypted — it has to stay readable for the store to update a row, and binding it is what
// stops the row being moved.
//
// The nonce is drawn fresh on every call and never derived from the record: two records sealed
// under one nonce and one key would give away both plaintexts to anyone holding the pair.
func (s *sealer) seal(filedUnder string, record []byte) (nonce, ciphertext string) {
	// crypto/rand does not report failure — it panics rather than hand back a buffer it could
	// not fill, which is the right end for a value whose whole job is to never repeat.
	raw := make([]byte, s.aead.NonceSize())
	rand.Read(raw)
	sealed := s.aead.Seal(nil, raw, record, []byte(filedUnder))
	return base64.RawURLEncoding.EncodeToString(raw), base64.RawURLEncoding.EncodeToString(sealed)
}
