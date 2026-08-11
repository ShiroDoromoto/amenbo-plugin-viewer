// Draws Amenbo's mark into every icon and launch image the two phones ask for.
//
//   dart run tool/gen_brand_assets.dart
//
// The mark's coordinates are `brand_mark.dart`'s; everything below turns them into files.
//
// Nothing is read from disk and no package is pulled in — not even Flutter, since none of these
// carry a letter. The shapes are circles and round-capped segments, which are three lines of
// arithmetic each, so the whole mark is a distance function this file evaluates per pixel — that
// is also what gives the edges their smoothing, and what keeps the joints of a leg from showing a
// seam where two segments overlap.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'brand_mark.dart';
import 'png.dart';

// ── What each platform is handed ───────────────────────────────────────────────────────────

/// iOS masks the corners itself and refuses an icon that carries transparency, so the tile there
/// fills the square edge to edge.
const _iosIcons = <String, int>{
  'Icon-App-20x20@1x.png': 20,
  'Icon-App-20x20@2x.png': 40,
  'Icon-App-20x20@3x.png': 60,
  'Icon-App-29x29@1x.png': 29,
  'Icon-App-29x29@2x.png': 58,
  'Icon-App-29x29@3x.png': 87,
  'Icon-App-40x40@1x.png': 40,
  'Icon-App-40x40@2x.png': 80,
  'Icon-App-40x40@3x.png': 120,
  'Icon-App-60x60@2x.png': 120,
  'Icon-App-60x60@3x.png': 180,
  'Icon-App-76x76@1x.png': 76,
  'Icon-App-76x76@2x.png': 152,
  'Icon-App-83.5x83.5@2x.png': 167,
  'Icon-App-1024x1024@1x.png': 1024,
};

/// The launch screen shows the mark at 120 points, and the storyboard places it without scaling.
const _iosLaunchImages = <String, int>{
  'LaunchImage.png': 120,
  'LaunchImage@2x.png': 240,
  'LaunchImage@3x.png': 360,
};

/// The five densities, as pixels per 48dp (the launcher icon) and per 108dp (the adaptive one).
const _androidDensities = <String, double>{
  'mdpi': 1.0,
  'hdpi': 1.5,
  'xhdpi': 2.0,
  'xxhdpi': 3.0,
  'xxxhdpi': 4.0,
};

/// An adaptive icon's foreground may only count on the middle two thirds of its square: the
/// launcher masks the rest away, and Android 12 and later draw this same layer on the splash.
const _adaptiveSafeFraction = 2 / 3;

void main(List<String> args) {
  final app = File.fromUri(Platform.script).parent.parent;
  if (!File('${app.path}/pubspec.yaml').existsSync()) {
    stderr.writeln(
      'run this from the app directory (no pubspec.yaml above ${app.path})',
    );
    exit(1);
  }

  final written = <String>[];
  void write(String path, Uint8List bytes) {
    final file = File('${app.path}/$path');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    written.add(path);
  }

  void writePng(String path, _Bitmap image, {required bool opaque}) => write(
    path,
    encodePng(
      width: image.size,
      height: image.size,
      rgba: image.rgba,
      opaque: opaque,
    ),
  );

  const icons = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
  for (final entry in _iosIcons.entries) {
    writePng(
      '$icons/${entry.key}',
      _tileIcon(entry.value, rounded: false),
      opaque: true,
    );
  }

  const launch = 'ios/Runner/Assets.xcassets/LaunchImage.imageset';
  for (final entry in _iosLaunchImages.entries) {
    writePng(
      '$launch/${entry.key}',
      _markOnly(entry.value, 0.98),
      opaque: false,
    );
  }

  for (final entry in _androidDensities.entries) {
    final res = 'android/app/src/main/res/mipmap-${entry.key}';
    writePng(
      '$res/ic_launcher.png',
      _tileIcon((48 * entry.value).round(), rounded: true),
      opaque: false,
    );
    writePng(
      '$res/ic_launcher_foreground.png',
      _markOnly((108 * entry.value).round(), _adaptiveSafeFraction),
      opaque: false,
    );
  }

  for (final path in written) {
    stdout.writeln(path);
  }
}

// ── Drawing ────────────────────────────────────────────────────────────────────────────────

/// The mark on its tile, filling the square the way the desktop icon does.
_Bitmap _tileIcon(int size, {required bool rounded}) {
  final scale = size / markDesign;
  final image = _Bitmap(size);
  final radius = rounded ? markTileCorner * scale : 0.0;
  image.paint([
    _roundRect(0, 0, size.toDouble(), size.toDouble(), radius),
  ], markTile);
  _paintMark(image, scale, 0, 0);
  return image;
}

/// The mark alone, centred on the square and taking [fraction] of it. The ground it stands on is
/// the screen's, so nothing is drawn behind it.
_Bitmap _markOnly(int size, double fraction) {
  final bounds = markBounds();
  final scale = fraction * size / math.max(bounds.width, bounds.height);
  final image = _Bitmap(size);
  _paintMark(
    image,
    scale,
    size / 2 - bounds.centreX * scale,
    size / 2 - bounds.centreY * scale,
  );
  return image;
}

/// Everything in the trace colour goes down as one shape — a leg's two segments overlap at the
/// knee, and blending them one after the other would leave a seam along the overlap.
void _paintMark(_Bitmap image, double scale, double dx, double dy) {
  double x(double v) => v * scale + dx;
  double y(double v) => v * scale + dy;

  final traces = <_Sdf>[];
  for (final leg in markLegs) {
    for (var i = 0; i + 1 < leg.length; i++) {
      traces.add(
        _capsule(
          x(leg[i][0]),
          y(leg[i][1]),
          x(leg[i + 1][0]),
          y(leg[i + 1][1]),
          markLegWidth / 2 * scale,
        ),
      );
    }
  }
  for (final node in markNodes) {
    traces.add(_circle(x(node[0]), y(node[1]), markNodeRadius * scale));
  }
  traces.add(
    _capsule(
      x(markBody[0][0]),
      y(markBody[0][1]),
      x(markBody[1][0]),
      y(markBody[1][1]),
      markBodyWidth / 2 * scale,
    ),
  );

  image.paint(traces, markTrace);
  image.paint([
    _circle(x(markHeadCentre[0]), y(markHeadCentre[1]), markHeadRadius * scale),
  ], markHead);
}

// ── A distance function per shape, and a canvas that turns distance into coverage ──────────

/// Signed distance from a point to a shape's edge, in pixels: negative inside.
typedef _Sdf = double Function(double x, double y);

_Sdf _circle(double cx, double cy, double r) =>
    (x, y) => math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) - r;

/// A segment thickened by [r], which is a line with round caps.
_Sdf _capsule(double ax, double ay, double bx, double by, double r) {
  final vx = bx - ax, vy = by - ay;
  final length2 = vx * vx + vy * vy;
  return (x, y) {
    final wx = x - ax, wy = y - ay;
    final t = length2 == 0
        ? 0.0
        : ((wx * vx + wy * vy) / length2).clamp(0.0, 1.0);
    final dx = wx - vx * t, dy = wy - vy * t;
    return math.sqrt(dx * dx + dy * dy) - r;
  };
}

_Sdf _roundRect(double x0, double y0, double x1, double y1, double r) {
  final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
  final hx = (x1 - x0) / 2 - r, hy = (y1 - y0) / 2 - r;
  return (x, y) {
    final qx = (x - cx).abs() - hx, qy = (y - cy).abs() - hy;
    final ox = math.max(qx, 0.0), oy = math.max(qy, 0.0);
    return math.sqrt(ox * ox + oy * oy) + math.min(math.max(qx, qy), 0.0) - r;
  };
}

/// A square canvas holding colours multiplied by their own coverage, which is what makes a
/// half-covered edge pixel blend the same way on any ground.
class _Bitmap {
  _Bitmap(this.size) : _pixels = Float64List(size * size * 4);

  final int size;
  final Float64List _pixels;

  /// Lays [colour] over the union of [shapes]: the nearest edge decides how much of the pixel is
  /// covered, so shapes that overlap are one silhouette rather than two blends.
  void paint(List<_Sdf> shapes, int colour) {
    final r = ((colour >> 16) & 0xFF) / 255,
        g = ((colour >> 8) & 0xFF) / 255,
        b = (colour & 0xFF) / 255;
    for (var py = 0; py < size; py++) {
      final y = py + 0.5;
      for (var px = 0; px < size; px++) {
        final x = px + 0.5;
        var distance = double.infinity;
        for (final shape in shapes) {
          final d = shape(x, y);
          if (d < distance) distance = d;
        }
        final coverage = (0.5 - distance).clamp(0.0, 1.0);
        if (coverage == 0) continue;
        final i = (py * size + px) * 4;
        final keep = 1 - coverage;
        _pixels[i] = r * coverage + _pixels[i] * keep;
        _pixels[i + 1] = g * coverage + _pixels[i + 1] * keep;
        _pixels[i + 2] = b * coverage + _pixels[i + 2] * keep;
        _pixels[i + 3] = coverage + _pixels[i + 3] * keep;
      }
    }
  }

  /// The pixels as the encoder wants them: eight bits a channel, no longer multiplied by
  /// coverage.
  Uint8List get rgba {
    final out = Uint8List(size * size * 4);
    for (var i = 0; i < out.length; i += 4) {
      final a = _pixels[i + 3];
      final undo = a == 0 ? 0.0 : 1 / a;
      out[i] = _byte(_pixels[i] * undo);
      out[i + 1] = _byte(_pixels[i + 1] * undo);
      out[i + 2] = _byte(_pixels[i + 2] * undo);
      out[i + 3] = _byte(a);
    }
    return out;
  }

  static int _byte(double v) => (v * 255).round().clamp(0, 255);
}
