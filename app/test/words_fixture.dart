// The English sheet, for the tests that need it.
//
// Two different needs. A widget test has to put the delegates on its own `MaterialApp`, or
// `Words.of` finds nothing under it; a test that calls one of the helpers directly needs the
// sheet in its hand. Both read the same one the app reads, so a screen and its test cannot end
// up checking different text.

import 'package:amenbo_viewer/l10n/words.dart';
import 'package:flutter/material.dart';

final words = lookupWords(const Locale('en'));
