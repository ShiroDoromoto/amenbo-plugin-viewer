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
}

/// A round of the intake did not finish, and why.
class IntakeException implements Exception {
  const IntakeException(this.failure, this.message);

  final IntakeFailure failure;

  /// One sentence, for whoever has to do something about it.
  final String message;

  @override
  String toString() => 'IntakeException(${failure.name}): $message';
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

/// Where the place stands, as `GET /meta` answers it.
class PlaceStanding {
  const PlaceStanding({
    required this.specVersion,
    required this.seq,
    this.version,
    this.updatedAt,
  });

  final int specVersion;

  /// How far the order has got. The device compares this with its own cursor to know whether
  /// there is anything to fetch — one small answer, so it can be asked often.
  final int seq;

  /// amenbo's own version, or null when nothing has ever been placed.
  final int? version;
  final String? updatedAt;
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
  }) : _client = client ?? http.Client();

  final Pairing pairing;
  final BacklogStore store;
  final http.Client _client;

  /// How long one request may take. A round nobody is watching still has to end — the phone
  /// refreshes on coming to the front, and a request left hanging would be joined by the next.
  final Duration timeout;

  /// Takes everything the place has that this device has not.
  ///
  /// Throws [IntakeException] if the round could not be finished. Whatever pages landed before
  /// that stay landed, cursor and all: the next round asks from there rather than starting again.
  Future<IntakeReport> run() async {
    var standing = await readStanding();

    var since = store.seq;
    var startedOver = false;
    // The order never rewinds, so a place standing behind this device's cursor is not the place
    // that cursor was counted against — a store rebuilt under a device still paired with the old
    // one. Reading on from here would hand it other records under numbers it recognises.
    if (standing.seq < since) {
      store.wipe();
      since = 0;
      startedOver = true;
    }

    var records = 0;
    var pages = 0;
    var more = since < standing.seq;
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
        continue;
      }
      // A page that promises more and does not move is one this device would ask for again, and
      // again. Whatever is wrong at the other end, the loop is not the place to find out.
      if (page.more && page.seq <= since) {
        throw const IntakeException(
          IntakeFailure.unreadable,
          'the place says there is more, and hands back the same point in the order',
        );
      }
      records += await _write(page);
      pages += 1;
      since = page.seq;
      more = page.more;
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

  /// `GET /meta` — the cheap question.
  Future<PlaceStanding> readStanding() async {
    final answered = await _get(_at('/meta'));
    final specVersion = _readContractVersion(answered);
    final seq = answered['seq'];
    if (seq is! int) {
      throw const IntakeException(
        IntakeFailure.unreadable,
        'the place did not say where it stands',
      );
    }
    return PlaceStanding(
      specVersion: specVersion,
      seq: seq,
      version: answered['version'] as int?,
      updatedAt: answered['updated_at'] as String?,
    );
  }

  /// `GET /records?since=` — one page of what came after a point in the order.
  Future<RecordPage> readPage(int since) async {
    final answered = await _get(_at('/records', {'since': '$since'}));
    final specVersion = _readContractVersion(answered);
    final seq = answered['seq'];
    final listed = answered['records'];
    if (seq is! int || listed is! List) {
      throw const IntakeException(
        IntakeFailure.unreadable,
        'the place answered with something that is not a page of records',
      );
    }

    final records = <SealedRecord>[];
    try {
      for (final entry in listed) {
        if (entry is! Map<String, Object?>) {
          throw const EnvelopeException('a record arrived as something else');
        }
        records.add(SealedRecord.fromJson(entry));
      }
    } on EnvelopeException catch (broken) {
      // A record that does not fit is not skipped: leaving it out would show a backlog with a
      // hole in it and nothing to say a hole was there.
      throw IntakeException(IntakeFailure.unreadable, broken.message);
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
      throw IntakeException(IntakeFailure.unreadable, shut.message);
    }
  }

  /// The one cipher this intake opens everything with. Built on first use, because building it is
  /// where a key of the wrong size is caught and there is no reason to catch it twice.
  late final RecordCipher _cipher = pairing.cipher();

  /// The one place this class reads a contract version, so a place that has moved past this
  /// build is refused at the door rather than at the first field that is not there.
  int _readContractVersion(Map<String, Object?> answered) {
    final specVersion = answered['spec_v'];
    if (specVersion != contractVersion) {
      throw IntakeException(
        IntakeFailure.tooNew,
        'this place speaks version $specVersion of the contract, and this app reads $contractVersion',
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
  Future<Map<String, Object?>> _get(Uri url) async {
    final http.Response answered;
    try {
      answered = await _client
          .get(url, headers: {'Authorization': 'Bearer ${pairing.readToken}'})
          .timeout(timeout);
    } on TimeoutException {
      throw const IntakeException(
        IntakeFailure.unreachable,
        'the place did not answer in time',
      );
    } catch (_) {
      // Whatever the platform called it, from here it is one thing: the place was not reached.
      // The detail is the socket's, and repeating it to the person explains nothing they can act
      // on.
      throw const IntakeException(
        IntakeFailure.unreachable,
        'the place could not be reached',
      );
    }

    if (answered.statusCode == 401 || answered.statusCode == 403) {
      throw const IntakeException(
        IntakeFailure.refused,
        'the place refused this device — pair it again',
      );
    }
    if (answered.statusCode == 409) {
      throw IntakeException(
        IntakeFailure.rebuilt,
        _said(answered) ??
            'this device is reading on from a point the place has not reached',
      );
    }
    if (answered.statusCode != 200) {
      throw IntakeException(
        IntakeFailure.unreadable,
        _said(answered) ?? 'the place answered ${answered.statusCode}',
      );
    }

    const notADocument = IntakeException(
      IntakeFailure.unreadable,
      'the place answered with something that is not a document',
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(answered.bodyBytes));
    } on FormatException {
      throw notADocument;
    }
    if (decoded is! Map<String, Object?>) throw notADocument;
    return decoded;
  }

  /// The sentence the place put in a refusal, when it put one there.
  String? _said(http.Response answered) {
    try {
      final decoded = jsonDecode(utf8.decode(answered.bodyBytes));
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {
      // A body that is not the shape refusals come in says nothing extra; the status stands on
      // its own.
    }
    return null;
  }
}
