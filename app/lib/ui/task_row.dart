/// One task, as every list draws it.
///
/// Two lines and no more. The first is what the task is; the second is the little that decides
/// whether to open it — where it lives, why it is not moving, when it is due, who has it. The
/// notes are deliberately absent: a title that does not say what the task is will not be rescued
/// by the first forty characters of its body, and every row that carries an excerpt is a row that
/// fits fewer tasks on the glass.
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
///
/// **Every premise the store bundles as stalled has a line here.** A row that landed in the bundle
/// and then had nothing to say about why would be the one row on the screen that wastes its
/// second line — a start day still ahead included, which is a stall nobody has to do anything
/// about and therefore the easiest one to leave out.
String? stallReason(TaskLine line, {required DateTime today}) {
  final blocker = line.blockedBy;
  if (blocker != null) return '${taskRef(blocker)} is not finished';
  final undecided = line.undecided;
  if (undecided != null) return '${decisionRef(undecided)} is undecided';
  if (line.draft) return 'Still being written';
  final start = line.startOn;
  if (start != null && start.compareTo(isoDay(today)) > 0) {
    return 'Starts ${dayLabel(start, now: today)}';
  }
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final reason = stallReason(line, today: today);
    final moved = movedAt;

    final second = <Widget>[
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
