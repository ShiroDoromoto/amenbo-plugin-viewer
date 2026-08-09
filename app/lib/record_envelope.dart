/// The envelope a record travels in, and the only place the app opens one.
///
/// The PC seals one ciphertext per record, so the phone opens them one at a time — that is what
/// lets either side move a single row without touching the rest. Both routes carry the same
/// envelope, so nothing below knows whether the bytes came out of iCloud or off a Worker.
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

/// The record could not be opened, and no plaintext should be inferred from it.
///
/// This covers both a malformed envelope and one whose tag does not verify — from the reading
/// side they are the same event, "this did not come from the key we hold", and the app has one
/// thing to say about it.
class EnvelopeException implements Exception {
  const EnvelopeException(this.message);

  final String message;

  @override
  String toString() => 'EnvelopeException: $message';
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
      throw const EnvelopeException('a record arrived without a key');
    }

    final op = json['op'];
    if (op == 'del') return SealedRecord.deleted(key: key);
    if (op != 'put') {
      throw EnvelopeException(
        'record $key asks for an operation nobody knows: $op',
      );
    }

    final nonce = decodeBase64Url(json['n'], what: 'the nonce of $key');
    if (nonce.length != _nonceLength) {
      throw EnvelopeException(
        'the nonce of $key is ${nonce.length} bytes, not $_nonceLength',
      );
    }

    final ciphertext = decodeBase64Url(
      json['c'],
      what: 'the ciphertext of $key',
    );
    if (ciphertext.length < _tagLength) {
      throw EnvelopeException(
        'the ciphertext of $key is too short to carry a tag',
      );
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
  factory RecordCipher.fromBase64Key(String encodedKey) {
    final key = decodeBase64Url(encodedKey, what: 'the key');
    if (key.length != _keyLength) {
      throw EnvelopeException(
        'the key is ${key.length} bytes, not $_keyLength',
      );
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
      throw EnvelopeException(
        '${record.key} is a deletion and carries nothing to open',
      );
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
      throw EnvelopeException(
        '${record.key} did not open with the key this device holds',
      );
    }
  }

  /// Opens one record and reads it as the JSON object a table row is sent as.
  Future<Map<String, Object?>> openJson(SealedRecord record) async {
    final clear = await open(record);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(clear));
    } on FormatException catch (error) {
      throw EnvelopeException(
        '${record.key} opened but is not JSON: ${error.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw EnvelopeException(
        '${record.key} opened to a ${decoded.runtimeType}, not a row',
      );
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
/// Exposed for the pairing screen, which decodes the same fields out of a QR code before there is
/// a cipher to hand them to.
Uint8List decodeBase64Url(Object? value, {required String what}) {
  if (value is! String || value.isEmpty) {
    throw EnvelopeException('$what is missing');
  }
  try {
    return base64Url.decode(base64Url.normalize(value));
  } on FormatException {
    throw EnvelopeException('$what is not base64url');
  }
}
