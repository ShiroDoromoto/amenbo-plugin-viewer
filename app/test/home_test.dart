// The root: which screen a phone opens on, and where the ways out of the three tabs lead.
//
// Every screen below this was built to be handed what it needs and to hand back what was pressed.
// What is checked here is only the joining — that the guide gives way once there is a way in, that
// a bundle's remainder and a number on the card arrive at the one list face carrying what was
// pressed, and that a task opens beside the list when there is width for it.

import 'dart:async';

import 'package:amenbo_viewer/cloudflare_intake.dart';
import 'package:amenbo_viewer/first_sync.dart';
import 'package:amenbo_viewer/home.dart';
import 'package:amenbo_viewer/now_screen.dart';
import 'package:amenbo_viewer/pairing_guide.dart';
import 'package:amenbo_viewer/pairing_store.dart';
import 'package:amenbo_viewer/search_screen.dart';
import 'package:amenbo_viewer/settings.dart';
import 'package:amenbo_viewer/settings_screen.dart';
import 'package:amenbo_viewer/store/backlog_queries.dart';
import 'package:amenbo_viewer/store/backlog_store.dart';
import 'package:amenbo_viewer/task_detail.dart';
import 'package:amenbo_viewer/ui/theme.dart';
import 'package:amenbo_viewer/ui/two_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backlog_fixture.dart';

final today = DateTime(2026, 8, 9, 12);

final aPairing = Pairing(
  url: Uri.parse('https://amenbo.example.workers.dev'),
  readToken: 'cmVhZC10b2tlbg',
  encryptionKey: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
);

/// A round that lands nothing and says so, so the first sync finishes without a network.
TakeTheBacklog nothingToTake(Pairing pairing) => (watching) async {
  watching(const IntakeProgress(records: 0, seq: 0, target: 0));
  return const IntakeReport(records: 0, pages: 0, seq: 0, startedOver: false);
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BacklogStore store;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    // The first sync buzzes once before it gets out of the way, and waits on the answer. Nothing
    // answers a channel with no engine behind it, so the phone's side is stood in for.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => null,
        );
    store = BacklogStore.openInMemory();
  });
  tearDown(() => store.close());

  Widget home({
    Size size = const Size(400, 800),
    Rounds? rounds,
    SettingsController? settings,
  }) => MaterialApp(
    theme: viewerTheme(Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: ViewerHome(
        store: store,
        settings: settings ?? SettingsController(UnkeptSettings()),
        appName: 'amenbo Viewer',
        clock: () => today,
        rounds: rounds ?? nothingToTake,
      ),
    ),
  );

  /// Settings as this phone left them, with the one choice this group is about already made.
  SettingsController asked(Refresh refresh) =>
      SettingsController(UnkeptSettings())..setRefresh(refresh);

  group('what the app opens on', () {
    testWidgets('a phone with no way in is told how to make one', (
      tester,
    ) async {
      await tester.pumpWidget(home());
      await tester.pumpAndSettle();

      expect(find.byType(PairingGuideScreen), findsOneWidget);
      expect(find.byType(HomeShell), findsNothing);
    });

    testWidgets('a paired phone is shown its backlog', (tester) async {
      await const PairingStore().save(aPairing);
      store.applyPage([BacklogChange.put('task', 1, task(id: 1))]);

      await tester.pumpWidget(home());
      await tester.pumpAndSettle();

      expect(find.byType(HomeShell), findsOneWidget);
      expect(find.byType(PairingGuideScreen), findsNothing);
    });

    testWidgets('rows that arrived by the other route are a way in of their own', (
      tester,
    ) async {
      // Nothing was ever set up on this phone — the iCloud route is all on the Mac — and rows
      // are here. A guide would be telling the person to set up what is already working.
      store.applyPage([BacklogChange.put('task', 1, task(id: 1))]);

      await tester.pumpWidget(home());
      await tester.pumpAndSettle();

      expect(find.byType(HomeShell), findsOneWidget);
    });

    testWidgets('a code that read goes straight into the first round', (
      tester,
    ) async {
      var rounds = 0;
      // Held open, so the wait can be looked at before it ends.
      final round = Completer<IntakeReport>();
      await tester.pumpWidget(
        home(
          rounds: (pairing) => (watching) {
            rounds += 1;
            return round.future;
          },
        ),
      );
      await tester.pumpAndSettle();

      // What the guide hands up, as the camera would have handed it.
      final guide = tester.widget<PairingGuideScreen>(
        find.byType(PairingGuideScreen),
      );
      guide.onPaired(aPairing);
      // Pumped rather than settled: the bar on the first sync turns for as long as the round
      // lasts, and a round that has not answered never settles.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(rounds, 1);
      expect(find.byType(FirstSyncScreen), findsOneWidget);

      round.complete(
        const IntakeReport(records: 2, pages: 1, seq: 2, startedOver: false),
      );
      await tester.pumpAndSettle();

      // And it comes out on the backlog, not on a screen congratulating anyone.
      expect(find.byType(HomeShell), findsOneWidget);
      expect(find.byType(FirstSyncScreen), findsNothing);
    });
  });

  group('the three tabs', () {
    setUp(() async {
      await const PairingStore().save(aPairing);
      store.applyPage([
        BacklogChange.put('task', 1, task(id: 1, title: 'いちばんのしごと')),
      ]);
    });

    testWidgets('the app opens on the front screen', (tester) async {
      await tester.pumpWidget(home());
      await tester.pumpAndSettle();

      expect(find.byType(NowScreen), findsOneWidget);
      expect(find.text(HomeShell.now), findsOneWidget);
      expect(find.text(HomeShell.search), findsOneWidget);
      expect(find.text(HomeShell.settingsTab), findsOneWidget);
    });

    testWidgets('each destination is one press away', (tester) async {
      await tester.pumpWidget(home());
      await tester.pumpAndSettle();

      await tester.tap(find.text(HomeShell.settingsTab));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);

      await tester.tap(find.text(HomeShell.search));
      await tester.pumpAndSettle();
      expect(find.byType(SearchScreen), findsOneWidget);
    });

    testWidgets('search starts from everything, every time it is arrived at', (
      tester,
    ) async {
      await tester.pumpWidget(home());
      await tester.pumpAndSettle();

      await tester.tap(find.text(HomeShell.search));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'のこらない');
      await tester.pumpAndSettle();

      await tester.tap(find.text(HomeShell.now));
      await tester.pumpAndSettle();
      await tester.tap(find.text(HomeShell.search));
      await tester.pumpAndSettle();

      // A word left behind on the way out would narrow a screen the person came to fresh.
      expect(find.text('のこらない'), findsNothing);
    });
  });

  group('where a list leads', () {
    setUp(() async {
      await const PairingStore().save(aPairing);
      store.applyPage([
        for (var id = 1; id <= Windows.bundle + 2; id++)
          BacklogChange.put('task', id, task(id: id, title: 'しごと $id')),
      ]);
    });

    testWidgets('a row opens the task it names', (tester) async {
      await tester.pumpWidget(home());
      await tester.pumpAndSettle();

      await tester.tap(find.text('しごと 1'));
      await tester.pumpAndSettle();

      expect(find.byType(TaskDetailScreen), findsOneWidget);
    });

    testWidgets('the rest of a bundle opens the one list face, holding it', (
      tester,
    ) async {
      await tester.pumpWidget(home());
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text(NowScreen.more(2)), 200);
      await tester.tap(find.text(NowScreen.more(2)));
      await tester.pumpAndSettle();

      expect(find.byType(SearchScreen), findsOneWidget);
      // Not plain search: the bundle came with it, in the form that can be taken off.
      expect(
        find.widgetWithText(InputChip, bundleHeading(Bundle.next)),
        findsOneWidget,
      );
    });

    testWidgets('a number on the card opens what that number counted', (
      tester,
    ) async {
      // A visit that ended, so the next one has something to count from.
      store.setMeta(MetaKey.lastOpenedAt, '2026-08-08T00:00:00Z');
      store.applyPage([
        BacklogChange.put(
          'task',
          99,
          task(
            id: 99,
            title: 'おわった',
            status: 'done',
            completedAt: '2026-08-09T09:00:00Z',
          ),
        ),
      ]);

      await tester.pumpWidget(home());
      await tester.pumpAndSettle();

      await tester.tap(
        find.text(NowScreen.moved(Moved.finished, const Counted(1, false))),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SearchScreen), findsOneWidget);
      expect(find.text(SearchScreen.since(Moved.finished)), findsOneWidget);
      // The list is what the number counted, and not everything that moved.
      expect(find.text('おわった'), findsOneWidget);
      expect(find.text('しごと 1'), findsNothing);
    });

    testWidgets('with width for two, what is opened sits beside the list', (
      tester,
    ) async {
      await tester.pumpWidget(home(size: const Size(1000, 800)));
      await tester.pumpAndSettle();

      expect(find.byType(TwoPane), findsWidgets);
      await tester.tap(find.text('しごと 1'));
      await tester.pumpAndSettle();

      // Beside it, not on top of it: the list is still there to go on reading.
      expect(find.byType(TaskDetailScreen), findsOneWidget);
      expect(find.byType(NowScreen), findsOneWidget);
    });
  });

  group('when it goes and looks', () {
    setUp(() async {
      await const PairingStore().save(aPairing);
      store.applyPage([BacklogChange.put('task', 1, task(id: 1))]);
    });

    /// A round that counts its callers and lands one record.
    ({List<int> ran, Rounds rounds}) counted() {
      final ran = <int>[];
      return (
        ran: ran,
        rounds: (pairing) => (watching) async {
          ran.add(ran.length);
          // A different row each round, so which round put it there is readable.
          final id = 2 + ran.length;
          store.applyPage([
            BacklogChange.put(
              'task',
              id,
              task(
                id: id,
                title: 'とどいた $id',
                // Stamped by the PC, and later each round: what arrived while the screen was
                // being read is decided by comparing these.
                updatedAt: '2026-08-09T11:0${ran.length}:00Z',
              ),
            ),
          ]);
          return const IntakeReport(
            records: 1,
            pages: 1,
            seq: 2,
            startedOver: false,
          );
        },
      );
    }

    testWidgets('automatically means the launch', (tester) async {
      final round = counted();
      await tester.pumpWidget(
        home(rounds: round.rounds, settings: asked(Refresh.automatic)),
      );
      await tester.pumpAndSettle();

      expect(round.ran, hasLength(1));
    });

    testWidgets('and the return to the front', (tester) async {
      final round = counted();
      await tester.pumpWidget(
        home(rounds: round.rounds, settings: asked(Refresh.automatic)),
      );
      await tester.pumpAndSettle();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(round.ran, hasLength(2));
    });

    testWidgets('only when I pull means neither of them', (tester) async {
      final round = counted();
      await tester.pumpWidget(
        home(rounds: round.rounds, settings: asked(Refresh.manualOnly)),
      );
      await tester.pumpAndSettle();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(round.ran, isEmpty);

      // The thumb still fetches: what the setting turns off is the app going on its own.
      await tester.tap(find.byTooltip(NowScreen.refresh));
      await tester.pumpAndSettle();
      expect(round.ran, hasLength(1));
    });

    testWidgets('what a round nobody asked for brought back waits', (
      tester,
    ) async {
      final round = counted();
      await tester.pumpWidget(
        home(rounds: round.rounds, settings: asked(Refresh.automatic)),
      );
      await tester.pumpAndSettle();
      // The launch round landed before there was anything to interrupt.
      expect(find.text('とどいた 3'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      // This one arrived under someone already reading, so it is counted, not applied.
      expect(find.text('とどいた 4'), findsNothing);
      expect(find.textContaining('New activity'), findsOneWidget);

      await tester.tap(find.textContaining('New activity'));
      await tester.pumpAndSettle();
      expect(find.text('とどいた 4'), findsOneWidget);
    });
  });
}
