// The subset a backlog is written in, and the two things this renderer does that a general one
// would not: a diagram stays source, and `##` sections are structure so they can fold.

import 'package:amenbo_viewer/ui/markdown.dart';
import 'package:amenbo_viewer/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('blocks', () {
    test('headings, paragraphs and rules come out as themselves', () {
      final blocks = parseMarkdown('# 表題\n\nひとつめ。\n\n---\n\n## 節\n');
      expect(blocks, hasLength(4));
      expect((blocks[0] as MdHeading).level, 1);
      expect((blocks[1] as MdParagraph).spans.single.text, 'ひとつめ。');
      expect(blocks[2], isA<MdRule>());
      expect((blocks[3] as MdHeading).level, 2);
    });

    test('a list keeps its depth, its numbering and its boxes', () {
      final list = parseMarkdown(
        '- そと\n  - なか\n1. ひとつ\n- [x] すんだ\n- [ ] まだ',
      ).whereType<MdList>().first;

      expect(list.items[0].depth, 0);
      expect(list.items[1].depth, 1);
      expect(list.items[2].marker, '1');
      expect(list.items[3].checked, isTrue);
      expect(list.items[4].checked, isFalse);
      expect(list.items[3].spans.single.text, 'すんだ');
    });

    test('a table needs the rule under it, or it is a line of pipes', () {
      final table =
          parseMarkdown('| a | b |\n|---|---|\n| 1 | 2 |').single as MdTable;
      expect(table.header.map((cell) => cell.single.text), ['a', 'b']);
      expect(table.rows.single.map((cell) => cell.single.text), ['1', '2']);

      expect(parseMarkdown('| a | b |').single, isA<MdParagraph>());
    });

    test('a diagram is a fence like any other, and is not drawn', () {
      final code =
          parseMarkdown('```mermaid\nflowchart LR\n  A --> B\n```').single
              as MdCode;
      expect(code.language, 'mermaid');
      expect(code.text, 'flowchart LR\n  A --> B');
    });

    test('an image is a row about an image, carrying its URL', () {
      final image =
          parseMarkdown('![shot](https://example.test/a.png)').single
              as MdImage;
      expect(image.alt, 'shot');
      expect(image.url, 'https://example.test/a.png');
    });

    test('a quote is set apart from what follows it', () {
      final blocks = parseMarkdown('> ひとこと\n> ふたこと\n\nつづき');
      expect((blocks.first as MdQuote).spans.single.text, 'ひとこと\nふたこと');
      expect(blocks.last, isA<MdParagraph>());
    });
  });

  group('inline', () {
    test('the four marks, and links', () {
      final spans = parseSpans('**ふとく** *ななめ* `code` [そこ](https://a.test)');
      expect(spans.firstWhere((span) => span.bold).text, 'ふとく');
      expect(spans.firstWhere((span) => span.italic).text, 'ななめ');
      expect(spans.firstWhere((span) => span.code).text, 'code');
      expect(spans.firstWhere((span) => span.href != null).text, 'そこ');
    });

    test('an underscore inside a word is a character', () {
      // `snake_case` is written into a backlog far more often than emphasis is.
      final spans = parseSpans('spec_v と format_version');
      expect(spans.every((span) => !span.italic), isTrue);
      expect(spans.map((span) => span.text).join(), 'spec_v と format_version');
    });

    test('an unclosed backtick is a backtick', () {
      expect(parseSpans('a ` b').single.code, isFalse);
    });
  });

  group('sections', () {
    const notes = '''
まえがき。

## やること

ひとつめ。

## なぜ

ふたつめ。
''';

    test('what stands before the first heading is its own, unfolded piece', () {
      final sections = splitSections(parseMarkdown(notes));
      expect(sections.first.heading, isNull);
      expect(sections, hasLength(3));
      expect(sections[1].heading!.spans.single.text, 'やること');
    });

    testWidgets('the first section opens and the rest wait to be asked for', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: viewerTheme(Brightness.light),
          home: const Scaffold(
            body: SingleChildScrollView(child: MarkdownSections(source: notes)),
          ),
        ),
      );

      expect(find.text('まえがき。'), findsOneWidget);
      expect(find.text('ひとつめ。'), findsOneWidget);
      expect(find.text('ふたつめ。'), findsNothing);

      await tester.tap(find.text('なぜ'));
      await tester.pumpAndSettle();
      expect(find.text('ふたつめ。'), findsOneWidget);
    });
  });

  testWidgets('a link is followed only when it is pressed', (tester) async {
    final followed = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: viewerTheme(Brightness.light),
        home: Scaffold(
          body: MarkdownBody(
            blocks: parseMarkdown('[そこ](https://a.test) へ'),
            onLink: followed.add,
          ),
        ),
      ),
    );

    expect(followed, isEmpty);
    // The recogniser sits on the span, so the tap lands on the paragraph that holds it.
    final span = tester.widget<Text>(find.byType(Text)).textSpan!;
    final link = (span as TextSpan).children!.whereType<TextSpan>().firstWhere(
      (child) => child.recognizer != null,
    );
    (link.recognizer! as dynamic).onTap();
    expect(followed, ['https://a.test']);
  });

  testWidgets('nothing overflows at the largest text a phone offers', (
    tester,
  ) async {
    const source =
        '# 表題\n\n本文が一行で収まらないくらいには長く書かれている場合の話。\n\n'
        '| 軸 | 値 | 意味 |\n|---|---|---|\n| a | b | c |\n\n'
        '- 箇条書きも折り返す\n\n```\ncode\n```\n';
    for (final scale in [1.0, 2.0, 3.2]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: viewerTheme(Brightness.light),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: const Scaffold(
              body: SingleChildScrollView(
                child: MarkdownSections(source: source),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: 'nothing broke at $scale');
    }
  });
}
