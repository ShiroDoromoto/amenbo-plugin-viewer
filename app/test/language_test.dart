// Which sheet a phone is read in — checked against the languages the app actually carries, so a
// sheet added or dropped is answered here rather than in a list that drifts.

import 'package:amenbo_viewer/l10n/language.dart';
import 'package:amenbo_viewer/l10n/words.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the phone asked for, answered out of what the app carries.
Locale read(List<Locale>? asked) => languageFor(asked, Words.supportedLocales);

const _hant = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');

void main() {
  test('a phone reads the language it is set to', () {
    expect(read([const Locale('ja')]), const Locale('ja'));
    // The place it is in is not a language: German is German in Austria.
    expect(read([const Locale('de', 'AT')]), const Locale('de'));
  });

  test('the first ask with a sheet behind it wins', () {
    // Somebody who reads two languages put them in that order on purpose. The app carries the
    // second one, so the second one is what they get — not the first sheet that answers anything.
    expect(
      read([const Locale('ar'), const Locale('fr'), const Locale('es')]),
      const Locale('fr'),
    );
  });

  test('a language the app does not carry falls to English', () {
    expect(read([const Locale('ar')]), const Locale('en'));
    // And so does a phone that asked for nothing at all.
    expect(read(null), const Locale('en'));
    expect(read(const []), const Locale('en'));
  });

  group('Chinese is two sheets, and the phone rarely says which', () {
    test('a script settles it outright', () {
      expect(read([_hant]), _hant);
      expect(
        read([
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
        ]),
        const Locale('zh'),
      );
    });

    test('a place settles it too, without meaning to', () {
      for (final where in ['TW', 'HK', 'MO']) {
        expect(read([Locale('zh', where)]), _hant, reason: where);
      }
      expect(read([const Locale('zh', 'CN')]), const Locale('zh'));
      expect(read([const Locale('zh', 'SG')]), const Locale('zh'));
    });

    test('a phone that says neither gets the simplified sheet', () {
      expect(read([const Locale('zh')]), const Locale('zh'));
    });

    test('a script and a place together are read from the script', () {
      // Traditional characters set on a phone in mainland China is a person saying which they
      // read, and the place says nothing over the top of it.
      expect(
        read([
          const Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hant',
            countryCode: 'CN',
          ),
        ]),
        _hant,
      );
    });
  });

  test('Portuguese is one sheet, and Portugal reads it', () {
    // The vocabulary is Brazilian. Some of the words are not the ones a phone in Portugal would
    // have picked, and every one of them is closer than English.
    expect(read([const Locale('pt', 'PT')]), const Locale('pt'));
    expect(read([const Locale('pt', 'BR')]), const Locale('pt'));
  });

  test('every sheet the app carries can be reached', () {
    // A sheet nothing resolves to is a sheet somebody translates for nobody.
    for (final sheet in Words.supportedLocales) {
      expect(read([sheet]), sheet, reason: '$sheet');
    }
  });
}
