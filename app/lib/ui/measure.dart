/// What stops a page from being as wide as the glass it is drawn on.
///
/// A phone gives a page one width and leaves nothing to decide. A tablet gives it a thousand
/// points, and a line that long is one the eye loses its place in coming back from — the return
/// sweep lands on the line it just read, or two below it. So a page stops where it stops reading
/// and sits in the middle of what it was given, rather than taking everything on offer.
///
/// **Two widths, because two things are being read.** Prose is read along the line, so it stops
/// where a line stops. A list is read down its left edge, so it stops sooner: past that, more
/// width only stretches titles nobody reads to the end of.
///
/// The numbers themselves are in one place ([Layout]) and not written per screen — the whole point
/// is that every page stops at the same place.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

class Measured extends StatelessWidget {
  /// A page read along its lines: a detail, a form, a page of instructions.
  const Measured.prose({super.key, required this.child})
    : width = Layout.readable;

  /// A page read down its left edge: rows.
  const Measured.rows({super.key, required this.child})
    : width = Layout.listPaneMax;

  /// The widest this page is drawn. Narrower glass is left alone.
  final double width;

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: width),
      child: child,
    ),
  );
}
