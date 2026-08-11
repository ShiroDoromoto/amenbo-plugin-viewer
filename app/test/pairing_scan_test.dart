// Setup is the whole of what this phone is ever configured with, so what these check is the way
// out of every place someone can get stuck: before the permission sheet, after it was refused,
// and after a code that turned out to be something else. A real camera can say none of that.

import 'package:amenbo_viewer/l10n/words.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amenbo_viewer/pairing_code.dart';
import 'package:amenbo_viewer/pairing_scan.dart';
import 'package:amenbo_viewer/pairing_store.dart';

import 'words_fixture.dart';

/// A camera that reports what it was asked for and shows whatever it is told to.
class FakeCamera implements Camera {
  FakeCamera({this.access = CameraAccess.granted});

  final CameraAccess access;

  int asked = 0;
  int sentToSettings = 0;

  /// The live view's callback, so a test can put a code in front of the camera.
  void Function(String text)? watching;

  @override
  Future<CameraAccess> ask() async {
    asked++;
    return access;
  }

  @override
  Future<void> openTheSettings() async => sentToSettings++;

  @override
  Widget view(void Function(String text) onCode) {
    watching = onCode;
    return const ColoredBox(color: Colors.black);
  }
}

const key = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';
const good =
    '{"v":1,"url":"https://viewer.example.workers.dev","t":"tok","k":"$key"}';

/// Pushes the screen the way a caller does, and hands back what it eventually pops.
Future<Pairing? Function()> open(WidgetTester tester, FakeCamera camera) async {
  Pairing? paired;

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Words.localizationsDelegates,
      supportedLocales: Words.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            paired = await Navigator.of(context).push<Pairing>(
              MaterialPageRoute(
                builder: (_) => PairingScanScreen(camera: camera),
              ),
            );
          },
          child: const Text('pair'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('pair'));
  await tester.pumpAndSettle();

  return () => paired;
}

Future<void> turnOnTheCamera(WidgetTester tester) async {
  await tester.tap(find.text('Turn on the camera'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('the reason comes before the permission sheet', (tester) async {
    final camera = FakeCamera();
    await open(tester, camera);

    // Nothing has been asked of the OS yet, and the screen says why it is about to.
    expect(camera.asked, 0);
    expect(find.text(words.pairWhy), findsOneWidget);

    await turnOnTheCamera(tester);

    expect(camera.asked, 1);
    expect(find.text(words.pairInFrame), findsOneWidget);
  });

  testWidgets('a code that reads pairs the phone and closes', (tester) async {
    final camera = FakeCamera();
    final paired = await open(tester, camera);
    await turnOnTheCamera(tester);

    camera.watching!(good);
    await tester.pumpAndSettle();

    // No confirm step: reading it is the act. And the pairing is on the phone by the time the
    // screen is gone, so nothing downstream has to remember to write it down.
    expect(find.byType(PairingScanScreen), findsNothing);
    expect((await const PairingStore().read())?.readToken, 'tok');
    expect(paired()?.url, Uri.parse('https://viewer.example.workers.dev'));
  });

  test('every refusal has a sentence of its own, and says what to do next', () {
    // "Could not read that" is the failure this screen cannot afford: the code is plainly in
    // frame, and there is nothing left to try. Six refusals, six lines, each ending in a full
    // stop because each of them is a sentence rather than a label.
    final said = {
      for (final problem in CodeProblem.values)
        troubleWith(
          words,
          PairingCodeException(
            problem,
            saidVersion: 2,
            url: Uri.parse('http://a.b'),
          ),
        ),
    };

    expect(said, hasLength(CodeProblem.values.length));
    for (final line in said) {
      expect(line, matches(RegExp(r'\.$')));
    }
  });

  test('a refusal that lost its number still says something', () {
    // The value and the refusal travel together, so this cannot happen — but a screen that threw
    // over it would leave a person staring at a camera with nothing on it at all.
    expect(
      troubleWith(words, const PairingCodeException(CodeProblem.tooNew)),
      words.codeIncomplete,
    );
  });

  testWidgets('a code that is something else says what was different', (
    tester,
  ) async {
    final camera = FakeCamera();
    await open(tester, camera);
    await turnOnTheCamera(tester);

    camera.watching!('{"ssid":"home","pass":"a-wifi-password"}');
    await tester.pumpAndSettle();

    // Still scanning, and now saying what it read instead of stopping at "could not read that".
    expect(find.byType(PairingScanScreen), findsOneWidget);
    expect(find.text(words.pairInFrame), findsNothing);
    expect(find.textContaining('not an Amenbo pairing code'), findsOneWidget);
  });

  testWidgets('a second code is read after the first one did not fit', (
    tester,
  ) async {
    final camera = FakeCamera();
    await open(tester, camera);
    await turnOnTheCamera(tester);

    camera.watching!('not a code of ours');
    await tester.pumpAndSettle();
    camera.watching!(good);
    await tester.pumpAndSettle();

    expect(find.byType(PairingScanScreen), findsNothing);
  });

  testWidgets('a refused camera leaves the settings as the one way back', (
    tester,
  ) async {
    final camera = FakeCamera(access: CameraAccess.refused);
    await open(tester, camera);
    await turnOnTheCamera(tester);

    expect(find.text(words.pairCameraRefused), findsOneWidget);

    // One button, and it is the settings. A code read out of a photograph would put the token
    // and the key in the photo library, so that way back is not offered at all.
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.textContaining('picture'), findsNothing);

    await tester.tap(find.text('Open the settings'));
    await tester.pumpAndSettle();
    expect(camera.sentToSettings, 1);
  });
}
