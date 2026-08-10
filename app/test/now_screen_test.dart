// The front screen: the four states switched between, every project at once unless the person
// says otherwise, and a floor that is never swapped while they are standing on it.

import 'package:amenbo_viewer/cloudflare_intake.dart';
import 'package:amenbo_viewer/now_screen.dart';
import 'package:amenbo_viewer/settings.dart';
import 'package:amenbo_viewer/state_band.dart';
import 'package:amenbo_viewer/store/backlog_queries.dart';
import 'package:amenbo_viewer/store/backlog_store.dart';
import 'package:amenbo_viewer/ui/task_row.dart';
import 'package:amenbo_viewer/ui/theme.dart';
import 'package:amenbo_viewer/ui/time.dart';
import 'package:amenbo_viewer/ui/tokens.dart';
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
  late List<TaskQuery> sinced;

  setUp(() {
    store = BacklogStore.openInMemory();
    arrivals = Arrivals();
    opened = [];
    sinced = [];
  });
  tearDown(() {
    arrivals.dispose();
    store.close();
  });

  // The clock this screen writes is the phone's, so which one the phone was set to is part of the
  // harness rather than whatever a test machine happens to default to.
  Widget screen({
    Future<void> Function()? take,
    IntakeFailure? failure,
    DoneWindow doneWindow = DoneWindow.sevenDays,
    bool hours24 = true,
  }) => MaterialApp(
    localizationsDelegates: Words.localizationsDelegates,
    supportedLocales: Words.supportedLocales,
    theme: viewerTheme(Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(alwaysUse24HourFormat: hours24),
      child: NowScreen(
        store: store,
        take: take,
        failure: failure,
        arrivals: arrivals,
        doneWindow: doneWindow,
        clock: () => today,
        onOpen: (line) => opened.add(line.id),
        onSince: sinced.add,
      ),
    ),
  );

  group('what the switch says', () {
    test('a state is named and counted in one', () {
      expect(
        NowScreen.tab(words, TaskState.todo, const Counted(3, false)),
        'To do 3',
      );
    });

    test('a count that stopped counting says so instead of lying', () {
      // `999+` is not a number, so nothing in any language can agree with it. It arrives as text.
      expect(
        NowScreen.tab(
          words,
          TaskState.finished,
          const Counted(Counted.cap, true),
        ),
        'Done 999+',
      );
    });
  });

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

    testWidgets('the hour is written the way the phone writes hours', (
      tester,
    ) async {
      store.setMeta(MetaKey.fetchedAt, stamp(DateTime(2026, 8, 9, 12, 34)));
      await tester.pumpWidget(screen(hours24: false));

      // The phone's own switch decides, not the language's habit — and English, left alone, asks
      // for twelve hours. The gap before PM is the narrow one the language's data asks for.
      expect(find.text('Taken 12:34\u202fPM'), findsOneWidget);
    });

    testWidgets('a picture from another day is dated, not just clocked', (
      tester,
    ) async {
      // The line is all a phone out of signal has to judge what it is reading by, and an hour on
      // its own reads as this morning's however many nights ago it was taken.
      for (final (taken, said) in [
        (DateTime(2026, 8, 8, 9, 14), 'Taken yesterday 09:14'),
        (DateTime(2026, 8, 2, 9, 14), 'Taken Aug 2 09:14'),
        (DateTime(2025, 12, 30, 9, 14), 'Taken Dec 30, 2025 09:14'),
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

  group('the four states, switched between', () {
    testWidgets('every state is on the switch, with how many are in it', (
      tester,
    ) async {
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, status: 'in_progress')),
        BacklogChange.put('task', 2, task(id: 2, status: 'blocked')),
        BacklogChange.put('task', 3, task(id: 3)),
      ]);

      await tester.pumpWidget(screen());

      // Including the one with nothing in it: a state is not on the switch because it has rows,
      // and "0 blocked" is the answer somebody came to read.
      expect(
        find.text(
          NowScreen.tab(words, TaskState.todo, const Counted(1, false)),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          NowScreen.tab(words, TaskState.inProgress, const Counted(1, false)),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          NowScreen.tab(words, TaskState.blocked, const Counted(1, false)),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          NowScreen.tab(words, TaskState.finished, const Counted(0, false)),
        ),
        findsOneWidget,
      );
    });

    testWidgets('it opens on what is next, and the rest is one press away', (
      tester,
    ) async {
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, title: 'これから')),
        BacklogChange.put(
          'task',
          2,
          task(id: 2, title: 'いま動いている', status: 'in_progress'),
        ),
      ]);

      await tester.pumpWidget(screen());
      expect(find.text('これから'), findsOneWidget);
      expect(find.text('いま動いている'), findsNothing);

      await tester.tap(
        find.text(
          NowScreen.tab(words, TaskState.inProgress, const Counted(1, false)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('いま動いている'), findsOneWidget);
      expect(find.text('これから'), findsNothing);
    });

    testWidgets('a row waiting on something stays in todo and says so', (
      tester,
    ) async {
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
          .inState(TaskState.todo, today: today)
          .singleWhere((row) => row.id == 5);
      expect(find.text(stallReason(face, line, today: today)!), findsOneWidget);
      // Both rows are here — the one that can be started is not lifted out of the list, it is
      // simply the one with no waiting mark on it.
      expect(find.byType(TaskRow), findsNWidgets(2));
    });

    testWidgets('a day that has not come is a reason like any other', (
      tester,
    ) async {
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, startOn: '2026-09-01')),
      ]);

      await tester.pumpWidget(screen());

      // Even the one stall nobody has to do anything about: a row that says nothing about why it
      // is waiting is the row that wastes its second line.
      expect(find.textContaining('Starts'), findsOneWidget);
    });

    testWidgets('only the rows in progress carry a time', (tester) async {
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
      final when = find.text(
        relativeTime(face, DateTime.parse(moved), now: today),
      );
      // Not on the state it opens on.
      expect(when, findsNothing);

      await tester.tap(
        find.text(
          NowScreen.tab(words, TaskState.inProgress, const Counted(1, false)),
        ),
      );
      await tester.pumpAndSettle();
      expect(when, findsOneWidget);
    });

    testWidgets('the finished state reaches as far as the setting says', (
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
        // So the phone is not one with nothing on it, which is a screen of its own.
        BacklogChange.put('task', 2, task(id: 2)),
      ]);

      Future<void> openFinished(WidgetTester tester, int count) async {
        await tester.tap(
          find.text(
            NowScreen.tab(words, TaskState.finished, Counted(count, false)),
          ),
        );
        await tester.pumpAndSettle();
      }

      // A week back does not reach it, so the state is empty and says so.
      await tester.pumpWidget(screen());
      await openFinished(tester, 0);
      expect(find.text('せんげつ終わった'), findsNothing);
      expect(find.text(words.nothingInState), findsOneWidget);

      await tester.pumpWidget(screen(doneWindow: DoneWindow.thirtyDays));
      await openFinished(tester, 1);
      // The reach is written above the rows, or the setting would look like it missed.
      expect(find.text(words.bundleFinishedWithin(30)), findsOneWidget);
      expect(find.text('せんげつ終わった'), findsOneWidget);
    });

    testWidgets('no cut-off says nothing about a reach', (tester) async {
      store.applyPage([
        BacklogChange.put(
          'task',
          1,
          task(
            id: 1,
            status: 'done',
            // Long past any cut-off: only "everything" holds it.
            completedAt: '2025-01-01T00:00:00Z',
          ),
        ),
        BacklogChange.put('task', 2, task(id: 2)),
      ]);

      await tester.pumpWidget(screen(doneWindow: DoneWindow.everything));
      await tester.tap(
        find.text(
          NowScreen.tab(words, TaskState.finished, const Counted(1, false)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(words.bundleFinishedWithin(30)), findsNothing);
      expect(find.byType(TaskRow), findsOneWidget);
    });

    testWidgets('one state is read to its end, not handed to another face', (
      tester,
    ) async {
      store.applyPage([
        for (var id = 1; id <= Windows.list + 3; id++)
          BacklogChange.put('task', id, task(id: id, title: 'しごと $id')),
      ]);

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.text('しごと ${Windows.list + 3}'), findsNothing);

      // Reaching the bottom is the whole of asking for more. The list being read is named, or
      // the switch and the row of states are scrollables too.
      await tester.scrollUntilVisible(
        find.text('しごと ${Windows.list + 3}'),
        400,
        scrollable: find
            .descendant(
              of: find.byType(TabBarView),
              matching: find.byType(Scrollable),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(find.text('しごと ${Windows.list + 3}'), findsOneWidget);
    });

    testWidgets('a state with nothing in it says so, quietly', (tester) async {
      store.applyPage([BacklogChange.put('task', 1, task(id: 1))]);

      await tester.pumpWidget(screen());
      await tester.tap(
        find.text(
          NowScreen.tab(words, TaskState.blocked, const Counted(0, false)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(words.nothingInState), findsOneWidget);
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

    testWidgets('a number is pressed with a thumb, so it is a thumb wide', (
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
      final label = NowScreen.moved(
        words,
        Moved.finished,
        const Counted(1, false),
      );

      expect(
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.text(label),
                    matching: find.byType(InkWell),
                  )
                  .first,
            )
            .height,
        greaterThanOrEqualTo(Layout.touch),
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
              onSince: (_) {},
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: 'nothing broke at $scale');
    }
  });
}
