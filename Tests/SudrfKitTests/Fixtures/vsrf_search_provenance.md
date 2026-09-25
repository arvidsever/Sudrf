# VSRF search fixture provenance

Observed: 25 September 2026, in the official VSRF search page rendered in the in-app browser.

These are small, sanitized rendered-DOM fragments, not raw HTTP response bytes. The positive fragment records the observed result container, count, current card/link classes, `/lk/practice/claims/12-34154493` link, case number `3-КГ23-1-К3`, UID `11RS0001-01-2021-021221-14`, and first-instance fields. Public case identifiers are retained to verify that the parsed UID and card URL stay tied to the same production. Party names are replaced with generic labels. Decorative SVG, inline styling, and tooltip-only markup are omitted; suffixes on non-semantic CSS-module classes are normalized.

The empty fragment records the rendered `Найдено: 0` count and the official empty-state text `По Вашему запросу информация не найдена` for a deliberately non-matching UID query.

Source: [Supreme Court of the Russian Federation electronic search](https://www.vsrf.ru/lk/practice/claims).

SHA-256 (UTF-8 fixture bytes):

- `vsrf_current_search_positive.html`: `5c46de87ab644d4874cea88792f9c4318595e1a788332c225950632a5ac4c035`
- `vsrf_current_search_empty.html`: `8ee69017f13366509a1ec3a984a7b1f99a4778ddab89eacb9af46d455629835e`
