// The camera, stood in for. Every screen that reads a code takes one of these, because a test
// cannot point a real lens at anything — and what happens *after* a code is read is the half of
// pairing worth checking.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amenbo_viewer/pairing_scan.dart';

/// A camera that reports what it was asked for and shows whatever it is told to.
class FakeCamera implements Camera {
  FakeCamera({this.access = CameraAccess.granted});

  final CameraAccess access;

  int asked = 0;
  int sentToSettings = 0;

  /// The live view's callback, so a test can put a code in front of the camera.
  void Function(String text)? watching;

  @override
  Future<CameraAccess> ask() async {
    asked++;
    return access;
  }

  @override
  Future<void> openTheSettings() async => sentToSettings++;

  @override
  Widget view(void Function(String text) onCode) {
    watching = onCode;
    return const ColoredBox(color: Colors.black);
  }
}

const key = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';

/// A code that reads, so a test can get past the reading and on to what follows it.
const good =
    '{"v":1,"url":"https://viewer.example.workers.dev","t":"tok","k":"$key"}';

/// The screen shows why it wants the camera before it asks for it. Getting past that page is a
/// step every test that reaches the lens has to take.
Future<void> goOnToTheCamera(WidgetTester tester) async {
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
}
