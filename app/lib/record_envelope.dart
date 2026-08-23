/// The envelope a record travels in, and the only place the app opens one.
///
/// The PC seals one ciphertext per record, so the phone opens them one at a time — that is what
/// lets either side move a single row without touching the rest. The envelope is what the two
/// ends agree on, and nothing below it knows where the bytes were carried from.
///
/// The other half of this lives on the PC, in Go. Only four things have to line up, and all four
/// are here: XChaCha20-Poly1305 with a 256-bit key, a 192-bit nonce carried beside the ciphertext
/// rather than inside it, Go's `Seal` output — ciphertext with its 128-bit tag already appended —
/// as the single `c` field, and the record's key as the associated data. Everything is base64url.
/// A test in `record_envelope_test.dart` opens a fixture the Go side actually produced, so a drift
/// in any of the four fails there rather than on someone's phone.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Why a record could not be opened.
///
/// Four, because four is what the reading side can honestly tell apart. Anything finer would be a
/// guess about what happened at the other end.
enum SealProblem {
  /// The envelope is not the shape one is: a field missing, not base64url, or the wrong number of
  /// bytes.
  malformed,

  /// The tag did not verify. Altered bytes, a record sealed under another name, and a key that is
  /// not the one it was sealed with are indistinguishable here by design.
  wrongKey,

  /// It opened, and what came out is not the row a record carries.
  notARow,

  /// The key this device holds is not a key of the size records are sealed with. It is its own
  /// answer because it is the one the pairing screen has something to say about — the code in
  /// front of the camera is where it can still be fixed.
  unusableKey,
}

/// The record could not be opened, and no plaintext should be inferred from it.
///
/// It carries which of the four it is and nothing written out: what a person is shown about a
/// record that will not open is the screen's to say, in the reader's own language.
class EnvelopeException implements Exception {
  const EnvelopeException(this.problem, {this.at});

  final SealProblem problem;

  /// Which record it happened on — `"<table>/<row id>"` — or null before there is a record to
  /// name. A locator for whoever is reading a stack trace, never a sentence and never shown.
  final String? at;

  @override
  String toString() =>
      'EnvelopeException(${problem.name})${at == null ? '' : ' on $at'}';
}

/// One record as it arrives, still sealed.
///
/// A deletion carries no ciphertext: the key is the whole message, so [nonce] and [ciphertext]
/// are null and there is nothing to open.
class SealedRecord {
  const SealedRecord.put({
    required this.key,
    required Uint8List this.nonce,
    required Uint8List this.ciphertext,
  }) : deleted = false;

  const SealedRecord.deleted({required this.key})
    : deleted = true,
      nonce = null,
      ciphertext = null;

  /// The record's name — `"<table>/<row id>"`, held as an opaque string.
  final String key;

  /// The row is gone. Nothing was sent for it beyond [key].
  final bool deleted;

  /// 24 bytes, fresh for every record. Null when [deleted].
  final Uint8List? nonce;

  /// The ciphertext with its authentication tag appended. Null when [deleted].
  final Uint8List? ciphertext;

  /// Reads one entry of the `records` array.
  ///
  /// Throws [EnvelopeException] rather than returning a half-read record: a record whose fields
  /// do not fit cannot be skipped quietly, because doing so would show the reader a backlog with
  /// a hole in it and no sign that anything was missing.
  factory SealedRecord.fromJson(Map<String, Object?> json) {
    final key = json['k'];
    if (key is! String || key.isEmpty) {
      throw const EnvelopeException(SealProblem.malformed);
    }

    final op = json['op'];
    if (op == 'del') return SealedRecord.deleted(key: key);
    if (op != 'put') {
      throw EnvelopeException(SealProblem.malformed, at: key);
    }

    final nonce = decodeBase64Url(json['n'], at: key);
    if (nonce.length != _nonceLength) {
      throw EnvelopeException(SealProblem.malformed, at: key);
    }

    final ciphertext = decodeBase64Url(json['c'], at: key);
    if (ciphertext.length < _tagLength) {
      throw EnvelopeException(SealProblem.malformed, at: key);
    }

    return SealedRecord.put(key: key, nonce: nonce, ciphertext: ciphertext);
  }
}

/// Opens sealed records with the key this device was paired with.
///
/// One instance holds one key. Building it is where a key of the wrong size is caught, so the
/// pairing screen learns about it while the person is still standing in front of the QR code
/// rather than at the first record that fails to open.
class RecordCipher {
  RecordCipher._(this._secretKey);

  /// Restores the key from the form it is issued and stored in.
  ///
  /// Everything that can be wrong with it comes back as the one answer: a key that is not
  /// base64url and a key of the wrong length are the same thing to whoever is holding the code.
  factory RecordCipher.fromBase64Key(String encodedKey) {
    final Uint8List key;
    try {
      key = decodeBase64Url(encodedKey);
    } on EnvelopeException {
      throw const EnvelopeException(SealProblem.unusableKey);
    }
    if (key.length != _keyLength) {
      throw const EnvelopeException(SealProblem.unusableKey);
    }
    return RecordCipher._(SecretKey(key));
  }

  static final _algorithm = Xchacha20.poly1305Aead();

  final SecretKey _secretKey;

  /// Opens one record and hands back its bytes.
  ///
  /// The record's key goes into the tag as associated data, which is what stops a record from
  /// being opened under a name other than the one it was sealed with. Whoever can write to the
  /// store can move a ciphertext to another row without being able to read it, and that alone
  /// would be enough to show one task's contents under a different task's name.
  ///
  /// A deletion has nothing to open — ask [SealedRecord.deleted] before calling this.
  Future<Uint8List> open(SealedRecord record) async {
    final nonce = record.nonce;
    final sealed = record.ciphertext;
    if (nonce == null || sealed == null) {
      throw EnvelopeException(SealProblem.malformed, at: record.key);
    }

    final split = sealed.length - _tagLength;
    final box = SecretBox(
      sealed.sublist(0, split),
      nonce: nonce,
      mac: Mac(sealed.sublist(split)),
    );

    try {
      final clear = await _algorithm.decrypt(
        box,
        secretKey: _secretKey,
        aad: utf8.encode(record.key),
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      // The bytes were altered, or they were sealed under another name, or this is not the key
      // they were sealed with. All three are indistinguishable here by design, and saying which
      // one it was would be a guess.
      throw EnvelopeException(SealProblem.wrongKey, at: record.key);
    }
  }

  /// Opens one record and reads it as the JSON object a table row is sent as.
  Future<Map<String, Object?>> openJson(SealedRecord record) async {
    final clear = await open(record);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(clear));
    } on FormatException {
      throw EnvelopeException(SealProblem.notARow, at: record.key);
    }
    if (decoded is! Map<String, Object?>) {
      throw EnvelopeException(SealProblem.notARow, at: record.key);
    }
    return decoded;
  }
}

const _keyLength = 32;
const _nonceLength = 24;
const _tagLength = 16;

/// Decodes base64url, padded or not.
///
/// The padding is what differs between the two sides' standard libraries — Go's `RawURLEncoding`
/// leaves it off, Dart's decoder wants it — and neither is worth making the other's problem.
///
/// [at] is the record it was read out of, carried into the refusal for whoever reads one. Null
/// where what is being decoded is the key itself, which belongs to no record.
/// Names the key this device holds, the way the PC names the one it sealed with.
///
/// The SHA-256 of the key's **bytes**, as 64 lower-case hex characters — never of how the key is
/// written. Padding is optional wherever a key is copied, so one key has two correct spellings,
/// and hashing the text would make them two keys to whoever is comparing.
///
/// This is what `GET /meta`'s `key_fingerprint` is held up against. The hash is what may be said
/// out loud: it is served to anyone holding a read token, and the key never is.
///
/// Throws [EnvelopeException] if this device's key is not a 256-bit key — the same answer
/// building a cipher out of it gives.
Future<String> keyFingerprint(String encodedKey) async {
  final Uint8List key;
  try {
    key = decodeBase64Url(encodedKey);
  } on EnvelopeException {
    throw const EnvelopeException(SealProblem.unusableKey);
  }
  if (key.length != _keyLength) {
    throw const EnvelopeException(SealProblem.unusableKey);
  }
  final named = await Sha256().hash(key);
  return [
    for (final byte in named.bytes) byte.toRadixString(16).padLeft(2, '0'),
  ].join();
}

Uint8List decodeBase64Url(Object? value, {String? at}) {
  if (value is! String || value.isEmpty) {
    throw EnvelopeException(SealProblem.malformed, at: at);
  }
  try {
    return base64Url.decode(base64Url.normalize(value));
  } on FormatException {
    throw EnvelopeException(SealProblem.malformed, at: at);
  }
}
