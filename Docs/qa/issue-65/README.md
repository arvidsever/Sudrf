# Issue #65: portal canary

## Scope

The scheduled, non-blocking workflow checks one public, queryless form or
landing page from each of seven source families:

| Family | Target |
| --- | --- |
| Ordinary SUDRF | Syktyvkar city court, `g1` form |
| Legacy/VNKOD | Zavolzhsky district court of Ulyanovsk, `g1` form |
| Subject court | Saint Petersburg city court, `g2` form |
| KSOYU | Third cassation court, `g3` form |
| Magistrate | Petrozavodsk magistrate portal form |
| Supreme Court | `/lk/practice/claims` with query removed |
| Moscow City Court | `/search` with query removed |

The legacy target is confirmed by `VNKODCourts.json` (`73RS0004`) and the
existing `sudrf-vintage-vnkod-card` source-contract fixture. The target test also
asserts that `SudrfURLBuilder` produces the legacy `name_op=sf` URL with
`_deloId`, `_caseType`, and `_new`, not the ordinary `delo_id` parameter.

These are public, blank-form/landing-page checks. The canary does not submit
case criteria, open case cards, solve CAPTCHA, or retain parsed case rows.

## Request and response safeguards

- One application-level `GET` per target, run in sequence with a 1.5 second
  pause between targets. Redirects are rejected; there is no application retry.
- The live session is ephemeral, does not read or write cookies, credentials,
  or URL cache, uses the platform TLS stack, and applies 30 second request /
  45 second resource timeouts.
- Response bodies larger than 1,000,000 bytes are cancelled and not hashed as
  complete. Only HTML/XHTML responses with HTTP 200 reach decoding and page
  classification.
- Existing SUDRF, magistrate, VSRF, and MosGorSud classifiers/parsers are used
  in memory. Parsed rows are reduced to a success/failure outcome and discarded.
- A recognized search form or source-parsed listing remains an expected
  outcome. A recognized CAPTCHA is also an expected *diagnostic* outcome: it
  is recorded distinctly and does not fail the workflow, but it does not prove
  parser or source health. The canary does not solve CAPTCHA. Maintenance,
  unknown pages, decode/parser failures, transport/HTTP failures, and empty
  listings remain non-success outcomes.

## Report and artifacts

The report contains only the family, host, outcome, stage, HTTP status, body
byte count, SHA-256, allow-listed charset names, and (for suspicious pages) a
small structural snapshot. The snapshot contains counts of allow-listed HTML
tags and booleans for known controls/listing markers/CAPTCHA. It does not
contain raw HTML, text nodes, attribute values, query strings, cookies, headers,
case identifiers, or parser output. This intentionally keeps unknown source
content out of workflow artifacts; an unexpected page is recorded structurally
instead of attaching its raw response.

GitHub Actions runs daily at 06:17 UTC and can also be started with
`workflow_dispatch`. It has read-only repository permissions, is not attached
to pull request checks, and retains the sanitized report artifact for seven
days. The job summary shows only family, host, stage, outcome, and HTTP status.

Run a single approved live check manually with:

```sh
swift run sudrf-cli portal-canary --live \
  --output-directory /tmp/portal-canary
```

Without `--live`, the command refuses to run. It issues all seven checks once
before returning a failing exit status if any source has an unexpected outcome.
Recognized forms, parsed listings, and recognized CAPTCHA challenges are
expected workflow outcomes; other outcomes remain failures.

## Offline evidence and remaining acceptance

The sixteen CLI tests use stubbed responses only. They verify seven queryless
HTTPS targets, the VNKOD directory and legacy URL/form contract, redirect
rejection, the body-size cap, single-request HTTP failure reporting, and
removal of text, case-like values, card IDs, UIDs, and tokens from reports.
They also distinguish recognized forms/listings from valid-but-empty VSRF and
Moscow results, keep broken listings and positive SUDRF/magistrate result
counters from falling back to co-located search controls, and require an actual
`<form>` around expected controls. These tests
do not establish that a live portal is available or currently matches its
parser contract.

## Build-only verification

On 2026-10-09, XcodeGen 2.45.4 regenerated the project and Xcode 27.0
(27A266a) completed an unsigned Debug build of the `Sudrf` scheme. The build
used base Git revision `2781b69936daa0b0a7731fa9f367f44583974c3c` plus the
uncommitted issue-65 working-tree changes. The built app's executable SHA-256
was `94ea957fc1491aeed83d555225e6dc71f47e072c49d4ee7fed69d065426bfc4b`;
the build log SHA-256 was
`071eccfd4aa8fb32987494a5753f6f67486e662d6d6df988d1ac33fd04c047f8`.
The temporary product was under `/private/tmp/sudrf-portal-canary-65-derived`.

The three ignored CoreML directories were copied from the separately verified
worktree at `014fc064954df639064091077ce7360c992b6f5f`. Each matched this
branch's tracked model manifest before copying, after copying, and inside the
built app bundle. The tracked FSSP eligibility file was identical in both
worktrees and in the bundle (SHA-256
`3961ceccb37f5c119452c4989b2ce3e2f7defa550b7529339c4c6bad8188f5a3`). The
product reported bundle `ru.sudrf.app`, version `0.64.2` (build `254`),
matching the existing project settings. The app was not launched. Xcode did
run its built-in `RegisterWithLaunchServices` build step for the temporary
product. This is a build check only; it does not replace live workflow
acceptance.

## First live run — 2026-10-09

One manual, single-pass run started at `2026-10-09T17:01:35Z`. The safe JSON
report is [archived here](live-run-2026-10-09.json), SHA-256
`f56098ba5b0392edef793cbb13a07e9939ea4634dc313f5f9d9ffe4ed11a50ce`. It
contains only request outcome metadata and bounded structural fields; no raw
response body, redirect destination, case data, or participant text was
captured. The local run log SHA-256 is
`e7c0ef03293c86aaa81124484d1dee63f0ec77b12c7663141c73acba26d0d2b0`.

| Family | Host | Outcome | HTTP / stage |
| --- | --- | --- | --- |
| Ordinary SUDRF | `syktsud--komi.sudrf.ru` | Redirect blocked | 301 / `redirect` |
| Legacy/VNKOD | `zavolgskiy--uln.sudrf.ru` | Redirect blocked | 301 / `redirect` |
| Subject court | `sankt-peterburgsky.spb.sudrf.ru` | CAPTCHA; expected control present | 200 / `classification` |
| KSOYU | `3kas.sudrf.ru` | CAPTCHA; expected control present | 200 / `classification` |
| Magistrate | `petrozavodskoj.komi.msudrf.ru` | TLS-stage network failure; cause unknown | — / `tls` |
| Supreme Court | `vsrf.ru` | Redirect blocked | 302 / `redirect` |
| Moscow City Court | `mos-gorsud.ru` | Response-size cap reached | 200 / `body_limit`, 1,000,000 bytes |

This run did not establish seven healthy parsers. Redirect locations were
intentionally not retained; the TLS failure has no established cause; and the
Moscow response was capped before parsing, so none of those outcomes proves a
source defect. No scheduled workflow run is included in this evidence.

The CLI build log reports its SwiftPM build and the sanitized outcomes, but
does not print a Git or executable hash. At run time, `HEAD` was
`2781b69936daa0b0a7731fa9f367f44583974c3c` and the issue-65 changes were
uncommitted. The [working-tree file manifest](live-run-2026-10-09-source-manifest.txt)
was recorded after the run and before adding this report; its SHA-256 is
`2d91c2b01b55531fbabce61affffc58e810750427b0eff2878fb42831c433b24`.
The local CLI executable at the report timestamp has SHA-256
`9622378e018047ad645ea24e2c6e21b99b342e23d5496af72fb7af15ae2a0e75`.
These hashes document the local run context; neither is embedded in the JSON.

## Offline address references

No target was changed based on this run. Existing SUDRF card and UID fixtures
(`Tests/SudrfKitTests/Fixtures/issue312_provenance.md` and
`Tests/SudrfKitTests/Fixtures/issue321_fixture_provenance.md`) also use
`syktsud.komi.sudrf.ru`, while the canary's generated blank-form URL uses
`syktsud--komi.sudrf.ru`; those card references do not identify the redirect
destination for a blank search form. The VNKOD source contract
(`Tests/SudrfKitTests/Fixtures/source-contract/index.json`) confirms the court
host and card format but does not record the redirect destination. The old
VSRF provenance fixture (`Tests/SudrfKitTests/Fixtures/vsrf_current_340_provenance.md`)
records `vsrf.ru` redirecting to `www.vsrf.ru` with a successful response, so
`https://www.vsrf.ru/lk/practice/claims` is an evidence-backed candidate for a
future direct target after review; this run's report deliberately omits the
current `Location` value. For MosGorSud, the endpoint
(`Sources/SudrfKit/MosGorSud.swift`) and source contract use `/search`; the
available fixture (`Tests/SudrfKitTests/Fixtures/mosgorsud/search-mgs-participant.html`)
is a 92,370-byte participant results page, not a blank page. It does not support
switching to `/mgs/search`, and the capped blank response is not a parser
result.

Issue #65 remains open. The first live pass is diagnostic, not source-health
acceptance. Any further target changes require offline source review before a
new live run. If a canary fails, first inspect the safe outcome and existing
source fixtures; any new fixture must be reviewed and sanitized before it is
committed. Do not copy raw unknown HTML into the workflow artifact.

## Current-main checkpoint

On 9 October 2026 the branch was rebased onto `60d7c45316b7bb2965d752e29c3a5a3346fff1ad`
(0.64.4, build 256). The roadmap conflict retained current-main calendar release
facts and this branch's diagnostic #65 result. No canary implementation or
target was changed. All test targets compiled without execution (log SHA-256
`f679506ab2d74ea9a1114f68e2f450d5944d328d97f5e1ccec3c858d3c157f42`).
The offline URLProtocol-based canary profile passed 15/15, 0 failures (log SHA-256
`ee189ea8ba8e9b48e52aa8dc7c772ec255f7f9c8b798572cf3b6fb19ebdc7469`).
No new live GET or workflow dispatch was performed.

## CAPTCHA exit policy

The author chose to treat a recognized CAPTCHA as an expected canary outcome,
separate from an error that fails GitHub Actions. The command still records
`captcha` in the report; the CAPTCHA is not solved and the result is not a
parser-health pass. A mixed report containing CAPTCHA and a network failure
still fails, as do unknown pages, parser/decode errors, maintenance, redirects,
HTTP failures, body-limit failures, non-HTML responses, and empty listings.
The seven-target count remains mandatory. This decision changes only workflow
exit status, not classification or report contents. New-head CI remains pending.

The updated offline profile passed 16 tests, 0 failures, on 9 October 2026 (log SHA-256 `280b7c13305cdb9c72ab1cfb6eaabdf7bd9e1c3986804f482eea03375e636e7a`). Independent review accepted the outcome-policy delta. No new live request or workflow dispatch was made. Final-head hosted CI is pending.

## Accepted first-stage release scope, 10 October 2026

The author selected CAPTCHA as a separate expected outcome without workflow failure. The 16-test offline profile passed (`/private/tmp/sudrf-65-captcha-policy-profile.log`, SHA-256 `280b7c13305cdb9c72ab1cfb6eaabdf7bd9e1c3986804f482eea03375e636e7a`). CI [37990541316](https://github.com/arvidsever/Sudrf/actions/runs/37990541316) succeeded on policy head `7930f858785a1d89548650bf513824d26e1bff6f`: 2032 XCTest, 20 skipped, 0 failures; 28 Swift Testing; 26 Python tests, 6 skipped. CI-log SHA-256 `6cf1d69c3ca368b742c7a94825d8d2ef07700f8119317b1e90aabf2e34613c58`. Hosted Xcode 27-specific build/test steps were skipped.

Independent review: Ship for publication of this diagnostic stage with #65 open. A failing daily job from blocked redirects, TLS errors or unknown/oversize pages is an expected diagnostic result, not a PR gate or proof of a portal regression. No scheduled report has yet been produced from main. Redirect destinations are not retained, and target URLs were not changed by guessing.

The branch was rebased onto release main `e9910a36b9d1af09d82de3f2eeaba246573a6cca`, preserving the canary implementation. Release 0.64.6 (258) is assigned to this developer-only stage; the final release commit must pass its own CI before merge.

After rebase, the 16-test profile passed again: `/private/tmp/sudrf-65-release-profile.log`, SHA-256 `1165c843b114a0271a717ab294b7a780d09fe5022908017a5c5994a30e1d3a7f`. XcodeGen regenerated the app project and the unsigned Xcode 27 Debug build succeeded without launch. Product version 0.64.6 (258); build log `/private/tmp/sudrf-65-release-xcodebuild.log`, SHA-256 `f724ba0216cbd333dcd11eb9ab2b75c7e58c3e7ee9072d73375d8ec2cda8828c`. Registry `--check` passed.
