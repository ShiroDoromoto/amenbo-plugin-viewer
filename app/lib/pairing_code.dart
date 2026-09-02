/// What the pairing code carries, and which refusal it is when it carries something else.
///
/// The PC draws the code and this reads it, so the two halves of one line of JSON live a repo
/// apart. Nothing else in the app knows the shape: the screen hands over text and gets back either
/// a [Pairing] or a [PairingCodeException] naming what was different about the code it just read.
///
/// **A code that does not fit is answered, not refused.** "Could not read that" leaves the person
/// pointing a camera at a thing that is definitely in frame and definitely not working, with
/// nothing to act on. A code from another app, a code from an Amenbo newer than this build, and a
/// key of the wrong size are three different problems with three different next steps, and the
/// only place that difference is still visible is here.
///
/// The difference is carried as [CodeProblem] and the numbers that go with it. The sentence it
/// becomes is the scanning screen's, so that a person reading a code in Portuguese is refused in
/// Portuguese.
library;

import 'dart:convert';

import 'cloudflare_intake.dart';
import 'pairing_store.dart';
import 'record_envelope.dart';

/// Why a code that was read cannot pair this phone.
///
/// Six, and each one has a next step the others do not: get the right code, update the app,
/// update Amenbo, ask the PC for a fresh one, and — for the two the code itself is wrong about —
/// nothing this phone can do at all.
enum CodeProblem {
  /// Not one of ours. Some other app's code, or a URL, or a shopping barcode.
  notAPairingCode,

  /// Ours, from an Amenbo that speaks a later contract than this build reads.
  tooNew,

  /// Ours, from an Amenbo that speaks an earlier one.
  tooOld,

  /// Ours, and this build's version, with one of the three things it carries not there.
  incomplete,

  /// Ours, and it would have this phone send its token in the clear.
  notHttps,

  /// Ours, and the key on it is not one records open with.
  keyWillNotOpen,
}

/// A code was read and cannot be paired with.
///
/// It carries which refusal it is and the values that belong in the sentence — the two versions,
/// the address — and never the sentence itself.
class PairingCodeException implements Exception {
  const PairingCodeException(this.problem, {this.saidVersion, this.url});

  final CodeProblem problem;

  /// The contract version the code says it speaks, where that is what it was refused for.
  final int? saidVersion;

  /// Where the code would have this phone read from, where that is what it was refused for.
  final Uri? url;

  @override
  String toString() => 'PairingCodeException(${problem.name})';
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
    throw const PairingCodeException(CodeProblem.notAPairingCode);
  }

  if (decoded is! Map<String, Object?> || decoded['v'] is! int) {
    throw const PairingCodeException(CodeProblem.notAPairingCode);
  }

  final version = decoded['v'] as int;
  if (version > contractVersion) {
    throw PairingCodeException(CodeProblem.tooNew, saidVersion: version);
  }
  if (version < contractVersion) {
    throw PairingCodeException(CodeProblem.tooOld, saidVersion: version);
  }

  final url = Uri.tryParse(decoded['url'] as String? ?? '');
  final readToken = decoded['t'];
  final encryptionKey = decoded['k'];
  if (url == null ||
      readToken is! String ||
      readToken.isEmpty ||
      encryptionKey is! String ||
      encryptionKey.isEmpty) {
    throw const PairingCodeException(CodeProblem.incomplete);
  }

  if (!url.isScheme('https') || url.host.isEmpty) {
    // The token on the code is what gets this phone in. Sent in the clear it is not this phone's
    // any more, and a pairing that starts by giving itself away is worth stopping at the camera.
    throw PairingCodeException(CodeProblem.notHttps, url: url);
  }

  final pairing = Pairing(
    url: url,
    readToken: readToken,
    encryptionKey: encryptionKey,
  );

  // The key is tried here rather than at the first sync. A key of the wrong size fails the same
  // way whenever it is noticed, and noticing it while the person is still holding the phone at
  // the screen is the one moment they can do something about it.
  try {
    pairing.cipher();
  } on EnvelopeException {
    throw const PairingCodeException(CodeProblem.keyWillNotOpen);
  }

  return pairing;
}
