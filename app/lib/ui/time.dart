/// Time as the screens say it.
///
/// Everything is relative, because what the person is judging is freshness — "12 min ago" answers
/// "has anything happened" and a timestamp does not. The exact instant is still there, one long
/// press away, for the times it is the answer.
///
/// The clock is passed in rather than read here, so a list and the line above it cannot disagree
/// about what "now" was. The words are passed in for the same reason they are everywhere else:
/// nothing here writes its own text.
library;

import 'package:flutter/material.dart';

import '../l10n/words.dart';

/// `12 min ago` / `yesterday 14:02` / `2 Aug` / `2 Aug 2025`.
///
/// It stops being a count of minutes as soon as counting stops helping: yesterday is named, and
/// anything older is a date, because "9,412 min ago" is a number nobody converts.
String relativeTime(Words words, DateTime when, {required DateTime now}) {
  final local = when.toLocal();
  final gap = now.difference(local);

  if (gap.inSeconds < 60) return words.timeJustNow;
  if (gap.inMinutes < 60) return words.timeMinutesAgo(gap.inMinutes);
  if (gap.inHours < 24 && _sameDay(local, now)) {
    return words.timeHoursAgo(gap.inHours);
  }

  final yesterday = now.subtract(const Duration(days: 1));
  if (_sameDay(local, yesterday)) {
    return words.timeYesterdayAt(clockTime(local));
  }

  return local.year == now.year
      ? _date(words, local)
      : words.dateWithYear(_date(words, local), local.year);
}

/// The whole instant, spelled out — what the long press reveals.
String absoluteTime(Words words, DateTime when) {
  final local = when.toLocal();
  return words.dateAndTime(
    words.dateWithYear(_date(words, local), local.year),
    clockTime(local),
  );
}

/// A day on its own (`due_on`, `start_on`), which amenbo writes as `YYYY-MM-DD`.
String dayLabel(Words words, String isoDay, {required DateTime now}) {
  final parsed = DateTime.tryParse(isoDay);
  if (parsed == null) return isoDay;
  return parsed.year == now.year
      ? _date(words, parsed)
      : words.dateWithYear(_date(words, parsed), parsed.year);
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
    message: absoluteTime(Words.of(context), when),
    triggerMode: TooltipTriggerMode.longPress,
    // The tooltip would otherwise be read out as a second thing on a row that is meant to be
    // read as one; the label the row carries already says the relative time.
    excludeFromSemantics: true,
    child: child,
  );
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// The wall clock, `14:02`. Used where the question is when something happened rather than how
/// long ago — a phone whose clock is out can still name the hour it took something at.
String clockTime(DateTime when) =>
    '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';

/// The wall clock with its day in front of it once today stops being the answer.
///
/// `14:02` / `yesterday 14:02` / `2 Aug 14:02` / `2 Aug 2025 14:02`.
///
/// Still the clock rather than a count of hours, for the same reason [clockTime] is — but an hour
/// on its own only names a moment while it is today's. A phone that spent the night out of signal
/// would otherwise say `09:14` about a picture two days old.
String clockOnDay(Words words, DateTime when, {required DateTime now}) {
  final local = when.toLocal();
  final time = clockTime(local);
  if (_sameDay(local, now)) return time;
  if (_sameDay(local, now.subtract(const Duration(days: 1)))) {
    return words.timeYesterdayAt(time);
  }
  return local.year == now.year
      ? words.dateThenTime(_date(words, local), time)
      : words.dateThenTime(
          words.dateWithYear(_date(words, local), local.year),
          time,
        );
}

String _month(Words words, int month) => switch (month) {
  1 => words.monthJanuary,
  2 => words.monthFebruary,
  3 => words.monthMarch,
  4 => words.monthApril,
  5 => words.monthMay,
  6 => words.monthJune,
  7 => words.monthJuly,
  8 => words.monthAugust,
  9 => words.monthSeptember,
  10 => words.monthOctober,
  11 => words.monthNovember,
  _ => words.monthDecember,
};

String _date(Words words, DateTime when) =>
    words.dateDayMonth(when.day, _month(words, when.month));
