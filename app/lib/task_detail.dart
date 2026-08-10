/// One task, read to the end.
///
/// This is where a list stops being a list. The order down the screen is the order somebody reads
/// it in when they are standing somewhere with a few minutes: what it is, whether it can move at
/// all, what it says, what it is tied to, and only then the conversation.
///
/// **Why it is stuck comes before what it says.** Reading a whole set of notes and finding out at
/// the bottom that the task is waiting on something else is the one order that wastes the minutes
/// the person actually had.
library;

// The store's `Chip` is a category value on a task, which is what this screen means by the word
// every time it uses it. Material's widget of the same name is not drawn here.
import 'package:flutter/material.dart' hide Chip;

import 'l10n/words.dart';
import 'store/backlog_queries.dart';
import 'store/backlog_store.dart';
import 'ui/markdown.dart';
import 'ui/marks.dart';
import 'ui/refs.dart';
import 'ui/task_row.dart';
import 'ui/time.dart';
import 'ui/tokens.dart';

class TaskDetailScreen extends StatefulWidget {
  const TaskDetailScreen({
    super.key,
    required this.store,
    required this.taskId,
    required this.onOpenTask,
    required this.onOpenDecision,
    this.projectName,
    this.onProject,
    this.onValue,
    this.onLink,
    this.onShare = shareHandoff,
    this.clock = DateTime.now,
  });

  final BacklogStore store;
  final int taskId;

  final void Function(int taskId) onOpenTask;
  final void Function(int decisionId) onOpenDecision;

  /// Which project it belongs to. Shown whether or not a list was narrowed — the number names the
  /// task on its own, but where to go back to on the PC is written nowhere else.
  final String? projectName;
  final void Function(int projectId)? onProject;

  /// A category chip, pressed — the one list face, narrowed to that value.
  final void Function(int valueId)? onValue;

  /// A link in the body, pressed. Null leaves links as text; nothing is ever followed unasked.
  final void Function(String url)? onLink;

  /// Hands the three lines out to the OS. The app cannot write a word back to the backlog, so
  /// this and the number are the whole of what a thought had here can be carried away in.
  final Future<void> Function(String text) onShare;

  final DateTime Function() clock;

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  TaskLine? _task;
  String _notes = '';
  var _blockers = const <TaskLine>[];
  var _blocking = const <TaskLine>[];
  var _decisions = const <DecisionLine>[];
  var _chips = const <Chip>[];
  var _commits = const <String>[];
  var _attachments = const <AttachmentLine>[];
  var _comments = const <CommentLine>[];
  late Counted _commentCount;
  String? _lastLooked;
  bool _commitsOpen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TaskDetailScreen old) {
    super.didUpdateWidget(old);
    if (old.taskId != widget.taskId) setState(_load);
  }

  void _load() {
    final store = widget.store;
    final id = widget.taskId;
    _task = store.task(id);
    _notes = store.record('task', id)?['notes'] as String? ?? '';
    _blockers = store.blockers(id);
    _blocking = store.blocking(id);
    _decisions = store.decisionsFor(id);
    _chips = store.chips(id);
    _commits = store.commits(id);
    _attachments = store.attachments('task', id);
    _commentCount = store.commentCount(id);
    _lastLooked = store.meta(MetaKey.lastOpenedAt);
    _comments = _openingComments(store, id);
  }

  /// The newest few, opened back far enough to reach what has not been read.
  ///
  /// A conversation is read forwards, so the window sits at the end of it. Unread comments are
  /// marked where they are rather than lifted out of order — which only works if the window
  /// reaches them, hence the one extra page. Past that the person asks: a task somebody has left
  /// alone for a month is not a task whose whole timeline should load itself.
  List<CommentLine> _openingComments(BacklogStore store, int id) {
    final first = store.comments(id);
    if (first.isEmpty || !_unread(first.first.createdAt)) return first;
    return store.comments(id, limit: Windows.comments + Windows.commentPage);
  }

  void _readEarlier() {
    final oldest = _comments.isEmpty ? null : _comments.first.id;
    final more = widget.store.comments(
      widget.taskId,
      limit: Windows.commentPage,
      before: oldest,
    );
    if (more.isEmpty) return;
    setState(() => _comments = [...more, ..._comments]);
  }

  bool _unread(String stamp) {
    final since = _lastLooked;
    return since != null && stamp.compareTo(since) > 0;
  }

  @override
  Widget build(BuildContext context) {
    final task = _task;
    final today = widget.clock();
    final words = Words.of(context);
    return Scaffold(
      appBar: AppBar(
        actions: [
          // Only where there is something to send. A task the phone does not hold has a number
          // and nothing else, and a share sheet carrying one line is not the bridge this is for.
          if (task != null)
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: words.share,
              onPressed: () => widget.onShare(
                handoffText(
                  ref: taskRef(task.id),
                  title: task.title,
                  state: statusWords(words, task.status),
                ),
              ),
            ),
        ],
      ),
      body: task == null
          ? Center(child: Text(words.taskGone))
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                Space.gutter,
                Space.s3,
                Space.gutter,
                Space.s7,
              ),
              children: [
                _header(context, words, task, today),
                ..._stall(context, words, task, today),
                if (_notes.trim().isNotEmpty)
                  MarkdownSections(source: _notes, onLink: widget.onLink),
                ..._tiesSection(context, words),
                ..._chipsSection(context, words),
                ..._attachmentsSection(context, words),
                ..._commitsSection(context, words),
                ..._commentsSection(context, words, today),
              ],
            ),
    );
  }

  Widget _header(
    BuildContext context,
    Words words,
    TaskLine task,
    DateTime today,
  ) {
    final theme = Theme.of(context);
    final project = widget.projectName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RefChip(taskRef(task.id)),
        if (project != null)
          InkWell(
            onTap: widget.onProject == null
                ? null
                : () => widget.onProject!(task.projectId),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.s1),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    project,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  if (widget.onProject != null)
                    Icon(
                      Icons.chevron_right,
                      size:
                          (theme.textTheme.labelLarge?.fontSize ??
                              Lettering.md) *
                          1.2,
                      color: theme.colorScheme.primary,
                    ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.s1),
          child: Text(task.title, style: theme.textTheme.headlineSmall),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            StatusMark(task.status),
            if (task.priority != null) PriorityMark(task.priority),
            if (task.assigneeKind == 'ai')
              Text(words.markAi, style: theme.textTheme.labelMedium),
            TimeOnHold(
              when: DateTime.parse(task.updatedAt),
              child: Text(
                relativeTime(words, DateTime.parse(task.updatedAt), now: today),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (task.dueOn != null) DueMark(task.dueOn!, today: today),
            if (task.startOn != null)
              Text(
                words.stallStarts(dayLabel(words, task.startOn!, now: today)),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        const Divider(),
      ],
    );
  }

  List<Widget> _stall(
    BuildContext context,
    Words words,
    TaskLine task,
    DateTime today,
  ) {
    final reason = stallReason(words, task, today: today);
    if (reason == null) return const [];
    final theme = Theme.of(context);
    return [
      Container(
        padding: const EdgeInsets.all(Space.s4),
        margin: const EdgeInsets.only(bottom: Space.s5),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: Corner.smooth,
        ),
        child: Row(
          children: [
            Icon(Icons.report_outlined, color: theme.colorScheme.error),
            const SizedBox(width: Space.s3),
            Expanded(
              child: Text(
                reason,
                style: theme.textTheme.bodyMedium,
                semanticsLabel: '${words.detailStalled}, $reason',
              ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _tiesSection(BuildContext context, Words words) {
    if (_blockers.isEmpty && _blocking.isEmpty && _decisions.isEmpty) {
      return const [];
    }
    return [
      _sectionHeading(context, words.ties),
      for (final one in _blockers)
        _tie(
          context,
          lead: words.waitingOn,
          ref: taskRef(one.id),
          title: one.title,
          // Whether the other one is finished is the whole of what waiting means.
          state: statusWords(words, one.status),
          onTap: () => widget.onOpenTask(one.id),
        ),
      for (final one in _blocking)
        _tie(
          context,
          lead: words.waitedOnBy,
          ref: taskRef(one.id),
          title: one.title,
          state: statusWords(words, one.status),
          onTap: () => widget.onOpenTask(one.id),
        ),
      for (final one in _decisions)
        _tie(
          context,
          lead: words.decisionsSection,
          ref: decisionRef(one.id),
          title: one.title,
          state: decisionStatusWords(words, one.status),
          onTap: () => widget.onOpenDecision(one.id),
        ),
      const SizedBox(height: Space.s3),
    ];
  }

  Widget _tie(
    BuildContext context, {
    required String lead,
    required String ref,
    required String title,
    required String state,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return SpokenAsOne(
      label: '$lead, $ref, $title, $state',
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.s3),
          child: Row(
            children: [
              SizedBox(
                width: Layout.leadColumn,
                child: Text(
                  lead,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$ref  $state', style: theme.textTheme.labelMedium),
                    Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: theme.colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _chipsSection(BuildContext context, Words words) {
    if (_chips.isEmpty) return const [];
    return [
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final chip in _chips)
            ActionChip(
              label: Text(words.chipLabel(chip.dimension, chip.value)),
              onPressed: widget.onValue == null
                  ? null
                  : () => widget.onValue!(chip.valueId),
            ),
        ],
      ),
      const SizedBox(height: Space.s3),
    ];
  }

  List<Widget> _attachmentsSection(BuildContext context, Words words) {
    if (_attachments.isEmpty) return const [];
    final theme = Theme.of(context);
    return [
      _sectionHeading(context, words.attachments),
      Text(
        words.attachmentsStayOnThePc,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      for (final file in _attachments)
        // Deliberately not a button. A row that looks pressable and does nothing is worse than a
        // row that never offered.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.s2),
          child: Row(
            children: [
              Icon(
                Icons.attach_file,
                size:
                    (theme.textTheme.bodyMedium?.fontSize ?? Lettering.md) *
                    1.2,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: Space.s3),
              Expanded(child: Text(file.filename)),
              Text(
                fileSize(words, file.bytes),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: Space.s3),
    ];
  }

  List<Widget> _commitsSection(BuildContext context, Words words) {
    if (_commits.isEmpty) return const [];
    final theme = Theme.of(context);
    return [
      InkWell(
        onTap: () => setState(() => _commitsOpen = !_commitsOpen),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.s3),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${words.commits} ${_commits.length}',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Icon(_commitsOpen ? Icons.expand_less : Icons.expand_more),
            ],
          ),
        ),
      ),
      if (_commitsOpen)
        for (final sha in _commits)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.hair),
            child: Text(
              // Nothing here can open one. The short form is what a person types on the PC.
              sha.substring(0, sha.length < 12 ? sha.length : 12),
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
      const SizedBox(height: Space.s3),
    ];
  }

  List<Widget> _commentsSection(
    BuildContext context,
    Words words,
    DateTime today,
  ) {
    if (_commentCount.value == 0) return const [];
    final theme = Theme.of(context);
    return [
      _sectionHeading(
        context,
        '${words.commentsSection} ${countLabel(words, _commentCount)}',
      ),
      if (_comments.length < _commentCount.value)
        TextButton(onPressed: _readEarlier, child: Text(words.readEarlier)),
      for (final one in _comments)
        Padding(
          padding: const EdgeInsets.only(bottom: Space.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  UnreadDot(unread: _unread(one.createdAt)),
                  Text(
                    one.authorKind == 'ai' ? words.markAi : words.markYou,
                    style: theme.textTheme.labelMedium,
                  ),
                  const SizedBox(width: Space.s3),
                  TimeOnHold(
                    when: DateTime.parse(one.createdAt),
                    child: Text(
                      relativeTime(
                        words,
                        DateTime.parse(one.createdAt),
                        now: today,
                      ),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              MarkdownBody(
                blocks: parseMarkdown(one.text),
                onLink: widget.onLink,
              ),
            ],
          ),
        ),
    ];
  }

  Widget _sectionHeading(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(top: Space.s3, bottom: Space.s1),
    child: Semantics(
      header: true,
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    ),
  );
}

/// A file's size, near enough. The row exists to say the file is there and roughly how big — a
/// figure to the byte would be precision about something nobody can open.
String fileSize(Words words, int bytes) {
  if (bytes < 1024) return words.fileSizeBytes(bytes);
  if (bytes < 1024 * 1024) {
    return words.fileSizeKilobytes((bytes / 1024).round());
  }
  return words.fileSizeMegabytes((bytes / (1024 * 1024)).toStringAsFixed(1));
}
