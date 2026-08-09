// Setup is the whole of what this phone is ever configured with, so what these check is the way
// out of every place someone can get stuck: before the permission sheet, after it was refused,
// and after a code that turned out to be something else. A real camera can say none of that.

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amenbo_viewer/pairing_code.dart';
import 'package:amenbo_viewer/pairing_scan.dart';
import 'package:amenbo_viewer/pairing_store.dart';

/// A camera that reports what it was asked for and shows whatever it is told to.
class FakeCamera implements Camera {
  FakeCamera({this.access = CameraAccess.granted, this.picture});

  final CameraAccess access;

  /// What a chosen picture turns out to hold. Null stands for the person backing out of the
  /// picker; a [PairingCodeException] for a picture with no code in it.
  final Object? picture;

  int asked = 0;
  int sentToSettings = 0;
  int pictures = 0;

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

  @override
  Future<String?> readAPicture() async {
    pictures++;
    final picture = this.picture;
    if (picture is PairingCodeException) throw picture;
    return picture as String?;
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
    expect(find.text(PairingScanScreen.why), findsOneWidget);

    await turnOnTheCamera(tester);

    expect(camera.asked, 1);
    expect(find.text(PairingScanScreen.inFrame), findsOneWidget);
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
    expect(find.text(PairingScanScreen.inFrame), findsNothing);
    expect(find.textContaining('not an amenbo pairing code'), findsOneWidget);
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

  group('when the camera is refused', () {
    testWidgets('both ways on are offered', (tester) async {
      final camera = FakeCamera(access: CameraAccess.refused);
      await open(tester, camera);
      await turnOnTheCamera(tester);

      expect(find.text(PairingScanScreen.refused), findsOneWidget);

      // The settings are one way back. The picture needs no permission at all, which is why it
      // is offered here and not only on the scanning screen.
      await tester.tap(find.text('Open the settings'));
      await tester.pumpAndSettle();
      expect(camera.sentToSettings, 1);
      expect(find.text(PairingScanScreen.fromAPicture), findsOneWidget);
    });

    testWidgets('a picture of the PC screen pairs the phone', (tester) async {
      final camera = FakeCamera(access: CameraAccess.refused, picture: good);
      await open(tester, camera);
      await turnOnTheCamera(tester);

      await tester.tap(find.text(PairingScanScreen.fromAPicture));
      await tester.pumpAndSettle();

      expect(camera.pictures, 1);
      expect(find.byType(PairingScanScreen), findsNothing);
      expect((await const PairingStore().read())?.readToken, 'tok');
    });

    testWidgets('a picture with no code in it says so', (tester) async {
      final camera = FakeCamera(
        access: CameraAccess.refused,
        picture: const PairingCodeException(
          CodeProblem.nothingInThePicture,
          'There is no code in that picture.',
        ),
      );
      await open(tester, camera);
      await turnOnTheCamera(tester);

      await tester.tap(find.text(PairingScanScreen.fromAPicture));
      await tester.pumpAndSettle();

      expect(find.text('There is no code in that picture.'), findsOneWidget);
    });

    testWidgets('backing out of the picker says nothing', (tester) async {
      final camera = FakeCamera(access: CameraAccess.refused);
      await open(tester, camera);
      await turnOnTheCamera(tester);

      await tester.tap(find.text(PairingScanScreen.fromAPicture));
      await tester.pumpAndSettle();

      // Nothing happened, so nothing is reported — and the button still works.
      expect(camera.pictures, 1);
      expect(find.byType(PairingScanScreen), findsOneWidget);
      await tester.tap(find.text(PairingScanScreen.fromAPicture));
      await tester.pumpAndSettle();
      expect(camera.pictures, 2);
    });
  });
}
