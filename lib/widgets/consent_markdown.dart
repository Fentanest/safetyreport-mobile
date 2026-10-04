import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/sr_tokens.dart';

/// The small Markdown subset used by the centrally supplied consent document.
/// Unsupported markup is displayed as ordinary text.
class ConsentMarkdown extends StatefulWidget {
  const ConsentMarkdown({super.key, required this.text});

  final String text;

  @override
  State<ConsentMarkdown> createState() => _ConsentMarkdownState();
}

class _ConsentMarkdownState extends State<ConsentMarkdown> {
  static final _heading = RegExp(r'^(#{1,3})\s+(.+)$');
  static final _listItem = RegExp(r'^-\s+(.+)$');
  static final _inline = RegExp(
    r'\*\*([^*\n]+)\*\*|`([^`\n]+)`|\[([^\]\n]+)\]\(([^)\s]+)\)',
  );
  static const _allowedHosts = {
    'safemap.worklazy.net',
    'safeauth.worklazy.net',
    'github.com',
  };

  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  Uri? _allowedUri(String address) {
    final uri = Uri.tryParse(address);
    if (uri == null ||
        uri.scheme != 'https' ||
        !_allowedHosts.contains(uri.host) ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri;
  }

  List<InlineSpan> _spans(String source, BuildContext context) {
    final spans = <InlineSpan>[];
    var start = 0;
    for (final match in _inline.allMatches(source)) {
      if (match.start > start) {
        spans.add(TextSpan(text: source.substring(start, match.start)));
      }
      if (match.group(1) != null) {
        spans.add(
          TextSpan(
            text: match.group(1),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        );
      } else if (match.group(2) != null) {
        spans.add(
          TextSpan(
            text: match.group(2),
            // No monospace family: it has no Hangul glyphs (codes like `경기76자3623` rendered as boxes).
            style: TextStyle(
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest,
            ),
          ),
        );
      } else {
        final label = match.group(3)!;
        final address = match.group(4)!;
        final uri = _allowedUri(address);
        if (uri == null) {
          spans.add(TextSpan(text: '$label ($address)'));
        } else {
          final recognizer = TapGestureRecognizer()
            ..onTap = () =>
                launchUrl(uri, mode: LaunchMode.externalApplication);
          _recognizers.add(recognizer);
          spans.add(
            TextSpan(
              text: label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
              recognizer: recognizer,
            ),
          );
        }
      }
      start = match.end;
    }
    if (start < source.length) {
      spans.add(TextSpan(text: source.substring(start)));
    }
    return spans;
  }

  Widget _text(String source, BuildContext context, {TextStyle? style}) {
    return SelectableText.rich(
      TextSpan(
        style: const TextStyle(fontSize: 12.5, height: 1.5).merge(style),
        children: _spans(source, context),
      ),
    );
  }

  List<String> _cells(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('|') || !trimmed.endsWith('|')) return [];
    return trimmed
        .substring(1, trimmed.length - 1)
        .split('|')
        .map((s) => s.trim())
        .toList();
  }

  bool _isTableStart(List<String> lines, int index) {
    if (index + 1 >= lines.length) return false;
    final headers = _cells(lines[index]);
    final dividers = _cells(lines[index + 1]);
    return headers.isNotEmpty &&
        headers.length == dividers.length &&
        dividers.every((cell) => RegExp(r'^:?-{3,}:?$').hasMatch(cell));
  }

  @override
  Widget build(BuildContext context) {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();

    final lines = widget.text.replaceAll('\r\n', '\n').split('\n');
    final blocks = <Widget>[];
    var i = 0;
    while (i < lines.length) {
      final line = lines[i].trim();
      if (line.isEmpty) {
        i++;
        continue;
      }
      final heading = _heading.firstMatch(line);
      if (heading != null) {
        final level = heading.group(1)!.length;
        blocks.add(
          _text(
            heading.group(2)!,
            context,
            style: TextStyle(
              fontSize: switch (level) {
                1 => 16.0,
                2 => 14.5,
                _ => 13.5,
              },
              fontWeight: FontWeight.bold,
            ),
          ),
        );
        i++;
      } else if (_isTableStart(lines, i)) {
        final headers = _cells(lines[i]);
        i += 2;
        while (i < lines.length) {
          final values = _cells(lines[i]);
          if (values.isEmpty) break;
          blocks.add(
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(SrRadius.md),
              ),
              // Narrow screen: the first cell is the card title; a two-column table needs no repeated column
              // labels, wider tables keep "label: value" for the remaining columns.
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _text(
                    values.isNotEmpty ? values[0] : '',
                    context,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  for (var column = 1; column < headers.length; column++)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: _text(
                        headers.length == 2
                            ? (column < values.length ? values[column] : '')
                            : '${headers[column]}: ${column < values.length ? values[column] : ''}',
                        context,
                      ),
                    ),
                ],
              ),
            ),
          );
          i++;
        }
      } else if (_listItem.hasMatch(line)) {
        while (i < lines.length) {
          final item = _listItem.firstMatch(lines[i].trim());
          if (item == null) break;
          blocks.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('• ', style: TextStyle(fontSize: 12.5, height: 1.5)),
                Expanded(child: _text(item.group(1)!, context)),
              ],
            ),
          );
          i++;
        }
      } else {
        final paragraph = <String>[];
        while (i < lines.length && lines[i].trim().isNotEmpty) {
          final next = lines[i].trim();
          if (paragraph.isNotEmpty &&
              (_heading.hasMatch(next) ||
                  _listItem.hasMatch(next) ||
                  _isTableStart(lines, i))) {
            break;
          }
          paragraph.add(next);
          i++;
        }
        blocks.add(_text(paragraph.join(' '), context));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < blocks.length; index++) ...[
          if (index > 0) const SizedBox(height: 8),
          blocks[index],
        ],
      ],
    );
  }
}
