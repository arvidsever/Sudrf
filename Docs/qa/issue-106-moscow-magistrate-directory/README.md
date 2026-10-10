# Issue #106: Moscow magistrate KoAP first stage

## Current status — 10 October 2026

The first KoAP stage is implemented: 471 active Moscow magistrate units appear
separately, ordered by the published visible unit number; classification code,
published title and native URL path ID remain distinct. Number/UID/participant
search is scoped to the selected unit. Exact native card identity is preserved
through card loading, saving, refresh and movement-cache admission.

One authorized live UID search and its returned card passed on 9 October 2026.
The native offline picker order and selection were accepted by the user on
10 October 2026. Source completeness, pagination, verified empty search and the
full live appeal chain remain unproved. Partial source results do not confirm
magistrate journal events. Acts from the unit, GPK/KAS and Moscow CSV/direct-link
import remain outside the completed first stage. Issue #106 stays open.

The source-backed directory, synthetic card/movement regressions, saved-store
checks and native fixture QA are different evidence. Current-head hosted CI and
release gates are checked separately below; historical totals do not replace
execution of the named disk regression. The actual main at integration is
`8a7f0e8245d7275dcd879692b998560c33ef9d9f` (0.64.8, build260).

## Historical directory/parser checkpoint — 9 October 2026

This initial checkpoint added the official directory parser and subject77
resolver routing. The directory fields remain separately preserved and the
generic `MagistrateCourt.isSupported` check stays limited to `*.msudrf.ru`.
The later search/card/movement implementation and acceptance evidence are
recorded below; this initial parser checkpoint is not the final feature status.

## Source and fixture

The parent task captured `https://mos-sud.ru/` once on 9 October 2026 at
17:25:33 UTC. The response had 366,469 bytes; its SHA-256 is
`ba1152d8dd64f9bf5cf4d3bf7c9e0d21b4b3afaaa3c53ad9a9a602bfc395474a`.
The full response remains in the private diagnostic directory
`/private/tmp/sudrf-106-directory/home.html` and is not checked into the
repository.

`Tests/SudrfKitTests/Fixtures/moscow_magistrate_directory.html` contains only
the source page's published `courts` array, wrapped in a minimal script element
for parser tests. It excludes the rest of the page, unrelated scripts, and
session/user state. Fixture SHA-256:
`610bba0358fb0a4f15932f58b67e9f8cc90605545bdd5cccb97c0e2d82c13b02`.
The captured array contains 476 rows: 471 active and 5 canceled. `rsCourtId`
repeats across many units; it is retained as metadata and never used as a row
identity.

The source demonstrates that the fields are not interchangeable. For example,
one active record publishes alias `424`, classification code `77MS0424`, and
URL path `/rs/424`. The returned `unitPathID` is read from that URL path; the
parser does not infer it from the alias, code or row number. It also retains
non-standard published codes such as `77MS02-388` unchanged.

The directory home is not established as a search endpoint. Separate parent
diagnostics found `/rs/424` redirects to the home page and `/424` has no current
court or search form. This checkpoint does not issue a search or fetch a unit
URL as a search request.

## Verification

Offline command:

```sh
swift test --package-path . --scratch-path /private/tmp/sudrf-106-spm --filter Magistrate
```

Result on 9 October 2026: 91 selected tests passed, 0 failures, including the
5 directory tests, 16 Moscow movement tests and 15 Moscow client tests. The log
is `/private/tmp/sudrf-106-directory-magistrate.log` (SHA-256
`bd9113664fcadc9639979c17bd89a5d7be9913b30fc2afda29bce92c5dda32a7`). Resolver
tests use an ephemeral `URLSession`, in-process `URLProtocol` responses and a
temporary disk cache. They verify use of the exact home URL, replacement of
stale Moscow cache entries, preservation of another region, and failure instead
of returning an old aggregate when the directory response is malformed. The
movement profile also checks that an external redirect is rejected by the
strict directory transport.

The offline coverage verifies fixture-backed directory parsing and resolver
behavior. The separate one-case live smoke below verifies one current UID
search and the card returned by that search. Neither establishes pagination,
search completeness, general UI selection, or directory-wide availability.
The app and production data were not opened.

## One-case live smoke result

Evidence types are kept separate:

- The directory capture and checked-in reduced directory fixture above are
  source-backed directory evidence.
- The pinned private reference
  magistrate KoAP HTML fixture and its directly associated test
  supplies only the published UID and case number for an opt-in smoke input.
  Its directly associated pinned test supplies native unit path ID `424`.
  This old reference chooses a bounded test query; it does not show that a
  current search or card endpoint is available.
- The checked-in client and movement fixtures are synthetic and establish
  parser, routing, and identity behavior only.
- Two separately authorized live attempts were run after a stable source
  checkpoint and isolation review. The second passed after correcting the
  first test predicate. They cover only the pinned query and unit described
  below; they do not establish general availability or result completeness.

The opt-in test is
`MoscowMagistrateKoAPLiveTests/testPinnedUIDSearchThenFetchReturnedNativeCard`.
It is disabled unless `SUDRF_MOS_SUD_LIVE_INPUT` names a private JSON file with
exactly `uid`, `unitPathID`, and `caseNumber`, protected as mode `0600`. The
test performs one bounded search by the pinned UID within unit `424`, requires exactly one
matching native result, then fetches only the card URL returned by that search.
It does not use the pinned card URL as a result fallback. Ordinary test runs
skip before constructing the client. Any live failure is a failed smoke gate;
there is no automatic retry of the test or broader query; the second run
required separate human authorization.

The private opt-in input used for the attempts is at
`/private/tmp/sudrf-106-live-smoke-20261009/input.json`; it is not part of the
repository. On 9 October 2026, 18:18:18–18:19:20 UTC, the selected test reached
the UID search and received a partial outcome with one candidate row. The
test then failed its unique exact-result predicate, which at that time
required the search row itself to publish the requested UID as well as the expected
number and native-unit URL. It stopped before fetching any card. The private
stdout log is `/private/tmp/sudrf-106-live-smoke-20261009/live-test.stdout.log`
(SHA-256 `73b87d71095b29a61ca934d93f65dc464d7721fdec816a80605677d33cec34e3`);
the sanitized result at `/private/tmp/sudrf-106-live-smoke-20261009/result.json`
has SHA-256 `2f9292eac6ec4624c713b41500cbccc711c09ccfe7fb0bb38fce4f4b5909771f`.
Both files are mode `0600`.

The candidate's individual values were not retained in the log, so this
attempt cannot identify which part of the combined predicate failed. The
existing synthetic UID-search test explicitly allows `caseUID == nil` on a
candidate row and prevents copying the query into that field. The harness has
therefore been adjusted so a missing row UID does not reject an otherwise
exact case-number/native-unit candidate; if a row does publish a UID, it must
match. The fetched card must still publish the requested UID. This is a
test-contract adjustment, not a finding that the source or search is
unavailable. The first attempt remains failed under the original predicate.

After the harness correction, the one authorized second attempt ran on
9 October 2026, 18:21:37–18:22:14 UTC. The search returned one candidate with
a card URL; the native route, unit, and case-number checks passed, and the row
did not publish a UID. The returned URL was then fetched. Response native
identity, unit, UID, case number, and useful session/result detail checks all
passed. The selected test passed 1/1 with 0 failures. Its private stdout log
is `/private/tmp/sudrf-106-live-smoke-20261009/retry-2/live-test.stdout.log`
(SHA-256 `eae7c795e90f6b32b7cb373004b67bcd58050c22e32e2b474478f6f6c375db26`);
the sanitized stage result at
`/private/tmp/sudrf-106-live-smoke-20261009/retry-2/result.json` has SHA-256
`f462a1b781e1b6174d84cb5d1922029177fca1dd0e710ff83f2dc684dbecc30c`. Both
files are mode `0600`. This
establishes one successful query-and-returned-card path for this pinned case
and unit only; it is not a completeness or broader availability claim. No
third attempt was made. The app and production data were not opened.

## Integration checkpoint

On 9 October 2026, the client profile passed 17/17 and the movement profile
initially passed 16/16 with synthetic responses. After the review fixes, the
movement profile passed 18/18 from a clean scratch directory. The client profile includes the shared
unit/year-preserving number-padding comparison. The movement profile checks
the district court, MGS lower-number relation and the separate federal provider.
Client log SHA-256: `44a625d8db594a87ee9c44d9479301aba1b4d73db20000ae79a52d433b3f1661`.
Movement log SHA-256: `2b03689deadf5ff74d5a8c9e03b11cdd1801bef9e12c367e202f1d0e6683db4f`.

`SudrfAppTests` compiled but was not executed locally. The new disk regression
creates its context through the selected-unit search, saves it, releases the
container, reopens the disk store and refreshes through injected clients.
It does not test CSV or direct-link import. Hosted execution remains required
because the existing SearchModel initializer reads `CaptchaSettings.shared`.

Independent review found missing native-source identity/admission branches
in the journal and insufficient stale-anchor checks. Exact native identity
mapping and saved UUID/UID contradiction guards have now been added. The final
18-test movement log SHA-256 is
`e5e0a951c4a7c3007a85b0240c421f870a89ceba8281579f04aba6bdb279f15e`.
This checkpoint is not a completed review or release gate.

The root source court remains partial until search completeness is established,
while its exact fetched card identity is preserved as positive evidence.
Fetching that one card does not qualify the whole unit for journal advancement.
The source host stays in the attempt's affected sources even if all higher
cards load. The existing court-wide admission policy from #262 is unchanged.

The original disk assertion that two journal-ID arrays matched could pass
with an empty journal. A separate temporary-disk regression now supplies
explicitly synthetic complete coverage and checks baseline, an actual hearing
addition, reopening and a repeated refresh without duplication. This tests the
native journal identity contract; it does not claim a complete live refresh.
Both App disk regressions remain compile-only pending hosted execution.
On 9 October 2026, the author accepted releasing the first stage with this
notification limitation. Search completeness remains an open criterion in
#106; this decision does not change source confirmation or journal admission.

The follow-up test review corrected two compile-only oracles: persisted movement
coverage is nil after standard stripping; first complete coverage quietly seeds
the semantic baseline. The subsequent reschedule must create exactly one event,
and the cold reopen/repeated refresh must preserve that journal. Final compile
and 18/18 Kit movement log SHA-256:
`838f2e8a0068df9f962870f80244a22d00f7bb359aae737da983819760f511b2`.
Production stripping and quiet first-baseline behavior were not changed.

## UID trust boundary follow-up

Independent review found that the live harness required the fetched card's
own UID to match the query, while interactive opening did not enforce this
when the result row omitted its UID. The app now retains the expected UID
with that result batch and verifies the fetched native card before permitting
tracking or higher-court requests. Editing the search field does not change
the older row's criterion. The query is never copied into published row data.
A failed fresh fetch revokes proof for that native identity; an older movement
request cannot restore it. Wrong or missing card UIDs leave no tracking context.

The focused Kit movement profile passed 19/19 with 0 failures. App and App-test
targets compiled, with 0 App tests executed locally. Final log SHA-256:
`0e8073c744a3cb1895806d41f83ebd8c37efc6d9ea2bc19e57c67535ab50602a`.
Hosted CI on the previous commit stopped because a new synchronous test
URLProtocol omitted its required `stopLoading()` override. Both new stubs now
provide that override; hosted execution must be repeated on the updated commit.
No further live attempt was performed for these synthetic regressions.

## Native identity across initial save and refresh

Hosted run `37978229688` on `325220d078da60e1d17ed4f40b27d939c35b4489`
executed the new App regressions. UID, picker and partial-save checks passed;
the complete-refresh disk test failed two assertions. Diagnosis found that
initial save used generic `msudrf|77MS0425` identity while complete refresh
used the Moscow source family. Without a judicial UID, reconciliation created
a second dossier and wrote the refreshed baseline there. Reading another key
or adding a UID to the fixture would hide the defect.

The shared identity builder now uses the validated native card locator for
initial save, refresh and bootstrap: `moscow-magistrate-koap|425|adm|UUID`.
The separately published court code remains unchanged. Contradictory source
domains, register, court level, native path or saved UUID fail closed.
The disk oracle still starts without a judicial UID and checks one record,
stable record key/logical ID/native identity, quiet first baseline, one actual
reschedule and no duplicate after cold reopening and repeated refresh.
Independent Astra review passed for this delta. App test targets compiled
locally without execution; hosted CI must be repeated on the new commit.
Existing persisted identity graphs are not silently rebuilt by this change.


## Numeric picker order regression

Native acceptance found lexicographic ordering such as 8, 89, 9, 90.
`moscowCourtOption(for:)` omitted `CourtOption.number`, so the existing shared
numeric comparator fell back to alphabetic title ordering. The first correction
forwarded the classification number and passed 13 synthetic focused tests, but
native QA then exposed a separate mismatch: active unit 48 has code `77MS0439`;
units 323 and 391 also have different classification numbers. That intermediate
implementation does not satisfy full visible-number ordering.

The final mapping reads the number after № in the published title, retaining the
classification code and native URL ID unchanged for routing and identity. It
uses the existing `SearchModel.ordered` numeric comparator. Synthetic units
intentionally use different classification and native IDs. A regression also
parses all 476 entries of the existing official-directory fixture and asserts
that all 471 active options appear as visible numbers 1 through 471. Inactive
historical entries remain excluded.

On 10 October 2026 the final focused command executed 14 App tests (5
`CourtOptionOrderTests`, 9 `MoscowCourtOptionTests`), all passed:

```sh
swift test --disable-sandbox --scratch-path /private/tmp/sudrf-106-spm -Xswiftc -strict-concurrency=complete --filter 'CourtOptionOrderTests|MoscowCourtOptionTests'
```

Log: `/private/tmp/sudrf-106-published-order-tests.log`, SHA-256:
`8743c227422f41e71d3cbfbfd1290508dfc68ae14c5e40c137b530c34b4eeba4`.
The fixture is a saved official directory, not a new live response. Independent
Astra review passed for this final correction on 10 October 2026, including the
fallback for an unparseable published number and unchanged routing identity.

Native offline QA used `Sudrf106PublishedQA`, bundle identifier
`ru.sudrf.qa.issue106.published`, with this final production mapping and the saved
directory. Its expanded native menu contained all 471 options in exactly the
order 1 through 471. Selection of 9 and 89 was checked; screenshots shown in the
conversation display 8, 9, 10 and 88, 89, 90 respectively. The source used an
offline fixture and no working database. The QA application and the two earlier
QA instances were quit; inventory confirmed no running QA applications.

On 10 October 2026 the user accepted the corrected picker order after reviewing
the native screenshots. This accepts the offline picker order and selection;
it does not accept live card/search completeness or the whole #106 scope.
Hosted current-commit CI remains a separate gate. The previous classification-
based review does not stand in for this final title-based review.

## Native movement cache identity — 10 October 2026

The Moscow magistrate cache now compares native published case numbers with
`MoscowMagistrateKoAPNumber.matchesPublishedNumber` and requires the cached
first-instance `SourceNativeCardLocator` identity to equal the selected card.
A different, absent or invalid locator is a cache miss. Other sources retain
their previous cache admission rules; saved records and journals are unchanged.

The initial review suspected an incorrect cache hit for two native cards with
the same unit and number. Execution did not reproduce that claim: the previous
generic number comparison rejected the valid three-part native number, so both
cards missed the cache. This correction adds safe native cache reuse rather
than establishing a prior wrong-card display.

The regression uses the actual Moscow client and MovementService against an
injected offline URLProtocol: selected card B is fetched for cached A, absent
and invalid source locators, despite equal unit/number and absent caseUID. The
same B identity is reused without a request. Transport cookies/cache, tokens,
corpus and higher-provider paths are isolated; the existing read-only
CaptchaSettings.shared object is retained without explicit test property writes
and with no CAPTCHA challenge in the fixture. Its legacy initialization still
reads/registers process defaults and may normalize the stored max-attempts key;
this profile does not establish zero common-settings access or mutation. No
normal-state rollback was attempted without a known prior baseline. The previous
in-memory cache entry is restored.

Fifteen focused tests passed without failures or skips (five ordering, nine
Moscow mapping and one cache regression). Log:
`/private/tmp/sudrf-106-cache-picker-final-profile.log`, SHA-256:
`73bae2e31702a57088eeeb8fe2e36a118658f158db652c3bb9453be5b6e41bda`.
This offline profile does not add live-source or native GUI acceptance evidence.

## Main integration and private-settings follow-up — 10 October 2026

Integrated actual `origin/main` `8a7f0e8245d7275dcd879692b998560c33ef9d9f`
(0.64.8, build 260) without conflicts. Current roadmap and release-history entries
are preserved; this feature branch has not assigned a release version.

Reused the exact independently reviewed #241 `CaptchaSettings(defaults:)`
injection. Production default and `CaptchaSettings.shared` still use `.standard`;
registration, reads and writes use the injected defaults instance. The new native
cache regression now supplies its own suite and removes that suite afterward.
It does not create the shared settings instance, migrate preferences or read the
standard preferences. The prior profile's legacy initialization boundary above
remains historical evidence, not a claim about this follow-up.

Only the safely scoped ordering, mapping and new cache regression profile was
repeated: 15 tests, no failures or skips. Log:
`/private/tmp/sudrf-106-cache-picker-main-integrated-private-profile.log`, SHA-256:
`9b40a87dd65977f2ad9f474a07bcdcf1a5a01f0b1110552dec8a2a1b2728354c`.
No full local suite, GUI or live-source request was repeated. Hosted current-head
CI remains the final execution gate.

The unused VSRF client is now created lazily, preserving the normal movement
factory's default while avoiding eager common-cookie client construction when
the injected offline factory bypasses that route. The final private profile
above ran after this change.

Historical hosted run38056295190 on `2b514b7` explicitly passed the named
`testSyntheticCompleteMoscowAnchorTransitionPersistsOnceAcrossDiskReopen`
(0.141s) and `testValidatedUnitContextPersistsAndRefreshesAfterDiskReopen`
(12.558s), plus `testPickerSelectionScopesGlobalSearchAndOpensExactNativeCard`
(0.026s) and the no-judicial-UID native identity test (0.001s). These were executed,
not skipped. Final integrated-head CI must independently repeat these gates.
