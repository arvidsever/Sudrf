# № 321 — provenance of `r_juid` fixtures

The files below are sanitized transcriptions of the official SUDRF result-table
DOMs inspected in a browser on 25 September 2026. The two `r_juid` result files
are sanitized transcriptions, not byte-for-byte captures: participant/detail
cells were replaced with `<стороны скрыты>`, while published court names, case
numbers, card links, dates, judges and outcomes were retained. The two card
fixtures are minimal sanitized reconstructions of only the confirmed case
number, judicial UID and published `r_juid` link; they are not claimed to be
transcriptions or byte captures. SHA-256 values identify committed fixture
bytes, not original responses.

- Saint Petersburg source query:
  <https://vos.spb.sudrf.ru/modules.php?name=sud_delo&name_op=r_juid&vnkod=78RS0001&srv_num=1&delo_id=1502001&case_type=0&judicial_uid=78RS0001-01-2026-002203-86>
  The table contains `12-538/2026` at Vasileostrovsky District Court and
  `12-1156/2026` at Kirovsky District Court. The latter card is published on
  `krv.spb.sudrf.ru`.
  Fixture: `issue321_rjuid_spb.html`
  SHA-256: `6c9c266ede0c32bf8f5028ef33dcdc1c47e1ab0702656c2522b9b0906374cf06`
- Komi source query:
  <https://uwsud.komi.sudrf.ru/modules.php?name=sud_delo&name_op=r_juid&vnkod=11RS0020&srv_num=1&delo_id=1502001&case_type=0&judicial_uid=11RS0020-01-2026-000655-63>
  The table contains `12-56/2026` at Ust-Vymsky District Court, then
  `12-461/2026` and `12-879/2026` at Syktyvkar City Court. The latter two
  cards are published on `syktsud.komi.sudrf.ru`.
  Fixture: `issue321_rjuid_komi.html`
  SHA-256: `a163a0a75b6d00312b67b23f95a331be6fe267ec7662b400ff08af3b18602abe`
- Confirmed Kirovsky card link, referenced by the Saint Petersburg UID listing:
  <https://krv.spb.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=984441524&case_uid=94fbe307-53f6-4f36-bf53-fd709a865d09&delo_id=1502001&case_type=0&new=0&srv_num=1>
  The inspected card's published UID listing link uses `vnkod=78RS0006` while
  the judicial UID begins `78RS0001`.
  Fixture: `issue321_card_kirov.html`
  SHA-256: `6fb9ec8fe7c6b0834142b2b17508133f8fc8567be0084590fc06672e87d80484`
- Confirmed Syktyvkar card link, referenced by the Komi UID listing:
  <https://syktsud.komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=38789069&case_uid=bd3a69d0-4f96-445c-93ca-26ac9d56cee8&delo_id=1502001&case_type=0&new=0&srv_num=1>
  The inspected card's published UID listing link uses `vnkod=11RS0001` while
  the judicial UID begins `11RS0020`.
  Fixture: `issue321_card_syktyvkar.html`
  SHA-256: `f12b429768b30478e6e5c461897694920ff8b4d68d82214971cea96ea295c53da`
