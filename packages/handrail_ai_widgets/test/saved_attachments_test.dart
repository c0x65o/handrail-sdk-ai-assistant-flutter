import 'dart:async';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';
import 'assistant_workspace_test.dart' as workspace;
import 'conversation_transcript_test.dart' as transcript;

const attachment = <String, Object?>{
  'attachment_id': 'att_file',
  'filename': 'report.pdf',
  'media_type': 'application/pdf',
  'size_bytes': 3
};
typedef DownloadResult = ({
  List<int>? bytes,
  String? errorCode,
  bool retryable
});

class SavePlatform extends FilePickerPlatform {
  int calls = 0;
  String? name, type;
  Uint8List? borrowed;
  Future<Uri?> Function()? save;
  @override
  Future<Uri?> saveFile(
      {required String fileName,
      required Uint8List bytes,
      required String mimeType,
      String? dialogTitle,
      String? initialDirectory,
      Function(FilePickerStatus)? onFileSaving,
      WindowsOptions windowsOptions = const WindowsOptions(),
      LinuxOptions linuxOptions = const LinuxOptions(),
      WebOptions webOptions = const WebOptions()}) async {
    calls++;
    name = fileName;
    type = mimeType;
    borrowed = bytes;
    return save == null ? Uri.parse('file:///saved/report.pdf') : save!();
  }
}

void savedMessage(workspace.Fixture fixture) {
  fixture.timeline.document['messages'] = [
    {
      ...transcript.message('question', 'Read this file', role: 'user'),
      'attachments': [attachment]
    }
  ];
}

Widget surface(workspace.Fixture fixture) => MaterialApp(
    home: Scaffold(
        body: SizedBox(
            width: 390,
            height: 800,
            child: HandrailAssistantWorkspace<void>(
                binding: fixture.binding,
                drafts: fixture.drafts,
                showAttachments: false,
                showVoice: false))));

void main() {
  late FilePickerPlatform original;
  late SavePlatform platform;
  setUp(() {
    original = FilePickerPlatform.instance;
    platform = SavePlatform();
    FilePickerPlatform.instance = platform;
  });
  tearDown(() {
    FilePickerPlatform.instance = original;
  });

  testWidgets(
      'minimal workspace downloads saved files with uploads hidden, using the SDK platform saver and private byte cleanup',
      (tester) async {
    final fixture = workspace.Fixture();
    savedMessage(fixture);
    addTearDown(fixture.dispose);
    var loads = 0;
    fixture.downloadFactory = (id) => (
            {required attachmentId,
            required mediaType,
            byteSize,
            required cancellation}) async {
          expect(id, 'one');
          expect(attachmentId, 'att_file');
          expect(mediaType, 'application/pdf');
          expect(byteSize, 3);
          loads++;
          return (bytes: [1, 2, 3], errorCode: null, retryable: false);
        };
    final saving = Completer<Uri?>();
    platform.save = () => saving.future;
    await tester.pumpWidget(surface(fixture));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Attach files'), findsNothing);
    expect(loads, 0);
    await tester.tap(find.text('Download report.pdf'));
    await tester.pump();
    expect(loads, 1);
    expect(platform.calls, 1);
    expect(platform.name, 'report.pdf');
    expect(platform.type, 'application/pdf');
    expect(platform.borrowed, [1, 2, 3]);
    saving.complete(
        null); // User cancelling the native dialog is not a download failure.
    await tester.pumpAndSettle();
    expect(platform.borrowed, [0, 0, 0]);
    expect(find.text('Attachment unavailable. Try again'), findsNothing);
    expect(fixture.requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'platform save failures stay safe and Retry reauthorizes before saving',
      (tester) async {
    var loads = 0;
    platform.save = () async {
      throw StateError('PRIVATE path');
    };
    Widget build() => MaterialApp(
        home: Scaffold(
            body: HandrailSavedAttachment(
                attachment: attachment,
                scope: 'account:conversation',
                maximumBytes: 8,
                downloader: (
                    {required attachmentId,
                    required mediaType,
                    byteSize,
                    required cancellation}) async {
                  loads++;
                  return (bytes: [1, 2, 3], errorCode: null, retryable: false);
                })));
    await tester.pumpWidget(build());
    await tester.tap(find.text('Download report.pdf'));
    await tester.pumpAndSettle();
    expect(find.text('Attachment unavailable. Try again'), findsOneWidget);
    expect(find.textContaining('PRIVATE'), findsNothing);
    platform.save = null;
    await tester.tap(find.text('Download report.pdf'));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(platform.calls, 2);
    expect(find.text('Attachment unavailable. Try again'), findsNothing);
  });

  for (final change in ['account', 'conversation', 'dispose']) {
    testWidgets(
        'cancels a pending workspace download on $change before any platform save',
        (tester) async {
      final first = workspace.Fixture(), second = workspace.Fixture();
      savedMessage(first);
      savedMessage(second);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final result = Completer<DownloadResult>();
      var cancelled = false;
      first.downloadFactory = (_) => (
              {required attachmentId,
              required mediaType,
              byteSize,
              required cancellation}) {
            unawaited(cancellation.then((_) {
              cancelled = true;
            }));
            return result.future;
          };
      second.downloadFactory = (_) => (
              {required attachmentId,
              required mediaType,
              byteSize,
              required cancellation}) async =>
          (bytes: [3, 2, 1], errorCode: null, retryable: false);
      await tester.pumpWidget(surface(first));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download report.pdf'));
      await tester.pump();
      if (change == 'account')
        await tester.pumpWidget(surface(second));
      else if (change == 'dispose')
        await tester.pumpWidget(const SizedBox());
      else {
        first.state['conversationId'] = 'two';
        first.timeline.conversationId = 'two';
        first.publish();
        first.timeline.publish();
        await tester.pump();
      }
      await tester.pump();
      expect(cancelled, isTrue);
      result.complete((bytes: [1, 2, 3], errorCode: null, retryable: false));
      await tester.pumpAndSettle();
      expect(platform.calls, 0);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'explicit host attachment formatting keeps precedence over the default downloader',
      (tester) async {
    final fixture = workspace.Fixture();
    savedMessage(fixture);
    addTearDown(fixture.dispose);
    var loads = 0;
    fixture.downloadFactory = (_) => (
            {required attachmentId,
            required mediaType,
            byteSize,
            required cancellation}) async {
          loads++;
          return (bytes: [1, 2, 3], errorCode: null, retryable: false);
        };
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: HandrailAssistantWorkspace<void>(
                binding: fixture.binding,
                drafts: fixture.drafts,
                attachmentBuilder: (_, attachment) =>
                    const Text('Host business file'),
                showVoice: false))));
    await tester.pumpAndSettle();
    expect(find.text('Host business file'), findsOneWidget);
    expect(find.text('Download report.pdf'), findsNothing);
    expect(loads, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
