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
/// * **"Last looked" is the moment the app came to the front, and it does not move while it is
///   there.** Both the card at the top and the unread dots count from it, so a mark that vanished
///   while it was being read would be one the person never got to act on.
library;

import 'package:flutter/material.dart';

import 'cloudflare_intake.dart';
import 'l10n/words.dart';
import 'settings.dart';
import 'state_band.dart';
import 'store/backlog_queries.dart';
import 'store/backlog_store.dart';
import 'ui/task_row.dart';
import 'ui/theme.dart';
import 'ui/tokens.dart';
import 'ui/touch.dart';

/// What the screen calls each bundle.
///
/// "Stalled" and "Next" are the two the person is really scanning: one is what to unblock, the
/// other is what to pick up. The words are plain rather than amenbo's own, because a status name
/// answers "what is this row" and a heading has to answer "why am I being shown these".
///
/// The finished one says its reach, because it is the one bundle that is not everything there is:
/// a person who set it to a month and reads "7 days" would take the setting for broken. With no
/// cut-off there is nothing to say, so it says nothing.
String bundleHeading(
  Words words,
  Bundle bundle, {
  int? finishedDays = finishedDaysDefault,
}) => switch (bundle) {
  Bundle.moving => words.bundleMoving,
  Bundle.stalled => words.bundleStalled,
  Bundle.next => words.bundleNext,
  Bundle.finished =>
    finishedDays == null
        ? words.bundleFinished
        : words.bundleFinishedWithin(finishedDays),
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
    required this.onMore,
    required this.onSince,
    this.failure,
    this.iCloudAvailable,
    this.onPairAgain,
    this.onOpenSettings,
    this.take,
    this.arrivals,
    required this.doneWindow,
    this.clock = DateTime.now,
  });

  final BacklogStore store;

  /// Opening a row.
  final void Function(TaskLine line) onOpen;

  /// The rest of a bundle, past the window the screen holds.
  ///
  /// It hands over a query rather than a bundle because what the person is holding is the bundle
  /// *and* whatever project they narrowed to, and a list that quietly widened back out would not
  /// be the rest of what they were reading.
  final void Function(TaskQuery narrowing) onMore;

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

  /// How far back the finished bundle reaches. Handed in rather than read from the settings here,
  /// and required rather than defaulted, because a screen that quietly kept its own week would
  /// leave the person with a choice that changes nothing.
  final DoneWindow doneWindow;

  /// Passed in rather than read here, so a row and the heading over it cannot disagree about what
  /// "today" was.
  final DateTime Function() clock;

  static String more(Words words, int rest, {bool overflowed = false}) =>
      words.more('$rest${overflowed ? '+' : ''}');

  static String arrived(Words words, Counted count) =>
      words.newActivity(countLabel(words, count));

  static String moved(Words words, Moved moved, Counted count) =>
      '${movedHeading(words, moved)} ${countLabel(words, count)}';

  @override
  State<NowScreen> createState() => _NowScreenState();
}

class _NowScreenState extends State<NowScreen> with WidgetsBindingObserver {
  /// Null is every project at once, and it is where the screen starts. Narrowing is a state of
  /// the screen, not a setting — coming back tomorrow shows everything again.
  int? _projectId;

  var _projects = const <({int id, String name})>[];
  var _names = const <int, String>{};
  final _bundles = <Bundle, ({List<TaskLine> rows, Counted total})>{};

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

  /// Closed work is history, and history is not what the screen is opened for.
  bool _finishedOpen = false;

  @override
  void initState() {
    super.initState();
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
    // A choice made on the settings screen and come back from. Nothing is being pulled out from
    // under anyone here: the person asked for this one, so it is applied rather than counted.
    if (old.doneWindow != widget.doneWindow) _load();
  }

  @override
  void dispose() {
    widget.arrivals?.removeListener(_rowsArrived);
    WidgetsBinding.instance.removeObserver(this);
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
            widget.store.bundle(
              bundle,
              today: today,
              projectId: _projectId,
              finishedDays: widget.doneWindow.days,
            ),
          ),
        ),
      );
    _drawnAt = widget.store.latestTaskChange(projectId: _projectId);
    _takenAt = DateTime.tryParse(
      widget.store.meta(MetaKey.fetchedAt) ?? '',
    )?.toLocal();
    _arrived = null;
    _countSinceLook();
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
      TaskQuery(
        changedSince: since,
        moved: moved,
        projectId: _projectId,
        finishedDays: widget.doneWindow.days,
      ),
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

  bool get _empty => _bundles.values.every((held) => held.rows.isEmpty);

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
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: words.refresh,
            onPressed: _pull,
          ),
          // The whole way to the settings: three choices opened a handful of times a year, which
          // is not what a third of the bottom bar is for. Last of the two, where a screen's
          // way out to what is behind it is looked for.
          if (widget.onOpenSettings != null)
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: words.settingsTitle,
              onPressed: widget.onOpenSettings,
            ),
        ],
        // While a fetch runs, a line and nothing else. A spinner over the list, or a skeleton in
        // place of it, would take away the old picture — which is the correct thing to be reading
        // until a newer one exists.
        bottom: _taking
            ? const PreferredSize(
                preferredSize: Size.fromHeight(Space.hair),
                child: LinearProgressIndicator(minHeight: Space.hair),
              )
            : null,
      ),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _pull,
            child: _empty
                ? _nothing(standing)
                : _scroll(words, today, standing),
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
  Widget _nothing(Standing standing) => ListView(
    // Still a scroll, or there is nothing to pull on.
    physics: const AlwaysScrollableScrollPhysics(),
    children: [_band(standing, whole: true)],
  );

  Widget _band(Standing standing, {bool whole = false}) => StateBand(
    standing: standing,
    lastTakenAt: _takenAt,
    onPairAgain: widget.onPairAgain,
    onOpenSettings: widget.onOpenSettings,
    whole: whole,
    clock: widget.clock,
  );

  Widget _scroll(Words words, DateTime today, Standing standing) {
    final rows = <Widget>[
      // Above the card and above the bundles: what is being read is only worth reading once the
      // person knows how old it is and why.
      _band(standing),
      // Then the card, because the person who opens this in bed is asking what happened overnight
      // before they are asking anything else.
      if (_sinceCounts.isNotEmpty)
        _SinceCard(counts: _sinceCounts, onOpen: _openSince),
    ];
    for (final bundle in Bundle.values) {
      final held = _bundles[bundle]!;
      // A heading over nothing is a line that says only that a question was asked.
      if (held.rows.isEmpty) continue;
      final folds = bundle == Bundle.finished;
      rows.add(
        BundleHeading(
          title: bundleHeading(
            words,
            bundle,
            finishedDays: widget.doneWindow.days,
          ),
          count: countLabel(words, held.total),
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
            onOpen: () {
              setState(() => _opened.add(line.id));
              widget.onOpen(line);
            },
          ),
        ),
      );
      final rest = held.total.value - held.rows.length;
      if (rest > 0) {
        rows.add(
          _MoreRow(
            label: NowScreen.more(
              words,
              rest,
              overflowed: held.total.overflowed,
            ),
            onTap: () => widget.onMore(
              TaskQuery(
                bundle: bundle,
                projectId: _projectId,
                // The reach the person set, carried with the bundle: the rest of a list that
                // stopped at a different day would not be the rest of this one.
                finishedDays: widget.doneWindow.days,
              ),
            ),
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
        padding: const EdgeInsets.fromLTRB(
          Space.gutter,
          Space.s4,
          Space.gutter,
          Space.s4,
        ),
        child: Row(
          children: [
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: Space.s1),
            Icon(
              Icons.chevron_right,
              size:
                  (theme.textTheme.bodyMedium?.fontSize ?? Lettering.md) * 1.2,
              color: theme.colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}
