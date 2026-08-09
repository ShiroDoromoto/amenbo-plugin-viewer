/// The reading half of the store: windows, and nothing wider.
///
/// Every list here comes back at a stated size. The backlog is a thing people add to and never
/// empty, so "read it all and filter in Dart" is a size that only ever grows, and on iOS an app
/// holding it gets dropped from memory the moment it goes behind — which is exactly when it is
/// about to be brought back to the front.
///
/// The counts follow the same rule: a screen shows how many are in a bundle, so the count stops
/// at [Counted.cap] instead of walking to the end of a backlog to produce a number that is
/// displayed as `999+` anyway.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'backlog_store.dart';

/// The four bundles the front screen stacks, in the order it stacks them.
enum Bundle {
  /// `in_progress` — what the AI has its hands on.
  moving,

  /// A premise is missing, or it is `blocked`. The screen writes the reason out, so the query
  /// carries the blocker and the undecided decision with the row.
  stalled,

  /// `todo` with every premise met.
  next,

  /// Closed within the last week.
  finished,
}

/// The three things the "since you last looked" card counts.
///
/// They are the three shapes an overnight change comes in: work that ended, work that appeared,
/// and somebody writing. Anything finer would be a report, and the card is read in the two seconds
/// before the person decides whether to scroll.
enum Moved {
  /// Closed — `done` or `rejected`.
  finished,

  /// Filed on the PC since.
  filed,

  /// Written on a task since.
  commented,
}

/// How many rows a face holds at once.
class Windows {
  /// A bundle on the front screen. Past this it says "N more" and the rest is another face.
  static const bundle = 20;

  /// The one list face — search, the rest of a bundle, the tasks under a category value.
  static const list = 50;

  /// What a task's detail opens with. Older ones are pulled [commentPage] at a time.
  static const comments = 3;
  static const commentPage = 20;
}

/// A count that stopped early.
class Counted {
  const Counted(this.value, this.overflowed);

  /// Counting stops here. A backlog can hold any number of anything, and no screen shows the
  /// difference between 1,000 and 40,000.
  static const cap = 999;

  final int value;

  /// The real number is [cap] or more. Screens show `999+`.
  final bool overflowed;
}

/// One row as a list shows it.
///
/// It carries no body: a list line is the title and the state, and the screens deliberately do
/// not print an excerpt of the notes under it.
class TaskLine {
  const TaskLine({
    required this.id,
    required this.projectId,
    required this.title,
    required this.status,
    required this.priority,
    required this.assigneeKind,
    required this.draft,
    required this.dueOn,
    required this.startOn,
    required this.updatedAt,
    required this.closedAt,
    required this.comments,
    required this.blockedBy,
    required this.undecided,
    required this.excerpt,
    required this.matchedIn,
  });

  final int id;
  final int projectId;
  final String title;
  final String status;
  final String? priority;
  final String? assigneeKind;

  /// The task is still being written on the PC — one of the reasons it is stalled.
  final bool draft;
  final String? dueOn;
  final String? startOn;
  final String updatedAt;

  /// When it was closed, for the "finished" bundle.
  final String? closedAt;
  final int comments;

  /// The first unfinished task it waits on, if any. The screen turns it into the line of text
  /// that says what to go and do.
  final int? blockedBy;

  /// The first linked decision nobody has ruled on, if any.
  final int? undecided;

  /// The stretch of text a search matched, when the line came out of a search.
  final String? excerpt;

  /// Where that stretch was found — `title`, `body` or `comment`.
  final String? matchedIn;

  /// The line a list puts under the row to say why the row is in it.
  ///
  /// Null for a title hit: the row already shows the title, and repeating it underneath says only
  /// that the search worked.
  String? get matchLine =>
      matchedIn == null || matchedIn == 'title' ? null : excerpt;
}

/// One decision as a list shows it.
class DecisionLine {
  const DecisionLine({
    required this.id,
    required this.projectId,
    required this.title,
    required this.status,
    required this.createdAt,
    required this.decidedAt,
    required this.excerpt,
    this.matchedIn,
  });

  final int id;
  final int projectId;
  final String title;

  /// `proposed` / `accepted` / `rejected`.
  final String status;
  final String createdAt;
  final String? decidedAt;
  final String? excerpt;

  /// Where a search matched — see [TaskLine.matchedIn].
  final String? matchedIn;

  String? get matchLine =>
      matchedIn == null || matchedIn == 'title' ? null : excerpt;
}

/// One comment, with its text — the one place a list does carry a body, because the body is the
/// whole of what a comment is.
class CommentLine {
  const CommentLine({
    required this.id,
    required this.authorKind,
    required this.createdAt,
    required this.text,
  });

  final int id;
  final String? authorKind;
  final String createdAt;
  final String text;
}

/// A category value on a task — the chip in the detail, and one of the five inputs to the list
/// face.
class Chip {
  const Chip({
    required this.dimensionId,
    required this.dimension,
    required this.valueId,
    required this.value,
  });

  final int dimensionId;
  final String dimension;
  final int valueId;
  final String value;
}

/// A file the PC holds and the phone does not. The row is all that travels.
class AttachmentLine {
  const AttachmentLine({
    required this.id,
    required this.filename,
    required this.bytes,
  });

  final int id;
  final String filename;
  final int bytes;
}

/// A decision standing on, or replacing, another one.
class DecisionEdgeLine {
  const DecisionEdgeLine({
    required this.targetId,
    required this.kind,
    required this.title,
    required this.status,
  });

  final int targetId;

  /// `builds_on`, `supersedes`, `amends` — amenbo's own word for the edge.
  final String kind;
  final String title;
  final String status;
}

/// What a list face was asked for. All five inputs are optional and they combine.
///
/// One face answers every list in the app — search results, the rest of a bundle, the tasks under
/// a category value, what changed since a moment, one project — so the screens do not multiply
/// with the ways of arriving at a list.
class TaskQuery {
  const TaskQuery({
    this.text,
    this.bundle,
    this.valueId,
    this.changedSince,
    this.projectId,
  });

  /// What was typed. Matched through the index, never by walking every row.
  final String? text;
  final Bundle? bundle;

  /// A category value (`dimension_value.id`), from a chip in a detail.
  final int? valueId;

  /// Only what moved after this instant — what the "since you last looked" card opens into.
  final DateTime? changedSince;

  /// Every project on the machine arrives, so every face has to be able to narrow to one.
  final int? projectId;
}

extension BacklogQueries on BacklogStore {
  // ------------------------------------------------------------- the front screen

  /// One bundle's window, and how many are in it.
  ///
  /// [today] is passed in rather than read from the clock so that a bundle drawn at 23:59 and the
  /// count beside it cannot disagree about which day it is.
  ({List<TaskLine> rows, Counted total}) bundle(
    Bundle bundle, {
    required DateTime today,
    int? projectId,
    int limit = Windows.bundle,
    int offset = 0,
  }) {
    final where = _bundleWhere(bundle, today, projectId);
    final rows = db.select(
      'SELECT ${_taskColumns()} FROM task t WHERE ${where.sql} '
      'ORDER BY ${_bundleOrder(bundle, today)} LIMIT ? OFFSET ?',
      [...where.args, ..._orderArgs(bundle, today), limit, offset],
    );
    return (
      rows: rows.map(_taskLine).toList(growable: false),
      total: _count('SELECT 1 FROM task t WHERE ${where.sql}', where.args),
    );
  }

  // ------------------------------------------------------------- the one list face

  List<TaskLine> tasks(
    TaskQuery query, {
    required DateTime today,
    int limit = Windows.list,
    int offset = 0,
  }) {
    final search = _searchJoin(query.text, 'task');
    final where = _listWhere(query, today);
    final order = query.bundle == null
        ? 't.updated_at DESC, t.id DESC'
        : _bundleOrder(query.bundle!, today);
    final rows = db.select(
      'SELECT ${_taskColumns(excerpt: search != null)} FROM task t ${search?.sql ?? ''} '
      'WHERE ${where.sql} ORDER BY $order LIMIT ? OFFSET ?',
      [
        ...?search?.args,
        ...where.args,
        if (query.bundle != null) ..._orderArgs(query.bundle!, today),
        limit,
        offset,
      ],
    );
    return rows.map(_taskLine).toList(growable: false);
  }

  Counted taskCount(TaskQuery query, {required DateTime today}) {
    final search = _searchJoin(query.text, 'task');
    final where = _listWhere(query, today);
    return _count(
      'SELECT 1 FROM task t ${search?.sql ?? ''} WHERE ${where.sql}',
      [...?search?.args, ...where.args],
    );
  }

  /// The other tab of the search face, and — with an empty query — the list of decisions by date
  /// that is the only way to reach one nothing links to.
  List<DecisionLine> decisions({
    String? text,
    int? projectId,
    int limit = Windows.list,
    int offset = 0,
  }) {
    final search = _searchJoin(text, 'decision');
    final clauses = <String>['1 = 1'];
    final args = <Object?>[];
    if (projectId != null) {
      clauses.add('d.project_id = ?');
      args.add(projectId);
    }
    final rows = db.select(
      'SELECT d.id, d.project_id, d.title, d.status, d.created_at, d.decided_at'
      '${search == null ? '' : ', h.excerpt AS excerpt, h.source AS matched_in'} '
      'FROM decision d ${search?.sql.replaceAll('t.id', 'd.id') ?? ''} '
      'WHERE ${clauses.join(' AND ')} '
      'ORDER BY d.created_at DESC, d.id DESC LIMIT ? OFFSET ?',
      [...?search?.args, ...args, limit, offset],
    );
    return rows
        .map(
          (row) => DecisionLine(
            id: row['id'] as int,
            projectId: row['project_id'] as int,
            title: row['title'] as String,
            status: row['status'] as String,
            createdAt: row['created_at'] as String,
            decidedAt: row['decided_at'] as String?,
            excerpt: search == null ? null : row['excerpt'] as String?,
            matchedIn: search == null ? null : row['matched_in'] as String?,
          ),
        )
        .toList(growable: false);
  }

  Counted decisionCount({String? text, int? projectId}) {
    final search = _searchJoin(text, 'decision');
    final clauses = <String>['1 = 1'];
    final args = <Object?>[];
    if (projectId != null) {
      clauses.add('d.project_id = ?');
      args.add(projectId);
    }
    return _count(
      'SELECT 1 FROM decision d ${search?.sql.replaceAll('t.id', 'd.id') ?? ''} '
      'WHERE ${clauses.join(' AND ')}',
      [...?search?.args, ...args],
    );
  }

  // ------------------------------------------------------------- one record

  /// The row exactly as it arrived — where a detail screen reads the long text from.
  Map<String, Object?>? record(String dataset, int id) {
    final rows = db.select(
      'SELECT raw FROM record WHERE dataset = ? AND id = ?',
      [dataset, id],
    );
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['raw'] as String) as Map<String, Object?>;
  }

  /// One decision, for the places that hold its number and nothing else.
  DecisionLine? decision(int id) {
    final rows = db.select(
      'SELECT d.id, d.project_id, d.title, d.status, d.created_at, d.decided_at '
      'FROM decision d WHERE d.id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return DecisionLine(
      id: row['id'] as int,
      projectId: row['project_id'] as int,
      title: row['title'] as String,
      status: row['status'] as String,
      createdAt: row['created_at'] as String,
      decidedAt: row['decided_at'] as String?,
      excerpt: null,
    );
  }

  /// One task's line. No day is needed: nothing about a single row depends on which day it is —
  /// what does (lateness, a start day still ahead) is decided by the screen that draws it.
  TaskLine? task(int id) {
    final rows = db.select(
      'SELECT ${_taskColumns()} FROM task t WHERE t.id = ?',
      [id],
    );
    return rows.isEmpty ? null : _taskLine(rows.first);
  }

  /// A task's comments, newest last, taken from the end.
  ///
  /// The detail opens on the last [Windows.comments] and walks backwards [Windows.commentPage] at
  /// a time, so [before] is the oldest id already on screen.
  List<CommentLine> comments(
    int taskId, {
    int limit = Windows.comments,
    int? before,
  }) => _comments(
    table: 'task_comment',
    owner: 'task_id',
    dataset: 'task_comment',
    ownerId: taskId,
    limit: limit,
    before: before,
  );

  List<CommentLine> decisionComments(
    int decisionId, {
    int limit = Windows.comments,
    int? before,
  }) => _comments(
    table: 'decision_comment',
    owner: 'decision_id',
    dataset: 'decision_comment',
    ownerId: decisionId,
    limit: limit,
    before: before,
  );

  Counted commentCount(int taskId) =>
      _count('SELECT 1 FROM task_comment WHERE task_id = ?', [taskId]);

  /// What this task waits on, with the other side's state — whether the other one is finished is
  /// the whole of what waiting means.
  List<TaskLine> blockers(int taskId) => _relatedTasks(
    'JOIN task_dependency d ON d.blocked_by_id = t.id WHERE d.task_id = ?',
    taskId,
  );

  /// What waits on this task.
  List<TaskLine> blocking(int taskId) => _relatedTasks(
    'JOIN task_dependency d ON d.task_id = t.id WHERE d.blocked_by_id = ?',
    taskId,
  );

  List<DecisionLine> decisionsFor(int taskId) {
    final rows = db.select(
      'SELECT d.id, d.project_id, d.title, d.status, d.created_at, d.decided_at '
      'FROM decision d JOIN decision_task_link l ON l.decision_id = d.id '
      'WHERE l.task_id = ? ORDER BY d.id',
      [taskId],
    );
    return rows
        .map(
          (row) => DecisionLine(
            id: row['id'] as int,
            projectId: row['project_id'] as int,
            title: row['title'] as String,
            status: row['status'] as String,
            createdAt: row['created_at'] as String,
            decidedAt: row['decided_at'] as String?,
            excerpt: null,
          ),
        )
        .toList(growable: false);
  }

  List<TaskLine> tasksFor(int decisionId) => _relatedTasks(
    'JOIN decision_task_link l ON l.task_id = t.id WHERE l.decision_id = ?',
    decisionId,
  );

  List<DecisionEdgeLine> edgesFor(int decisionId) {
    final rows = db.select(
      'SELECT e.target_decision_id, e.kind, d.title, d.status '
      'FROM decision_edge e JOIN decision d ON d.id = e.target_decision_id '
      'WHERE e.decision_id = ? ORDER BY e.id',
      [decisionId],
    );
    return rows
        .map(
          (row) => DecisionEdgeLine(
            targetId: row['target_decision_id'] as int,
            kind: row['kind'] as String,
            title: row['title'] as String,
            status: row['status'] as String,
          ),
        )
        .toList(growable: false);
  }

  List<Chip> chips(int taskId) {
    final rows = db.select(
      'SELECT m.id AS dimension_id, m.name AS dimension, v.id AS value_id, v.name AS value '
      'FROM task_dimension_value x '
      'JOIN dimension m ON m.id = x.dimension_id '
      'JOIN dimension_value v ON v.id = x.value_id '
      'WHERE x.task_id = ? ORDER BY m.order_key, v.order_key',
      [taskId],
    );
    return rows
        .map(
          (row) => Chip(
            dimensionId: row['dimension_id'] as int,
            dimension: row['dimension'] as String,
            valueId: row['value_id'] as int,
            value: row['value'] as String,
          ),
        )
        .toList(growable: false);
  }

  /// The commit SHAs recorded on a task. Nothing on the phone can open one; the count is what
  /// says whether the work landed.
  List<String> commits(int taskId) => db
      .select(
        'SELECT sha FROM task_commit WHERE task_id = ? ORDER BY created_at, id',
        [taskId],
      )
      .map((row) => row['sha'] as String)
      .toList(growable: false);

  List<AttachmentLine> attachments(String targetType, int targetId) => db
      .select(
        'SELECT id, filename, size_bytes FROM attachment '
        'WHERE target_type = ? AND target_id = ? ORDER BY order_key, id',
        [targetType, targetId],
      )
      .map(
        (row) => AttachmentLine(
          id: row['id'] as int,
          filename: row['filename'] as String,
          bytes: row['size_bytes'] as int,
        ),
      )
      .toList(growable: false);

  /// The projects the machine sent, in the order amenbo holds them.
  ///
  /// Archived ones are left out by default, because nothing in a project nobody adds to any more
  /// belongs in "what to do when I get back". Search asks with [includeArchived] set: remembering
  /// how something ended up is exactly what an archived project is kept for.
  List<({int id, String name})> projects({bool includeArchived = false}) => db
      .select(
        'SELECT id, name FROM project '
        '${includeArchived ? '' : 'WHERE archived = 0 '}'
        'ORDER BY order_key, id',
      )
      .map((row) => (id: row['id'] as int, name: row['name'] as String))
      .toList(growable: false);

  /// One category value, named by the dimension it belongs to — what a narrowing arriving from a
  /// chip calls itself once the chip is behind it.
  ({String dimension, String value})? dimensionValue(int id) {
    final rows = db.select(
      'SELECT m.name AS dimension, v.name AS value FROM dimension_value v '
      'JOIN dimension m ON m.id = v.dimension_id WHERE v.id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    return (
      dimension: rows.first['dimension'] as String,
      value: rows.first['value'] as String,
    );
  }

  /// The newest change any task in view carries, as the PC stamped it.
  ///
  /// The front screen takes this when it draws and hands it back to [movedSince] later, so "what
  /// arrived while you were reading" is decided on the PC's clock at both ends. The phone's own
  /// clock never enters it, and a phone whose clock is wrong still counts correctly.
  String? latestTaskChange({int? projectId}) {
    final rows = db.select(
      'SELECT MAX(t.updated_at) AS newest FROM task t '
      'WHERE $_liveProject${projectId == null ? '' : ' AND t.project_id = ?'}',
      [?projectId],
    );
    return rows.first['newest'] as String?;
  }

  /// How many tasks changed after [stamp] — the number on the pill that waits to be pressed.
  ///
  /// A null [stamp] is a screen that drew before anything had arrived, so everything counts.
  Counted movedSince(String? stamp, {int? projectId}) => _count(
    'SELECT 1 FROM task t WHERE $_liveProject'
    '${stamp == null ? '' : ' AND t.updated_at > ?'}'
    '${projectId == null ? '' : ' AND t.project_id = ?'}',
    [?stamp, ?projectId],
  );

  /// What has happened since [stamp] — the three numbers on the card at the top of the screen.
  ///
  /// They are counted inside whatever narrowing the screen is holding. A card that counts the
  /// whole machine while the bundles under it count one project would send the person, from a
  /// number they pressed, to a list of a different length.
  ///
  /// [stamp] is the moment the app was last brought to the front, so this is deliberately not the
  /// same question as [movedSince], which asks what arrived while the screen was being read.
  Map<Moved, Counted> sinceLastLook(String stamp, {int? projectId}) {
    final narrowed = projectId == null ? '' : ' AND t.project_id = ?';
    final args = [stamp, ?projectId];
    return {
      Moved.finished: _count(
        'SELECT 1 FROM task t WHERE $_liveProject '
        "AND t.status IN ('done', 'rejected') "
        'AND COALESCE(t.completed_at, t.status_changed_at, t.updated_at) > ?'
        '$narrowed',
        args,
      ),
      Moved.filed: _count(
        'SELECT 1 FROM task t WHERE $_liveProject AND t.created_at > ?$narrowed',
        args,
      ),
      // Left join, so a comment that arrived ahead of the task it belongs to is still counted
      // while nothing is narrowed — pages land in the order the place hands them over, and a row
      // that is merely early must not go missing. Narrowed, it cannot be placed, so it is out.
      Moved.commented: _count(
        'SELECT 1 FROM task_comment c LEFT JOIN task t ON t.id = c.task_id '
        'WHERE $_liveProject AND c.created_at > ?$narrowed',
        args,
      ),
    };
  }

  // ------------------------------------------------------------- internals

  List<CommentLine> _comments({
    required String table,
    required String owner,
    required String dataset,
    required int ownerId,
    required int limit,
    int? before,
  }) {
    final rows = db.select(
      'SELECT c.id, c.author_kind, c.created_at, '
      "json_extract(r.raw, '\$.text') AS text "
      'FROM $table c JOIN record r ON r.dataset = ? AND r.id = c.id '
      'WHERE c.$owner = ?${before == null ? '' : ' AND c.id < ?'} '
      'ORDER BY c.created_at DESC, c.id DESC LIMIT ?',
      [dataset, ownerId, ?before, limit],
    );
    // Read newest-first so the window comes off the end, then hand them back oldest-first: a
    // comment thread is a conversation, and a conversation is read forwards.
    return rows.reversed
        .map(
          (row) => CommentLine(
            id: row['id'] as int,
            authorKind: row['author_kind'] as String?,
            createdAt: row['created_at'] as String,
            text: row['text'] as String? ?? '',
          ),
        )
        .toList(growable: false);
  }

  List<TaskLine> _relatedTasks(String join, int id) => db
      .select('SELECT ${_taskColumns()} FROM task t $join ORDER BY t.id', [id])
      .map(_taskLine)
      .toList(growable: false);

  Counted _count(String inner, List<Object?> args) {
    final rows = db.select(
      'SELECT COUNT(*) AS n FROM ($inner LIMIT ${Counted.cap + 1})',
      args,
    );
    final n = rows.first['n'] as int;
    return n > Counted.cap
        ? const Counted(Counted.cap, true)
        : Counted(n, false);
  }
}

/// A missing premise, stated once. Four things hold a task back, and every face that asks
/// "can this be started" asks it with these.
const _openBlocker =
    'EXISTS (SELECT 1 FROM task_dependency d '
    'JOIN task b ON b.id = d.blocked_by_id '
    "WHERE d.task_id = t.id AND b.status NOT IN ('done', 'rejected'))";

const _unsettledDecision =
    'EXISTS (SELECT 1 FROM decision_task_link l '
    'JOIN decision c ON c.id = l.decision_id '
    "WHERE l.task_id = t.id AND c.status = 'proposed')";

const _notStarted = '(t.start_on IS NOT NULL AND t.start_on > ?)';

const _stillDraft = 't.draft = 1';

String _readySql() =>
    'NOT ($_openBlocker OR $_unsettledDecision OR $_notStarted OR $_stillDraft)';

String _taskColumns({bool excerpt = false}) =>
    't.id, t.project_id, t.title, t.status, t.priority, t.assignee_kind, t.draft, '
    't.due_on, t.start_on, t.updated_at, '
    'COALESCE(t.completed_at, t.status_changed_at) AS closed_at, '
    '(SELECT COUNT(*) FROM task_comment c WHERE c.task_id = t.id) AS comments, '
    '(SELECT d.blocked_by_id FROM task_dependency d JOIN task b ON b.id = d.blocked_by_id '
    "WHERE d.task_id = t.id AND b.status NOT IN ('done', 'rejected') "
    'ORDER BY d.blocked_by_id LIMIT 1) AS blocked_by, '
    '(SELECT l.decision_id FROM decision_task_link l JOIN decision c ON c.id = l.decision_id '
    "WHERE l.task_id = t.id AND c.status = 'proposed' "
    'ORDER BY l.decision_id LIMIT 1) AS undecided'
    '${excerpt ? ', h.excerpt AS excerpt, h.source AS matched_in' : ''}';

TaskLine _taskLine(Row row) => TaskLine(
  id: row['id'] as int,
  projectId: row['project_id'] as int,
  title: row['title'] as String,
  status: row['status'] as String,
  priority: row['priority'] as String?,
  assigneeKind: row['assignee_kind'] as String?,
  draft: row['draft'] == 1,
  dueOn: row['due_on'] as String?,
  startOn: row['start_on'] as String?,
  updatedAt: row['updated_at'] as String,
  closedAt: row['closed_at'] as String?,
  comments: row['comments'] as int,
  blockedBy: row['blocked_by'] as int?,
  undecided: row['undecided'] as int?,
  excerpt: row.keys.contains('excerpt') ? row['excerpt'] as String? : null,
  matchedIn: row.keys.contains('matched_in')
      ? row['matched_in'] as String?
      : null,
);

({String sql, List<Object?> args}) _bundleWhere(
  Bundle bundle,
  DateTime today,
  int? projectId,
) {
  final day = _day(today);
  final clauses = <String>[];
  final args = <Object?>[];
  switch (bundle) {
    case Bundle.moving:
      clauses.add("t.status = 'in_progress'");
    case Bundle.stalled:
      clauses.add(
        "(t.status = 'blocked' OR (t.status = 'todo' AND NOT ${_readySql()}))",
      );
      args.add(day);
    case Bundle.next:
      clauses.add("t.status = 'todo' AND ${_readySql()}");
      args.add(day);
    case Bundle.finished:
      clauses.add(
        "t.status IN ('done', 'rejected') "
        'AND COALESCE(t.completed_at, t.status_changed_at, t.updated_at) >= ?',
      );
      args.add(amenboStamp(today.subtract(const Duration(days: 7))));
  }
  clauses.add(_liveProject);
  if (projectId != null) {
    clauses.add('t.project_id = ?');
    args.add(projectId);
  }
  return (sql: clauses.join(' AND '), args: args);
}

/// A task a bundle may hold at all: its project is one the person still works in.
///
/// Archived is amenbo's word for a project nobody adds to any more, so nothing in it belongs in
/// "what to do when I get back". Search still reaches it — remembering how something ended up is
/// exactly what an archived project is kept for.
///
/// A task whose project row has not arrived yet counts as live: pages land in the order the place
/// hands them over, and a row that is merely early must not disappear.
const _liveProject =
    'NOT EXISTS (SELECT 1 FROM project p WHERE p.id = t.project_id AND p.archived = 1)';

String _bundleOrder(Bundle bundle, DateTime today) => switch (bundle) {
  // Movement is the subject here, so freshness outranks everything but priority.
  Bundle.moving => 't.priority_rank, t.updated_at DESC, t.id',
  Bundle.stalled => 't.priority_rank, t.id',
  // Overdue first, then today, then priority — a deadline is not a bundle of its own, it is
  // a reason to be at the top of this one.
  Bundle.next =>
    'CASE WHEN t.due_on IS NOT NULL AND t.due_on < ? THEN 0 '
        'WHEN t.due_on = ? THEN 1 ELSE 2 END, t.priority_rank, t.id',
  Bundle.finished =>
    'COALESCE(t.completed_at, t.status_changed_at, t.updated_at) DESC, t.id DESC',
};

List<Object?> _orderArgs(Bundle bundle, DateTime today) =>
    bundle == Bundle.next ? [_day(today), _day(today)] : const [];

({String sql, List<Object?> args}) _listWhere(TaskQuery query, DateTime today) {
  final clauses = <String>[];
  final args = <Object?>[];
  if (query.bundle != null) {
    final bundle = _bundleWhere(query.bundle!, today, null);
    clauses.add('(${bundle.sql})');
    args.addAll(bundle.args);
  }
  if (query.valueId != null) {
    clauses.add(
      'EXISTS (SELECT 1 FROM task_dimension_value x '
      'WHERE x.task_id = t.id AND x.value_id = ?)',
    );
    args.add(query.valueId);
  }
  if (query.changedSince != null) {
    clauses.add('t.updated_at > ?');
    args.add(amenboStamp(query.changedSince!));
  }
  if (query.projectId != null) {
    clauses.add('t.project_id = ?');
    args.add(query.projectId);
  }
  if (clauses.isEmpty) clauses.add('1 = 1');
  return (sql: clauses.join(' AND '), args: args);
}

/// The join that turns a typed query into hits, with the line around each one.
///
/// A record is indexed once per place its text can be found — title, body, comment — so a task
/// can match more than once. Only the first is kept, title before body before comment, because
/// the list shows one line per task and the strongest place to have matched is the one to show.
///
/// Below three characters the index cannot answer: trigrams are three characters long. Those
/// queries are matched with `LIKE` instead, which is a scan — bounded by the window, and the
/// price of letting someone search for `qr`.
({String sql, List<Object?> args})? _searchJoin(String? text, String kind) {
  final needle = text?.trim() ?? '';
  if (needle.isEmpty) return null;

  final matched = needle.length >= 3
      ? (
          where: 'search_fts MATCH ?',
          from: 'search_fts f JOIN search_row s ON s.id = f.rowid',
          excerpt: "snippet(search_fts, 0, '', '', '…', 12)",
          arg: '"${needle.replaceAll('"', '""')}"',
        )
      : (
          where: "s.body LIKE ? ESCAPE '\\'",
          from: 'search_row s',
          excerpt: 'substr(s.body, MAX(1, instr(s.body, ?) - 12), 48)',
          arg:
              '%${needle.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')}%',
        );

  final args = needle.length >= 3
      ? <Object?>[matched.arg, kind]
      : <Object?>[needle, matched.arg, kind];

  // The excerpt is taken one level further in than the numbering. FTS5's snippet() reads the
  // cursor of the match it is standing on, and a window function sorts the rows out from under
  // it — so the hits are collected first, and only then ranked.
  return (
    sql:
        'JOIN (SELECT owner_id, excerpt, source, '
        'ROW_NUMBER() OVER (PARTITION BY owner_id ORDER BY place, hit) AS n FROM ('
        'SELECT s.owner_id AS owner_id, ${matched.excerpt} AS excerpt, s.id AS hit, '
        's.source AS source, '
        "CASE s.source WHEN 'title' THEN 0 WHEN 'body' THEN 1 ELSE 2 END AS place "
        'FROM ${matched.from} WHERE ${matched.where} AND s.kind = ?)) h '
        'ON h.owner_id = t.id AND h.n = 1',
    args: args,
  );
}

/// amenbo writes days as `YYYY-MM-DD` and instants as ISO-8601 in UTC. Comparisons here are
/// string comparisons on those, which is why both formats are produced in one place.
String _day(DateTime when) {
  final local = when.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

/// An instant in the shape amenbo writes them, for the one mark the device makes itself — when it
/// was last looked at. Everything else compared against it came stamped from the PC.
String amenboStamp(DateTime when) =>
    '${when.toUtc().toIso8601String().split('.').first}Z';
