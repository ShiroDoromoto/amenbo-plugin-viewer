/// What the app opens on, and where everything leads.
///
/// The screens were each built to be handed what they need and to hand back what was pressed, so
/// until something joined them up none of them could be reached. This is that joining, and it is
/// two decisions.
///
/// **Which screen the app opens on.** A phone with no way in gets the guide — not an empty list,
/// which cannot say what to do about itself. A phone that has a way in, either a pairing it was
/// given or rows that already arrived, gets its backlog. Pairing runs straight into the first
/// sync and comes out on the front screen; erasing goes back to the guide.
///
/// **When it goes and looks.** "Automatically" is the launch and the return to the front, and
/// nothing else — the app does not sit in the background and has no interval to offer. What a
/// round like that brings back is counted rather than applied, because nobody asked for it while
/// they were reading. Both routes come through here: which one a round takes is decided from what
/// the phone holds, and everything downstream of it — the count, the pill, the band — is handed the
/// same report either way.
///
/// **Where the ways out go.** Three of them, across the bottom of a phone, because the thumb of a
/// hand holding one reaches the bottom half and a menu at the top does not exist for someone
/// standing on a train. That reach is worth spending on what is read every day — the tasks, the
/// decisions, and the way back to what stopped moving — and settings are three choices opened a
/// handful of times a year, so they sit at the top of the front screen instead, one tap further
/// away and out of the way of the three that are not. On glass nobody is holding one-handed the
/// same three move to a rail down the side, where the bottom edge would be the furthest point on
/// the screen. Everything that opens a list opens the one list face; everything that opens a task
/// opens the one detail. Where there is width for it, what was opened sits beside the list it was
/// opened from rather than on top of it.
library;

import 'package:flutter/material.dart';

import 'cloudflare_intake.dart';
import 'connection.dart';
import 'decision_detail.dart';
import 'decisions_screen.dart';
import 'first_sync.dart';
import 'icloud_container.dart';
import 'l10n/words.dart';
import 'icloud_intake.dart';
import 'now_screen.dart';
import 'pairing_guide.dart';
import 'pairing_scan.dart';
import 'pairing_store.dart';
import 'search_screen.dart';
import 'settings.dart';
import 'settings_screen.dart';
import 'store/backlog_queries.dart';
import 'store/backlog_store.dart';
import 'task_detail.dart';
import 'ui/tokens.dart';
import 'ui/two_pane.dart';

/// One round against the place, for the pairing this phone holds.
///
/// Handed in rather than built here, so the root can be walked with no network behind it.
typedef Rounds = TakeTheBacklog Function(Pairing pairing);

class ViewerHome extends StatefulWidget {
  const ViewerHome({
    super.key,
    required this.store,
    required this.settings,
    required this.appName,
    this.pairings = const PairingStore(),
    this.hasICloud = false,
    this.rounds,
    this.folderRounds,
    this.clock = DateTime.now,
  });

  final BacklogStore store;
  final SettingsController settings;
  final String appName;
  final PairingStore pairings;

  /// Whether this build runs somewhere with an iCloud container — iOS. Passed in rather than read
  /// from `dart:io`, so the Android answer is reachable from a Mac.
  final bool hasICloud;

  final Rounds? rounds;

  /// One round over the folder the Mac writes into. Handed in for the same reason [rounds] is —
  /// the root has to be walkable on a machine with no container behind it.
  final TakeTheBacklog? folderRounds;

  final DateTime Function() clock;

  @override
  State<ViewerHome> createState() => _ViewerHomeState();
}

class _ViewerHomeState extends State<ViewerHome> with WidgetsBindingObserver {
  Pairing? _pairing;

  /// Whether the container answers, on a phone that has one and was never paired. Null everywhere
  /// else, where it is not a fact about this phone's route at all.
  bool? _iCloudAvailable;

  /// Whether the keychain has been read yet. It is a file on the device, not a request.
  bool _looked = false;

  /// How the last round ended, for the band at the top of the front screen.
  IntakeFailure? _failure;

  /// Ticks when a round the front screen did not run has written rows. What it does about them
  /// depends on whether anybody was watching them land.
  final _arrivals = Arrivals();

  /// Whether a round is already running. The launch and the return to the front can land close
  /// together, and two rounds at once would read the same pages twice.
  bool _fetching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _look();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _arrivals.dispose();
    super.dispose();
  }

  /// One of the two moments "automatically" means. The other is the launch, at the end of [_look].
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _goAndLook();
  }

  /// Goes and looks, if that is what the person asked for.
  ///
  /// The other choice is not "never" but "only when I pull": the list still fetches under the
  /// thumb that asks for it, and this is the only thing the setting turns off.
  void _goAndLook() {
    if (widget.settings.value.refresh != Refresh.automatic) return;
    _round(asked: false);
  }

  Future<void> _look() async {
    final pairing = await widget.pairings.read();
    // A pairing is this phone having been pointed at a Worker on purpose, so it settles the route
    // — the same rule the connection screen reads by.
    final available = pairing == null && widget.hasICloud
        ? (await ICloudContainer.status()).available
        : null;
    if (!mounted) return;
    setState(() {
      _pairing = pairing;
      _iCloudAvailable = available;
      _looked = true;
    });
    _goAndLook();
  }

  /// Goes and takes a round, for the pull on the front screen.
  ///
  /// Null on a phone with no route to take — nothing paired and no container to read. A pull that
  /// silently did nothing would be worse than a list that does not offer one.
  Future<void> Function()? get _take =>
      _rounds == null ? null : () => _round(asked: true);

  /// One round on this phone's route.
  ///
  /// [asked] is whether the person pulled for it. A round they asked for is applied where they
  /// are looking, because they are expecting it; one that ran on its own is only counted, and the
  /// front screen offers it behind a pill.
  Future<void> _round({required bool asked}) async {
    final take = _rounds;
    if (take == null || _fetching) return;
    final folder = _pairing == null;
    _fetching = true;
    try {
      final report = await take((_) {});
      if (!mounted) return;
      setState(() {
        _failure = null;
        // A round that read the folder is the container answering, whatever it said at launch.
        if (folder) _iCloudAvailable = true;
      });
      if (!asked && report.records > 0) _arrivals.tick();
    } on IntakeException catch (stopped) {
      // Which of the two lines the band owes — signed out of iCloud, or simply not reached — is a
      // fact about the container rather than about the round, and it can have changed since the
      // launch asked. Both arrive here as the same failure, so the container is asked again.
      final available = folder
          ? (await ICloudContainer.status()).available
          : null;
      if (!mounted) return;
      // The list keeps what it had. Which line the band shows is decided from this.
      setState(() {
        _failure = stopped.failure;
        if (folder) _iCloudAvailable = available;
      });
    } finally {
      _fetching = false;
    }
  }

  /// The round this phone's route takes, or null where it has no route: an Android phone nobody
  /// has paired has neither a place to ask nor a folder to read.
  ///
  /// A pairing settles it — it is this phone having been pointed at a Worker on purpose — and the
  /// same rule the connection screen reads by.
  TakeTheBacklog? get _rounds {
    final pairing = _pairing;
    if (pairing != null) return _overTheNetwork(pairing);
    return widget.hasICloud ? _overTheFolder : null;
  }

  TakeTheBacklog _overTheNetwork(Pairing pairing) =>
      widget.rounds?.call(pairing) ??
      (watching) => CloudflareIntake(
        pairing: pairing,
        store: widget.store,
      ).run(watching: watching);

  TakeTheBacklog get _overTheFolder =>
      widget.folderRounds ??
      (watching) => ICloudIntake(store: widget.store).run(watching: watching);

  /// A code was read. The first round is the one wait long enough to be worth a screen, so it gets
  /// one, and what it comes back to is the backlog rather than a report that it arrived.
  Future<void> _paired(Pairing pairing) async {
    setState(() {
      _pairing = pairing;
      _iCloudAvailable = null;
      _failure = null;
    });
    await Navigator.of(context).push<IntakeReport>(
      MaterialPageRoute(
        builder: (_) => FirstSyncScreen(take: _overTheNetwork(pairing)),
      ),
    );
    if (!mounted) return;
    // The front screen was built behind this wait, against a store that was still empty, and it
    // reads the store once. Rebuilding it would draw the same answer again — what it has to be
    // told is that there is a newer one to go and ask for.
    _arrivals.tick(watched: true);
  }

  /// A fresh code, from the band that says this device was turned away. The scanning screen keeps
  /// what it read, so what is left here is the first round against the new place.
  Future<void> _pairAgain() async {
    final pairing = await Navigator.of(context).push<Pairing>(
      MaterialPageRoute(builder: (_) => const PairingScanScreen()),
    );
    if (pairing == null || !mounted) return;
    await _paired(pairing);
  }

  /// This phone's copy is gone, and with it the way in. What is left to show is the guide, and the
  /// phone is asked about itself again — a phone that can read a container is back on that route.
  void _erased() {
    setState(() {
      _pairing = null;
      _failure = null;
    });
    _look();
  }

  @override
  Widget build(BuildContext context) {
    // Nothing is drawn while the keychain is read: a guide that appeared and vanished a frame
    // later would be the app telling the person they are not set up and then taking it back.
    if (!_looked) return const Scaffold(body: SizedBox.shrink());
    final pairing = _pairing;
    // The guide is for a phone with no way in. Rows already here are a way in of their own — the
    // iCloud route is set up entirely on the Mac, so there is nothing this phone was asked to do.
    if (pairing == null && widget.store.latestTaskChange() == null) {
      return PairingGuideScreen(appName: widget.appName, onPaired: _paired);
    }
    return HomeShell(
      store: widget.store,
      settings: widget.settings,
      connection: PhoneConnection(
        store: widget.store,
        pairings: widget.pairings,
        hasICloud: widget.hasICloud,
      ),
      appName: widget.appName,
      take: _take,
      arrivals: _arrivals,
      failure: _failure,
      iCloudAvailable: _iCloudAvailable,
      onPairAgain: _pairAgain,
      onErased: _erased,
      clock: widget.clock,
    );
  }
}

/// The three screens, and the destinations they share.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.store,
    required this.settings,
    required this.connection,
    required this.appName,
    this.take,
    this.arrivals,
    this.failure,
    this.iCloudAvailable,
    this.onPairAgain,
    this.onErased,
    this.clock = DateTime.now,
  });

  final BacklogStore store;
  final SettingsController settings;
  final ConnectionFacts connection;
  final String appName;
  final Future<void> Function()? take;

  /// Ticks when rows landed from somewhere other than the front screen's own pull.
  final Arrivals? arrivals;

  final IntakeFailure? failure;
  final bool? iCloudAvailable;
  final VoidCallback? onPairAgain;
  final VoidCallback? onErased;
  final DateTime Function() clock;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  /// How many times one of the two faces that start fresh has been arrived at. It keys both of
  /// them, so every visit builds them again: search starts from everything, and a narrowing
  /// carried over from a screen the person left would be one they did not ask for — and the
  /// decisions list is read off the store as it stands now rather than as it stood when the shell
  /// was built. The front screen is not one of them: it holds what arrived while it was being
  /// read behind a pill, and rebuilding it would let those rows in unasked.
  int _visits = 0;

  /// What is open beside the list, on a screen wide enough to hold both. Null on a phone held
  /// upright, where opening pushes instead and the back gesture is the way out.
  int? _besideTaskId;

  bool get _wide => MediaQuery.sizeOf(context).width >= Layout.twoPane;

  /// Opens a task from one of the tabs: beside the list where there is room, on top of it where
  /// there is not.
  void _open(int taskId) {
    if (_wide) {
      setState(() => _besideTaskId = taskId);
      return;
    }
    _push(taskId);
  }

  /// Opens a task from a screen that is itself pushed. Whatever is beside the list is behind two
  /// routes by now, and putting it there would be putting it out of sight.
  void _push(int taskId) => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => _detail(taskId, opens: _push)));

  /// The one list face, opened with whatever narrowing was pressed.
  void _list(TaskQuery narrowing) => Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => _searchFace(narrowing, opens: _push)),
  );

  /// The settings, from the top of the front screen. Pushed like everything else that is opened
  /// from a tab rather than being one — and what comes back is whether the phone's copy was erased
  /// two screens in, which is the root's news, not this shell's.
  Future<void> _openSettings() async {
    final erased = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          settings: widget.settings,
          connection: widget.connection,
          appName: widget.appName,
        ),
      ),
    );
    if (erased == true) widget.onErased?.call();
  }

  /// A decision, from a task that links one or from the other tab of the search face.
  ///
  /// Always pushed, whatever the width: what it was opened from is a detail as often as a list,
  /// and swapping the pane beside a list would leave the person on a screen they cannot see the
  /// way back from.
  void _openDecision(int decisionId) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => DecisionDetailScreen(
        store: widget.store,
        decisionId: decisionId,
        clock: widget.clock,
        onOpenTask: _push,
        onOpenDecision: _openDecision,
        onProject: (projectId) => _list(TaskQuery(projectId: projectId)),
      ),
    ),
  );

  Widget _detail(int taskId, {required void Function(int taskId) opens}) =>
      TaskDetailScreen(
        store: widget.store,
        taskId: taskId,
        clock: widget.clock,
        onOpenTask: opens,
        onOpenDecision: _openDecision,
        onProject: (projectId) => _list(TaskQuery(projectId: projectId)),
        onValue: (valueId) => _list(TaskQuery(valueId: valueId)),
      );

  /// The one list face. [opens] is how a row is opened: pushed where the face itself was pushed,
  /// beside the list where it is the tab.
  Widget _searchFace(
    TaskQuery narrowing, {
    required void Function(int taskId) opens,
  }) => SearchScreen(
    store: widget.store,
    narrowing: narrowing,
    clock: widget.clock,
    onOpenTask: (line) => opens(line.id),
    onOpenDecision: (line) => _openDecision(line.id),
  );

  /// A tab's list, with what it opened beside it once there is width for two.
  Widget _pane(Widget list) => TwoPane(
    list: list,
    detail: _besideTaskId == null
        ? null
        : _detail(
            _besideTaskId!,
            opens: (id) => setState(() => _besideTaskId = id),
          ),
    placeholder: Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.pageGutter),
        child: Text(
          Words.of(context).nothingOpen,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ),
  );

  /// Moving between the three ways out.
  ///
  /// The same handler whichever side of the screen the destinations were drawn on: what a tab does
  /// is not a fact about where it sits.
  void _goTo(int chosen) => setState(() {
    _tab = chosen;
    // What was open belonged to the list being left.
    _besideTaskId = null;
    // The front screen is the first, and the only one that is not read fresh on arrival.
    if (chosen != 0) _visits += 1;
  });

  @override
  Widget build(BuildContext context) {
    final words = Words.of(context);
    // The bottom is where a thumb reaches on a phone held in one hand, and nowhere else. On a
    // tablet, or a phone turned sideways, that hand is not holding it and the bottom edge is the
    // furthest point on the glass — so the ways out move to the side the same width the list and
    // the detail split at, both being the same judgement about how it is being held.
    final wide = _wide;
    // The three keep their state while the person moves between them — the front screen most of
    // all, which holds what arrived while it was being read behind a pill and would let those
    // rows in unasked if it were rebuilt. The two that are keyed on the visit are the exception,
    // and they are keyed because being read fresh is what they are for.
    final tabs = IndexedStack(
      index: _tab,
      children: [
        _pane(
          NowScreen(
            store: widget.store,
            clock: widget.clock,
            doneWindow: widget.settings.value.doneWindow,
            take: widget.take,
            arrivals: widget.arrivals,
            failure: widget.failure,
            iCloudAvailable: widget.iCloudAvailable,
            onOpen: (line) => _open(line.id),
            onPairAgain: widget.onPairAgain,
            onOpenSettings: _openSettings,
          ),
        ),
        KeyedSubtree(
          key: ValueKey(('decisions', _visits)),
          // Not in a pane: a decision is always pushed, whatever the width, so there is never one
          // sitting beside this list.
          child: DecisionsScreen(
            store: widget.store,
            clock: widget.clock,
            take: widget.take,
            onOpen: (line) => _openDecision(line.id),
          ),
        ),
        KeyedSubtree(
          key: ValueKey(('search', _visits)),
          child: _pane(_searchFace(const TaskQuery(), opens: _open)),
        ),
      ],
    );

    return Scaffold(
      body: wide
          ? Row(
              children: [
                _rail(words),
                const VerticalDivider(width: Stroke.rule),
                Expanded(child: tabs),
              ],
            )
          : tabs,
      bottomNavigationBar: wide ? null : _bar(words),
    );
  }

  /// The three ways out, down the side.
  ///
  /// The labels stay under the icons rather than being shown for the chosen one alone: a list
  /// icon, a gavel and a magnifying glass are not three things anybody reads at a glance, and a
  /// way out nobody can name is one they find by pressing it.
  Widget _rail(Words words) => NavigationRail(
    selectedIndex: _tab,
    onDestinationSelected: _goTo,
    labelType: NavigationRailLabelType.all,
    destinations: [
      NavigationRailDestination(
        icon: const Icon(Icons.list_alt_outlined),
        selectedIcon: const Icon(Icons.list_alt),
        label: Text(words.tabTasks),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.gavel_outlined),
        selectedIcon: const Icon(Icons.gavel),
        label: Text(words.tabDecisions),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.search_outlined),
        selectedIcon: const Icon(Icons.search),
        label: Text(words.tabSearch),
      ),
    ],
  );

  /// The same three, across the bottom, where a thumb is what reaches them.
  Widget _bar(Words words) => NavigationBar(
    selectedIndex: _tab,
    onDestinationSelected: _goTo,
    destinations: [
      NavigationDestination(
        icon: const Icon(Icons.list_alt_outlined),
        selectedIcon: const Icon(Icons.list_alt),
        label: words.tabTasks,
      ),
      NavigationDestination(
        icon: const Icon(Icons.gavel_outlined),
        selectedIcon: const Icon(Icons.gavel),
        label: words.tabDecisions,
      ),
      NavigationDestination(
        icon: const Icon(Icons.search_outlined),
        selectedIcon: const Icon(Icons.search),
        label: words.tabSearch,
      ),
    ],
  );
}
