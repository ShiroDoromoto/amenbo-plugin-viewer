// The English sheet, for the tests that need it.
//
// Two different needs. A widget test has to put the delegates on its own `MaterialApp`, or
// `Words.of` finds nothing under it; a test that calls one of the helpers directly needs the
// sheet in its hand. Both read the same one the app reads, so a screen and its test cannot end
// up checking different text.

import 'package:amenbo_viewer/l10n/words.dart';
import 'package:amenbo_viewer/ui/time.dart';
import 'package:flutter/material.dart';

final words = lookupWords(const Locale('en'));

/// The same sheet, plus the one thing a date needs that a sheet does not carry: whether this
/// phone was set to a 24-hour clock. Written out so a test that says `14:02` is saying it about a
/// phone that was set that way, rather than about whichever way the machine running the test is.
final face = TimeFace(words, hours24: true);

/// A phone left on the 12-hour clock its language prefers.
final face12 = TimeFace(words, hours24: false);
