// Every screen that is opened on its own, drawn on glass wider than a page wants to be.
//
// The split holds the two lists that have a detail beside them, and the detail with them. What is
// left is everything the split never sees: the screens pushed over the top, and the one list that
// is a tab of its own. On a phone none of them can be too wide, so none of them were — the tablet
// is where a line runs a thousand points and the eye loses which row it is coming back to.
//
// What is asserted is the width the page was actually laid out at, on a surface that is really
// that wide: a screen told it is on a tablet while being drawn on the binding's default surface
// is one that never runs out of room.

import 'package:amenbo_viewer/about_screen.dart';
import 'package:amenbo_viewer/build_origin.dart';
import 'package:amenbo_viewer/cloudflare_intake.dart';
import 'package:amenbo_viewer/connection.dart';
import 'package:amenbo_viewer/connection_screen.dart';
import 'package:amenbo_viewer/decision_detail.dart';
import 'package:amenbo_viewer/decisions_screen.dart';
import 'package:amenbo_viewer/first_sync.dart';
import 'package:amenbo_viewer/l10n/words.dart';
import 'package:amenbo_viewer/settings.dart';
import 'package:amenbo_viewer/settings_screen.dart';
import 'package:amenbo_viewer/store/backlog_store.dart';
import 'package:amenbo_viewer/ui/measure.dart';
import 'package:amenbo_viewer/ui/theme.dart';
import 'package:amenbo_viewer/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backlog_fixture.dart';
import 'connection_screen_test.dart' show FakeFacts;

/// A tablet in landscape, which is the widest glass this app is opened on.
const _tablet = Size(1200, 900);

final _today = DateTime(2026, 8, 9, 12);

const _paired = Connection(
  paired: true,
  label: 'iPhone',
  host: 'amenbo.example.workers.dev',
);

void main() {
  late BacklogStore store;

  setUp(() {
    store = BacklogStore.openInMemory();
    store.applyPage([
      BacklogChange.put('project', 16, project(id: 16, name: 'viewer')),
      BacklogChange.put(
        'decision',
        1,
        decision(id: 1, title: 'きめた', body: 'りゆう'),
      ),
    ]);
  });
  tearDown(() => store.close());

  /// Draws one screen on the tablet, and hands back the width its page was given.
  Future<double> widthOn(WidgetTester tester, Widget screen) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = _tablet;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: Words.localizationsDelegates,
        supportedLocales: Words.supportedLocales,
        theme: viewerTheme(Brightness.light),
        home: screen,
      ),
    );
    await tester.pumpAndSettle();
    return tester
        .getSize(
          find
              .descendant(
                of: find.byType(Measured),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .width;
  }

  group('a page of prose stops at a readable measure', () {
    testWidgets('the settings', (tester) async {
      expect(
        await widthOn(
          tester,
          SettingsScreen(
            settings: SettingsController(UnkeptSettings()),
            connection: FakeFacts(_paired),
            appName: 'Amenbo Viewer',
          ),
        ),
        Layout.readable,
      );
    });

    testWidgets('what this phone is connected to', (tester) async {
      expect(
        await widthOn(tester, ConnectionScreen(facts: FakeFacts(_paired))),
        Layout.readable,
      );
    });

    testWidgets('what this build is', (tester) async {
      expect(
        await widthOn(
          tester,
          AboutScreen(
            appName: 'Amenbo Viewer',
            readOrigin: () async => BuildOrigin.unknown,
          ),
        ),
        Layout.readable,
      );
    });

    testWidgets('the first round, and what it says when it stops', (
      tester,
    ) async {
      expect(
        await widthOn(tester, const FirstSyncScreen(take: _cannotReachIt)),
        Layout.readable,
      );
    });

    testWidgets('a decision read to the end', (tester) async {
      expect(
        await widthOn(
          tester,
          DecisionDetailScreen(
            store: store,
            decisionId: 1,
            projectName: 'viewer',
            onProject: (_) {},
            onOpenTask: (_) {},
            onOpenDecision: (_) {},
            clock: () => _today,
          ),
        ),
        Layout.readable,
      );
    });
  });

  // The one list nothing is opened beside. It stops narrower than the pages above: what a row
  // gives the eye is its left edge, and a title stretched to a thousand points is read no further
  // than a short one.
  testWidgets('a list of rows stops sooner', (tester) async {
    expect(
      await widthOn(
        tester,
        DecisionsScreen(store: store, clock: () => _today, onOpen: (_) {}),
      ),
      Layout.listPaneMax,
    );
  });
}

/// A round that gets nowhere: the screen draws everything it has to say, and holds still while it
/// is measured.
Future<IntakeReport> _cannotReachIt(void Function(IntakeProgress) watching) =>
    Future.error(const IntakeException(IntakeFailure.unreachable));
