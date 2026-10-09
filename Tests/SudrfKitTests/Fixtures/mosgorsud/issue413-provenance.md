# Issue 413 sanitized source fixtures

Both public Moscow City Court appeal cards were checked on 9 October 2026. The source URLs and capture window are also recorded in `Docs/qa/issue-413/README.md`.

| Appeal | Published source URL | Raw response-body SHA-256 | Sanitized fixture SHA-256 |
| --- | --- | --- | --- |
| 33-20562/2020 | `https://mos-gorsud.ru/mgs/services/cases/appeal-civil/details/fb4fa046-3e53-4806-91b2-ff52ddab9b8e` | `b5396ff91c52113127acab9e05a54f5ff01fdeb5acabe1d43b08364e5ced7883` | `369aabd99de449865c48355a3cdd760bd7d75371b23a12ac96e60ba1ace387b3` |
| 33-6416/2021 | `https://mos-gorsud.ru/mgs/services/cases/appeal-civil/details/15cd4120-69f1-11eb-983b-a36322a7831d` | `d397c7096db1e64eb7ec9213ff7b085ffe711d6133958b1b3100d931181b432f` | `4cc8dbf544bb78ac42e5f6f34e68f65d341e68e8380e69782d97d40545f44064` |

The saved transport metadata records separate UTC capture windows: `2026-10-09T06:26:05.365212Z`–`2026-10-09T06:26:07.018795Z` for 33-6416/2021 and `2026-10-09T06:29:50.349365Z`–`2026-10-09T06:29:52.190462Z` for 33-20562/2020. Per-card source hashes above are from the structural diagnostic. The private sanitized DOM excerpt SHA-256 is `22fb42b3dc0e146d74672d397a9e548601ee0d94e15f9676aafa35d5bc7c589f`.

Each fixture preserves the source order of the relevant published left/right labels and the Moscow City Court breadcrumb. The lower UID, lower registration number, lower court and lower judge are synthetic; the composition number is redacted. The intermediate breadcrumb labels are redacted. The separate constructed own-number DOM path was omitted because the published `Номер жалобы ~ дела` field carries the own number. CSS/style attributes, SVG icons, duplicate copy-widget nodes and other DOM attributes were omitted or flattened. These are selected source-derived excerpts, not byte-exact HTML or full-card fixtures. Raw responses and participant data are not included.
