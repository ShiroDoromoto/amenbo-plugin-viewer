/// One look, for both platforms.
///
/// Material 3 is used as-is on iOS as well as Android. The app is read in bursts of well under a
/// minute, so the thing worth spending on is that a row reads the same wherever it is met — not
/// that a switch matches the platform it is drawn on.
///
/// Two rules are kept here rather than in each screen, because a screen that forgets one of them
/// looks fine to whoever wrote it:
///
/// * **nothing states its size.** Sizes come from the text theme, which follows the setting the
///   person made in their OS. A number written into a widget stops following it.
/// * **no state is carried by colour alone.** Priority, lateness and unread all come with a word
///   or a shape beside them — see `marks.dart`.
library;

import 'package:flutter/material.dart';

/// The seed the app was started with. Kept: it is already what the person has seen.
const seedColour = Colors.teal;

ThemeData viewerTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColour,
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    // Read at night as much as in daylight, and often one-handed on the move, so targets stay at
    // the platform's comfortable size rather than being tightened to fit more rows in.
    visualDensity: VisualDensity.standard,
    listTileTheme: const ListTileThemeData(
      // Rows carry two or three lines; a fixed height would either clip them or leave a gap once
      // the text size goes up.
      minVerticalPadding: 10,
    ),
  );
}

/// A title as every list draws it: it wraps to a second line and stops there.
///
/// At the largest text size a phone offers, a backlog title runs well past one line. Two lines is
/// what a row can give it without the rows around it being pushed off the screen, so the title
/// takes two and the rest is cut — which is legible, where an overflowing row is not.
class RowTitle extends StatelessWidget {
  const RowTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.titleMedium,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
  );
}

/// A heading over a bundle, with how many are in it.
///
/// The count is part of the heading rather than a badge: it is read out with the heading, and it
/// is the number the person is actually after when they glance at the screen.
class BundleHeading extends StatelessWidget {
  const BundleHeading({
    super.key,
    required this.title,
    this.count,
    this.expanded,
    this.onToggle,
  });

  final String title;

  /// Already capped by the store — `999+` is what a backlog past the cap says. Null where the
  /// heading is over a handful the person just left behind and counting them says nothing.
  final String? count;

  /// Whether the rows under it are showing, for a bundle that folds. Null for one that does not,
  /// and then the heading is not a button.
  final bool? expanded;

  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall;
    final folds = expanded != null;
    final heading = Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Row(
        children: [
          Expanded(child: Text(title, style: style)),
          if (count != null) Text(count!, style: style),
          if (folds)
            Icon(
              expanded! ? Icons.expand_less : Icons.expand_more,
              size: (style?.fontSize ?? 14) * 1.4,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    );
    return Semantics(
      header: true,
      container: true,
      button: folds,
      label: [
        title,
        ?count,
        if (folds) expanded! ? 'showing' : 'folded',
      ].join(', '),
      child: ExcludeSemantics(
        child: folds ? InkWell(onTap: onToggle, child: heading) : heading,
      ),
    );
  }
}
