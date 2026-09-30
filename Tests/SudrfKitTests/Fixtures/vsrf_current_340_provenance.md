# VSRF current-page fixtures for #340

Captured on 30 September 2026 from the official Supreme Court of the Russian Federation electronic case service, using the `VSRFClient` Safari 17 user agent.

- Search: [official VSRF search](https://www.vsrf.ru/lk/practice/claims?registerDateExact=off&considerationDateExact=off&numberExact=true&uniqueNumber=11OS0000-01-2025-000169-68). The request to `vsrf.ru` redirected to `www.vsrf.ru`; the final response was HTTP 200 at 14:03:25 UTC and contained 209,360 bytes. Raw response SHA-256: `0b29060a430f72f3c38fc054ca6374b152d3d75f18c2125268b0de8f0bf1966f`.
- Card: [official VSRF card](https://www.vsrf.ru/lk/practice/claims/12-36321243). Raw response size: 186,370 bytes. Raw response SHA-256: `746fe45e534124b1678659a7e4f52f1eb91746e5f685f675ae34b808dc281b7a`.

The fixtures contain the source DOM subtree for the result and card. Their element hierarchy, CSS-module classes, card ID, event labels, event details, published dates, the visible publication timestamp `16.09.2025 16:24`, and final act text are preserved. Page head, footer, scripts, inline styles, and unrelated attributes are omitted. Participant names, the lower-court name and judge, and the claim subject are fictionalized. The fixture UID is `11OS0000-01-2025-000169-68`; retained production numbers are `3-ИКАД25-3-А2` and `3а-85/2025`.

Sanitized fixture SHA-256:

- `vsrf_current_card_340.html`: `497ed7d8fd9fe83e76377cac3dc955bd5be52268a47cc7358b050b9f136ebd6a`
- `vsrf_current_search_340.html`: `cd23deb20c01b65a14f7cf36c1407b2e9554ca43c7c8fbf528da195956c6aad4`
