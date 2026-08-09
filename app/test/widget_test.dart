// What CI actually proves at this stage: the app boots, on its own, with no amenbo and no
// plugin anywhere near it. That independence is the requirement these tests exist to keep —
// the moment a test needs a snapshot from somewhere, the app has stopped being verifiable on
// its own and the store release is coupled to two others.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amenbo_viewer/main.dart';
import 'package:amenbo_viewer/pairing_guide.dart';
import 'package:amenbo_viewer/settings.dart';

/// Settings with nothing behind them. The app boots the same way whether the choices came off the
/// device or are the defaults, and the boot is what is being checked here.
SettingsController unkeptSettings() => SettingsController(UnkeptSettings());

void main() {
  testWidgets('the app boots with nothing else present', (tester) async {
    await tester.pumpWidget(AmenboViewerApp(settings: unkeptSettings()));

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text(AmenboViewerApp.title), findsOneWidget);
  });

  testWidgets('an unpaired app explains itself instead of failing', (
    tester,
  ) async {
    await tester.pumpWidget(AmenboViewerApp(settings: unkeptSettings()));

    // Not an error, not a spinner, not a plausible empty backlog — a screen that looked
    // finished would make "no tasks" and "not set up yet" the same picture.
    expect(find.text(PairingGuideScreen.heading), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('the app wears the brightness that was chosen', (tester) async {
    final settings = unkeptSettings();
    await tester.pumpWidget(AmenboViewerApp(settings: settings));
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
    await tester.pumpWidget(
      const MaterialApp(home: PairingGuideScreen(appName: 'amenbo Viewer')),
    );

    for (final step in PairingRoute.cloudflare.steps) {
      expect(find.text(step), findsOneWidget);
    }
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
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const PairingGuideScreen(appName: 'amenbo Viewer'),
      ),
    );

    expect(find.text(PairingRoute.iCloud.name), findsNothing);
    expect(find.text(PairingRoute.cloudflare.name), findsOneWidget);
  });
}
