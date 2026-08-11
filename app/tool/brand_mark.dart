// Amenbo's mark, as coordinates.
//
// The mark is Amenbo's own — a water strider whose legs are drawn as circuit traces — and it is
// copied here for the same reason the design tokens are: this repository has to build with nothing
// else beside it. If the mark moves over there, this file is what gets moved here, and everything
// drawn from it is redrawn.
//
// Only the numbers live here. How they are turned into pixels is the business of whoever reads
// them: `gen_brand_assets.dart` evaluates them per pixel as distance functions, `gen_feature_
// graphic.dart` hands the same points to a canvas. Two files drawing the same mark from two sets
// of numbers is how the two would drift apart.

/// The square the mark is drawn in. Every number below is in it.
const markDesign = 1024.0;

/// A matte off-white; a pure white face reads as a glossy pebble.
const markTile = 0xF3F2EE;
const markTrace = 0x1B93C2;
const markHead = 0xFF7E5F;

/// The tile's corner, as the icon of the desktop application cuts it.
const markTileCorner = 232.0;

/// The legs: fore and hind pairs run out at 45 degrees, the middle pair straight out.
const markLegs = <List<List<double>>>[
  [
    [482, 410],
    [382, 410],
    [172, 200],
  ],
  [
    [542, 410],
    [642, 410],
    [852, 200],
  ],
  [
    [482, 558],
    [110, 558],
  ],
  [
    [542, 558],
    [914, 558],
  ],
  [
    [482, 706],
    [382, 706],
    [172, 916],
  ],
  [
    [542, 706],
    [642, 706],
    [852, 916],
  ],
];
const markLegWidth = 50.0;

/// The nodes at the leg tips.
const markNodes = <List<double>>[
  [172, 200],
  [852, 200],
  [110, 558],
  [914, 558],
  [172, 916],
  [852, 916],
];
const markNodeRadius = 24.0;

/// The body, and the head above it.
const markBody = <List<double>>[
  [512, 383],
  [512, 733],
];
const markBodyWidth = 64.0;
const markHeadCentre = <double>[512, 317];
const markHeadRadius = 58.0;

/// What the mark occupies of its square, with the stroke widths counted in.
///
/// It is narrower than the square and shorter still, so anything that centres the mark on
/// something else has to centre this rather than the square it is written in.
({double width, double height, double centreX, double centreY}) markBounds() {
  var left = double.infinity, top = double.infinity;
  var right = -double.infinity, bottom = -double.infinity;
  void include(double cx, double cy, double r) {
    left = left < cx - r ? left : cx - r;
    top = top < cy - r ? top : cy - r;
    right = right > cx + r ? right : cx + r;
    bottom = bottom > cy + r ? bottom : cy + r;
  }

  for (final leg in markLegs) {
    for (final point in leg) {
      include(point[0], point[1], markLegWidth / 2);
    }
  }
  for (final node in markNodes) {
    include(node[0], node[1], markNodeRadius);
  }
  for (final point in markBody) {
    include(point[0], point[1], markBodyWidth / 2);
  }
  include(markHeadCentre[0], markHeadCentre[1], markHeadRadius);

  return (
    width: right - left,
    height: bottom - top,
    centreX: (left + right) / 2,
    centreY: (top + bottom) / 2,
  );
}
