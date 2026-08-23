/// What a project menu carries when one of its items is picked.
///
/// "Every project" is a choice like any other, so it has to be a value like any other.
/// [PopupMenuButton] hands `null` back when the menu is dismissed, and cannot tell that apart from
/// an item whose value *is* `null` — so it drops the selection instead of reporting it. A menu that
/// spells "every project" as a bare `null` therefore has exactly one item that does nothing when
/// tapped, which is the one that undoes a narrowing.
///
/// Wrapping it moves the `null` inside the value, where nothing compares it against a dismissal.
library;

import 'package:flutter/foundation.dart';

@immutable
class ProjectChoice {
  const ProjectChoice(this.id);

  /// Narrow to nothing — every project stacked together.
  static const all = ProjectChoice(null);

  /// The project to narrow to, or `null` for [all].
  final int? id;

  @override
  bool operator ==(Object other) => other is ProjectChoice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
