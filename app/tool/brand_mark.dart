// Amenbo's mark, as coordinates.
//
// The mark is the designer's, and the origin is `assets/brand/` in the main repository — this file
// is a copy of the numbers in it, kept here for the same reason the design tokens are: this
// repository has to build with nothing else beside it. If the mark moves over there, this file is
// what gets moved here, and everything drawn from it is redrawn.
//
// **There are two drawings, not one.** The delivered mark's stroke is a 64th of its square, so
// below about 32 pixels it asks for a fraction of a pixel and the screen answers with grey. The
// small drawing is the same figure re-cut for a whole-pixel stroke, and it takes over at 32 and
// below (`markSmallMax`). It changes two things and only because the size cannot hold them: the
// nodes are filled rather than outlined, and the free leg beside the upper-right arm is dropped,
// reading as a stray dot at that size.
//
// Only the numbers live here. How they are turned into pixels is the business of whoever reads
// them: `gen_brand_assets.dart` evaluates them per pixel as distance functions, `gen_feature_
// graphic.dart` hands the same points to a canvas. Two files drawing the same mark from two sets
// of numbers is how the two would drift apart.

import 'dart:math' as math;

/// One drawing, in the units of the viewBox it was delivered in.
///
/// The two origins are written at different scales — 64 units across for the delivered one, 16
/// for the small one — so nothing here is comparable between them. What reads a drawing scales it
/// by its own [side] or fits [markBounds] to the room it has.
class MarkArt {
  const MarkArt({
    required this.left,
    required this.top,
    required this.side,
    required this.links,
    required this.nodes,
    required this.nodeRadius,
    required this.stroke,
    required this.nodesAreFilled,
  });

  /// The corner the drawing's square starts at. The delivered mark is written around its own
  /// origin, the small one out of a corner, so neither square can be assumed to start at zero.
  final double left;
  final double top;

  /// The side of the square the drawing is written in.
  final double side;

  /// The arms and the legs, each `[x1, y1, x2, y2]`. They are drawn with butt caps: the ends are
  /// square, and a node is what covers the joint where several meet.
  final List<List<double>> links;

  /// The nodes, as the centres of squares standing on a corner.
  final List<List<double>> nodes;

  /// Half a node's diagonal — the distance from its centre to any of its four points.
  final double nodeRadius;

  /// How wide a line is drawn, in this drawing's own units.
  final double stroke;

  /// Whether a node is a solid diamond or an outlined one. Below 32 pixels the hole an outline
  /// needs is thinner than a pixel, which is why the small drawing fills them.
  final bool nodesAreFilled;
}

/// The delivered mark: a 45-degree lattice, 64 units across, centred on its own origin.
const markLarge = MarkArt(
  left: -32,
  top: -32,
  side: 64,
  links: <List<double>>[
    // The arms, running out of the middle node.
    [-4, 0, -16, 0],
    [0, -4, 0, -16],
    [2, -2, 18, -18],
    [-2, 2, -14, 14],
    [2, 2, 18, 18],
    // The free legs — ends with no node on them.
    [2, -18, 12, -8],
    [0, 4, 0, 16],
  ],
  nodes: <List<double>>[
    [0, 0],
    [0, -20],
    [-20, 0],
    [20, -20],
    [-16, 16],
    [20, 20],
  ],
  nodeRadius: 4,
  stroke: 1,
  nodesAreFilled: false,
);

/// The same figure re-cut for small sizes: 16 units across, one unit to a pixel at 16.
const markSmall = MarkArt(
  left: 0,
  top: 0,
  side: 16,
  links: <List<double>>[
    [6.380, 7.500, 3.020, 7.500],
    [7.500, 6.380, 7.500, 3.020],
    [8.060, 6.940, 12.540, 2.460],
    [6.940, 8.060, 3.580, 11.420],
    [8.060, 8.060, 12.540, 12.540],
    [7.500, 8.620, 7.500, 11.980],
  ],
  nodes: <List<double>>[
    [7.500, 7.500],
    [7.500, 1.900],
    [1.900, 7.500],
    [13.100, 1.900],
    [3.020, 11.980],
    [13.100, 13.100],
  ],
  nodeRadius: 1.4,
  stroke: 1,
  nodesAreFilled: true,
);

/// Where the small drawing takes over, in pixels of the finished image. The number is the main
/// repository's `SMALL_MAX`, and the line is drawn in the same place for the same reason.
const markSmallMax = 32;

/// Which drawing a given pixel size is baked from.
MarkArt markFor(int size) => size <= markSmallMax ? markSmall : markLarge;

/// The mark's ink, and the ink it is drawn in on a dark ground. The delivered artwork is these
/// two and nothing else: the ground belongs to whatever surface the mark is laid on.
const markInk = 0x000000;
const markInkOnDark = 0xFFFFFF;

/// A matte off-white for the tile an icon stands on; a pure white face reads as a glossy pebble.
const markTile = 0xF3F2EE;

/// The tile's corner, as a fraction of its side — the ratio the platforms' own icons keep.
const markTileCorner = 232 / 1024;

/// How much of a tile the mark is given, as a fraction of its side.
///
/// It is the grid macOS lays its icons on, kept here so a phone icon and the desktop one stand
/// the same way. The small drawing needs it most: it is written edge to edge in its own square,
/// with none of the air the delivered one carries inside its viewBox.
const markSafe = 824 / 1024;

/// How far the mark's ink reaches from the centre of [markBounds].
///
/// **A square safe area and a round one are not the same allowance.** The mark's arms run out
/// diagonally, so fitting its box to a square leaves the arm ends outside the circle drawn on that
/// square — which is exactly the shape a launcher masks an adaptive icon into. Whoever is placing
/// the mark inside a circle scales by this rather than by [markBounds].
///
/// It measures the shapes `gen_brand_assets.dart` actually puts down, not the boxes around them:
/// a link is a rectangle with square ends, so its far corners are the endpoint pushed sideways by
/// half a stroke; a node is a diamond standing on a corner, so its far points are on the axes. An
/// outlined node's edge is offset half a stroke perpendicular to each of its four sides, which
/// moves the point it meets at further out than that by the diagonal.
double markRadius(MarkArt art) {
  final bounds = markBounds(art);
  var radius = 0.0;
  void reach(double x, double y) {
    final d = math.sqrt(
      (x - bounds.centreX) * (x - bounds.centreX) +
          (y - bounds.centreY) * (y - bounds.centreY),
    );
    if (d > radius) radius = d;
  }

  for (final link in art.links) {
    final dx = link[2] - link[0], dy = link[3] - link[1];
    final length = math.sqrt(dx * dx + dy * dy);
    // Half a stroke, turned a quarter turn off the link's own direction.
    final sx = -dy / length * art.stroke / 2;
    final sy = dx / length * art.stroke / 2;
    for (final end in <List<double>>[
      [link[0], link[1]],
      [link[2], link[3]],
    ]) {
      reach(end[0] + sx, end[1] + sy);
      reach(end[0] - sx, end[1] - sy);
    }
  }
  for (final node in art.nodes) {
    final r =
        art.nodeRadius + (art.nodesAreFilled ? 0 : art.stroke / 2 * math.sqrt2);
    reach(node[0] + r, node[1]);
    reach(node[0] - r, node[1]);
    reach(node[0], node[1] + r);
    reach(node[0], node[1] - r);
  }
  return radius;
}

/// What the mark occupies of its square, with the stroke and the nodes counted in.
///
/// It is narrower than the square and off its centre, so anything that centres the mark on
/// something else has to centre this rather than the square it is written in.
({double width, double height, double centreX, double centreY}) markBounds(
  MarkArt art,
) {
  var left = double.infinity, top = double.infinity;
  var right = -double.infinity, bottom = -double.infinity;
  void include(double cx, double cy, double r) {
    left = left < cx - r ? left : cx - r;
    top = top < cy - r ? top : cy - r;
    right = right > cx + r ? right : cx + r;
    bottom = bottom > cy + r ? bottom : cy + r;
  }

  for (final link in art.links) {
    include(link[0], link[1], art.stroke / 2);
    include(link[2], link[3], art.stroke / 2);
  }
  for (final node in art.nodes) {
    // An outlined node is half a stroke wider than the diamond its points describe.
    include(
      node[0],
      node[1],
      art.nodeRadius + (art.nodesAreFilled ? 0 : art.stroke / 2),
    );
  }

  return (
    width: right - left,
    height: bottom - top,
    centreX: (left + right) / 2,
    centreY: (top + bottom) / 2,
  );
}
