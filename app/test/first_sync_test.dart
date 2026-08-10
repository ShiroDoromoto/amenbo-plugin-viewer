// The wait itself is what is under test here, so the round is a function the test drives step by
// step: what the person sees between the first page and the last is the whole reason this screen
// exists, and a round that finished before the screen was pumped would show none of it.

import 'dart:async';

import 'package:amenbo_viewer/l10n/words.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amenbo_viewer/cloudflare_intake.dart';
import 'package:amenbo_viewer/first_sync.dart';

import 'words_fixture.dart';

/// A round the test moves by hand.
class Round {
  final _finished = Completer<IntakeReport>();
  late void Function(IntakeProgress reached) _watching;

  Future<IntakeReport> take(void Function(IntakeProgress reached) watching) {
    _watching = watching;
    return _finished.future;
  }

  void reached(int records, {int seq = 0, int target = 100}) =>
      _watching(IntakeProgress(records: records, seq: seq, target: target));

  void finish(int records) => _finished.complete(
    IntakeReport(records: records, pages: 1, seq: 100, startedOver: false),
  );

  void stop(IntakeFailure failure) =>
      _finished.completeError(IntakeException(failure));
}

/// A round that fails once and then succeeds, so the resume can be walked.
class Flaky {
  final rounds = <Round>[];

  Future<IntakeReport> take(void Function(IntakeProgress reached) watching) {
    final round = Round();
    rounds.add(round);
    return round.take(watching);
  }
}

void main() {
  /// Every buzz the app asked the phone for.
  late List<String> felt;

  setUp(() {
    felt = [];
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            felt.add('${call.arguments}');
          }
          return null;
        });
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  Future<IntakeReport? Function()> open(
    WidgetTester tester,
    TakeTheBacklog take,
  ) async {
    IntakeReport? finished;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: Words.localizationsDelegates,
        supportedLocales: Words.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              finished = await Navigator.of(context).push<IntakeReport>(
                MaterialPageRoute(builder: (_) => FirstSyncScreen(take: take)),
              );
            },
            child: const Text('sync'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('sync'));
    // Not pumpAndSettle: the screen opens on an indeterminate bar, which by design never stops
    // moving, so settling is a thing this state never does.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return () => finished;
  }

  test('every way a round can stop has a line of its own', () {
    // A single "something went wrong" would send everybody to the same next step, and only one
    // of the five would be at the right one.
    final said = {
      for (final failure in IntakeFailure.values) whatStopped(words, failure),
    };

    expect(said, hasLength(IntakeFailure.values.length));
    expect(said.any((line) => line.isEmpty), isFalse);
  });

  testWidgets('the count climbs with what has landed', (tester) async {
    final round = Round();
    await open(tester, round.take);

    // Asked, not answered. An empty backlog and a place that has not spoken yet look nothing
    // alike to someone waiting.
    expect(find.text(words.firstSyncOpening), findsOneWidget);

    round.reached(0, seq: 0);
    await tester.pump();
    round.reached(800, seq: 25);
    await tester.pump();

    expect(find.text(words.firstSyncTaken(800)), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.25,
    );
  });

  testWidgets('a place that has spoken is not a record that has landed', (
    tester,
  ) async {
    final round = Round();
    await open(tester, round.take);

    // Where the whole wait is actually spent: a backlog that fits in one page has nothing to
    // report until that page is written, so this is the only thing the screen is told.
    round.reached(0, seq: 0, target: 27);
    await tester.pump();

    expect(find.text(words.firstSyncOpening), findsOneWidget);
    expect(find.text(words.firstSyncTaken(0)), findsNothing);
    // And the bar goes on moving rather than standing at a zero it cannot leave.
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );
  });

  testWidgets('finishing buzzes once and gets out of the way', (tester) async {
    final round = Round();
    final finished = await open(tester, round.take);

    round.reached(2400, seq: 100);
    await tester.pump();
    round.finish(2400);
    await tester.pumpAndSettle();

    // No screen saying it worked: what the person came for is the backlog, and the way to show
    // them the backlog is to leave.
    expect(find.byType(FirstSyncScreen), findsNothing);
    expect(finished()?.records, 2400);
    expect(felt.length, 1);
  });

  testWidgets('a round that stopped says what to do about it', (tester) async {
    final round = Round();
    await open(tester, round.take);

    round.reached(120, seq: 5);
    await tester.pump();
    round.stop(IntakeFailure.unreachable);
    await tester.pumpAndSettle();

    expect(find.text(words.stopUnreachable), findsOneWidget);
    expect(find.textContaining('Nothing was lost'), findsOneWidget);
    expect(find.text(words.tryAgain), findsOneWidget);
    // Nothing was celebrated, so nothing was felt.
    expect(felt, isEmpty);
  });

  testWidgets('a revoked phone is not told to try again forever', (
    tester,
  ) async {
    final round = Round();
    await open(tester, round.take);

    round.stop(IntakeFailure.refused);
    await tester.pumpAndSettle();

    // Retrying a refusal cannot work — the way out is the PC, so there is no button offering it.
    expect(find.textContaining('fresh code from the PC'), findsOneWidget);
    expect(find.text(words.tryAgain), findsNothing);
    // And nothing is left saying it carries on, because it does not carry on until the PC hands
    // out a new code.
    expect(find.text(words.firstSyncCarriesOn), findsNothing);
  });

  testWidgets('an app the place has outgrown is not offered a retry either', (
    tester,
  ) async {
    final round = Round();
    await open(tester, round.take);

    round.stop(IntakeFailure.tooNew);
    await tester.pumpAndSettle();

    expect(find.textContaining('Update this app'), findsOneWidget);
    expect(find.text(words.tryAgain), findsNothing);
  });

  testWidgets('trying again carries on rather than counting back down', (
    tester,
  ) async {
    final flaky = Flaky();
    await open(tester, flaky.take);

    flaky.rounds[0].reached(800, seq: 30);
    await tester.pump();
    flaky.rounds[0].stop(IntakeFailure.unreachable);
    await tester.pumpAndSettle();

    await tester.tap(find.text(words.tryAgain));
    await tester.pumpAndSettle();

    // The second round starts from the cursor, so its own count starts at zero. What the person
    // is watching is how much is on the phone, which never goes backwards.
    flaky.rounds[1].reached(0, seq: 30);
    await tester.pump();
    expect(find.text(words.firstSyncTaken(800)), findsOneWidget);

    flaky.rounds[1].reached(200, seq: 60);
    await tester.pump();
    expect(find.text(words.firstSyncTaken(1000)), findsOneWidget);
  });
}
