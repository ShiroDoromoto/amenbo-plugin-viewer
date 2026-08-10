// The store copy is text nobody compiles, so nothing else would notice a field that grew past
// what the store accepts — and the first place that noticing happens is the upload, on the day of
// the release. These are the counts from store/README.md, kept where the rest of the gate is.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The nineteen the app is written in. A language with no file is as much a hole as an empty
/// field, so the list is here rather than read off the directory.
const _languages = <String>[
  'en',
  'ja',
  'zh-Hans',
  'zh-Hant',
  'ko',
  'es',
  'pt-BR',
  'fr',
  'de',
  'it',
  'ru',
  'hi',
  'id',
  'vi',
  'th',
  'tr',
  'pl',
  'nl',
  'uk',
];

/// What each store will take, in characters. The release note is the App Store's 4000 and Play's
/// 500, which means it is 500.
const _limits = <String, int>{
  'name': 30,
  'subtitle': 30,
  'short': 80,
  'keywords': 100,
  'description': 4000,
  'release_notes': 500,
};

void main() {
  final directory = Directory('store');

  test(
    'every language has a file, and no file is a language nobody speaks',
    () {
      final files =
          directory
              .listSync()
              .whereType<File>()
              .map((f) => f.uri.pathSegments.last)
              .where((name) => name != 'README.md')
              .toList()
            ..sort();
      expect(files, equals([for (final l in _languages) '$l.md']..sort()));
    },
  );

  for (final language in _languages) {
    group(language, () {
      final fields = _read(File('${directory.path}/$language.md'));

      test('says something in every field', () {
        expect(fields.keys.toSet(), equals(_limits.keys.toSet()));
        for (final entry in fields.entries) {
          expect(entry.value, isNotEmpty, reason: '${entry.key} is empty');
        }
      });

      test('fits what the store takes', () {
        for (final entry in fields.entries) {
          final limit = _limits[entry.key]!;
          expect(
            entry.value.length,
            lessThanOrEqualTo(limit),
            reason:
                '${entry.key} is ${entry.value.length} characters, and the store takes $limit',
          );
        }
      });

      test('is the same app as the other eighteen', () {
        expect(fields['name'], equals('amenbo Viewer'));
      });

      test('spends no keyword room on spaces', () {
        // The App Store counts the separator too, and a space after a comma is a character that
        // could have been part of a word.
        expect(fields['keywords'], isNot(contains(', ')));
      });
    });
  }
}

/// The fields of one language's file: `## <field>` opens a section, and what follows it until the
/// next one is the text, exactly as it will be pasted.
Map<String, String> _read(File file) {
  final fields = <String, String>{};
  var field = '';
  final body = StringBuffer();

  void close() {
    if (field.isNotEmpty) fields[field] = body.toString().trim();
    body.clear();
  }

  for (final line in file.readAsLinesSync()) {
    if (line.startsWith('## ')) {
      close();
      field = line.substring(3).trim();
    } else if (field.isNotEmpty) {
      body.writeln(line);
    }
  }
  close();
  return fields;
}
