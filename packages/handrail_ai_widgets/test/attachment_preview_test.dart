import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/attachment_preview.dart';

void main() {
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=');
  Widget preview(String id, Future<Uint8List> Function() load) => MaterialApp(
      home: Scaffold(
          body: HandrailAttachmentPreview(
              attachmentId: id,
              label: 'Membership photo',
              mediaType: 'image/png',
              loadBytes: load)));
  testWidgets(
      'retries a failed authorized image load without exposing the exception',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(preview('scope/photo', () async {
      if (++calls == 1) throw Exception('private server detail');
      return png;
    }));
    await tester.pumpAndSettle();
    expect(find.textContaining('private server'), findsNothing);
    expect(find.text('Preview unavailable. Try again'), findsOneWidget);
    await tester.tap(find.text('Preview unavailable. Try again'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('ignores an old scope load after switching and after disposal',
      (tester) async {
    final old = Completer<Uint8List>(), current = Completer<Uint8List>();
    await tester.pumpWidget(preview('old/photo', () => old.future));
    await tester.pumpWidget(preview('new/photo', () => current.future));
    old.complete(png);
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    await tester.pumpWidget(const SizedBox());
    current.complete(png);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  Widget file({
    Object scope = 'account/one',
    required Future<Uint8List> Function() load,
    required FutureOr<void> Function(Uint8List) open,
    int maximumBytes = 1024,
    int? expectedByteSize,
    String mediaType = 'application/pdf',
  }) =>
      MaterialApp(
          home: Scaffold(
              body: Center(
                  child: SizedBox(
                      width: 280,
                      child: HandrailAttachmentPreview(
                        attachmentId: 'same-file-id',
                        scope: scope,
                        label: 'Saved file',
                        mediaType: mediaType,
                        loadBytes: load,
                        onOpenBytes: open,
                        maximumBytes: maximumBytes,
                        expectedByteSize: expectedByteSize,
                        presentation: HandrailAttachmentPresentation.inline,
                        openKey: const ValueKey('open'),
                        openLabel: 'Open saved file',
                      )))));

  testWidgets(
      'opening requires activation, prevents duplicates and clears only its own bytes',
      (tester) async {
    final response = Completer<Uint8List>(), opening = Completer<void>();
    final source = Uint8List.fromList([1, 2, 3]);
    Uint8List? borrowed;
    var loads = 0, opens = 0;
    await tester.pumpWidget(file(load: () {
      loads++;
      return response.future;
    }, open: (bytes) {
      opens++;
      borrowed = bytes;
      expect(bytes, [1, 2, 3]);
      return opening.future;
    }));
    expect(loads, 0);
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('open')));
    expect(loads, 1);
    expect(opens, 0);
    response.complete(source);
    await tester.pump();
    expect(opens, 1);
    opening.complete();
    await tester.pumpAndSettle();
    expect(borrowed, [0, 0, 0]);
    expect(source, [1, 2, 3]);
  });

  for (final failure in ['load', 'open']) {
    testWidgets(
        '$failure failure offers inline retry with a fresh authorized read',
        (tester) async {
      var loads = 0, opens = 0;
      final copies = <Uint8List>[];
      await tester.pumpWidget(file(load: () async {
        loads++;
        if (failure == 'load' && loads == 1)
          throw Exception('private server response');
        return Uint8List.fromList([1, 2, 3]);
      }, open: (bytes) {
        copies.add(bytes);
        opens++;
        if (failure == 'open' && opens == 1)
          throw Exception('private platform path');
      }));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      expect(find.textContaining('private'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      final retry = find.text('Attachment unavailable. Try again');
      expect(retry.hitTestable(), findsOneWidget);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(loads, 2);
      expect(opens, failure == 'load' ? 1 : 2);
      expect(
          copies.every((bytes) => bytes.every((value) => value == 0)), isTrue);
      expect(retry, findsNothing);
    });
  }

  for (final change in ['scope', 'dispose']) {
    testWidgets(
        '$change excludes a late saved-file open for the same attachment ID',
        (tester) async {
      final response = Completer<Uint8List>();
      var opens = 0;
      await tester
          .pumpWidget(file(load: () => response.future, open: (_) => opens++));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pump();
      if (change == 'scope') {
        await tester.pumpWidget(file(
            scope: 'account/two',
            load: () async => Uint8List.fromList([4, 5, 6]),
            open: (_) => opens++));
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      response.complete(Uint8List.fromList([1, 2, 3]));
      await tester.pumpAndSettle();
      expect(opens, 0);
      if (change == 'scope') {
        await tester.tap(find.byKey(const ValueKey('open')));
        await tester.pumpAndSettle();
        expect(opens, 1);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final expectedSize in [null, 2]) {
    testWidgets(
        'returned bytes must satisfy declared bounds (expected size $expectedSize)',
        (tester) async {
      var opens = 0;
      await tester.pumpWidget(file(
          load: () async => Uint8List.fromList([1, 2, 3]),
          open: (_) => opens++,
          maximumBytes: expectedSize == null ? 2 : 10,
          expectedByteSize: expectedSize));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      expect(opens, 0);
      expect(find.text('Attachment unavailable. Try again'), findsOneWidget);
    });
  }

  testWidgets(
      'opening a preview reauthorizes bytes and disposal clears its private preview',
      (tester) async {
    var loads = 0, opens = 0;
    await tester.pumpWidget(file(
        mediaType: 'image/png',
        maximumBytes: 1024,
        load: () async {
          loads++;
          return png;
        },
        open: (bytes) {
          opens++;
          expect(bytes, png);
        }));
    await tester.pumpAndSettle();
    expect(loads, 1);
    final cacheBytes =
        (tester.widget<Image>(find.byType(Image)).image as MemoryImage).bytes;
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(opens, 1);
    await tester.pumpWidget(const SizedBox());
    expect(cacheBytes.every((value) => value == 0), isTrue);
    expect(png.take(4), [137, 80, 78, 71]);
  });
}
