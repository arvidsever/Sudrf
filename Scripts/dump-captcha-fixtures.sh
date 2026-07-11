#!/bin/bash
# Scripts/dump-captcha-fixtures.sh
#
# Скачивает капчи с реальных судов для тестирования `CaptchaSolver`.
# НЕ запускается в CI — требует сетевого доступа к sudrf / msudrf.
#
# Использование:
#   bash Scripts/dump-captcha-fixtures.sh                 # 30 капч каждого вида
#   bash Scripts/dump-captcha-fixtures.sh 10              # 10 каждого
#   bash Scripts/dump-captcha-fixtures.sh 5 sudrf         # 5 только sudrf
#
# После запуска нужно вручную разметить результаты:
#   Tests/CaptchaSolverTests/Fixtures/sudrf/labels.csv
#   Tests/CaptchaSolverTests/Fixtures/msudrf/labels.csv

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COUNT="${1:-30}"
KIND="${2:-both}"

USER_AGENT='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15'

# Список судов для фикстур. Ветки ГАС «Правосудие» (sudrfToken) и
# мировых судей (kcaptcha). Источник — `MagistrateDirectory` /
# `CourtDirectory` (списки встроены в Sudrf).
SUDRF_DOMAINS=(
    "sankt-peterburgsky--spb.sudrf.ru"
    "mos--svd.sudrf.ru"
    "sverdlovsky--svd.sudrf.ru"
    "kalininsky--tvs.sudrf.ru"
    "sovetsky--nsk.sudrf.ru"
)

# Мировые судьи СПб (msudrf.ru): по одному участку на район.
# Реальные домены — из MagistrateDirectory или из живого резолвера.
MSUDRF_DOMAINS=(
    "msudrf.ru"
)

dump_sudrf() {
    local out="$ROOT/Tests/CaptchaSolverTests/Fixtures/sudrf"
    mkdir -p "$out"
    : > "$out/.tmp_dumper_index"
    local i=0
    for domain in "${SUDRF_DOMAINS[@]}"; do
        for n in $(seq 1 $COUNT); do
            i=$((i + 1))
            local url="https://${domain}/modules.php?name=sud_delo&srv_num=1&name_op=sf&delo_id=1540005&new=5"
            local html
            html=$(curl -s --max-time 15 \
                -H "User-Agent: $USER_AGENT" \
                -H "Accept: text/html,application/xhtml+xml" \
                "$url" || true)
            if [[ -z "$html" ]]; then
                printf "  skip %s #%d (empty response)\n" "$domain" "$n" >&2
                continue
            fi
            local b64
            b64=$(printf '%s' "$html" | grep -oE 'data: image/png;base64, [A-Za-z0-9+/= ]+' | head -1 \
                | sed 's/^data: image\/png;base64, //' | tr -d ' ' || true)
            local cid
            cid=$(printf '%s' "$html" | grep -oE 'name="captchaid" type="hidden" value="[a-z0-9]+"' \
                | head -1 | sed -E 's/.*value="([^"]+)".*/\1/' || true)
            if [[ -z "$b64" || -z "$cid" ]]; then
                printf "  skip %s #%d (no captcha in response)\n" "$domain" "$n" >&2
                continue
            fi
            local safe_domain="${domain//./_}"
            local filename="${safe_domain}_${i}_${cid}.png"
            printf '%s' "$b64" | base64 -d > "$out/$filename" 2>/dev/null || {
                printf "  skip %s #%d (decode failed)\n" "$domain" "$n" >&2
                continue
            }
            printf '%s,sudrfToken,%s\n' "$filename" "$cid" >> "$out/.tmp_dumper_index"
        done
    done
    printf "wrote %d sudrf fixtures to %s\n" "$i" "$out" >&2
}

dump_msudrf() {
    local out="$ROOT/Tests/CaptchaSolverTests/Fixtures/msudrf"
    mkdir -p "$out"
    : > "$out/.tmp_dumper_index"
    local i=0
    for domain in "${MSUDRF_DOMAINS[@]}"; do
        for n in $(seq 1 $COUNT); do
            i=$((i + 1))
            local url="https://${domain}/modules.php?name=sud_delo&op=hl"
            local html
            html=$(curl -s --max-time 15 \
                -H "User-Agent: $USER_AGENT" \
                "$url" || true)
            if [[ -z "$html" ]]; then
                printf "  skip %s #%d (empty response)\n" "$domain" "$n" >&2
                continue
            fi
            local b64
            b64=$(printf '%s' "$html" | grep -oE 'data: image/[a-z]+;base64, [A-Za-z0-9+/= ]+' | head -1 \
                | sed -E 's/^data: image\/[a-z]+;base64, //' | tr -d ' ' || true)
            local cid
            cid=$(printf '%s' "$html" | grep -oE 'name="captchaid" type="hidden" value="[a-z0-9]+"' \
                | head -1 | sed -E 's/.*value="([^"]+)".*/\1/' || true)
            if [[ -z "$b64" || -z "$cid" ]]; then
                printf "  skip %s #%d (no captcha in response)\n" "$domain" "$n" >&2
                continue
            fi
            local safe_domain="${domain//./_}"
            local filename="${safe_domain}_${i}_${cid}.png"
            printf '%s' "$b64" | base64 -d > "$out/$filename" 2>/dev/null || {
                printf "  skip %s #%d (decode failed)\n" "$domain" "$n" >&2
                continue
            }
            printf '%s,kcaptcha,%s\n' "$filename" "$cid" >> "$out/.tmp_dumper_index"
        done
    done
    printf "wrote %d msudrf fixtures to %s\n" "$i" "$out" >&2
}

case "$KIND" in
    sudrf)  dump_sudrf ;;
    msudrf) dump_msudrf ;;
    both)   dump_sudrf; dump_msudrf ;;
    *)      printf "unknown kind: %s (use: sudrf, msudrf, both)\n" "$KIND" >&2; exit 2 ;;
esac

printf "\nNext: разметьте %d капч в Tests/CaptchaSolverTests/Fixtures/{sudrf,msudrf}/labels.csv\n" "$COUNT"
