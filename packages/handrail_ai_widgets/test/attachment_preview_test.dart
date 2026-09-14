import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/attachment_preview.dart';

void main() {
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=');

  for (final exit in ['account', 'background', 'dispose']) {
    testWidgets('shared image zoom reauthorizes and clears on $exit',
        (tester) async {
      var loads = 0;
      Widget subject(String account) => MaterialApp(
              home: Scaffold(
                  body: HandrailAttachmentPreview(
            attachmentId: 'image',
            scope: account,
            label: 'Protected photo',
            mediaType: 'image/png',
            expectedByteSize: png.length,
            enableImageZoom: true,
            presentation: HandrailAttachmentPresentation.inline,
            openKey: const ValueKey('zoom'),
            loadBytes: () async {
              loads++;
              return png;
            },
          )));
      await tester.pumpWidget(subject('first'));
      await tester.pumpAndSettle();
      expect(loads, 1);
      await tester.tap(find.byKey(const ValueKey('zoom')));
      await tester.pumpAndSettle();
      expect(loads, 2, reason: 'Opening reauthorizes through the loader.');
      expect(find.byType(InteractiveViewer), findsOneWidget);
      final enlarged = tester.widget<Image>(find.descendant(
          of: find.byType(InteractiveViewer), matching: find.byType(Image)));
      final borrowed = (enlarged.image as MemoryImage).bytes;
      expect(borrowed, png);
      if (exit == 'account') {
        await tester.pumpWidget(subject('second'));
      } else if (exit == 'background') {
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
      } else {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.pumpAndSettle();
      if (exit != 'background')
        expect(find.byType(InteractiveViewer), findsNothing);
      expect(borrowed.every((b) => b == 0), isTrue);
      expect(png.any((b) => b != 0), isTrue,
          reason: 'The loader owns its source buffer.');
      if (exit == 'background') {
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(loads, 3);
        expect(find.byType(InteractiveViewer), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('a stale image-opening read cannot open on a replacement account',
      (tester) async {
    final held = Completer<Uint8List>();
    var loads = 0;
    Widget subject(String account) => MaterialApp(
            home: Scaffold(
                body: HandrailAttachmentPreview(
          attachmentId: 'image',
          scope: account,
          label: 'Protected photo',
          mediaType: 'image/png',
          enableImageZoom: true,
          presentation: HandrailAttachmentPresentation.inline,
          openKey: const ValueKey('zoom'),
          loadBytes: () {
            loads++;
            return loads == 2 ? held.future : Future.value(png);
          },
        )));
    await tester.pumpWidget(subject('first'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('zoom')));
    await tester.pump();
    await tester.pumpWidget(subject('second'));
    held.complete(png);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a saved PDF control returns after resume without an automatic download',
      (tester) async {
    var loads = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: HandrailAttachmentPreview(
      attachmentId: 'pdf',
      label: 'Saved PDF',
      mediaType: 'application/pdf',
      onOpenBytes: (_) {},
      presentation: HandrailAttachmentPresentation.inline,
      loadBytes: () async {
        loads++;
        return Uint8List.fromList([1]);
      },
    ))));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Saved PDF'), findsOneWidget);
    expect(loads, 0);
    await tester.tap(find.text('Saved PDF'));
    await tester.pumpAndSettle();
    expect(loads, 1);
  });
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
