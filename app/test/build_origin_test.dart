// Where this copy came from, as the phone answers it.
//
// The one thing this must never do is name an origin it does not have — a build that says it came
// from the store when it came from a testing track is worse than one that says nothing. So the
// three ways of not getting an answer are all held here: a platform that replies with a word this
// app does not know, a call that fails, and no platform side at all (a test, or a machine). Each
// has to land on unknown rather than on whichever origin is likeliest.

import 'package:amenbo_viewer/build_origin.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('work.amenbo.viewer/build_origin');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void phoneSays(Object? Function() reply) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'read');
      return reply();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  test('every word the two platform sides send is read back', () async {
    for (final origin in BuildOrigin.values) {
      phoneSays(() => origin.raw);
      expect(await BuildOrigin.read(), origin);
    }
  });

  test('a word this app does not know is not guessed at', () async {
    phoneSays(() => 'some-other-store');
    expect(await BuildOrigin.read(), BuildOrigin.unknown);
  });

  test('a call that fails is not an origin either', () async {
    phoneSays(() => throw PlatformException(code: 'no'));
    expect(await BuildOrigin.read(), BuildOrigin.unknown);
  });

  test('nothing on the other end at all', () async {
    expect(await BuildOrigin.read(), BuildOrigin.unknown);
  });
}
