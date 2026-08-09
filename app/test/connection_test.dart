// Reading this phone's connection off the phone. What matters here is which route the answer
// names, and that the two secrets a pairing carries are not part of the answer at all.

import 'package:amenbo_viewer/connection.dart';
import 'package:amenbo_viewer/pairing_store.dart';
import 'package:amenbo_viewer/store/backlog_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

final pairing = Pairing(
  url: Uri.parse('https://amenbo.example.workers.dev/read'),
  readToken: 'cmVhZC10b2tlbg',
  encryptionKey: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BacklogStore store;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    store = BacklogStore.openInMemory();
  });
  tearDown(() => store.close());

  test('a paired phone is on the Cloudflare route, named by host alone', () async {
    await const PairingStore().save(pairing);

    final connection = await PhoneConnection(store: store).read();

    expect(connection.route, ConnectionRoute.cloudflare);
    // The host says which place this is. The path, the token and the key say who may read it,
    // and a screen is a thing people photograph and hand over to be looked at.
    expect(connection.host, 'amenbo.example.workers.dev');
    expect(connection.canPairAgain, isTrue);
  });

  test('a phone with no pairing is on the iCloud route', () async {
    // Nothing was ever set up here, which is the whole of what the iCloud route asks of a phone.
    final connection = await PhoneConnection(store: store).read();

    expect(connection.route, ConnectionRoute.iCloud);
    expect(connection.iCloudAvailable, isFalse);
    expect(connection.canPairAgain, isFalse);
  });

  test('what was last taken comes off the store', () async {
    store
      ..setMeta(MetaKey.fetchedAt, '2026-08-09T03:00:00Z')
      ..setMeta(MetaKey.version, '91')
      ..setMeta(MetaKey.specVersion, '1')
      ..seq = 4207;

    final taken = (await PhoneConnection(store: store).read()).lastTaken;

    expect(taken.isEmpty, isFalse);
    expect(taken.at, DateTime.utc(2026, 8, 9, 3));
    expect(taken.version, 91);
    expect(taken.seq, 4207);
    expect(taken.specVersion, 1);
  });

  test('a phone that has taken nothing says so rather than guessing', () async {
    expect(
      (await PhoneConnection(store: store).read()).lastTaken.isEmpty,
      isTrue,
    );
  });

  test('erasing drops both the rows and the key that opens them', () async {
    await const PairingStore().save(pairing);
    store.applyPage([
      BacklogChange.put('task', 1, {
        'id': 1,
        'project_id': 1,
        'title': 'a task',
        'status': 'todo',
        'priority_rank': 1,
        'draft': 0,
        'created_at': '2026-08-01T00:00:00Z',
        'updated_at': '2026-08-01T00:00:00Z',
      }),
    ], seq: 7);

    await PhoneConnection(store: store).erase();

    // Half an erase — rows without a key, or a key without rows — is the state this must never
    // leave behind.
    expect(await const PairingStore().read(), isNull);
    expect(store.db.select('SELECT * FROM task'), isEmpty);
    expect(store.seq, 0);
  });
}
