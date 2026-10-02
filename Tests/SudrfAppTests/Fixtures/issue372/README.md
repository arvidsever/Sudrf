# Issue 372 cassation fixtures

The seven source movements were received in `/private/tmp/sudrf372-cases.json` on 2 October 2026 (SHA-256 `195188ed6f8cd8197e6c499aa463e207c55381bb6dc8831a3377e3f395224358`). `issue372_movement_examples.json` contains only the listed case cards and event rows used by the regressions, plus relevant linked operative clauses. Public case categories and exact event/result wording are retained, with any party reference replaced by `[СТОРОНА]`. Party names, judges, participant records, and movement/source-evidence judicial UIDs were removed or replaced. Exact source card URLs remain verbatim, including query parameters, for provenance.

The source websites have since reset; their current contents have not been live-confirmed. The fixtures preserve the received copy and do not claim to describe current portal state.

Sanitized JSON SHA-256: `b581962118f55256b03377974b432a954de1d642544db08a780741fc0649a6ff`.

В этапе #222 добавлен собственный фрагмент кассационного акта `2а-11046/2024`: поступление в первую инстанцию 9 апреля 2025 года отличается от поступления в КСОЮ 22 апреля 2025 года. Дата окончательной формы в исходной копии не найдена; она не дописана.

Для части #222 возвращены собственная фраза о мотивированном определении 5 августа 2026 года и фраза о поступлении жалобы в первую инстанцию 9 апреля 2025 года. УИД заменены валидными синтетическими УИД с сохранением исходных связей внутри досье; это позволяет проверить существующий классификатор материалов без угадывания вида производства.
