/// What the pairing code carries, and what to say when it carries something else.
///
/// The PC draws the code and this reads it, so the two halves of one line of JSON live a repo
/// apart. Nothing else in the app knows the shape: the screen hands over text and gets back either
/// a [Pairing] or a sentence saying what was different about the code it just read.
///
/// **A code that does not fit is answered, not refused.** "Could not read that" leaves the person
/// pointing a camera at a thing that is definitely in frame and definitely not working, with
/// nothing to act on. A code from another app, a code from an amenbo newer than this build, and a
/// key of the wrong size are three different problems with three different next steps, and the
/// only place that difference is still visible is here.
library;

import 'dart:convert';

import 'cloudflare_intake.dart';
import 'pairing_store.dart';
import 'record_envelope.dart';

/// Why a code that was read cannot pair this phone.
enum CodeProblem {
  /// Not one of ours. Some other app's code, or a URL, or a shopping barcode.
  notAPairingCode,

  /// Ours, from an amenbo that speaks a later contract than this build reads.
  tooNew,

  /// Ours, from an amenbo that speaks an earlier one.
  tooOld,

  /// Ours, and this build's version, but one of the three things on it will not do.
  unusable,
}

/// A code was read and cannot be paired with, and the sentence to show for it.
class PairingCodeException implements Exception {
  const PairingCodeException(this.problem, this.message);

  final CodeProblem problem;

  /// One sentence, saying what was different and what to do about it. It is shown as written.
  final String message;

  @override
  String toString() => 'PairingCodeException: $message';
}

/// Reads what a code carries into the three things a pairing is, and the name it goes by.
///
/// The version is settled before anything else is looked at: a later contract may well have moved
/// the other fields, and "this code is missing its URL" would then be a wrong answer to a right
/// question.
Pairing readPairingCode(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw const PairingCodeException(
      CodeProblem.notAPairingCode,
      'That is not an amenbo pairing code. The one you want is the code amenbo '
      'put on your PC screen.',
    );
  }

  if (decoded is! Map<String, Object?> || decoded['v'] is! int) {
    throw const PairingCodeException(
      CodeProblem.notAPairingCode,
      'That is not an amenbo pairing code. The one you want is the code amenbo '
      'put on your PC screen.',
    );
  }

  final version = decoded['v'] as int;
  if (version > contractVersion) {
    throw PairingCodeException(
      CodeProblem.tooNew,
      'That code was made by a newer amenbo than this app reads (it speaks '
      'version $version, this app reads $contractVersion). Update the app, '
      'then show the code again.',
    );
  }
  if (version < contractVersion) {
    throw PairingCodeException(
      CodeProblem.tooOld,
      'That code was made by an older amenbo than this app reads (it speaks '
      'version $version, this app reads $contractVersion). Update amenbo on '
      'the PC and show a fresh code.',
    );
  }

  final url = Uri.tryParse(decoded['url'] as String? ?? '');
  final readToken = decoded['t'];
  final encryptionKey = decoded['k'];
  if (url == null ||
      readToken is! String ||
      readToken.isEmpty ||
      encryptionKey is! String ||
      encryptionKey.isEmpty) {
    throw const PairingCodeException(
      CodeProblem.unusable,
      'That code is an amenbo pairing code with something missing from it. Show '
      'a fresh one from the PC.',
    );
  }

  if (!url.isScheme('https') || url.host.isEmpty) {
    // The token on the code is what gets this phone in. Sent in the clear it is not this phone's
    // any more, and a pairing that starts by giving itself away is worth stopping at the camera.
    throw PairingCodeException(
      CodeProblem.unusable,
      'That code reads from $url, and this app will only send its token over '
      'https.',
    );
  }

  // The name is not one of the three things a pairing is, so a code without one still pairs. It
  // was added to the code after the three were, and a phone that refused the older code would be
  // refusing a pairing that works over a line it only displays.
  final label = decoded['l'];

  final pairing = Pairing(
    url: url,
    readToken: readToken,
    encryptionKey: encryptionKey,
    label: label is String && label.isNotEmpty ? label : null,
  );

  // The key is tried here rather than at the first sync. A key of the wrong size fails the same
  // way whenever it is noticed, and noticing it while the person is still holding the phone at
  // the screen is the one moment they can do something about it.
  try {
    pairing.cipher();
  } on EnvelopeException catch (wrong) {
    throw PairingCodeException(
      CodeProblem.unusable,
      'The key on that code is not one this app can open records with '
      '(${wrong.message}). Show a fresh code from the PC.',
    );
  }

  return pairing;
}
