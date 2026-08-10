/// One decision, as a list draws it.
///
/// It is built to sit in the same list as a task row, which is why it keeps the same two-line
/// shape: title, then the little that says whether it is worth opening. What differs is what goes
/// on the second line — a decision has no priority, no due day and nothing blocking it, and the
/// one thing it does have is whether anybody has ruled on it yet.
library;

import 'package:flutter/material.dart';

import '../l10n/words.dart';
import '../store/backlog_queries.dart';
import 'marks.dart';
import 'refs.dart';
import 'theme.dart';
import 'time.dart';
import 'tokens.dart';

class DecisionRow extends StatelessWidget {
  const DecisionRow({
    super.key,
    required this.line,
    required this.today,
    required this.onOpen,
    this.projectName,
  });

  final DecisionLine line;

  /// The day the screen was drawn against, so a row and its neighbours agree on what "yesterday"
  /// was.
  final DateTime today;

  final VoidCallback onOpen;

  /// Null while the list is narrowed to one project.
  final String? projectName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final words = Words.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final excerpt = line.matchLine?.trim();
    // When it was decided if it was, when it was raised if it was not — either way, the date the
    // list is sorted by is the date the row shows.
    final when = DateTime.tryParse(line.decidedAt ?? line.createdAt);

    return SpokenAsOne(
      label: [
        decisionRef(line.id),
        line.title,
        ?projectName,
        decisionStatusWords(words, line.status),
        if (when != null) relativeTime(words, when, now: today),
        ?excerpt,
      ].join(', '),
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.gutter,
            vertical: Space.s4,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RowTitle(line.title),
              Padding(
                padding: const EdgeInsets.only(top: Space.hair),
                child: Row(
                  children: [
                    DecisionStatusMark(line.status),
                    if (projectName != null) ...[
                      _dot(quiet),
                      Flexible(
                        child: Text(
                          projectName!,
                          style: quiet,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    if (when != null) ...[
                      _dot(quiet),
                      Text(relativeTime(words, when, now: today), style: quiet),
                    ],
                  ],
                ),
              ),
              if (excerpt != null && excerpt.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: Space.hair),
                  child: Text(
                    excerpt,
                    style: quiet,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(TextStyle? style) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Space.s2),
    child: Text('·', style: style),
  );
}
