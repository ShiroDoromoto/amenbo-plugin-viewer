/// The Cloudflare route: the one place the app fetches anything over the network.
///
/// The place holds the records in an order that only ever climbs, and this device remembers the
/// point it read to. So a round of the intake is two questions and a loop: where does the place
/// stand, and — if it stands further along than we do — what came after our point, a page at a
/// time until there is no more.
///
/// **Every page is opened and written before the next one is asked for.** Building the whole
/// answer in memory and saving it at the end would make the first sync of a long backlog the one
/// moment the app is most likely to be killed for its size, and it would throw away everything it
/// had already opened when that happened. Page by page, an interrupted sync costs the page it was
/// on: the cursor moved with the pages that landed, and the next round carries on from there.
///
/// Nothing here draws anything. What it leaves behind is rows in the local store, which is the
/// only thing the screens read.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'pairing_store.dart';
import 'record_envelope.dart';
import 'store/backlog_store.dart';

/// The version of the shared contract this build reads.
///
/// A place answering with another one is not a place this app can read: the fields it would be
/// reading are not the fields that were written. That is a message asking the person to update
/// the app, not an error to retry.
const contractVersion = 1;

/// How the intake waits, when a place asks it to come back in a moment.
Future<void> _sleep(Duration howLong) => Future<void>.delayed(howLong);

/// Why a round of the intake could not be finished.
enum IntakeFailure {
  /// The place could not be reached at all — no network, or nothing answering there.
  unreachable,

  /// The place refused this device's token. The pairing was revoked, or it was never for this
  /// place. Either way the way out is to pair again, not to retry.
  refused,

  /// The place speaks a version of the contract this build does not read.
  tooNew,

  /// The place is not the one this device's cursor was counted against — it was built again
  /// from nothing. The local copy has to go and be taken from the beginning.
  rebuilt,

  /// The place answered, and what it said could not be read as records.
  unreadable,

  /// The records at the place were sealed with a key other than this device's, and the place said
  /// so before a single one was fetched. Not a fault at either end and not a pairing that went
  /// wrong: two Amenbo stores share one place — the Worker and the database are named the same
  /// whoever sets them up — so the second one to be set up seals with its own key while the
  /// first one's records are still standing there. The next placement from the PC replaces them,
  /// and there is nothing for this device to do in the meantime.
  otherKey,

  /// The place is being written again from the beginning, and what is there now is part of a
  /// backlog. It closed its reading doors rather than answer with a fraction — a phone cannot
  /// tell that fraction from a backlog that really did shrink, and would write it down and call
  /// itself level. Seconds, not a fault.
  placing,

  /// The place answered that it cannot answer right now, and said to come back later than a
  /// placement ever takes. The database behind it has run into a limit of its own — a day's
  /// writes used up, no room left — and every one of those ends with time passing rather than
  /// with anything anybody does. Nothing here is damaged, nothing at either end is misconfigured,
  /// and the PC is not the end to go and look at.
  busy,
}

/// Whether another round could end any differently.
///
/// Three of them cannot: a refusal stands until the PC hands out a fresh code, a contract this
/// build does not read stands until the store hands out a newer app, and records sealed with
/// another key stand until the PC sends again. All three are settled somewhere else, so a button
/// that repeats them is a button that fails identically every time it is pressed — and the
/// sentence beside it has already said where to go instead.
bool worthAnotherRound(IntakeFailure failure) =>
    failure != IntakeFailure.refused &&
    failure != IntakeFailure.tooNew &&
    failure != IntakeFailure.otherKey;

/// A round of the intake did not finish, and why.
///
/// It carries which refusal this is and the values that go with it, and never a sentence. What
/// the person waiting is told is the screen's to say — there is one line for each of them,
/// written in whichever language the phone is set to.
class IntakeException implements Exception {
  const IntakeException(
    this.failure, {
    this.at,
    this.status,
    this.placeVersion,
  });

  final IntakeFailure failure;

  /// Where the round stopped — an endpoint, a file, or a record's key. A locator for whoever is
  /// reading a stack trace, never a sentence and never shown to anybody.
  final String? at;

  /// What the place answered with, where it answered something no reading was expected of.
  final int? status;

  /// The contract version the other end speaks, where that is what stopped the round.
  ///
  /// Not shown either, and deliberately: the way out of it is the same number or another
  /// ([worthAnotherRound] says there is none), and which version this build reads is on the about
  /// screen for whoever wants to compare the two.
  final int? placeVersion;

  @override
  String toString() =>
      'IntakeException(${failure.name})'
      '${at == null ? '' : ' at $at'}'
      '${status == null ? '' : ' answered $status'}'
      '${placeVersion == null ? '' : ' speaking version $placeVersion'}';
}

/// What one round of the intake did.
class IntakeReport {
  const IntakeReport({
    required this.records,
    required this.pages,
    required this.seq,
    required this.startedOver,
  });

  /// How many records were written. Zero with no pages read means the device was already level.
  final int records;
  final int pages;

  /// The point in the order the device now stands at.
  final int seq;

  /// The local copy was emptied first, because the place could not be the one this device's
  /// cursor was counted against.
  final bool startedOver;

  /// Nothing had moved since the last round.
  bool get alreadyLevel => pages == 0;
}

/// How far a round has got, handed out as each page lands.
///
/// The first sync is the one time anybody watches this, and it is watched because it is long.
/// What it can honestly say is two different things, so it says both: [records] is exact and only
/// climbs, and [through] is where the round stands in an order whose end is known.
///
/// **[records] is not a countdown.** How many rows the place holds is not a question `GET /meta`
/// answers, and [target] counts writes rather than rows — a row rewritten since it was first
/// placed took two of them. Reading [target] as "how many are coming" would overcount every
/// backlog that has ever been edited.
class IntakeProgress {
  const IntakeProgress({
    required this.records,
    required this.seq,
    required this.target,
  });

  /// Records written in this round so far.
  final int records;

  /// The point in the order the device now stands at.
  final int seq;

  /// The point the place stands at — where this round ends.
  final int target;

  /// How far along the order the round is, 0 to 1.
  double get through => target <= 0 ? 1 : (seq / target).clamp(0, 1).toDouble();
}

/// Where the place stands, as `GET /meta` answers it.
class PlaceStanding {
  const PlaceStanding({
    required this.specVersion,
    required this.seq,
    this.placedFrom = 0,
    this.version,
    this.updatedAt,
    this.keyFingerprint,
  });

  final int specVersion;

  /// How far the order has got. The device compares this with its own cursor to know whether
  /// there is anything to fetch — one small answer, so it can be asked often.
  final int seq;

  /// Where the placement standing at the place began — the point the order had reached the moment
  /// everything there was written again from nothing.
  ///
  /// A cursor that has not passed it points at rows that were all made again, so what this device
  /// holds is not the beginning of what is there now. Zero is a place that has never been placed
  /// again, and it is also what an older place — one deployed before this number existed — leaves
  /// out of its answer; both mean there is nothing here to be behind.
  final int placedFrom;

  /// Amenbo's own version, or null when nothing has ever been placed.
  final int? version;
  final String? updatedAt;

  /// The name of the key the records standing there were sealed with — what `keyFingerprint` in
  /// `record_envelope.dart` answers, taken on the PC over the same bytes.
  ///
  /// **Null is not a mismatch.** It is a place nobody has named a key over, which is every place
  /// written by a sender older than the field, so there is nothing to hold this device's key up
  /// against and the round carries on as it always did.
  final String? keyFingerprint;
}

/// One page of `GET /records`.
class RecordPage {
  const RecordPage({
    required this.specVersion,
    required this.seq,
    required this.more,
    required this.records,
    this.version,
  });

  final int specVersion;

  /// The point this page reached — what the next one is asked from.
  final int seq;

  /// There is another page behind this one.
  final bool more;
  final int? version;
  final List<SealedRecord> records;
}

/// Reads a place over HTTPS, and writes what it hands over into the local store.
class CloudflareIntake {
  CloudflareIntake({
    required this.pairing,
    required this.store,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this._pause = _sleep,
  }) : _client = client ?? http.Client();

  final Pairing pairing;
  final BacklogStore store;
  final http.Client _client;

  /// How long one request may take. A round nobody is watching still has to end — the phone
  /// refreshes on coming to the front, and a request left hanging would be joined by the next.
  final Duration timeout;

  /// How the round waits out a placement. Handed in so a test can sit through five seconds
  /// without taking five seconds.
  final Future<void> Function(Duration) _pause;

  /// The longest `Retry-After` this phone will actually sit through.
  ///
  /// A placement is seconds, which is why waiting it out inside the round is worth doing at all:
  /// the person who pulled gets their rows instead of a line about a state they cannot act on.
  /// A longer wait than this is not that state wearing the same status — it is a place that
  /// cannot answer right now ([IntakeFailure.busy]) — and sleeping on it would be an app that
  /// hangs on whatever a header says.
  static const _longestPause = Duration(seconds: 10);

  /// Takes everything the place has that this device has not.
  ///
  /// Throws [IntakeException] if the round could not be finished. Whatever pages landed before
  /// that stay landed, cursor and all: the next round asks from there rather than starting again.
  ///
  /// [watching] is called once the place has said where it stands, and again after each page is
  /// written — after, so what it reports is what is on the phone rather than what is expected.
  Future<IntakeReport> run({
    void Function(IntakeProgress reached)? watching,
  }) async {
    var standing = await readStanding();

    var since = store.seq;
    var startedOver = false;
    // Two ways the same cheap answer says this device's copy is not the beginning of what is
    // there now. The order never rewinds, so a place standing behind this cursor is not the place
    // that cursor was counted against — a store rebuilt under a device still paired with the old
    // one; reading on from here would hand it other records under numbers it recognises. And a
    // cursor the standing placement began at or above holds only rows that placement wrote again,
    // with whatever was deleted in between in neither the copy nor what is coming. Either way the
    // copy goes. Asking first is what spares the round the refusal `/records` would answer with.
    if (standing.seq < since || (since > 0 && since <= standing.placedFrom)) {
      store.wipe();
      since = 0;
      startedOver = true;
    }

    var records = 0;
    var pages = 0;
    var more = since < standing.seq;
    void reached() => watching?.call(
      IntakeProgress(records: records, seq: since, target: standing.seq),
    );
    reached();
    while (more) {
      final RecordPage page;
      try {
        page = await readPage(since);
      } on IntakeException catch (failed) {
        // The place saying the same thing from its end: this cursor is past where it stands. It
        // is worth starting over exactly once — a place that says it again is one this round
        // cannot make progress against, and looping on it would fetch forever.
        if (failed.failure != IntakeFailure.rebuilt || startedOver) rethrow;
        store.wipe();
        since = 0;
        startedOver = true;
        standing = await readStanding();
        more = standing.seq > 0;
        reached();
        continue;
      }
      // A page that promises more and does not move is one this device would ask for again, and
      // again. Whatever is wrong at the other end, the loop is not the place to find out.
      if (page.more && page.seq <= since) {
        throw const IntakeException(IntakeFailure.unreadable, at: _records);
      }
      records += await _write(page);
      pages += 1;
      since = page.seq;
      more = page.more;
      reached();
    }

    store.setMeta(MetaKey.specVersion, '$contractVersion');
    store.setMeta(MetaKey.fetchedAt, DateTime.now().toUtc().toIso8601String());
    return IntakeReport(
      records: records,
      pages: pages,
      seq: since,
      startedOver: startedOver,
    );
  }

  /// The two the place answers on. Named once, so what a stopped round says it stopped at is the
  /// address it was really asking.
  static const _meta = '/meta';
  static const _records = '/records';

  /// `GET /meta` — the cheap question.
  Future<PlaceStanding> readStanding() async {
    final answered = await _get(_at(_meta), from: _meta);
    final specVersion = _readContractVersion(answered, from: _meta);
    final seq = answered['seq'];
    if (seq is! int) {
      throw const IntakeException(IntakeFailure.unreadable, at: _meta);
    }
    final placedFrom = answered['placed_from'];
    final sealedWith = answered['key_fingerprint'];
    final named = sealedWith is String && sealedWith.isNotEmpty
        ? sealedWith
        : null;
    // Held up before a single record is asked for. A place naming a key other than this device's
    // holds nothing this device can open, and a fetch would spend the whole order finding that
    // out — then say the records are damaged, which they are not, and offer to pair again, which
    // would not help. The two are told apart here or not at all.
    final ours = await _ourKeyNamed;
    if (named != null && ours != null && named != ours) {
      throw const IntakeException(IntakeFailure.otherKey, at: _meta);
    }
    return PlaceStanding(
      specVersion: specVersion,
      seq: seq,
      placedFrom: placedFrom is int ? placedFrom : 0,
      version: answered['version'] as int?,
      updatedAt: answered['updated_at'] as String?,
      keyFingerprint: named,
    );
  }

  /// What this device's own key is called, or null when it cannot be called anything.
  ///
  /// A key this build cannot even name is one it cannot open a record with either, and that is
  /// already told where a record fails to open. Nothing is gained by turning it into a different
  /// answer here, so a key that will not name itself simply leaves the comparison unmade.
  late final Future<String?> _ourKeyNamed = _nameOurKey();

  Future<String?> _nameOurKey() async {
    try {
      return await keyFingerprint(pairing.encryptionKey);
    } on EnvelopeException {
      return null;
    }
  }

  /// `GET /records?since=` — one page of what came after a point in the order.
  Future<RecordPage> readPage(int since) async {
    final answered = await _get(
      _at(_records, {'since': '$since'}),
      from: _records,
    );
    final specVersion = _readContractVersion(answered, from: _records);
    final seq = answered['seq'];
    final listed = answered['records'];
    if (seq is! int || listed is! List) {
      throw const IntakeException(IntakeFailure.unreadable, at: _records);
    }

    final records = <SealedRecord>[];
    try {
      for (final entry in listed) {
        if (entry is! Map<String, Object?>) {
          throw const EnvelopeException(SealProblem.malformed);
        }
        records.add(SealedRecord.fromJson(entry));
      }
    } on EnvelopeException catch (broken) {
      // A record that does not fit is not skipped: leaving it out would show a backlog with a
      // hole in it and nothing to say a hole was there.
      throw IntakeException(
        IntakeFailure.unreadable,
        at: broken.at ?? _records,
      );
    }

    return RecordPage(
      specVersion: specVersion,
      seq: seq,
      more: answered['more'] == true,
      version: answered['version'] as int?,
      records: records,
    );
  }

  /// Opens one page and writes it, cursor and all, in one transaction.
  ///
  /// The version is only taken once the last page has landed. Until then this device holds half
  /// of a turn, and a version saying otherwise would have it tell the person it is level when it
  /// is halfway.
  Future<int> _write(RecordPage page) async {
    final changes = <BacklogChange>[];
    for (final record in page.records) {
      // A record that will not open is not written around: whoever can write to the place can
      // move a ciphertext to another name, and a device that skipped what it could not open
      // would show the rest of the page as if nothing were missing.
      final change = record.deleted
          ? BacklogChange.fromKey(record.key)
          : BacklogChange.fromKey(record.key, row: await _opened(record));
      // A key that is not `<name>/<id>` names a row in a shape this build has no reading for.
      // The store has nowhere to put it, and guessing is worse than leaving it where it is.
      if (change != null) changes.add(change);
    }
    store.applyPage(
      changes,
      seq: page.seq,
      version: page.more ? null : page.version,
    );
    return changes.length;
  }

  Future<Map<String, Object?>> _opened(SealedRecord record) async {
    try {
      return await _cipher.openJson(record);
    } on EnvelopeException catch (shut) {
      throw IntakeException(
        IntakeFailure.unreadable,
        at: shut.at ?? record.key,
      );
    }
  }

  /// The one cipher this intake opens everything with. Built on first use, because building it is
  /// where a key of the wrong size is caught and there is no reason to catch it twice.
  late final RecordCipher _cipher = pairing.cipher();

  /// The one place this class reads a contract version, so a place that has moved past this
  /// build is refused at the door rather than at the first field that is not there.
  int _readContractVersion(
    Map<String, Object?> answered, {
    required String from,
  }) {
    final specVersion = answered['spec_v'];
    if (specVersion != contractVersion) {
      throw IntakeException(
        IntakeFailure.tooNew,
        at: from,
        placeVersion: specVersion is int ? specVersion : null,
      );
    }
    return contractVersion;
  }

  /// Builds a URL under the place, keeping whatever path the pairing carried.
  Uri _at(String path, [Map<String, String>? query]) {
    final base = pairing.url;
    final carried = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(path: '$carried$path', queryParameters: query);
  }

  /// One GET, with this device's token on it, read as the JSON object every answer is.
  ///
  /// [again] is set on the one retry a placement gets, so that a place which is still placing
  /// when the wait is over ends the round instead of being waited on twice.
  Future<Map<String, Object?>> _get(
    Uri url, {
    required String from,
    bool again = false,
  }) async {
    final http.Response answered;
    try {
      answered = await _client
          .get(url, headers: {'Authorization': 'Bearer ${pairing.readToken}'})
          .timeout(timeout);
    } on TimeoutException {
      throw IntakeException(IntakeFailure.unreachable, at: from);
    } catch (_) {
      // Whatever the platform called it, from here it is one thing: the place was not reached.
      // The detail is the socket's, and repeating it to the person explains nothing they can act
      // on.
      throw IntakeException(IntakeFailure.unreachable, at: from);
    }

    final status = answered.statusCode;
    if (status == 401 || status == 403) {
      throw IntakeException(IntakeFailure.refused, at: from, status: status);
    }
    if (status == 409) {
      throw IntakeException(IntakeFailure.rebuilt, at: from, status: status);
    }
    if (status == 503) {
      // Three things answer 503, and the header is what tells them apart. A Worker deployed
      // without its write token has nothing to say and nothing that waiting would fix. A
      // placement says to come back in the seconds it takes. And a place whose database has hit
      // a limit of its own says to come back after a wait no placement ever asks for — that one
      // ends by itself too, but not inside this round.
      final comeBack = answered.headers['retry-after'];
      if (comeBack == null) {
        throw IntakeException(
          IntakeFailure.unreadable,
          at: from,
          status: status,
        );
      }
      final seconds = int.tryParse(comeBack.trim());
      final wait = seconds == null ? null : Duration(seconds: seconds);
      // A wait longer than a placement takes, or one written in a spelling this build does not
      // read, is not the state that ends inside the round. Calling it a placement would tell the
      // person their PC is mid-send, which is a sentence about the one end that has nothing to
      // do with it.
      if (wait == null || wait > _longestPause) {
        throw IntakeException(IntakeFailure.busy, at: from, status: status);
      }
      if (!again) {
        await _pause(wait);
        return _get(url, from: from, again: true);
      }
      throw IntakeException(IntakeFailure.placing, at: from, status: status);
    }
    if (status != 200) {
      throw IntakeException(IntakeFailure.unreadable, at: from, status: status);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(answered.bodyBytes));
    } on FormatException {
      throw IntakeException(IntakeFailure.unreadable, at: from, status: status);
    }
    if (decoded is! Map<String, Object?>) {
      throw IntakeException(IntakeFailure.unreadable, at: from, status: status);
    }
    return decoded;
  }
}
