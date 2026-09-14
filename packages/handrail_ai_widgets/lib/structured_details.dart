import 'package:flutter/material.dart';

/// Format field names only; amounts, dates, IDs and other values stay exact.
String handrailStructuredDetailLabel(String key) {
  final words = key
      .replaceAllMapped(
        RegExp(r'([A-Z]+)([A-Z][a-z])'),
        (match) => '${match[1]} ${match[2]}',
      )
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match[1]} ${match[2]}',
      )
      .replaceAll(RegExp(r'[_-]+'), ' ')
      .trim();
  return words.isEmpty
      ? 'Unnamed field'
      : '${words[0].toUpperCase()}${words.substring(1)}';
}

/// Readable fields and lists for already-authorized JSON-compatible data.
/// Does not infer units, interpret markup, omit fields or summarize a review.
class HandrailStructuredDetails extends StatelessWidget {
  const HandrailStructuredDetails({super.key, required this.value});
  final Object? value;

  @override
  Widget build(BuildContext context) => _DetailValue(value, depth: 0);
}

/// Presentation budget only; expanding preserves all authorized data.
bool handrailShouldCollapseStructuredDetails(Object? value) {
  var rows = 0;
  var characters = 0;
  var lines = 0;
  bool visit(Object? item, int depth) {
    if (++rows > 8 || depth > 4) return true;
    if (item is Map) {
      for (final entry in item.entries) {
        characters += (entry.key as String).length;
        if (characters > 800 || visit(entry.value, depth + 1)) return true;
      }
    } else if (item is List) {
      for (final child in item) {
        if (visit(child, depth + 1)) return true;
      }
    } else {
      final text = item == null ? '' : '$item';
      characters += text.length;
      lines += '\n'.allMatches(text).length;
    }
    return characters > 800 || lines > 8;
  }

  return visit(value, 0);
}

/// Default SDK review presentation. Host-owned expansion tiles can use the
/// plain HandrailStructuredDetails widget without nesting disclosures.
class HandrailStructuredDetailsDisclosure extends StatelessWidget {
  const HandrailStructuredDetailsDisclosure({
    super.key,
    required this.value,
    this.title = 'Details',
  });
  final Object? value;
  final String title;

  @override
  Widget build(BuildContext context) {
    if (!handrailShouldCollapseStructuredDetails(value)) {
      return HandrailStructuredDetails(value: value);
    }
    return ExpansionTile(
      title: Text(title),
      childrenPadding: const EdgeInsets.all(8),
      children: [HandrailStructuredDetails(value: value)],
    );
  }
}

class _DetailValue extends StatelessWidget {
  const _DetailValue(this.value, {required this.depth});
  final Object? value;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final value = this.value;
    final theme = Theme.of(context);
    Widget empty(String text) => Text(
      text,
      style: TextStyle(
        color: theme.colorScheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
    );
    if (value == null) return empty('Not set');
    if (value is List) {
      if (value.isEmpty) return empty('No items');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < value.length; index++)
            Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${index + 1}. ',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  Expanded(child: _DetailValue(value[index], depth: depth + 1)),
                ],
              ),
            ),
        ],
      );
    }
    if (value is Map) {
      if (value.isEmpty) return empty('No fields');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final entry in value.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final label = Text(
                    handrailStructuredDetailLabel(entry.key as String),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  );
                  final nested = entry.value is Map || entry.value is List;
                  final detail = _DetailValue(entry.value, depth: depth + 1);
                  if (!nested && constraints.maxWidth >= 480) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 144, child: label),
                        const SizedBox(width: 16),
                        Expanded(child: detail),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      label,
                      const SizedBox(height: 4),
                      if (nested && depth < 4)
                        Container(
                          padding: const EdgeInsetsDirectional.only(start: 12),
                          decoration: BoxDecoration(
                            border: BorderDirectional(
                              start: BorderSide(
                                color: theme.colorScheme.outlineVariant,
                                width: 2,
                              ),
                            ),
                          ),
                          child: detail,
                        )
                      else
                        detail,
                    ],
                  );
                },
              ),
            ),
        ],
      );
    }
    if (value == '') return empty('Empty text');
    return SelectableText(value is bool ? (value ? 'Yes' : 'No') : '$value');
  }
}
