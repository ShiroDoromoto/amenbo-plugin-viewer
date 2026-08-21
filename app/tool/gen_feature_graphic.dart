// Draws the one wide picture Google Play will not publish a listing without.
//
//   flutter test tool/gen_feature_graphic.dart      (or: make -C app feature-graphic)
//
// It runs as a test because that is the only headless way to reach a canvas that can set type:
// `dart run` has no engine behind it, and the mark's own generator next door draws its shapes by
// arithmetic precisely because it never has to draw a letter.
//
// Play asks for 1024×500 exactly, and shows it at the head of the listing in every language. So
// the picture carries the mark and the product's name and nothing else — a sentence burnt into it
// would be English on nineteen listings, and a screen shrunk into 500 pixels of height would be
// a phone nobody can read.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:amenbo_viewer/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'brand_mark.dart';
import 'png.dart';

/// What Play asks for. Neither number is negotiable — the console rejects anything else.
const _width = 1024.0;
const _height = 500.0;

const _out = 'store/graphics/feature-graphic-1024x500.png';

/// The mark's height on the picture, and the name's size beside it. The mark is the taller of the
/// two by a wide margin: it is what is recognised at the size a listing is skimmed at, and the
/// name is read only once the eye has already stopped.
const _markHeight = 214.0;
const _nameSize = 72.0;

/// The air between them, and the tracking the name is set with. A wordmark standing alone is read
/// as a shape rather than as words, and a little more room between the letters is what keeps it
/// from setting like a line of running text.
const _gap = 54.0;
const _tracking = 1.5;

/// How much of Roboto's em its capitals stand in. A line of type is boxed with room for the
/// letters that hang below the baseline, and this name has none — centring the box would leave the
/// whole word sitting high of the mark beside it, so what gets centred is the capitals.
const _capHeight = 0.711;

/// Android's own face, which is the one this app is drawn in on the phones this picture is shown
/// to. It ships inside the Flutter SDK, so nothing has to be carried in the repository for it —
/// and the app carries no typeface of its own by design (see its README).
const _face = 'Roboto-Medium.ttf';

void main() {
  testWidgets('feature graphic', (tester) async {
    // `flutter test` runs from the package's own directory, which is where the picture goes.
    final app = Directory.current;
    if (!File('${app.path}/pubspec.yaml').existsSync()) {
      throw StateError('run this from the app directory, not ${app.path}');
    }

    late final Uint8List png;
    await tester.runAsync(() async {
      await _loadFace();
      png = await _draw();
    });

    File('${app.path}/$_out')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(png);
    stdout.writeln(
      '$_out  (${_width.toInt()}×${_height.toInt()}, '
      '${(png.length / 1024).round()} KiB)',
    );
  });
}

/// Puts the face where a [TextStyle] can ask for it. A test binding starts with no typeface at
/// all — text drawn without this comes out as the boxes the framework uses to measure with.
Future<void> _loadFace() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null || root.isEmpty) {
    throw StateError('no FLUTTER_ROOT: run this through `flutter test`');
  }
  final file = File('$root/bin/cache/artifacts/material_fonts/$_face');
  if (!file.existsSync()) {
    throw StateError('the SDK has no $_face at ${file.path}');
  }
  await (FontLoader(
    'Wordmark',
  )..addFont(Future.value(file.readAsBytesSync().buffer.asByteData()))).load();
}

/// The mark and the name, laid out as one group and centred together. Play crops the picture's
/// edges on some of the shapes it shows it in, so nothing is allowed near them.
Future<Uint8List> _draw() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);

  canvas.drawRect(
    const Rect.fromLTWH(0, 0, _width, _height),
    Paint()..color = const Color(0xFF000000 | markTile),
  );

  final name = TextPainter(
    text: TextSpan(
      text: 'Amenbo Viewer',
      style: TextStyle(
        fontFamily: 'Wordmark',
        fontSize: _nameSize,
        letterSpacing: _tracking,
        // The app's own ink, so the name is written in the colour it is written in on the screens
        // beside it in the listing.
        color: lightPalette.text,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  // The wide picture is 214 pixels of mark, well clear of where the small drawing takes over.
  const art = markLarge;
  final bounds = markBounds(art);
  final scale = _markHeight / bounds.height;
  final markWidth = bounds.width * scale;

  // The last letter is followed by one more space of tracking, which is width the word does not
  // occupy — counting it would push the whole group left of centre.
  final nameWidth = name.width - _tracking;
  final left = (_width - (markWidth + _gap + nameWidth)) / 2;

  _paintMark(
    canvas,
    art,
    scale,
    left + markWidth / 2 - bounds.centreX * scale,
    _height / 2 - bounds.centreY * scale,
  );
  name.paint(
    canvas,
    Offset(
      left + markWidth + _gap,
      _height / 2 +
          _nameSize * _capHeight / 2 -
          name.computeDistanceToActualBaseline(TextBaseline.alphabetic),
    ),
  );

  final image = await recorder.endRecording().toImage(
    _width.toInt(),
    _height.toInt(),
  );
  // Flutter's own PNG encoder always writes the alpha channel, which Play refuses here. So the
  // pixels come out raw and are written by the encoder the mark's generator uses. Raw means
  // multiplied by alpha, which changes nothing: every pixel of this picture is opaque.
  final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return encodePng(
    width: _width.toInt(),
    height: _height.toInt(),
    rgba: pixels!.buffer.asUint8List(),
    opaque: true,
  );
}

/// The mark, [scale]d out of its own square and moved by [dx] / [dy].
///
/// The arms are drawn with butt caps, which is how the artwork is written: an arm stops where the
/// node it runs out of begins, and a round cap would push it half a stroke further. The nodes are
/// squares standing on a corner, stroked rather than filled at this size.
void _paintMark(
  Canvas canvas,
  MarkArt art,
  double scale,
  double dx,
  double dy,
) {
  Offset at(double x, double y) => Offset(x * scale + dx, y * scale + dy);

  final ink = Paint()..color = const Color(0xFF000000 | markInk);
  final stroked = Paint()
    ..color = ink.color
    ..style = PaintingStyle.stroke
    ..strokeWidth = art.stroke * scale
    ..strokeCap = StrokeCap.butt
    ..strokeJoin = StrokeJoin.miter;

  for (final link in art.links) {
    canvas.drawLine(at(link[0], link[1]), at(link[2], link[3]), stroked);
  }
  for (final node in art.nodes) {
    final path = Path()
      ..moveTo(
        at(node[0] - art.nodeRadius, node[1]).dx,
        at(node[0], node[1]).dy,
      )
      ..lineTo(
        at(node[0], node[1] - art.nodeRadius).dx,
        at(node[0], node[1] - art.nodeRadius).dy,
      )
      ..lineTo(
        at(node[0] + art.nodeRadius, node[1]).dx,
        at(node[0], node[1]).dy,
      )
      ..lineTo(
        at(node[0], node[1] + art.nodeRadius).dx,
        at(node[0], node[1] + art.nodeRadius).dy,
      )
      ..close();
    canvas.drawPath(path, art.nodesAreFilled ? ink : stroked);
  }
}
