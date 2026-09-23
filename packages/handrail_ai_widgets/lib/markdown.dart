import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

export 'package:flutter_markdown_plus/flutter_markdown_plus.dart'
    show MarkdownStyleSheet;

/// CommonMark/GFM message presentation shared by native and Flutter web hosts.
/// Links only navigate through the host callback; images remain attachments.
class HandrailMarkdown extends StatelessWidget {
  const HandrailMarkdown({
    super.key,
    required this.data,
    this.isUserMessage = false,
    this.selectable = false,
    this.onTapLink,
    this.styleSheet,
  });

  final String data;
  final bool isUserMessage;
  final bool selectable;
  final void Function(String text, String href, String? title)? onTapLink;
  final MarkdownStyleSheet? styleSheet;

  @override
  Widget build(BuildContext context) {
    if (isUserMessage) {
      return selectable
          ? SelectableText(data, style: styleSheet?.p)
          : Text(data, style: styleSheet?.p);
    }
    final theme = MarkdownStyleSheet.fromTheme(
      Theme.of(context),
    ).merge(styleSheet);
    final body = MarkdownBody(
      data: data,
      // Per-paragraph SelectableText creates an editable-text/selection stack
      // for every paragraph and table cell. Markdown reparses growing answers
      // with fresh child keys, repeatedly recreating all those stacks. One
      // selection region keeps formatted text selectable without those editors.
      selectable: false,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      styleSheet: theme.copyWith(
        tableColumnWidth: const IntrinsicColumnWidth(),
        tableScrollbarThumbVisibility: true,
        tableHeadAlign: TextAlign.left,
      ),
      imageBuilder: (uri, title, alt) => const SizedBox.shrink(),
      onTapLink: (text, href, title) {
        if (href != null && _safeLink(href)) onTapLink?.call(text, href, title);
      },
    );
    return selectable ? SelectionArea(child: body) : body;
  }
}

bool _safeLink(String value) {
  final trimmed = value.trim();
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(trimmed) ||
      trimmed.contains(r'\') ||
      trimmed.startsWith('//'))
    return false;
  final uri = Uri.tryParse(trimmed);
  return uri != null &&
      (!uri.hasScheme ||
          const {'http', 'https', 'mailto', 'tel'}.contains(uri.scheme));
}
