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
    'catalogActions': {
      'archive': true,
      'restore': true,
      'permanentDelete': true,
    },
    'rows': [
      {
        'id': 'one',
        'version': 1,
        'title': 'Saved conversation',
        'preview': 'Background answer preview',
        'updatedAt': '2026-09-01T00:00:00Z',
        'lifecycle': 'active',
        'unread': true,
        'running': false,
      },
    ],
  };
  final actions = <String>[];
  Future<void>? deletionResult;
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
        delete: (id, version) async {
          actions.add('delete:$id:$version');
          await deletionResult;
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
        },
      );
}

void main() {
  for (final compact in [false, true]) {
    testWidgets(
      'catalog permission disables creation and saved deletion retry (compact $compact)',
      (tester) async {
        final history = History();
        addTearDown(history.changes.close);
        history.state.addAll({
          'canCreate': false,
          'canManageConversations': false,
          'catalogActions': {
            'archive': false,
            'restore': false,
            'permanentDelete': false,
          },
          'pendingDeletions': [
            {
              'id': 'other',
              'version': 1,
              'busy': false,
              'error':
                  'Your current access does not allow conversation changes.',
            },
          ],
        });
        const createKey = ValueKey('create');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HandrailConversationHistory(
                binding: history.binding,
                compact: compact,
                newButtonKey: createKey,
              ),
            ),
          ),
        );
        bool disabled(Widget button) => button is IconButton
            ? button.onPressed == null
            : (button as ButtonStyleButton).onPressed == null;
        expect(disabled(tester.widget(find.byKey(createKey))), isTrue);
        if (compact) {
          await tester.tap(find.byKey(const ValueKey('handrail-open-history')));
          await tester.pumpAndSettle();
        }
        expect(find.byTooltip('Delete conversation'), findsNothing);
        expect(find.byTooltip('Archive conversation'), findsNothing);
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Retry deletion'),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(
          find.byKey(const ValueKey('handrail-conversation-one')),
        );
        await tester.pumpAndSettle();
        expect(history.actions, ['open:one']);
      },
    );
  }

  testWidgets(
    'voice markers survive narrow layouts and retry without changing text actions',
    (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final history = History();
      addTearDown(history.changes.close);
      final row = (history.state['rows'] as List).first as Map;
      row['voice'] = {
        'activeCalls': 1,
        'unconfirmedCalls': 2,
        'unreadCalls': 3,
        'unresolvedTools': 4,
        'stale': false,
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
              child: HandrailConversationHistory(
                binding: history.binding,
                compact: false,
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('1 voice call active'), findsOneWidget);
      expect(
        find.textContaining('2 voice calls awaiting end confirmation'),
        findsOneWidget,
      );
      expect(
        find.textContaining('3 voice calls with unread results'),
        findsOneWidget,
      );
      expect(
        find.textContaining('4 voice actions awaiting a confirmed outcome'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Archive conversation',
              ),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      history.state['voiceError'] = 'Private transport details';
      (row['voice'] as Map)['stale'] = true;
      history.changed();
      await tester.pumpAndSettle();
      expect(find.textContaining('last reported active'), findsOneWidget);
      expect(
        find.text('Could not refresh voice activity. Retrying…'),
        findsOneWidget,
      );
      expect(find.textContaining('Private transport'), findsNothing);
      await tester.tap(find.text('Retry voice activity'));
      await tester.pumpAndSettle();
      expect(history.actions, ['refresh']);
      history.state['voiceErrorCode'] = 'scopeLimit';
      history.changed();
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Voice history is too large to refresh. '
          'Existing activity is still shown.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Could not refresh voice activity. Retrying…'),
        findsNothing,
      );
      expect(find.textContaining('last reported active'), findsOneWidget);
      expect(
        find.textContaining('3 voice calls with unread results'),
        findsOneWidget,
      );
      expect(find.textContaining('Private transport'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an old deletion failure cannot overwrite a replacement account history',
    (tester) async {
      final first = History(), second = History(), finish = Completer<void>();
      first.deletionResult = finish.future;
      addTearDown(first.changes.close);
      addTearDown(second.changes.close);
      Widget subject(History history) => MaterialApp(
            home: Scaffold(
              body: HandrailConversationHistory(
                binding: history.binding,
                compact: false,
              ),
            ),
          );
      await tester.pumpWidget(subject(first));
      await tester.tap(find.byTooltip('Delete conversation'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Delete conversation'),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(subject(second));
      await tester.pumpAndSettle();
      finish.completeError(StateError('Old account failure'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'The conversation change could not be confirmed. Retry the same action.',
        ),
        findsNothing,
      );
      await tester.tap(find.byTooltip('Delete conversation'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this conversation?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(second.actions, isEmpty);
    },
  );
  for (final compact in [false, true]) {
    testWidgets(
      'deletion reviews an exact version and cancels safely (compact $compact)',
      (tester) async {
        final history = History();
        addTearDown(history.changes.close);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HandrailConversationHistory(
                binding: history.binding,
                compact: compact,
              ),
            ),
          ),
        );
        if (compact) {
          await tester.tap(find.byKey(const ValueKey('handrail-open-history')));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('Delete conversation'));
        await tester.pumpAndSettle();
        expect(find.text('Delete this conversation?'), findsOneWidget);
        expect(find.textContaining('Saved conversation'), findsWidgets);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(history.actions, isEmpty);
        await tester.tap(find.byTooltip('Delete conversation'));
        await tester.pumpAndSettle();
        (history.state['rows'] as List).cast<Map>().single['version'] = 2;
        history.changed();
        await tester.pump();
        await tester.tap(
          find.widgetWithText(FilledButton, 'Delete conversation'),
        );
        await tester.pumpAndSettle();
        expect(history.actions, isEmpty);
        expect(
          find.text('The conversation changed. Review it before deleting.'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Delete conversation'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(FilledButton, 'Delete conversation'),
        );
        await tester.pumpAndSettle();
        expect(history.actions, ['delete:one:2']);
      },
    );

    testWidgets(
      'account replacement closes its deletion confirmation (compact $compact)',
      (tester) async {
        final first = History(), second = History();
        addTearDown(first.changes.close);
        addTearDown(second.changes.close);
        Widget subject(History history) => MaterialApp(
              home: Scaffold(
                body: HandrailConversationHistory(
                  binding: history.binding,
                  compact: compact,
                ),
              ),
            );
        await tester.pumpWidget(subject(first));
        if (compact) {
          await tester.tap(find.byKey(const ValueKey('handrail-open-history')));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('Delete conversation'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(subject(second));
        await tester.pumpAndSettle();
        expect(find.text('Delete this conversation?'), findsNothing);
        expect(first.actions, isEmpty);
        expect(second.actions, isEmpty);
      },
    );
  }
  testWidgets(
    'negotiation disables new deletion but saved retry remains reachable',
    (tester) async {
      final history = History();
      addTearDown(history.changes.close);
      history.state['catalogActions'] = <String, Object?>{};
      history.state['rows'] = <Object?>[];
      history.state['pendingDeletions'] = [
        {'id': 'one', 'version': 1, 'busy': false, 'error': 'Connection lost'},
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HandrailConversationHistory(
              binding: history.binding,
              compact: false,
            ),
          ),
        ),
      );
      expect(find.byTooltip('Delete conversation'), findsNothing);
      await tester.tap(find.text('Retry deletion'));
      await tester.pumpAndSettle();
      expect(history.actions, ['delete:one:1']);
    },
  );

  for (final (width, height, scale) in [
    (320.0, 568.0, 2.0),
    (768.0, 900.0, 1.0),
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
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: HandrailConversationHistory(binding: history.binding),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('handrail-open-history')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Unread (1)'));
        await tester.pumpAndSettle();
        expect(history.state['unreadOnly'], isTrue);
        await tester.scrollUntilVisible(
          find.byTooltip('Archive conversation'),
          100,
          scrollable: find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(
          find.textContaining('Background answer preview'),
          findsOneWidget,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Archive conversation'));
        await tester.pumpAndSettle();
        expect(history.actions, ['archive:one']);
        history.state['error'] = 'History is temporarily unavailable.';
        history.changed();
        await tester.pumpAndSettle();
        expect(find.text('Retry history'), findsOneWidget);
        await tester.ensureVisible(find.text('Retry history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Retry history'));
        await tester.pumpAndSettle();
        expect(history.actions.last, 'refresh');
        await tester.ensureVisible(
          find.byKey(const ValueKey('handrail-conversation-one')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('handrail-conversation-one')),
        );
        await tester.pumpAndSettle();
        expect(history.actions.last, 'open:one');
        expect(find.text('Conversations'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('an account change closes the previous history overlay', (
    tester,
  ) async {
    final first = History(), second = History();
    addTearDown(first.changes.close);
    addTearDown(second.changes.close);
    Widget subject(History value) => MaterialApp(
          home: Scaffold(
              body: HandrailConversationHistory(binding: value.binding)),
        );
    await tester.pumpWidget(subject(first));
    await tester.tap(find.byKey(const ValueKey('handrail-open-history')));
    await tester.pumpAndSettle();
    expect(find.text('Saved conversation'), findsOneWidget);
    await tester.pumpWidget(subject(second));
    await tester.pumpAndSettle();
    expect(find.text('Saved conversation'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
