/// The Markdown a backlog is actually written in, and nothing else.
///
/// amenbo's notes, comments and decision bodies are Markdown, so a detail that printed them raw
/// would show `##` and `|` down the middle of the one screen where the text matters most. What it
/// needs rendering is a small, known set: headings, lists, tables, quotes, code and the four
/// inline marks. That set is written out here rather than taken off the shelf, for two reasons the
/// shelf cannot meet.
///
/// * **A diagram is shown as its source.** Backlog bodies carry ```mermaid fences, and drawing one
///   on a phone costs more than the little it would say at that size. It is a code block here.
/// * **`##` sections fold.** The notes are long and sectioned; opening every one of them at once
///   turns the detail into a scroll nobody reaches the bottom of. Folding needs the sections as
///   structure, not as pixels.
///
/// Anything outside the set is left as the characters it is written with — raw HTML included,
/// which is what amenbo itself does with it. Text that renders as itself is never wrong; text a
/// half-understood parser rearranged is.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

// --------------------------------------------------------------------------- the shapes

/// A run of text and what is on it. The marks combine, so `**a `b`**` is bold and code at once.
class MdSpan {
  const MdSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.href,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool code;

  /// Where a link goes. The app never follows one on its own — see [MarkdownBody.onLink].
  final String? href;
}

sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.spans);

  final int level;
  final List<MdSpan> spans;
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.spans);

  final List<MdSpan> spans;
}

class MdQuote extends MdBlock {
  const MdQuote(this.spans);

  final List<MdSpan> spans;
}

class MdRule extends MdBlock {
  const MdRule();
}

class MdItem {
  const MdItem(this.spans, {this.depth = 0, this.marker, this.checked});

  final List<MdSpan> spans;
  final int depth;

  /// `1.` and the like, kept as written so a numbered list starting at 3 still starts at 3.
  final String? marker;

  /// A GFM task list box, or null where the item is not one.
  final bool? checked;
}

class MdList extends MdBlock {
  const MdList(this.items);

  final List<MdItem> items;
}

class MdTable extends MdBlock {
  const MdTable(this.header, this.rows);

  final List<List<MdSpan>> header;
  final List<List<List<MdSpan>>> rows;
}

class MdCode extends MdBlock {
  const MdCode(this.text, {this.language});

  final String text;

  /// `mermaid` for the diagrams, which are shown as source like any other fence.
  final String? language;
}

/// An image is a row saying an image is there, never the image.
///
/// Fetching one would be the app's only outbound request that is not the intake, and it would be
/// made while somebody is reading on a train.
class MdImage extends MdBlock {
  const MdImage(this.alt, this.url);

  final String alt;
  final String url;
}

/// A `##` section: its heading, and everything down to the next one.
class MdSection {
  const MdSection(this.heading, this.blocks);

  /// Null for whatever stands before the first `##` — the lead, which is never folded away.
  final MdHeading? heading;
  final List<MdBlock> blocks;
}

// --------------------------------------------------------------------------- reading it

List<MdBlock> parseMarkdown(String source) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final blocks = <MdBlock>[];
  var paragraph = <String>[];

  void flushParagraph() {
    if (paragraph.isEmpty) return;
    blocks.add(MdParagraph(parseSpans(paragraph.join('\n'))));
    paragraph = [];
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();

    if (trimmed.isEmpty) {
      flushParagraph();
      continue;
    }

    final fence = _fence.firstMatch(trimmed);
    if (fence != null) {
      flushParagraph();
      final language = fence.group(1)?.trim();
      final body = <String>[];
      i++;
      while (i < lines.length && _fence.firstMatch(lines[i].trim()) == null) {
        body.add(lines[i]);
        i++;
      }
      blocks.add(
        MdCode(
          body.join('\n'),
          language: language == null || language.isEmpty ? null : language,
        ),
      );
      continue;
    }

    final heading = _heading.firstMatch(trimmed);
    if (heading != null) {
      flushParagraph();
      blocks.add(
        MdHeading(heading.group(1)!.length, parseSpans(heading.group(2)!)),
      );
      continue;
    }

    if (_rule.hasMatch(trimmed)) {
      flushParagraph();
      blocks.add(const MdRule());
      continue;
    }

    final image = _image.firstMatch(trimmed);
    if (image != null) {
      flushParagraph();
      blocks.add(MdImage(image.group(1)!, image.group(2)!));
      continue;
    }

    // A table is only a table with the `---` row under it; a line of pipes on its own is a line
    // of pipes.
    if (trimmed.startsWith('|') &&
        i + 1 < lines.length &&
        _tableRule.hasMatch(lines[i + 1].trim())) {
      flushParagraph();
      final header = _cells(trimmed);
      final rows = <List<List<MdSpan>>>[];
      i += 2;
      while (i < lines.length && lines[i].trim().startsWith('|')) {
        rows.add(_cells(lines[i].trim()));
        i++;
      }
      i--;
      blocks.add(MdTable(header, rows));
      continue;
    }

    if (_bullet.hasMatch(line) || _numbered.hasMatch(line)) {
      flushParagraph();
      final items = <MdItem>[];
      while (i < lines.length &&
          (_bullet.hasMatch(lines[i]) ||
              _numbered.hasMatch(lines[i]) ||
              _continuation(lines, i, items.isNotEmpty))) {
        final at = lines[i];
        final bullet = _bullet.firstMatch(at);
        final numbered = bullet == null ? _numbered.firstMatch(at) : null;
        if (bullet == null && numbered == null) {
          // A wrapped line belongs to the item above it.
          final last = items.removeLast();
          items.add(
            MdItem(
              parseSpans('${_plain(last.spans)} ${at.trim()}'),
              depth: last.depth,
              marker: last.marker,
              checked: last.checked,
            ),
          );
          i++;
          continue;
        }
        final match = bullet ?? numbered!;
        // Two spaces of indent is one step in, which is what every editor writes.
        final depth = match.group(1)!.length ~/ 2;
        var text = match.group(bullet != null ? 2 : 3)!;
        bool? checked;
        final box = _checkbox.firstMatch(text);
        if (box != null) {
          checked = box.group(1)!.toLowerCase() == 'x';
          text = box.group(2)!;
        }
        items.add(
          MdItem(
            parseSpans(text),
            depth: depth,
            marker: numbered?.group(2),
            checked: checked,
          ),
        );
        i++;
      }
      i--;
      blocks.add(MdList(items));
      continue;
    }

    if (trimmed.startsWith('> ') || trimmed == '>') {
      flushParagraph();
      final body = <String>[];
      while (i < lines.length &&
          (lines[i].trim().startsWith('> ') || lines[i].trim() == '>')) {
        body.add(lines[i].trim().replaceFirst(RegExp(r'^>\s?'), ''));
        i++;
      }
      i--;
      blocks.add(MdQuote(parseSpans(body.join('\n'))));
      continue;
    }

    paragraph.add(trimmed);
  }
  flushParagraph();
  return blocks;
}

/// Splits the blocks at every `##`, so each section can be folded on its own.
List<MdSection> splitSections(List<MdBlock> blocks) {
  final sections = <MdSection>[];
  var current = <MdBlock>[];
  MdHeading? heading;

  void close() {
    if (heading == null && current.isEmpty) return;
    sections.add(MdSection(heading, current));
    current = [];
  }

  for (final block in blocks) {
    if (block is MdHeading && block.level == 2) {
      close();
      heading = block;
    } else {
      current.add(block);
    }
  }
  close();
  return sections;
}

/// The four inline marks, and links.
List<MdSpan> parseSpans(String text) {
  final spans = <MdSpan>[];
  final buffer = StringBuffer();
  var bold = false;
  var italic = false;

  void flush() {
    if (buffer.isEmpty) return;
    spans.add(MdSpan(buffer.toString(), bold: bold, italic: italic));
    buffer.clear();
  }

  var i = 0;
  while (i < text.length) {
    final rest = text.substring(i);

    if (rest.startsWith('**')) {
      flush();
      bold = !bold;
      i += 2;
      continue;
    }
    // A single `*` or `_` inside a word is a character, not a mark: `snake_case` is written far
    // more often in a backlog than emphasis is.
    if ((rest.startsWith('*') || rest.startsWith('_')) &&
        _emphasisHere(text, i)) {
      flush();
      italic = !italic;
      i += 1;
      continue;
    }
    if (rest.startsWith('`')) {
      final end = text.indexOf('`', i + 1);
      if (end > i) {
        flush();
        spans.add(
          MdSpan(
            text.substring(i + 1, end),
            bold: bold,
            italic: italic,
            code: true,
          ),
        );
        i = end + 1;
        continue;
      }
    }
    final link = _link.matchAsPrefix(text, i);
    if (link != null) {
      flush();
      spans.add(
        MdSpan(link.group(1)!, bold: bold, italic: italic, href: link.group(2)),
      );
      i = link.end;
      continue;
    }

    buffer.write(text[i]);
    i++;
  }
  flush();
  return spans;
}

bool _emphasisHere(String text, int at) {
  final before = at == 0 ? ' ' : text[at - 1];
  final after = at + 1 < text.length ? text[at + 1] : ' ';
  final opening = before.trim().isEmpty && after.trim().isNotEmpty;
  final closing = before.trim().isNotEmpty && !_word.hasMatch(after);
  return opening || closing;
}

List<List<MdSpan>> _cells(String row) => row
    .substring(1, row.endsWith('|') ? row.length - 1 : row.length)
    .split('|')
    .map((cell) => parseSpans(cell.trim()))
    .toList(growable: false);

String _plain(List<MdSpan> spans) => spans.map((span) => span.text).join();

bool _continuation(List<String> lines, int at, bool started) =>
    started && lines[at].startsWith('  ') && lines[at].trim().isNotEmpty;

final _fence = RegExp(r'^```(.*)$');
final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
final _rule = RegExp(r'^(-{3,}|\*{3,}|_{3,})$');
final _image = RegExp(r'^!\[([^\]]*)\]\(([^)]+)\)$');
final _tableRule = RegExp(r'^\|[\s:|-]+\|?$');
final _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
final _numbered = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$');
final _checkbox = RegExp(r'^\[([ xX])\]\s+(.*)$');
final _link = RegExp(r'\[([^\]]*)\]\(([^)]+)\)');
final _word = RegExp(r'[A-Za-z0-9_]');

// --------------------------------------------------------------------------- drawing it

/// A body, drawn.
class MarkdownBody extends StatelessWidget {
  const MarkdownBody({super.key, required this.blocks, this.onLink});

  final List<MdBlock> blocks;

  /// Handed a link the person pressed. Null leaves links as plain text — nothing is followed on
  /// the app's own initiative, ever.
  final void Function(String url)? onLink;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final block in blocks)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _block(context, block),
        ),
    ],
  );

  Widget _block(BuildContext context, MdBlock block) {
    final theme = Theme.of(context);
    switch (block) {
      case MdHeading(:final level, :final spans):
        return Text.rich(
          _spans(context, spans),
          style: switch (level) {
            1 => theme.textTheme.titleLarge,
            2 => theme.textTheme.titleMedium,
            _ => theme.textTheme.titleSmall,
          },
        );
      case MdParagraph(:final spans):
        return Text.rich(_spans(context, spans));
      case MdQuote(:final spans):
        return Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 3,
              ),
            ),
          ),
          child: Text.rich(
            _spans(context, spans),
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        );
      case MdRule():
        return const Divider();
      case MdList(:final items):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final item in items) _item(context, item)],
        );
      case MdTable(:final header, :final rows):
        return _table(context, header, rows);
      case MdCode(:final text):
        return _code(context, text);
      case MdImage(:final alt, :final url):
        return _imageRow(context, alt, url);
    }
  }

  Widget _item(BuildContext context, MdItem item) {
    final theme = Theme.of(context);
    final box = item.checked;
    return Padding(
      padding: EdgeInsets.only(left: 12.0 * item.depth, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (box != null)
            Padding(
              padding: const EdgeInsets.only(right: 6, top: 2),
              child: Icon(
                box ? Icons.check_box_outlined : Icons.check_box_outline_blank,
                size: (theme.textTheme.bodyMedium?.fontSize ?? 14) * 1.1,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(item.marker == null ? '•' : '${item.marker}.'),
            ),
          Expanded(child: Text.rich(_spans(context, item.spans))),
        ],
      ),
    );
  }

  /// A table scrolls sideways rather than squeezing its columns.
  ///
  /// A backlog table is written on a PC, where the width is there. Wrapping every cell to fit a
  /// phone turns three columns into a grey block; letting it run off the side keeps each row
  /// readable and costs a sideways drag.
  Widget _table(
    BuildContext context,
    List<List<MdSpan>> header,
    List<List<List<MdSpan>>> rows,
  ) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 36,
        dataRowMinHeight: 32,
        dataRowMaxHeight: double.infinity,
        columns: [
          for (final cell in header)
            DataColumn(
              label: Text.rich(
                _spans(context, cell),
                style: theme.textTheme.labelLarge,
              ),
            ),
        ],
        rows: [
          for (final row in rows)
            DataRow(
              cells: [
                for (var i = 0; i < header.length; i++)
                  DataCell(
                    i < row.length
                        ? Text.rich(_spans(context, row[i]))
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _code(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        ),
      ),
    );
  }

  Widget _imageRow(BuildContext context, String alt, String url) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(Icons.image_outlined, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              alt.isEmpty ? url : '$alt — $url',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  TextSpan _spans(BuildContext context, List<MdSpan> spans) {
    final theme = Theme.of(context);
    return TextSpan(
      style: theme.textTheme.bodyMedium,
      children: [
        for (final span in spans)
          TextSpan(
            text: span.text,
            style: TextStyle(
              fontWeight: span.bold ? FontWeight.w700 : null,
              fontStyle: span.italic ? FontStyle.italic : null,
              fontFamily: span.code ? 'monospace' : null,
              backgroundColor: span.code
                  ? theme.colorScheme.surfaceContainerHighest
                  : null,
              color: span.href != null ? theme.colorScheme.primary : null,
              decoration: span.href != null ? TextDecoration.underline : null,
            ),
            recognizer: span.href == null || onLink == null
                ? null
                : (TapGestureRecognizer()..onTap = () => onLink!(span.href!)),
          ),
      ],
    );
  }
}

/// A body split into `##` sections, with all but the first folded.
///
/// The notes on a backlog task run to several sections and the reader wants one of them. Opening
/// every one turns the detail into a scroll they have to hunt down; opening none makes them press
/// before they can read a word. The first is the one that says what the task is.
class MarkdownSections extends StatefulWidget {
  const MarkdownSections({super.key, required this.source, this.onLink});

  final String source;
  final void Function(String url)? onLink;

  @override
  State<MarkdownSections> createState() => _MarkdownSectionsState();
}

class _MarkdownSectionsState extends State<MarkdownSections> {
  late List<MdSection> _sections;
  final _open = <int>{};

  @override
  void initState() {
    super.initState();
    _split();
  }

  @override
  void didUpdateWidget(MarkdownSections old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) {
      _open.clear();
      _split();
    }
  }

  void _split() {
    _sections = splitSections(parseMarkdown(widget.source));
    final first = _sections.indexWhere((section) => section.heading != null);
    if (first >= 0) _open.add(first);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _sections.length; i++) ...[
          if (_sections[i].heading case final heading?)
            InkWell(
              onTap: () => setState(
                () => _open.contains(i) ? _open.remove(i) : _open.add(i),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            for (final span in heading.spans)
                              TextSpan(text: span.text),
                          ],
                        ),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    Icon(
                      _open.contains(i) ? Icons.expand_less : Icons.expand_more,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          if (_sections[i].heading == null || _open.contains(i))
            MarkdownBody(blocks: _sections[i].blocks, onLink: widget.onLink),
        ],
      ],
    );
  }
}
