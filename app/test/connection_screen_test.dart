// The connection screen says what this phone's connection is and offers the two things that can
// be done to it. What is checked here is mostly what it does *not* say: no other device, no place
// named on a phone that is paired with none, and no erasing without being asked first.

import 'package:amenbo_viewer/connection.dart';
import 'package:amenbo_viewer/connection_screen.dart';
import 'package:amenbo_viewer/l10n/words.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'words_fixture.dart';

class FakeFacts implements ConnectionFacts {
  FakeFacts(this.connection);

  final Connection connection;
  int erased = 0;

  @override
  Future<Connection> read() async => connection;

  @override
  Future<void> erase() async => erased += 1;
}

final _cloudflare = Connection(
  paired: true,
  label: 'iPhone',
  host: 'amenbo.example.workers.dev',
  lastTaken: LastTaken(
    at: DateTime.now().subtract(const Duration(minutes: 12)),
    version: 91,
    seq: 4207,
    specVersion: 1,
  ),
);

/// A phone holding rows that came in over a route this build no longer has.
const _unpaired = Connection();

Future<bool?> pumpConnection(WidgetTester tester, ConnectionFacts facts) async {
  bool? popped;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Words.localizationsDelegates,
      supportedLocales: Words.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              popped = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => ConnectionScreen(facts: facts),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return popped;
}

void main() {
  testWidgets('this phone is named the way the PC would cut it off', (
    tester,
  ) async {
    await pumpConnection(tester, FakeFacts(_cloudflare));

    expect(find.text(words.thisPhone), findsOneWidget);
    expect(find.text('iPhone'), findsOneWidget);
  });

  testWidgets('a phone paired before the code carried a name says nothing', (
    tester,
  ) async {
    // An empty row headed "This phone" would read as the phone having no name on the PC, which
    // is not what happened — the code it was paired from simply did not carry one.
    await pumpConnection(
      tester,
      FakeFacts(
        const Connection(paired: true, host: 'amenbo.example.workers.dev'),
      ),
    );

    expect(find.text(words.thisPhone), findsNothing);
  });

  testWidgets('the Cloudflare route names its host and can be paired again', (
    tester,
  ) async {
    await pumpConnection(tester, FakeFacts(_cloudflare));

    expect(find.text('amenbo.example.workers.dev'), findsOneWidget);
    expect(find.text(words.pairAgainTitle), findsOneWidget);
    // The freshness of the picture, which is what a phone with no signal is really asking.
    expect(find.text('12 min ago'), findsOneWidget);
    expect(find.textContaining('version 91'), findsOneWidget);
  });

  testWidgets('a phone with no pairing names no place', (tester) async {
    await pumpConnection(tester, FakeFacts(_unpaired));

    expect(find.text(words.routeNone), findsOneWidget);
    // Naming a host here would be the screen answering for a place nothing is coming from.
    expect(find.text('amenbo.example.workers.dev'), findsNothing);
    // Reading a code is still the way on, and it is the only one.
    expect(find.text(words.pairAgainTitle), findsOneWidget);
  });

  testWidgets('a phone that has been fed nothing says so plainly', (
    tester,
  ) async {
    await pumpConnection(
      tester,
      FakeFacts(
        const Connection(paired: true, host: 'amenbo.example.workers.dev'),
      ),
    );

    // Paired is not fed, and this is not an error — the PC simply has not written yet.
    expect(find.text(words.nothingArrivedYet), findsOneWidget);
  });

  group('erasing this phone', () {
    testWidgets('it is asked about first, and backing out changes nothing', (
      tester,
    ) async {
      final facts = FakeFacts(_cloudflare);
      await pumpConnection(tester, facts);

      await tester.tap(find.text(words.erase));
      await tester.pumpAndSettle();
      expect(find.text(words.eraseQuestion), findsOneWidget);

      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();

      expect(facts.erased, 0);
      expect(find.text(words.connectionTitle), findsOneWidget);
    });

    testWidgets('agreeing erases, and says so to whoever opened the screen', (
      tester,
    ) async {
      final facts = FakeFacts(_cloudflare);
      final popped = await pumpConnection(tester, facts);
      expect(popped, isNull);

      await tester.tap(find.text(words.erase));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Erase'));
      await tester.pumpAndSettle();

      expect(facts.erased, 1);
      // The screen behind is holding a backlog that no longer exists, so it has to be told.
      expect(find.text(words.connectionTitle), findsNothing);
    });
  });

  testWidgets('pairing again goes to the code on the PC', (tester) async {
    await pumpConnection(tester, FakeFacts(_cloudflare));

    await tester.tap(find.text(words.pairAgainTitle));
    await tester.pumpAndSettle();

    // The reason for the camera, before the camera — the scanning screen's own rule.
    expect(find.text(words.pairHeading), findsOneWidget);
  });
}
