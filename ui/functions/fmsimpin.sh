#!/bin/sh

LOG="${FM_ACTION_LOG:-/tmp/devui-fmswitch-action.log}"
PIN_KEY="zwrt_zte_mdm.sim_info.pin_no_need_decode"
SWITCH_TIMEOUT="${FM_SWITCH_TIMEOUT:-60}"
POLL_INTERVAL="${FM_POLL_INTERVAL:-1}"
KNOWN_FLYCAT_ATR="3B9F11801FC78031E073FE211B57378660C90200215C"
KNOWN_FLYCAT_ICCID_PREFIX="89860487"
KNOWN_FLYCAT_ICCID_LENGTH="20"

timestamp() {
    date '+%F %T'
}

trim_log() {
    [ -f "$LOG" ] || return 0
    tail -n 40 "$LOG" >"$LOG.trim" 2>/dev/null && mv "$LOG.trim" "$LOG"
}

log() {
    printf '[%s] %s\n' "$(timestamp)" "$1" >>"$LOG"
}

json_value() {
    printf '%s' "$1" | jsonfilter -e "@.$2" 2>/dev/null | head -n 1
}

json_type() {
    printf '%s' "$1" | jsonfilter -t "@.$2" 2>/dev/null | head -n 1
}

one_line() {
    printf '%s' "$1" | tr '\r\n=' '   ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

uci_value() {
    uci -q get "$1" 2>/dev/null | head -n 1
}

detect_flycat_card() {
    fm_detect_json="$1"
    FM_DETECT_AVAILABLE=0
    FM_DETECT_SOURCE="none"
    FM_DETECT_REASON="card fingerprint not matched"
    FM_CARD_PREFIX="-"
    FM_CARD_LENGTH=0

    fm_detect_flag=$(json_value "$fm_detect_json" seecom_card_flag)
    fm_detect_flag_type=$(json_type "$fm_detect_json" seecom_card_flag)
    if [ "$fm_detect_flag_type" = "string" ]; then
        case "$fm_detect_flag" in
            2)
                FM_DETECT_AVAILABLE=1
                FM_DETECT_SOURCE="vendor_flymodem"
                FM_DETECT_REASON="seecom_card_flag string 2"
                return 0
                ;;
            1)
                FM_DETECT_AVAILABLE=1
                FM_DETECT_SOURCE="vendor_seecom"
                FM_DETECT_REASON="seecom_card_flag string 1"
                return 0
                ;;
        esac
    fi

    fm_detect_iccid=$(json_value "$fm_detect_json" sim_iccid | tr -cd '0-9')
    [ -n "$fm_detect_iccid" ] || \
        fm_detect_iccid=$(uci_value zwrt_zte_mdm.sim_info.current_sim_iccid | tr -cd '0-9')
    [ -n "$fm_detect_iccid" ] || \
        fm_detect_iccid=$(uci_value zwrt_zte_mdm.sim_info.sim_iccid | tr -cd '0-9')
    fm_detect_atr=$(uci_value zwrt_zte_mdm.sim_info.sim_atr | tr '[:lower:]' '[:upper:]' | tr -cd '0-9A-F')
    FM_CARD_LENGTH=${#fm_detect_iccid}
    [ -z "$fm_detect_iccid" ] || FM_CARD_PREFIX=$(printf '%.8s' "$fm_detect_iccid")

    if [ "$fm_detect_atr" = "$KNOWN_FLYCAT_ATR" ] &&
       [ "$FM_CARD_PREFIX" = "$KNOWN_FLYCAT_ICCID_PREFIX" ] &&
       [ "$FM_CARD_LENGTH" = "$KNOWN_FLYCAT_ICCID_LENGTH" ]; then
        FM_DETECT_AVAILABLE=1
        FM_DETECT_SOURCE="known_fingerprint"
        FM_DETECT_REASON="ATR and ICCID issuer fingerprint matched"
        return 0
    fi

    FM_DETECT_REASON="flag ${fm_detect_flag_type:-missing} ${fm_detect_flag:-missing}; fingerprint mismatch"
    return 1
}

get_sim_info() {
    ubus -t 4 call zwrt_zte_mdm.api get_sim_info '{}' 2>/dev/null
}

get_net_info() {
    ubus -t 4 call zte_nwinfo_api nwinfo_get_netinfo '{}' 2>/dev/null
}

carrier_name() {
    case "$1" in
        YD) printf '%s' '中国移动' ;;
        DX) printf '%s' '中国电信' ;;
        LT) printf '%s' '中国联通' ;;
        *)  printf '%s' '未知' ;;
    esac
}

pin_carrier() {
    case "$1" in
        0200) printf '%s' 'YD' ;;
        0300) printf '%s' 'DX' ;;
        0100) printf '%s' 'LT' ;;
        *) return 1 ;;
    esac
}

normalize_mnc() {
    case "$1" in
        [0-9]) printf '0%s' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

network_registered() {
    case "$1" in
        SA|NSA|LTE|ENDC) return 0 ;;
        *) return 1 ;;
    esac
}

response_success() {
    [ -n "$1" ] || return 1
    printf '%s' "$1" | grep -Eq \
        '"result"[[:space:]]*:[[:space:]]*(0|\[[[:space:]]*0[[:space:]]*\]|true|"(success|ok)")([[:space:]],|[[:space:]}])'
}

print_status() {
    sim_json=$(get_sim_info)
    net_json=$(get_net_info)
    detect_flycat_card "$sim_json" || true
    carrier=$(json_value "$sim_json" seecom_card_carrier_type | tr '[:lower:]' '[:upper:]')
    net_type=$(json_value "$net_json" network_type)
    band=$(json_value "$net_json" wan_active_band)
    signal=$(json_value "$net_json" signalbar)
    mcc=$(json_value "$net_json" rmcc)
    mnc=$(normalize_mnc "$(json_value "$net_json" rmnc)")
    provider=$(carrier_name "$carrier")

    [ -n "$carrier" ] || carrier="-"
    [ -n "$net_type" ] || net_type="-"
    [ -n "$band" ] || band="-"
    [ -n "$signal" ] || signal="-"
    if [ -n "$mcc" ] && [ -n "$mnc" ]; then
        plmn="$mcc$mnc"
    else
        plmn="-"
    fi

    printf 'FM_AVAILABLE=%s\n' "$FM_DETECT_AVAILABLE"
    printf 'FM_DETECT_SOURCE=%s\n' "$(one_line "$FM_DETECT_SOURCE")"
    printf 'FM_DETECT_REASON=%s\n' "$(one_line "$FM_DETECT_REASON")"
    printf 'FM_CARD_PREFIX=%s\n' "$(one_line "$FM_CARD_PREFIX")"
    printf 'FM_CARD_LENGTH=%s\n' "$FM_CARD_LENGTH"
    printf 'FM_CARRIER=%s\n' "$(one_line "$carrier")"
    printf 'FM_PROVIDER=%s\n' "$(one_line "$provider")"
    printf 'FM_NETTYPE=%s\n' "$(one_line "$net_type")"
    printf 'FM_BAND=%s\n' "$(one_line "$band")"
    printf 'FM_SIGNAL=%s\n' "$(one_line "$signal")"
    printf 'FM_PLMN=%s\n' "$(one_line "$plmn")"
}

PIN_HAD=0
PIN_OLD=""

cleanup_pin_decode() {
    rc=$?
    trap - EXIT
    if [ "$PIN_HAD" = "1" ]; then
        ubus -t 5 call zwrt_zte_mdm.api zwrt_mdm_uci_set \
            "{\"option\":\"pin_no_need_decode\",\"value\":\"$PIN_OLD\"}" >/dev/null 2>&1
    else
        ubus -t 5 call zwrt_zte_mdm.api zwrt_mdm_uci_set \
            '{"option":"pin_no_need_decode","value":"0"}' >/dev/null 2>&1
        uci -q delete "$PIN_KEY" >/dev/null 2>&1
        uci -q commit zwrt_zte_mdm >/dev/null 2>&1
    fi
    trim_log
    exit "$rc"
}

switch_carrier() {
    target_pin="$1"
    target_carrier=$(pin_carrier "$target_pin") || {
        log "拒绝切换：无效目标 PIN"
        trim_log
        return 2
    }
    target_name=$(carrier_name "$target_carrier")

    sim_json=$(get_sim_info)
    detect_flycat_card "$sim_json" || true
    current=$(json_value "$sim_json" seecom_card_carrier_type | tr '[:lower:]' '[:upper:]')
    if [ "$FM_DETECT_AVAILABLE" != "1" ]; then
        log "拒绝切换：未检测到飞猫分身卡"
        trim_log
        return 3
    fi
    if [ "$current" = "$target_carrier" ]; then
        log "无需切换：当前已经是$target_name"
        trim_log
        return 0
    fi

    if PIN_OLD=$(uci -q get "$PIN_KEY" 2>/dev/null); then
        PIN_HAD=1
        case "$PIN_OLD" in 0|1) ;; *) PIN_OLD=0 ;; esac
    fi
    trap cleanup_pin_decode EXIT
    trap 'exit 130' INT TERM

    log "开始切换到$target_name"
    set_reply=$(ubus -t 5 call zwrt_zte_mdm.api zwrt_mdm_uci_set \
        '{"option":"pin_no_need_decode","value":"1"}' 2>&1)
    set_rc=$?
    if [ "$set_rc" -ne 0 ] || ! response_success "$set_reply"; then
        log "切换失败：无法启用临时 PIN 解码模式"
        return 4
    fi

    switch_reply=$(ubus -t 20 call zwrt_zte_mdm.api sim_change_pin_mode \
        "{\"pin_num_m\":\"$target_pin\",\"pin_mode\":1}" 2>&1)
    switch_rc=$?
    if [ "$switch_rc" -ne 0 ] || ! response_success "$switch_reply"; then
        log "切换失败：设备未返回明确成功结果"
        return 5
    fi

    case "$SWITCH_TIMEOUT" in ''|*[!0-9]*) SWITCH_TIMEOUT=60 ;; esac
    elapsed=0
    while [ "$elapsed" -lt "$SWITCH_TIMEOUT" ]; do
        sim_json=$(get_sim_info)
        net_json=$(get_net_info)
        detect_flycat_card "$sim_json" || true
        current=$(json_value "$sim_json" seecom_card_carrier_type | tr '[:lower:]' '[:upper:]')
        net_type=$(json_value "$net_json" network_type)
        if [ "$FM_DETECT_AVAILABLE" = "1" ] &&
           [ "$current" = "$target_carrier" ] && network_registered "$net_type"; then
            log "切换成功：$target_name，网络已恢复为$net_type"
            return 0
        fi
        [ "$POLL_INTERVAL" = "0" ] || sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + 1))
    done

    log "切换失败：等待$target_name驻网超时"
    return 6
}

case "${1:-}" in
    status)
        print_status
        ;;
    switch)
        switch_carrier "${2:-}"
        ;;
    *)
        echo "usage: $0 status | switch <0100|0200|0300>" >&2
        exit 2
        ;;
esac
