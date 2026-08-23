// The settings screen. What it offers, what it deliberately does not, and that a choice made
// here reaches the app rather than only the screen it was made on.

import 'package:amenbo_viewer/about_screen.dart';
import 'package:amenbo_viewer/connection.dart';
import 'package:amenbo_viewer/main.dart';
import 'package:amenbo_viewer/settings.dart';
import 'package:amenbo_viewer/settings_screen.dart';
import 'package:amenbo_viewer/store/backlog_store.dart';
import 'package:amenbo_viewer/l10n/words.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'connection_screen_test.dart' show FakeFacts;

import 'words_fixture.dart';

const _facts = Connection(paired: true, host: 'amenbo.example.workers.dev');

Future<SettingsController> pumpSettings(
  WidgetTester tester, {
  SettingsKeep? keep,
  ConnectionFacts? connection,
}) async {
  final settings = SettingsController(keep ?? UnkeptSettings());
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Words.localizationsDelegates,
      supportedLocales: Words.supportedLocales,
      home: SettingsScreen(
        settings: settings,
        connection: connection ?? FakeFacts(_facts),
        appName: AmenboViewerApp.title,
      ),
    ),
  );
  return settings;
}

/// The two ways out sit under the choices, which is further than a test surface is tall.
Future<void> tapRow(WidgetTester tester, Finder row) async {
  await tester.scrollUntilVisible(row, 200);
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the two choices are all there is to change', (tester) async {
    await pumpSettings(tester);

    for (final one in Refresh.values) {
      expect(find.text(refreshWords(words, one)), findsOneWidget);
    }
    for (final one in Appearance.values) {
      expect(find.text(appearanceWords(words, one)), findsOneWidget);
    }
    // Everything a person can decide here is a radio in one of those two groups, plus the one
    // switch a phone with a container gets and the two ways out. Anything else on this screen
    // would be the app's shape handed over.
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('nothing here decides where a snapshot comes from', (
    tester,
  ) async {
    await pumpSettings(tester);

    // There is one route and it is ended by erasing this phone's copy, which is a screen further
    // in. A switch here would be a second way to do it, drawn as a preference.
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('there is no interval to set', (tester) async {
    await pumpSettings(tester);

    // The app is never resident, so a number of minutes would be a number that does nothing.
    expect(find.textContaining('minute'), findsNothing);
    expect(find.textContaining('background'), findsOneWidget);
  });

  testWidgets('a choice is kept, and the app hears about it', (tester) async {
    final keep = UnkeptSettings();
    final settings = await pumpSettings(tester, keep: keep);
    var announced = 0;
    settings.addListener(() => announced += 1);

    await tester.tap(find.text(appearanceWords(words, Appearance.dark)));
    await tester.pumpAndSettle();

    expect(settings.value.appearance, Appearance.dark);
    expect(keep.read(MetaKey.appearance), Appearance.dark.stored);
    // The listener is how `AmenboViewerApp` learns to redraw dark.
    expect(announced, 1);
  });

  testWidgets('the screen shows what is chosen, not what was tapped', (
    tester,
  ) async {
    final keep = UnkeptSettings()..write(MetaKey.appearance, 'dark');
    await pumpSettings(tester, keep: keep);

    final group = tester.widget<RadioGroup<Appearance>>(
      find.byType(RadioGroup<Appearance>),
    );
    expect(group.groupValue, Appearance.dark);
  });

  testWidgets('how far back the finished ones reach is not asked here', (
    tester,
  ) async {
    await pumpSettings(tester);

    // The list holds everything the device has, and what a list holds is narrowed where it is
    // read rather than in a drawer two screens away from it.
    expect(find.textContaining('7 days'), findsNothing);
    expect(find.textContaining('30 days'), findsNothing);
  });

  testWidgets('the connection is one tap away', (tester) async {
    await pumpSettings(tester);

    await tapRow(tester, find.text(words.connectionTitle));

    expect(find.text(_facts.host!), findsOneWidget);
  });

  testWidgets('erasing the phone closes the settings behind it', (
    tester,
  ) async {
    // Both screens are standing on a backlog that has just stopped existing, so neither is a
    // place to be left.
    bool? popped;
    final settings = SettingsController(UnkeptSettings());
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: Words.localizationsDelegates,
        supportedLocales: Words.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                popped = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => SettingsScreen(
                      settings: settings,
                      connection: FakeFacts(_facts),
                      appName: AmenboViewerApp.title,
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tapRow(tester, find.text(words.connectionTitle));
    await tapRow(tester, find.text(words.erase));
    await tester.tap(find.text('Erase'));
    await tester.pumpAndSettle();

    expect(popped, isTrue);
    expect(find.text(words.settingsTitle), findsNothing);
  });

  testWidgets('what this build is, is on the screen it is asked from', (
    tester,
  ) async {
    await pumpSettings(tester);

    await tapRow(tester, find.text(words.aboutTitle));

    expect(find.text('Version $appVersionShown'), findsOneWidget);
    // The one thing a server and a phone can disagree about while both are working.
    expect(find.textContaining('data format'), findsOneWidget);
    expect(find.text(words.licences), findsOneWidget);
  });

  testWidgets('the licences are the ones built in, not fetched', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tapRow(tester, find.text(words.aboutTitle));

    await tester.tap(find.text(words.licences));
    await tester.pumpAndSettle();

    expect(find.byType(LicensePage), findsOneWidget);
  });
}
