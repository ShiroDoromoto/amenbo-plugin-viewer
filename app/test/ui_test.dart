// The rules that hold across every screen, checked where they are decided rather than once per
// screen — a screen that forgets one of them looks right to whoever wrote it.

import 'package:amenbo_viewer/main.dart';
import 'package:amenbo_viewer/settings.dart';
import 'package:amenbo_viewer/store/backlog_store.dart';
import 'package:amenbo_viewer/ui/marks.dart';
import 'package:amenbo_viewer/ui/refs.dart';
import 'package:amenbo_viewer/ui/theme.dart';
import 'package:amenbo_viewer/ui/time.dart';
import 'package:amenbo_viewer/ui/two_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime(2026, 8, 9, 12, 0);

void main() {
  group('one look, both platforms', () {
    test('light and dark come from the same seed', () {
      for (final brightness in Brightness.values) {
        final theme = viewerTheme(brightness);
        expect(theme.colorScheme.brightness, brightness);
      }
      // The colour the app already shipped with. Changing it is changing what people have seen.
      expect(
        viewerTheme(Brightness.light).colorScheme.primary,
        ColorScheme.fromSeed(seedColor: seedColour).primary,
      );
    });

    testWidgets('the platform does not get a look of its own', (tester) async {
      final seen = <Color>{};
      for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: viewerTheme(Brightness.light).copyWith(platform: platform),
            home: const Scaffold(body: RowTitle('a title')),
          ),
        );
        seen.add(
          Theme.of(tester.element(find.byType(RowTitle))).colorScheme.primary,
        );
      }
      expect(seen, hasLength(1));
    });
  });

  group('the text size is the OS setting', () {
    testWidgets('a long title takes two lines and no more, at any size', (
      tester,
    ) async {
      final heights = <double, double>{};
      for (final scale in [1.0, 2.0, 3.2]) {
        await tester.pumpWidget(
          _scaled(
            scale,
            const SizedBox(
              width: 320,
              child: RowTitle(
                'a backlog title long enough that it cannot possibly fit on one line '
                'even before anybody turns their text size up at all',
              ),
            ),
          ),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'nothing overflowed at $scale',
        );
        expect(tester.widget<Text>(find.byType(Text)).maxLines, 2);
        heights[scale] = tester.getSize(find.byType(Text)).height;
      }

      // The size is the OS setting's to decide: turning it up has to make the text bigger, which
      // a widget that wrote its own size into itself would not do.
      expect(heights[2.0]!, greaterThan(heights[1.0]!));
      expect(heights[3.2]!, greaterThan(heights[2.0]!));
    });
  });

  group('no state is carried by colour alone', () {
    testWidgets('priority says which one it is', (tester) async {
      for (final entry in {
        'high': 'High',
        'medium': 'Med',
        'low': 'Low',
      }.entries) {
        await tester.pumpWidget(_wrap(PriorityMark(entry.key)));
        expect(find.text(entry.value), findsOneWidget);
      }
    });

    testWidgets('a late task says it is late, in words', (tester) async {
      await tester.pumpWidget(_wrap(DueMark('2026-08-07', today: now)));
      expect(find.textContaining('Overdue'), findsOneWidget);

      await tester.pumpWidget(_wrap(DueMark('2026-08-09', today: now)));
      expect(find.text('Due today'), findsOneWidget);
    });

    testWidgets('a state says its name', (tester) async {
      await tester.pumpWidget(_wrap(const StatusMark('in_progress')));
      expect(find.text('In progress'), findsOneWidget);
    });

    test('lateness is decided against the day, not the instant', () {
      expect(isOverdue('2026-08-08', today: now), isTrue);
      expect(isOverdue('2026-08-09', today: now), isFalse);
    });
  });

  group('a row is read as one thing', () {
    test('the sentence carries what the marks show, and no glyphs', () {
      final label = rowLabel(
        ref: taskRef(2833),
        title: 'wire the store up',
        status: 'in_progress',
        priority: 'medium',
        unread: true,
        assigneeKind: 'ai',
        comments: 5,
      );

      expect(label, startsWith('unread, '));
      expect(label, contains('In progress'));
      expect(label, contains('Med priority'));
      expect(label, contains('assigned to AI'));
      expect(label, contains('5 comments'));
    });

    test('one comment is not read as "1 comments"', () {
      final label = rowLabel(
        ref: taskRef(1),
        title: 't',
        status: 'todo',
        comments: 1,
      );
      expect(label, endsWith('1 comment'));

      // Nothing at all when there are none: a row saying "0 comments" spends the listener's
      // attention on the absence of something.
      expect(
        rowLabel(ref: taskRef(1), title: 't', status: 'todo'),
        isNot(contains('comment')),
      );
    });

    testWidgets('the marks inside a row say nothing on their own', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _wrap(
          SpokenAsOne(
            label: 'the whole row',
            child: Row(
              children: [
                const UnreadDot(unread: true),
                const PriorityMark('high'),
                const Expanded(child: RowTitle('wire the store up')),
              ],
            ),
          ),
        ),
      );

      expect(find.bySemanticsLabel('the whole row'), findsOneWidget);
      expect(find.bySemanticsLabel('High'), findsNothing);
      handle.dispose();
    });
  });

  group('time', () {
    test('it counts while counting helps, then names the day', () {
      expect(
        relativeTime(now.subtract(const Duration(seconds: 20)), now: now),
        'just now',
      );
      expect(
        relativeTime(now.subtract(const Duration(minutes: 12)), now: now),
        '12 min ago',
      );
      expect(
        relativeTime(now.subtract(const Duration(hours: 3)), now: now),
        '3 h ago',
      );
      expect(
        relativeTime(DateTime(2026, 8, 8, 14, 2), now: now),
        'yesterday 14:02',
      );
      expect(relativeTime(DateTime(2026, 8, 2), now: now), '2 Aug');
      expect(relativeTime(DateTime(2025, 8, 2), now: now), '2 Aug 2025');
    });

    test('"h ago" never outlives the day it was counted from', () {
      // 13 hours back, but on the day before: counting the hours would read as though it were
      // still today.
      expect(
        relativeTime(
          DateTime(2026, 8, 8, 23, 0),
          now: DateTime(2026, 8, 9, 12, 0),
        ),
        'yesterday 23:00',
      );
      // Forty minutes back and also the day before. Minutes still beat naming the day, because
      // the question being answered is how fresh it is.
      expect(
        relativeTime(
          DateTime(2026, 8, 8, 23, 50),
          now: DateTime(2026, 8, 9, 0, 30),
        ),
        '40 min ago',
      );
    });

    testWidgets('the exact instant is one long press away', (tester) async {
      await tester.pumpWidget(
        _wrap(
          TimeOnHold(
            when: DateTime(2026, 8, 2, 14, 2),
            child: const Text('2 Aug'),
          ),
        ),
      );

      await tester.longPress(find.text('2 Aug'));
      await tester.pumpAndSettle();
      expect(find.text('2 Aug 2026, 14:02'), findsOneWidget);
    });
  });

  group('a ref is the way back to the PC', () {
    test('it is namespaced, so it still means something off the screen', () {
      // Written in two halves on purpose: a whole ref in a tracked file is what the repository's
      // own lint refuses, since the number resolves in one store and nowhere else.
      expect(taskRef(2833), startsWith('AMB-T-'));
      expect(taskRef(2833), endsWith('2833'));
      expect(decisionRef(31), startsWith('AMB-D-'));
    });

    testWidgets('tapping it copies it and says so', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );

      await tester.pumpWidget(_wrap(RefChip(taskRef(2833))));
      await tester.tap(find.byType(RefChip));
      await tester.pumpAndSettle();

      expect(copied.single, taskRef(2833));
      expect(find.textContaining('Copied'), findsOneWidget);
    });
  });

  group('width, not device', () {
    testWidgets('a narrow screen shows one pane at a time', (tester) async {
      await tester.pumpWidget(
        _sized(
          const Size(400, 800),
          const TwoPane(list: Text('list'), detail: Text('detail')),
        ),
      );
      expect(find.text('list'), findsNothing);
      expect(find.text('detail'), findsOneWidget);
    });

    testWidgets(
      'a wide screen shows both, and holds the place when nothing is open',
      (tester) async {
        await tester.pumpWidget(
          _sized(
            const Size(1000, 800),
            const TwoPane(list: Text('list'), detail: Text('detail')),
          ),
        );
        expect(find.text('list'), findsOneWidget);
        expect(find.text('detail'), findsOneWidget);

        await tester.pumpWidget(
          _sized(
            const Size(1000, 800),
            const TwoPane(
              list: Text('list'),
              placeholder: Text('nothing open'),
              detail: null,
            ),
          ),
        );
        expect(find.text('nothing open'), findsOneWidget);
      },
    );
  });

  testWidgets('the app itself is drawn with this theme', (tester) async {
    // The root asks the phone whether it is paired before it draws anything else.
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(
      AmenboViewerApp(
        store: BacklogStore.openInMemory(),
        settings: SettingsController(UnkeptSettings()),
      ),
    );
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(
      app.theme?.colorScheme.primary,
      viewerTheme(Brightness.light).colorScheme.primary,
    );
    expect(app.darkTheme?.colorScheme.brightness, Brightness.dark);
  });
}

Widget _wrap(Widget child) => MaterialApp(
  theme: viewerTheme(Brightness.light),
  home: Scaffold(body: Center(child: child)),
);

Widget _scaled(double scale, Widget child) => MaterialApp(
  theme: viewerTheme(Brightness.light),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(body: child),
  ),
);

/// A window of exactly [size]. `home:` is laid out tight to the test surface, so the box has to
/// sit under something that hands down loose constraints or it silently keeps the surface's own
/// width — which is the one thing these tests are about.
Widget _sized(Size size, Widget child) => MaterialApp(
  theme: viewerTheme(Brightness.light),
  home: Align(
    alignment: Alignment.topLeft,
    child: SizedBox.fromSize(
      size: size,
      child: Scaffold(body: child),
    ),
  ),
);
