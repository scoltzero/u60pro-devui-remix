#!/bin/sh
set -eu

BASE=/sys/devices/system/cpu/cpufreq

first_policy() {
    for p in "$BASE"/policy*; do
        [ -d "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

nearest_freq() {
    file="$1"
    target="$2"
    fallback="$3"
    if [ -s "$file" ]; then
        awk -v target="$target" '
            { for (i = 1; i <= NF; i++) {
                d = $i - target; if (d < 0) d = -d
                if (!seen || d < best) { seen = 1; best = d; value = $i }
            }}
            END { if (seen) print value }
        ' "$file"
    else
        echo "$fallback"
    fi
}

mode_for_policy() {
    p="$1"
    gov="$(cat "$p/scaling_governor" 2>/dev/null || true)"
    min="$(cat "$p/scaling_min_freq" 2>/dev/null || echo 0)"
    max="$(cat "$p/scaling_max_freq" 2>/dev/null || echo 0)"
    hwmax="$(cat "$p/cpuinfo_max_freq" 2>/dev/null || echo 0)"
    if [ "$gov" = powersave ]; then
        echo powersave
    elif [ "$gov" = performance ] && [ "$min" = "$hwmax" ] && [ "$max" = "$hwmax" ]; then
        echo extreme
    elif [ "$gov" = schedutil ] && [ "$hwmax" -gt 0 ] && [ "$min" -ge $((hwmax * 3 / 5)) ]; then
        echo performance
    elif [ "$gov" = schedutil ]; then
        echo balance
    else
        echo custom
    fi
}

status() {
    p="$(first_policy 2>/dev/null || true)"
    if [ -z "$p" ]; then
        echo CPU_INST=0
        return 1
    fi
    echo CPU_INST=1
    echo "CPU_MODE=$(mode_for_policy "$p")"
    echo "CPU_GOV=$(cat "$p/scaling_governor" 2>/dev/null || echo -)"
    echo "CPU_CUR=$(( $(cat "$p/scaling_cur_freq" 2>/dev/null || echo 0) / 1000 )) MHz"
    echo "CPU_MIN=$(( $(cat "$p/scaling_min_freq" 2>/dev/null || echo 0) / 1000 )) MHz"
    echo "CPU_MAX=$(( $(cat "$p/scaling_max_freq" 2>/dev/null || echo 0) / 1000 )) MHz"
}

apply_mode() {
    mode="$1"
    changed=0
    for p in "$BASE"/policy*; do
        [ -d "$p" ] || continue
        hwmin="$(cat "$p/cpuinfo_min_freq")"
        hwmax="$(cat "$p/cpuinfo_max_freq")"
        save_max="$(nearest_freq "$p/scaling_available_frequencies" $((hwmax / 2)) $((hwmax / 2)))"
        perf_min="$(nearest_freq "$p/scaling_available_frequencies" $((hwmax * 2 / 3)) $((hwmax * 2 / 3)))"
        case "$mode" in
            powersave) gov=powersave; target_min="$hwmin"; target_max="$save_max" ;;
            balance) gov=schedutil; target_min="$hwmin"; target_max="$hwmax" ;;
            performance) gov=schedutil; target_min="$perf_min"; target_max="$hwmax" ;;
            extreme) gov=performance; target_min="$hwmax"; target_max="$hwmax" ;;
            *) echo "usage: $0 {status|powersave|balance|performance|extreme}" >&2; return 2 ;;
        esac

        echo "$hwmin" > "$p/scaling_min_freq"
        echo "$hwmax" > "$p/scaling_max_freq"
        echo "$target_max" > "$p/scaling_max_freq"
        echo "$target_min" > "$p/scaling_min_freq"
        echo "$gov" > "$p/scaling_governor"
        changed=1
    done
    [ "$changed" -eq 1 ] || { echo "cpufreq policy not found" >&2; return 1; }
    echo "模式已应用：$mode"
    status
}

case "${1:-status}" in
    status) status ;;
    powersave|balance|performance|extreme) apply_mode "$1" ;;
    *) echo "usage: $0 {status|powersave|balance|performance|extreme}" >&2; exit 2 ;;
esac
