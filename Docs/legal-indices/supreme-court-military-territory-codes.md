# Территориальные индексы военных судов в номерах Верховного Суда РФ

Версия 1.0 · проверка 12 сентября 2026 года · дополнение к общему справочнику 1.5

**Результат:** по официальным карточкам Верховного Суда РФ восстановлены все девять значений серии **221–229**. Каждая строка подтверждена собственной карточкой, а не получена продолжением последовательности. Для большинства кодов основной контрольный пример один; примеры 223 и 226 дополнительно сопоставлены в разных контекстах. Это подтверждённые наблюдаемые соответствия, но не дословно восстановленное отсутствующее нормативное приложение.

### А. Нормативный смысл

В приложенной инструкции ВС РФ, п. 3.5.2, сноска 27, PDF-страница 41 (`ТЕКСТ Инстр ИТОГ.pdf`, источник `I-VS32P`) сказано:

> Для Судебной коллегии по делам военнослужащих территориальное деление определяется по территориальной юрисдикции окружных (флотских) военных судов.

Таким образом, первый блок — **индекс военной судебной территории**, а не субъект РФ, город размещения здания, номер гарнизонного суда или территориальный код УИД. Сами цифровые соответствия ниже восстановлены по веб-источникам; сноска устанавливает вид классификации, но не содержит чисел 221–229.

### Б. Подтверждённый словарь

| Индекс ВС РФ | Окружной / флотский военный суд | Контрольный номер ВС РФ | Поступление в ВС РФ |
|---|---|---|---|
| **`221`** | 1-й Западный окружной военный суд | [`221-УД25-11-А6`](https://vsrf.ru/lk/practice/cases/17-36246841) | 2025-08-11 |
| **`222`** | 2-й Западный окружной военный суд | [`222-УД25-20-А6`](https://vsrf.ru/lk/practice/cases/17-36130348) | 2025-06-04 |
| **`223`** | Центральный окружной военный суд | [`223-УД25-5-А6`](https://vsrf.ru/lk/practice/cases/17-35854787) | 2025-02-05 |
| **`224`** | Южный окружной военный суд | [`224-УД25-10-А6`](https://vsrf.ru/lk/practice/cases/17-35952655) | 2025-03-12 |
| **`225`** | 1-й Восточный окружной военный суд | [`225-УД25-2-А6`](https://vsrf.ru/lk/practice/cases/17-35952497) | 2025-03-12 |
| **`226`** | 2-й Восточный окружной военный суд | [`226-УД25-1-А6`](https://vsrf.ru/lk/practice/cases/17-35953327) | 2025-03-12 |
| **`227`** | Северный флотский военный суд | [`227-УД25-10-А6`](https://vsrf.ru/lk/practice/cases/17-36478967) | 2025-11-26 |
| **`228`** | Тихоокеанский флотский военный суд | [`228-УД26-3-А6`](https://vsrf.ru/lk/practice/cases/17-36939669) | 2026-06-11 |
| **`229`** | Балтийский флотский военный суд | [`229-УД26-1-А6`](https://vsrf.ru/lk/practice/cases/17-36727516) | 2026-03-17 |

### В. Почему код нельзя превращать в точный суд первой инстанции

**223.** Сопоставлены три разных контекста:

| Номер | Опубликованный суд первой инстанции | Что проверено |
|---|---|---|
| [`223-УД25-5-А6`](https://vsrf.ru/lk/practice/cases/17-35854787) | Центральный окружной военный суд (г. Екатеринбург) | Основная пара для кода 223. |
| [`223-УД25-26-А6`](https://vsrf.ru/lk/practice/cases/17-36295113) | Центральный окружной военный суд, ПСП в Самаре | Другое место рассмотрения внутри того же суда не меняет код. |
| [`223-КАД25-2-К10`](https://vsrf.ru/lk/practice/cases/12-35820087) | Саратовский ГВС, дело `2а-22/2024` | Код 223 встречается и тогда, когда первая инстанция — гарнизонный, а не сам окружной суд. |

Последняя карточка прочитана через поисковый индекс официального сайта; прямое открытие вернуло `cache miss`. В ней также видна жалоба `223-КАС24-74-К10`. Это одна цепочка, а не два независимых подтверждения.

**226.** У [`226-УД25-1-А6`](https://vsrf.ru/lk/practice/cases/17-35953327) указан 2-й Восточный окружной военный суд в Чите, у [`226-УД25-2-А6`](https://vsrf.ru/lk/practice/cases/17-35983025) — тот же суд, ПСП в Новосибирске. Индекс не кодирует регион расположения конкретного зала заседания.

**Начало и конец номера — разные поля.** `223-…-А6` и `223-…-К10` относятся к одной военной судебной территории, но содержат разные суффиксы суда предшествующего маршрута. Не следует включать А6/К10 в таблицу первой числовой группы. Сам территориальный индекс не устанавливает ни текущую стадию ВС РФ, ни следующий суд обжалования.

### Г. Исторические номера: не присваивать современные значения задним числом

В официальном извлечении определения Военной коллегии ВС РФ от 15.07.2010 № [`201-О10-10`](https://www.vsrf.ru/files/13548/) назван Московский окружной военный суд. Но в официальной карточке [`201-Н13-49СС`](https://vsrf.ru/lk/practice/cases/5591660), поступившей 11.12.2013, первой инстанцией названа Военная коллегия Верховного Суда СССР, приговор 22.02.1939. Вторая пара прочитана через поисковый индекс официальной карточки.

Это **два исторических наблюдения, не строка универсального словаря `201 → Московский`**. Тем более они не разрешают заменять 201 на 222 или применять к старому номеру современную таблицу 221–229. Полная история кодов, переименований и границы интервалов их применения пока не восстановлены. Исторический номер вне новой серии не считается ошибкой.

### Д. Контракт для приложения

Ключ должен включать пространство имён `supreme_military_territorial_index`. Использовать таблицу можно лишь после установления контекста ВС РФ, военной коллегии и соответствующего семейства номера.

Возвращаемое значение — `militaryTerritorialCourt`, то есть окружной/флотский суд, по юрисдикции которого определена территория. Отдельно хранятся опубликованные `firstInstanceCourt`, `currentCourt`, субъект РФ и суффикс `А…/К…`. Никакое из этих полей не перезаписывается результатом расшифровки начального кода.

Неизвестный префикс сохраняется как неизвестный или исторический. Отсутствие его в таблице не означает неправильный номер и не является основанием скрывать карточку. У всех девяти строк `effectiveFrom` и `effectiveTo` оставлены `null`: дата найденной регистрации не является доказательством начала действия кода. Номер не пересоздаётся из предполагаемого округа.

### Е. Источники и проверка

Для нового словаря использованы 12 современных официальных карточек: девять основных и три контекстных. Отдельно приведены одна историческая карточка и одно официальное извлечение судебного акта. Наиболее узко подтверждённое значение — пара «числовой префикс + конкретный опубликованный окружной/флотский суд»; эта пара, её дата и ссылка сохранены в JSON.

Выполнены **28 автономных проверок** таблицы и контекстного извлечения начального блока. Они проверяют программное поведение эталонной функции, а не юридическую полноту и не код приложения Sudrf. Текст нормативного приложения с числовой таблицей по-прежнему не получен. Репозиторий не читался и не изменялся.

## Машиночитаемый словарь и источники

```json
{
  "schemaVersion": "1.0",
  "artifactDate": "2026-09-12",
  "title": "Территориальные индексы военных судебных территорий в номерах Верховного Суда РФ",
  "instructionSource": {
    "id": "I-VS32P",
    "scope": "Делопроизводство в Верховном Суде Российской Федерации",
    "filename": "ТЕКСТ Инстр ИТОГ.pdf",
    "orderDate": "2015-05-08",
    "orderNumber": "32-П",
    "latestAmendmentListedInPDF": {
      "date": "2026-06-08",
      "number": "43-П"
    },
    "pdfPages": 99,
    "sha256": "70f0e96fef8381fd87308abf9da6182b28bd41505adaa007492996e0d10b3b6a",
    "effectiveFrom": null,
    "effectiveTo": null,
    "verifiedScope": "supplied_pdf_body_with_appendices_title_only_not_a_claim_of_latest_law",
    "missingAppendices": [
      "37",
      "38",
      "38-А",
      "38-Б",
      "39",
      "39-А",
      "40"
    ],
    "sourceVersionEvidence": "Титульный лист, PDF1; метаданные созданы10.06.2026, не самостоятельная дата юридического действия."
  },
  "militaryTerritorialIndices": {
    "version": "1.0",
    "verifiedOn": "2026-09-12",
    "title": "Территориальные индексы военных судебных территорий в номерах Верховного Суда РФ",
    "scope": "Девять наблюдаемых соответствий современной серии 221–229; исторические коды не исчерпаны.",
    "namespace": "supreme_military_territorial_index",
    "normativeBasis": {
      "sourceId": "I-VS32P",
      "provision": "п. 3.5.2, сноска 27",
      "pdfPage": 41,
      "quote": "Для Судебной коллегии по делам военнослужащих территориальное деление определяется по территориальной юрисдикции окружных (флотских) военных судов.",
      "whatThisEstablishes": "Тип территориального деления, а не числовые значения 221–229."
    },
    "notANormativeAnnexReproduction": true,
    "status": "official_case_card_reconstruction",
    "runtimeActivated": false,
    "records": [
      {
        "code": "221",
        "namespace": "supreme_military_territorial_index",
        "militaryTerritorialCourt": "1-й Западный окружной военный суд",
        "semanticRole": "territorial_jurisdiction_of_circuit_or_fleet_military_court",
        "status": "confirmed_official_observation",
        "evidenceSourceIds": [
          "VS-MIL-TERR-221"
        ],
        "exampleNumber": "221-УД25-11-А6",
        "exampleRegistrationDate": "2025-08-11",
        "normativeAnnexRowVerified": false,
        "effectiveFrom": null,
        "effectiveTo": null,
        "usableAs": "military_judicial_territory_hint_with_explicit_namespace",
        "mayOverridePublishedCourt": false,
        "mayInferExactGarrisonCourt": false,
        "mayInferFederalSubject": false,
        "mayInferCurrentReviewCourt": false,
        "mayInferNextAppealCourt": false,
        "runtimeActivated": false
      },
      {
        "code": "222",
        "namespace": "supreme_military_territorial_index",
        "militaryTerritorialCourt": "2-й Западный окружной военный суд",
        "semanticRole": "territorial_jurisdiction_of_circuit_or_fleet_military_court",
        "status": "confirmed_official_observation",
        "evidenceSourceIds": [
          "VS-MIL-TERR-222"
        ],
        "exampleNumber": "222-УД25-20-А6",
        "exampleRegistrationDate": "2025-06-04",
        "normativeAnnexRowVerified": false,
        "effectiveFrom": null,
        "effectiveTo": null,
        "usableAs": "military_judicial_territory_hint_with_explicit_namespace",
        "mayOverridePublishedCourt": false,
        "mayInferExactGarrisonCourt": false,
        "mayInferFederalSubject": false,
        "mayInferCurrentReviewCourt": false,
        "mayInferNextAppealCourt": false,
        "runtimeActivated": false
      },
      {
        "code": "223",
        "namespace": "supreme_military_territorial_index",
        "militaryTerritorialCourt": "Центральный окружной военный суд",
        "semanticRole": "territorial_jurisdiction_of_circuit_or_fleet_military_court",
        "status": "confirmed_official_observation",
        "evidenceSourceIds": [
          "VS-MIL-TERR-223",
          "VS-TERR-MILITARY-223-SAMARA",
          "VS-MIL-TERR-223-GARRISON"
        ],
        "exampleNumber": "223-УД25-5-А6",
        "exampleRegistrationDate": "2025-02-05",
        "normativeAnnexRowVerified": false,
        "effectiveFrom": null,
        "effectiveTo": null,
        "usableAs": "military_judicial_territory_hint_with_explicit_namespace",
        "mayOverridePublishedCourt": false,
        "mayInferExactGarrisonCourt": false,
        "mayInferFederalSubject": false,
        "mayInferCurrentReviewCourt": false,
        "mayInferNextAppealCourt": false,
        "runtimeActivated": false
      },
      {
        "code": "224",
        "namespace": "supreme_military_territorial_index",
        "militaryTerritorialCourt": "Южный окружной военный суд",
        "semanticRole": "territorial_jurisdiction_of_circuit_or_fleet_military_court",
        "status": "confirmed_official_observation",
        "evidenceSourceIds": [
          "VS-MIL-TERR-224"
        ],
        "exampleNumber": "224-УД25-10-А6",
        "exampleRegistrationDate": "2025-03-12",
        "normativeAnnexRowVerified": false,
        "effectiveFrom": null,
        "effectiveTo": null,
        "usableAs": "military_judicial_territory_hint_with_explicit_namespace",
        "mayOverridePublishedCourt": false,
        "mayInferExactGarrisonCourt": false,
        "mayInferFederalSubject": false,
        "mayInferCurrentReviewCourt": false,
        "mayInferNextAppealCourt": false,
        "runtimeActivated": false
      },
      {
        "code": "225",
        "namespace": "supreme_military_territorial_index",
        "militaryTerritorialCourt": "1-й Восточный окружной военный суд",
        "semanticRole": "territorial_jurisdiction_of_circuit_or_fleet_military_court",
        "status": "confirmed_official_observation",
        "evidenceSourceIds": [
          "VS-MIL-TERR-225"
        ],
        "exampleNumber": "225-УД25-2-А6",
        "exampleRegistrationDate": "2025-03-12",
        "normativeAnnexRowVerified": false,
        "effectiveFrom": null,
        "effectiveTo": null,
        "usableAs": "military_judicial_territory_hint_with_explicit_namespace",
        "mayOverridePublishedCourt": false,
        "mayInferExactGarrisonCourt": false,
        "mayInferFederalSubject": false,
        "mayInferCurrentReviewCourt": false,
        "mayInferNextAppealCourt": false,
        "runtimeActivated": false
      },
      {
        "code": "226",
        "namespace": "supreme_military_territorial_index",
        "militaryTerritorialCourt": "2-й Восточный окружной военный суд",
        "semanticRole": "territorial_jurisdiction_of_circuit_or_fleet_military_court",
        "status": "confirmed_official_observation",
        "evidenceSourceIds": [
          "VS-MIL-TERR-226",
          "VS-MIL-TERR-226-NOVOSIBIRSK"
        ],
        "exampleNumber": "226-УД25-1-А6",
        "exampleRegistrationDate": "2025-03-12",
        "normativeAnnexRowVerified": false,
        "effectiveFrom": null,
        "effectiveTo": null,
        "usableAs": "military_judicial_territory_hint_with_explicit_namespace",
        "mayOverridePublishedCourt": false,
        "mayInferExactGarrisonCourt": false,
        "mayInferFederalSubject": false,
        "mayInferCurrentReviewCourt": false,
        "mayInferNextAppealCourt": false,
        "runtimeActivated": false
      },
      {
        "code": "227",
        "namespace": "supreme_military_territorial_index",
        "militaryTerritorialCourt": "Северный флотский военный суд",
        "semanticRole": "territorial_jurisdiction_of_circuit_or_fleet_military_court",
        "status": "confirmed_official_observation",
        "evidenceSourceIds": [
          "VS-MIL-TERR-227"
        ],
        "exampleNumber": "227-УД25-10-А6",
        "exampleRegistrationDate": "2025-11-26",
        "normativeAnnexRowVerified": false,
        "effectiveFrom": null,
        "effectiveTo": null,
        "usableAs": "military_judicial_territory_hint_with_explicit_namespace",
        "mayOverridePublishedCourt": false,
        "mayInferExactGarrisonCourt": false,
        "mayInferFederalSubject": false,
        "mayInferCurrentReviewCourt": false,
        "mayInferNextAppealCourt": false,
        "runtimeActivated": false
      },
      {
        "code": "228",
        "namespace": "supreme_military_territorial_index",
        "militaryTerritorialCourt": "Тихоокеанский флотский военный суд",
        "semanticRole": "territorial_jurisdiction_of_circuit_or_fleet_military_court",
        "status": "confirmed_official_observation",
        "evidenceSourceIds": [
          "VS-MIL-TERR-228"
        ],
        "exampleNumber": "228-УД26-3-А6",
        "exampleRegistrationDate": "2026-06-11",
        "normativeAnnexRowVerified": false,
        "effectiveFrom": null,
        "effectiveTo": null,
        "usableAs": "military_judicial_territory_hint_with_explicit_namespace",
        "mayOverridePublishedCourt": false,
        "mayInferExactGarrisonCourt": false,
        "mayInferFederalSubject": false,
        "mayInferCurrentReviewCourt": false,
        "mayInferNextAppealCourt": false,
        "runtimeActivated": false
      },
      {
        "code": "229",
        "namespace": "supreme_military_territorial_index",
        "militaryTerritorialCourt": "Балтийский флотский военный суд",
        "semanticRole": "territorial_jurisdiction_of_circuit_or_fleet_military_court",
        "status": "confirmed_official_observation",
        "evidenceSourceIds": [
          "VS-MIL-TERR-229"
        ],
        "exampleNumber": "229-УД26-1-А6",
        "exampleRegistrationDate": "2026-03-17",
        "normativeAnnexRowVerified": false,
        "effectiveFrom": null,
        "effectiveTo": null,
        "usableAs": "military_judicial_territory_hint_with_explicit_namespace",
        "mayOverridePublishedCourt": false,
        "mayInferExactGarrisonCourt": false,
        "mayInferFederalSubject": false,
        "mayInferCurrentReviewCourt": false,
        "mayInferNextAppealCourt": false,
        "runtimeActivated": false
      }
    ],
    "sourceIds": [
      "VS-MIL-TERR-221",
      "VS-MIL-TERR-222",
      "VS-MIL-TERR-223",
      "VS-MIL-TERR-224",
      "VS-MIL-TERR-225",
      "VS-MIL-TERR-226",
      "VS-MIL-TERR-227",
      "VS-MIL-TERR-228",
      "VS-MIL-TERR-229",
      "VS-TERR-MILITARY-223-SAMARA",
      "VS-MIL-TERR-226-NOVOSIBIRSK",
      "VS-MIL-TERR-223-GARRISON",
      "VS-MIL-HIST-201-O10",
      "VS-MIL-HIST-201-SSR"
    ],
    "contextObservations": [
      {
        "id": "mil-223-not-a-region",
        "sourceIds": [
          "VS-MIL-TERR-223",
          "VS-TERR-MILITARY-223-SAMARA",
          "VS-MIL-TERR-223-GARRISON"
        ],
        "finding": "223 подтверждён у Центрального окружного суда в Екатеринбурге, его ПСП в Самаре и дела Саратовского гарнизонного военного суда. Регион здания и точный суд первой инстанции не выводятся из кода."
      },
      {
        "id": "mil-226-not-a-building",
        "sourceIds": [
          "VS-MIL-TERR-226",
          "VS-MIL-TERR-226-NOVOSIBIRSK"
        ],
        "finding": "226 сохраняется у 2-го Восточного суда в Чите и его ПСП в Новосибирске."
      },
      {
        "id": "mil-prefix-vs-suffix",
        "sourceIds": [
          "VS-MIL-TERR-223",
          "VS-MIL-TERR-223-GARRISON"
        ],
        "finding": "223 встречается с А6 и К10; начальный территориальный код и конечный судебный суффикс — независимые поля."
      }
    ],
    "historicalObservations": [
      {
        "rawPrefix": "201",
        "number": "201-О10-10",
        "sourceId": "VS-MIL-HIST-201-O10",
        "courtAsPublished": "Московский окружной военный суд",
        "observationDate": "2010-07-15",
        "isGlobalMapping": false
      },
      {
        "rawPrefix": "201",
        "number": "201-Н13-49СС",
        "sourceId": "VS-MIL-HIST-201-SSR",
        "courtAsPublished": "Военная коллегия Верховного Суда СССР",
        "observationDate": "2013-12-11",
        "isGlobalMapping": false
      }
    ],
    "parserContract": {
      "requires": {
        "court": "Верховный Суд РФ",
        "chamber": "Судебная коллегия по делам военнослужащих",
        "numberForm": "territorial_collegium"
      },
      "extraction": "Числовой блок перед первым дефисом после допустимой нормализации внешнего оформления.",
      "lookup": "Только явная таблица 221–229, без арифметического достраивания.",
      "outputFields": [
        "rawNumber",
        "firstNumericBlock",
        "namespace",
        "militaryTerritorialCourt",
        "evidenceSourceIds",
        "mappingStatus"
      ],
      "separateFields": [
        "publishedFirstInstanceCourt",
        "currentCourt",
        "federalSubject",
        "reviewCourtSuffix",
        "nextAppealCourt"
      ],
      "unknownPolicy": "Сохранить неизвестный/исторический номер, не считать его ошибкой и не переписывать.",
      "mayOverridePublishedCourt": false,
      "effectiveDatePolicy": "Дата примера подтверждает наблюдение, а не начало или конец действия кода; интервалы действия остаются null.",
      "noInferenceFromArmyDistrictName": true,
      "noInferenceForPresidiumOrEconomicFormats": true
    },
    "tests": [
      {
        "id": "mil-prefix-221",
        "input": "221-УД25-11-А6",
        "expectedStatus": "observed_mapping",
        "expectedCode": "221",
        "passed": true
      },
      {
        "id": "mil-prefix-222",
        "input": "222-УД25-20-А6",
        "expectedStatus": "observed_mapping",
        "expectedCode": "222",
        "passed": true
      },
      {
        "id": "mil-prefix-223",
        "input": "223-УД25-5-А6",
        "expectedStatus": "observed_mapping",
        "expectedCode": "223",
        "passed": true
      },
      {
        "id": "mil-prefix-224",
        "input": "224-УД25-10-А6",
        "expectedStatus": "observed_mapping",
        "expectedCode": "224",
        "passed": true
      },
      {
        "id": "mil-prefix-225",
        "input": "225-УД25-2-А6",
        "expectedStatus": "observed_mapping",
        "expectedCode": "225",
        "passed": true
      },
      {
        "id": "mil-prefix-226",
        "input": "226-УД25-1-А6",
        "expectedStatus": "observed_mapping",
        "expectedCode": "226",
        "passed": true
      },
      {
        "id": "mil-prefix-227",
        "input": "227-УД25-10-А6",
        "expectedStatus": "observed_mapping",
        "expectedCode": "227",
        "passed": true
      },
      {
        "id": "mil-prefix-228",
        "input": "228-УД26-3-А6",
        "expectedStatus": "observed_mapping",
        "expectedCode": "228",
        "passed": true
      },
      {
        "id": "mil-prefix-229",
        "input": "229-УД26-1-А6",
        "expectedStatus": "observed_mapping",
        "expectedCode": "229",
        "passed": true
      },
      {
        "id": "mil-context-10",
        "input": "223-УД25-26-А6",
        "expectedStatus": "observed_mapping",
        "expectedCode": "223",
        "passed": true
      },
      {
        "id": "mil-context-11",
        "input": "226-УД25-2-А6",
        "expectedStatus": "observed_mapping",
        "expectedCode": "226",
        "passed": true
      },
      {
        "id": "mil-context-12",
        "input": "223-КАД25-2-К10",
        "expectedStatus": "observed_mapping",
        "expectedCode": "223",
        "passed": true
      },
      {
        "id": "mil-context-13",
        "input": "223-КАС24-74-К10",
        "expectedStatus": "observed_mapping",
        "expectedCode": "223",
        "passed": true
      },
      {
        "id": "mil-context-14",
        "input": "221-УН25-30-А6",
        "expectedStatus": "observed_mapping",
        "expectedCode": "221",
        "passed": true
      },
      {
        "id": "mil-normalize-15",
        "input": " № 223-КАД25-2-К10  ",
        "expectedStatus": "observed_mapping",
        "expectedCode": "223",
        "passed": true
      },
      {
        "id": "mil-normalize-16",
        "input": "223–КАД25–2–К10",
        "expectedStatus": "observed_mapping",
        "expectedCode": "223",
        "passed": true
      },
      {
        "id": "mil-normalize-17",
        "input": "223 - кад25-2-к10",
        "expectedStatus": "observed_mapping",
        "expectedCode": "223",
        "passed": true
      },
      {
        "id": "mil-negative-18",
        "input": "201-О10-10",
        "context": {},
        "expectedStatus": "unknown_or_historical",
        "expectedCode": "201",
        "passed": true
      },
      {
        "id": "mil-negative-19",
        "input": "201-Н13-49СС",
        "context": {},
        "expectedStatus": "unknown_or_historical",
        "expectedCode": "201",
        "passed": true
      },
      {
        "id": "mil-negative-20",
        "input": "230-УД26-1-А6",
        "context": {},
        "expectedStatus": "unknown_or_historical",
        "expectedCode": "230",
        "passed": true
      },
      {
        "id": "mil-negative-21",
        "input": "300-ЭС25-1",
        "context": {
          "chamber": "economic"
        },
        "expectedStatus": "not_applicable",
        "expectedCode": null,
        "passed": true
      },
      {
        "id": "mil-negative-22",
        "input": "25-ПВ15",
        "context": {
          "number_form": "presidium"
        },
        "expectedStatus": "not_applicable",
        "expectedCode": null,
        "passed": true
      },
      {
        "id": "mil-negative-23",
        "input": "3-КГ25-1-К3",
        "context": {
          "chamber": "civil"
        },
        "expectedStatus": "not_applicable",
        "expectedCode": null,
        "passed": true
      },
      {
        "id": "mil-negative-24",
        "input": "223-УД25-5-А6",
        "context": {
          "court": "garrison"
        },
        "expectedStatus": "not_applicable",
        "expectedCode": null,
        "passed": true
      },
      {
        "id": "mil-negative-25",
        "input": "223-УД25-5-А6",
        "context": {
          "chamber": "unknown"
        },
        "expectedStatus": "not_applicable",
        "expectedCode": null,
        "passed": true
      },
      {
        "id": "mil-negative-26",
        "input": "223",
        "context": {},
        "expectedStatus": "unrecognized_shape",
        "expectedCode": null,
        "passed": true
      },
      {
        "id": "mil-negative-27",
        "input": "2223-УД25-5-А6",
        "context": {},
        "expectedStatus": "unrecognized_shape",
        "expectedCode": null,
        "passed": true
      },
      {
        "id": "mil-negative-28",
        "input": "78OV0000-01-2025-000006-70",
        "context": {},
        "expectedStatus": "unrecognized_shape",
        "expectedCode": null,
        "passed": true
      }
    ],
    "audit": {
      "primaryMappings": 9,
      "primaryMappingsDirectlyRead": 9,
      "currentRegistrationCardSources": 12,
      "historicalRegistrationCardSources": 1,
      "historicalDecisionExcerptSources": 1,
      "primaryVerification": "Для каждого кода открыта официальная карточка и сопоставлены номер и явно названный суд. Для дополнительного гарнизонного примера и исторического реабилитационного примера использован поисковый индекс официальных страниц.",
      "missingAnnexNotRecovered": true,
      "historicalDictionaryComplete": false,
      "standaloneTestsExecuted": 28,
      "standaloneTestsPassed": 28,
      "testsAreSudrfTests": false,
      "repositoryReadDuringRevision": false,
      "repositoryChanged": false,
      "fullReferenceLegalReverification": false
    }
  },
  "sources": [
    {
      "id": "VS-MIL-TERR-221",
      "type": "official_supreme_court_registration_card",
      "publisher": "Верховный Суд Российской Федерации",
      "url": "https://vsrf.ru/lk/practice/cases/17-36246841",
      "checkedOn": "2026-09-12",
      "selectedRecordNumber": "221-УД25-11-А6",
      "recordRegistrationDate": "2025-08-11",
      "courtFieldName": "Суд 1-ой инстанции",
      "courtFieldValue": "1-й Западный окружной военный суд (г. Санкт-Петербург)",
      "lowerCourtCaseNumber": "2-14/2025",
      "lowerCourtDecisionDate": "2025-02-07",
      "publishedUID": "78OV0000-01-2025-000006-70",
      "verificationMethod": "official_card_opened_and_read",
      "verifiedScope": "Номер ВС РФ, его первая числовая группа, коллегия и явно опубликованный суд первой инстанции; без оценки виновности или существа дела.",
      "localPageSnapshotAvailable": false,
      "evidenceLevel": "official_published_application_not_normative_annex",
      "effectiveFrom": null,
      "effectiveTo": null
    },
    {
      "id": "VS-MIL-TERR-222",
      "type": "official_supreme_court_registration_card",
      "publisher": "Верховный Суд Российской Федерации",
      "url": "https://vsrf.ru/lk/practice/cases/17-36130348",
      "checkedOn": "2026-09-12",
      "selectedRecordNumber": "222-УД25-20-А6",
      "recordRegistrationDate": "2025-06-04",
      "courtFieldName": "Суд 1-ой инстанции",
      "courtFieldValue": "2-й Западный окружной военный суд (г. Москва)",
      "lowerCourtCaseNumber": "2-230/2024",
      "lowerCourtDecisionDate": "2024-11-14",
      "publishedUID": null,
      "verificationMethod": "official_card_opened_and_read",
      "verifiedScope": "Номер ВС РФ, его первая числовая группа, коллегия и явно опубликованный суд первой инстанции; без оценки виновности или существа дела.",
      "localPageSnapshotAvailable": false,
      "evidenceLevel": "official_published_application_not_normative_annex",
      "effectiveFrom": null,
      "effectiveTo": null
    },
    {
      "id": "VS-MIL-TERR-223",
      "type": "official_supreme_court_registration_card",
      "publisher": "Верховный Суд Российской Федерации",
      "url": "https://vsrf.ru/lk/practice/cases/17-35854787",
      "checkedOn": "2026-09-12",
      "selectedRecordNumber": "223-УД25-5-А6",
      "recordRegistrationDate": "2025-02-05",
      "courtFieldName": "Суд 1-ой инстанции",
      "courtFieldValue": "Центральный окружной военный суд (г. Екатеринбург)",
      "lowerCourtCaseNumber": "2-76/2024",
      "lowerCourtDecisionDate": "2024-06-18",
      "publishedUID": "66OV0001-01-2024-000017-74",
      "verificationMethod": "official_card_opened_and_read",
      "verifiedScope": "Номер ВС РФ, его первая числовая группа, коллегия и явно опубликованный суд первой инстанции; без оценки виновности или существа дела.",
      "localPageSnapshotAvailable": false,
      "evidenceLevel": "official_published_application_not_normative_annex",
      "effectiveFrom": null,
      "effectiveTo": null
    },
    {
      "id": "VS-MIL-TERR-224",
      "type": "official_supreme_court_registration_card",
      "publisher": "Верховный Суд Российской Федерации",
      "url": "https://vsrf.ru/lk/practice/cases/17-35952655",
      "checkedOn": "2026-09-12",
      "selectedRecordNumber": "224-УД25-10-А6",
      "recordRegistrationDate": "2025-03-12",
      "courtFieldName": "Суд 1-ой инстанции",
      "courtFieldValue": "Южный окружной военный суд (г. Ростов–на-Дону)",
      "lowerCourtCaseNumber": "2-214/2023",
      "lowerCourtDecisionDate": "2023-12-14",
      "publishedUID": "61OV0000-01-2023-000153-22",
      "verificationMethod": "official_card_opened_and_read",
      "verifiedScope": "Номер ВС РФ, его первая числовая группа, коллегия и явно опубликованный суд первой инстанции; без оценки виновности или существа дела.",
      "localPageSnapshotAvailable": false,
      "evidenceLevel": "official_published_application_not_normative_annex",
      "effectiveFrom": null,
      "effectiveTo": null
    },
    {
      "id": "VS-MIL-TERR-225",
      "type": "official_supreme_court_registration_card",
      "publisher": "Верховный Суд Российской Федерации",
      "url": "https://vsrf.ru/lk/practice/cases/17-35952497",
      "checkedOn": "2026-09-12",
      "selectedRecordNumber": "225-УД25-2-А6",
      "recordRegistrationDate": "2025-03-12",
      "courtFieldName": "Суд 1-ой инстанции",
      "courtFieldValue": "1-й Восточный окружной военный суд",
      "lowerCourtCaseNumber": "1-112/2023",
      "lowerCourtDecisionDate": "2023-10-25",
      "publishedUID": null,
      "verificationMethod": "official_card_opened_and_read",
      "verifiedScope": "Номер ВС РФ, его первая числовая группа, коллегия и явно опубликованный суд первой инстанции; без оценки виновности или существа дела.",
      "localPageSnapshotAvailable": false,
      "evidenceLevel": "official_published_application_not_normative_annex",
      "effectiveFrom": null,
      "effectiveTo": null
    },
    {
      "id": "VS-MIL-TERR-226",
      "type": "official_supreme_court_registration_card",
      "publisher": "Верховный Суд Российской Федерации",
      "url": "https://vsrf.ru/lk/practice/cases/17-35953327",
      "checkedOn": "2026-09-12",
      "selectedRecordNumber": "226-УД25-1-А6",
      "recordRegistrationDate": "2025-03-12",
      "courtFieldName": "Суд 1-ой инстанции",
      "courtFieldValue": "2-й Восточный окружной военный суд (г.Чита)",
      "lowerCourtCaseNumber": "1-26/2024",
      "lowerCourtDecisionDate": "2024-04-24",
      "publishedUID": "75OV0000-01-2024-000026-69",
      "verificationMethod": "official_card_opened_and_read",
      "verifiedScope": "Номер ВС РФ, его первая числовая группа, коллегия и явно опубликованный суд первой инстанции; без оценки виновности или существа дела.",
      "localPageSnapshotAvailable": false,
      "evidenceLevel": "official_published_application_not_normative_annex",
      "effectiveFrom": null,
      "effectiveTo": null
    },
    {
      "id": "VS-MIL-TERR-227",
      "type": "official_supreme_court_registration_card",
      "publisher": "Верховный Суд Российской Федерации",
      "url": "https://vsrf.ru/lk/practice/cases/17-36478967",
      "checkedOn": "2026-09-12",
      "selectedRecordNumber": "227-УД25-10-А6",
      "recordRegistrationDate": "2025-11-26",
      "courtFieldName": "Суд 1-ой инстанции",
      "courtFieldValue": "Северный флотский военный суд",
      "lowerCourtCaseNumber": "1-7/2025",
      "lowerCourtDecisionDate": "2025-04-10",
      "publishedUID": "51OV0000-01-2025-000011-51",
      "verificationMethod": "official_card_opened_and_read",
      "verifiedScope": "Номер ВС РФ, его первая числовая группа, коллегия и явно опубликованный суд первой инстанции; без оценки виновности или существа дела.",
      "localPageSnapshotAvailable": false,
      "evidenceLevel": "official_published_application_not_normative_annex",
      "effectiveFrom": null,
      "effectiveTo": null
    },
    {
      "id": "VS-MIL-TERR-228",
      "type": "official_supreme_court_registration_card",
      "publisher": "Верховный Суд Российской Федерации",
      "url": "https://vsrf.ru/lk/practice/cases/17-36939669",
      "checkedOn": "2026-09-12",
      "selectedRecordNumber": "228-УД26-3-А6",
      "recordRegistrationDate": "2026-06-11",
      "courtFieldName": "Суд 1-ой инстанции",
      "courtFieldValue": "Тихоокеанский флотский военный суд",
      "lowerCourtCaseNumber": "1-36/2025",
      "lowerCourtDecisionDate": "2025-10-13",
      "publishedUID": "25OV0000-01-2025-000046-14",
      "verificationMethod": "official_card_opened_and_read",
      "verifiedScope": "Номер ВС РФ, его первая числовая группа, коллегия и явно опубликованный суд первой инстанции; без оценки виновности или существа дела.",
      "localPageSnapshotAvailable": false,
      "evidenceLevel": "official_published_application_not_normative_annex",
      "effectiveFrom": null,
      "effectiveTo": null
    },
    {
      "id": "VS-MIL-TERR-229",
      "type": "official_supreme_court_registration_card",
      "publisher": "Верховный Суд Российской Федерации",
      "url": "https://vsrf.ru/lk/practice/cases/17-36727516",
      "checkedOn": "2026-09-12",
      "selectedRecordNumber": "229-УД26-1-А6",
      "recordRegistrationDate": "2026-03-17",
      "courtFieldName": "Суд 1-ой инстанции",
      "courtFieldValue": "Балтийский флотский военный суд",
      "lowerCourtCaseNumber": "2-2/2025",
      "lowerCourtDecisionDate": "2025-04-11",
      "publishedUID": null,
      "verificationMethod": "official_card_opened_and_read",
      "verifiedScope": "Номер ВС РФ, его первая числовая группа, коллегия и явно опубликованный суд первой инстанции; без оценки виновности или существа дела.",
      "localPageSnapshotAvailable": false,
      "evidenceLevel": "official_published_application_not_normative_annex",
      "effectiveFrom": null,
      "effectiveTo": null
    },
    {
      "id": "VS-TERR-MILITARY-223-SAMARA",
      "type": "official_supreme_court_registration_card",
      "url": "https://vsrf.ru/lk/practice/cases/17-36295113",
      "selectedRecordNumber": "223-УД25-26-А6",
      "recordRegistrationDate": "2025-09-03",
      "courtFieldValue": "Центральный окружной военный суд (ПСП в г.Самаре)",
      "lowerCourtCaseNumber": "2-167/2024",
      "lowerCourtDecisionDate": "2024-10-14",
      "verificationMethod": "official_card_opened_and_read",
      "verifiedScope": "Тот же код 223 у того же окружного суда при рассмотрении в ПСП в другом субъекте РФ.",
      "publisher": "Верховный Суд Российской Федерации",
      "checkedOn": "2026-09-12",
      "localPageSnapshotAvailable": false,
      "evidenceLevel": "official_published_application_not_normative_annex",
      "effectiveFrom": null,
      "effectiveTo": null,
      "courtFieldName": "Суд 1-ой инстанции"
    },
    {
      "id": "VS-MIL-TERR-226-NOVOSIBIRSK",
      "type": "official_supreme_court_registration_card",
      "url": "https://vsrf.ru/lk/practice/cases/17-35983025",
      "selectedRecordNumber": "226-УД25-2-А6",
      "recordRegistrationDate": "2025-03-26",
      "courtFieldValue": "2-й Восточный окружной военный суд (ПСП г.Новосибирск)",
      "lowerCourtCaseNumber": "1-32/2024",
      "lowerCourtDecisionDate": "2024-04-16",
      "verificationMethod": "official_card_opened_and_read",
      "verifiedScope": "Тот же код 226 у 2-го Восточного суда в Чите и его ПСП в Новосибирске.",
      "publisher": "Верховный Суд Российской Федерации",
      "checkedOn": "2026-09-12",
      "localPageSnapshotAvailable": false,
      "evidenceLevel": "official_published_application_not_normative_annex",
      "effectiveFrom": null,
      "effectiveTo": null,
      "courtFieldName": "Суд 1-ой инстанции"
    },
    {
      "id": "VS-MIL-TERR-223-GARRISON",
      "type": "official_supreme_court_registration_card",
      "url": "https://vsrf.ru/lk/practice/cases/12-35820087",
      "selectedRecordNumber": "223-КАД25-2-К10",
      "recordRegistrationDate": "2025-01-22",
      "relatedRecordNumbers": [
        "223-КАС24-74-К10"
      ],
      "courtFieldValue": "Саратовский ГВС",
      "lowerCourtCaseNumber": "2а-22/2024",
      "lowerCourtDecisionDate": "2024-03-21",
      "publishedReviewCourt": "Кассационный военный суд (г. Новосибирск)",
      "reviewDecisionDate": "2024-11-26",
      "verificationMethod": "web_search_index_of_official_case_card",
      "directOpenResult": "cache_miss",
      "verifiedScope": "Пара номер/суд прочитана в индексе официальной страницы; полная HTML-страница при прямом открытии недоступна. Номер 223 встречается при первой инстанции в гарнизонном суде, а также с К10, не только с А6.",
      "publisher": "Верховный Суд Российской Федерации",
      "checkedOn": "2026-09-12",
      "localPageSnapshotAvailable": false,
      "evidenceLevel": "official_published_application_not_normative_annex",
      "effectiveFrom": null,
      "effectiveTo": null,
      "courtFieldName": "Суд 1-ой инстанции"
    },
    {
      "id": "VS-MIL-HIST-201-O10",
      "type": "official_supreme_court_published_decision_excerpt",
      "url": "https://www.vsrf.ru/files/13548/",
      "selectedRecordNumber": "201-О10-10",
      "decisionDate": "2010-07-15",
      "courtFieldValue": "Московский окружной военный суд",
      "verificationMethod": "official_decision_excerpt_opened_and_read",
      "verifiedScope": "Историческое наблюдение: код 201 в определении от 15.07.2010 по приговору Московского окружного военного суда. Это не универсальная расшифровка 201.",
      "publisher": "Верховный Суд Российской Федерации",
      "checkedOn": "2026-09-12",
      "localPageSnapshotAvailable": false,
      "evidenceLevel": "official_published_application_not_normative_annex",
      "effectiveFrom": null,
      "effectiveTo": null
    },
    {
      "id": "VS-MIL-HIST-201-SSR",
      "type": "official_supreme_court_registration_card",
      "url": "https://vsrf.ru/lk/practice/cases/5591660",
      "selectedRecordNumber": "201-Н13-49СС",
      "recordRegistrationDate": "2013-12-11",
      "courtFieldValue": "Военная коллегия Верховного Суда СССР",
      "lowerCourtCaseNumber": "Н-13715",
      "lowerCourtDecisionDate": "1939-02-22",
      "verificationMethod": "web_search_index_of_official_case_card",
      "verifiedScope": "Историческое наблюдение по реабилитационному производству; демонстрирует, что 201 нельзя без учёта эпохи и вида производства толковать исключительно как код Московского окружного военного суда.",
      "publisher": "Верховный Суд Российской Федерации",
      "checkedOn": "2026-09-12",
      "localPageSnapshotAvailable": false,
      "evidenceLevel": "official_published_application_not_normative_annex",
      "effectiveFrom": null,
      "effectiveTo": null,
      "courtFieldName": "Суд 1-ой инстанции"
    }
  ]
}
```
