// The ten ways things can stand, told apart. What matters here is not how the band looks but
// that it never says the wrong one of them — a cause reported as an absence sends the person to
// wait on a PC that already did its part.

import 'package:amenbo_viewer/cloudflare_intake.dart';
import 'package:amenbo_viewer/state_band.dart';
import 'package:amenbo_viewer/ui/theme.dart';
import 'package:amenbo_viewer/l10n/words.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'words_fixture.dart';

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
        IntakeFailure.otherKey,
        IntakeFailure.refused,
        IntakeFailure.unreachable,
        IntakeFailure.placing,
        IntakeFailure.busy,
      ]) {
        expect(
          standingOf(anythingHere: false, failure: failure),
          isNot(Standing.waiting),
          reason: '$failure',
        );
      }
      expect(standingOf(anythingHere: false, paired: false), Standing.unpaired);
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
      // Told apart from the one above it, and that is the whole reason it exists: the records
      // are not damaged, and pairing again would hand this phone the key it already has.
      expect(
        standingOf(anythingHere: true, failure: IntakeFailure.otherKey),
        Standing.otherKey,
      );
      expect(
        standingOf(anythingHere: true, failure: IntakeFailure.refused),
        Standing.refused,
      );
      expect(
        standingOf(anythingHere: true, failure: IntakeFailure.unreachable),
        Standing.offline,
      );
      // The one cause that ends by itself. It is still said: a pull that brought nothing owes
      // the person a reason, and "offline" would send them to look at their signal.
      expect(
        standingOf(anythingHere: true, failure: IntakeFailure.placing),
        Standing.placing,
      );
      // The other cause that ends by itself, and told apart from the one above it: nothing is
      // being sent, so a line about the PC would point at the one end that is not involved.
      expect(
        standingOf(anythingHere: true, failure: IntakeFailure.busy),
        Standing.busy,
      );
    });

    test('rows with no pairing behind them say so', () {
      // The state a phone lands in when its route was taken out from under it: rows are here,
      // and there is nothing left to ask for more.
      expect(standingOf(anythingHere: true, paired: false), Standing.unpaired);
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
          standingWords(words, standing).isEmpty,
          standing == Standing.quiet,
          reason: '$standing',
        );
      }
    });
  });

  group('the band itself', () {
    Widget band(
      Standing standing, {
      bool whole = false,
      VoidCallback? onPairAgain,
    }) => MaterialApp(
      localizationsDelegates: Words.localizationsDelegates,
      supportedLocales: Words.supportedLocales,
      theme: viewerTheme(Brightness.light),
      home: Scaffold(
        body: StateBand(
          standing: standing,
          whole: whole,
          onPairAgain: onPairAgain,
        ),
      ),
    );

    testWidgets('a quiet standing takes no room', (tester) async {
      await tester.pumpWidget(band(Standing.quiet));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('offline is said without a retry to press', (tester) async {
      await tester.pumpWidget(band(Standing.offline));

      expect(find.text(standingWords(words, Standing.offline)), findsOneWidget);
      // Nothing to press: the round the person could ask for is on the front screen above this,
      // and another one happens on its own the moment it can.
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('a key that does not open offers the way out', (tester) async {
      var paired = 0;
      await tester.pumpWidget(
        band(Standing.unreadable, onPairAgain: () => paired++),
      );

      expect(
        find.text(standingWords(words, Standing.unreadable)),
        findsOneWidget,
      );
      await tester.tap(find.text(words.bandPairAgain));
      expect(paired, 1);
    });

    testWidgets('having no pairing offers reading a code', (tester) async {
      var paired = 0;
      await tester.pumpWidget(
        band(Standing.unpaired, onPairAgain: () => paired++),
      );

      // Not "pair again": this phone may never have read one.
      await tester.tap(find.text(words.bandPair));
      expect(paired, 1);
    });

    testWidgets('records sealed elsewhere are said without a way out', (
      tester,
    ) async {
      await tester.pumpWidget(band(Standing.otherKey, onPairAgain: () {}));

      expect(
        find.text(standingWords(words, Standing.otherKey)),
        findsOneWidget,
      );
      expect(
        find.text(standingDetail(words, Standing.otherKey)),
        findsOneWidget,
      );
      // Even handed one: pairing again is the way out of the state this reads like, and not of
      // this one.
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('with nothing underneath, the words take the screen', (
      tester,
    ) async {
      await tester.pumpWidget(band(Standing.waiting, whole: true));
      expect(find.text(standingWords(words, Standing.waiting)), findsOneWidget);
      expect(
        find.text(standingDetail(words, Standing.waiting)),
        findsOneWidget,
      );
    });

    test('three are lifted, and they are the three with a way out', () {
      // The cap is the point: a fourth would cost the other three the attention they are lifted
      // for. Anything that is not on this list is a state the person cannot act on from here.
      expect(Standing.values.where(standingIsLifted).toSet(), {
        Standing.unreadable,
        Standing.refused,
        Standing.unpaired,
      });
      for (final standing in Standing.values) {
        expect(
          standingMark(standing) != null,
          standingIsLifted(standing),
          reason: '$standing wears a mark exactly when it is lifted',
        );
      }
    });

    testWidgets('a lifted line does not look like a quiet one', (tester) async {
      Color surfaceOf(WidgetTester tester) =>
          (tester
                  .widgetList<Container>(find.byType(Container))
                  .firstWhere((one) => one.color != null))
              .color!;

      await tester.pumpWidget(band(Standing.offline));
      final quiet = surfaceOf(tester);
      expect(find.byType(Icon), findsNothing);

      await tester.pumpWidget(band(Standing.unreadable, onPairAgain: () {}));
      final lifted = surfaceOf(tester);

      expect(lifted, isNot(quiet));
      // Not the alarm, though: the person is being asked to do something, not told the app broke.
      expect(lifted, isNot(viewerTheme(Brightness.light).colorScheme.error));
      // The colour is never the only thing saying which of the three this is.
      expect(find.byIcon(standingMark(Standing.unreadable)!), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
    });

    testWidgets('a quiet line still says what is happening', (tester) async {
      for (final standing in [
        Standing.offline,
        Standing.waiting,
        Standing.tooNew,
      ]) {
        await tester.pumpWidget(band(standing));
        expect(
          find.text(standingWords(words, standing)),
          findsOneWidget,
          reason: 'quiet is not silent: $standing',
        );
      }
    });

    testWidgets('nothing overflows at the largest text a phone offers', (
      tester,
    ) async {
      for (final scale in [1.0, 2.0, 3.2]) {
        for (final standing in Standing.values) {
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: Words.localizationsDelegates,
              supportedLocales: Words.supportedLocales,
              theme: viewerTheme(Brightness.light),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: StateBand(standing: standing, onPairAgain: () {}),
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
