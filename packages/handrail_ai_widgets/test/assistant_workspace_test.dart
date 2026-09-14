import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';
import 'conversation_history_test.dart' as history;
import 'conversation_transcript_test.dart' as transcript;

typedef UploadResult = ({
  Map<String, Object?>? reference,
  String? errorCode,
  bool retryable,
});

class Fixture {
  final events = StreamController<Object?>.broadcast();
  final catalog = history.History(), timeline = transcript.Fixture();
  final state = <String, Object?>{
    'conversationId': 'one',
    'enabled': true,
    'canSend': true,
    'running': false,
    'submitting': false,
    'canStop': false,
    'stopping': false,
  };
  final approvalItems = <Map<String, Object?>>[];
  final requests = <({String id, Map<String, Object?> request})>[];
  final stops = <String>[];
  Completer<UploadResult>? upload;
  Completer<bool>? admission;
  VoidCallback? accepted;
  HandrailWorkspaceDownloader? Function(String?)? downloadFactory;
  late final drafts = HandrailComposerController.forAssistant(binding);
  HandrailWorkspaceBinding get binding => (
    scope: this,
    changes: events.stream,
    initialize: () async {},
    approvals: (
      scope: this,
      changes: events.stream,
      read: () => <String, Object?>{
        'conversationId': state['conversationId'],
        'items': approvalItems,
      },
      review: (_, __) async {},
      decide: (_, __, ___, ____) async {},
      retry: (_) async {},
    ),
    read: () => state,
    history: catalog.binding,
    transcript: timeline.binding,
    capabilitiesFor: (_) => {
      if (downloadFactory != null) 'attachmentDownloadMaximumBytes': 8,
      'attachments': <String, Object?>{
        'acceptedMediaTypes': ['image/png'],
        'maximumFiles': 2,
        'maximumBytesPerFile': 1024,
      },
      'transcriptionMaximumBytes': 1024 * 1024,
      'transcriptionMaximumDurationSeconds': 30,
    },
    uploaderFor: (_) =>
        ({
          required bytes,
          required filename,
          required mediaType,
          required idempotencyKey,
          required cancellation,
        }) async => upload != null
        ? upload!.future
        : (
            reference: <String, Object?>{
              'attachment_id': 'file',
              'content_ref': 'protected:file',
              'byte_size': 3,
              'filename': filename,
              'media_type': mediaType,
            },
            errorCode: null,
            retryable: false,
          ),
    downloaderFor: (id) => downloadFactory?.call(id),
    transcriberFor: (_) =>
        ({
          required bytes,
          required mediaType,
          required duration,
          required idempotencyKey,
          required cancellation,
        }) async => (text: 'dictated words', errorCode: null, retryable: false),
    send:
        ({
          required conversationId,
          required request,
          required onAccepted,
        }) async {
          requests.add((id: conversationId, request: request));
          accepted = onAccepted;
          state.addAll({'submitting': true, 'canSend': false, 'canStop': true});
          publish();
          final success = await (admission?.future ?? Future.value(true));
          if (success) onAccepted();
          state.addAll({'submitting': false, 'running': success});
          publish();
          return success;
        },
    stop: (id) async {
      stops.add(id);
      state.addAll({'stopping': true, 'canStop': false});
      publish();
    },
  );
  void publish() {
    if (!events.isClosed) events.add(null);
  }

  Future<void> dispose() async {
    drafts.dispose();
    await events.close();
    await catalog.changes.close();
    await timeline.changes.close();
  }
}

Widget surface(
  Fixture fixture, {
  double width = 390,
  double scale = 1,
  String Function()? captureContext,
  Map<String, Object?> Function(HandrailWorkspaceSubmission<String>)?
  buildRequest,
  HandrailApprovalMode mode = HandrailApprovalMode.required,
  bool approvals = true,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SizedBox(
      width: width,
      height: 800,
      child: HandrailAssistantWorkspace<String>(
        binding: fixture.binding,
        drafts: fixture.drafts,
        captureContext: captureContext,
        buildRequest: buildRequest,
        initialApprovalMode: mode,
        showApprovalControl: approvals,
        inputKey: const ValueKey('draft'),
        sendKey: const ValueKey('send'),
      ),
    ),
  ),
);

void main() {
  testWidgets('platform editor hooks preserve the shared composer', (
    tester,
  ) async {
    final fixture = Fixture();
    addTearDown(fixture.dispose);
    Widget menu(BuildContext context, EditableTextState editor) =>
        const Text('Native menu');
    void paste(HandrailClipboardImage image) {}
    void voiceBusy(bool busy) {}
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HandrailAssistantWorkspace(
            binding: fixture.binding,
            drafts: fixture.drafts,
            contextMenuBuilder: menu,
            onPasteImage: paste,
            onVoiceBusyChanged: voiceBusy,
            sendKey: const ValueKey('native-send'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final composer = tester.widget<HandrailComposer>(
      find.byType(HandrailComposer),
    );
    expect(composer.contextMenuBuilder, same(menu));
    expect(composer.onPasteImage, same(paste));
    expect(composer.onVoiceBusyChanged, same(voiceBusy));
    expect(composer.input, isNull);
    await tester.enterText(find.byType(TextField).first, 'Native editor send');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('native-send')));
    await tester.pumpAndSettle();
    expect(fixture.requests, hasLength(1));
  });

  testWidgets(
    'pending approval remains visible without messages or tool activity',
    (tester) async {
      final f = Fixture();
      addTearDown(f.dispose);
      f.approvalItems.add({
        'proposal_id': 'p',
        'proposal_version': 1,
        'tool_name': 'Review transfer',
        'status': 'pending',
        'canReview': true,
        'canConfirm': false,
        'canReject': true,
        'binding': 'review',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HandrailAssistantWorkspace(
              binding: f.binding,
              drafts: f.drafts,
              showToolActivity: false,
              transcriptTrailing: const [Text('Business display')],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Review transfer'), findsOneWidget);
      expect(find.text('Review change'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
      expect(find.text('Business display'), findsOneWidget);
    },
  );

  testWidgets(
    'confirmed deletion discards only that conversation’s drafts and files',
    (tester) async {
      final fixture = Fixture();
      addTearDown(fixture.dispose);
      final drafts = fixture.drafts;
      drafts.controller.text = 'Deleted private draft';
      drafts.addAttachments([
        HandrailAttachmentFile(
          fileName: 'delete.png',
          mediaType: 'image/png',
          bytes: [1],
        ),
      ]);
      fixture.state['conversationId'] = 'two';
      fixture.publish();
      await tester.pump();
      drafts.controller.text = 'Other private draft';
      drafts.addAttachments([
        HandrailAttachmentFile(
          fileName: 'keep.png',
          mediaType: 'image/png',
          bytes: [2],
        ),
      ]);
      fixture.state['deletedConversationIds'] = ['one'];
      fixture.publish();
      await tester.pump();
      expect(drafts.controller.text, 'Other private draft');
      expect(drafts.attachments.single.displayName, 'keep.png');
      expect(drafts.draftConversationIds, {'two'});
      fixture.publish();
      await tester.pump();
      expect(drafts.controller.text, 'Other private draft');
      drafts.select('one');
      expect(drafts.controller.text, isEmpty);
      expect(drafts.attachments, isEmpty);
    },
  );
  testWidgets(
    'clearing account drafts while expanded detaches the old editor safely',
    (tester) async {
      final fixture = Fixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HandrailAssistantWorkspace(
              binding: fixture.binding,
              drafts: fixture.drafts,
              allowExpandedEditor: true,
              expandKey: const ValueKey('expand'),
              expandedInputKey: const ValueKey('expanded'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      fixture.drafts.controller.text = 'Private draft';
      await tester.tap(find.byKey(const ValueKey('expand')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('expanded')), findsOneWidget);
      fixture.drafts.clear();
      await tester.pumpAndSettle();
      expect(fixture.drafts.controller.text, isEmpty);
      expect(find.byKey(const ValueKey('expanded')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('hides the routine counter but explains an overlong draft', (
    tester,
  ) async {
    final fixture = Fixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HandrailAssistantWorkspace(
            binding: fixture.binding,
            drafts: fixture.drafts,
            maxPromptLength: 12,
            inputKey: const ValueKey('draft'),
            sendKey: const ValueKey('send'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('characters'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('draft')),
      '1234567890123',
    );
    await tester.pump();
    expect(
      find.text('Message is too long — shorten before sending.'),
      findsOneWidget,
    );
    expect(
      tester.widget<IconButton>(find.byKey(const ValueKey('send'))).onPressed,
      isNull,
    );
    expect(fixture.drafts.controller.text, '1234567890123');
    await tester.enterText(find.byKey(const ValueKey('draft')), 'Short draft');
    await tester.pump();
    expect(find.textContaining('shorten before sending'), findsNothing);
  });

  testWidgets(
    'business slots and editor settings retain default controls and submission gates',
    (tester) async {
      final fixture = Fixture();
      addTearDown(fixture.dispose);
      Widget app(bool enabled) => MaterialApp(
        home: Scaffold(
          body: HandrailAssistantWorkspace(
            binding: fixture.binding,
            drafts: fixture.drafts,
            maxPromptLength: 12,
            maxInputLength: 12,
            composerMaxLines: 1,
            allowExpandedEditor: true,
            expandedEditorTitle: 'Business message',
            inputKey: const ValueKey('draft'),
            expandKey: const ValueKey('expand'),
            expandedInputKey: const ValueKey('expanded'),
            sendKey: const ValueKey('send'),
            submissionEnabled: enabled,
            transcriptTrailing: const [Text('Business review card')],
          ),
        ),
      );
      await tester.pumpWidget(app(false));
      await tester.pumpAndSettle();
      expect(find.text('Business review card'), findsOneWidget);
      expect(find.byType(HandrailConversationHistory), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('draft')),
        '123456789012345',
      );
      await tester.pump();
      expect(fixture.drafts.controller.text, '123456789012');
      expect(
        tester.widget<IconButton>(find.byKey(const ValueKey('send'))).onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('expand')));
      await tester.pumpAndSettle();
      expect(find.text('Business message'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('expanded')),
        'Next draft',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(fixture.drafts.controller.text, 'Next draft');
      expect(fixture.requests, isEmpty);
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pumpAndSettle();
      expect(fixture.requests, hasLength(1));
      expect(fixture.drafts.controller.text, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'minimal workspace supplies history, transcript, voice, files and admission-safe sending',
    (tester) async {
      final fixture = Fixture()..admission = Completer<bool>();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(surface(fixture));
      await tester.pumpAndSettle();
      expect(find.byType(HandrailConversationHistory), findsOneWidget);
      expect(find.byType(HandrailTranscriptMessage), findsNWidgets(2));
      expect(find.byTooltip('Add files and images'), findsOneWidget);
      expect(find.byTooltip('Approval settings'), findsOneWidget);
      expect(find.byTooltip('Dictate a message'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('draft')), 'Original');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
      expect(fixture.requests, hasLength(1));
      expect(fixture.drafts.controller.text, 'Original');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(fixture.requests, hasLength(1));
      await tester.enterText(find.byKey(const ValueKey('draft')), '');
      await tester.enterText(find.byKey(const ValueKey('draft')), 'Original');
      fixture.admission!.complete(true);
      await tester.pumpAndSettle();
      expect(fixture.drafts.controller.text, 'Original');
      final request = fixture.requests.single.request;
      expect(request['protocol_version'], 'handrail.ai-runtime.v1');
      expect(
        (request['metadata'] as Map)['handrail_approval_mode'],
        'required',
      );
      await tester.tap(find.byTooltip('Stop response'));
      await tester.pump();
      expect(fixture.stops, ['one']);
      expect(find.byTooltip('Stopping response…'), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byKey(const ValueKey('send'))).onPressed,
        isNull,
      );
      expect(fixture.drafts.controller.text, 'Original');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'upload preserves origin, context, approval and later conversation drafts',
    (tester) async {
      final fixture = Fixture()..upload = Completer<UploadResult>();
      addTearDown(fixture.dispose);
      var route = 'original-route';
      await tester.pumpWidget(
        surface(
          fixture,
          captureContext: () => route,
          mode: HandrailApprovalMode.automatic,
          approvals: false,
          buildRequest: (submission) => {
            'business_context': submission.context,
            'text': submission.text,
            'files': submission.attachments,
            'metadata': {'business': true},
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Approval settings'), findsNothing);
      fixture.drafts.addAttachments([
        HandrailAttachmentFile(
          fileName: 'photo.png',
          mediaType: 'image/png',
          bytes: [1, 2, 3],
        ),
      ]);
      await tester.enterText(
        find.byKey(const ValueKey('draft')),
        'First draft',
      );
      await tester.pump();
      expect(
        fixture.drafts.controller.text,
        'First draft',
        reason: 'draft before Send',
      );
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
      expect(
        fixture.drafts.controller.text,
        'First draft',
        reason: 'draft during upload',
      );
      expect(fixture.requests, isEmpty);
      route = 'later-route';
      fixture.state['conversationId'] = 'two';
      fixture.publish();
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('draft')),
        'Second draft',
      );
      fixture.upload!.complete((
        reference: <String, Object?>{
          'attachment_id': 'file',
          'content_ref': 'protected:file',
          'byte_size': 3,
          'filename': 'photo.png',
          'media_type': 'image/png',
        },
        errorCode: null,
        retryable: false,
      ));
      await tester.pumpAndSettle();
      expect(fixture.requests, hasLength(1));
      expect(fixture.requests.single.id, 'one');
      expect(
        fixture.requests.single.request['business_context'],
        'original-route',
      );
      expect(fixture.requests.single.request['text'], 'First draft');
      expect(fixture.requests.single.request['metadata'], {
        'business': true,
        ...handrailApprovalMetadata(HandrailApprovalMode.automatic),
      });
      expect(fixture.drafts.controller.text, 'Second draft');
      fixture.drafts.select('one');
      expect(fixture.drafts.controller.text, isEmpty);
      expect(fixture.drafts.attachments, isEmpty);
    },
  );

  testWidgets(
    'replacement account excludes late admission and resets approval controls',
    (tester) async {
      final first = Fixture()..admission = Completer<bool>(),
          second = Fixture();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(
        surface(first, mode: HandrailApprovalMode.automatic),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('draft')),
        'Old account',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
      await tester.pumpWidget(surface(second));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('draft')),
        'New account',
      );
      first.admission!.complete(true);
      await tester.pumpAndSettle();
      expect(second.drafts.controller.text, 'New account');
      expect(second.requests, isEmpty);
      expect(
        tester
            .widget<HandrailComposer>(find.byType(HandrailComposer))
            .approvalMode,
        HandrailApprovalMode.required,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an account change closes approval settings from the previous account',
    (tester) async {
      final first = Fixture(), second = Fixture();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(
        surface(first, mode: HandrailApprovalMode.automatic),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Approval settings'));
      await tester.pumpAndSettle();
      expect(find.text('Auto-approve changes'), findsOneWidget);
      await tester.pumpWidget(surface(second));
      await tester.pumpAndSettle();
      expect(find.text('Auto-approve changes'), findsNothing);
      expect(
        tester
            .widget<HandrailComposer>(find.byType(HandrailComposer))
            .approvalMode,
        HandrailApprovalMode.required,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final (width, scale) in [(320.0, 2.0), (1000.0, 1.0)]) {
    testWidgets(
      'default workspace remains usable at width $width and text scale $scale',
      (tester) async {
        tester.view.reset();
        tester.view.physicalSize = Size(width, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = Fixture();
        addTearDown(fixture.dispose);
        await tester.pumpWidget(surface(fixture, width: width, scale: scale));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<HandrailConversationHistory>(
                find.byType(HandrailConversationHistory),
              )
              .compact,
          width < 720,
        );
        expect(
          find.byKey(const ValueKey('send')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('draft')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
