# Source-fixture contract

`Tests/SudrfKitTests/Fixtures/source-contract/index.json` is the level-1
catalogue for issue #181. It references existing source material; it does not
copy, rename, or manufacture a response. A runner resolves an artifact path
relative to `source-contract/`, verifies its SHA-256 before parsing it, then
compares the normalized result with the JSON named by `expected.path`.

The catalogue deliberately separates a real portal origin from the fidelity of
the committed bytes. `capturedAt: null` means that an old fixture has no
recorded capture timestamp. It is not replaced with the Git commit time.
`redaction.originalSHA256: null` means the pre-commit capture cannot be
independently verified. These records remain useful parser regressions but do
not prove a byte-for-byte original capture. The fixed `observedAt` in an
expected `SourceAttempt` is a test clock, not capture metadata.

## What is covered now

| Pathology | Status | Record(s) |
| --- | --- | --- |
| Windows-1251 and alternate/canonical SUDRF host | covered | `sudrf-cp1251-captcha-form`, `sudrf-canonical-host-*` |
| CAPTCHA response | covered | `sudrf-cp1251-captcha-form`, `sudrf-canonical-host-captcha`, `ksoyu-captcha-rejected-listing` |
| `msudrf` unlocked listing without a UID | covered | `msudrf-unlocked-results` |
| KSOYu non-standard КоАП listing | covered | `ksoyu-adm3-koap-listing` |
| One complete normalized `CaseMovement` | covered | `sudrf-sanitized-card-movement` |
| Vintage SUDRF markup and mobile duplicate rows | covered | `sudrf-vintage-vnkod-card` |
| Moscow and VSRF portal families | covered | `mosgorsud-participant-search`, `vsrf-search-by-uid` |
| Post-CAPTCHA session; KCAPTCHA cookie continuity | missing | no safely retained real response pair |
| HTTP-200 maintenance; honest zero; unknown response | missing | only synthetic or ambiguous material exists |
| Search duplicate rows, unstable UID and proven renumbering | missing | only the missing-UID and combined-number shapes are represented |
| Partial KSOYu / stale links | missing | no proven raw outcome retained |
| `r_juid` known, new, partial/error responses | missing | existing cards contain links, not endpoint responses |
| Transport failure envelope | missing | no safely retained real URL-loading error envelope |

The KSOYu `new=0` page is intentionally not counted as honest zero: it is a
known malformed-request response that merely looks empty.

## Capture and redaction workflow

1. Save a failed live response once, outside the test run, together with its
   portal family, requested and effective host, response status, content type,
   charset, and capture time. Never put cookies, request bodies, CAPTCHA
   answers or authorization headers in the manifest. Replay URLs must contain
   only the minimum non-sensitive parameters needed to match the adapter.
2. Review the bytes for names, IDs, referrers, session values, CAPTCHA IDs and
   other private or transient values. Redact in place only when the parser
   shape remains representative; record the pre-redaction and committed
   SHA-256 values. If that is not possible, leave the matrix row missing.
3. Add one L1 record with explicit runner input and an expected
   `SourceAttempt` or a full `CaseMovement` JSON. Do not make the expected
   data a second raw HTML fixture.
4. Validate before committing:

   ```bash
   jq empty Tests/SudrfKitTests/Fixtures/source-contract/index.json
   find Tests/SudrfKitTests/Fixtures/source-contract -name '*.json' -print0 | xargs -0 -n1 jq empty
   shasum -a 256 Tests/SudrfKitTests/Fixtures/sudrf_captcha_form.html
   swift test --filter SourceFixtureContractTests
   ```

The last command is local only; the contract harness must never make a live
request. A live drift discovered by #65 is evidence for a new capture, not a
network dependency of the regression test.

## Metadata audit

Replay URLs are public, minimal and fail closed; metadata contains no cookie,
CAPTCHA answer/token, credential or authorization value. One Moscow fixture
retains the public search surname already present in that real response because
the portal adapter requires it to reproduce the exact URL. The historic
Windows-1251 CAPTCHA fixture had one embedded transient CAPTCHA identifier; it
was replaced in-place with equal-length redaction and records both hashes.
Existing raw fixtures that contain only a link to `r_juid` are not treated as
endpoint responses. Synthetic unit HTML, unproved origin material, and
unredacted sensitive captures remain outside the counted corpus.

## Level 2: semantic changes

`Tests/SudrfAppTests/Fixtures/source-contract/l2-index.json` closes the second
contract level: each entry pins a real raw artifact by SHA-256, derives an old
and a new normalized snapshot from values present in that artifact, and compares
the complete deterministic `CaseEvent[]` payload. The runner never uses the live
network.

The initial matrix covers all required source families:

| Pair | Source artifact | Proven semantic change |
| --- | --- | --- |
| `sudrf-sgs-explicit-postponement` | `sgs_card.html` (`1d63993f…`) | the 31 March hearing is explicitly marked `Заседание отложено` and paired with the sole 11 April hearing as one `hearingRescheduled` |
| `ksoyu-published-act` | `ksoyu_case_card.html` (`50a15cbf…`) | one stable published act becomes `judicialActPublished` |
| `msudrf-discovered-card` | `magistrate_results.html` (`e83e298d…`) | one stable magistrate card becomes `instanceDiscovered` |

These source-derived pairs are deliberately narrow: they prove the semantic
facts contained in the retained response, but do not pretend that a single
capture is a chronological before/after archive. Additional real pairs follow
the same #65 capture and redaction procedure. Synthetic snapshots remain useful
only as negative and edge-case unit tests and do not count toward this matrix.

Run the level separately with:

```bash
swift test --filter SourceFixtureLevel2ContractTests
```
