/// "Tasks" — the four states, one at a time.
///
/// This is the screen the app is opened for, and what it is asked is nearly always one of four
/// questions: what is being worked on, what is stuck, what is next, what got finished. So the
/// screen is divided the way the backlog itself is — by amenbo's own status — and the person moves
/// between the four rather than scrolling past them. The same four they read on the PC, in the
/// same words, so there is nothing to learn twice.
///
/// Four rules shape everything below.
///
/// * **Divided by state, not by whether it can be started.** Whether a task's premises are met is
///   derived, and it changes overnight without the task moving. A row waiting on something stays
///   in `todo` and says what it is waiting on.
/// * **One state is read to its end.** A window at a time, asked for by reaching the bottom —
///   there is no "N more" that hands the rest to another screen. Finished work is all of it,
///   newest first, with the date written in wherever it changes: the device holds the whole copy,
///   so a cut-off would be hiding rows that are already here.
/// * **The floor is never swapped while someone is standing on it.** Rows that arrive on their own
///   are counted, not applied — the person presses a pill when they are ready. The exception is a
///   list that is still empty, where there is nothing to pull out from under anyone and a first
///   sync should be seen filling up.
/// * **Projects narrow, they do not divide.** Everything the machine sends is stacked together by
///   default, because "what moved overnight" is not a question anybody asks one project at a time.
/// * **"Last looked" is the moment the app came to the front, and it does not move while it is
///   there.** Both the card at the top and the unread dots count from it, so a mark that vanished
///   while it was being read would be one the person never got to act on.
library;

import 'package:flutter/material.dart';

import 'cloudflare_intake.dart';
import 'l10n/words.dart';
import 'state_band.dart';
import 'store/backlog_queries.dart';
import 'store/backlog_store.dart';
import 'ui/task_row.dart';
import 'ui/theme.dart';
import 'ui/time.dart';
import 'ui/tokens.dart';
import 'ui/touch.dart';

/// What the switch calls each state.
///
/// amenbo's own words, and the same ones a row wears — a switch named one thing holding rows
/// marked another would be two names for one fact. The closed one is said as "done" because that
/// is what nearly all of it is; a rejected row says so on itself.
String stateHeading(Words words, TaskState state) => switch (state) {
  TaskState.todo => words.statusTodo,
  TaskState.inProgress => words.statusInProgress,
  TaskState.blocked => words.statusBlocked,
  TaskState.finished => words.statusDone,
};

/// What the card calls each of its three numbers.
String movedHeading(Words words, Moved moved) => switch (moved) {
  Moved.finished => words.movedFinished,
  Moved.filed => words.movedFiled,
  Moved.commented => words.movedCommented,
};

/// Says that rows arrived. Nothing about which — the screen that cares reads the store itself.
///
/// [watched] is the one thing it carries, because it decides whether the floor may be swapped.
/// Rows that landed behind someone's back are offered behind a pill; rows the person sat and
/// watched land — the first sync — are what they are here to read, and holding those back would
/// be offering them what they just finished waiting for.
class Arrivals extends ChangeNotifier {
  bool _watched = false;

  /// Whether the last lot were watched arriving.
  bool get watched => _watched;

  void tick({bool watched = false}) {
    _watched = watched;
    notifyListeners();
  }
}

class NowScreen extends StatefulWidget {
  const NowScreen({
    super.key,
    required this.store,
    required this.onOpen,
    required this.onSince,
    this.failure,
    this.iCloudAvailable,
    this.onPairAgain,
    this.onOpenSettings,
    this.take,
    this.arrivals,
    this.clock = DateTime.now,
  });

  final BacklogStore store;

  /// Opening a row.
  final void Function(TaskLine line) onOpen;

  /// One number on the card, opened into the list of just what it counted — same face, and the
  /// same narrowing, as everything else that leaves this screen.
  final void Function(TaskQuery narrowing) onSince;

  /// How the last round of the intake ended, or null where it did not fail. It decides the band
  /// at the top; it never decides whether the list is drawn.
  final IntakeFailure? failure;

  /// Whether the iCloud route can be read at all, or null where that is not the route.
  final bool? iCloudAvailable;

  final VoidCallback? onPairAgain;
  final VoidCallback? onOpenSettings;

  /// Goes and fetches, on whichever route this phone is on. Null where it has no route to take —
  /// the screen still draws what is on the device, which is the whole point of it being a local
  /// store.
  final Future<void> Function()? take;

  /// Ticks when a fetch this screen did not run has written rows.
  final Arrivals? arrivals;

  /// Passed in rather than read here, so a row and the heading over it cannot disagree about what
  /// "today" was.
  final DateTime Function() clock;

  /// One state on the switch: its name, and how many are in it.
  static String tab(Words words, TaskState state, Counted count) =>
      labelWithCount(words, stateHeading(words, state), count);

  static String arrived(Words words, Counted count) =>
      words.newActivity(countLabel(words, count));

  /// The clock, not "3 h ago".
  ///
  /// This is the one place the app spells a time out. What the person is judging here is how old
  /// what they are reading is, and a phone whose clock is wrong can still say the hour it took
  /// something at — where "3 h ago" would be wrong by exactly the amount the clock is out.
  ///
  /// The day comes with it once it is not today's. This line is the only thing a phone with no
  /// signal has to date what it is reading by, and out of signal is exactly where a picture stops
  /// being hours old and starts being days old.
  static String takenAt(
    TimeFace face,
    DateTime when, {
    required DateTime now,
  }) => face.words.takenAt(clockOnDay(face, when, now: now));

  static String moved(Words words, Moved moved, Counted count) =>
      '${movedHeading(words, moved)} ${countLabel(words, count)}';

  @override
  State<NowScreen> createState() => _NowScreenState();
}

class _NowScreenState extends State<NowScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  /// Built here rather than lazily beside its declaration: a screen taken down before it ever
  /// drew the switch — a phone with nothing on it — would otherwise create the controller inside
  /// `dispose`, which is the one place it cannot be created.
  late final TabController _tabs;

  /// Null is every project at once, and it is where the screen starts. Narrowing is a state of
  /// the screen, not a setting — coming back tomorrow shows everything again.
  int? _projectId;

  var _projects = const <({int id, String name})>[];
  var _names = const <int, String>{};

  /// What each state holds: the windows read so far, how many there are in all, and whether the
  /// last window came back full. A full window is the only honest sign that there is more.
  final _rows = <TaskState, List<TaskLine>>{};
  final _totals = <TaskState, Counted>{};
  final _more = <TaskState, bool>{};
  bool _widening = false;

  /// The newest change the drawn rows include, stamped by the PC. What arrived after it is what
  /// the pill offers.
  String? _drawnAt;

  /// When the last round finished. It is what says how old the picture is, which is the one thing
  /// a reader offline has to be told and the one thing nothing else on the screen says.
  DateTime? _takenAt;

  /// When the app was last brought to the front, taken once on arriving there and held for as
  /// long as it stays. Null on a device that has never had it open, where there is no "last time"
  /// to count from.
  String? _lastLooked;

  /// The card's three numbers, counted from [_lastLooked]. Empty when nothing moved, which is
  /// also when no card is drawn — a card saying "nothing changed" is a line of the screen spent
  /// on the one answer the person could have assumed.
  var _sinceCounts = const <Moved, Counted>{};

  /// Rows opened during this visit. Their dots are gone: the person has read them, and
  /// [_lastLooked] deliberately does not move to say so.
  final _opened = <int>{};

  /// What has arrived since [_drawnAt], waiting to be let in. Null while nothing has.
  Counted? _arrived;
  bool _taking = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: TaskState.values.length, vsync: this);
    WidgetsBinding.instance.addObserver(this);
    _cameToFront();
    _load();
    widget.arrivals?.addListener(_rowsArrived);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) setState(_cameToFront);
  }

  /// Takes the new mark for "last looked", and leaves the old one standing as what the screen
  /// counts against.
  ///
  /// The new one is written the moment the app arrives, not on the way out: the question the card
  /// answers is "what happened while I was away", and away began here.
  void _cameToFront() {
    _lastLooked = widget.store.meta(MetaKey.lastOpenedAt);
    widget.store.setMeta(MetaKey.lastOpenedAt, amenboStamp(widget.clock()));
    // A new visit, and nothing on the screen has been read in it yet.
    _opened.clear();
    _countSinceLook();
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
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
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
    for (final state in TaskState.values) {
      final rows = widget.store.inState(
        state,
        today: today,
        projectId: _projectId,
      );
      _rows[state] = rows;
      _totals[state] = widget.store.stateCount(
        state,
        today: today,
        projectId: _projectId,
      );
      _more[state] = rows.length == Windows.list;
    }
    _drawnAt = widget.store.latestTaskChange(projectId: _projectId);
    _takenAt = DateTime.tryParse(
      widget.store.meta(MetaKey.fetchedAt) ?? '',
    )?.toLocal();
    _arrived = null;
    _countSinceLook();
  }

  /// Asks for the next window of one state, once the end of this one has been reached.
  ///
  /// The rows come from a file on the device, so there is nothing to wait for and no spinner to
  /// show. What it must not do is ask twice for the same window.
  void _widen(TaskState state) {
    if (_widening) return;
    _widening = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _widening = false;
        return;
      }
      final held = _rows[state] ?? const <TaskLine>[];
      setState(() {
        final next = widget.store.inState(
          state,
          today: widget.clock(),
          projectId: _projectId,
          offset: held.length,
        );
        _rows[state] = [...held, ...next];
        _more[state] = next.length == Windows.list;
      });
      _widening = false;
    });
  }

  /// Counted inside the narrowing the screen is holding, or a number the person presses opens a
  /// list that does not hold that many.
  /// A number on the card, as the query that opens exactly what it counted.
  ///
  /// The instant is the one the card counted from, not "now": the card is read minutes after it
  /// was drawn, and a list counted from a fresher moment would come back shorter than the number
  /// that was pressed.
  void _openSince(Moved moved) {
    final since = DateTime.tryParse(_lastLooked ?? '');
    if (since == null) return;
    widget.onSince(
      TaskQuery(changedSince: since, moved: moved, projectId: _projectId),
    );
  }

  void _countSinceLook() {
    final since = _lastLooked;
    _sinceCounts = since == null
        ? const {}
        : Map.fromEntries(
            widget.store
                .sinceLastLook(since, projectId: _projectId)
                .entries
                // A zero is not worth its width, and it is a number that opens an empty list.
                .where((counted) => counted.value.value > 0),
          );
  }

  void _apply() => setState(_load);

  bool get _empty => _rows.values.every((rows) => rows.isEmpty);

  void _rowsArrived() {
    if (!mounted) return;
    // Nothing is being read yet, so there is no place to lose — and a list somebody watched fill
    // up is one they are already looking at. Either way the rows go straight in rather than
    // waiting behind a pill.
    if (_empty || (widget.arrivals?.watched ?? false)) {
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
    // Opening it is what reads it. The dot goes at that moment rather than at the next visit,
    // because the row is still on the screen the person comes back to.
    if (_opened.contains(line.id)) return false;
    final since = _lastLooked;
    // Both are written in amenbo's shape, so the comparison is a string one.
    return since != null && line.updatedAt.compareTo(since) > 0;
  }

  @override
  Widget build(BuildContext context) {
    final today = widget.clock();
    final words = Words.of(context);
    final standing = standingOf(
      anythingHere: !_empty,
      failure: widget.failure,
      iCloudAvailable: widget.iCloudAvailable,
    );
    return Scaffold(
      appBar: AppBar(
        title: _title(),
        actions: [
          // The whole way to the settings: three choices opened a handful of times a year, which
          // is not what a third of the bottom bar is for. The corner where a screen's way out to
          // what is behind it is looked for.
          if (widget.onOpenSettings != null)
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: words.settingsTitle,
              onPressed: widget.onOpenSettings,
            ),
        ],
        // A phone that holds nothing is not in one of four states — it is a phone with nothing on
        // it, and four empty switches would be four ways of finding that out.
        bottom: _empty
            ? null
            : TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  for (final state in TaskState.values)
                    Tab(
                      text: NowScreen.tab(
                        words,
                        state,
                        _totals[state] ?? const Counted(0, false),
                      ),
                    ),
                ],
              ),
      ),
      body: Stack(
        children: [
          if (_empty)
            RefreshIndicator(onRefresh: _pull, child: _nothing(words, standing))
          else
            TabBarView(
              controller: _tabs,
              children: [
                for (final state in TaskState.values)
                  _state(state, words, today, standing),
              ],
            ),
          // While a fetch runs, a line and nothing else. A spinner over the list, or a skeleton in
          // place of it, would take away the old picture — which is the correct thing to be
          // reading until a newer one exists.
          if (_taking)
            const Align(
              alignment: Alignment.topCenter,
              child: LinearProgressIndicator(minHeight: Space.hair),
            ),
          if (_arrived != null)
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: Space.s3),
                child: ActionChip(
                  avatar: const Icon(Icons.arrow_upward, size: Space.s5),
                  label: Text(NowScreen.arrived(words, _arrived!)),
                  onPressed: _showWhatArrived,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _title() {
    final words = Words.of(context);
    // Nothing to choose between: one project is the title, and a menu offering the only answer
    // is a control that costs a tap and gives nothing back.
    if (_projects.length < 2) {
      return Text(
        _projects.isEmpty ? words.allProjects : _projects.single.name,
      );
    }
    final label = _projectId == null
        ? words.allProjects
        : _names[_projectId] ?? words.allProjects;
    return PopupMenuButton<int?>(
      tooltip: words.chooseProject,
      initialValue: _projectId,
      onSelected: (chosen) => setState(() {
        _projectId = chosen;
        _load();
      }),
      itemBuilder: (context) => [
        PopupMenuItem(value: null, child: Text(words.allProjects)),
        for (final project in _projects)
          PopupMenuItem(value: project.id, child: Text(project.name)),
      ],
      child: Semantics(
        label: '$label, ${words.chooseProject}',
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

  /// A device that has never had anything. There is no picture for a band to sit above, so the
  /// same words take the screen — which is also the only time this app shows an empty list, and it
  /// does not show one even then.
  Widget _nothing(Words words, Standing standing) => ListView(
    // Still a scroll, or there is nothing to pull on.
    physics: const AlwaysScrollableScrollPhysics(),
    children: [_takeLine(words), _band(standing, whole: true)],
  );

  Widget _band(Standing standing, {bool whole = false}) => StateBand(
    standing: standing,
    onPairAgain: widget.onPairAgain,
    onOpenSettings: widget.onOpenSettings,
    whole: whole,
  );

  /// How old what is being read is, and the way to make it newer.
  ///
  /// The two are one question asked in two halves — "how old is this" and "can I have a newer
  /// one" — so they are read together instead of the answer being a bare arrow in a corner that
  /// says nothing about what pressing it does.
  ///
  /// The line is here whether or not a round has ever finished. The pull is the same fetch and
  /// costs nothing to keep, but it cannot be seen, and an operation that is only discovered by
  /// trying a gesture on it is one most people never have.
  Widget _takeLine(Words words) {
    final theme = Theme.of(context);
    final taken = _takenAt;
    return Padding(
      padding: const EdgeInsets.only(left: Space.gutter, right: Space.s2),
      child: Row(
        children: [
          if (taken != null)
            Expanded(
              child: TimeOnHold(
                when: taken,
                child: Text(
                  NowScreen.takenAt(
                    TimeFace.of(context),
                    taken,
                    now: widget.clock(),
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else
            const Spacer(),
          // Nothing to press on a phone with no route to take: the screen still draws what is on
          // the device, and a button that quietly did nothing would be worse than no button.
          if (widget.take != null)
            TextButton(onPressed: _pull, child: Text(words.refresh)),
        ],
      ),
    );
  }

  /// One state, read to its end.
  ///
  /// What stands above the rows — how old the picture is, how things stand, what moved overnight
  /// — is the same on all four and scrolls away with them, because it is about the screen rather
  /// than about the state being read.
  Widget _state(
    TaskState state,
    Words words,
    DateTime today,
    Standing standing,
  ) {
    final rows = _rows[state] ?? const <TaskLine>[];
    final header = <Widget>[
      _takeLine(words),
      _band(standing),
      // The person who opens this in bed is asking what happened overnight before they are asking
      // anything else.
      if (_sinceCounts.isNotEmpty)
        _SinceCard(counts: _sinceCounts, onOpen: _openSince),
    ];
    final dates = state == TaskState.finished
        ? _dateHeadings(rows, now: today)
        : const <int, String>{};
    return RefreshIndicator(
      onRefresh: _pull,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount:
            header.length +
            (rows.isEmpty ? 1 : rows.length) +
            ((_more[state] ?? false) ? 1 : 0),
        itemBuilder: (context, index) {
          if (index < header.length) return header[index];
          final place = index - header.length;
          if (rows.isEmpty) return _none(words);
          if (place < rows.length) {
            final line = rows[place];
            final row = TaskRow(
              line: line,
              today: today,
              unread: _unread(line),
              // Movement is what this state is about, so freshness earns its width here and
              // nowhere else.
              movedAt: state == TaskState.inProgress
                  ? DateTime.tryParse(line.updatedAt)
                  : null,
              // Only where it tells the person something the title has not: narrowed to one, or
              // on a machine that holds only one, every row would carry the same name.
              projectName: _projectId == null && _projects.length > 1
                  ? _names[line.projectId]
                  : null,
              onOpen: () {
                setState(() => _opened.add(line.id));
                widget.onOpen(line);
              },
            );
            final date = dates[place];
            // The heading travels with the first row of its day rather than as an item of its
            // own, so a window arriving underneath cannot land between the two.
            return date == null
                ? row
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListHeading(title: date),
                      row,
                    ],
                  );
          }
          _widen(state);
          return const SizedBox(height: Stroke.rule);
        },
      ),
    );
  }

  /// Which rows of the finished state open a new day, and what that day is called.
  ///
  /// Finished work is all of it and it only grows, so the date is what says how far down someone
  /// has read — written in wherever it changes, and nowhere else. It is taken from the same
  /// instant the list is ordered by, or a row would sit under a day it did not end on.
  Map<int, String> _dateHeadings(List<TaskLine> rows, {required DateTime now}) {
    final face = TimeFace.of(context);
    final headings = <int, String>{};
    DateTime? standing;
    for (var place = 0; place < rows.length; place += 1) {
      final line = rows[place];
      final when = DateTime.tryParse(
        line.closedAt ?? line.updatedAt,
      )?.toLocal();
      if (when == null || DateUtils.isSameDay(standing, when)) continue;
      standing = when;
      headings[place] = dateHeading(face, when, now: now);
    }
    return headings;
  }

  /// A state with nothing in it.
  ///
  /// One quiet line rather than the empty face the app shows elsewhere: the switch above is still
  /// there with the other three states and their numbers on it, so the person is neither told
  /// nothing nor left without a way on. Nothing being blocked is good news, and good news does not
  /// need a screen of its own.
  Widget _none(Words words) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: Space.pageGutter,
      vertical: Space.s7,
    ),
    child: Text(
      words.nothingInState,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// What moved while the person was away, in one card.
///
/// Every number is its own way in: pressing one opens the list of exactly what it counted, so the
/// card is a set of doors rather than a summary to be read and dismissed. They are laid out in a
/// [Wrap] because at the largest text size a phone offers, three of them do not share a line.
class _SinceCard extends StatelessWidget {
  const _SinceCard({required this.counts, required this.onOpen});

  final Map<Moved, Counted> counts;
  final void Function(Moved moved) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(
        Space.gutter,
        Space.s4,
        Space.gutter,
        Space.s1,
      ),
      child: Padding(
        padding: const EdgeInsets.all(Space.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              Words.of(context).sinceLastLook,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: Space.s1),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // Fixed order, so the same number is in the same place every morning.
                for (final moved in Moved.values)
                  if (counts[moved] case final count?)
                    _SinceNumber(
                      moved: moved,
                      count: count,
                      onOpen: () => onOpen(moved),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SinceNumber extends StatelessWidget {
  const _SinceNumber({
    required this.moved,
    required this.count,
    required this.onOpen,
  });

  final Moved moved;
  final Counted count;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final words = Words.of(context);
    final label = NowScreen.moved(words, moved, count);
    return Semantics(
      // On its own it would be read as two words and a number, with no way to tell what the
      // number is since. Said rather than lower-cased: case is not a thing every language does
      // the same way.
      label: '$label, ${words.sinceLastLookSpoken}',
      button: true,
      container: true,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onOpen,
          // Set in the running text of a card and pressed with a thumb: what is drawn stays the
          // size of the sentence it belongs to, and what answers the press is the finger's.
          child: TapTarget(
            child: Padding(
              padding: const EdgeInsets.all(Space.s2),
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
