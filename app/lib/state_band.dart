/// One line at the top, for the seven ways things can stand.
///
/// The promise the whole app is built on is that **it never breaks quietly**. Every state below is
/// one the person can end up in without doing anything wrong — a train tunnel, a signed-out iCloud,
/// a PC that has not sent anything yet — and each of them has to be told apart from the others,
/// because the next thing to do is different in every case and identical silence is what makes
/// somebody reinstall an app that was working.
///
/// Two rules hold across all of them.
///
/// * **What is on the device stays readable.** The band sits above the picture; it never replaces
///   it. Only a device that has never had anything has nothing to put underneath.
/// * **Nothing here is drawn as a failure.** No dialog, no red screen, no empty list. Offline is
///   not a fault, it is one of the shapes ordinary use takes.
library;

import 'package:flutter/material.dart';

import 'cloudflare_intake.dart';
import 'ui/time.dart';

/// Which single line is owed, out of everything that is true at once.
enum Standing {
  /// Nothing worth a line.
  quiet,

  /// The place writes a contract this build does not read.
  tooNew,

  /// Records arrived and this device's key did not open them.
  unreadable,

  /// The place turned this device away. The token was revoked, or it was never for this place.
  refused,

  /// The iCloud route, with nobody signed in to iCloud.
  noICloud,

  /// The last round could not reach the place.
  offline,

  /// Paired, reachable, and the place has not been given anything yet.
  waiting,
}

/// Picks the one line to show.
///
/// **A cause outranks an absence.** "Nothing has arrived yet" is the only state here that merely
/// describes what is missing; every other one names why. Showing the absence while a cause is
/// known would be the app's one outright lie — something did arrive, or something did stop it, and
/// the person would be waiting on a PC that had already done its part.
///
/// Among the causes the order is how much they take away: a contract this build cannot read stops
/// everything, a key that does not open stops the records, a refusal stops the fetch, a signed-out
/// iCloud stops one route, and being unreachable stops nothing that is already here.
Standing standingOf({
  required bool anythingHere,
  IntakeFailure? failure,
  bool? iCloudAvailable,
}) {
  switch (failure) {
    case IntakeFailure.tooNew:
      return Standing.tooNew;
    case IntakeFailure.unreadable:
      return Standing.unreadable;
    case IntakeFailure.refused:
      return Standing.refused;
    case IntakeFailure.unreachable:
      // Held below iCloud: being signed out is the more specific of the two, and the one with
      // something to do about it.
      if (iCloudAvailable == false) return Standing.noICloud;
      return Standing.offline;
    // The intake empties the local copy and takes the place from the beginning by itself, so by
    // the time anybody could read a line about it there is nothing left to say.
    case IntakeFailure.rebuilt:
    case null:
      break;
  }
  if (iCloudAvailable == false) return Standing.noICloud;
  if (!anythingHere) return Standing.waiting;
  return Standing.quiet;
}

/// What each standing says.
String standingWords(Standing standing) => switch (standing) {
  Standing.quiet => '',
  Standing.tooNew => 'Your PC is writing a newer format than this app reads',
  Standing.unreadable => "This device's key does not open what arrived",
  Standing.refused => 'Your PC turned this device away',
  Standing.noICloud => 'Sign in to iCloud to read what your PC leaves there',
  Standing.offline => 'Offline',
  Standing.waiting => 'Nothing has arrived yet',
};

/// The line under it, where there is something useful to add.
///
/// Every one of these says what happens next without asking for a retry. There is nothing to press
/// again: the app takes another round on its own the moment it can.
String standingDetail(Standing standing) => switch (standing) {
  Standing.tooNew => 'Update the app and the rest will read',
  Standing.unreadable => 'Pair this device again to get a key that opens it',
  Standing.refused => 'Pair this device again',
  Standing.noICloud => 'It is the iPhone settings, not this app',
  Standing.waiting => 'Your PC sends it the next time your backlog changes',
  _ => '',
};

class StateBand extends StatelessWidget {
  const StateBand({
    super.key,
    required this.standing,
    this.lastTakenAt,
    this.onPairAgain,
    this.onOpenSettings,
    this.whole = false,
    this.clock = DateTime.now,
  });

  final Standing standing;

  /// When the last round finished, which is what says how old the picture underneath is.
  final DateTime? lastTakenAt;

  final VoidCallback? onPairAgain;
  final VoidCallback? onOpenSettings;

  /// Passed in rather than read here, so the band and the rows under it cannot disagree about
  /// what day it is — which is the whole of what [takenAt] needs it for.
  final DateTime Function() clock;

  /// True where there is no picture to sit above — a device that has never had anything. Then the
  /// same words take the screen instead of a strip of it.
  final bool whole;

  static const pairAgain = 'Pair again';
  static const openSettings = 'Open settings';

  /// The clock, not "3 h ago".
  ///
  /// This is the one place the app spells a time out. What the person is judging here is how old
  /// what they are reading is, and a phone whose clock is wrong can still say the hour it took
  /// something at — where "3 h ago" would be wrong by exactly the amount the clock is out.
  ///
  /// The day comes with it once it is not today's. This line is the only thing a phone with no
  /// signal has to date what it is reading by, and out of signal is exactly where a picture stops
  /// being hours old and starts being days old.
  static String takenAt(DateTime when, {required DateTime now}) =>
      'Taken ${clockOnDay(when, now: now)}';

  @override
  Widget build(BuildContext context) {
    if (standing == Standing.quiet) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final detail = standingDetail(standing);
    final taken = lastTakenAt;
    final action = switch (standing) {
      Standing.unreadable || Standing.refused =>
        onPairAgain == null ? null : (label: pairAgain, onTap: onPairAgain!),
      Standing.noICloud =>
        onOpenSettings == null
            ? null
            : (label: openSettings, onTap: onOpenSettings!),
      _ => null,
    };

    final lines = Column(
      crossAxisAlignment: whole
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Text(
          standingWords(standing),
          textAlign: whole ? TextAlign.center : TextAlign.start,
          style: whole
              ? theme.textTheme.titleMedium
              : theme.textTheme.bodyMedium,
        ),
        if (detail.isNotEmpty)
          Text(
            detail,
            textAlign: whole ? TextAlign.center : TextAlign.start,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        if (taken != null)
          TimeOnHold(
            when: taken,
            child: Text(
              takenAt(taken, now: clock()),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (action != null)
          TextButton(onPressed: action.onTap, child: Text(action.label)),
      ],
    );

    if (whole) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
        child: lines,
      );
    }
    return Container(
      width: double.infinity,
      // The same quiet surface for all seven. None of them is an error, and a band that turned
      // red for some of them would teach the person to read the colour instead of the words.
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: lines,
    );
  }
}
