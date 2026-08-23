// Draws Amenbo's mark into every icon and launch image the two phones ask for, and into the icon
// Play stands beside the listing.
//
//   dart run tool/gen_brand_assets.dart
//
// The mark's coordinates are `brand_mark.dart`'s; everything below turns them into files.
//
// Nothing is read from disk and no package is pulled in — not even Flutter, since none of these
// carry a letter. The shapes are square-ended bars and diamonds, which are a few lines of
// arithmetic each, so the whole mark is a distance function this file evaluates per pixel — that
// is also what gives the edges their smoothing, and what keeps an arm and the node it runs out of
// from showing a seam where the two overlap.
//
// **Which of the two drawings is used depends on the size being baked** (`markFor`), and the two
// are not written at the same scale, so nothing here may hold a number out of one and use it on
// the other.

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
///
/// **It is baked twice.** The ground behind it follows the phone's setting (`LaunchBackground`
/// carries a dark appearance of its own), and the delivered mark is one colour — so a single
/// black sheet would vanish on the dark ground it is laid on. The `-Dark` names are what the
/// imageset points its dark appearance at.
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

/// What an adaptive icon's foreground may count on: a **circle** of two thirds of its square.
///
/// The launcher masks whatever shape it likes, and a circle is the one every one of them fits
/// inside — so a mark that fills the middle two thirds as a *square* has its corners cut off. This
/// one runs its arms out diagonally, which is where a square's corners are: fitted by its box, a
/// quarter of its ink fell outside the circle and the arms read as running off the edge (seen on a
/// phone, 2026-08-23).
const _adaptiveSafeFraction = 2 / 3;

/// What the launch sheet may count on: two thirds of its **square**, and no mask.
///
/// The same number, a different shape, and that is the whole reason the two are written apart.
/// Nothing crops the launch sheet — Android 12 and later draw the icon named in
/// `values-v31/styles.xml` as it is, and the layer list older versions use places it in a box — so
/// shrinking it to a circle here would only make the mark smaller for nothing.
const _launchSafeFraction = 2 / 3;

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
      _markOnly(entry.value, 0.98, ink: markInk),
      opaque: false,
    );
    writePng(
      '$launch/${entry.key.replaceFirst('.png', '-Dark.png')}',
      _markOnly(entry.value, 0.98, ink: markInkOnDark),
      opaque: false,
    );
  }

  // The icon Play stands beside the listing. It is the same tile the phone gets, at the size the
  // console asks for — it was once drawn by hand, which is how it came to be the one asset here
  // that nobody could re-bake when the mark changed.
  writePng(
    'store/graphics/icon-512.png',
    _tileIcon(512, rounded: false),
    opaque: true,
  );

  for (final entry in _androidDensities.entries) {
    final res = 'android/app/src/main/res/mipmap-${entry.key}';
    writePng(
      '$res/ic_launcher.png',
      _tileIcon((48 * entry.value).round(), rounded: true),
      opaque: false,
    );
    writePng(
      '$res/ic_launcher_foreground.png',
      _markInCircle(
        (108 * entry.value).round(),
        _adaptiveSafeFraction,
        ink: markInk,
      ),
      opaque: false,
    );
    // The launch sheet carries the same drawing, and differs from the foreground twice over: the
    // ground under it is the app's, which follows the phone's setting, so the mark has to follow
    // it too (a `-night` qualifier is how the same name answers with the other sheet) — and
    // nothing masks it, so it keeps the room the foreground has to give up.
    writePng(
      '$res/launch_mark.png',
      _markOnly((108 * entry.value).round(), _launchSafeFraction, ink: markInk),
      opaque: false,
    );
    writePng(
      'android/app/src/main/res/mipmap-night-${entry.key}/launch_mark.png',
      _markOnly(
        (108 * entry.value).round(),
        _launchSafeFraction,
        ink: markInkOnDark,
      ),
      opaque: false,
    );
  }

  for (final path in written) {
    stdout.writeln(path);
  }
}

// ── Drawing ────────────────────────────────────────────────────────────────────────────────

/// The mark on its tile.
///
/// **The drawing is placed by its own square, not by what it happens to occupy of it.** The two
/// origins carry different amounts of air inside their viewBox, and fitting each one's ink to the
/// tile would make the mark jump in weight at the size where they change over. What is placed is
/// the square, into the same safe area the desktop icon keeps.
_Bitmap _tileIcon(int size, {required bool rounded}) {
  final art = markFor(size);
  final inside = size * markSafe;
  final scale = inside / art.side;
  final at = (size - inside) / 2;
  final image = _Bitmap(size);
  image.paint([
    _roundRect(
      0,
      0,
      size.toDouble(),
      size.toDouble(),
      rounded ? markTileCorner * size : 0.0,
    ),
  ], markTile);
  _paintMark(
    image,
    art,
    scale,
    at - art.left * scale,
    at - art.top * scale,
    markInk,
  );
  return image;
}

/// The mark alone, centred on the square and taking [fraction] of it, drawn in [ink]. The ground
/// it stands on is the screen's, so nothing is drawn behind it.
_Bitmap _markOnly(int size, double fraction, {required int ink}) {
  final art = markFor(size);
  final bounds = markBounds(art);
  final scale = fraction * size / math.max(bounds.width, bounds.height);
  final image = _Bitmap(size);
  _paintMark(
    image,
    art,
    scale,
    size / 2 - bounds.centreX * scale,
    size / 2 - bounds.centreY * scale,
    ink,
  );
  return image;
}

/// The mark alone, centred on the square and drawn to fit a circle of [diameter] of it.
///
/// The one difference from [_markOnly] is what is being fitted: its box, or the circle around it.
/// For this mark the second is the smaller allowance by nearly a quarter, because the arms run out
/// towards the box's corners.
_Bitmap _markInCircle(int size, double diameter, {required int ink}) {
  final art = markFor(size);
  final bounds = markBounds(art);
  final scale = diameter / 2 * size / markRadius(art);
  final image = _Bitmap(size);
  _paintMark(
    image,
    art,
    scale,
    size / 2 - bounds.centreX * scale,
    size / 2 - bounds.centreY * scale,
    ink,
  );
  return image;
}

/// The whole mark goes down as one shape — an arm ends inside the node it runs out of, and
/// blending them one after the other would leave a seam along the overlap.
void _paintMark(
  _Bitmap image,
  MarkArt art,
  double scale,
  double dx,
  double dy,
  int ink,
) {
  final halfStroke = _atLeastAPixel(art.stroke / 2 * scale);
  double x(double v) => v * scale + dx;
  double y(double v) => v * scale + dy;

  final shapes = <_Sdf>[];
  for (final link in art.links) {
    shapes.add(
      _bar(x(link[0]), y(link[1]), x(link[2]), y(link[3]), halfStroke),
    );
  }
  for (final node in art.nodes) {
    final diamond = _diamond(x(node[0]), y(node[1]), art.nodeRadius * scale);
    shapes.add(art.nodesAreFilled ? diamond : _outlined(diamond, halfStroke));
  }

  image.paint(shapes, ink);
}

// ── A distance function per shape, and a canvas that turns distance into coverage ──────────

/// Signed distance from a point to a shape's edge, in pixels: negative inside.
typedef _Sdf = double Function(double x, double y);

/// Half a line's width, never less than half a pixel.
///
/// **A line thinner than a pixel is not a paler line, it is a line nobody can see.** The mark's
/// stroke is a 64th of its square, so from 40 pixels down it asks for half a pixel and the
/// coverage this file works out answers with grey — measurably so: at 40 the darkest pixel came
/// out at 59 of 255 rather than 0. The main repository never meets this because it bakes through
/// a browser, which lands a hairline on one whole pixel; here the geometry is followed exactly,
/// so the floor has to be stated.
///
/// Below that the small drawing takes over (`markSmallMax`), which is the real answer for the
/// sizes where a whole-pixel stroke is a large fraction of the mark.
double _atLeastAPixel(double halfStroke) => math.max(halfStroke, 0.5);

/// A segment thickened by [r], with the ends left square — the mark is drawn with butt caps, and
/// a round one would push an arm half a stroke past the node it stops at.
_Sdf _bar(double ax, double ay, double bx, double by, double r) {
  final vx = bx - ax, vy = by - ay;
  final length = math.sqrt(vx * vx + vy * vy);
  if (length == 0) return (x, y) => double.infinity;
  final ux = vx / length, uy = vy / length;
  return (x, y) {
    final wx = x - ax, wy = y - ay;
    // Along the segment and across it, which is the box this reduces to once turned upright.
    final along = math.max(-(wx * ux + wy * uy), wx * ux + wy * uy - length);
    final across = (wx * -uy + wy * ux).abs() - r;
    final ox = math.max(along, 0.0), oy = math.max(across, 0.0);
    return math.sqrt(ox * ox + oy * oy) +
        math.min(math.max(along, across), 0.0);
  };
}

/// A square standing on a corner, [r] from its centre to any of its points. Dividing by the
/// diagonal is what turns "how far along |x|+|y|" into a distance in pixels, which is what the
/// coverage at an edge is worked out from.
_Sdf _diamond(double cx, double cy, double r) =>
    (x, y) => ((x - cx).abs() + (y - cy).abs() - r) / math.sqrt2;

/// A shape's outline rather than its body: what is within half a stroke of its edge, inside or
/// out. The delivered nodes are drawn this way, and the hole is what the small drawing gives up.
_Sdf _outlined(_Sdf shape, double halfStroke) =>
    (x, y) => shape(x, y).abs() - halfStroke;

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
