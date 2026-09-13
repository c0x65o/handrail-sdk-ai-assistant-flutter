import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

class History {
  final changes = StreamController<Object?>.broadcast();
  final state = <String, Object?>{
    'selectedTitle': 'A long saved conversation title',
    'view': 'active',
    'unreadOnly': false,
    'unreadCount': 1,
    'busy': false,
    'loading': false,
    'hasMore': false,
    'selectedId': 'one',
    'rows': [
      {
        'id': 'one',
        'title': 'Saved conversation',
        'preview': 'Background answer preview',
        'updatedAt': '2026-09-01T00:00:00Z',
        'lifecycle': 'active',
        'unread': true,
        'running': false
      }
    ]
  };
  final actions = <String>[];
  void changed() => changes.add(null);
  Future<void> create() async {
    actions.add('create');
  }

  HandrailHistoryUiBinding get binding => (
        scope: this,
        changes: changes.stream,
        read: () => state,
        create: create,
        open: (id) async {
          actions.add('open:$id');
        },
        archive: (id) async {
          actions.add('archive:$id');
        },
        restore: (id) async {
          actions.add('restore:$id');
        },
        view: (name) async {
          state['view'] = name;
          changed();
        },
        unread: (value) {
          state['unreadOnly'] = value;
          changed();
        },
        loadMore: () async {
          actions.add('more');
        },
        refresh: () async {
          actions.add('refresh');
          state.remove('error');
          changed();
        }
      );
}

void main() {
  for (final (width, height, scale) in [
    (320.0, 568.0, 2.0),
    (768.0, 900.0, 1.0)
  ]) {
    testWidgets(
        'minimal history picker remains usable at $width with text scale $scale',
        (tester) async {
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final history = History();
      addTearDown(history.changes.close);
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(
                  size: Size(width, height),
                  textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                  body:
                      HandrailConversationHistory(binding: history.binding)))));
      await tester.tap(find.text('A long saved conversation title'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Background answer preview\n9/1/2026'),
          findsNothing); // Locale owns date formatting.
      expect(find.textContaining('Background answer preview'), findsOneWidget);
      await tester.tap(find.text('Unread (1)'));
      await tester.pumpAndSettle();
      expect(history.state['unreadOnly'], isTrue);
      await tester.tap(find.byTooltip('Archive conversation'));
      await tester.pumpAndSettle();
      expect(history.actions, ['archive:one']);
      history.state['error'] = 'History is temporarily unavailable.';
      history.changed();
      await tester.pumpAndSettle();
      expect(find.text('Retry history'), findsOneWidget);
      await tester.tap(find.text('Retry history'));
      await tester.pumpAndSettle();
      expect(history.actions.last, 'refresh');
      await tester.tap(find.byKey(const ValueKey('handrail-conversation-one')));
      await tester.pumpAndSettle();
      expect(history.actions.last, 'open:one');
      expect(find.text('Conversations'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('an account change closes the previous history overlay',
      (tester) async {
    final first = History(), second = History();
    addTearDown(first.changes.close);
    addTearDown(second.changes.close);
    Widget subject(History value) => MaterialApp(
        home: Scaffold(
            body: HandrailConversationHistory(binding: value.binding)));
    await tester.pumpWidget(subject(first));
    await tester.tap(find.text('A long saved conversation title'));
    await tester.pumpAndSettle();
    expect(find.text('Saved conversation'), findsOneWidget);
    await tester.pumpWidget(subject(second));
    await tester.pumpAndSettle();
    expect(find.text('Saved conversation'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
