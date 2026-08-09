/// The small marks a row wears — priority, state, lateness, unread, who is on it.
///
/// **None of them says anything with colour alone.** The screen is read at night, at arm's
/// length, and by people who do not separate the colours the same way, so every mark carries a
/// word or a shape that survives the colour being lost. Colour is the fastest of the three and it
/// is used — it is just never the only one.
///
/// They are also silent to a screen reader. A row is read as one sentence built by [rowLabel];
/// left to themselves these would interrupt it with the names of glyphs.
library;

import 'package:flutter/material.dart';

import 'time.dart';

/// amenbo's `high` / `medium` / `low`, or none at all.
class PriorityMark extends StatelessWidget {
  const PriorityMark(this.priority, {super.key});

  final String? priority;

  @override
  Widget build(BuildContext context) {
    if (priority == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    // Shape carries the ranking on its own: full, half, hollow.
    final (icon, colour) = switch (priority) {
      'high' => (Icons.circle, scheme.error),
      'medium' => (Icons.contrast, scheme.onSurface),
      _ => (Icons.circle_outlined, scheme.onSurfaceVariant),
    };
    return _Mark(
      icon: icon,
      colour: colour,
      text: _priorityWords[priority] ?? priority!,
    );
  }
}

const _priorityWords = {'high': 'High', 'medium': 'Med', 'low': 'Low'};

/// amenbo's status, for the places that show it outright — a detail, or a search result whose
/// row is not in a bundle that already says it.
class StatusMark extends StatelessWidget {
  const StatusMark(this.status, {super.key});

  final String status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, colour) = switch (status) {
      'in_progress' => (Icons.play_arrow, scheme.primary),
      'done' => (Icons.check, scheme.onSurfaceVariant),
      'rejected' => (Icons.close, scheme.onSurfaceVariant),
      'blocked' => (Icons.block, scheme.error),
      _ => (Icons.radio_button_unchecked, scheme.onSurfaceVariant),
    };
    return _Mark(icon: icon, colour: colour, text: statusWords(status));
  }
}

String statusWords(String status) => switch (status) {
  'todo' => 'Next',
  'in_progress' => 'In progress',
  'done' => 'Done',
  'rejected' => 'Rejected',
  'blocked' => 'Blocked',
  _ => status,
};

/// A due day, saying in words when it has passed.
///
/// Lateness is not a bundle of its own — it lifts a task to the top of the one it is already in —
/// so this is where a person finds out, and "Overdue" has to be written rather than implied by
/// the date turning red.
class DueMark extends StatelessWidget {
  const DueMark(this.dueOn, {super.key, required this.today});

  final String dueOn;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = dueLabel(dueOn, today: today);
    final late = isOverdue(dueOn, today: today);
    return _Mark(
      icon: late ? Icons.priority_high : Icons.event_outlined,
      colour: late ? scheme.error : scheme.onSurfaceVariant,
      text: label,
    );
  }
}

bool isOverdue(String dueOn, {required DateTime today}) =>
    dueOn.compareTo(isoDay(today)) < 0;

String dueLabel(String dueOn, {required DateTime today}) {
  final day = isoDay(today);
  if (dueOn.compareTo(day) < 0) return 'Overdue ${dayLabel(dueOn, now: today)}';
  if (dueOn == day) return 'Due today';
  return 'Due ${dayLabel(dueOn, now: today)}';
}

/// Not read since the person last looked.
///
/// A filled dot against nothing at all, so it reads as present or absent without needing the
/// colour to be seen — and it is the one mark that carries no word, because a row with nothing
/// new about it must not say "read".
class UnreadDot extends StatelessWidget {
  const UnreadDot({super.key, required this.unread});

  final bool unread;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: 16,
      child: unread
          ? Icon(
              Icons.circle,
              size: 8,
              color: Theme.of(context).colorScheme.primary,
            )
          : null,
    ),
  );
}

/// One line of text and its glyph.
class _Mark extends StatelessWidget {
  const _Mark({required this.icon, required this.colour, required this.text});

  final IconData icon;
  final Color colour;
  final String text;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(color: colour);
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The glyph follows the text size rather than sitting at a fixed one, or it shrinks
          // away as soon as someone turns their text up.
          Icon(icon, size: (style?.fontSize ?? 12) * 1.1, color: colour),
          const SizedBox(width: 4),
          Text(text, style: style),
        ],
      ),
    );
  }
}

/// Everything a row says, as one sentence.
///
/// A screen reader that walks the marks one at a time reads out a list of glyph names between
/// every two useful words. Rows are given this instead, and their contents are hidden — see
/// [SpokenAsOne].
String rowLabel({
  required String ref,
  required String title,
  required String status,
  String? priority,
  bool unread = false,
  String? assigneeKind,
  int comments = 0,
  String? due,
  String? stallReason,
  String? project,
  String? when,
}) => [
  if (unread) 'unread',
  ref,
  title,
  // Only where the row shows it — a list narrowed to one project would otherwise say the same
  // name on every line.
  ?project,
  statusWords(status),
  if (priority != null) '${_priorityWords[priority] ?? priority} priority',
  ?due,
  ?stallReason,
  ?when,
  if (assigneeKind == 'ai') 'assigned to AI',
  if (comments == 1) '1 comment' else if (comments > 1) '$comments comments',
].join(', ');

/// Reads [label] in place of whatever [child] would have said.
class SpokenAsOne extends StatelessWidget {
  const SpokenAsOne({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    container: true,
    button: true,
    child: ExcludeSemantics(child: child),
  );
}

/// A day as amenbo writes one, so a `due_on` or a `start_on` can be compared against today
/// without either side being parsed into an instant.
String isoDay(DateTime when) {
  final local = when.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}
