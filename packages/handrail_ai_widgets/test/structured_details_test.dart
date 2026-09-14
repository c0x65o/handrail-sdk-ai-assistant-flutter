import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/handrail_ai_widgets.dart';

void main() {
  for (final width in [320.0, 800.0]) {
    testWidgets('readable complete details fit ${width}px with large text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final description = List.filled(
        20,
        'Verify switch configuration.',
      ).join(' ');
      final identifier = List.filled(100, 'x').join();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(1.5)),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: HandrailStructuredDetails(
                  value: {
                    'task_title': 'Verify backups',
                    'description': description,
                    'paymentDetails': {
                      'amount': '0012.3400',
                      'currency': 'USD',
                      'approved': false,
                      'retry_count': 0,
                    },
                    'resources': [
                      {'host_name': 'hc-220-private-dc', 'enabled': true},
                      identifier,
                      null,
                    ],
                    'empty_list': [],
                    'empty_object': {},
                    'note': '',
                    'unsafe_text': '<img src=x onerror="alert(1)">',
                  },
                ),
              ),
            ),
          ),
        ),
      );
      for (final label in ['Task title', 'Payment Details', 'Retry count']) {
        expect(find.text(label), findsOneWidget);
      }
      for (final value in [
        '0012.3400',
        'USD',
        '0',
        'No',
        'Yes',
        'Not set',
        'hc-220-private-dc',
        'No items',
        'No fields',
        'Empty text',
        description,
        identifier,
        '<img src=x onerror="alert(1)">',
      ]) {
        expect(find.text(value), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
