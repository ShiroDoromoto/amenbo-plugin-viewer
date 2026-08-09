/// One task, as every list draws it.
///
/// Two lines. The first is what the task is; the second is the little that decides whether to open
/// it — where it lives, why it is not moving, when it is due, who has it. The notes are
/// deliberately absent: a title that does not say what the task is will not be rescued by the
/// first forty characters of its body, and every row that carries an excerpt is a row that fits
/// fewer tasks on the glass.
///
/// A row that came out of a search gets a third line, and only there: when the word was found in a
/// body or a comment rather than in the title, the stretch around it is the answer to "why is this
/// one in my results", which nothing else on the row can give.
library;

import 'package:flutter/material.dart';

import '../store/backlog_queries.dart';
import 'marks.dart';
import 'refs.dart';
import 'theme.dart';
import 'time.dart';

/// A count as a heading prints it.
String countLabel(Counted counted) =>
    counted.overflowed ? '${Counted.cap}+' : '${counted.value}';

/// Why a task cannot be started, in the words the person needs in order to act.
///
/// A named blocker comes first because it is the only one that says what to go and do. `blocked`
/// comes last for the same reason from the other end: it is amenbo's word for a stall nobody has
/// written down, so it is what is left when there is nothing more useful to say.
String? stallReason(TaskLine line) {
  final blocker = line.blockedBy;
  if (blocker != null) return '${taskRef(blocker)} is not finished';
  final undecided = line.undecided;
  if (undecided != null) return '${decisionRef(undecided)} is undecided';
  if (line.draft) return 'Still being written';
  if (line.status == 'blocked') return 'Blocked';
  return null;
}

class TaskRow extends StatelessWidget {
  const TaskRow({
    super.key,
    required this.line,
    required this.today,
    required this.onOpen,
    this.projectName,
    this.movedAt,
    this.unread = false,
    this.showStatus = false,
  });

  final TaskLine line;

  /// The day the whole screen was drawn against, so a row and the heading over it cannot disagree
  /// about whether something is late.
  final DateTime today;

  final VoidCallback onOpen;

  /// Null while the list is narrowed to one project — repeating the same name down every row
  /// only takes width away from the titles.
  final String? projectName;

  /// When it last moved, for the one bundle where movement is the subject. Elsewhere freshness is
  /// not what the person is judging, and a time on every row reads as noise.
  final DateTime? movedAt;

  final bool unread;

  /// Whether to say what state it is in. A bundle already said it in its heading; a search result
  /// stands on its own, and there the state is half of what the person came back to find out.
  final bool showStatus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final reason = stallReason(line);
    final moved = movedAt;

    final excerpt = line.matchLine?.trim();

    final second = <Widget>[
      if (showStatus) StatusMark(line.status),
      if (projectName != null)
        // The first thing to be cut when the line will not fit: which project a task is in is
        // worth knowing, and never worth as much as why it is stuck or when it is due.
        Flexible(
          child: Text(
            projectName!,
            style: quiet,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      if (reason != null)
        Flexible(
          flex: 3,
          child: Text(
            reason,
            style: quiet,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        )
      else if (line.dueOn != null)
        DueMark(line.dueOn!, today: today),
      if (line.assigneeKind == 'ai') Text('AI', style: quiet),
      if (moved != null) Text(relativeTime(moved, now: today), style: quiet),
      if (line.comments > 0)
        Text(
          '${line.comments} ${line.comments == 1 ? 'comment' : 'comments'}',
          style: quiet,
        ),
    ];

    return SpokenAsOne(
      label: rowLabel(
        ref: taskRef(line.id),
        title: line.title,
        status: line.status,
        priority: line.priority,
        unread: unread,
        assigneeKind: line.assigneeKind,
        comments: line.comments,
        due: reason == null && line.dueOn != null
            ? dueLabel(line.dueOn!, today: today)
            : null,
        stallReason: reason,
        project: projectName,
        when: moved == null ? null : relativeTime(moved, now: today),
        excerpt: excerpt,
      ),
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UnreadDot(unread: unread),
                  PriorityMark(line.priority),
                  const SizedBox(width: 8),
                  Expanded(child: RowTitle(line.title)),
                ],
              ),
              if (second.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: _Separated(children: second),
                ),
              if (excerpt != null && excerpt.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
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
}

/// The second line's parts, with a dot between them.
class _Separated extends StatelessWidget {
  const _Separated({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final dot = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        '·',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return Row(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) dot,
          children[i],
        ],
      ],
    );
  }
}
