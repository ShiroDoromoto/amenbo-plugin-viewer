// The fixture below was produced by the PC side's own library — Go's
// golang.org/x/crypto/chacha20poly1305, sealed with the key, nonce and record key spelled out
// here — and not by this package encrypting something and reading it back. A round trip through
// one implementation proves it agrees with itself, which is exactly the thing that was never in
// doubt. What has to hold is that the two halves agree, so the test holds bytes the other half
// wrote: if either side moves the nonce, drops the tag off `c`, stops sealing the key in as
// associated data, or changes the alphabet, this is where it stops.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:amenbo_viewer/record_envelope.dart';

/// 32 bytes, 0x00..0x1f.
const goKey = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';

/// 24 bytes, 0xa0..0xb7.
const goNonce = 'oKGio6SlpqeoqaqrrK2ur7CxsrO0tba3';

/// The name this record was sealed under, and the associated data of the tag.
const goRecordKey = 'task/2812';

/// Go's `Seal` output: the ciphertext with its 16-byte tag already on the end.
const goCiphertext =
    'Ps5jeZVnlpRQXQGrBVnXrF6IpQ5JhHU6n_loZUhAfKQyBRPMxdifTxkI7d54tzrNJ4_FemmLUQASHawJq6FQ_j2g4XFN2WvWGVaSToaUs80';

const goPlaintext = '{"id":2812,"title":"タスクをスマートフォンで読む"}';

/// What the PC calls that key — `fingerprintOf` in the plugin's `crypto.go`, over the same 32
/// bytes. Written down here rather than computed, for the same reason the ciphertext is: what has
/// to hold is that the two halves name one key the same thing.
const goKeyNamed =
    '630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd';

/// 32 more bytes, 0x20..0x3f — another key entirely.
const anotherKey = 'ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8';

Map<String, Object?> sealedJson({
  String key = goRecordKey,
  String nonce = goNonce,
  String ciphertext = goCiphertext,
}) => {'k': key, 'op': 'put', 'n': nonce, 'c': ciphertext};

void main() {
  group('naming the key', () {
    test('calls it what the PC calls it', () async {
      expect(await keyFingerprint(goKey), goKeyNamed);
    });

    test('one key spelled two ways is one name', () async {
      // Padding is optional wherever a key is copied. Naming the text rather than the bytes would
      // make these two keys to whoever is comparing, and the comparison is the whole point.
      expect(await keyFingerprint('$goKey='), goKeyNamed);
    });

    test('another key is another name', () async {
      expect(await keyFingerprint(anotherKey), isNot(goKeyNamed));
    });

    test('a key this build cannot use has no name', () {
      expect(
        keyFingerprint('AAEC'),
        throwsA(
          isA<EnvelopeException>().having(
            (it) => it.problem,
            'problem',
            SealProblem.unusableKey,
          ),
        ),
      );
    });
  });

  group('a record the PC sealed', () {
    test('opens with the key the PC used', () async {
      final cipher = RecordCipher.fromBase64Key(goKey);
      final record = SealedRecord.fromJson(sealedJson());

      expect(utf8.decode(await cipher.open(record)), goPlaintext);
    });

    test('opens as the row it is', () async {
      final cipher = RecordCipher.fromBase64Key(goKey);
      final row = await cipher.openJson(SealedRecord.fromJson(sealedJson()));

      expect(row['id'], 2812);
      expect(row['title'], 'タスクをスマートフォンで読む');
    });

    test('does not open with another key', () async {
      final cipher = RecordCipher.fromBase64Key(
        base64Url.encode(List.filled(32, 7)),
      );

      await expectLater(
        cipher.open(SealedRecord.fromJson(sealedJson())),
        throwsA(isA<EnvelopeException>()),
      );
    });

    test('does not open under another name', () async {
      // Whoever can write to the store can move a ciphertext to another row without being able
      // to read it. Sealing the name in is what keeps that from showing one task's contents
      // under a different task's heading.
      final cipher = RecordCipher.fromBase64Key(goKey);

      await expectLater(
        cipher.open(SealedRecord.fromJson(sealedJson(key: 'task/9999'))),
        throwsA(isA<EnvelopeException>()),
      );
    });

    test('does not open once a byte of it has been changed', () async {
      // The tag is the whole point of choosing an AEAD: a record that arrives altered has to
      // refuse to open, not open to something plausible.
      final bytes = base64Url.decode(base64Url.normalize(goCiphertext));
      bytes[3] ^= 0x01;
      final cipher = RecordCipher.fromBase64Key(goKey);

      await expectLater(
        cipher.open(
          SealedRecord.fromJson(
            sealedJson(ciphertext: base64Url.encode(bytes)),
          ),
        ),
        throwsA(isA<EnvelopeException>()),
      );
    });
  });

  group('the padding either side happens to write', () {
    test('is optional', () {
      // Go's RawURLEncoding writes none and Dart's encoder writes it; both have to be readable,
      // or the envelope would carry a detail neither side chose on purpose.
      expect(decodeBase64Url('AAEC'), decodeBase64Url('AAEC'));
      expect(decodeBase64Url('AAECAw'), decodeBase64Url('AAECAw=='));
    });

    test('does not make a malformed field readable', () {
      expect(
        () => decodeBase64Url('not base64!'),
        throwsA(isA<EnvelopeException>()),
      );
      expect(() => decodeBase64Url(null), throwsA(isA<EnvelopeException>()));
    });
  });

  group('an envelope that does not fit', () {
    test('is refused rather than skipped', () {
      // Skipping it quietly would show a backlog with a hole in it and no sign of the hole.
      expect(
        () => SealedRecord.fromJson(
          sealedJson(nonce: base64Url.encode(List.filled(12, 0))),
        ),
        throwsA(isA<EnvelopeException>()),
      );
      expect(
        () => SealedRecord.fromJson(
          sealedJson(ciphertext: base64Url.encode([1, 2, 3])),
        ),
        throwsA(isA<EnvelopeException>()),
      );
      expect(
        () => SealedRecord.fromJson({
          'op': 'put',
          'n': goNonce,
          'c': goCiphertext,
        }),
        throwsA(isA<EnvelopeException>()),
      );
      expect(
        () => SealedRecord.fromJson({'k': 'task/1', 'op': 'merge'}),
        throwsA(isA<EnvelopeException>()),
      );
    });

    test('includes a key of the wrong size', () {
      expect(
        () => RecordCipher.fromBase64Key(base64Url.encode(List.filled(16, 0))),
        throwsA(isA<EnvelopeException>()),
      );
    });
  });

  group('a deletion', () {
    test('is the key alone', () {
      final record = SealedRecord.fromJson({'k': 'task/2799', 'op': 'del'});

      expect(record.deleted, isTrue);
      expect(record.ciphertext, isNull);
    });

    test('has nothing to open', () async {
      final cipher = RecordCipher.fromBase64Key(goKey);

      await expectLater(
        cipher.open(SealedRecord.fromJson({'k': 'task/2799', 'op': 'del'})),
        throwsA(isA<EnvelopeException>()),
      );
    });
  });
}
