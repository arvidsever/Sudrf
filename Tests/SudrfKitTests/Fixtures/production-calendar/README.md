# Production calendar parser fixtures

Minimal table-and-totals extracts captured on 9 September 2026 from:

- `consultant-2020b.html`: https://www.consultant.ru/law/ref/calendar/proizvodstvennye/2020b/ (raw SHA-256 `718665b4433ab6839f09469e2f0d3f4a7e255180d0f4ae3ad02e8284053f1328`)
- `consultant-2021.html`: https://www.consultant.ru/law/ref/calendar/proizvodstvennye/2021/ (raw SHA-256 `79a01aee86edb658267a3990cda32de7d1638f9e59a7c95c6ff37d0982808ad2`)
- `consultant-2024b.html`: https://www.consultant.ru/law/ref/calendar/proizvodstvennye/2024b/ (raw SHA-256 `5194ab080c2e63c7dc260455dc64a026c9c674666a4b45d284ee05aa054c6a56`)
- `consultant-2026.html`: https://www.consultant.ru/law/ref/calendar/proizvodstvennye/2026/ (raw SHA-256 `9e5787f70899055470fbfb9f41c13d45a3182fdbfba555351ed7c0333e31bc8d`)
- `consultant-2027-project.html`: https://www.consultant.ru/law/ref/calendar/proizvodstvennye/2027/ (raw SHA-256 `2755d46ec51cd775ac37d4a56fbf485f211ed884239225991af3ac728c9c77ed`)

The extracts preserve the original `h1`, all twelve calendar tables, monthly totals, and annual totals. They omit navigation and unrelated editorial text.

`consultant-2027.html` was extracted from the approved calendar received on
9 October 2026 at 15:02:51 UTC from the same exact 2027 URL (HTTP 200,
no redirect). Raw response SHA-256:
`f31ac571377f35fe57b36ba302931fa2a165958a09c56ecf7bb282263a1ec18b`.
Extract SHA-256:
`890f825bbceef667952bec502389905258e4c762d0db26140599c42aa62488cb`.
The earlier draft remains a negative fixture; approval is established separately
by the decree and normative verification recorded in `Docs/qa/federal-calendar-2027/`.
