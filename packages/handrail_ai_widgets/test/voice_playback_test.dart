import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handrail_ai_widgets/src/voice_playback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native output failure stays retryable without creating a call',
    () async {
      const channel = MethodChannel('FlutterWebRTC.Method');
      final methods = <String>[];
      var unavailable = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize') return null;
        methods.add(call.method);
        if (unavailable) {
          throw PlatformException(code: 'audio_route_unavailable');
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final playback = createVoicePlayback();
      expect(await playback.play(), isFalse);
      unavailable = false;
      expect(await playback.play(), isTrue);
      playback.stop();
      expect(methods, [
        'enableSpeakerphoneButPreferBluetooth',
        'enableSpeakerphoneButPreferBluetooth',
      ]);
    },
  );
}
