// What this build is, and the one line on that screen that is read off the phone rather than
// written into the build.
//
// A copy handed out for testing and the one on the store are the same app under the same version,
// so this line is the only thing telling the person which of them is in their hand. Two things
// have to hold for it to be worth reading: no two origins may say the same sentence, and nothing
// may be said before the phone has answered.

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
    Future<BuildOrigin> Function() readOrigin,
  ) => tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Words.localizationsDelegates,
      supportedLocales: Words.supportedLocales,
      home: AboutScreen(appName: 'Amenbo Viewer', readOrigin: readOrigin),
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
    expect(find.text(words.appVersion(appVersion)), findsOneWidget);

    answer.complete(BuildOrigin.appStore);
    await tester.pumpAndSettle();
    expect(find.text(words.originAppStore), findsOneWidget);
  });
}
