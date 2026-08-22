# Reference: alexxmirny/sudrf_parser

Status: reviewed 22.08.2026 as an addendum to `open-source-reference.md`.

Repository: https://github.com/alexxmirny/sudrf_parser

## Why it matters

This is a very small but unusually direct analogue of Sudrf's monitoring loop. It watches explicit `sudrf.ru` case URLs, fetches server-rendered HTML, converts each page to a JSON snapshot, compares it with the previous snapshot, appends changes to a JSONL log and emits a Windows toast.

The project was created on 08.08.2026 and last pushed on 19.08.2026 at review time. It is Python 3.11, MIT-licensed and has no Selenium/browser dependency. Main dependencies are `requests`, BeautifulSoup, `lxml` and `win11toast`.

## Useful design choices

### 1. Monitoring pipeline is explicit

The application structure is almost exactly:

`URL → fetch → structured snapshot → diff → append-only change log → notification`

This is useful confirmation of the product direction behind Sudrf issue #155. The difference is that Sudrf should stop one layer later: the diff must produce typed semantic `CaseEvent`s rather than field-level JSON changes.

### 2. Layout detection uses page semantics, not `delo_id`

For case cards the parser distinguishes first instance from cassation by visible tab labels (`ДЕЛО` / `ОБЖАЛОВАНИЕ` versus `ПРОИЗВОДСТВО` / `РАССМОТРЕНИЕ В НИЖЕСТОЯЩЕМ СУДЕ` / `ЖАЛОБЫ`) rather than treating a particular `delo_id` as the schema.

Sudrf already follows the same principle: `CaseCardParser` searches tab/container contents and header text instead of relying on fixed `contN` positions. Treat this as independent validation of the current parser design, not a new task.

### 3. Tables are mapped by header text

Rows are decoded through header names with exact-match-then-substring lookup. This is materially more robust than positional parsing and matches the direction already used by Sudrf for movement/vintage tables.

The parser also keeps unrecognised key/value fields under `main.extra` and emits parser warnings such as missing main section or tab/container mismatch. The general lesson is useful for diagnostics: preserve evidence of source drift instead of silently dropping every unknown field.

### 4. Identity model is richer than the display number

A case-detail snapshot records:

- УИД;
- displayed case number;
- `case_id`;
- `case_uid`;
- `delo_id`;
- instance type;
- `vnkod` court code;
- source subdomain.

This independently supports Sudrf's #155 identity rule that the human-readable case number cannot be the primary identity.

### 5. `name_op=r_juid` is worth evaluating for discovery

The project separately parses the `name_op=r_juid` registry endpoint. Given a `judicial_uid`, it obtains the set of case rows tied to that UID, including court, case number, dates, judge, result and case URL.

At review time, repository search in Sudrf finds `r_juid` in captured HTML fixtures but not in production source. This endpoint should therefore be evaluated as an additional evidence source for:

- #87 higher-instance/background discovery;
- #94/#132 identity and changing production numbers;
- conservative reconstruction of the logical case graph.

It should not replace existing source-specific discovery until tested against real chains: shared/reused/missing UIDs and portal inconsistencies remain possible.

### 6. Retry handling has a useful small detail

The fetcher uses bounded connect/read timeouts, retries 408/429/5xx, exponential backoff and honours both forms of `Retry-After`.

Sudrf already has stronger actor-owned throttling/session/trust/CAPTCHA behavior. The reusable question is narrower: ensure every HTTP transport that can receive 429/503 deliberately handles `Retry-After` rather than immediately retrying on its own cadence.

## What not to reuse

### Raw positional JSON diff

`diff.py` recursively compares dictionaries and compares arrays by index. It ignores only `meta.fetched_at`.

This is exactly the failure mode #155 should avoid. If a court inserts an event at the top, reorders rows, reformats equivalent text or changes a source timestamp, a positional/field-level diff can produce a cascade of user-visible changes even though only one semantic event occurred.

Use this implementation as a negative reference: normalize and reconcile entities first, then emit typed semantic events.

### URL hash as persisted identity

Snapshots are stored under a SHA-1-derived ID of the watched URL. If the canonical URL changes while the underlying case is the same, the monitor starts a new baseline and history is split.

Sudrf should continue to persist source/case identity separately from navigation URLs.

### Saving every parseable HTTP-200 snapshot as authoritative

The runner correctly refuses non-2xx responses and parser exceptions, but after a successful parse it saves the new snapshot before interpreting changes. There is no strong page classifier/CAPTCHA/partial-state contract around that step.

A maintenance page or partial HTTP-200 response that happens to parse into an incomplete structure can therefore replace the last good baseline and create false removals on the next diff.

Sudrf's existing policy of retaining the last successful usable movement and merging partial higher-court results is safer and must be preserved in #155.

### Missing production hardening

At review time the repository has no visible test suite in its root tree. It also has no CAPTCHA flow, no per-host work scheduler/circuit breaker and no multi-source abstraction. It is a focused personal monitor, not a framework to port wholesale.

## Net effect on Sudrf decisions

This repository does **not** change the roadmap sequence or recommended stack. It strengthens four existing conclusions:

1. keep plain HTTP as the normal SUDRF transport;
2. keep content/header-driven parsing instead of hardcoded layout positions;
3. make #155 a semantic event layer, explicitly rejecting raw field-level diff;
4. investigate `r_juid` as an additional UID-based discovery/identity signal under #87 rather than creating a separate feature area.
