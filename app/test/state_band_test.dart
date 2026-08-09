// The seven ways things can stand, told apart. What matters here is not how the band looks but
// that it never says the wrong one of them — a cause reported as an absence sends the person to
// wait on a PC that already did its part.

import 'package:amenbo_viewer/cloudflare_intake.dart';
import 'package:amenbo_viewer/state_band.dart';
import 'package:amenbo_viewer/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('which one is owed', () {
    test('a working device with a picture on it says nothing at all', () {
      expect(standingOf(anythingHere: true), Standing.quiet);
    });

    test('nothing here and nothing wrong is the only absence it reports', () {
      expect(standingOf(anythingHere: false), Standing.waiting);
    });

    test('every cause outranks the absence', () {
      // Saying "nothing has arrived yet" while one of these holds would be the app's one
      // outright lie: something did arrive, or something stopped it.
      for (final failure in [
        IntakeFailure.tooNew,
        IntakeFailure.unreadable,
        IntakeFailure.refused,
        IntakeFailure.unreachable,
      ]) {
        expect(
          standingOf(anythingHere: false, failure: failure),
          isNot(Standing.waiting),
          reason: '$failure',
        );
      }
      expect(
        standingOf(anythingHere: false, iCloudAvailable: false),
        Standing.noICloud,
      );
    });

    test('each failure keeps its own words', () {
      expect(
        standingOf(anythingHere: true, failure: IntakeFailure.tooNew),
        Standing.tooNew,
      );
      expect(
        standingOf(anythingHere: true, failure: IntakeFailure.unreadable),
        Standing.unreadable,
      );
      expect(
        standingOf(anythingHere: true, failure: IntakeFailure.refused),
        Standing.refused,
      );
      expect(
        standingOf(anythingHere: true, failure: IntakeFailure.unreachable),
        Standing.offline,
      );
    });

    test('being signed out is more specific than being unreachable', () {
      expect(
        standingOf(
          anythingHere: true,
          failure: IntakeFailure.unreachable,
          iCloudAvailable: false,
        ),
        Standing.noICloud,
      );
    });

    test('a place built again says nothing — the intake already handled it', () {
      // The local copy is emptied and taken from the beginning without anybody being asked, so
      // there is nothing left for a line to be about.
      expect(
        standingOf(anythingHere: true, failure: IntakeFailure.rebuilt),
        Standing.quiet,
      );
    });

    test('every standing but the quiet one has words', () {
      for (final standing in Standing.values) {
        expect(
          standingWords(standing).isEmpty,
          standing == Standing.quiet,
          reason: '$standing',
        );
      }
    });
  });

  group('the band itself', () {
    Widget band(
      Standing standing, {
      DateTime? taken,
      bool whole = false,
      VoidCallback? onPairAgain,
      VoidCallback? onOpenSettings,
    }) => MaterialApp(
      theme: viewerTheme(Brightness.light),
      home: Scaffold(
        body: StateBand(
          standing: standing,
          lastTakenAt: taken,
          whole: whole,
          onPairAgain: onPairAgain,
          onOpenSettings: onOpenSettings,
        ),
      ),
    );

    testWidgets('a quiet standing takes no room', (tester) async {
      await tester.pumpWidget(band(Standing.quiet));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('offline says when the picture under it was taken', (
      tester,
    ) async {
      final taken = DateTime(2026, 8, 9, 12, 34);
      await tester.pumpWidget(band(Standing.offline, taken: taken));

      expect(find.text(standingWords(Standing.offline)), findsOneWidget);
      // The clock, not "3 h ago": a phone whose clock is out can still name the hour.
      expect(find.text(StateBand.takenAt(taken)), findsOneWidget);
      // No dialog, no retry to press — another round happens on its own.
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('a key that does not open offers the way out', (tester) async {
      var paired = 0;
      await tester.pumpWidget(
        band(Standing.unreadable, onPairAgain: () => paired++),
      );

      expect(find.text(standingWords(Standing.unreadable)), findsOneWidget);
      await tester.tap(find.text(StateBand.pairAgain));
      expect(paired, 1);
    });

    testWidgets('a signed-out iCloud points at the OS, not at this app', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        band(Standing.noICloud, onOpenSettings: () => opened++),
      );

      await tester.tap(find.text(StateBand.openSettings));
      expect(opened, 1);
    });

    testWidgets('with nothing underneath, the words take the screen', (
      tester,
    ) async {
      await tester.pumpWidget(band(Standing.waiting, whole: true));
      expect(find.text(standingWords(Standing.waiting)), findsOneWidget);
      expect(find.text(standingDetail(Standing.waiting)), findsOneWidget);
    });

    testWidgets('nothing overflows at the largest text a phone offers', (
      tester,
    ) async {
      for (final scale in [1.0, 2.0, 3.2]) {
        for (final standing in Standing.values) {
          await tester.pumpWidget(
            MaterialApp(
              theme: viewerTheme(Brightness.light),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: StateBand(
                      standing: standing,
                      lastTakenAt: DateTime(2026, 8, 9, 12, 34),
                      onPairAgain: () {},
                      onOpenSettings: () {},
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull, reason: '$standing at $scale');
        }
      }
    });
  });
}
