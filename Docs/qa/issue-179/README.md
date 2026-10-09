# #179 — legacy renderer oracle and act-only journal shadow

This note records **stage 1** (legacy renderer extraction) and **stage 2** (published-act
shadow); neither passes the full downstream shadow gate or authorizes cutover.
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

The focused tests use isolated fixed synthetic data. They do not instantiate `AppRouter`,
read SwiftData or persisted preferences, make network calls, launch the app, or deliver
system notifications.

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
