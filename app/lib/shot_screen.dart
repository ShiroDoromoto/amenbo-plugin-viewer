/// A third entrypoint, for the one job nobody can do by hand every time the screens move: the
/// pictures the two stores put next to the app.
///
/// ```
/// tool/store-shots.sh ios
/// tool/store-shots.sh android
/// ```
///
/// **Why not the real phone.** The way in is a QR code read through the camera and nothing else,
/// so a simulator cannot be paired and shows the guide forever; and the phone that *is* paired
/// draws 1125x2436, which is not a size either store has a slot for any more. This seeds the rows
/// itself, which leaves the picture to a simulator of whatever size a store asks for.
///
/// **What it draws is the app.** The same screens, the same theme, the same sheet of words — what
/// is standing in is the backlog behind them ([sampleBacklog]) and the round that would go and
/// fetch one. Nothing here is reachable from `main.dart`, so none of it is in a build that ships.
///
/// **How the pictures are actually taken.** Not from in here: a simulator's pixels are the host's
/// to grab (`simctl io screenshot`, `adb exec-out screencap`), and what the host cannot do is
/// press anything. So this walks the screens itself and stops at each one, leaving a file behind
/// to say which screen is standing still — the script takes the picture and deletes the file,
/// which is what lets the next screen come up. Neither side guesses at a delay.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'connection.dart';
import 'home.dart';
import 'l10n/language.dart';
import 'l10n/words.dart';
import 'main.dart';
import 'pairing_guide.dart';
import 'settings.dart';
import 'shot_backlog.dart';
import 'store/backlog_store.dart';
import 'task_detail.dart';
import 'ui/theme.dart';

/// The screens the stores get, in the order they are taken.
enum Shot {
  /// What the app opens on: the four states of the backlog, and how old the picture is.
  front,

  /// One task, opened — the body, what it is waiting on, and the timeline.
  detail,

  /// The face that reads everything at once, tasks and decisions together.
  search,

  /// A phone with no way in yet. Nothing is seeded behind this one; the guide is the whole screen.
  guide,
}

/// Where the app says which screen is standing still.
///
/// The directory is asked for rather than taken from `Directory.systemTemp`, which is not the
/// same place on both systems: this is the app's own temporary directory either way — `tmp/`
/// inside the container on iOS, `cache/` inside the data directory on Android — and each is a
/// place the host has a way to reach.
const readyFileName = 'shot-ready.txt';

/// Long enough for the screen to arrive at what it settles into — a debug build warms up, and a
/// pushed route slides in. Nothing downstream depends on the number: the picture is not taken
/// until the file below it appears.
const _settle = Duration(milliseconds: 2500);

/// How long a screen waits to be photographed before giving up on the script and moving on.
const _patience = Duration(minutes: 3);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final store = await BacklogStore.open();
  // A run starts from a phone holding nothing, so a second run cannot photograph the leftovers of
  // the first — and so the rows are dated from this moment rather than from whenever the last run
  // seeded them.
  store.wipe();
  final now = DateTime.now();
  store.applyPage(sampleBacklog(now), seq: 4821, version: 1);
  // Four minutes before the clock the status bar is pinned to, so the hour on the screen and the
  // hour above it are not two different times of day in the same picture.
  store.setMeta(
    MetaKey.fetchedAt,
    DateTime(now.year, now.month, now.day, 9, 37).toUtc().toIso8601String(),
  );
  final settings = SettingsController(StoredSettings(store));
  final marker = File('${(await getTemporaryDirectory()).path}/$readyFileName');

  for (final shot in Shot.values) {
    // Keyed on the shot, so each one is a fresh tree rather than an update to the one before it.
    // Without that, a screen that opens somewhere — the tab the shell starts on, the detail that
    // is pushed once — would be settled by the first shot and never move again.
    runApp(
      _ShotApp(
        key: ValueKey(shot),
        shot: shot,
        store: store,
        settings: settings,
      ),
    );
    await Future<void>.delayed(_settle);
    await _standStill(shot, marker);
  }
  debugPrint('store shots: every screen has been photographed');
}

/// Says which screen is up, and waits for the host to say it has the picture.
///
/// The waiting is the point. A delay picked in here and a delay picked in the script would be two
/// guesses at the same number, and the run would go wrong silently the first time a debug build
/// took a second longer than it used to.
Future<void> _standStill(Shot shot, File marker) async {
  try {
    marker.writeAsStringSync(shot.name);
  } catch (error) {
    debugPrint('store shots: could not say that ${shot.name} is up — $error');
    return;
  }
  final until = DateTime.now().add(_patience);
  while (marker.existsSync()) {
    if (DateTime.now().isAfter(until)) {
      debugPrint('store shots: nobody photographed ${shot.name} — moving on');
      marker.deleteSync();
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// The app, assembled around one screen.
///
/// It is `main.dart`'s assembly with two things stood in for: the pairing this phone would have
/// been given, and the round that would go and use it. Neither one can be had on a simulator, and
/// neither one is in the picture.
class _ShotApp extends StatefulWidget {
  const _ShotApp({
    super.key,
    required this.shot,
    required this.store,
    required this.settings,
  });

  final Shot shot;
  final BacklogStore store;
  final SettingsController settings;

  @override
  State<_ShotApp> createState() => _ShotAppState();
}

class _ShotAppState extends State<_ShotApp> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // The detail is a pushed route in the app, and it is photographed as one — so it is pushed
    // here too, rather than drawn as if it were a screen the app opens on. The way back is part
    // of what the picture shows.
    if (widget.shot == Shot.detail) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _navigator.currentState?.push(
          MaterialPageRoute<void>(
            builder: (_) => TaskDetailScreen(
              store: widget.store,
              taskId: shotTaskId,
              onOpenTask: (_) {},
              onOpenDecision: (_) {},
              onProject: (_) {},
              onValue: (_) {},
            ),
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AmenboViewerApp.title,
      // A ribbon across the corner of a picture in a store listing would be the app's first word
      // to somebody deciding whether to install it.
      debugShowCheckedModeBanner: false,
      localizationsDelegates: Words.localizationsDelegates,
      supportedLocales: Words.supportedLocales,
      localeListResolutionCallback: languageFor,
      // The one set the stores get is the English one, so it is asked for here rather than left to
      // whatever language the simulator was last set to. Nothing is written on top of these
      // pictures, which is why one set covers all nineteen.
      locale: const Locale('en'),
      theme: viewerTheme(Brightness.light),
      darkTheme: viewerTheme(Brightness.dark),
      themeMode: widget.settings.value.appearance.themeMode,
      navigatorKey: _navigator,
      home: switch (widget.shot) {
        Shot.guide => PairingGuideScreen(
          appName: AmenboViewerApp.title,
          onPaired: (_) {},
        ),
        Shot.front || Shot.detail => _shell(0),
        Shot.search => _shell(2),
      },
    );
  }

  /// The three tabs, opened on one of them.
  Widget _shell(int tab) => HomeShell(
    store: widget.store,
    settings: widget.settings,
    connection: PhoneConnection(store: widget.store),
    appName: AmenboViewerApp.title,
    initialTab: tab,
    // A route this phone has, so the front screen draws the way to ask for a fresh picture. It
    // does not go anywhere: what is being photographed is the screen, not a fetch.
    take: () async {},
  );
}
