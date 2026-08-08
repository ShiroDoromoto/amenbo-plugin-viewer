// What CI actually proves at this stage: the app boots, on its own, with no amenbo and no
// plugin anywhere near it. That independence is the requirement these tests exist to keep —
// the moment a test needs a snapshot from somewhere, the app has stopped being verifiable on
// its own and the store release is coupled to two others.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amenbo_viewer/main.dart';

void main() {
  testWidgets('the app boots with nothing else present', (tester) async {
    await tester.pumpWidget(const AmenboViewerApp());

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text(AmenboViewerApp.title), findsOneWidget);
  });

  testWidgets('the placeholder says it is a placeholder', (tester) async {
    await tester.pumpWidget(const AmenboViewerApp());

    // Not an empty list, not a spinner: a screen that looked finished would make "no tasks"
    // and "nothing implemented" the same picture.
    expect(find.text('Nothing is built here yet.'), findsOneWidget);
  });
}
