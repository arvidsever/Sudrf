#!/usr/bin/env python3
"""Генерация Sources/SudrfKit/Resources/VNKODCourts.json — списка судов,
работающих на «винтажной» версии модуля sud_delo (VNKOD-паттерн: параметры
_deloId/_new/case__vnkod вместо delo_id/new/<TABLE>__…).

Источник — конфигурация судов из проекта tochno-st/sudrfscraper:
https://raw.githubusercontent.com/tochno-st/sudrfscraper/master/src/main/resources/config/config_sudrf.json
(2270 судов; берётся только срез searchPattern == "VNKOD_PATTERN", ~101 суд —
для остальных действует наш обычный primary-паттерн и данные не нужны).

Запуск:  python3 Scripts/derive-vnkod.py путь/к/config_sudrf.json
"""
import json
import sys
from pathlib import Path

def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: derive-vnkod.py path/to/config_sudrf.json")
    cfg = json.load(open(sys.argv[1], encoding="utf-8"))
    out = []
    for c in cfg:
        if c.get("searchPattern") != "VNKOD_PATTERN":
            continue
        domain = c["searchString"].split("://", 1)[-1].strip("/").lower()
        out.append({
            "domain": domain,               # дефисная (модульная) форма хоста
            "vnkod": c["vnkod"],            # внутренний код суда, напр. 28RS0011
            "title": c["name"],
            "hasCaptcha": bool(c["hasCaptcha"]),
        })
    out.sort(key=lambda x: x["domain"])
    dest = Path(__file__).resolve().parent.parent / "Sources/SudrfKit/Resources/VNKODCourts.json"
    dest.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(out)} судов → {dest}")

if __name__ == "__main__":
    main()
