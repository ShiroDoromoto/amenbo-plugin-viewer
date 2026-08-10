/// A screen with nothing on it, saying what happened and what can be done about it.
///
/// One line in the middle of the glass is the shape an empty screen usually takes, and it is the
/// one shape that leaves the person stuck: it says the list is empty, which they can see, and
/// nothing about how to get out of it. Every empty face in this app therefore carries three
/// things — a mark, what happened, and what to do next — and a way on drawn as a button wherever
/// there is one to offer.
///
/// It is the arrangement the band already takes when a device has never had anything, because the
/// two are the same moment to the person reading: the app has nothing to show and owes them a next
/// step. Two shapes for that would be two things to learn.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

class EmptyFace extends StatelessWidget {
  const EmptyFace({
    super.key,
    required this.mark,
    required this.said,
    required this.detail,
    this.action,
  });

  /// What this is, in one glyph. It never carries meaning on its own — the line under it says the
  /// same thing in words.
  final IconData mark;

  /// What happened, in the voice of a fact rather than of a failure.
  final String said;

  /// What to do next. Always said, even where nothing here can do it: a person who knows the PC
  /// is the end to go to is not stuck, and one staring at an empty list is.
  final String detail;

  /// The way on, where this screen holds one. Null where the next step is somewhere else.
  final ({String label, VoidCallback onTap})? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final way = action;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.pageGutter,
        Space.emptyScreenTop,
        Space.pageGutter,
        Space.pageGutter,
      ),
      child: Column(
        children: [
          Icon(mark, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: Space.s3),
          Text(
            said,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: Space.s1),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (way != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.s5),
              child: FilledButton(onPressed: way.onTap, child: Text(way.label)),
            ),
        ],
      ),
    );
  }
}
