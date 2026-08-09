// The PC writes this line of JSON and this reads it, so these cases are the app's half of the
// only contract pairing has. The payloads are written out by hand rather than built from the
// reader's own constants: a field the two sides stopped agreeing on has to fail here, and it
// cannot fail against a fixture that follows whatever this file currently thinks.

import 'package:flutter_test/flutter_test.dart';

import 'package:amenbo_viewer/pairing_code.dart';

void main() {
  // 32 bytes, base64url without padding — the size the records are sealed with.
  const key = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';

  test('a code from the PC becomes a pairing, name and all', () {
    final pairing = readPairingCode(
      '{"v":1,"url":"https://viewer.example.workers.dev",'
      '"t":"cmVhZC10b2tlbg","k":"$key","l":"iPhone"}',
    );

    expect(pairing.url, Uri.parse('https://viewer.example.workers.dev'));
    expect(pairing.readToken, 'cmVhZC10b2tlbg');
    expect(pairing.encryptionKey, key);
    // The key came back usable, not merely present.
    expect(pairing.cipher(), isNotNull);
    // And the name the PC would cut this phone off by.
    expect(pairing.label, 'iPhone');
  });

  test('a code with no name on it still pairs', () {
    // The name arrived on the code after the three secrets did. Refusing the older code would be
    // refusing a pairing that works, over a line the phone only displays.
    final pairing = readPairingCode(
      '{"v":1,"url":"https://viewer.example.workers.dev","t":"tok","k":"$key"}',
    );

    expect(pairing.readToken, 'tok');
    expect(pairing.label, isNull);
  });

  test('a field this build does not know is ignored', () {
    // Room to add to the code without every phone already out there refusing it.
    final pairing = readPairingCode(
      '{"v":1,"url":"https://viewer.example.workers.dev","t":"tok","k":"$key",'
      '"issued_at":"2026-08-09T09:00:00Z"}',
    );

    expect(pairing.readToken, 'tok');
  });

  group('a code that is not ours', () {
    test('plain text says so', () {
      expect(
        () => readPairingCode('https://example.com/promo'),
        throwsA(problem(CodeProblem.notAPairingCode)),
      );
    });

    test('JSON from something else says so', () {
      expect(
        () => readPairingCode('{"ssid":"home","pass":"a-wifi-password"}'),
        throwsA(problem(CodeProblem.notAPairingCode)),
      );
    });

    test('a version that is not a number says so', () {
      expect(
        () =>
            readPairingCode('{"v":"1","url":"https://a.b","t":"t","k":"$key"}'),
        throwsA(problem(CodeProblem.notAPairingCode)),
      );
    });
  });

  group('a code from another version', () {
    // The version is settled before the rest is looked at. A later contract may have moved the
    // other fields, so "the URL is missing" would be a wrong answer to a right question.
    test('a newer one asks for the app to be updated', () {
      final thrown = catchIt(() => readPairingCode('{"v":2,"nothing":"else"}'));

      expect(thrown.problem, CodeProblem.tooNew);
      expect(thrown.message, contains('Update the app'));
    });

    test('an older one asks for amenbo to be updated', () {
      final thrown = catchIt(
        () => readPairingCode(
          '{"v":0,"url":"https://viewer.example.workers.dev","t":"t","k":"$key"}',
        ),
      );

      expect(thrown.problem, CodeProblem.tooOld);
      expect(thrown.message, contains('Update amenbo on the PC'));
    });
  });

  group('a code of ours that will not do', () {
    test('one with a field missing', () {
      expect(
        () => readPairingCode('{"v":1,"url":"https://a.b","t":"tok"}'),
        throwsA(problem(CodeProblem.unusable)),
      );
    });

    test('one with an empty token', () {
      expect(
        () => readPairingCode('{"v":1,"url":"https://a.b","t":"","k":"$key"}'),
        throwsA(problem(CodeProblem.unusable)),
      );
    });

    test('one that would send the token in the clear', () {
      // The token on the code is what gets this phone in. Handed over unencrypted it is not this
      // phone's any more, and the camera is the last place that is still worth stopping at.
      final thrown = catchIt(
        () => readPairingCode(
          '{"v":1,"url":"http://viewer.example.workers.dev","t":"t","k":"$key"}',
        ),
      );

      expect(thrown.problem, CodeProblem.unusable);
      expect(thrown.message, contains('https'));
    });

    test('one carrying a key of the wrong size', () {
      // Caught while the phone is still pointed at the screen, rather than at the first sync
      // where nothing about it can be done any more.
      final thrown = catchIt(
        () => readPairingCode(
          '{"v":1,"url":"https://a.b","t":"t","k":"c2hvcnQ"}',
        ),
      );

      expect(thrown.problem, CodeProblem.unusable);
      expect(thrown.message, contains('key'));
    });
  });

  test('every refusal says what to do next', () {
    // "Could not read that" is the failure this screen cannot afford: the code is plainly in
    // frame, and there is nothing left to try.
    for (final code in [
      'not json at all',
      '{"ssid":"home"}',
      '{"v":9}',
      '{"v":1,"url":"http://a.b","t":"t","k":"$key"}',
    ]) {
      final said = catchIt(() => readPairingCode(code)).message;
      expect(said, isNot(isEmpty));
      expect(said, matches(RegExp(r'\.$')));
    }
  });
}

Matcher problem(CodeProblem expected) =>
    isA<PairingCodeException>().having((e) => e.problem, 'problem', expected);

PairingCodeException catchIt(void Function() read) {
  try {
    read();
  } on PairingCodeException catch (thrown) {
    return thrown;
  }
  fail('that code was read as a pairing');
}
