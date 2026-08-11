/// The first round after pairing — the one wait in this app that is long enough to be felt.
///
/// Every later round is a few rows arriving behind a screen that already has something on it. The
/// first one carries the whole backlog into a phone holding nothing, and the person who just
/// pointed a camera at their PC is sitting in front of it with no way to tell a slow sync from a
/// broken one. So this screen exists only for that, and it is built around what someone waiting
/// actually needs:
///
/// * **numbers, not a bar alone.** A count that climbs says work is being done; a bar alone at 40%
///   says the same thing whether it moved a second ago or a minute ago.
/// * **an interruption costs the page it was on.** The intake writes and moves its cursor page by
///   page, so leaving and coming back carries on. Saying so is the difference between waiting and
///   giving up.
/// * **one buzz at the end, and no congratulations.** The phone was empty and now is not, which is
///   worth feeling once. What the person came for is the backlog, not a screen telling them the
///   backlog arrived.
///
/// The round reaches the screen as a function, so the whole of the above can be walked in a test
/// with no network and no store behind it.
library;

import 'package:flutter/material.dart';

import 'cloudflare_intake.dart';
import 'l10n/words.dart';
import 'ui/measure.dart';
import 'ui/tokens.dart';
import 'ui/touch.dart';

/// One round of the intake, reporting as it goes.
///
/// This is `run` with its `watching` named — either route's, since both report the same shape.
/// Whoever waits on it holds a function rather than an intake, so it can be run against answers
/// written by hand.
typedef TakeTheBacklog =
    Future<IntakeReport> Function(
      void Function(IntakeProgress reached) watching,
    );

/// What stopped the round, in words.
///
/// The intake carries which refusal it is and no sentence, so this is where one is chosen. Five
/// of them, and no "something went wrong": the line under this one says what to do next, and it
/// is a different thing to do in every case.
String whatStopped(Words words, IntakeFailure failure) => switch (failure) {
  IntakeFailure.unreachable => words.stopUnreachable,
  IntakeFailure.refused => words.stopRefused,
  IntakeFailure.tooNew => words.stopTooNew,
  IntakeFailure.rebuilt => words.stopRebuilt,
  IntakeFailure.unreadable => words.stopUnreadable,
};

class FirstSyncScreen extends StatefulWidget {
  const FirstSyncScreen({super.key, required this.take});

  final TakeTheBacklog take;

  @override
  State<FirstSyncScreen> createState() => _FirstSyncScreenState();
}

class _FirstSyncScreenState extends State<FirstSyncScreen> {
  /// Records across every round this screen has run, not just the current one. A round that
  /// failed halfway and was tried again would otherwise count back down from zero in front of
  /// someone watching the number for reassurance.
  int _records = 0;

  /// Where the round stands in the order, or null before the place has said anything.
  double? _through;

  /// Why the last round stopped, when one did.
  IntakeException? _stopped;

  bool _running = false;

  @override
  void initState() {
    super.initState();
    _take();
  }

  Future<void> _take() async {
    if (_running) return;
    final before = _records;
    setState(() {
      _running = true;
      _stopped = null;
    });

    try {
      final report = await widget.take((reached) {
        if (!mounted) return;
        setState(() {
          _records = before + reached.records;
          _through = reached.through;
        });
      });
      if (!mounted) return;
      setState(() {
        _records = before + report.records;
        _running = false;
      });
      // The one moment the app was empty and now is not. It comes before the screen goes, so it
      // lands while the person is still looking at the thing that finished.
      await Touch.firstSyncFinished();
      if (!mounted) return;
      Navigator.of(context).pop(report);
    } on IntakeException catch (stopped) {
      if (!mounted) return;
      setState(() {
        _stopped = stopped;
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final words = Words.of(context);
    final stopped = _stopped;

    return Scaffold(
      appBar: AppBar(title: Text(words.firstSyncTitle)),
      body: Measured.prose(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Space.pageGutter,
            Space.s7,
            Space.pageGutter,
            Space.s7,
          ),
          children: [
            Text(
              _records == 0
                  ? words.firstSyncOpening
                  : words.firstSyncTaken(_records),
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: Space.s6),
            // Determinate once there is a position worth pointing at, and indeterminate while there
            // is not — a bar sitting at zero would read as stuck rather than as still going. A round
            // that stopped holds still at where it got to.
            LinearProgressIndicator(
              value: _running && (_through ?? 0) == 0 ? null : (_through ?? 0),
            ),
            const SizedBox(height: Space.s6),
            // Promising that it carries on is only true while carrying on is still what happens
            // next. Under a refusal it is the sentence that keeps somebody sitting here.
            if (stopped == null || worthAnotherRound(stopped.failure))
              Text(
                words.firstSyncCarriesOn,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            if (stopped != null) ...[
              const SizedBox(height: Space.s7),
              Text(
                whatStopped(words, stopped.failure),
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              const SizedBox(height: Space.s3),
              Text(
                _wayOut(words, stopped.failure),
                style: theme.textTheme.bodyMedium,
              ),
              if (worthAnotherRound(stopped.failure)) ...[
                const SizedBox(height: Space.s6),
                FilledButton(
                  onPressed: _running ? null : _take,
                  child: Text(words.tryAgain),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// What there is to do about a round that stopped. Each of these has a different next step, and
  /// a single "something went wrong" would send everyone to the same wrong one.
  static String _wayOut(Words words, IntakeFailure failure) =>
      switch (failure) {
        IntakeFailure.unreachable => words.wayOutUnreachable,
        IntakeFailure.refused => words.wayOutRefused,
        IntakeFailure.tooNew => words.wayOutTooNew,
        IntakeFailure.rebuilt => words.wayOutRebuilt,
        IntakeFailure.unreadable => words.wayOutUnreadable,
      };
}
