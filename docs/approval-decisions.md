# Shared mobile approval decisions

This API is included in public Flutter commit
`50fe566d73f68b2beacc2a874dc9a038363b1509`. All three main mobile consumers now
normally install it with matching locks. The exact-decision receipt correction
is included in public JS `15a3806c2595a3f93a87a768ad13293113f41b58`, installed
by the gateway fixture; all 138 client cases pass, including lost-response
recovery after execution advances. A newer terminal-approval response fix in
JS source remains unpublished: a different late dismissal currently gets 400
on the public server, while the executed effect/proposal remain immutable.
That installed server regression still requires corrected public adoption.

`HandrailAssistantController.approvals` owns canonical proposal review and exact
version decisions. Its `uiBinding` is included in the standard workspace, which
renders `HandrailApprovalDecisionsView` even when messages are empty or tool
activity is hidden. The approval preference control is separate from deciding a
pending proposal. Custom argument formatting does not replace the standard
Review/Approve/Reject or saved-decision controls. Group membership and execution
status are shown; this version makes one reviewed decision at a time, not a batch
financial authorization.

The controller accepts a trusted `loadApprovalReview` host adapter. For opaque
references, the adapter must validate the response's conversation, proposal ID,
version, turn, tool call, tool name and argument reference before constructing
`HandrailApprovalReview.forProposal`. Its `arguments` are display-only, capped at
64 KiB; `complete: false` disables confirmation. Do not substitute a shortened,
truncated or unvalidated financial review. Without an adapter, the SDK can show
the canonical bounded `redacted_json` review but cannot confirm opaque references.
Mills must retain its current validated native-review implementation until this
adapter and its financial formatting/permission checks are adopted and tested.

`canDecideApproval(proposal, confirm)` is an additional current host permission
gate. It does not grant authority that the gateway denies. The controller checks
the current proposal binding/version, lifecycle, expiry and negotiated approval
capability. Selection changes invalidate an in-flight review. A changed binding
invalidates a previously loaded review, including changes at the same version.
The host widget hook `approvalReviewBuilder` formats already validated arguments.
It never supplies execution input or enables a disabled decision.

Before dispatch, a decision is saved through `HandrailApprovalDecisionStore`.
The existing encrypted, account/API-scoped `HandrailKeyValuePendingTurnStore`
implements this journal automatically. Multiple adapter instances in the same
Dart isolate serialize writes by account; multi-isolate/process hosts must supply
an atomic database implementation. The journal stores identity, version, choice,
idempotency key/fingerprint and a canonical binding hash, never argument contents,
prompts or credentials. It has a 100-request/1-million-character read boundary.
The hash correlates an immutable review; server authorization remains required.

Unknown results retain the exact request and expose **Check saved decision**.
Another choice/version is blocked until that request settles. Startup resumes
only previously saved user decisions. Another controller's saved choice wins
over a conflicting new choice, and the view can check that original result.
The target conversation cannot be locally deleted with an unsettled decision;
other conversations remain usable. Sign-out before dispatch prevents that
dispatch; a saved choice is available only when its original account resumes.

The receipt must match the original proposal binding, requested status and exact
next version. The JS gateway now returns the immutable transition result instead
of fetching a newer execution state after confirmation. A version/transition
conflict discards the cached review and requires new review; it never silently
retries the newest version. A verified confirmation means permission was recorded,
not that a business tool succeeded. Canonical history owns execution status.

Validation: 13 focused controller/journal tests and five new widget/workspace
tests cover incomplete/opaque review, domain veto, expiry/capabilities, changed
arguments, account/selection changes, durable-write failure, competing writers,
receipt mismatch and lost replies. A real HTTP Dart-to-JS test drops the reply,
advances synthetic execution state, then restarts and settles the same decision
without provider execution. The new JS regression checks replay after actual
fixture tool execution with exactly one invocation. No live provider, financial
operation, audio, browser or mobile-device acceptance is established by these
fixtures. See the shared goal handoff for logs and remaining consumer work.
