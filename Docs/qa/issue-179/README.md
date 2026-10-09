# #179 — legacy renderer oracle and event-family journal shadows

This note records **stage 1** (legacy renderer extraction), **stage 2** (published-act
shadow), and **stage 3** (hearing-family shadow, including a narrow reschedule projection);
none passes the full downstream shadow gate or authorizes cutover.
`AppRouter.reload` prepares ordered value-only inputs and calls
`LegacyFeedProjection.project`; the focused renderer tests call that same pure function
and assert the current legacy output. Stage 2 compares only the published-act family.
Neither stage changes user-visible feed, unread, notification, or badge behavior.

## Checked contracts

| Existing behavior | Exercised implementation | Result represented by the focused tests |
| --- | --- | --- |
| Issue #99: a dated clerical movement with a time is not a hearing; legacy feed identity migration drops the old kind segment. | `CaseLifecycleResolver`, `MovementDerivation.futureHearings`, `AppRouter.feedID`, `AppRouter.feedIDDroppingKind`. | The clerical row is absent from future hearings, a real historical hearing remains a hearing, and the old ID normalizes to the current legacy ID. |
| The pure recent-entry helper includes non-future entries inside its requested window. | `CaseEventDeriver`, `AppRouter.recentFeedEntries`. | A future hearing exists in the semantic derivation while a six-day entry is included and a future or seven-day-boundary entry is excluded for `days: 7`. |
| The first v6 semantic baseline is quiet; partial coverage does not advance it; a complete confirmed change is recorded once. | `CaseEventBaselineTransition.refresh`, `CaseEventDeriver`, `CaseEventJournal.append`. | A synthetic past session seeds without an event, an incomplete judge change leaves the baseline unchanged, and the complete change creates one `judgeChanged` event; repeating the same complete snapshot creates none. |
| Journal event identity is semantic and independent of the legacy feed ID and presentation evidence. | `CaseEventDeriver`, `AppRouter.feedID`. | Independently deriving the same published act with reformatted title/court labels yields the same journal ID but different evidence; the act ID remains distinct from the legacy feed ID. Transitioning an already-known act to the reformatted observation emits no new act event. |
| Treasury RSS identity remains GUID-based and read filtering still follows the existing unread flag. | `AppRouter.enforcementFeedID`, `AppRouter.filteredFeedEntries`. | Toggling unread state does not change the GUID identity; the existing unread filter includes the unread item and excludes the read item. |
| Existing material-feed read and known IDs migrate to the source-specific row once, without becoming a wildcard for a later unrelated card. | `AppRouter.materialFeedTransitionsToMigrate`, `AppRouter.migratedFeedIDs`. | The alias is consumed, then retained legacy IDs in both sets do not transfer to a later second card. A separate known-only case migrates the known ID while keeping read IDs empty. |
| Adding a published instance number to an already-known native card is not a new semantic case event. | `CaseEventDeriver`. | A synthetic observation's number-only enrichment under the same source-card ID emits no journal event. |
| The current renderer covers Treasury, sessions, and acts, including Treasury without a snapshot. | `LegacyFeedProjection.project`, the same function called by `AppRouter.reload`. | Exact `FeedEntry` identity, display, unread, and source-navigation fields are checked; the inclusive `DateUtil.daysBetween` boundary is exercised at -1, 0, 45, and 46 days for all three sources. Material rows retain source-scoped IDs and deduplicate exact duplicates; conflicting numbers, previous-registration details, ambiguous act ownership, fallback review number, and returned read/known migration state are checked, including repeat projection using that returned state. |

## Stage 2: published-act journal shadow

This layer projects only persisted `.judicialActPublished` events. The shadow
entry is constructed from the event and exact current act metadata; a current
snapshot act without a persisted event never creates a shadow entry. Event IDs
are preserved. Admission requires the event occurrence key to equal a current
`CaseAct.id`, with evidence source card, raw date, and level, and one current
act observation and owner agreeing on date, level, and source. Date conflicts
are reported before the process-date filter. The feed window is inclusive
0–45 days by the proven act date; a valid event outside it is quietly excluded,
regardless of `observedAt`.

The comparator is the actual `LegacyFeedProjection.project` output. Aliases
require an exact `(recordKey, actID)` pair and a raw legacy ID independently
recomputed with the existing feed-ID and material-ID helpers. Every raw legacy
act row participates in duplicate-ID detection before any read/known IDs are
formed into sets. ID mismatches and ambiguous IDs fail closed. Only an exact
alias transfers read and known marks, into separate shadow sets; known-only
does not mark an entry read. The existing case unread flag still controls the
shadow entry. For presentation, the current act may update title and review
number while the event ID stays stable. Legacy source navigation is preserved:
only material acts expose a source card, and a source instance appears only for
an exact linked owner or material mapping.

Unmapped diagnostics retain quiet in-window legacy act rows with no published
event and identify missing evidence/current act/owner, duplicate identities,
date/level/source conflicts, changed mirrors, legacy-ID mismatch, and ambiguous
aliases. Other journal event kinds are outside this layer and are not reported
as act errors. The tests derive real persisted events and compare against the
real legacy projection. One adversarial comparator case changes a legacy row's
time and text and asserts those exact field mismatches.

This is an act-family diagnostic only. The full shadow gate remains open; it
does not establish corpus-wide parity or authorize cutover.

## Stage 3: hearing journal shadow

This layer projects persisted `hearingScheduled`, `hearingPostponed`, and
`hearingRescheduled` events. It does not create a shadow entry from a current
snapshot by itself.
An event is projected only when its occurrence key matches exactly one current
stored hearing and its source card, level, date, time, event text, result, own
instance observation, and own movement instance all agree. The existing
`CaseEventDeriver.hearingKey` helper supplies the occurrence key; the projector
checks level and result separately because they are intentionally absent from
that key.

The legacy comparison runs on the complete `LegacyFeedProjection` output before
hearing rows are selected. Exact aliases use the existing feed-ID and
material-ID helpers, and every raw feed ID is counted first because its
identity omits the row kind. Read and known marks migrate separately, while
the case unread flag and material/previous-registration navigation fields
remain part of the projected row. The history boundary is the process date's
inclusive 0–45-day window; `observedAt` does not change it. Rows and events
outside that window are quiet unless an event occurrence key points to a
current stored hearing inside the window. A scheduled or postponed event stays
in scope and an out-of-window evidence date is reported as a date conflict.
Competing persisted events for that occurrence are counted before date
filtering, so a stale event cannot let another event claim the legacy alias or
read/known marks. A
rescheduled event remains relevant when its affected occurrence keys point to
a current in-window hearing, even if its stored date fields are outside the
window; it is validated and reported as unproven instead of being quietly
skipped.

Multiple persisted events matching one current occurrence are reported as
unmapped rather than choosing one. For a reschedule, the synthetic checks
require both exact current hearing occurrences, one source card and level,
matching prior/new date and time evidence, the prior result, and two distinct
legacy aliases from the full `LegacyFeedProjection` output. The shadow creates
one row at the new hearing date; the former date stays in event evidence. The
tests include day 0, 6, 7, and 44, and exercise day 45 with an absent former
legacy alias, which correctly prevents partial migration. Both
aliases must be unique across the complete raw feed before either can be
accepted. A missing or out-of-window alias, a cross-family ID collision, a
chained reschedule that gives one legacy row two event owners, or a target
session result absent from the reschedule evidence fails closed. Both legacy
rows remain in the actual legacy projection. The shadow emits one row at the
new date and retains the former row's alias only for identity and mark-migration
checks; presentation is compared against the new/current row. The existing feed
date and recent-entry helpers exercise the new date's
0–45-day scope and 7-day inclusion behavior.

Read state moves to the one reschedule event only if both former legacy IDs are
read. The transfer of a known/notified mark remains unresolved pending the
user's choice and is intentionally not asserted for reschedules. Quiet legacy
hearing rows without a journal event remain unmapped. Tests use synthetic
records and events derived by `CaseEventBaselineTransition` /
`CaseEventDeriver`, then compare against the actual `LegacyFeedProjection`
output. Material source identity/navigation and Codable replay are checked;
repeating the same refresh does not append a second event.

The legacy case-level `unreadByCase` flag remains an independent suppression
rule: when it is false, legacy and shadow entries are not unread regardless of
per-item read IDs. The two-alias read-transfer matrix keeps this flag true and
tests explicit read IDs; an existing projection check covers the case-level
rule.

This layer does not change feed, notification, badge, persistence, or UI callers.

The focused tests use isolated fixed synthetic data. They do not instantiate `AppRouter`,
read SwiftData or persisted preferences, make network calls, launch the app, or deliver
system notifications. The projection remains diagnostic-only; production feed, known
mark, notification, badge, and UI callers are not switched.

## Not established here

- The stage 1 pure oracle is the extracted current renderer, not an independent
  reconstruction. Its field assertions alone do not prove parity between legacy rows
  and journal events; stage 2 adds comparison only for published acts.
- Full history parity and the downstream shadow gate remain open. Generic movement,
  Treasury-to-journal semantics, out-of-window history, evidence-backed cancellation,
  production source provenance, notification/deep-link/badge behavior, and user
  preference behavior still need their own confirmed inputs and comparison.
- Future hearings and newly derived judge changes remain shadow-only. This checkpoint
  does not authorize user-facing notifications or a feed cutover.

These gaps require a later downstream comparison and explicit acceptance before changing
the feed, notifications, or badges. The extraction leaves `buildFeed` and its day-head
clock in `AppRouter` and leaves `reconcileFeed` in place.

## Focused verification

Stage 1 result on **9 October 2026**: **10 tests, 0 failures** (five existing
`CaseEventFeedCompatibilityTests` plus five `LegacyFeedProjectionTests`). The isolated
scratch tree was `/private/tmp/sudrf-179-renderer.xF6NCZ`, with module cache at
`/private/tmp/sudrf-179-renderer.xF6NCZ/module-cache` and Clang module cache at
`/private/tmp/sudrf-179-renderer.xF6NCZ/clang-cache`. This was a SwiftPM focused test
run, not a full-suite, CI, or application-build gate.

```sh
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sudrf-179-renderer.xF6NCZ/module-cache \
CLANG_MODULE_CACHE_PATH=/private/tmp/sudrf-179-renderer.xF6NCZ/clang-cache \
swift test --disable-sandbox --skip-update \
  --scratch-path /private/tmp/sudrf-179-renderer.xF6NCZ/build \
  --filter '(CaseEventFeedCompatibilityTests|LegacyFeedProjectionTests)'
```

Focused log `/private/tmp/sudrf-179-renderer.xF6NCZ/focused-tests.log` SHA-256:
`e9d3f95b4ba1fd23ddfa88078389ae7d7fcb08c4d908710563d739f90ddf9267`.
The orchestrator independently repeated the same ten tests successfully; its log
`/private/tmp/sudrf-179-root-renderer-focused.log` has SHA-256
`aeae800198402eff99608e67b1129248e45aed66690fe513b16174002fc5a8ad`.
Independent review found and then cleared a retention regression: the inputs retain
only renderer metadata, not complete movements, act bodies, or instance sessions.
Renderer test source SHA-256: `aa35fb7e6b81663f7bcdabfe3a1c4bc87ac04daf24c183c581cfd62ccc2290cb`.
The renderer implementation SHA-256 is
`ca58fa7fdf126a863857152261202e1b1ab70268da73281abf0b327310f8c6cc`.

This does not establish the deferred downstream shadow gate.

Stage 2 focused result on **9 October 2026**: **20 tests, 0 failures** (five
`CaseEventFeedCompatibilityTests`, five `LegacyFeedProjectionTests`, and ten
`ActJournalFeedProjectionTests`). SwiftPM used the isolated scratch tree
`/private/tmp/sudrf-179-act-shadow`, with module cache at
`/private/tmp/sudrf-179-act-shadow/module-cache` and Clang module cache at
`/private/tmp/sudrf-179-act-shadow/clang-cache`.

```sh
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sudrf-179-act-shadow/module-cache \
CLANG_MODULE_CACHE_PATH=/private/tmp/sudrf-179-act-shadow/clang-cache \
swift test --disable-sandbox --skip-update \
  --scratch-path /private/tmp/sudrf-179-act-shadow/build \
  --filter 'CaseEventFeedCompatibilityTests|LegacyFeedProjectionTests|ActJournalFeedProjectionTests'
```

Focused log `/private/tmp/sudrf-179-act-shadow/combined-focused.log` SHA-256:
`a9757588c8edf6c69fa34565de20784f42530c53527203f1f28999beae18505a`.
Act shadow implementation SHA-256:
`18171421c2f0627e29b80a6e8f66d72d6d38f4801f65a59ae2994508709c0de6`.
Focused test source SHA-256:
`cfe7fc8389474651cec6cb2c7fa7495d81e590512630c1231958b4e8c70ba561`.
This remains an isolated synthetic test run, not a full suite, corpus acceptance, CI,
or application-build gate.

The orchestrator independently repeated the same twenty pure tests successfully on
9 October 2026. Log `/private/tmp/sudrf-179-root-act-shadow-focused.log` SHA-256:
`0507656dece1f9b69c8d1d3112c51396b5adb44ea399989bc93342549be84465`.
Independent Astra review cleared three concrete issues before accepting this narrow
checkpoint: legacy navigation fields, independent legacy-ID validation before mark
transfer, and duplicate detection across all raw legacy act rows. Its final result
was Ship for the act-only checkpoint; the full #179 gate remains open.

Stage 3 focused result on **9 October 2026**: **35 XCTest cases, 0 failures** — fourteen
hearing-shadow tests (including wrong-date diagnostics, stale-event collision
blocking, rescheduled relevance, and full legacy material-mark handoff), eleven
act-shadow tests (including the cross-family raw-ID collision regression), five
legacy renderer tests, and five feed-compatibility tests.
SwiftPM used isolated scratch tree `/private/tmp/sudrf-179-hearing-shadow`, module
cache `/private/tmp/sudrf-179-hearing-shadow/module-cache`, and Clang module cache
`/private/tmp/sudrf-179-hearing-shadow/clang-cache`.

```sh
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sudrf-179-hearing-shadow/module-cache \
CLANG_MODULE_CACHE_PATH=/private/tmp/sudrf-179-hearing-shadow/clang-cache \
swift test --disable-sandbox --skip-update \
  --scratch-path /private/tmp/sudrf-179-hearing-shadow/build \
  --filter 'HearingJournalFeedProjectionTests|CaseEventFeedCompatibilityTests|LegacyFeedProjectionTests|ActJournalFeedProjectionTests'
```

Before the evidence-window fix, the newly added wrong-date, competing-event, and
stale-reschedule regressions failed: out-of-window evidence was skipped before
the current occurrence was checked, leaving no date/reschedule diagnostic and
allowing the competing current event to claim the legacy alias and marks.
Red log `/private/tmp/sudrf-179-hearing-shadow/evidence-window-red.log`; the
SHA-256 is `0e4fe0cc4614b1973ae80762ff188cb6f9aac4af08fa79134a59fd6e5ccf3bcc`.
The corrected source and tests passed in the final focused run below.

Final focused log `/private/tmp/sudrf-179-hearing-shadow/combined-final.log`.
SHA-256: `ee7c42255b7f6785f40396be5570d8b3efbd998d26d860f96e6be13b36bcdf20`.
This remains a synthetic, focused SwiftPM run; it is not the full suite, a CI run,
live-corpus acceptance, or an application-build gate.

The orchestrator independently repeated the final **35 pure tests, 0 failures**
on 9 October 2026 after the date-relevance fix, distinct native-card fixture, and
shared comparator extraction. Log `/private/tmp/sudrf-179-root-hearing-final.log`
SHA-256: `0fbbff56882fc2cafd975e70dca8dbbf402125123b841f2100bd561883d0ba5a`.
Independent Astra review cleared both concrete P2 findings and approved this
checkpoint. The duplicate post-projection occurrence pass was removed because
the earlier count and exact date/session validation already exclude every
competing occurrence. This is still a synthetic pure-component gate, not real
source-corpus acceptance, a local app/system run, or authorization for cutover.

The reschedule continuation focused run on **9 October 2026** passed **44 XCTest
cases, 0 failures**: 23 hearing-shadow, 11 act-shadow, 5 legacy-renderer, and 5
feed-compatibility cases. It used the isolated scratch tree
`/private/tmp/sudrf-179-reschedule-scratch` with:

```sh
swift test --package-path . \
  --scratch-path /private/tmp/sudrf-179-reschedule-scratch \
  --filter 'HearingJournalFeedProjectionTests|CaseEventFeedCompatibilityTests|LegacyFeedProjectionTests|ActJournalFeedProjectionTests'
```

Log `/private/tmp/sudrf-179-reschedule-final-20261009.log` SHA-256:
`0d4b3ec912621a0f3043223c2ff019119a12ffe84c983ac8b548371b9d4299fb`. The cases
cover all four read-mark combinations, new-date filtering, exact two-row aliases,
wrong source/level/date/time/result, duplicate event/current rows, missing and
cross-family aliases, target-result drift after rescheduling, chained
reschedules, a partial-own-court to full-refresh replay, material identity, and
Codable/repeated-refresh replay. This remains a synthetic focused SwiftPM
check, not full-suite, CI, real-corpus, application, or cutover evidence.

The earlier act-collision commit `7d478980f32f03a0f53a502306763186b75d3b12`
passed [CI run 37886437956](https://github.com/arvidsever/Sudrf/actions/runs/37886437956):
2,009 XCTest cases, 20 skipped, 0 failures; 28 Swift Testing cases passed;
the Python corpus gate ran 26 tests with 6 skipped. Registry verification,
Xcode app, SwiftPM app/CLI, packaged app, and all three model manifests passed.
The hosted Xcode 27 build and test steps were skipped. This run precedes the
hearing-shadow commit and is not CI evidence for that later source.

The local Xcode project was regenerated after fetching the three immutable
model assets through the existing manifest-checked script. Project generation
does not build or launch the application. A local application build remains
deferred because it would register the application with Launch Services.

## Current continuation checkpoint

On 9 October 2026, the author selected the **new hearing date** for sorting a
reschedule row and its inclusion in the existing 7/45-day windows. Both former
and new dates remain part of the proposed row; its visual presentation must
still be approved before UI changes. The previously agreed migration rule is
unchanged: the one reschedule event is read only when both legacy rows are read.
Whether a known/notified mark should migrate across both aliases remains pending
the user's decision.

The branch was rebased onto main `60d7c45316b7bb2965d752e29c3a5a3346fff1ad`,
retaining the released #413 source-card fields. Compile-only validation with
`swift build --build-tests` passed; no tests or application were executed.
Build log SHA-256:
`40ceb0366368ed625f8c2d8a30bff0624491184b0218ad0dac9a2058c5c1def5`.
The production feed still uses the legacy projection. The synthetic shadow
checkpoint now covers one reschedule and fails closed on unsupported target
results; the known-mark decision and downstream gate remain open. This is not
evidence for cutover.
