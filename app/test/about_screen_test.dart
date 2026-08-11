// What this build is, the one line on that screen that is read off the phone rather than written
// into the build, and the way out to the privacy policy.
//
// A copy handed out for testing and the one on the store are the same app under the same version,
// so this line is the only thing telling the person which of them is in their hand. Two things
// have to hold for it to be worth reading: no two origins may say the same sentence, and nothing
// may be said before the phone has answered.
//
// The policy is the one row that leaves the app, and both stores ask that it can be reached from
// inside it — so what is checked is that it is there, that it opens the address the stores were
// given, and that a phone which cannot open it says so instead of doing nothing.

import 'dart:async';

import 'package:amenbo_viewer/about_screen.dart';
import 'package:amenbo_viewer/build_origin.dart';
import 'package:amenbo_viewer/l10n/words.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final words = lookupWords(const Locale('en'));

  Future<void> open(
    WidgetTester tester,
    Future<BuildOrigin> Function() readOrigin, {
    OpenALink? openLink,
  }) => tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Words.localizationsDelegates,
      supportedLocales: Words.supportedLocales,
      home: AboutScreen(
        appName: 'Amenbo Viewer',
        readOrigin: readOrigin,
        openLink: openLink ?? (where) async => true,
      ),
    ),
  );

  for (final origin in BuildOrigin.values) {
    testWidgets('a copy from ${origin.name} says so', (tester) async {
      await open(tester, () async => origin);
      await tester.pumpAndSettle();
      expect(find.text(buildOriginWords(words, origin)), findsOneWidget);
    });
  }

  test('no two origins read the same', () {
    expect(
      {
        for (final origin in BuildOrigin.values)
          buildOriginWords(words, origin),
      },
      hasLength(BuildOrigin.values.length),
      reason: 'two origins with one sentence between them is one of them lying',
    );
  });

  testWidgets('nothing is said until the phone has answered', (tester) async {
    final answer = Completer<BuildOrigin>();
    await open(tester, () => answer.future);
    await tester.pump();

    for (final origin in BuildOrigin.values) {
      expect(find.text(buildOriginWords(words, origin)), findsNothing);
    }
    // The rest of the screen is there while the answer is on its way.
    expect(find.text(words.appVersion(appVersionShown)), findsOneWidget);

    answer.complete(BuildOrigin.appStore);
    await tester.pumpAndSettle();
    expect(find.text(words.originAppStore), findsOneWidget);
  });

  group('the way to the privacy policy', () {
    testWidgets('opens the address the stores were given', (tester) async {
      final asked = <Uri>[];
      await open(
        tester,
        () async => BuildOrigin.appStore,
        openLink: (where) async {
          asked.add(where);
          return true;
        },
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(words.privacyPolicy));
      await tester.pumpAndSettle();

      expect(asked.single.toString(), privacyPolicyUrl);
    });

    // A row that does nothing is what somebody meets on a phone with no browser, and they came
    // here looking for a page they were told they could read.
    testWidgets('says the address out loud when nothing opened', (
      tester,
    ) async {
      await open(
        tester,
        () async => BuildOrigin.appStore,
        openLink: (where) async => false,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(words.privacyPolicy));
      await tester.pumpAndSettle();

      expect(
        find.text(words.privacyPolicyUnopened(privacyPolicyUrl)),
        findsOneWidget,
      );
    });

    testWidgets('says the same when the platform refuses outright', (
      tester,
    ) async {
      await open(
        tester,
        () async => BuildOrigin.appStore,
        openLink: (where) async => throw Exception('no activity found'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(words.privacyPolicy));
      await tester.pumpAndSettle();

      expect(
        find.text(words.privacyPolicyUnopened(privacyPolicyUrl)),
        findsOneWidget,
      );
    });

    // The address is written once. A second one anywhere would be the one that goes stale, and
    // the stores were handed this one.
    test('is the product site, over https', () {
      final where = Uri.parse(privacyPolicyUrl);
      expect(where.scheme, 'https');
      expect(where.host, 'amenbo.work');
    });
  });
}
