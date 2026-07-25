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
CALLS_FILE="$TMP/switch-calls"
LOG_FILE="$TMP/action.log"

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
        [ -f "$FM_MOCK_PIN_FILE" ] || exit 1
        cat "$FM_MOCK_PIN_FILE"
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
        printf '%s\n' "$value" >"$FM_MOCK_PIN_FILE"
        case "${FM_MOCK_SET_MODE:-success}" in
            success) printf '%s\n' '{"result":"success"}' ;;
            error) printf '%s\n' '{"result":1}' ;;
            empty) ;;
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
                printf '{"seecom_card_flag":"1","seecom_card_carrier_type":"%s"}\n' "$carrier" >"$FM_MOCK_SIM_FILE"
                printf '%s\n' '{"result":[0]}'
                ;;
            no-update)
                printf '%s\n' '{"result":0}'
                ;;
            error)
                printf '%s\n' '{"result":1}'
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
export FM_MOCK_CALLS_FILE="$CALLS_FILE"
export FM_ACTION_LOG="$LOG_FILE"
export FM_SWITCH_TIMEOUT=1
export FM_POLL_INTERVAL=0

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

run_switch() {
    expected=$1
    mode=$2
    pin=$3
    export FM_MOCK_SWITCH_MODE="$mode"
    export FM_MOCK_SET_MODE=success
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
assert_contains "$out" 'FM_CARRIER=YD'

printf '%s\n' '{"seecom_card_flag":"1","seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
out=$("$CTL" status)
assert_contains "$out" 'FM_AVAILABLE=1'
assert_contains "$out" 'FM_CARRIER=LT'
assert_contains "$out" 'FM_PLMN=46001'

printf '%s\n' '{"seecom_card_flag":1,"seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
out=$("$CTL" status)
assert_contains "$out" 'FM_AVAILABLE=0'

printf '%s\n' '{}' >"$SIM_FILE"
out=$("$CTL" status)
assert_contains "$out" 'FM_AVAILABLE=0'

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
run_switch 5 empty 0200
[ ! -e "$PIN_FILE" ]

printf '%s\n' '{"seecom_card_flag":"1","seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
run_switch 5 error 0200
[ ! -e "$PIN_FILE" ]

printf '%s\n' '{"seecom_card_flag":"1","seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
run_switch 6 no-update 0200
[ ! -e "$PIN_FILE" ]

printf '%s\n' '{"seecom_card_flag":"0","seecom_card_carrier_type":"YD"}' >"$SIM_FILE"
run_switch 3 success 0200
[ "$(wc -l <"$CALLS_FILE" | tr -d ' ')" = "0" ]

printf '%s\n' '{"seecom_card_flag":1,"seecom_card_carrier_type":"LT"}' >"$SIM_FILE"
run_switch 3 success 0200
[ "$(wc -l <"$CALLS_FILE" | tr -d ' ')" = "0" ]

echo "fmsimpin tests: OK"
