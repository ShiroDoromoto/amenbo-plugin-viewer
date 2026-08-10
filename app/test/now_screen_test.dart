// The front screen: four bundles in one scroll, every project at once unless the person says
// otherwise, and a floor that is never swapped while they are standing on it.

import 'package:amenbo_viewer/cloudflare_intake.dart';
import 'package:amenbo_viewer/now_screen.dart';
import 'package:amenbo_viewer/settings.dart';
import 'package:amenbo_viewer/state_band.dart';
import 'package:amenbo_viewer/store/backlog_queries.dart';
import 'package:amenbo_viewer/store/backlog_store.dart';
import 'package:amenbo_viewer/ui/task_row.dart';
import 'package:amenbo_viewer/ui/theme.dart';
import 'package:amenbo_viewer/ui/time.dart';
import 'package:amenbo_viewer/l10n/words.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backlog_fixture.dart';
import 'words_fixture.dart';

/// One day for the whole file, so a row and the heading over it cannot disagree about it.
final today = DateTime(2026, 8, 9, 12);

/// A round that finished at a wall-clock moment, in the shape the store keeps it in. Written from
/// a local time rather than a literal, so what the screen says is the hour that was passed in
/// wherever the test is run.
String stamp(DateTime when) => when.toUtc().toIso8601String();

void main() {
  late BacklogStore store;
  late Arrivals arrivals;
  late List<int> opened;
  late List<TaskQuery> widened;
  late List<TaskQuery> sinced;

  setUp(() {
    store = BacklogStore.openInMemory();
    arrivals = Arrivals();
    opened = [];
    widened = [];
    sinced = [];
  });
  tearDown(() {
    arrivals.dispose();
    store.close();
  });

  Widget screen({
    Future<void> Function()? take,
    IntakeFailure? failure,
    DoneWindow doneWindow = DoneWindow.sevenDays,
  }) => MaterialApp(
    localizationsDelegates: Words.localizationsDelegates,
    supportedLocales: Words.supportedLocales,
    theme: viewerTheme(Brightness.light),
    home: NowScreen(
      store: store,
      take: take,
      failure: failure,
      arrivals: arrivals,
      doneWindow: doneWindow,
      clock: () => today,
      onOpen: (line) => opened.add(line.id),
      onMore: widened.add,
      onSince: sinced.add,
    ),
  );

  group('how old this is, and the way to a newer one', () {
    testWidgets('the two halves are read together, in words', (tester) async {
      var takes = 0;
      store.setMeta(MetaKey.fetchedAt, stamp(DateTime(2026, 8, 9, 12, 34)));
      await tester.pumpWidget(screen(take: () async => takes++));

      // The clock, not "3 h ago": a phone whose clock is out can still name the hour.
      expect(find.text('Taken 12:34'), findsOneWidget);
      // And what to do about it said in words rather than drawn as an arrow, so it can be read
      // before it is pressed.
      await tester.tap(find.widgetWithText(TextButton, words.refresh));
      await tester.pumpAndSettle();
      expect(takes, 1);
    });

    testWidgets('a picture from another day is dated, not just clocked', (
      tester,
    ) async {
      // The line is all a phone out of signal has to judge what it is reading by, and an hour on
      // its own reads as this morning's however many nights ago it was taken.
      for (final (taken, said) in [
        (DateTime(2026, 8, 8, 9, 14), 'Taken yesterday 09:14'),
        (DateTime(2026, 8, 2, 9, 14), 'Taken 2 Aug 09:14'),
        (DateTime(2025, 12, 30, 9, 14), 'Taken 30 Dec 2025 09:14'),
      ]) {
        store.setMeta(MetaKey.fetchedAt, stamp(taken));
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();
        expect(find.text(said), findsOneWidget);
        // Torn down between the rounds: the screen reads the stamp when it is built, so a second
        // one built over the first would still be showing the first one's hour.
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('the line is there before any round has finished', (
      tester,
    ) async {
      await tester.pumpWidget(screen(take: () async {}));

      // Nothing to date yet, and the way to go and get something is still on the screen — an
      // operation nobody can find until it has already happened is one nobody finds.
      expect(find.textContaining('Taken'), findsNothing);
      expect(find.widgetWithText(TextButton, words.refresh), findsOneWidget);
    });

    testWidgets('a phone with no route to take is offered nothing to press', (
      tester,
    ) async {
      await tester.pumpWidget(screen());

      expect(find.widgetWithText(TextButton, words.refresh), findsNothing);
    });
  });

  group('how things stand sits above the picture, never in place of it', () {
    testWidgets('offline keeps every row readable', (tester) async {
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, title: 'よめる')),
      ]);
      store.setMeta(MetaKey.fetchedAt, '2026-08-09T03:34:00Z');

      await tester.pumpWidget(screen(failure: IntakeFailure.unreachable));

      expect(find.text(standingWords(words, Standing.offline)), findsOneWidget);
      // The whole promise: what is on the device stays readable whatever the network did.
      expect(find.text('よめる'), findsOneWidget);
    });

    testWidgets('a device that never got anything is told which of the two', (
      tester,
    ) async {
      await tester.pumpWidget(screen(failure: IntakeFailure.tooNew));

      // Not "nothing has arrived yet" — something did, and this build cannot read it.
      expect(find.text(standingWords(words, Standing.tooNew)), findsOneWidget);
      expect(find.text(standingWords(words, Standing.waiting)), findsNothing);
    });
  });

  group('the four bundles, stacked', () {
    testWidgets('each one that has anything in it says how many', (
      tester,
    ) async {
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, status: 'in_progress')),
        BacklogChange.put('task', 2, task(id: 2, status: 'blocked')),
        BacklogChange.put('task', 3, task(id: 3)),
      ]);

      await tester.pumpWidget(screen());

      for (final bundle in [Bundle.moving, Bundle.stalled, Bundle.next]) {
        expect(find.text(bundleHeading(words, bundle)), findsOneWidget);
      }
      // A heading over nothing would say only that a question had been asked.
      expect(find.text(bundleHeading(words, Bundle.finished)), findsNothing);
    });

    testWidgets('a stalled row says the reason, by number', (tester) async {
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1)),
        BacklogChange.put('task', 5, task(id: 5)),
        BacklogChange.put(
          'task_dependency',
          1,
          dependency(id: 1, taskId: 5, blockedById: 1),
        ),
      ]);

      await tester.pumpWidget(screen());

      final line = store
          .bundle(Bundle.stalled, today: today)
          .rows
          .singleWhere((row) => row.id == 5);
      expect(
        find.text(stallReason(words, line, today: today)!),
        findsOneWidget,
      );
    });

    testWidgets('a day that has not come is a reason like any other', (
      tester,
    ) async {
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, startOn: '2026-09-01')),
      ]);

      await tester.pumpWidget(screen());

      // It lands in the stalled bundle, so the row owes an answer for why — even the one stall
      // nobody has to do anything about.
      expect(find.text(bundleHeading(words, Bundle.stalled)), findsOneWidget);
      expect(find.textContaining('Starts'), findsOneWidget);
    });

    testWidgets('only the moving rows carry a time', (tester) async {
      const moved = '2026-08-01T00:00:00Z';
      store.applyPage([
        BacklogChange.put(
          'task',
          1,
          task(id: 1, status: 'in_progress', updatedAt: moved),
        ),
        BacklogChange.put('task', 2, task(id: 2, updatedAt: moved)),
      ]);

      await tester.pumpWidget(screen());

      expect(
        find.text(relativeTime(words, DateTime.parse(moved), now: today)),
        findsOneWidget,
      );
    });

    testWidgets('closed work is folded away until it is asked for', (
      tester,
    ) async {
      store.applyPage([
        BacklogChange.put(
          'task',
          1,
          task(
            id: 1,
            title: 'ぜんぶ終わった',
            status: 'done',
            completedAt: '2026-08-08T00:00:00Z',
          ),
        ),
      ]);

      await tester.pumpWidget(screen());
      expect(find.text(bundleHeading(words, Bundle.finished)), findsOneWidget);
      expect(find.text('ぜんぶ終わった'), findsNothing);

      await tester.tap(find.text(bundleHeading(words, Bundle.finished)));
      await tester.pumpAndSettle();
      expect(find.text('ぜんぶ終わった'), findsOneWidget);
    });

    testWidgets('the finished bundle reaches as far as the setting says', (
      tester,
    ) async {
      store.applyPage([
        BacklogChange.put(
          'task',
          1,
          task(
            id: 1,
            title: 'せんげつ終わった',
            status: 'done',
            completedAt: '2026-07-20T00:00:00Z',
          ),
        ),
      ]);

      // A week back does not reach it, so there is no bundle at all.
      await tester.pumpWidget(screen());
      expect(find.text(bundleHeading(words, Bundle.finished)), findsNothing);

      await tester.pumpWidget(screen(doneWindow: DoneWindow.thirtyDays));
      final heading = bundleHeading(words, Bundle.finished, finishedDays: 30);
      // The heading says the reach it was read with, or the setting would look like it missed.
      expect(find.text(heading), findsOneWidget);
      await tester.tap(find.text(heading));
      await tester.pumpAndSettle();
      expect(find.text('せんげつ終わった'), findsOneWidget);
    });

    testWidgets('everything keeps the window and what is behind it', (
      tester,
    ) async {
      store.applyPage([
        for (var id = 1; id <= Windows.bundle + 3; id++)
          BacklogChange.put(
            'task',
            id,
            task(
              id: id,
              status: 'done',
              // Long past any cut-off: only "everything" holds these.
              completedAt: '2025-01-0${id % 9 + 1}T00:00:00Z',
            ),
          ),
      ]);

      await tester.pumpWidget(screen(doneWindow: DoneWindow.everything));
      final heading = bundleHeading(words, Bundle.finished, finishedDays: null);
      expect(find.text(heading), findsOneWidget);
      await tester.tap(find.text(heading));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text(NowScreen.more(words, 3)), 200);
      await tester.tap(find.text(NowScreen.more(words, 3)));
      expect(widened.single.bundle, Bundle.finished);
      // The reach travels with it: the rest of a list that stopped at a different day would not
      // be the rest of this one.
      expect(widened.single.finishedDays, isNull);
    });

    testWidgets('past the window the bundle offers the rest', (tester) async {
      store.applyPage([
        for (var id = 1; id <= Windows.bundle + 3; id++)
          BacklogChange.put('task', id, task(id: id)),
      ]);

      await tester.pumpWidget(screen());
      await tester.scrollUntilVisible(find.text(NowScreen.more(words, 3)), 200);

      await tester.tap(find.text(NowScreen.more(words, 3)));
      expect(widened.single.bundle, Bundle.next);
    });

    testWidgets('a row opens the task it names', (tester) async {
      store.applyPage([
        BacklogChange.put('task', 42, task(id: 42, title: 'ひらく')),
      ]);

      await tester.pumpWidget(screen());
      await tester.tap(find.text('ひらく'));
      expect(opened, [42]);
    });
  });

  group('projects narrow, they do not divide', () {
    setUp(
      () => store.applyPage([
        BacklogChange.put('project', 16, project(id: 16, name: 'viewer')),
        BacklogChange.put('project', 20, project(id: 20, name: 'nsys')),
        BacklogChange.put('task', 1, task(id: 1, projectId: 16)),
        BacklogChange.put('task', 2, task(id: 2, projectId: 20)),
      ]),
    );

    testWidgets('everything is stacked together, and each row says where', (
      tester,
    ) async {
      await tester.pumpWidget(screen());

      expect(find.text(words.allProjects), findsOneWidget);
      expect(find.byType(TaskRow), findsNWidgets(2));
      expect(find.text('viewer'), findsOneWidget);
      expect(find.text('nsys'), findsOneWidget);
    });

    testWidgets('choosing one narrows the list and stops repeating its name', (
      tester,
    ) async {
      await tester.pumpWidget(screen());

      await tester.tap(find.text(words.allProjects));
      await tester.pumpAndSettle();
      await tester.tap(find.text('viewer').last);
      await tester.pumpAndSettle();

      expect(find.byType(TaskRow), findsOneWidget);
      // Once only — the title. Repeating it down every row buys nothing and costs width.
      expect(find.text('viewer'), findsOneWidget);
    });

    testWidgets('one project is a title, not a menu', (tester) async {
      final alone = BacklogStore.openInMemory();
      addTearDown(alone.close);
      alone.applyPage([
        BacklogChange.put('project', 16, project(id: 16, name: 'viewer')),
        BacklogChange.put('task', 1, task(id: 1, projectId: 16)),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: Words.localizationsDelegates,
          supportedLocales: Words.supportedLocales,
          home: NowScreen(
            store: alone,
            doneWindow: DoneWindow.sevenDays,
            clock: () => today,
            onOpen: (_) {},
            onMore: (_) {},
            onSince: (_) {},
          ),
        ),
      );

      expect(find.text('viewer'), findsOneWidget);
      expect(find.byType(PopupMenuButton<int?>), findsNothing);
    });
  });

  group('the floor is not swapped while it is being read', () {
    testWidgets('rows that arrive on their own wait behind a pill', (
      tester,
    ) async {
      store.applyPage([
        BacklogChange.put(
          'task',
          1,
          task(id: 1, title: 'よんでいる', updatedAt: '2026-08-09T09:00:00Z'),
        ),
      ]);
      await tester.pumpWidget(screen());

      store.applyPage([
        BacklogChange.put(
          'task',
          2,
          task(id: 2, title: 'あとから', updatedAt: '2026-08-09T09:05:00Z'),
        ),
      ]);
      arrivals.tick();
      await tester.pumpAndSettle();

      expect(find.text('あとから'), findsNothing);
      expect(
        find.text(NowScreen.arrived(words, const Counted(1, false))),
        findsOneWidget,
      );

      await tester.tap(
        find.text(NowScreen.arrived(words, const Counted(1, false))),
      );
      await tester.pumpAndSettle();
      expect(find.text('あとから'), findsOneWidget);
      expect(find.textContaining('New activity'), findsNothing);
    });

    testWidgets('a list with nothing in it fills as the rows land', (
      tester,
    ) async {
      await tester.pumpWidget(screen());
      expect(find.text(standingWords(words, Standing.waiting)), findsOneWidget);

      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, title: 'とどいた')),
      ]);
      arrivals.tick();
      await tester.pumpAndSettle();

      // Nobody is mid-read, and a first sync is meant to be watched arriving.
      expect(find.text('とどいた'), findsOneWidget);
      expect(find.textContaining('New activity'), findsNothing);
    });

    testWidgets('rows somebody sat and watched land are not held back', (
      tester,
    ) async {
      // Pairing again from a phone that already holds a backlog. The person watched this round
      // fill a screen of its own, so a pill offering it would be offering them what they just
      // waited for.
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, title: 'まえから')),
      ]);
      await tester.pumpWidget(screen());

      store.applyPage([
        BacklogChange.put('task', 2, task(id: 2, title: 'みていた')),
      ]);
      arrivals.tick(watched: true);
      await tester.pumpAndSettle();

      expect(find.text('みていた'), findsOneWidget);
      expect(find.textContaining('New activity'), findsNothing);
    });

    testWidgets('asking for it applies it there and then', (tester) async {
      var takes = 0;
      await tester.pumpWidget(
        screen(
          take: () async {
            takes++;
            store.applyPage([
              BacklogChange.put('task', 1, task(id: 1, title: 'ひっぱった')),
            ]);
          },
        ),
      );

      await tester.tap(find.widgetWithText(TextButton, words.refresh));
      await tester.pumpAndSettle();

      expect(takes, 1);
      expect(find.text('ひっぱった'), findsOneWidget);
      expect(find.textContaining('New activity'), findsNothing);
    });

    testWidgets('a fetch that failed leaves the picture it had', (
      tester,
    ) async {
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, title: 'のこる')),
      ]);
      await tester.pumpWidget(screen(take: () async => throw Exception('off')));

      await tester.tap(find.widgetWithText(TextButton, words.refresh));
      await tester.pumpAndSettle();

      expect(find.text('のこる'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('what moved while they were away', () {
    /// The mark the previous visit left behind. Everything in this group is stamped after it.
    const lastLook = '2026-08-09T00:00:00Z';
    const after = '2026-08-09T09:00:00Z';

    testWidgets('a device nobody has opened before has nothing to say', (
      tester,
    ) async {
      store.applyPage([BacklogChange.put('task', 1, task(id: 1))]);

      await tester.pumpWidget(screen());

      expect(find.text(words.sinceLastLook), findsNothing);
    });

    testWidgets('the three numbers are counted from the last visit', (
      tester,
    ) async {
      store.setMeta(MetaKey.lastOpenedAt, lastLook);
      store.applyPage([
        BacklogChange.put(
          'task',
          1,
          task(id: 1, status: 'done', completedAt: after),
        ),
        BacklogChange.put('task', 2, task(id: 2, createdAt: after)),
        BacklogChange.put('task', 3, task(id: 3)),
        BacklogChange.put(
          'task_comment',
          1,
          comment(id: 1, taskId: 3, createdAt: after),
        ),
      ]);

      await tester.pumpWidget(screen());

      expect(find.text(words.sinceLastLook), findsOneWidget);
      for (final moved in Moved.values) {
        expect(
          find.text(NowScreen.moved(words, moved, const Counted(1, false))),
          findsOneWidget,
        );
      }
    });

    testWidgets('nothing moved is no card at all, not a card saying so', (
      tester,
    ) async {
      store.setMeta(MetaKey.lastOpenedAt, after);
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, createdAt: lastLook)),
      ]);

      await tester.pumpWidget(screen());

      expect(find.text(words.sinceLastLook), findsNothing);
      expect(
        find.textContaining(movedHeading(words, Moved.filed)),
        findsNothing,
      );
    });

    testWidgets('a number opens the list of just what it counted', (
      tester,
    ) async {
      store.setMeta(MetaKey.lastOpenedAt, lastLook);
      store.applyPage([
        BacklogChange.put(
          'task',
          1,
          task(id: 1, status: 'done', completedAt: after),
        ),
      ]);

      await tester.pumpWidget(screen());
      await tester.tap(
        find.text(
          NowScreen.moved(words, Moved.finished, const Counted(1, false)),
        ),
      );

      expect(sinced.single.moved, Moved.finished);
      // Counted from the moment the card counted from, so the list is the length of the number
      // that was pressed.
      expect(sinced.single.changedSince, isNotNull);
    });

    testWidgets('it counts inside the narrowing the screen is holding', (
      tester,
    ) async {
      store.setMeta(MetaKey.lastOpenedAt, lastLook);
      store.applyPage([
        BacklogChange.put('project', 16, project(id: 16, name: 'viewer')),
        BacklogChange.put('project', 20, project(id: 20, name: 'nsys')),
        BacklogChange.put(
          'task',
          1,
          task(id: 1, projectId: 16, createdAt: after),
        ),
        BacklogChange.put(
          'task',
          2,
          task(id: 2, projectId: 20, createdAt: after),
        ),
      ]);

      await tester.pumpWidget(screen());
      expect(
        find.text(NowScreen.moved(words, Moved.filed, const Counted(2, false))),
        findsOneWidget,
      );

      await tester.tap(find.text(words.allProjects));
      await tester.pumpAndSettle();
      await tester.tap(find.text('viewer').last);
      await tester.pumpAndSettle();

      expect(
        find.text(NowScreen.moved(words, Moved.filed, const Counted(1, false))),
        findsOneWidget,
      );
    });

    testWidgets('the mark is taken on arriving and held while reading', (
      tester,
    ) async {
      store.setMeta(MetaKey.lastOpenedAt, lastLook);
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, createdAt: after)),
      ]);

      await tester.pumpWidget(screen());
      expect(store.meta(MetaKey.lastOpenedAt), amenboStamp(today));

      // Rows landing behind the pill, and then being let in, are not a new visit: the card has to
      // still say what it said when the person started reading.
      store.applyPage([
        BacklogChange.put(
          'task',
          2,
          task(id: 2, createdAt: after, updatedAt: after),
        ),
      ]);
      arrivals.tick();
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(NowScreen.arrived(words, const Counted(1, false))),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(NowScreen.moved(words, Moved.filed, const Counted(2, false))),
        findsOneWidget,
      );
    });

    testWidgets('opening a row takes its dot away', (tester) async {
      store.setMeta(MetaKey.lastOpenedAt, lastLook);
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, updatedAt: after)),
      ]);

      await tester.pumpWidget(screen());
      expect(tester.widget<TaskRow>(find.byType(TaskRow)).unread, isTrue);

      await tester.tap(find.byType(TaskRow));
      await tester.pumpAndSettle();

      expect(tester.widget<TaskRow>(find.byType(TaskRow)).unread, isFalse);
    });
  });

  testWidgets('nothing overflows at the largest text a phone offers', (
    tester,
  ) async {
    store.setMeta(MetaKey.lastOpenedAt, '2026-07-01T00:00:00Z');
    store.applyPage([
      BacklogChange.put('project', 16, project(id: 16, name: 'viewer')),
      BacklogChange.put('project', 20, project(id: 20, name: 'nsys')),
      BacklogChange.put('task', 1, task(id: 1)),
      BacklogChange.put(
        'task',
        5,
        task(
          id: 5,
          title:
              'a backlog title long enough that it cannot possibly fit on one '
              'line even before anybody turns their text size up',
          assigneeKind: 'ai',
        ),
      ),
      BacklogChange.put(
        'task_dependency',
        1,
        dependency(id: 1, taskId: 5, blockedById: 1),
      ),
      BacklogChange.put('task_comment', 1, comment(id: 1, taskId: 5)),
    ]);

    for (final scale in [1.0, 2.0, 3.2]) {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: Words.localizationsDelegates,
          supportedLocales: Words.supportedLocales,
          theme: viewerTheme(Brightness.light),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: NowScreen(
              store: store,
              doneWindow: DoneWindow.sevenDays,
              clock: () => today,
              onOpen: (_) {},
              onMore: (_) {},
              onSince: (_) {},
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: 'nothing broke at $scale');
    }
  });
}
