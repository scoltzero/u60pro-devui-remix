#!/bin/sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CTL="$ROOT/ui/functions/fmsimpin.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fmsimpin-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
SIM_FILE="$TMP/sim.json"
NET_FILE="$TMP/net.json"
PIN_FILE="$TMP/pin-state"
ATR_FILE="$TMP/sim-atr"
CALLS_FILE="$TMP/switch-calls"
LOG_FILE="$TMP/action.log"
DISPLAY_FILE="$TMP/flymodem-display.conf"

cat >"$TMP/bin/jsonfilter" <<'EOF'
#!/bin/sh
expr=
mode=value
while [ $# -gt 0 ]; do
    case "$1" in
        -e) expr=$2; mode=value; shift 2 ;;
        -t) expr=$2; mode=type; shift 2 ;;
        *) shift ;;
    esac
done
key=${expr#@.}
python3 -c 'import json, sys
key = sys.argv[1]
mode = sys.argv[2]
try:
    value = json.load(sys.stdin).get(key, "")
except Exception:
    raise SystemExit(1)
if mode == "type":
    if isinstance(value, str): print("string")
    elif isinstance(value, bool): print("boolean")
    elif isinstance(value, int): print("int")
    elif isinstance(value, float): print("double")
    elif isinstance(value, list): print("array")
    elif isinstance(value, dict): print("object")
    elif value is None: print("null")
    raise SystemExit(0)
if isinstance(value, bool):
    print("true" if value else "false")
elif value is not None:
    print(value)
' "$key" "$mode"
EOF

cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-q" ] && shift
case "${1:-}" in
    get)
        case "${2:-}" in
            zwrt_zte_mdm.sim_info.pin_no_need_decode)
                [ -f "$FM_MOCK_PIN_FILE" ] || exit 1
                cat "$FM_MOCK_PIN_FILE"
                ;;
            zwrt_zte_mdm.sim_info.sim_atr)
                [ -s "$FM_MOCK_ATR_FILE" ] || exit 1
                cat "$FM_MOCK_ATR_FILE"
                ;;
            zwrt_zte_mdm.sim_info.simcard_0_iccid)
                [ -n "${FM_MOCK_SLOT0_ICCID:-}" ] || exit 1
                printf '%s\n' "$FM_MOCK_SLOT0_ICCID"
                ;;
            zwrt_zte_mdm.sim_info.simcard_1_iccid)
                [ -n "${FM_MOCK_SLOT1_ICCID:-}" ] || exit 1
                printf '%s\n' "$FM_MOCK_SLOT1_ICCID"
                ;;
            *) exit 1 ;;
        esac
        ;;
    delete)
        rm -f "$FM_MOCK_PIN_FILE"
        ;;
    commit)
        ;;
    *) exit 1 ;;
esac
EOF

cat >"$TMP/bin/ubus" <<'EOF'
#!/bin/sh
args=$*
case "$args" in
    *" get_sim_info "*)
        cat "$FM_MOCK_SIM_FILE"
        ;;
    *" nwinfo_get_netinfo "*)
        cat "$FM_MOCK_NET_FILE"
        ;;
    *" zwrt_mdm_uci_set "*)
        value=$(printf '%s' "$args" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
        case "${FM_MOCK_SET_MODE:-success}" in
            success)
                printf '%s\n' "$value" >"$FM_MOCK_PIN_FILE"
                printf '%s\n' '{"result":"success"}'
                ;;
            error)
                printf '%s\n' "$value" >"$FM_MOCK_PIN_FILE"
                printf '%s\n' '{"result":1}'
                ;;
            empty)
                printf '%s\n' "$value" >"$FM_MOCK_PIN_FILE"
                ;;
            empty-no-write)
                ;;
        esac
        ;;
    *" sim_change_pin_mode "*)
        printf '1\n' >>"$FM_MOCK_CALLS_FILE"
        case "${FM_MOCK_SWITCH_MODE:-success}" in
            success)
                case "$args" in
                    *0200*) carrier=YD ;;
                    *0300*) carrier=DX ;;
                    *0100*) carrier=LT ;;
                    *) carrier=UNKNOWN ;;
                esac
                case "${FM_MOCK_CARD_CLASS:-vendor}" in
                    fingerprint)
                        printf '{"seecom_card_flag":"0","seecom_card_carrier_type":"%s","sim_iccid":"89860487000000000000"}\n' "$carrier" >"$FM_MOCK_SIM_FILE"
                        ;;
                    slot-fingerprint)
                        printf '{"seecom_card_flag":"0","seecom_card_carrier_type":"%s","sim_iccid":"89861123000000000000"}\n' "$carrier" >"$FM_MOCK_SIM_FILE"
                        ;;
                    manual)
                        printf '{"seecom_card_flag":"0","seecom_card_carrier_type":"%s","sim_iccid":"89860489000000000000"}\n' "$carrier" >"$FM_MOCK_SIM_FILE"
                        ;;
                    *)
                        printf '{"seecom_card_flag":"1","seecom_card_carrier_type":"%s"}\n' "$carrier" >"$FM_MOCK_SIM_FILE"
                        ;;
                esac
                printf '%s\n' '{"result":[0]}'
                ;;
            no-update)
                printf '%s\n' '{"result":0}'
                ;;
            error)
                printf '%s\n' '{"result":1}'
                ;;
            empty-success)
                case "$args" in
                    *0200*) carrier=YD ;;
                    *0300*) carrier=DX ;;
                    *0100*) carrier=LT ;;
                    *) carrier=UNKNOWN ;;
                esac
                printf '{"seecom_card_flag":"1","seecom_card_carrier_type":"%s"}\n' "$carrier" >"$FM_MOCK_SIM_FILE"
                ;;
            unknown-success)
                case "$args" in
                    *0200*) carrier=YD ;;
                    *0300*) carrier=DX ;;
                    *0100*) carrier=LT ;;
                    *) carrier=UNKNOWN ;;
                esac
                printf '{"seecom_card_flag":"1","seecom_card_carrier_type":"%s"}\n' "$carrier" >"$FM_MOCK_SIM_FILE"
                printf '%s\n' '{"message":"queued"}'
                ;;
            empty)
                ;;
        esac
        ;;
    *) exit 1 ;;
esac
EOF

chmod 755 "$TMP/bin/jsonfilter" "$TMP/bin/uci" "$TMP/bin/ubus"

export PATH="$TMP/bin:$PATH"
export FM_MOCK_SIM_FILE="$SIM_FILE"
export FM_MOCK_NET_FILE="$NET_FILE"
export FM_MOCK_PIN_FILE="$PIN_FILE"
export FM_MOCK_ATR_FILE="$ATR_FILE"
export FM_MOCK_CALLS_FILE="$CALLS_FILE"
export FM_ACTION_LOG="$LOG_FILE"
export FM_ENABLE_FILE="$DISPLAY_FILE"
export FM_SWITCH_TIMEOUT=1
export FM_POLL_INTERVAL=0
export FM_MOCK_SLOT0_ICCID=
export FM_MOCK_SLOT1_ICCID=
: >"$ATR_FILE"
rm -f "$DISPLAY_FILE"

write_net() {
    printf '%s\n' '{"network_type":"SA","wan_active_band":"n78","signalbar":"4","rmcc":460,"rmnc":1}' >"$NET_FILE"
}

assert_contains() {
    printf '%s' "$1" | grep -q "$2" || {
        echo "missing '$2' in output:" >&2
        printf '%s\n' "$1" >&2
        exit 1
    }
}

assert_not_contains() {
    if printf '%s' "$1" | grep -q "$2"; then
        echo "unexpected '$2' in output:" >&2
        printf '%s\n' "$1" >&2
        exit 1
    fi
}

run_switch() {
    expected=$1
    mode=$2
    pin=$3
    card_class=${4:-vendor}
    set_mode=${5:-success}
    export FM_MOCK_SWITCH_MODE="$mode"
    export FM_MOCK_SET_MODE="$set_mode"
    export FM_MOCK_CARD_CLASS="$card_class"
    : >"$CALLS_FILE"
    : >"$LOG_FILE"
    if "$CTL" switch "$pin"; then rc=0; else rc=$?; fi
    [ "$rc" -eq "$expected" ] || {
        echo "switch rc=$rc expected=$expected mode=$mode" >&2
        cat "$LOG_FILE" >&2
        exit 1
    }
}

write_net
printf '%s\n' '{"seecom_card_flag":"0","seecom_card_carrier_type":"YD"}' >"$SIM_FILE"
out=$("$CTL" status)
assert_contains "$out" 'FM_AVAILABLE=0'
assert_contains "$out" 'FM_DETECT_SOURCE=none'
assert_contains "$out" 'FM_CARRIER=YD'

printf '%s\n' '{"seecom_card_flag":"1","seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
out=$("$CTL" status)
assert_contains "$out" 'FM_AVAILABLE=1'
assert_contains "$out" 'FM_DETECT_SOURCE=vendor_seecom'
assert_contains "$out" 'FM_CARRIER=LT'
assert_contains "$out" 'FM_PLMN=46001'

printf '%s\n' '{"seecom_card_flag":"2","seecom_card_carrier_type":"DX"}' >"$SIM_FILE"
out=$("$CTL" status)
assert_contains "$out" 'FM_AVAILABLE=1'
assert_contains "$out" 'FM_DETECT_SOURCE=vendor_flymodem'

printf '%s\n' '3B9F11801FC78031E073FE211B57378660C90200215C' >"$ATR_FILE"
printf '%s\n' '{"seecom_card_flag":"0","seecom_card_carrier_type":"YD","sim_iccid":"89860487000000000000"}' >"$SIM_FILE"
out=$("$CTL" status)
assert_contains "$out" 'FM_AVAILABLE=1'
assert_contains "$out" 'FM_DETECT_SOURCE=known_fingerprint'
assert_contains "$out" 'FM_CARD_PREFIX=89860487'
assert_contains "$out" 'FM_CARD_LENGTH=20'
assert_not_contains "$out" '89860487000000000000'

printf '%s\n' '3B9D96801FC78031E073FE2113651509638683A2' >"$ATR_FILE"
out=$("$CTL" status)
assert_contains "$out" 'FM_AVAILABLE=0'

printf '%s\n' '3B9F11801FC78031E073FE211B57378660C90200215C' >"$ATR_FILE"
export FM_MOCK_SLOT0_ICCID=89860487000000000000
printf '%s\n' '{"seecom_card_flag":"0","seecom_card_carrier_type":"DX","sim_iccid":"89861123000000000000"}' >"$SIM_FILE"
out=$("$CTL" status)
assert_contains "$out" 'FM_AVAILABLE=1'
assert_contains "$out" 'FM_DETECT_SOURCE=known_slot_fingerprint'
assert_contains "$out" 'FM_CARD_PREFIX=89861123'
assert_contains "$out" 'FM_BASE_PREFIX=89860487'
assert_not_contains "$out" '89861123000000000000'
export FM_MOCK_SLOT0_ICCID=

printf '%s\n' '3B9F11801FC78031E073FE211B57378660C90200215C' >"$ATR_FILE"
printf '%s\n' '{"seecom_card_flag":"0","seecom_card_carrier_type":"YD","sim_iccid":"89860210000000000000"}' >"$SIM_FILE"
out=$("$CTL" status)
assert_contains "$out" 'FM_AVAILABLE=0'

: >"$ATR_FILE"

printf '%s\n' '{"seecom_card_flag":1,"seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
out=$("$CTL" status)
assert_contains "$out" 'FM_AVAILABLE=1'
assert_contains "$out" 'FM_DETECT_SOURCE=vendor_seecom'

printf '%s\n' '{}' >"$SIM_FILE"
out=$("$CTL" status)
assert_contains "$out" 'FM_AVAILABLE=0'

printf '%s\n' '3B9A94801FC38031E073FE211B2404198D' >"$ATR_FILE"
printf '%s\n' '{"seecom_card_flag":"0","seecom_card_carrier_type":"YD","sim_iccid":"89860489000000000000"}' >"$SIM_FILE"
out=$("$CTL" status)
assert_contains "$out" 'FM_AVAILABLE=0'
assert_contains "$out" 'FM_MANUAL_ENABLED=0'
printf '1\n' >"$DISPLAY_FILE"
out=$("$CTL" status)
assert_contains "$out" 'FM_AVAILABLE=1'
assert_contains "$out" 'FM_MANUAL_ENABLED=1'
assert_contains "$out" 'FM_DETECT_SOURCE=manual_override'
assert_not_contains "$out" '89860489000000000000'
rm -f "$DISPLAY_FILE"

rm -f "$PIN_FILE"
printf '%s\n' '3B9F11801FC78031E073FE211B57378660C90200215C' >"$ATR_FILE"
printf '%s\n' '{"seecom_card_flag":"0","seecom_card_carrier_type":"LT","sim_iccid":"89860487000000000000"}' >"$SIM_FILE"
run_switch 0 success 0200 fingerprint
[ "$(wc -l <"$CALLS_FILE" | tr -d ' ')" = "1" ]
[ ! -e "$PIN_FILE" ]
assert_not_contains "$(cat "$LOG_FILE")" '89860487000000000000'
: >"$ATR_FILE"

printf '%s\n' '{broken' >"$SIM_FILE"
out=$("$CTL" status)
assert_contains "$out" 'FM_AVAILABLE=0'

rm -f "$PIN_FILE"
printf '%s\n' '{"seecom_card_flag":"1","seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
run_switch 0 success 0200
[ "$(wc -l <"$CALLS_FILE" | tr -d ' ')" = "1" ]
[ ! -e "$PIN_FILE" ]
[ -s "$LOG_FILE" ]

printf '0\n' >"$PIN_FILE"
printf '%s\n' '{"seecom_card_flag":"1","seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
run_switch 0 success 0300
[ "$(cat "$PIN_FILE")" = "0" ]

rm -f "$PIN_FILE"
printf '%s\n' '{"seecom_card_flag":"1","seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
run_switch 0 empty-success 0200
[ "$(wc -l <"$CALLS_FILE" | tr -d ' ')" = "1" ]
[ ! -e "$PIN_FILE" ]
assert_contains "$(cat "$LOG_FILE")" '设备未返回切换结果'

rm -f "$PIN_FILE"
printf '%s\n' '{"seecom_card_flag":"1","seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
run_switch 0 unknown-success 0200
[ ! -e "$PIN_FILE" ]
assert_contains "$(cat "$LOG_FILE")" '设备返回未识别结果'

rm -f "$PIN_FILE"
printf '%s\n' '{"seecom_card_flag":"1","seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
run_switch 6 empty 0200
[ ! -e "$PIN_FILE" ]

printf '%s\n' '{"seecom_card_flag":"1","seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
run_switch 5 error 0200
[ ! -e "$PIN_FILE" ]

rm -f "$PIN_FILE"
printf '%s\n' '{"seecom_card_flag":"1","seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
run_switch 0 success 0200 vendor empty
[ ! -e "$PIN_FILE" ]
assert_contains "$(cat "$LOG_FILE")" '已通过配置回读确认生效'

rm -f "$PIN_FILE"
printf '%s\n' '{"seecom_card_flag":"1","seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
run_switch 4 success 0200 vendor empty-no-write
[ "$(wc -l <"$CALLS_FILE" | tr -d ' ')" = "0" ]
[ ! -e "$PIN_FILE" ]

rm -f "$PIN_FILE"
printf '%s\n' '{"seecom_card_flag":"1","seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
run_switch 4 success 0200 vendor error
[ "$(wc -l <"$CALLS_FILE" | tr -d ' ')" = "0" ]
[ ! -e "$PIN_FILE" ]

printf '%s\n' '{"seecom_card_flag":"1","seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
run_switch 6 no-update 0200
[ ! -e "$PIN_FILE" ]

printf '%s\n' '{"seecom_card_flag":"0","seecom_card_carrier_type":"YD"}' >"$SIM_FILE"
run_switch 3 success 0200
[ "$(wc -l <"$CALLS_FILE" | tr -d ' ')" = "0" ]

printf '%s\n' '{"seecom_card_flag":1,"seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
run_switch 0 success 0200
[ "$(wc -l <"$CALLS_FILE" | tr -d ' ')" = "1" ]

rm -f "$PIN_FILE"
printf '%s\n' '3B9F11801FC78031E073FE211B57378660C90200215C' >"$ATR_FILE"
export FM_MOCK_SLOT0_ICCID=89860487000000000000
printf '%s\n' '{"seecom_card_flag":"0","seecom_card_carrier_type":"DX","sim_iccid":"89861123000000000000"}' >"$SIM_FILE"
run_switch 0 success 0200 slot-fingerprint
[ "$(wc -l <"$CALLS_FILE" | tr -d ' ')" = "1" ]
[ ! -e "$PIN_FILE" ]
export FM_MOCK_SLOT0_ICCID=

rm -f "$PIN_FILE"
printf '1\n' >"$DISPLAY_FILE"
printf '%s\n' '3B9A94801FC38031E073FE211B2404198D' >"$ATR_FILE"
printf '%s\n' '{"seecom_card_flag":"0","seecom_card_carrier_type":"DX","sim_iccid":"89860489000000000000"}' >"$SIM_FILE"
run_switch 0 success 0200 manual
[ "$(wc -l <"$CALLS_FILE" | tr -d ' ')" = "1" ]
[ ! -e "$PIN_FILE" ]
rm -f "$DISPLAY_FILE"

echo "fmsimpin tests: OK"
