// The connection screen says what this phone's connection is and offers the two things that can
// be done to it. What is checked here is mostly what it does *not* say: no other device, no place
// named on a phone that is paired with none, and no erasing without being asked first.

import 'package:amenbo_viewer/connection.dart';
import 'package:amenbo_viewer/connection_screen.dart';
import 'package:amenbo_viewer/l10n/words.dart';
import 'package:amenbo_viewer/pairing_scan.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'camera_fixture.dart';
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

/// Pushes the screen the way the settings do, and hands back a way to read what it popped —
/// read after the fact, because what the screen answers with lands when it closes.
Future<ConnectionOutcome? Function()> pumpConnection(
  WidgetTester tester,
  ConnectionFacts facts, {
  Camera? camera,
}) async {
  ConnectionOutcome? popped;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Words.localizationsDelegates,
      supportedLocales: Words.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              popped = await Navigator.of(context).push<ConnectionOutcome>(
                MaterialPageRoute(
                  builder: (_) => ConnectionScreen(
                    facts: facts,
                    camera: camera ?? const LiveCamera(),
                  ),
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
  return () => popped;
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

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
      expect(popped(), isNull);

      await tester.tap(find.text(words.erase));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Erase'));
      await tester.pumpAndSettle();

      expect(facts.erased, 1);
      // The screen behind is holding a backlog that no longer exists, so it has to be told.
      expect(find.text(words.connectionTitle), findsNothing);
      expect(popped(), isA<CopyErased>());
    });
  });

  testWidgets('pairing again goes to the code on the PC', (tester) async {
    await pumpConnection(tester, FakeFacts(_cloudflare));

    await tester.tap(find.text(words.pairAgainTitle));
    await tester.pumpAndSettle();

    // The reason for the camera, before the camera — the scanning screen's own rule.
    expect(find.text(words.pairHeading), findsOneWidget);
  });

  testWidgets('a code read here is handed out to be fetched with', (
    tester,
  ) async {
    // The half that keeping the code does not cover. A new token answers nobody until a round
    // asks with it, and no round is run from this screen — so what it read has to leave with it.
    // Held here rather than in the root, because this is where re-pairing was done from and where
    // it therefore has to end: the band still saying the PC turned this phone away, after a fresh
    // code was read, is the failure with nothing on screen to act on.
    final camera = FakeCamera();
    final popped = await pumpConnection(
      tester,
      FakeFacts(_cloudflare),
      camera: camera,
    );

    await tester.tap(find.text(words.pairAgainTitle));
    await tester.pumpAndSettle();
    await goOnToTheCamera(tester);
    camera.watching!(good);
    await tester.pumpAndSettle();

    expect(popped(), isA<PairedAgain>());
    expect((popped()! as PairedAgain).pairing.readToken, 'tok');
    // Both screens are behind now — the one that read the code, and the scanning screen itself.
    expect(find.text(words.connectionTitle), findsNothing);
  });
}
