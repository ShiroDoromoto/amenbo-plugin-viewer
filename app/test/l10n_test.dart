// The sheets of words, checked as sheets — before any of them is a screen.
//
// Eighteen of the nineteen are written later, and by the time they are all in, nobody can hold in
// their head which key is missing where. So the count is taken here, where it costs nothing: what
// each sheet is short of, said as a number, every time the gate runs.
//
// Three things are failures rather than counts.
//
// * A key on a sheet that the template does not have. It is a typo, or a key the app stopped
//   using — either way nothing reads it, and it will sit there looking like a translation.
// * A message in the template with no description on it. The person writing Polish is not looking
//   at the screen, and a bare `"more": "{count} more"` does not say what it is more of.
// * A sheet the app does not carry, or a language the app carries with no sheet behind it.
// * A count written into a sentence without the arms a number needs. English gets away with two
//   forms and several languages do not, so a message that takes a count as a number has to be a
//   plural message — and the sheet it is copied from is where that is settled, not the sheet of
//   whoever notices in Polish.

import 'dart:convert';
import 'dart:io';

import 'package:amenbo_viewer/l10n/words.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where the sheets live, relative to the package root the tests run from.
const _sheets = 'lib/l10n';

/// The template. Every other sheet is a copy of it with the words replaced.
const _template = 'app_en.arb';

void main() {
  final template = _read(_template);
  final wanted = _messages(template);

  test('the template says what each message is for', () {
    final undescribed = [
      for (final key in wanted)
        if ((template['@$key'] as Map<String, Object?>?)?['description']
            is! String)
          key,
    ];
    expect(
      undescribed,
      isEmpty,
      reason:
          'a message with no description is one that gets guessed at in '
          'eighteen languages',
    );
  });

  test('the sheets and the languages the app carries are the same set', () {
    final onDisk = _localesOnDisk().toSet();
    final carried = Words.supportedLocales
        .map((locale) => locale.toString())
        .toSet();
    expect(
      onDisk,
      carried,
      reason:
          'a sheet nothing reads is dead weight, and a language with no sheet '
          'behind it falls back to English without saying so',
    );
  });

  test('a count in a sentence is written as a plural', () {
    // Only where the number arrives as a number. A count that stopped counting comes through as
    // text (`999+`) and there is nothing for a language to agree with, which is exactly why those
    // are separate messages.
    final flat = [
      for (final key in wanted)
        if (_countsInWords(template, key) &&
            !'${template[key]}'.contains('plural,'))
          key,
    ];
    expect(
      flat,
      isEmpty,
      reason:
          'a sentence with a bare number in it is a sentence written in English '
          'and handed to eighteen languages that do not count that way',
    );
  });

  group('every sheet against the template', () {
    for (final locale in _localesOnDisk()) {
      if (locale == 'en') continue;
      final sheet = _read('app_$locale.arb');
      final has = _messages(sheet).toSet();

      test('$locale carries no key the template does not have', () {
        expect(has.difference(wanted.toSet()), isEmpty);
      });

      test('$locale is counted', () {
        final missing = wanted.where((key) => !has.contains(key)).toList();
        // Not a failure. The dictionaries are written after the keys exist, and a gate that went
        // red the moment a language was started would be a gate nobody could start one under.
        printOnFailure(
          '$locale: ${missing.length} of ${wanted.length} missing',
        );
        stdout.writeln(
          'l10n $locale: ${wanted.length - missing.length}/${wanted.length} '
          'written, ${missing.length} missing'
          '${missing.isEmpty ? '' : ' — ${missing.take(10).join(', ')}'
                    '${missing.length > 10 ? ', …' : ''}'}',
        );
      });
    }
  });
}

Map<String, Object?> _read(String file) =>
    jsonDecode(File('$_sheets/$file').readAsStringSync())
        as Map<String, Object?>;

/// Whether a message takes a number that its words have to agree with.
///
/// The name is the tell, and it is one this sheet keeps: a count is called `count` or `days`, and
/// arrives as an `int`. A version, a sequence number and a size in bytes are numbers too, and
/// nothing in any language changes shape around them.
bool _countsInWords(Map<String, Object?> sheet, String key) {
  final placeholders =
      (sheet['@$key'] as Map<String, Object?>?)?['placeholders']
          as Map<String, Object?>?;
  if (placeholders == null) return false;
  return placeholders.entries.any(
    (entry) =>
        (entry.key == 'count' || entry.key == 'days') &&
        (entry.value as Map<String, Object?>?)?['type'] == 'int',
  );
}

/// The keys that are messages — everything that is not `@@locale` or a `@key` block of metadata.
List<String> _messages(Map<String, Object?> sheet) =>
    sheet.keys.where((key) => !key.startsWith('@')).toList();

Iterable<String> _localesOnDisk() =>
    Directory(_sheets)
        .listSync()
        .map((entry) => entry.uri.pathSegments.last)
        .where((name) => name.startsWith('app_') && name.endsWith('.arb'))
        .map(
          (name) => name.substring('app_'.length, name.length - '.arb'.length),
        )
        .toList()
      ..sort();
