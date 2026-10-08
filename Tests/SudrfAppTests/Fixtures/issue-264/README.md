# Historical tracked-store fixtures for issue #264

These SQLite stores contain synthetic records only (`*.invalid` hosts and
`Synthetic` case text). They were created by the app source at each historical
revision in isolated `/private/tmp` worktrees, then copied here unchanged. The
generator sources are retained as `.swift.txt` files because their model types
exist only at the corresponding historical revisions. They use explicit store
URLs and make no network calls.

| Fixture | Historical source | Schema |
| --- | --- | --- |
| `pre-uid-v0.38.0.store` | tag `v0.38.0`, commit `f0827a0664ddb35f4a52ab967b84e74c12ac074a` | Unversioned, 12-field `TrackedCaseRecord`; before `judicialUID` |
| `unversioned-v0.40.0.store` | tag `v0.40.0`, commit `531f92b6cf4cde05d1d091528b7a43a339082bba` | Unversioned, 13-field `TrackedCaseRecord`; after `judicialUID` |
| `v1-0.42.30.store` | tag `v0.42.30`, commit `913a6ad10b30194c4601b67a6bfd7eb8cca41c2a` | Historical versioned V1 |
| `v2-0.42.30.store` | tag `v0.42.30`, commit `913a6ad10b30194c4601b67a6bfd7eb8cca41c2a` | Historical versioned V2, including `CourtActRecord` |
| `v3-0.42.30.store` | tag `v0.42.30`, commit `913a6ad10b30194c4601b67a6bfd7eb8cca41c2a` | Historical versioned V3, including acts and summaries |

The V1/V2 schema plan was introduced by commit
`075ef3cb5dd3ee909f07ab9171e5c8aeeac87487`; the V0.42.30 tag is
the released source used to generate those two versioned stores. The released
V0.42.30 source also provides the actual V3 model declaration. Later V3–V6
transition coverage remains in `DataCatalogTests`, using their frozen schema
snapshots.

SHA-256 (fixture stores):

```text
9c619b4a9a9aae7c42aba5e4e9bc615350a8485445b58a1617ac00da008f2516  pre-uid-v0.38.0.store
fc50c329891e5c1d8af0d3c5afcb5b4e7c538d48f29bf31a02f3c237799567fa  unversioned-v0.40.0.store
be42d76e5696db1ece19061541f2a6a49ac0ec84c59b78c888171592b74ae670  v1-0.42.30.store
bf3c03b41cfd1dd3d847edf65eeae6ddf4e14022c13c4e7a9d6e323e215e78ea  v2-0.42.30.store
030046b6ad3e7d309e46a6dae37241ae6726634515156971a3ba036e35cbb5a6  v3-0.42.30.store
```

SHA-256 (generator sources):

```text
aeef131c99eba7587cfad0d8770b2261cd977faa5f1566f8125b67ca84256360  generate-preuid-v038.swift.txt
94930d8f03ac313da6b51bcf19c3d4740364597ac91c38f14c64bed8e3093b16  generate-unversioned-v040.swift.txt
ab3e0a7ef0d41205eeec67d6b9ab9d791bc5206f091dc42ce5aed5800918eabc  generate-versioned-v04230.swift.txt
```

Only the dedicated generator test ran at each historical revision, with an
explicit fixture URL under `/private/tmp/sudrf-historical-fixtures-264/`.
No historical app launch, default store, user defaults, or installed data was
opened. Original repository copyright and license notices remain governed by
the root `LICENSE.md` and `THIRD_PARTY_NOTICES.md`.
