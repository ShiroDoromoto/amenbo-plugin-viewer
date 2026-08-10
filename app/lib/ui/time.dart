/// Time as the screens say it.
///
/// Everything is relative, because what the person is judging is freshness — "12 min ago" answers
/// "has anything happened" and a timestamp does not. The exact instant is still there, one long
/// press away, for the times it is the answer.
///
/// The clock is passed in rather than read here, so a list and the line above it cannot disagree
/// about what "now" was.
///
/// **What is a phrase and what is a convention are held apart.** "just now", "12 min ago" and
/// "yesterday" are phrases: a language writes them its own way and they live in the sheet of
/// words like everything else on the screen. A month's name, whether the day comes before it, and
/// whether the clock runs to twelve or to twenty-four are conventions: they are the same in every
/// app that language is read in, and asking nineteen translators to reinvent them key by key is
/// how a date ends up written in a way nobody there writes dates.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/words.dart';

/// How this phone writes a date and a clock.
///
/// Two things decide it, and neither is a screen's to choose: the language the app is being read
/// in, and whether its owner set a 24-hour clock. Both arrive together so that no caller can pick
/// up one and forget the other.
@immutable
class TimeFace {
  const TimeFace(this.words, {required this.hours24});

  TimeFace.of(BuildContext context)
    : this(
        Words.of(context),
        // The phone's own switch, not the language's habit. Somebody who turned it on wants
        // 14:02 in every app, including the ones written in a language that would say 2 PM.
        hours24: MediaQuery.alwaysUse24HourFormatOf(context),
      );

  final Words words;
  final bool hours24;

  /// The language the phrases are being read in, which is the same one the conventions come from.
  String get locale => words.localeName;
}

/// `12 min ago` / `yesterday 14:02` / `Aug 2` / `Aug 2, 2025` — the English of it. Every part
/// past the count is written the way the language being read is written.
///
/// It stops being a count of minutes as soon as counting stops helping: yesterday is named, and
/// anything older is a date, because "9,412 min ago" is a number nobody converts.
String relativeTime(TimeFace face, DateTime when, {required DateTime now}) {
  final words = face.words;
  final local = when.toLocal();
  final gap = now.difference(local);

  if (gap.inSeconds < 60) return words.timeJustNow;
  if (gap.inMinutes < 60) return words.timeMinutesAgo(gap.inMinutes);
  if (gap.inHours < 24 && _sameDay(local, now)) {
    return words.timeHoursAgo(gap.inHours);
  }

  final yesterday = now.subtract(const Duration(days: 1));
  if (_sameDay(local, yesterday)) {
    return words.timeYesterdayAt(clockTime(face, local));
  }

  return local.year == now.year
      ? _date(face, local)
      : _dateWithYear(face, local);
}

/// The whole instant, spelled out — what the long press reveals.
String absoluteTime(TimeFace face, DateTime when) {
  final local = when.toLocal();
  return face.words.dateAndTime(
    _dateWithYear(face, local),
    clockTime(face, local),
  );
}

/// A day on its own (`due_on`, `start_on`), which amenbo writes as `YYYY-MM-DD`.
String dayLabel(TimeFace face, String isoDay, {required DateTime now}) {
  final parsed = DateTime.tryParse(isoDay);
  if (parsed == null) return isoDay;
  return dateHeading(face, parsed, now: now);
}

/// The day an instant fell on, as a heading over the rows that share it.
///
/// The year comes with it once it is not this one. A list of finished work reaches back years, and
/// a heading that said only the month and the day would repeat itself once a year without saying
/// which one the reader is now in.
String dateHeading(TimeFace face, DateTime when, {required DateTime now}) {
  final local = when.toLocal();
  return local.year == now.year
      ? _date(face, local)
      : _dateWithYear(face, local);
}

/// Reveals [when] in full while it is held down.
///
/// A long press, not a tap: tapping a row opens it, and the exact time is wanted rarely enough
/// that it must not take the gesture that everything else uses.
class TimeOnHold extends StatelessWidget {
  const TimeOnHold({super.key, required this.when, required this.child});

  final DateTime when;
  final Widget child;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: absoluteTime(TimeFace.of(context), when),
    triggerMode: TooltipTriggerMode.longPress,
    // The tooltip would otherwise be read out as a second thing on a row that is meant to be
    // read as one; the label the row carries already says the relative time.
    excludeFromSemantics: true,
    child: child,
  );
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// The wall clock, `14:02` or `2:02 PM`. Used where the question is when something happened rather
/// than how long ago — a phone whose clock is out can still name the hour it took something at.
String clockTime(TimeFace face, DateTime when) => face.hours24
    ? DateFormat.Hm(face.locale).format(when)
    : DateFormat.jm(face.locale).format(when);

/// The wall clock with its day in front of it once today stops being the answer.
///
/// `14:02` / `yesterday 14:02` / `Aug 2 14:02` / `Aug 2, 2025 14:02`.
///
/// Still the clock rather than a count of hours, for the same reason [clockTime] is — but an hour
/// on its own only names a moment while it is today's. A phone that spent the night out of signal
/// would otherwise say `09:14` about a picture two days old.
String clockOnDay(TimeFace face, DateTime when, {required DateTime now}) {
  final local = when.toLocal();
  final time = clockTime(face, local);
  if (_sameDay(local, now)) return time;
  if (_sameDay(local, now.subtract(const Duration(days: 1)))) {
    return face.words.timeYesterdayAt(time);
  }
  return local.year == now.year
      ? face.words.dateThenTime(_date(face, local), time)
      : face.words.dateThenTime(_dateWithYear(face, local), time);
}

/// A day and its month, in whichever order this language writes them.
String _date(TimeFace face, DateTime when) =>
    DateFormat.MMMd(face.locale).format(when);

String _dateWithYear(TimeFace face, DateTime when) =>
    DateFormat.yMMMd(face.locale).format(when);
