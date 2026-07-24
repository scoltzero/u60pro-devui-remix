#!/bin/sh
# fmsimpin.sh - 飞猫分身切卡 v5.2.5

CMD="$1"
PIN_NUM_M="$2"
TIMEOUT="${3:-30}"

LOG="/tmp/devui-fmswitch-action.log"
PIDFILE="/tmp/fmswitch.pid"

log() {
    stamp=$(date '+%F %T')
    echo "[$stamp] $1" >> "$LOG"
}

json_get() {
    echo "$1" | sed -n 's/.*"'$2'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

json_get_num() {
    echo "$1" | sed -n 's/.*"'$2'"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1
}

get_netinfo() {
    ubus call zte_nwinfo_api nwinfo_get_netinfo {} 2>/dev/null
}

provider_to_cn() {
    case "$1" in
        "China Mobile"*| "CHINA MOBILE"* | "CMCC"*) echo "中国移动" ;;
        "China Telecom"*|"CHINA TELECOM"*|"CT"*)    echo "中国电信" ;;
        "China Unicom"*| "CHINA UNICOM"* | "CU"*)  echo "中国联通" ;;
        *) echo "$1" ;;
    esac
}

pin_to_provider() {
    case "$1" in
        0200) echo "中国移动" ;;
        0300) echo "中国电信" ;;
        0100) echo "中国联通" ;;
        *)    echo "未知" ;;
    esac
}

case "$CMD" in
    status)
        result=$(get_netinfo)
        provider=$(json_get "$result" "network_provider_fullname")
        net_type=$(json_get "$result" "network_type")
        band=$(json_get "$result" "wan_active_band")
        signal=$(json_get "$result" "signalbar")
        mcc=$(json_get_num "$result" "rmcc")
        mnc=$(json_get_num "$result" "rmnc")

        case "$mnc" in
            0|00)  cur_pin="0200" ;;
            11)    cur_pin="0300" ;;
            1|01)  cur_pin="0100" ;;
            *)     cur_pin="-" ;;
        esac

        provider_cn=$(provider_to_cn "$provider")
        [ -z "$provider_cn" ] && provider_cn="未知"

        [ -z "$net_type" ] && net_type="无服务"
        [ -z "$band" ] && band="-"
        [ -z "$signal" ] && signal="-"
        [ -z "$mcc" ] && mcc="-"
        [ -z "$mnc" ] && mnc="-"

        echo "FM_INSTALLED=1"
        echo "FM_PROVIDER=$provider_cn"
        echo "FM_PROVIDER_EN=$provider"
        echo "FM_NETTYPE=$net_type"
        echo "FM_BAND=$band"
        echo "FM_SIGNAL=$signal"
        echo "FM_MCC=$mcc"
        echo "FM_MNC=$mnc"
        echo "FM_CUR_PIN=$cur_pin"
        echo "FM_SWITCHING=0"
        ;;

    switch)
        echo "=== 飞猫分身切卡 ===" | tee -a "$LOG"

        if [ -z "$PIN_NUM_M" ]; then
            echo "ERROR: 缺少 PIN 参数" | tee -a "$LOG"
            exit 1
        fi

        result=$(get_netinfo)
        cur_mnc=$(json_get_num "$result" "rmnc")
        target_provider=$(pin_to_provider "$PIN_NUM_M")

        case "$cur_mnc" in
            0|00)  cur_pin="0200" ;;
            11)    cur_pin="0300" ;;
            1|01)  cur_pin="0100" ;;
            *)     cur_pin="" ;;
        esac

        if [ "$cur_pin" = "$PIN_NUM_M" ]; then
            echo "SKIP: 当前已是 $target_provider，无需切换" | tee -a "$LOG"
            echo "FM_SKIP=1"
            echo "FM_SKIP_MSG=当前已是 $target_provider，无需切换"
            exit 0
        fi

        echo "$$" > "$PIDFILE"
        log "START: 切卡 pin=$PIN_NUM_M (目标: $target_provider)"

        echo "[1/2] 设置 PIN 解码模式..." | tee -a "$LOG"
        ubus call zwrt_zte_mdm.api zwrt_mdm_uci_set             '{"option":"pin_no_need_decode","value":"1"}' 2>/dev/null

        echo "[2/2] 执行切卡..." | tee -a "$LOG"
        result=$(ubus call zwrt_zte_mdm.api sim_change_pin_mode             '{"pin_num_m":"'$PIN_NUM_M'","pin_mode":1}' 2>/dev/null)

        switch_ok=0
        if [ -z "$result" ]; then
            switch_ok=1
            echo "  设备无返回，切卡已执行" | tee -a "$LOG"
        elif echo "$result" | grep -qE '"result"[[:space:]]*:[[:space:]]*(\[?[[:space:]]*0[[:space:]]*\]?|true|"ok"|"success")'; then
            switch_ok=1
        elif ! echo "$result" | grep -qiE '("result"[[:space:]]*:[[:space:]]*[1-9]|error|fail)'; then
            switch_ok=1
        fi

        if [ "$switch_ok" -gt 0 ]; then
            echo "SUCCESS: 切卡成功!" | tee -a "$LOG"
            log "SUCCESS: 切卡成功 pin=$PIN_NUM_M"
        else
            echo "ERROR: 切卡失败" | tee -a "$LOG"
            echo "返回: $(echo "$result" | head -c 200)" | tee -a "$LOG"
            rm -f "$PIDFILE"
            exit 1
        fi

        echo "等待网络恢复..." | tee -a "$LOG"
        elapsed=0
        while [ "$elapsed" -lt "$TIMEOUT" ]; do
            result=$(get_netinfo)
            net_type=$(json_get "$result" "network_type")
            if [ "$net_type" = "SA" ] || [ "$net_type" = "NSA" ] || [ "$net_type" = "LTE" ]; then
                provider=$(json_get "$result" "network_provider_fullname")
                provider_cn=$(provider_to_cn "$provider")
                echo "网络已恢复: $provider_cn/$net_type" | tee -a "$LOG"
                break
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done

        rm -f "$PIDFILE"
        echo "=== 完成 ===" | tee -a "$LOG"
        ;;

    *)
        echo "用法: $0 status | switch <pin_num_m>"
        exit 1
        ;;
esac
