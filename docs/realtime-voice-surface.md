# Shared realtime voice and media lifecycle

`HandrailRealtimeVoiceSurface<T>` owns the standard native voice controls: startup
choices and retry, status announcements, mute, playback recovery, Stop, close/Back,
uncertain-end recovery and background stopping. It inherits `Theme.colorScheme`
and text styles. Host content appears alongside these controls; branding and
financial review do not replace them.

This API is included in public Flutter commit
`50fe566d73f68b2beacc2a874dc9a038363b1509`. Mills' main mobile checkout now uses
it through a normal public Git install and matching lock. Full main analysis,
312 selected cases and the release web build pass. Device microphone, actual
provider/audio playback and native builds remain separately unqualified.

```dart
HandrailRealtimeVoiceSurface<SpeakerContext>(
  session: voiceSession,
  conversationId: savedConversationId,
  title: 'Family Assistant voice',
  idleLabel: 'Who will speak?',
  canStart: savedCalls.state.canStartCall,
  beforeStart: (_) async {
    await savedCalls.refresh();
    return accountIsCurrent && savedCalls.state.canStartCall;
  },
  startOptions: const [
    HandrailRealtimeVoiceStartOption(
      label: 'Just me', context: SpeakerContext.authenticatedUser),
    HandrailRealtimeVoiceStartOption(
      label: 'Shared device', context: SpeakerContext.sharedOrUncertain),
  ],
  contentBuilder: (context, state, closing) => BusinessVoiceReview(
    conversationId: savedConversationId,
    canMutate: !closing && trustedPermission,
  ),
);
```

Create `voiceSession` with `HandrailWebRtcVoiceSession<SpeakerContext>(gateway:
yourAuthenticatedGateway)`. `SpeakerContext`, `BusinessVoiceReview` and the
trusted gateway are host adapters; microphone/WebRTC/playback are SDK-owned.
Supply immutable identity/context choices. The session's generic
`start(conversationId: ..., context: ...)` is called only after preflight succeeds
and the current scope, foreground state and `canStart` still permit startup.
Double taps share one startup attempt. Close, Back, account/conversation
replacement and backgrounding invalidate pending preflight work. A failed
startup retries its captured choice. Returning to the foreground never enables
the microphone automatically.

The host owns the session lifetime and must dispose it when the account or route
ends. Mount the surface in a bounded view. When used in a modal, disable outside
barrier dismissal and drag dismissal so explicit close can retain an uncertain
end result. Close pops the containing route only after `stop()` returns with
`ended`; `endUnconfirmed` retains Retry End and a separate explicit leave action.
Leaving that view never changes the saved call's result. Saved-call discovery,
resolving uncertain calls, activity/caption monitoring and business review remain
separate adapters; the surface does not establish that business effects settled.

A `HandrailRealtimeVoiceSession<T>` implementation must disable local capture and
playback before awaiting remote teardown, invalidate pending capture/SDP work,
join concurrent Stop/disposal requests and reuse its call identity for retry.
Only the trusted host's durable end acknowledgement may report `ended` after a
call was dispatched. Peer disconnection and client events alone cannot prove
server finalization, usage accounting or business outcomes. Disposed or stale
media callbacks must disable/release their tracks. Raw transport/provider errors
must not become UI messages.

## Trusted gateway seam

`HandrailWebRtcVoiceSession<T>` implements the lifecycle contract above. Supply a
`HandrailRealtimeVoiceGateway<T>` with two operations:

- `exchangeSdp(request)` sends the offer through the authenticated host endpoint.
  `request` contains the saved conversation, a stable UUID call ID, immutable host
  context, the SDP offer, a cancellation bridge and a 30-second timeout. Send the
  call ID as the idempotency key; reject stale accounts and validate the answer.
  Bridge `request.cancellation.onCancel(...)` to the protected HTTP cancellation
  token and unlink it in `finally`. A cancelled HTTP wait can still have admitted
  a call; it never authorizes a fresh call ID or proves remote termination.
- `endCall(conversationId: ..., callId: ...)` returns true only after validating a
  durable ended receipt for that exact pair. An accepted/ending response returns
  false. Keep authorization expiry handling in the host account adapter.

The SDK now owns capture, echo/noise suppression, peer/data-channel setup, ICE
readiness, SDP application, stable admission identity, session-event correlation,
local mute, playback enable/retry and ordered teardown. It retains the same call
ID after uncertain admission/end and rejects another startup on that session.
The current protocol expects a `session.started` event with a stable session ID;
only a matching `session.closed` event requests teardown. The event itself never
settles usage, business effects or the saved call. The gateway still owns provider
credentials, tools, business authorization and durable receipts.

Map trusted transport failures to `HandrailRealtimeVoiceFailureKind` (unsupported,
alreadyStarted, authentication, busy, offline, timeout or unavailable); the SDK
supplies bounded messages. Arbitrary response bodies are not displayed. The SDK
waits up to 10 seconds for ICE and 15 seconds for the started control event; the
host enforces the request timeout. SDK cancellation invokes all registered cleanup
listeners even if one fails.

Mills' main checkout now uses this implementation. Its 95-line adapter provides
protected SDP/end requests, explicit shared-speaker context and authentication
handling. The host WebRTC engine and native/browser playback implementations have
been removed. Saved-call and activity monitors remain SDK client services; Mills
still supplies their domain presentation, captions and financial review. Further
presentation consolidation and actual live qualification remain separate work.

The widgets package declares `flutter_webrtc` 1.5.2, `dart_webrtc` 1.8.1 and `web`
with a matching normal SDK lock; these match Mills' already installed media
baseline. A normal SDK `flutter pub get --offline` resolved the cached packages.
No packaging/publishing step is needed. Host platform microphone permissions and
native build requirements still apply. Mills now normally adopts public 50fe;
its redundant direct WebRTC dependencies are removed and the matching host lock
resolves the SDK-owned media dependencies. Historical source-alias checks below
are separate from current installed adoption and live qualification.

Qualification: 20 SDK cases cover the 12 surface scenarios plus native playback,
delayed capture/joined disposal, real WebRTC Dart platform-channel startup,
identity/mute/end retry, late SDP cancellation, provider identity/close events and
bounded unknown outcomes. Ten Mills gateway cases cover exact protected headers,
cancellation, failure mapping, auth expiry and exact ended-versus-ending receipts;
the 19-case Mills native/route/review suite also passes. These are owned fixtures,
not device microphone, provider execution, speaker/audio playback or native iOS
compilation evidence.
