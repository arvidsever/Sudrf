# Issue 322 source fixtures

Observed on 25 September 2026. These are minimal, sanitized HTML excerpts
preserving the published fields needed by the parsers. They are **not** raw
byte-for-byte copies of the court responses; party details and unrelated page
chrome are omitted. The SHA-256 values below identify these committed excerpts,
not the remote pages.

| Fixture | Official source | SHA-256 |
|---|---|---|
| `issue322_asoy_2013.html` | https://1ap.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=6724440&case_uid=0cd448a3-5cf2-49bc-99c1-35bf0706c2d5&delo_id=42 | `7157cf335d5d3832f02357abd73544331907f1a5f29789b6b4847199c936afda` |
| `issue322_asoy_4311.html` | https://1ap.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=6749107&case_uid=6dc098e7-acb0-4b6b-b250-fcbb25479004&delo_id=42 | `f933f78a33aecbb6aabc3ae2eaeb77b12d33f1b703b528569740f637780a2db4` |
| `issue322_ksoyu_8501.html` | https://2kas.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=2723657&case_uid=576e5fae-ee46-434a-99eb-5956562963b0&new=0&delo_id=43 | `6657bb59b2f4e734f1dcea34a5dbf59db985fdcc96107bafffcfb8d8c2eedd7a` |
| `issue322_mgs_first.html` | https://mos-gorsud.ru/mgs/services/cases/first-admin/details/49e1e932-ca18-4a54-9797-987d15209322?caseNumber=3%D0%B0-3696/2020 | `d23c2a286c1a62ebea943085e8bae0153d159a7c460dca3ef1cba344627c84f7` |
| `issue322_mgs_appeal.html` | https://mos-gorsud.ru/mgs/services/cases/appeal-admin/details/b8390500-58cc-11ec-b06c-31916f371c35?uid=77RS0030-02-2021-008181-07&formType=fullForm | `61bf49f152809171abea2a8ab1961af96e05f85f60fb4e3fb507b7ceac65ad6b` |
| `issue322_mgs_hamov.html` | https://mos-gorsud.ru/rs/hamovnicheskij/services/cases/kas/details/1b274aa1-0cb0-11ec-a70f-232197c57890?uid=77RS0030-02-2021-008181-07&formType=fullForm | `d4bc4aaa1951f2de1b26f2c2ce36c7d3d2e7c063645f84dfc1162056f1cdec6a` |
| `issue322_mgs_search_first.html` | Moscow City Court search for `3а-3696/2020` in first-admin | `e427f8f6949735b8f8faac3a088138e3459f622165b691a441a3e5f0220447bc` |
| `issue322_mgs_search_uid.html` | Moscow portal search for `77RS0030-02-2021-008181-07` | `24d6e3bcab89ca147fd4c0167103090f3271ee0a8902b5b8c11a6e22d504c099` |

The two 1 ASOYu lower-court tabs name `3а-3696/2020`, Moscow City Court,
and judge Sevastyanova, but **do not publish a lower-court decision date**.
Their own decisions are dated 2 April and 10 September 2020. The Moscow
first-instance card independently lists appellate-ruling documents on both
dates. The 2019 case with the same number is a different registration and is
deliberately rejected by the tests.
