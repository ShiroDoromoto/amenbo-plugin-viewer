// The place is written by hand here, answer by answer. Nothing in this file reaches a Worker:
// what is under test is what the app does with each answer it can be given, and the answers
// worth testing are the ones that are awkward to produce on demand — a cursor the place has not
// reached, a contract version from a later build, a record that will not open.
//
// The records are sealed here rather than pasted in, because what they are is not the point: the
// agreement with the PC's own cipher is held down by `record_envelope_test.dart`, against bytes
// Go actually wrote.

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:amenbo_viewer/cloudflare_intake.dart';
import 'package:amenbo_viewer/pairing_store.dart';
import 'package:amenbo_viewer/store/backlog_queries.dart';
import 'package:amenbo_viewer/store/backlog_store.dart';

import 'backlog_fixture.dart';

/// 32 bytes. The pairing's key, in the spelling a QR carries it in.
const key = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';

const readToken = 'this-devices-own-read-token';

final _algorithm = Xchacha20.poly1305Aead();

var _nonceCount = 0;

/// Seals one row the way the PC does: a fresh nonce beside the ciphertext, the tag on the end of
/// it, and the record's key sealed in as associated data.
Future<Map<String, Object?>> sealed(
  String recordKey,
  Map<String, Object?> row,
) async {
  final nonce = List<int>.generate(24, (at) => (at + (_nonceCount += 1)) % 256);
  final box = await _algorithm.encrypt(
    utf8.encode(jsonEncode(row)),
    secretKey: SecretKey(base64Url.decode(base64Url.normalize(key))),
    nonce: nonce,
    aad: utf8.encode(recordKey),
  );
  return {
    'k': recordKey,
    'op': 'put',
    'n': base64Url.encode(nonce),
    'c': base64Url.encode([...box.cipherText, ...box.mac.bytes]),
  };
}

Map<String, Object?> deleted(String recordKey) => {'k': recordKey, 'op': 'del'};

/// A place, answering whatever the test says it answers.
class Place {
  Place({this.seq = 0, this.version = 100, this.specVersion = 1});

  int seq;
  int? version;
  int specVersion;

  /// What `GET /records?since=` hands back, keyed by the point it was asked from.
  final pages = <int, Map<String, Object?>>{};

  /// A status to answer with instead, keyed the same way.
  final refusals = <int, int>{};

  /// A status `GET /meta` answers with instead of saying where it stands.
  int? metaRefusal;

  /// How many more answers are the closed door of a placement, and what each one says to come
  /// back after. Counted down, so a test can have the door open again on the second ask.
  int closedFor = 0;
  String? comeBackAfter = '5';

  /// The points the intake asked from, in order.
  final asked = <int>[];

  /// The tokens the requests carried, and the URLs they went to.
  final carried = <String?>[];
  final visited = <String>[];

  /// One page, spelled the way the place spells it.
  void page(
    int since, {
    required int seq,
    required bool more,
    required List<Map<String, Object?>> records,
  }) {
    pages[since] = {
      'spec_v': specVersion,
      'version': version,
      'seq': seq,
      'more': more,
      'records': records,
    };
  }

  http.Client get client => MockClient((request) async {
    carried.add(request.headers['Authorization']);
    visited.add(request.url.path);

    // Both reading doors close together for the length of a placement, so this is asked before
    // either of them is answered.
    if (closedFor > 0) {
      closedFor -= 1;
      final headers = {..._json};
      final after = comeBackAfter;
      // A door with nothing to come back for is the other 503 — a Worker deployed without its
      // write token — which the phone has to tell apart from this one.
      if (after != null) headers['retry-after'] = after;
      return http.Response(
        jsonEncode({'error': 'the whole of this store is being placed again'}),
        503,
        headers: headers,
      );
    }

    if (request.url.path.endsWith('/meta')) {
      if (metaRefusal != null) {
        return http.Response(
          jsonEncode({'error': 'no'}),
          metaRefusal!,
          headers: _json,
        );
      }
      return http.Response(
        jsonEncode({
          'spec_v': specVersion,
          'version': version,
          'seq': seq,
          'updated_at': '2026-08-09T12:00:00Z',
        }),
        200,
        headers: _json,
      );
    }

    final since = int.parse(request.url.queryParameters['since'] ?? '0');
    asked.add(since);
    final refusal = refusals[since];
    if (refusal != null) {
      return http.Response(
        jsonEncode({'error': 'read again from the beginning'}),
        refusal,
        headers: _json,
      );
    }
    return http.Response(jsonEncode(pages[since]), 200, headers: _json);
  });

  static const _json = {'content-type': 'application/json; charset=utf-8'};
}

final _pairing = Pairing(
  url: Uri.parse('https://viewer.example.workers.dev'),
  readToken: readToken,
  encryptionKey: key,
);

void main() {
  late BacklogStore store;

  setUp(() => store = BacklogStore.openInMemory());
  tearDown(() => store.close());

  CloudflareIntake intakeFrom(Place place, {Pairing? pairing}) =>
      CloudflareIntake(
        pairing: pairing ?? _pairing,
        store: store,
        client: place.client,
      );

  group('a round of the intake', () {
    test('writes what the place handed over, and moves the cursor', () async {
      final place = Place(seq: 2)
        ..page(
          0,
          seq: 2,
          more: false,
          records: [
            await sealed('task/1', task(id: 1, title: 'QR を読む')),
            await sealed('task/2', task(id: 2, title: '設定を作る')),
          ],
        );

      final report = await intakeFrom(place).run();

      expect(report.records, 2);
      expect(report.seq, 2);
      expect(store.seq, 2);
      expect(store.record('task', 1)!['title'], 'QR を読む');
      expect(store.record('task', 2)!['title'], '設定を作る');
      expect(store.meta(MetaKey.version), '100');
      expect(store.meta(MetaKey.specVersion), '1');
      expect(store.meta(MetaKey.fetchedAt), isNotNull);
    });

    test('carries this device\'s token, and nothing else', () async {
      final place = Place(seq: 1)
        ..page(
          0,
          seq: 1,
          more: false,
          records: [await sealed('task/1', task(id: 1))],
        );

      await intakeFrom(place).run();

      expect(place.carried, everyElement('Bearer $readToken'));
    });

    test('keeps whatever path the pairing carried', () async {
      final place = Place(seq: 0);

      await intakeFrom(
        place,
        pairing: Pairing(
          url: Uri.parse('https://example.test/viewer/'),
          readToken: readToken,
          encryptionKey: key,
        ),
      ).run();

      expect(place.visited, ['/viewer/meta']);
    });

    // The cheap question is the whole reason `/meta` exists: a device that is level pays for one
    // small answer and stops, which is what lets it ask every time the app comes to the front.
    test('asks for no records at all when it is already level', () async {
      store.seq = 7;
      final place = Place(seq: 7);

      final report = await intakeFrom(place).run();

      expect(place.asked, isEmpty);
      expect(report.alreadyLevel, isTrue);
      expect(report.records, 0);
    });

    test('takes a deletion as the row going away', () async {
      store.applyPage([BacklogChange.put('task', 1, task(id: 1))]);
      final place = Place(seq: 5)
        ..page(0, seq: 5, more: false, records: [deleted('task/1')]);

      await intakeFrom(place).run();

      expect(store.record('task', 1), isNull);
    });

    // A key naming something in a shape this build has no reading for is left where it is. The
    // rest of the page is not held up by it — it will be readable by a later build, from the
    // records the device already holds.
    test('steps over a key it has no reading for', () async {
      final place = Place(seq: 2)
        ..page(
          0,
          seq: 2,
          more: false,
          records: [
            await sealed('banner', {'text': 'hello'}),
            await sealed('task/1', task(id: 1, title: 'これは入る')),
          ],
        );

      final report = await intakeFrom(place).run();

      expect(report.records, 1);
      expect(store.record('task', 1)!['title'], 'これは入る');
    });
  });

  group('pages', () {
    test('are followed until there is no more', () async {
      final place = Place(seq: 2)
        ..page(
          0,
          seq: 1,
          more: true,
          records: [await sealed('task/1', task(id: 1))],
        )
        ..page(
          1,
          seq: 2,
          more: false,
          records: [await sealed('task/2', task(id: 2))],
        );

      final report = await intakeFrom(place).run();

      expect(place.asked, [0, 1]);
      expect(report.pages, 2);
      expect(store.seq, 2);
    });

    // Half a turn is not a version. A device that wrote it down after the first page would tell
    // the person it was level with a backlog it had only half of.
    test('leave the version alone until the last one lands', () async {
      final place = Place(seq: 2)
        ..page(
          0,
          seq: 1,
          more: true,
          records: [await sealed('task/1', task(id: 1))],
        )
        ..refusals[1] = 500;

      await expectLater(
        intakeFrom(place).run(),
        throwsA(isA<IntakeException>()),
      );

      expect(store.seq, 1, reason: 'the page that landed keeps its place');
      expect(store.meta(MetaKey.version), isNull);
    });

    // Whatever is wrong at the other end, asking the same question forever is not how to find
    // out — and on a phone it is the battery that pays for it.
    test('stop when the place promises more and does not move', () async {
      final place = Place(seq: 9)..page(0, seq: 0, more: true, records: []);

      await expectLater(
        intakeFrom(place).run(),
        throwsA(
          isA<IntakeException>().having(
            (it) => it.failure,
            'failure',
            IntakeFailure.unreadable,
          ),
        ),
      );
    });
  });

  group('what a round says while it runs', () {
    // The first sync is long enough to be watched, and what is reported has to be what is on the
    // phone — a page counted before it was written would tell someone a row is there to read
    // when the app died in the middle of writing it.
    test('reports after each page, never before', () async {
      final place = Place(seq: 2)
        ..page(
          0,
          seq: 1,
          more: true,
          records: [await sealed('task/1', task(id: 1))],
        )
        ..page(
          1,
          seq: 2,
          more: false,
          records: [await sealed('task/2', task(id: 2))],
        );

      final reached = <IntakeProgress>[];
      await intakeFrom(place).run(watching: reached.add);

      // One before the first page — the place has answered, so the end of the order is known —
      // and one after each page that landed.
      expect(reached.map((at) => at.records), [0, 1, 2]);
      expect(reached.map((at) => at.seq), [0, 1, 2]);
      expect(reached.every((at) => at.target == 2), isTrue);
      expect(reached.map((at) => at.through), [0.0, 0.5, 1.0]);
    });

    test('a device already level is all the way through', () async {
      final place = Place(seq: 0);

      final reached = <IntakeProgress>[];
      await intakeFrom(place).run(watching: reached.add);

      // Nothing to fetch is not nothing to say: a bar at zero would read as stuck.
      expect(reached.single.through, 1);
    });
  });

  group('a place this cursor did not come from', () {
    // The order never rewinds, so one standing behind this device was built again from nothing.
    // Reading on from here would hand it other records under numbers it recognises.
    test('is read again from the beginning, and the old copy goes', () async {
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, title: 'まえの置き場のもの')),
      ], seq: 40);
      final place = Place(seq: 1)
        ..page(
          0,
          seq: 1,
          more: false,
          records: [await sealed('task/2', task(id: 2, title: 'いまの置き場のもの'))],
        );

      final report = await intakeFrom(place).run();

      expect(report.startedOver, isTrue);
      expect(store.record('task', 1), isNull);
      expect(store.record('task', 2), isNotNull);
      expect(store.seq, 1);
    });

    // The same verdict, reached from the other end: the place refuses a cursor past where it
    // stands, and it can say so about a rebuild that happened between the two questions.
    test('is started over when the place refuses the cursor', () async {
      store.applyPage([BacklogChange.put('task', 1, task(id: 1))], seq: 3);
      final place = Place(seq: 9)
        ..refusals[3] = 409
        ..page(
          0,
          seq: 2,
          more: false,
          records: [await sealed('task/2', task(id: 2))],
        );

      final report = await intakeFrom(place).run();

      expect(place.asked, [3, 0]);
      expect(report.startedOver, isTrue);
      expect(store.record('task', 1), isNull);
      expect(store.record('task', 2), isNotNull);
    });

    // Starting over is worth doing once. A place that refuses the beginning too is not one this
    // round can make progress against, and trying again would be a loop with a network in it.
    test('is not started over twice', () async {
      final place = Place(seq: 9)
        ..refusals[0] = 409
        ..refusals[3] = 409;
      store.seq = 3;

      await expectLater(
        intakeFrom(place).run(),
        throwsA(
          isA<IntakeException>().having(
            (it) => it.failure,
            'failure',
            IntakeFailure.rebuilt,
          ),
        ),
      );
    });
  });

  group('what the round cannot go on from', () {
    test('a contract version this build does not read', () async {
      final place = Place(seq: 1, specVersion: 2);

      await expectLater(
        intakeFrom(place).run(),
        throwsA(
          isA<IntakeException>().having(
            (it) => it.failure,
            'failure',
            IntakeFailure.tooNew,
          ),
        ),
      );
      expect(store.meta(MetaKey.specVersion), isNull);
    });

    test('a token the place no longer knows', () async {
      final place = Place(seq: 1)..metaRefusal = 401;

      await expectLater(
        intakeFrom(place).run(),
        throwsA(
          isA<IntakeException>().having(
            (it) => it.failure,
            'failure',
            IntakeFailure.refused,
          ),
        ),
      );
    });

    // A record that will not open is one the place, or somebody who can write to it, moved or
    // altered. Writing the page around it would show the rest as if nothing were missing.
    test('a record that does not open with the key this device holds', () async {
      final place = Place(seq: 2)
        ..page(
          0,
          seq: 2,
          more: false,
          records: [
            await sealed('task/1', task(id: 1)),
            // Sealed under one name and filed under another — which is exactly what sealing the
            // key in as associated data is there to catch.
            {...await sealed('task/2', task(id: 2)), 'k': 'task/3'},
          ],
        );

      await expectLater(
        intakeFrom(place).run(),
        throwsA(
          isA<IntakeException>().having(
            (it) => it.failure,
            'failure',
            IntakeFailure.unreadable,
          ),
        ),
      );
      expect(store.seq, 0, reason: 'the page is written whole or not at all');
      expect(store.record('task', 1), isNull);
    });

    test('an envelope that does not fit', () async {
      final place = Place(seq: 1)
        ..page(
          0,
          seq: 1,
          more: false,
          records: [
            {'k': 'task/1', 'op': 'put', 'n': 'not-a-nonce', 'c': 'nor-this'},
          ],
        );

      await expectLater(
        intakeFrom(place).run(),
        throwsA(isA<IntakeException>()),
      );
    });
  });

  group('a place that is being written again from the beginning', () {
    /// The waits the round sat through, instead of sitting through them.
    ({List<Duration> waited, CloudflareIntake intake}) intakeCounting(
      Place place,
    ) {
      final waited = <Duration>[];
      return (
        waited: waited,
        intake: CloudflareIntake(
          pairing: _pairing,
          store: store,
          client: place.client,
          pause: (howLong) async => waited.add(howLong),
        ),
      );
    }

    test('the round waits out the placement and takes what follows', () async {
      final place = Place(seq: 1)
        ..closedFor = 1
        ..page(
          0,
          seq: 1,
          more: false,
          records: [await sealed('task/1', task(id: 1, title: 'あとから来た'))],
        );
      final counting = intakeCounting(place);

      final report = await counting.intake.run();

      // The door said five seconds, so five seconds is what was waited — and the ask that
      // followed is the one that brought the rows.
      expect(counting.waited, [const Duration(seconds: 5)]);
      expect(report.records, 1);
      expect(store.record('task', 1)!['title'], 'あとから来た');
    });

    test('a door still closed after the wait ends the round as a wait', () async {
      final place = Place(seq: 1)..closedFor = 5;
      final counting = intakeCounting(place);

      // Not unreadable: the place is not broken and this device's key is fine. Waiting twice on
      // one round would be the app deciding how long the person stands there.
      await expectLater(
        counting.intake.run(),
        throwsA(
          isA<IntakeException>().having(
            (stopped) => stopped.failure,
            'failure',
            IntakeFailure.placing,
          ),
        ),
      );
      expect(counting.waited, hasLength(1));
    });

    test('a wait longer than a placement is not sat through', () async {
      final place = Place(seq: 1)
        ..closedFor = 1
        ..comeBackAfter = '600';
      final counting = intakeCounting(place);

      await expectLater(
        counting.intake.run(),
        throwsA(
          isA<IntakeException>().having(
            (stopped) => stopped.failure,
            'failure',
            IntakeFailure.placing,
          ),
        ),
      );
      // Ten minutes is not the state that ends by itself, whatever status it wears.
      expect(counting.waited, isEmpty);
    });

    test('a 503 with nothing to come back for is not a placement', () async {
      final place = Place(seq: 1)
        ..closedFor = 1
        ..comeBackAfter = null;
      final counting = intakeCounting(place);

      // A Worker deployed without its write token answers 503 too, and no amount of waiting
      // fixes a deployment.
      await expectLater(
        counting.intake.run(),
        throwsA(
          isA<IntakeException>().having(
            (stopped) => stopped.failure,
            'failure',
            IntakeFailure.unreadable,
          ),
        ),
      );
      expect(counting.waited, isEmpty);
    });
  });
}
