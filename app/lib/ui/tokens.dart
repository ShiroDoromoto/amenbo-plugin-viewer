/// The numbers the whole app is drawn with — colours, spacing, corners, text sizes.
///
/// They are not decided here. They are a copy of the set Amenbo itself is drawn with, so that two
/// tools reading the same backlog do not look like two products. The copy is deliberate and it has
/// a cost: when Amenbo's own set moves, nothing here follows on its own.
///
/// Only four things are copied — colour, spacing, corner, text size. How a screen is put together
/// is not: Amenbo is read on a wide desk, this is read one-handed for half a minute, and the same
/// arrangement does not serve both.
///
/// **Nothing outside this file writes a number into a widget.** A padding written at the point of
/// use looks right to whoever wrote it and cannot be moved afterwards, which is the whole reason
/// the set exists.
library;

import 'package:flutter/material.dart';

/// Space between things. Amenbo's ladder, rung for rung.
///
/// [hair] is below the ladder on purpose: Amenbo has the same sub-rung, used the same way — the
/// optical nudge that lines a glyph up with the text beside it. It is named here so that even that
/// one is somewhere it can be found.
abstract final class Space {
  static const hair = 2.0;
  static const s1 = 4.0;
  static const s2 = 6.0;
  static const s3 = 8.0;
  static const s4 = 12.0;
  static const s5 = 16.0;
  static const s6 = 24.0;
  static const s7 = 32.0;

  /// The margin a list keeps from the edge of the glass. Rows are read by scanning down one edge,
  /// and every pixel here is taken off the title.
  static const gutter = s5;

  /// The margin a page of prose keeps instead. Wider, because sentences are read across rather
  /// than scanned down.
  static const pageGutter = s6;

  /// The air above the first line of an empty screen, which has nothing above it to push it down.
  static const emptyScreenTop = s7 * 2;
}

/// Widths that decide a layout rather than the space inside one. Amenbo keeps its own in the same
/// sheet, for the same reason: they are the numbers a screen would otherwise hide.
abstract final class Layout {
  /// Where one pane becomes two.
  ///
  /// Below it, no phone held upright qualifies; above it, a phone turned sideways and every tablet
  /// do. It is a width, not a device: asking what kind of machine this is gets the answer wrong
  /// for the same machine held the other way.
  static const twoPane = 720.0;

  /// The narrowest the list is drawn at once there is room to show a detail beside it. It keeps a
  /// readable measure and the detail takes the rest — a half-and-half split gives the list more
  /// width than a row of text wants.
  static const listPane = 360.0;

  /// The widest. Past it, more width would only stretch the titles: a row is read by scanning down
  /// its left edge, and the far end of a very long line is not where the eye goes.
  static const listPaneMax = 460.0;

  /// The share of a wide screen the list takes between those two. A third leaves the detail the
  /// two-thirds a page of prose wants, and it is what keeps the split growing with the glass
  /// instead of putting every extra pixel on one side.
  static const listPaneShare = 1 / 3;

  /// The widest a page of prose is drawn at. Past it a line runs long enough that the eye loses
  /// which row it is coming back to, so the page stops growing and sits in the middle of what it
  /// was given.
  static const readable = 760.0;

  /// The column a detail's link rows put their lead-in word in, so the refs beside them line up.
  static const leadColumn = 110.0;

  /// The column a numbered step's number sits in.
  static const stepNumber = 26.0;

  /// The smallest anything a finger presses is allowed to be.
  ///
  /// Both platforms ask for the same number, and it is not a matter of taste: it is roughly the
  /// width of a fingertip, and a target under it is one that gets missed on a moving train. What
  /// is *drawn* is free to be smaller — a number set in the running text of a card is the right
  /// size for reading and the wrong size for hitting — but what answers the press is not.
  static const touch = 48.0;
}

/// The two colours drawn over the camera.
///
/// They are not in the palette and they do not follow the brightness: a viewfinder is drawn over a
/// live photograph, which is neither a surface nor a background, and the frame has to be seen
/// against whatever the person is pointing at.
abstract final class OverCamera {
  static const frame = Color(0xffffffff);
  static const scrim = Color(0x99000000);
}

/// Line widths. Amenbo draws every rule and border at [rule]; [thick] is the one heavier stroke it
/// keeps for a line that has to be seen against a photograph rather than against a surface.
abstract final class Stroke {
  static const rule = 1.0;
  static const thick = 3.0;
}

/// Corners.
abstract final class Corner {
  static const sm = 5.0;
  static const md = 8.0;
  static const lg = 12.0;

  static const smooth = BorderRadius.all(Radius.circular(sm));
  static const rounded = BorderRadius.all(Radius.circular(md));
  static const wide = BorderRadius.all(Radius.circular(lg));
}

/// How long the two things that move take, and the shape they move with.
///
/// Motion belongs in the sheet for the same reason spacing does — written at the point of use it
/// drifts, and one place is the only place a phone asking for less of it can be answered.
///
/// There are two entries because there are two places: a section of a body folding, and the notice
/// of what has arrived coming and going. Everything else keeps whatever the platform already does,
/// screen to screen included. Motion here is not decoration; it is there so that a change nobody
/// pressed for can be seen happening rather than found already done.
abstract final class Motion {
  /// A section opening or closing under the finger that asked for it. Short: the person is waiting
  /// on the words, not on the movement.
  static const fold = Duration(milliseconds: 160);

  /// The notice of new arrivals, which comes in on its own and leaves once it is taken. A touch
  /// longer than a fold, because nothing pointed at it first.
  static const notice = Duration(milliseconds: 200);

  /// Away quickly and slowing into place — something settling where it was put.
  static const curve = Curves.easeOutCubic;

  /// [duration], or none at all where the person has asked their phone to move less. Both
  /// platforms carry that setting, and it is not a matter of taste: motion is what makes some
  /// people ill. Every animation in the app reads it through here.
  static Duration asked(BuildContext context, Duration duration) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;
}

/// Text sizes, and the weights and leading that go with them.
///
/// Writing sizes here is not the same as a widget writing its own size: these are the text theme,
/// and the OS text-size setting scales them. A number written into a widget is what stops
/// following that setting.
abstract final class Lettering {
  static const xxs = 10.0;
  static const xs = 12.0;
  static const sm = 13.0;
  static const md = 14.0;
  static const body = 16.0;
  static const lg = 17.0;
  static const xl = 20.0;

  /// Amenbo asks for 550 and 680. A system typeface is what draws this app (no face is shipped
  /// with it), and those land between the weights one offers, so each takes the nearer step.
  static const normal = FontWeight.w400;
  static const medium = FontWeight.w500;
  static const bold = FontWeight.w700;

  /// Amenbo's leading, which it sets on running text. Headings and marks are one line each here
  /// and take a tighter one — on a phone row that air is taken from the row below.
  static const leading = 1.5;
  static const leadingTight = 1.25;

  /// Whatever the phone calls its monospace face. Nothing is shipped, so this is a request the OS
  /// answers — see the note on the typeface in the app's README.
  static const mono = 'monospace';
}

/// One brightness worth of colour.
///
/// The names are Amenbo's. Which Material role each one lands on is decided once, in the theme.
class Palette {
  const Palette({
    required this.bg,
    required this.containerLowest,
    required this.containerLow,
    required this.container,
    required this.containerHigh,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.accent,
    required this.onAccent,
    required this.accentWeak,
    required this.accentText,
    required this.danger,
    required this.onDanger,
    required this.ai,
    required this.statusTodo,
    required this.statusInProgress,
    required this.statusDone,
    required this.statusBlocked,
    required this.priorityHigh,
    required this.priorityMedium,
    required this.priorityLow,
    required this.dueOverdue,
    required this.dueToday,
    required this.dueFuture,
  });

  /// The ground the app stands on, and the four surfaces that sit on it in order.
  final Color bg;
  final Color containerLowest;
  final Color containerLow;
  final Color container;
  final Color containerHigh;

  final Color border;
  final Color borderStrong;

  final Color text;
  final Color textMuted;
  final Color textFaint;

  /// The one accent. Amenbo has no second one, so neither does this.
  final Color accent;
  final Color onAccent;
  final Color accentWeak;
  final Color accentText;

  final Color danger;
  final Color onDanger;

  /// Work that is on an AI rather than a person.
  final Color ai;

  final Color statusTodo;
  final Color statusInProgress;
  final Color statusDone;
  final Color statusBlocked;

  final Color priorityHigh;
  final Color priorityMedium;
  final Color priorityLow;

  final Color dueOverdue;
  final Color dueToday;
  final Color dueFuture;
}

const lightPalette = Palette(
  bg: Color(0xfff7f6f3),
  containerLowest: Color(0xffffffff),
  containerLow: Color(0xfffbfaf8),
  container: Color(0xfff7f6f3),
  containerHigh: Color(0xfff1efe9),
  border: Color(0xffe4e1d9),
  borderStrong: Color(0xffd2cec3),
  text: Color(0xff23211c),
  textMuted: Color(0xff6f6a5e),
  textFaint: Color(0xff9b958a),
  accent: Color(0xff0e7c7b),
  onAccent: Color(0xffffffff),
  accentWeak: Color(0xffd6ecec),
  accentText: Color(0xff095a59),
  danger: Color(0xffc0392b),
  onDanger: Color(0xffffffff),
  ai: Color(0xff8a4fd0),
  statusTodo: Color(0xff9b958a),
  statusInProgress: Color(0xff0e7c7b),
  statusDone: Color(0xff2fae66),
  statusBlocked: Color(0xffc6791f),
  priorityHigh: Color(0xffc0392b),
  priorityMedium: Color(0xffc6791f),
  priorityLow: Color(0xff9b958a),
  dueOverdue: Color(0xffc0392b),
  dueToday: Color(0xffc6791f),
  dueFuture: Color(0xff6f6a5e),
);

const darkPalette = Palette(
  bg: Color(0xff1b1a17),
  containerLowest: Color(0xff1b1a17),
  containerLow: Color(0xff1f1e1b),
  container: Color(0xff242320),
  containerHigh: Color(0xff2a2925),
  border: Color(0xff3a3833),
  borderStrong: Color(0xff4c4a43),
  text: Color(0xffece9e1),
  textMuted: Color(0xffa8a399),
  textFaint: Color(0xff7d786e),
  accent: Color(0xff2ba6a4),
  // The dark accent is light enough that white on it is unreadable; the ground it sits on is what
  // reads.
  onAccent: Color(0xff1b1a17),
  accentWeak: Color(0xff11403f),
  accentText: Color(0xff7fd6d4),
  danger: Color(0xffe06155),
  onDanger: Color(0xff1b1a17),
  ai: Color(0xffb083ea),
  statusTodo: Color(0xff7d786e),
  statusInProgress: Color(0xff2ba6a4),
  statusDone: Color(0xff46c97e),
  statusBlocked: Color(0xffe0a04a),
  priorityHigh: Color(0xffe06155),
  priorityMedium: Color(0xffe0a04a),
  priorityLow: Color(0xff7d786e),
  dueOverdue: Color(0xffe06155),
  dueToday: Color(0xffe0a04a),
  dueFuture: Color(0xffa8a399),
);

Palette paletteFor(Brightness brightness) =>
    brightness == Brightness.dark ? darkPalette : lightPalette;
