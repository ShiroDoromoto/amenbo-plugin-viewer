/// "Now" — the four bundles, in one scroll.
///
/// This is the screen the app is opened for. Three of the four things a person wants while they
/// are away from the PC are answered here, and the fourth is a search away, so what matters is not
/// how much fits but how few seconds pass before the one line they came for is under their eyes.
/// Hence one scroll rather than four tabs: a bundle behind a tab is a bundle nobody glances at.
///
/// Two rules shape everything below.
///
/// * **The floor is never swapped while someone is standing on it.** Rows that arrive on their own
///   are counted, not applied — the person presses a pill when they are ready. The exception is a
///   list that is still empty, where there is nothing to pull out from under anyone and a first
///   sync should be seen filling up.
/// * **Projects narrow, they do not divide.** Everything the machine sends is stacked together by
///   default, because "what moved overnight" is not a question anybody asks one project at a time.
library;

import 'package:flutter/material.dart';

import 'store/backlog_queries.dart';
import 'store/backlog_store.dart';
import 'ui/task_row.dart';
import 'ui/theme.dart';
import 'ui/touch.dart';

/// What the screen calls each bundle.
///
/// "Stalled" and "Next" are the two the person is really scanning: one is what to unblock, the
/// other is what to pick up. The words are plain rather than amenbo's own, because a status name
/// answers "what is this row" and a heading has to answer "why am I being shown these".
String bundleHeading(Bundle bundle) => switch (bundle) {
  Bundle.moving => 'In progress',
  Bundle.stalled => 'Stalled',
  Bundle.next => 'Next',
  Bundle.finished => 'Finished (7 days)',
};

class NowScreen extends StatefulWidget {
  const NowScreen({
    super.key,
    required this.store,
    required this.onOpen,
    required this.onMore,
    this.take,
    this.arrivals,
    this.clock = DateTime.now,
  });

  final BacklogStore store;

  /// Opening a row.
  final void Function(TaskLine line) onOpen;

  /// The rest of a bundle, past the window the screen holds.
  final void Function(Bundle bundle) onMore;

  /// Goes and fetches. Null before anything is paired — the screen still draws what is on the
  /// device, which is the whole point of it being a local store.
  final Future<void> Function()? take;

  /// Ticks when a fetch the person did not ask for has written rows.
  final Listenable? arrivals;

  /// Passed in rather than read here, so a row and the heading over it cannot disagree about what
  /// "today" was.
  final DateTime Function() clock;

  static const allProjects = 'All projects';
  static const chooseProject = 'Choose a project';
  static const refresh = 'Refresh';

  /// Not an error and not an empty backlog: what the place holds has not reached the device yet.
  /// The band above says which of those it is.
  static const nothingYet = 'Nothing here yet';

  static String more(int rest, {bool overflowed = false}) =>
      '$rest${overflowed ? '+' : ''} more';

  static String arrived(Counted count) => 'New activity · ${countLabel(count)}';

  @override
  State<NowScreen> createState() => _NowScreenState();
}

class _NowScreenState extends State<NowScreen> {
  /// Null is every project at once, and it is where the screen starts. Narrowing is a state of
  /// the screen, not a setting — coming back tomorrow shows everything again.
  int? _projectId;

  var _projects = const <({int id, String name})>[];
  var _names = const <int, String>{};
  final _bundles = <Bundle, ({List<TaskLine> rows, Counted total})>{};

  /// The newest change the drawn rows include, stamped by the PC. What arrived after it is what
  /// the pill offers.
  String? _drawnAt;

  String? _lastLooked;

  /// What has arrived since [_drawnAt], waiting to be let in. Null while nothing has.
  Counted? _arrived;
  bool _taking = false;

  /// Closed work is history, and history is not what the screen is opened for.
  bool _finishedOpen = false;

  @override
  void initState() {
    super.initState();
    _load();
    widget.arrivals?.addListener(_rowsArrived);
  }

  @override
  void didUpdateWidget(NowScreen old) {
    super.didUpdateWidget(old);
    if (old.arrivals != widget.arrivals) {
      old.arrivals?.removeListener(_rowsArrived);
      widget.arrivals?.addListener(_rowsArrived);
    }
  }

  @override
  void dispose() {
    widget.arrivals?.removeListener(_rowsArrived);
    super.dispose();
  }

  void _load() {
    final today = widget.clock();
    _projects = widget.store.projects();
    _names = {for (final project in _projects) project.id: project.name};
    // A project can go away — archived on the PC, or gone from the place entirely — and the
    // narrowing it held has to let go rather than showing an empty list forever.
    if (_projectId != null && !_names.containsKey(_projectId)) {
      _projectId = null;
    }
    _bundles
      ..clear()
      ..addEntries(
        Bundle.values.map(
          (bundle) => MapEntry(
            bundle,
            widget.store.bundle(bundle, today: today, projectId: _projectId),
          ),
        ),
      );
    _drawnAt = widget.store.latestTaskChange(projectId: _projectId);
    _lastLooked = widget.store.meta(MetaKey.lastOpenedAt);
    _arrived = null;
  }

  void _apply() => setState(_load);

  bool get _empty => _bundles.values.every((held) => held.rows.isEmpty);

  void _rowsArrived() {
    if (!mounted) return;
    // Nothing is being read yet, so there is no place to lose. This is also the first sync:
    // the rows are meant to be watched arriving, not held back behind a pill.
    if (_empty) {
      _apply();
      return;
    }
    final moved = widget.store.movedSince(_drawnAt, projectId: _projectId);
    if (moved.value == 0) return;
    setState(() => _arrived = moved);
  }

  Future<void> _pull() async {
    final take = widget.take;
    if (take != null) {
      setState(() => _taking = true);
      // A fetch that failed leaves the picture the device already had. Saying so is the band's
      // job, and it reads the same store — a list that stopped to report would be showing less
      // than it has.
      await take().catchError((Object _) {});
      if (!mounted) return;
      setState(() => _taking = false);
    }
    _showWhatArrived();
  }

  void _showWhatArrived() {
    _apply();
    // The one change that is not a surprise: the person asked for it.
    Touch.refreshApplied();
  }

  bool _unread(TaskLine line) {
    final since = _lastLooked;
    // Both are amenbo's own instants, written the same way, so the comparison is a string one.
    return since != null && line.updatedAt.compareTo(since) > 0;
  }

  @override
  Widget build(BuildContext context) {
    final today = widget.clock();
    return Scaffold(
      appBar: AppBar(
        title: _title(),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: NowScreen.refresh,
            onPressed: _pull,
          ),
        ],
        // While a fetch runs, a line and nothing else. A spinner over the list, or a skeleton in
        // place of it, would take away the old picture — which is the correct thing to be reading
        // until a newer one exists.
        bottom: _taking
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _pull,
            child: _empty ? _nothing() : _scroll(today),
          ),
          if (_arrived != null)
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ActionChip(
                  avatar: const Icon(Icons.arrow_upward, size: 16),
                  label: Text(NowScreen.arrived(_arrived!)),
                  onPressed: _showWhatArrived,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _title() {
    // Nothing to choose between: one project is the title, and a menu offering the only answer
    // is a control that costs a tap and gives nothing back.
    if (_projects.length < 2) {
      return Text(
        _projects.isEmpty ? NowScreen.allProjects : _projects.single.name,
      );
    }
    final label = _projectId == null
        ? NowScreen.allProjects
        : _names[_projectId] ?? NowScreen.allProjects;
    return PopupMenuButton<int?>(
      tooltip: NowScreen.chooseProject,
      initialValue: _projectId,
      onSelected: (chosen) => setState(() {
        _projectId = chosen;
        _load();
      }),
      itemBuilder: (context) => [
        const PopupMenuItem(value: null, child: Text(NowScreen.allProjects)),
        for (final project in _projects)
          PopupMenuItem(value: project.id, child: Text(project.name)),
      ],
      child: Semantics(
        label: '$label, ${NowScreen.chooseProject}',
        button: true,
        container: true,
        child: ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nothing() => ListView(
    // Still a scroll, or there is nothing to pull on.
    physics: const AlwaysScrollableScrollPhysics(),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
        child: Text(
          NowScreen.nothingYet,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ],
  );

  Widget _scroll(DateTime today) {
    final rows = <Widget>[];
    for (final bundle in Bundle.values) {
      final held = _bundles[bundle]!;
      // A heading over nothing is a line that says only that a question was asked.
      if (held.rows.isEmpty) continue;
      final folds = bundle == Bundle.finished;
      rows.add(
        BundleHeading(
          title: bundleHeading(bundle),
          count: countLabel(held.total),
          expanded: folds ? _finishedOpen : null,
          onToggle: folds
              ? () => setState(() => _finishedOpen = !_finishedOpen)
              : null,
        ),
      );
      if (folds && !_finishedOpen) continue;
      rows.addAll(
        held.rows.map(
          (line) => TaskRow(
            line: line,
            today: today,
            unread: _unread(line),
            // Movement is what this bundle is about, so freshness earns its width here and
            // nowhere else.
            movedAt: bundle == Bundle.moving
                ? DateTime.tryParse(line.updatedAt)
                : null,
            // Only where it tells the person something the title has not: narrowed to one, or
            // on a machine that holds only one, every row would carry the same name.
            projectName: _projectId == null && _projects.length > 1
                ? _names[line.projectId]
                : null,
            onOpen: () => widget.onOpen(line),
          ),
        ),
      );
      final rest = held.total.value - held.rows.length;
      if (rest > 0) {
        rows.add(
          _MoreRow(
            label: NowScreen.more(rest, overflowed: held.total.overflowed),
            onTap: () => widget.onMore(bundle),
          ),
        );
      }
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: rows,
    );
  }
}

/// The way out of a bundle's window and into the one list face.
class _MoreRow extends StatelessWidget {
  const _MoreRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              size: (theme.textTheme.bodyMedium?.fontSize ?? 14) * 1.2,
              color: theme.colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}
