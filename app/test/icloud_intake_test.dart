// The iCloud route, walked over a folder written by hand: the drop is the whole truth there, so
// what is tested is a pass over it — what lands, what is forgotten, and what stops the pass.

import 'dart:async';
import 'dart:convert';

import 'package:amenbo_viewer/cloudflare_intake.dart';
import 'package:amenbo_viewer/icloud_intake.dart';
import 'package:amenbo_viewer/store/backlog_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late BacklogStore store;
  late _Drop drop;

  setUp(() {
    store = BacklogStore.openInMemory();
    drop = _Drop();
  });
  tearDown(() => store.close());

  ICloudIntake intake() => ICloudIntake(store: store, drop: drop);

  test(
    'a folder the PC has not placed anything in is nothing to read',
    () async {
      final report = await intake().run();

      expect(report.alreadyLevel, isTrue);
      expect(report.records, 0);
      expect(store.heldKeys(), isEmpty);
    },
  );

  test('iCloud being off is reported as the place not being reached', () async {
    drop.reachable = false;

    await expectLater(
      intake().run(),
      throwsA(
        isA<IntakeException>().having(
          (thrown) => thrown.failure,
          'failure',
          IntakeFailure.unreachable,
        ),
      ),
    );
  });

  test(
    'what the folder holds lands as rows, and the version with it',
    () async {
      drop.place(version: 12);
      drop.put('task/1', {'id': 1, 'title': 'よむ', 'status': 'todo'});
      drop.put('task/2', {'id': 2, 'title': 'かく', 'status': 'done'});

      final report = await intake().run();

      expect(report.records, 2);
      expect(store.heldKeys(), {'task/1', 'task/2'});
      expect(store.meta(MetaKey.version), '12');
      expect(store.meta(MetaKey.specVersion), '$contractVersion');
    },
  );

  test('a row the folder no longer holds is forgotten', () async {
    drop.place(version: 1);
    drop.put('task/1', {'id': 1, 'title': 'のこる', 'status': 'todo'});
    drop.put('task/2', {'id': 2, 'title': 'きえる', 'status': 'todo'});
    await intake().run();

    // The PC removed one. On this route that is the file being gone, and nothing else says so.
    drop.remove('task/2');
    drop.place(version: 2);
    await intake().run();

    expect(store.heldKeys(), {'task/1'});
  });

  test('a version that has not moved is not read again', () async {
    drop.place(version: 5);
    drop.put('task/1', {'id': 1, 'title': 'いちど', 'status': 'todo'});
    await intake().run();

    final read = drop.reads;
    final report = await intake().run();

    expect(report.alreadyLevel, isTrue);
    // The meta was asked for and nothing else was.
    expect(drop.reads, read + 1);
  });

  test('a device holding nothing reads even at the same version', () async {
    drop.place(version: 5);
    drop.put('task/1', {'id': 1, 'title': 'もういちど', 'status': 'todo'});
    await intake().run();
    store.wipe();

    final report = await intake().run();

    expect(report.records, 1);
    expect(store.heldKeys(), {'task/1'});
  });

  test('a folder written to a newer contract is refused whole', () async {
    drop.place(version: 1, specVersion: contractVersion + 1);
    drop.put('task/1', {'id': 1, 'title': 'あたらしい', 'status': 'todo'});

    await expectLater(
      intake().run(),
      throwsA(
        isA<IntakeException>().having(
          (thrown) => thrown.failure,
          'failure',
          IntakeFailure.tooNew,
        ),
      ),
    );
    expect(store.heldKeys(), isEmpty);
  });

  test('a record filed under a name that is not its own stops the pass', () async {
    drop.place(version: 1);
    // Written as task/1, put where task/9 belongs. Nothing here is sealed, so the file's place
    // and the name inside it are all there is to compare.
    drop.files['records/task/9.json'] = jsonEncode({
      'k': 'task/1',
      'op': 'put',
      'r': {'id': 1, 'title': 'なりすまし', 'status': 'todo'},
    });

    await expectLater(
      intake().run(),
      throwsA(
        isA<IntakeException>().having(
          (thrown) => thrown.failure,
          'failure',
          IntakeFailure.unreadable,
        ),
      ),
    );
    // No version, so the next round reads the folder again rather than trusting a half pass.
    expect(store.meta(MetaKey.version), isNull);
  });

  test('a record with no row in it stops the pass', () async {
    drop.place(version: 1);
    // What a sealed record looks like from here: a key, an op, and nothing this route reads.
    drop.files['records/task/1.json'] = jsonEncode({
      'k': 'task/1',
      'op': 'put',
      'n': 'a-nonce',
      'c': 'a-ciphertext',
    });

    await expectLater(
      intake().run(),
      throwsA(
        isA<IntakeException>().having(
          (thrown) => thrown.failure,
          'failure',
          IntakeFailure.unreadable,
        ),
      ),
    );
    expect(store.meta(MetaKey.version), isNull);
  });

  test('a read that never comes back is given up on, not waited on', () async {
    drop.place(version: 1);
    drop.put('task/1', {'id': 1, 'title': 'とどかない', 'status': 'todo'});
    // Airplane mode, from the reader's side: the file is listed, its contents are elsewhere, and
    // there is nobody to fetch them from.
    drop.stall = true;

    final waiting = ICloudIntake(
      store: store,
      drop: drop,
      timeout: const Duration(milliseconds: 20),
    );

    await expectLater(
      waiting.run(),
      throwsA(
        isA<IntakeException>().having(
          (thrown) => thrown.failure,
          'failure',
          IntakeFailure.unreachable,
        ),
      ),
    );
    // The same limit went down to the read itself, so the one left behind ends too.
    expect(drop.asked, const Duration(milliseconds: 20));
  });

  test('how far the pass has got is reported as it goes', () async {
    drop.place(version: 3);
    for (var id = 1; id <= 3; id++) {
      drop.put('task/$id', {'id': id, 'title': 'み$id', 'status': 'todo'});
    }

    final reached = <IntakeProgress>[];
    await intake().run(watching: reached.add);

    expect(reached.first.records, 0);
    expect(reached.first.target, 3);
    expect(reached.last.records, 3);
    expect(reached.last.through, 1);
  });
}

/// A drop written by hand: paths to text, and a count of what was read out of it.
class _Drop implements BacklogDrop {
  final files = <String, String>{};
  var reachable = true;
  var reads = 0;

  /// A record whose contents are not on the device, with nobody to fetch them from: the read is
  /// handed out and never answered.
  var stall = false;

  /// The limit the last read was handed.
  Duration? asked;

  /// Writes `meta.json`, which is what says the folder has been placed into at all.
  void place({required int version, int specVersion = contractVersion}) {
    files[ICloudIntake.metaName] = jsonEncode({
      'spec_v': specVersion,
      'version': version,
      'placed_at': '2026-08-09T00:00:00Z',
    });
  }

  /// One record, written the way the PC writes it: the key, the op, and the row as it is.
  void put(String key, Map<String, Object?> row) {
    files['${ICloudIntake.recordsDir}/$key.json'] = jsonEncode({
      'k': key,
      'op': 'put',
      'r': row,
    });
  }

  void remove(String key) =>
      files.remove('${ICloudIntake.recordsDir}/$key.json');

  @override
  Future<bool> available() async => reachable;

  @override
  Future<List<DropEntry>> entriesIn(String path, {Duration? within}) async {
    final under = path.isEmpty ? '' : '$path/';
    final entries = <String, bool>{};
    for (final name in files.keys) {
      if (!name.startsWith(under)) continue;
      final rest = name.substring(under.length);
      final slash = rest.indexOf('/');
      entries[slash < 0 ? rest : rest.substring(0, slash)] = slash >= 0;
    }
    return [
      for (final entry in entries.entries)
        DropEntry(entry.key, isDirectory: entry.value),
    ];
  }

  @override
  Future<String?> readText(String path, {Duration? within}) async {
    reads += 1;
    // The iOS side is handed the same limit the pass holds, which is what lets it call its own
    // read off rather than leaving one pinned behind a reader that stopped waiting.
    asked = within;
    if (stall && path != ICloudIntake.metaName) {
      return Completer<String?>().future;
    }
    return files[path];
  }
}
