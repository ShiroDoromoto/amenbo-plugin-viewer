// What CI actually proves at this stage: the app boots, on its own, with no Amenbo and no
// plugin anywhere near it. That independence is the requirement these tests exist to keep —
// the moment a test needs a snapshot from somewhere, the app has stopped being verifiable on
// its own and the store release is coupled to two others.

import 'package:amenbo_viewer/l10n/words.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amenbo_viewer/main.dart';
import 'package:amenbo_viewer/pairing_guide.dart';
import 'package:amenbo_viewer/pairing_store.dart';
import 'package:amenbo_viewer/settings.dart';
import 'package:amenbo_viewer/store/backlog_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'words_fixture.dart';

/// Settings with nothing behind them. The app boots the same way whether the choices came off the
/// device or are the defaults, and the boot is what is being checked here.
SettingsController unkeptSettings() => SettingsController(UnkeptSettings());

final aPairing = Pairing(
  url: Uri.parse('https://amenbo.example.workers.dev'),
  readToken: 'cmVhZC10b2tlbg',
  encryptionKey: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
);

/// Presses the one button the screen has, which on an iPhone sits under two cards.
Future<void> tapTheAction(WidgetTester tester) async {
  final button = find.text(
    pairingRouteWords(words, PairingRoute.cloudflare).action!,
  );
  await tester.scrollUntilVisible(button, 200);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

/// The guide as a screen on its own, with the camera stood in for.
Widget guide({
  TargetPlatform platform = TargetPlatform.iOS,
  ValueChanged<Pairing>? onPaired,
  Future<Pairing?> Function(BuildContext context)? readACode,
}) => MaterialApp(
  localizationsDelegates: Words.localizationsDelegates,
  supportedLocales: Words.supportedLocales,
  theme: ThemeData(platform: platform),
  home: PairingGuideScreen(
    appName: 'Amenbo Viewer',
    onPaired: onPaired ?? (_) {},
    readACode: readACode ?? (_) async => null,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The whole app, on a phone that has never been paired and holds nothing.
  Widget app(SettingsController settings) {
    FlutterSecureStorage.setMockInitialValues({});
    final store = BacklogStore.openInMemory();
    addTearDown(store.close);
    return AmenboViewerApp(store: store, settings: settings);
  }

  testWidgets('the app boots with nothing else present', (tester) async {
    await tester.pumpWidget(app(unkeptSettings()));
    await tester.pumpAndSettle();

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text(AmenboViewerApp.title), findsOneWidget);
  });

  testWidgets('an unpaired app explains itself instead of failing', (
    tester,
  ) async {
    await tester.pumpWidget(app(unkeptSettings()));
    await tester.pumpAndSettle();

    // Not an error, not a spinner, not a plausible empty backlog — a screen that looked
    // finished would make "no tasks" and "not set up yet" the same picture.
    expect(find.text(words.guideHeading), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('the app wears the brightness that was chosen', (tester) async {
    final settings = unkeptSettings();
    await tester.pumpWidget(app(settings));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );

    settings.setAppearance(Appearance.dark);
    await tester.pump();

    // The choice is made on a screen two pushes down, so the app has to be listening — otherwise
    // it takes effect on the next launch and reads as a setting that did nothing.
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
  });

  testWidgets('the steps are the ones the person can actually take', (
    tester,
  ) async {
    await tester.pumpWidget(guide());

    for (final step in pairingRouteWords(
      words,
      PairingRoute.cloudflare,
    ).steps) {
      expect(find.text(step), findsOneWidget);
    }
  });

  testWidgets('only the one thing this phone can do is pressable', (
    tester,
  ) async {
    await tester.pumpWidget(guide());

    // The iCloud route's whole setup is on the Mac. A button beside it would read as the app
    // being broken rather than as the next step being somewhere else.
    expect(find.byType(FilledButton), findsOneWidget);
    expect(
      find.text(pairingRouteWords(words, PairingRoute.cloudflare).action!),
      findsOneWidget,
    );
    expect(pairingRouteWords(words, PairingRoute.iCloud).action, isNull);
  });

  testWidgets('the button opens the camera on the code', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: Words.localizationsDelegates,
        supportedLocales: Words.supportedLocales,
        home: PairingGuideScreen(appName: 'Amenbo Viewer', onPaired: (_) {}),
      ),
    );

    await tapTheAction(tester);

    // The reason for the camera comes before the camera — the scanning screen's own rule, and
    // the default way in has to be the one that carries it.
    expect(find.text(words.pairHeading), findsOneWidget);
  });

  testWidgets('a code that read hands the pairing up and says nothing else', (
    tester,
  ) async {
    Pairing? handed;
    await tester.pumpWidget(
      guide(onPaired: (p) => handed = p, readACode: (_) async => aPairing),
    );

    await tapTheAction(tester);

    expect(handed, aPairing);
    // The guide is still the screen. What replaces it is the root's judgement, and deciding it
    // here as well would put the same decision in two places.
    expect(find.byType(PairingGuideScreen), findsOneWidget);
  });

  testWidgets('backing out of the camera changes nothing', (tester) async {
    var handed = 0;
    await tester.pumpWidget(
      guide(onPaired: (_) => handed += 1, readACode: (_) async => null),
    );

    await tapTheAction(tester);

    expect(handed, 0);
  });

  group('which routes a phone is offered', () {
    // The iCloud route is not a preference — it is a capability. Only the iPhone has one, so
    // offering it anywhere else would be an instruction that cannot be followed.
    test('an iPhone gets both', () {
      expect(PairingRoute.forPlatform(TargetPlatform.iOS), [
        PairingRoute.iCloud,
        PairingRoute.cloudflare,
      ]);
    });

    test('an Android phone gets Cloudflare alone', () {
      expect(PairingRoute.forPlatform(TargetPlatform.android), [
        PairingRoute.cloudflare,
      ]);
    });
  });

  testWidgets('an Android phone is not told to open a folder it cannot open', (
    tester,
  ) async {
    await tester.pumpWidget(guide(platform: TargetPlatform.android));

    expect(
      find.text(pairingRouteWords(words, PairingRoute.iCloud).name),
      findsNothing,
    );
    expect(
      find.text(pairingRouteWords(words, PairingRoute.cloudflare).name),
      findsOneWidget,
    );
  });
}
