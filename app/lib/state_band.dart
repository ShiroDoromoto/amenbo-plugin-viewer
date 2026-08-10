/// One line at the top, for the seven ways things can stand.
///
/// The promise the whole app is built on is that **it never breaks quietly**. Every state below is
/// one the person can end up in without doing anything wrong — a train tunnel, a signed-out iCloud,
/// a PC that has not sent anything yet — and each of them has to be told apart from the others,
/// because the next thing to do is different in every case and identical silence is what makes
/// somebody reinstall an app that was working.
///
/// Three rules hold across all of them.
///
/// * **What is on the device stays readable.** The band sits above the picture; it never replaces
///   it. Only a device that has never had anything has nothing to put underneath.
/// * **Nothing here is drawn as a failure.** No dialog, no red screen, no empty list. Offline is
///   not a fault, it is one of the shapes ordinary use takes.
/// * **The ones with a way out are the ones drawn to be seen** ([standingIsLifted]). The rest keep
///   the quiet strip — still said, in words, and not made to look like something went wrong.
library;

import 'package:flutter/material.dart';

import 'cloudflare_intake.dart';
import 'l10n/words.dart';
import 'ui/tokens.dart';

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
String standingWords(Words words, Standing standing) => switch (standing) {
  Standing.quiet => '',
  Standing.tooNew => words.standingTooNew,
  Standing.unreadable => words.standingUnreadable,
  Standing.refused => words.standingRefused,
  Standing.noICloud => words.standingNoICloud,
  Standing.offline => words.standingOffline,
  Standing.waiting => words.standingWaiting,
};

/// The line under it, where there is something useful to add.
///
/// Every one of these says what happens next without asking for a retry. There is nothing to press
/// again: the app takes another round on its own the moment it can.
String standingDetail(Words words, Standing standing) => switch (standing) {
  Standing.tooNew => words.standingDetailTooNew,
  Standing.unreadable => words.standingDetailUnreadable,
  Standing.refused => words.standingDetailRefused,
  Standing.noICloud => words.standingDetailNoICloud,
  Standing.waiting => words.standingDetailWaiting,
  _ => '',
};

/// The three the person can do something about, and the only three drawn to be noticed.
///
/// Seven lines all wearing the same quiet strip is seven lines nobody reads, and the one that
/// matters — a device whose key does not open what arrives — then goes on receiving nothing for as
/// long as it is ignored. So these are lifted: a colour of their own, a mark, and their way out as
/// a button that looks like one.
///
/// **Three is the cap, not the count so far.** Every state that is lifted makes the lifting mean
/// less, and a band that is loud about everything is the quiet band again. The line is drawn at
/// what the person can act on from here: a contract this build cannot read is real and is not on
/// this list, because nothing in this app will fix it.
bool standingIsLifted(Standing standing) => switch (standing) {
  Standing.unreadable || Standing.refused || Standing.noICloud => true,
  _ => false,
};

/// The mark a lifted line wears. It says which of the three this is, so the colour is never
/// carrying that on its own.
IconData? standingMark(Standing standing) => switch (standing) {
  Standing.unreadable => Icons.key_off_outlined,
  Standing.refused => Icons.do_not_disturb_on_outlined,
  Standing.noICloud => Icons.cloud_off_outlined,
  _ => null,
};

class StateBand extends StatelessWidget {
  const StateBand({
    super.key,
    required this.standing,
    this.onPairAgain,
    this.onOpenSettings,
    this.whole = false,
  });

  final Standing standing;

  final VoidCallback? onPairAgain;
  final VoidCallback? onOpenSettings;

  /// True where there is no picture to sit above — a device that has never had anything. Then the
  /// same words take the screen instead of a strip of it.
  final bool whole;

  @override
  Widget build(BuildContext context) {
    if (standing == Standing.quiet) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final words = Words.of(context);
    final detail = standingDetail(words, standing);
    final action = switch (standing) {
      Standing.unreadable || Standing.refused =>
        onPairAgain == null
            ? null
            : (label: words.bandPairAgain, onTap: onPairAgain!),
      Standing.noICloud =>
        onOpenSettings == null
            ? null
            : (label: words.bandOpenSettings, onTap: onOpenSettings!),
      _ => null,
    };

    final lifted = standingIsLifted(standing);
    final mark = standingMark(standing);
    // The accent, and not the error colour. Something is in the way and the person can move it —
    // that is the same thing the accent says everywhere else in the app, where red would say the
    // app has broken.
    final onBand = lifted
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;
    final under = lifted
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;

    final lines = Column(
      crossAxisAlignment: whole
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Text(
          standingWords(words, standing),
          textAlign: whole ? TextAlign.center : TextAlign.start,
          style:
              (whole || lifted
                      ? theme.textTheme.titleMedium
                      : theme.textTheme.bodyMedium)
                  ?.copyWith(color: onBand),
        ),
        if (detail.isNotEmpty)
          Text(
            detail,
            textAlign: whole ? TextAlign.center : TextAlign.start,
            style: theme.textTheme.bodySmall?.copyWith(color: under),
          ),
        // A way out that is drawn as one. The three that carry a button are the three worth
        // pressing, so nothing is gained by making them look like text.
        if (action != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.hair),
            child: FilledButton(
              onPressed: action.onTap,
              child: Text(action.label),
            ),
          ),
      ],
    );

    if (whole) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.pageGutter,
          Space.emptyScreenTop,
          Space.pageGutter,
          Space.pageGutter,
        ),
        child: Column(
          children: [
            if (mark != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.s3),
                child: Icon(mark, color: onBand),
              ),
            lines,
          ],
        ),
      );
    }
    return Container(
      width: double.infinity,
      // Two surfaces, not seven: the quiet one for what the person cannot do anything about, and
      // the accent for the three they can. Neither is the error colour — a band that turned red
      // for being out of signal would teach the person to read the colour instead of the words,
      // and then the colour would be all that is read.
      color: lifted
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.gutter,
        vertical: Space.s3,
      ),
      child: mark == null
          ? lines
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    top: Space.hair,
                    right: Space.s3,
                  ),
                  child: Icon(mark, color: onBand),
                ),
                Expanded(child: lines),
              ],
            ),
    );
  }
}
