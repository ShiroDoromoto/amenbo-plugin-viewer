/// A list and a detail, side by side once there is room.
///
/// The phone held upright is the common case, not the only one: the same build runs on a tablet
/// and on a phone turned sideways, and there a full-screen detail wastes half the glass and makes
/// the person go back to see where they were.
library;

import 'package:flutter/material.dart';

/// Where one pane becomes two.
///
/// Below it, no phone held upright qualifies; above it, a phone turned sideways and every tablet
/// do. It is a width, not a device: asking what kind of machine this is gets the answer wrong for
/// the same machine held the other way.
const twoPaneWidth = 720.0;

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
      if (constraints.maxWidth < twoPaneWidth) {
        return detail ?? list;
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The list keeps a readable measure and the detail takes the rest — a half-and-half
          // split gives the list more width than a row of text wants.
          SizedBox(width: 360, child: list),
          const VerticalDivider(width: 1),
          Expanded(child: detail ?? placeholder ?? const SizedBox.shrink()),
        ],
      );
    },
  );
}
