// The iCloud route, walked over a folder written by hand: the drop is the whole truth there, so
// what is tested is a pass over it — what lands, what is forgotten, and what stops the pass.

import 'dart:convert';

import 'package:amenbo_viewer/cloudflare_intake.dart';
import 'package:amenbo_viewer/icloud_intake.dart';
import 'package:amenbo_viewer/record_envelope.dart';
import 'package:amenbo_viewer/store/backlog_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// The same 32 bytes the envelope fixture is sealed with, so the two tests speak of one key.
const key = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';

void main() {
  late BacklogStore store;
  late _Drop drop;

  setUp(() {
    store = BacklogStore.openInMemory();
    drop = _Drop();
  });
  tearDown(() => store.close());

  ICloudIntake intake() => ICloudIntake(
    cipher: RecordCipher.fromBase64Key(key),
    store: store,
    drop: drop,
  );

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
      await drop.put('task/1', {'id': 1, 'title': 'よむ', 'status': 'todo'});
      await drop.put('task/2', {'id': 2, 'title': 'かく', 'status': 'done'});

      final report = await intake().run();

      expect(report.records, 2);
      expect(store.heldKeys(), {'task/1', 'task/2'});
      expect(store.meta(MetaKey.version), '12');
      expect(store.meta(MetaKey.specVersion), '$contractVersion');
    },
  );

  test('a row the folder no longer holds is forgotten', () async {
    drop.place(version: 1);
    await drop.put('task/1', {'id': 1, 'title': 'のこる', 'status': 'todo'});
    await drop.put('task/2', {'id': 2, 'title': 'きえる', 'status': 'todo'});
    await intake().run();

    // The PC removed one. On this route that is the file being gone, and nothing else says so.
    drop.remove('task/2');
    drop.place(version: 2);
    await intake().run();

    expect(store.heldKeys(), {'task/1'});
  });

  test('a version that has not moved is not read again', () async {
    drop.place(version: 5);
    await drop.put('task/1', {'id': 1, 'title': 'いちど', 'status': 'todo'});
    await intake().run();

    final read = drop.reads;
    final report = await intake().run();

    expect(report.alreadyLevel, isTrue);
    // The meta was asked for and nothing else was.
    expect(drop.reads, read + 1);
  });

  test('a device holding nothing reads even at the same version', () async {
    drop.place(version: 5);
    await drop.put('task/1', {'id': 1, 'title': 'もういちど', 'status': 'todo'});
    await intake().run();
    store.wipe();

    final report = await intake().run();

    expect(report.records, 1);
    expect(store.heldKeys(), {'task/1'});
  });

  test('a folder written to a newer contract is refused whole', () async {
    drop.place(version: 1, specVersion: contractVersion + 1);
    await drop.put('task/1', {'id': 1, 'title': 'あたらしい', 'status': 'todo'});

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
    // Sealed as task/1, put where task/9 belongs — which is what moving a file around looks like
    // to somebody who cannot read it.
    drop.files['records/task/9.json'] = jsonEncode(
      await _seal('task/1', {'id': 1, 'title': 'なりすまし', 'status': 'todo'}),
    );

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

  test('a record this key does not open stops the pass', () async {
    drop.place(version: 1);
    await drop.put('task/1', {'id': 1, 'title': 'ひらかない', 'status': 'todo'});

    final other = ICloudIntake(
      cipher: RecordCipher.fromBase64Key(base64Url.encode(List.filled(32, 7))),
      store: store,
      drop: drop,
    );

    await expectLater(
      other.run(),
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

  test('how far the pass has got is reported as it goes', () async {
    drop.place(version: 3);
    for (var id = 1; id <= 3; id++) {
      await drop.put('task/$id', {'id': id, 'title': 'み$id', 'status': 'todo'});
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

  /// Writes `meta.json`, which is what says the folder has been placed into at all.
  void place({required int version, int specVersion = contractVersion}) {
    files[ICloudIntake.metaName] = jsonEncode({
      'spec_v': specVersion,
      'version': version,
      'placed_at': '2026-08-09T00:00:00Z',
    });
  }

  Future<void> put(String key, Map<String, Object?> row) async {
    files['${ICloudIntake.recordsDir}/$key.json'] = jsonEncode(
      await _seal(key, row),
    );
  }

  void remove(String key) =>
      files.remove('${ICloudIntake.recordsDir}/$key.json');

  @override
  Future<bool> available() async => reachable;

  @override
  Future<List<DropEntry>> entriesIn(String path) async {
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
  Future<String?> readText(String path) async {
    reads += 1;
    return files[path];
  }
}

/// Seals one row the way the PC does — the same cipher, the record's key as associated data.
Future<Map<String, Object?>> _seal(String key, Map<String, Object?> row) async {
  final algorithm = Xchacha20.poly1305Aead();
  final nonce = List.generate(24, (at) => (at + key.hashCode) % 256);
  final box = await algorithm.encrypt(
    utf8.encode(jsonEncode(row)),
    secretKey: SecretKey(base64Url.decode(base64Url.normalize(_key))),
    nonce: nonce,
    aad: utf8.encode(key),
  );
  return {
    'k': key,
    'op': 'put',
    'n': base64Url.encode(nonce),
    'c': base64Url.encode([...box.cipherText, ...box.mac.bytes]),
  };
}

const _key = key;
