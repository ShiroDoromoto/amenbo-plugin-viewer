// These run against the package's own in-memory platform, so what they check is this file's
// half of the bargain — that a pairing survives whole, that forgetting leaves nothing behind,
// and that an unpaired phone reads as unpaired rather than as a failure. Whether the entry is
// actually in the keychain is the platform's half and only a device can say.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amenbo_viewer/pairing_store.dart';
import 'package:amenbo_viewer/record_envelope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final pairing = Pairing(
    url: Uri.parse('https://amenbo.example.workers.dev'),
    readToken: 'cmVhZC10b2tlbg',
    encryptionKey: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    label: 'iPhone',
  );

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('a phone nobody has paired holds nothing', () async {
    // Not an error and not an empty backlog — the state the guide screen exists for.
    expect(await const PairingStore().read(), isNull);
  });

  test('a pairing comes back the way it went in', () async {
    const store = PairingStore();
    await store.save(pairing);

    final stored = await store.read();
    expect(stored?.url, pairing.url);
    expect(stored?.readToken, pairing.readToken);
    expect(stored?.encryptionKey, pairing.encryptionKey);
    expect(stored?.label, pairing.label);
  });

  test('a phone paired before the code carried a name stays paired', () async {
    // The entry an older build wrote has no name in it. Reading that as a broken entry would
    // unpair a phone that reads perfectly well, over a line the connection screen only displays.
    FlutterSecureStorage.setMockInitialValues({
      'pairing':
          '{"url":"https://amenbo.example.workers.dev","t":"cmVhZC10b2tlbg",'
          '"k":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}',
    });

    final stored = await const PairingStore().read();
    expect(stored?.readToken, 'cmVhZC10b2tlbg');
    expect(stored?.label, isNull);
  });

  test('the stored key opens what the PC sealed with it', () async {
    // The point of keeping the key here at all: it has to come back usable, not merely intact.
    const store = PairingStore();
    await store.save(pairing);

    final cipher = (await store.read())!.cipher();
    final record = SealedRecord.fromJson({
      'k': 'task/2812',
      'op': 'put',
      'n': 'oKGio6SlpqeoqaqrrK2ur7CxsrO0tba3',
      'c':
          'Ps5jeZVnlpRQXQGrBVnXrF6IpQ5JhHU6n_loZUhAfKQyBRPMxdifTxkI7d54tzrN'
          'J4_FemmLUQASHawJq6FQ_j2g4XFN2WvWGVaSToaUs80',
    });

    expect((await cipher.openJson(record))['id'], 2812);
  });

  test('forgetting leaves nothing to read', () async {
    const store = PairingStore();
    await store.save(pairing);
    await store.forget();

    expect(await store.read(), isNull);
  });

  test('an entry that no longer parses reads as unpaired', () async {
    FlutterSecureStorage.setMockInitialValues({'pairing': 'not json'});

    expect(await const PairingStore().read(), isNull);
  });
}
