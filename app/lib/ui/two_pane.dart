/// A list and a detail, side by side once there is room.
///
/// The phone held upright is the common case, not the only one: the same build runs on a tablet
/// and on a phone turned sideways, and there a full-screen detail wastes half the glass and makes
/// the person go back to see where they were.
library;

import 'package:flutter/material.dart';

import 'measure.dart';
import 'tokens.dart';

class TwoPane extends StatelessWidget {
  const TwoPane({
    super.key,
    required this.list,
    required this.detail,
    this.placeholder,
  });

  final Widget list;

  /// What is open, or null when nothing is. On a narrow screen a non-null detail is the whole
  /// screen; a null one leaves the list showing.
  final Widget? detail;

  /// Shown in the right pane while nothing is open. Only ever seen when there are two panes.
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < Layout.twoPane) {
        return detail ?? list;
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The list keeps a readable measure and the detail takes the rest — a half-and-half
          // split gives the list more width than a row of text wants. It grows with the glass
          // between two bounds rather than staying at one width: fixed, every pixel a wider
          // screen brings lands on one side of the rule.
          SizedBox(width: _listWidth(constraints.maxWidth), child: list),
          const VerticalDivider(width: Stroke.rule),
          // And the side that takes the rest stops growing where a line of prose stops being
          // readable, sitting in the middle of what it was given — the same measure a page of
          // prose keeps wherever it is drawn.
          Expanded(
            child: Measured.prose(
              child: detail ?? placeholder ?? const SizedBox.shrink(),
            ),
          ),
        ],
      );
    },
  );

  /// A share of the width, held between the narrowest a list of rows reads well at and the widest
  /// it is worth drawing.
  static double _listWidth(double available) =>
      (available * Layout.listPaneShare).clamp(
        Layout.listPane,
        Layout.listPaneMax,
      );
}
