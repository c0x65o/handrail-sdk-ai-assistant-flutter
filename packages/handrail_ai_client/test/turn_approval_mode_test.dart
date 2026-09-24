import 'package:handrail_ai_client/handrail_ai_client.dart';
import 'package:test/test.dart';
import 'assistant_controller_test.dart' show Fixture, ok;

void main() {
  test(
      'negotiated binding updates the exact running turn with the server revision',
      () async {
    final f = Fixture()..displayHistory = true;
    f.activeTurns['one'] = 'running-turn';
    final changes = <Map>[];
    f.before = (request, body) async {
      if (request.url.path.endsWith('/capabilities'))
        return ok({
          'protocolVersion': 'handrail.application-gateway.v1',
          'synchronization': true,
          'authoritativeCancellation': true,
          'displayHistory': {
            'version': 1,
            'control': true,
            'maximumPageSize': 50,
            'maximumPageBytes': 262144
          },
          'resources': {'turnApprovalMode': true},
        });
      if (request.url.path.endsWith('/approvals/mode')) {
        changes.add(body);
        return ok({
          'mode': body['mode'] ?? 'required',
          'revision': 3,
          'active': true
        });
      }
      return null;
    };
    final controller = f.controller();
    try {
      await controller.initialize();
      await controller.openConversation('one');
      final change =
          controller.uiBinding.capabilitiesFor('one')['changeApprovalMode']
              as Future<void> Function(String);
      await change('automatic');
      expect(changes, hasLength(2));
      expect(changes[0], {'conversationId': 'one', 'turnId': 'running-turn'});
      expect(changes[1]['mode'], 'automatic');
      expect(changes[1]['expectedRevision'], 3);
      expect(changes[1]['mutationId'], isNotEmpty);
      expect(changes[1]['turnId'], 'running-turn');
    } finally {
      await controller.dispose();
    }
  });
}
