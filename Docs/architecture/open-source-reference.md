# Open-source reference architecture for Sudrf

Status: architectural research note, 22.08.2026.

This note records the useful conclusions from a review of open-source court/scraping projects and maps them onto Sudrf's current architecture. It is not a migration plan and does not imply a replatform.

## Executive conclusion

Sudrf should remain a native Swift application with `SudrfKit` as the source/parsing core. The most valuable borrowed design is not a language/framework choice but a processing model:

`source adapter → normalized snapshot → identity/reconciliation → semantic diff → append-only event journal → projections`

The highest-value architectural addition is therefore a stable `CaseSnapshot → CaseEvent` layer. Feed, local notifications, Apple Calendar and future server push should consume the same semantic events rather than each comparing source data independently.

The current choices that should be preserved unless measured evidence says otherwise:

- Swift 6 / Swift Concurrency;
- SwiftUI for the macOS client;
- SwiftData for the current persistent store and migrations;
- `URLSession` + actor-owned throttling/cookies/trust handling;
- SwiftSoup for HTML parsing;
- source-specific clients for standard SUDRF, magistrates, VS RF and Moscow;
- CP1251 handling and Russian trust-chain support;
- local Vision/CoreML CAPTCHA solver with manual fallback;
- fixture-heavy regression testing around real court pages.

Do **not** introduce Selenium/Puppeteer, PostgreSQL, Redis, Celery or Elasticsearch into the desktop product merely because reference projects use them. They solve different deployment problems.

## Reference projects

### 1. freelawproject/juriscraper — strongest architecture reference

Repository: https://github.com/freelawproject/juriscraper

As of 22.08.2026 it is an active, mature BSD-2-Clause project with a long history and hundreds of stars/forks.

What it solves well:

- many heterogeneous court sites behind a common scraper contract;
- strict separation between scraping and persistence/application concerns;
- minimal duplication between site implementations;
- fixture-driven parser regression tests;
- browser automation only as an escalation path where plain HTTP is insufficient.

Design worth reusing:

- scraper/source adapters expose normalized data rather than UI-specific output;
- source-specific selectors stay inside adapters;
- persistence is not embedded in the scraper layer;
- fixture tests are a first-class contract.

Design not to copy literally:

- Python/lxml is not a reason to replace SwiftSoup or Swift;
- Juriscraper's domain model is US-court-specific and should not drive Russian procedural semantics.

Sudrf implication: keep `SudrfKit` independent of SwiftData/UI and make adapter + fixture discipline more explicit as new portal families are added.

### 2. AlexanderKuzikov/CourtSniffer — closest current Russian peer

Repository: https://github.com/AlexanderKuzikov/CourtSniffer

Created in July 2026; active in August 2026; Apache-2.0. TypeScript/Node with Puppeteer/RuCaptcha support.

What it has recently reverse-engineered usefully:

- official court `code` as a stable identity signal;
- source adapters dispatched through a registry;
- current SUDRF `delo_id`/portal variants;
- magistrate CAPTCHA behavior where waiting for navigation is incorrect and network-idle/session continuation matters;
- session cookies after CAPTCHA can permit subsequent requests without repeated challenges;
- narrower CAPTCHA detection is safer than broad page-text heuristics;
- CP1251 URL encoding remains relevant.

Design worth reusing:

- official court code as primary court identity where trustworthy;
- adapter registry / capabilities rather than a growing tree of `if source == ...`;
- ADR-style documentation of protocol quirks and decisions;
- explicit distinction between listing/search and detail enrichment.

Design to avoid:

- Puppeteer as the default transport;
- external paid CAPTCHA as the core UX;
- disabling TLS verification (`rejectUnauthorized: false`);
- weak test coverage around a fast-changing protocol;
- duplicated logic between adapters where a shared transport concern is identifiable.

Sudrf implication: use CourtSniffer as a live protocol/reference corpus, not as a stack blueprint.

### 3. tochno-st/sudrfscraper — strongest Russian breadth/corpus reference

Repository: https://github.com/tochno-st/sudrfscraper

Java/Spring Boot project covering first, appeal and cassation instances, including military courts. The repository was still maintained into late 2024 and its GitHub metadata remained active in 2026, but it has no declared GitHub license.

What it solves well:

- broad Russian court coverage;
- first/appellate/cassation search and extraction;
- a large collection of court/domain quirks;
- resume/export workflows;
- practical handling of CAPTCHA and sites that behave differently from foreign IPs.

Useful assets/ideas:

- court catalogues and mapping knowledge;
- legacy/VNKOD edge cases;
- empirical portal behavior and fixture candidates;
- operational knowledge about source instability.

Design to avoid:

- Spring desktop/web stack for a macOS-native application;
- Selenium as normal operation;
- dependency sprawl and mixed/duplicated library versions;
- copying code without resolving the undeclared-license problem.

Sudrf implication: treat it as a protocol/corpus oracle. Reimplement verified behavior in Sudrf's own tested adapters.

### 4. OlegSirik/sudrf-proxy — obsolete implementation, excellent monitoring model

Repository: https://github.com/OlegSirik/sudrf-proxy

The code is effectively abandoned (2019) and should not be reused. The conceptual product decomposition is still highly relevant:

1. keep a local court/source directory;
2. discover and store cases;
3. periodically refresh known case cards;
4. compare current data with the local copy;
5. retain and expose the latest changes.

This is the clearest historical analogue of what Sudrf is becoming.

Design worth reusing conceptually:

`discovery → local snapshot → refresh → diff → change feed`

Sudrf implication: formalize this around normalized `CaseSnapshot` and durable semantic `CaseEvent`, not raw HTML diffs.

### 5. dataout-org/sudrfparser — useful catalogue/regression oracle

Repository: https://github.com/dataout-org/sudrfparser

Python project with Selenium/BeautifulSoup/requests and 2Captcha integration. It claims coverage of more than two thousand court websites and remained active in 2026. Source comments identify CC-BY-SA 4.0 licensing, while GitHub metadata is less clear.

Value:

- broad court list;
- another independent parser to compare outputs against;
- useful regression cases when Sudrf and another implementation disagree.

Do not copy its architecture:

- large monolithic parser files;
- tight coupling of Selenium, HTTP, CAPTCHA and parsing;
- license ambiguity unless attribution/share-alike implications are deliberately accepted.

### 6. freelawproject/courtlistener — future backend scale reference only

Repository: https://github.com/freelawproject/courtlistener

Highly active production system. Uses Django/PostgreSQL, Redis, Celery, Elasticsearch and Selenium services.

What it demonstrates:

- ingestion and user-facing application can be separated;
- long-running refresh work belongs in queues/workers at server scale;
- search indexes and materialized projections become useful only after dataset/query volume justifies them;
- operational services need retry, diagnostics and independent health surfaces.

Do **not** copy this stack into the local MVP. It becomes relevant only if #149 grows into an always-on multi-user/server product.

### 7. zaebee/sudrf-bot — screened out

Repository: https://github.com/zaebee/sudrf-bot

Small 2020 parser/bot, no meaningful recent activity or license. No architectural advantage over the references above.

## Architecture decisions for Sudrf

### A. Keep transport, source parsing and procedural semantics separate

Transport responsibilities:

- HTTP and redirects;
- cookies/session continuity;
- TLS/trust policy;
- charset decoding;
- throttling and retry/backoff;
- CAPTCHA challenge/continuation state;
- host health/diagnostics.

Source-adapter responsibilities:

- URL/query construction;
- source-specific response classification;
- listing/detail parsing;
- source-native identifiers;
- normalization into shared models.

Domain responsibilities:

- instance/case identity reconciliation;
- lifecycle and stage interpretation;
- deadlines/rules/provenance;
- semantic change detection.

UI/projection responsibilities:

- feed;
- notifications;
- calendar;
- badges;
- Spotlight/deep links.

A parser should not decide that a textual row is a user notification. A View should not reconstruct legal lifecycle semantics from raw movement strings.

### B. Treat identity as a first-class model

Preferred hierarchy:

- court: official court code where available;
- source card/instance: reliable UИД, otherwise source-native ID scoped by court/source/cartoteka;
- logical case: graph/reconciliation across instance cards using official links/UIDs first and conservative matching only as fallback.

Never use the displayed case number as the sole database identity. Issues #94 and #132 already demonstrate why: a single production can acquire or expose multiple numbers over time.

### C. Make semantic events durable

Tracked refresh should converge on:

`old normalized snapshot + new normalized snapshot → CaseEvent[]`

The event vocabulary should be small, typed and legally meaningful. Candidate first set:

- instance discovered;
- hearing scheduled/rescheduled/cancelled;
- judge changed;
- status/result changed;
- judicial act published;
- entry into force recorded;
- complaint/transfer registered where confidently supported;
- deadline proposed/confirmed/changed/expired/superseded through #70.

Not every changed source string is an event. Cosmetic reordering, whitespace, source timestamps and equivalent wording should not notify users.

The event journal should be append-only from the user's perspective and have stable IDs. This avoids repeated notifications after relaunch or after presentation logic changes.

Primary implementation issue: #155.

### D. Keep SwiftData unless it becomes a measured bottleneck

Sudrf already has migrations, reconciliation logic and persistent user data around SwiftData. Replacing it now adds risk without solving the primary architectural problem.

Add logical persistence concepts before changing the database technology:

- last normalized/source snapshot;
- append-only event journal;
- refresh attempt/provenance/diagnostic records where useful.

Reconsider GRDB or a server database only after a measured workload demonstrates a SwiftData limitation.

### E. Improve refresh scheduling after correctness is stable

Current per-host throttling, in-flight deduplication and preservation of last successful state are good foundations.

A later scheduler can prioritize by:

- proximity of next hearing/deadline;
- recent changes;
- expectation of a new higher instance;
- previous failure/partial state;
- source TTL;
- recent user access.

Use exponential backoff + jitter and a host circuit-breaker for repeated external failures. Do not mark an unsuccessful/partial refresh as fully fresh if doing so suppresses discovery (#87).

### F. Two-level fixture discipline

For every important portal family maintain:

1. `response/HTML fixture → normalized snapshot`;
2. `old snapshot + new snapshot → expected semantic events`.

Keep a permanent pathology corpus for:

- CP1251;
- alternate/canonical hosts;
- CAPTCHA and post-CAPTCHA continuation;
- maintenance/HTTP-200 error pages;
- honest zero-results vs unknown pages;
- duplicate rows;
- missing or unstable UIDs;
- changing production numbers;
- partial KSOYU cards;
- stale links;
- Moscow/non-standard magistrate sources.

This complements #65: live canary detects external drift; fixtures prevent regression after adapting to it.

## Mapping to current issues

| Architectural concern | Existing issue(s) | Integration decision |
| --- | --- | --- |
| Semantic change pipeline | #155 | New umbrella/core issue |
| Explainable deadline rules | #70, #56, #111, #125, #128, #129 | Rules produce/provenance domain events; do not implement a parallel feed model |
| Background refresh/discovery | #87 | Must produce identical events whether refresh is periodic or manual |
| CAPTCHA/partial state | #82, #88, #89 | Partial/error state must not create false cancel/delete events |
| Source health | #68 | Diagnostics explain refresh attempts; they are not user case events |
| Live portal drift | #65 | Canary + raw artifacts feed the fixture corpus |
| Apple Calendar | #148 | Projection of stable Sudrf events; no separate diff engine |
| Server monitoring/APNs | #149 | Depend on #155 contract; backend must reproduce/consume same event semantics |
| Enforcement | #113, #150 | Later source/event family under the same monitoring model |
| New source families | #106, #107, #108 | Add adapters/capabilities; do not leak source branching into UI |
| KSOYU renumbering/identity | #94, #132 | Explicit evidence that display number cannot be primary identity |

## Recommended development sequence

1. Finish current correctness work that supplies reliable normalized inputs and regression cases.
2. Define identity contracts and source capabilities explicitly.
3. Implement #155 in shadow mode: persist snapshots/events while current feed remains authoritative.
4. Compare shadow events against existing feed on real tracked cases; build negative fixtures from discrepancies.
5. Make the event journal authoritative for feed/local notifications/badges.
6. Connect #70 deadline lifecycle to the same event model.
7. Build #148 as an event projection.
8. Improve adaptive refresh/source health/canary around the now-stable contract.
9. Add new court/source families behind adapters.
10. Only then build #149 if always-on monitoring is still required. The server should reuse the event contract rather than define a second notion of “change”.

## What to avoid

- replatforming the working native client to Python/Node/Java;
- browser automation for normal `sud_delo` pages;
- disabling TLS verification to make broken court sites “work”;
- treating CAPTCHA/error/unknown HTML as `0 results`;
- using case number as identity;
- deriving feed, calendar and server notifications independently;
- notification IDs based on presentation strings;
- replacing the persistence stack before measuring a real limitation;
- Elasticsearch/Redis/queue infrastructure before a server-scale workload exists;
- LLM/AI in the critical path for procedural status or deadline calculation.

## Bottom line

The useful combination is:

- **current Sudrf Swift architecture** for the product and transport;
- **Juriscraper** for adapter/fixture discipline;
- **CourtSniffer** for current SUDRF protocol details and adapter registry ideas;
- **sudrfscraper / sudrfparser** as Russian portal/corpus oracles;
- **sudrf-proxy** for the monitoring mental model;
- **CourtListener** only as a future scale reference.

The next architectural investment is not a new framework. It is one trustworthy pipeline from normalized court state to durable semantic events.
