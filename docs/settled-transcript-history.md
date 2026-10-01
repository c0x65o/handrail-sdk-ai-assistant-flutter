# Settled action history and transcript following

`HandrailApprovalDecisionsView` now separates active decisions from settled
history by canonical status. Executed, finished/completed, rejected and expired
items begin inside the collapsed **Action history** expansion. The original
cards, title/review formatters and canonical records remain available there.
An explicitly selected `proposalId` still renders its complete inbox card.

Pending decisions, approved-but-not-executed actions, executing actions,
failures, unknown states and pending/busy/review/error evidence remain visible.
This is presentation only: approval gates and execution contracts are unchanged.
The history expansion resets on account/conversation change and starts closed
after remount/reload. No persisted local hidden-ID list is introduced.

Both transcript implementations preserve scroll intent across streaming, layout
and keyboard changes. Scroll geometry changes and SDK anchor/tail corrections
cannot reclassify the reader as following or away. A deliberate upward movement
pauses following; scrolling down to the actual tail (two-pixel tolerance) or
choosing Jump to latest resumes it. Crossing the old near-bottom thresholds does
not blink the control. Paged transcript viewport-only metric changes now also
schedule the existing anchor/follow correction. Read acknowledgements continue
to use the existing visibility and revision guards.

See `settled-transcript-qualification.json` for regression reproduction, commands,
outputs and verification boundaries. The corresponding JS repository contains
`docs/settled-transcript-handoff.md` with both repositories' consumer installation
steps and remaining Mills native acceptance work. This is an SDK preparation;
Handrail's post-agent step still owns versions/commits/pushes, and Avery owns Mills
adoption and its existing delivery workflow. No theme or business data changes
are part of this patch.
