/// A second entrypoint that answers one question from a phone nobody is holding: what is on the
/// screen?
///
/// ```
/// tool/device-screen.sh ios
/// ```
///
/// It runs the real app — same entry widget, same theme — and writes the semantics tree to a file
/// the Mac can fetch over the cable. Text, not pixels: it is what a screen reader would be told,
/// so it carries the words and the order, which is what a check is actually about, and it can be
/// searched and diffed the way an image cannot.
///
/// Android needs none of this (`uiautomator dump` reads any app from outside), so this exists for
/// iOS, where nothing outside the app can see in.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'main.dart';

/// Where the dump lands. On iOS this is the app's `tmp/`, which
/// `devicectl device copy from --domain-type appDataContainer` can reach.
const dumpFileName = 'screen.txt';

/// Long enough for a first frame and whatever it kicks off, short enough that a script does not
/// sit on it. The dump is repeated once after this again, so a slow start is not a wrong answer.
const _settle = Duration(seconds: 3);

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  // Semantics are off until something asks for them — a screen reader, or this. The handle has to
  // outlive the dump, so it is never disposed: the app is here to be read and then killed.
  binding.ensureSemantics();

  // The same start the real entrypoint makes, so what is dumped is the app as it runs and not a
  // second assembly of it that could drift.
  runApp(AmenboViewerApp(settings: await openSettings()));

  () async {
    await Future<void>.delayed(_settle);
    _dump('after ${_settle.inSeconds}s', first: true);
    await Future<void>.delayed(_settle);
    _dump('after ${_settle.inSeconds * 2}s', first: false);
  }();
}

/// Writes one reading of the tree — the first of a run replaces the file, the second is appended,
/// so what comes back is this run and shows whether the screen settled or moved.
void _dump(String label, {required bool first}) {
  final out = StringBuffer()..writeln('--- $label ---');
  // The root owner owns no tree of its own: each view hangs its own owner underneath, so the
  // tree is found by descending rather than by asking the root.
  final roots = <SemanticsNode>[];
  void collect(PipelineOwner owner) {
    final root = owner.semanticsOwner?.rootSemanticsNode;
    if (root != null) roots.add(root);
    owner.visitChildren(collect);
  }

  collect(RendererBinding.instance.rootPipelineOwner);
  if (roots.isEmpty) {
    out.writeln('(no semantics tree — nothing has been laid out yet)');
  } else {
    for (final root in roots) {
      _walk(root, 0, out);
    }
  }
  try {
    File('${Directory.systemTemp.path}/$dumpFileName').writeAsStringSync(
      out.toString(),
      mode: first ? FileMode.write : FileMode.append,
    );
  } catch (error) {
    // Nothing can be done about it from in here, and the screen is still on the phone.
    debugPrint('screen probe: could not write the dump — $error');
  }
  debugPrint(out.toString());
}

void _walk(SemanticsNode node, int depth, StringBuffer out) {
  final data = node.getSemanticsData();
  final words = [
    if (data.label.isNotEmpty) data.label,
    if (data.value.isNotEmpty) '= ${data.value}',
    if (data.hint.isNotEmpty) '(${data.hint})',
  ].join(' ');
  // The rectangle is the node's own, in its parent's coordinates. It is here to tell two
  // otherwise identical rows apart and to show that something has a size at all — not as a
  // layout measurement.
  final size =
      '${node.rect.width.round()}x${node.rect.height.round()}'
      '@${node.rect.left.round()},${node.rect.top.round()}';
  out.writeln('${'  ' * depth}$size  $words'.trimRight());
  node.visitChildren((child) {
    _walk(child, depth + 1, out);
    return true;
  });
}
