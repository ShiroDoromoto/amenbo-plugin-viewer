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
    'Ps5jeZVnlpRQXQGrBVnXrF6IpQ5JhHU6n_loZUhAfKQ4HBHH7_efTQIDxPt4ti8M2EhME1XD_DfPnKVUD9xDavc';

const goPlaintext = '{"id":2812,"title":"タスクを電話で読む"}';

Map<String, Object?> sealedJson({
  String key = goRecordKey,
  String nonce = goNonce,
  String ciphertext = goCiphertext,
}) => {'k': key, 'op': 'put', 'n': nonce, 'c': ciphertext};

void main() {
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
      expect(row['title'], 'タスクを電話で読む');
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
      expect(
        decodeBase64Url('AAEC', what: 'x'),
        decodeBase64Url('AAEC', what: 'x'),
      );
      expect(
        decodeBase64Url('AAECAw', what: 'x'),
        decodeBase64Url('AAECAw==', what: 'x'),
      );
    });

    test('does not make a malformed field readable', () {
      expect(
        () => decodeBase64Url('not base64!', what: 'the key'),
        throwsA(isA<EnvelopeException>()),
      );
      expect(
        () => decodeBase64Url(null, what: 'the key'),
        throwsA(isA<EnvelopeException>()),
      );
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
