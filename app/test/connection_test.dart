// Reading this phone's connection off the phone. What matters here is which route the answer
// names, and that the two secrets a pairing carries are not part of the answer at all.

import 'package:amenbo_viewer/connection.dart';
import 'package:amenbo_viewer/pairing_store.dart';
import 'package:amenbo_viewer/settings.dart';
import 'package:amenbo_viewer/store/backlog_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

final pairing = Pairing(
  url: Uri.parse('https://amenbo.example.workers.dev/read'),
  readToken: 'cmVhZC10b2tlbg',
  encryptionKey: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
  label: 'iPhone',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BacklogStore store;
  late SettingsController settings;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    store = BacklogStore.openInMemory();
    settings = SettingsController(UnkeptSettings());
  });
  tearDown(() => store.close());

  /// The phone under test. [hasICloud] is the iPhone answer — the one where erasing has a route
  /// to take down as well as a copy.
  PhoneConnection phone({bool hasICloud = false}) =>
      PhoneConnection(store: store, settings: settings, hasICloud: hasICloud);

  test('a paired phone is on the Cloudflare route, named by host alone', () async {
    await const PairingStore().save(pairing);

    final connection = await phone().read();

    expect(connection.route, ConnectionRoute.cloudflare);
    // The host says which place this is. The path, the token and the key say who may read it,
    // and a screen is a thing people photograph and hand over to be looked at.
    expect(connection.host, 'amenbo.example.workers.dev');
    expect(connection.canPairAgain, isTrue);
    // The name the PC issued this phone's token under, which is what revoking it takes.
    expect(connection.label, 'iPhone');
  });

  test('a switched-off route is named as one nothing comes from', () async {
    settings.setICloud(TakeFromICloud.off);

    final connection = await phone(hasICloud: true).read();

    expect(connection.route, ConnectionRoute.iCloud);
    expect(connection.taking, isFalse);
    // Not "signed out": whether iCloud answers says nothing about a route nobody is taking, and
    // an answer here would be read as the reason nothing is arriving.
    expect(connection.iCloudAvailable, isNull);
  });

  test('a phone with no pairing is on the iCloud route', () async {
    // Nothing was ever set up here, which is the whole of what the iCloud route asks of a phone.
    final connection = await phone().read();

    expect(connection.route, ConnectionRoute.iCloud);
    expect(connection.iCloudAvailable, isFalse);
    expect(connection.canPairAgain, isFalse);
    // The container was never named, and there is no token on it to cut off by a name.
    expect(connection.label, isNull);
  });

  test('what was last taken comes off the store', () async {
    store
      ..setMeta(MetaKey.fetchedAt, '2026-08-09T03:00:00Z')
      ..setMeta(MetaKey.version, '91')
      ..setMeta(MetaKey.specVersion, '1')
      ..seq = 4207;

    final taken = (await phone().read()).lastTaken;

    expect(taken.isEmpty, isFalse);
    expect(taken.at, DateTime.utc(2026, 8, 9, 3));
    expect(taken.version, 91);
    expect(taken.seq, 4207);
    expect(taken.specVersion, 1);
  });

  test('a phone that has taken nothing says so rather than guessing', () async {
    expect((await phone().read()).lastTaken.isEmpty, isTrue);
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

    await phone().erase();

    // Half an erase — rows without a key, or a key without rows — is the state this must never
    // leave behind.
    expect(await const PairingStore().read(), isNull);
    expect(store.db.select('SELECT * FROM task'), isEmpty);
    expect(store.seq, 0);
  });

  test('erasing on a phone that reads the folder shuts that route too', () async {
    // The Cloudflare route ends with the pairing. The iCloud route has no pairing to end — the
    // folder is the Mac's and this phone reads it for having been opened once — so a copy thrown
    // away while the route stayed on would be back on the next launch.
    await phone(hasICloud: true).erase();

    expect(settings.value.iCloud, TakeFromICloud.off);
  });

  test('a phone with no folder to read is left as it was', () async {
    // Android. Switching off a route the phone does not have would be a choice nothing on this
    // build can show or undo.
    await phone().erase();

    expect(settings.value.iCloud, TakeFromICloud.on);
  });
}
