/// Which of the sheets a phone is read in.
///
/// Nobody is asked. The phone already knows — both iOS and Android let a person set a language per
/// app, and offering the same choice again inside a reader would only create a moment where it is
/// unclear which of the two is winning. So the whole of this is: take what the phone asked for,
/// and find the nearest sheet the app carries.
///
/// Flutter's own matching would do most of it. What it cannot do is the two places where a
/// language is written more than one way, because the answer is not in the tags the phone sends:
///
/// * **Chinese** is two sheets, and which one a phone means is often unsaid. A phone that names a
///   script has said it. A phone that names only a place has said it without knowing: Taiwan, Hong
///   Kong and Macau read the traditional characters, everywhere else the simplified. A phone that
///   names neither gets the simplified, which is the larger half by a long way — so that is the
///   sheet filed under plain `zh`, and the traditional one sits beside it as `zh_Hant`.
/// * **Portuguese** is one sheet, written with the Brazilian vocabulary, filed under plain `pt`. A
///   phone set to Portugal reads it rather than English: some of the words are not the ones it
///   would have chosen, and every one of them is closer than English is.
///
/// Everything that matches nothing falls to English — not to whichever sheet happens to sort
/// first, which is a thing that changes when a language is added.
library;

import 'package:flutter/widgets.dart';

/// Where a phone lands when it asked for something the app does not carry.
const fallbackLanguage = Locale('en');

/// The places that write Chinese with the traditional characters.
const _traditional = {'TW', 'HK', 'MO'};

/// The sheet the phone should be read in, out of [carried].
///
/// [asked] is the phone's list in the order it prefers, which is what somebody who reads two
/// languages set on purpose — so the first ask with a sheet behind it wins, rather than the first
/// sheet that happens to answer any of them.
Locale languageFor(List<Locale>? asked, Iterable<Locale> carried) {
  final sheets = carried.toList();
  for (final want in asked ?? const <Locale>[]) {
    final spelled = _spelledOut(want);
    for (final sheet in sheets) {
      if (sheet == spelled) return sheet;
    }
    // The same language written the same way, said with a place the app keeps no separate sheet
    // for — a German phone in Austria, a Portuguese one in Portugal.
    for (final sheet in sheets) {
      if (sheet.languageCode == spelled.languageCode &&
          sheet.scriptCode == spelled.scriptCode) {
        return sheet;
      }
    }
  }
  return fallbackLanguage;
}

/// The ask, with what it left unsaid filled in and what it said differently said this app's way.
///
/// Only Chinese has anything to settle. For every other language the place a phone names is a
/// place and not a way of writing, so the sheet is the same either way.
Locale _spelledOut(Locale want) {
  if (want.languageCode != 'zh') return want;
  final traditional =
      want.scriptCode == 'Hant' ||
      (want.scriptCode == null && _traditional.contains(want.countryCode));
  return traditional
      ? const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')
      : const Locale('zh');
}
