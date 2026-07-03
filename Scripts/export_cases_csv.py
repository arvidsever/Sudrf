#!/usr/bin/env python3
"""Выгрузка списка дел из webarchive LegalHelp (lk.legalhelp.pw) в CSV.

Использование:
    python3 Scripts/export_cases_csv.py "/путь/к/Список дел.webarchive" [выход.csv]

Без второго аргумента CSV кладётся рядом с webarchive (то же имя, .csv).
Колонки: number,court,kind,level,parties,updated,url — формат, который
понимает импорт приложения (Файл → «Импортировать дела из CSV…»).
Обязательные для импорта: number (может быть пуст — добудется из карточки),
court, url; остальные информационные.
"""

import csv
import plistlib
import re
import sys
from html import unescape
from pathlib import Path

CARD_RE = re.compile(r'<div class="card mb-4"(.*?)Ссылка на дело</a>', re.S)
COURT_RE = re.compile(r'<h5 class="card-title mb-1">\s*(.*?)\s*<', re.S)
NUMBER_RE = re.compile(r'>(?:ДЕЛО|МАТЕРИАЛ) № (.*?)</a>')
PARTIES_RE = re.compile(r'<span class="card-text mb-1"><p>\s*(.*?)\s*</p></span>', re.S)
UPDATED_RE = re.compile(r'Обновлено ([\d.: ]+)')
KIND_RE = re.compile(r'•\s*([^<]+?)\s*<br>')
LEVEL_RE = re.compile(r'•\s*([А-ЯЁа-яё() -]+?суд[а-яё]*)\s*$', re.M)
HREF_RE = re.compile(r'<a href="(https?://[^"]+)"')


def clean(s):
    return re.sub(r'\s+', ' ', unescape(s)).strip() if s else ''


def first(rx, text):
    m = rx.search(text)
    return clean(m.group(1)) if m else ''


def parse_cards(html):
    rows = []
    for chunk in CARD_RE.findall(html):
        hrefs = HREF_RE.findall(chunk)
        # «Ссылка на дело» — последний внешний href карточки.
        url = unescape(hrefs[-1]) if hrefs else ''
        rows.append({
            'number': first(NUMBER_RE, chunk),
            'court': first(COURT_RE, chunk),
            'kind': first(KIND_RE, chunk),
            'level': first(LEVEL_RE, chunk),
            'parties': first(PARTIES_RE, chunk),
            'updated': first(UPDATED_RE, chunk),
            'url': url,
        })
    return rows


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix('.csv')

    with open(src, 'rb') as f:
        archive = plistlib.load(f)
    html = archive['WebMainResource']['WebResourceData'].decode('utf-8', errors='replace')

    rows = parse_cards(html)
    # utf-8-sig (BOM) — чтобы Numbers/Excel сразу открывали кириллицу.
    with open(dst, 'w', newline='', encoding='utf-8-sig') as f:
        w = csv.DictWriter(f, fieldnames=['number', 'court', 'kind', 'level',
                                          'parties', 'updated', 'url'])
        w.writeheader()
        w.writerows(rows)
    print(f'{len(rows)} дел → {dst}')


if __name__ == '__main__':
    main()
