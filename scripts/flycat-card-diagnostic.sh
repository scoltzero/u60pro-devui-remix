#!/bin/sh

# Read-only diagnostic collector for Feimao/Seecom multi-carrier SIM detection.
# The report is safe to share after the built-in redaction pass.

OUTPUT="${1:-/tmp/flycat-card-diagnostic-$(date '+%Y%m%d-%H%M%S').txt}"

case "$OUTPUT" in
    -h|--help)
        echo "usage: $0 [output-file]"
        exit 0
        ;;
esac

umask 077

redact() {
    awk '
    function lower(s) { return tolower(s) }
    function safe_pin_field(k) {
        return k ~ /(pin_no_need_decode|pin_mode|pin_save_flag|pin_encode_flag|pin_status|pin_state|pin_lock|pin_retry|pin_remain)/
    }
    function secret_field(k) {
        k = lower(k)
        if (k ~ /(imsi|iccid|imei|msisdn|phone|mobile_number|(^|[._-])mdn([._-]|$)|(^|[._-])puk([._-]|$)|(^|[._-])nck([._-]|$))/)
            return 1
        if (k ~ /(password|passwd|private_key|preshared_key|auth_key|secret)/)
            return 1
        if (k ~ /(cell_id|lac_code|tac_code)/)
            return 1
        if (k ~ /(^|[._-])(mac|mac_address|serial|serial_number|msn)([._-]|$)/)
            return 1
        if (k ~ /pin/ && !safe_pin_field(k))
            return 1
        return 0
    }
    function mask_json(line, key, colon, suffix) {
        colon = index(line, ":")
        if (!colon) return line
        suffix = ""
        if (line ~ /,[[:space:]]*$/) suffix = ","
        return substr(line, 1, colon) " \"<redacted>\"" suffix
    }
    function mask_assignment(line, eq) {
        eq = index(line, "=")
        if (!eq) return line
        return substr(line, 1, eq) "<redacted>"
    }
    function mask_long_numbers(line, out, digits, i, ch) {
        if (lower(line) ~ /sim_atr/) return line
        out = ""
        digits = ""
        for (i = 1; i <= length(line); i++) {
            ch = substr(line, i, 1)
            if (ch ~ /[0-9]/) {
                digits = digits ch
            } else {
                if (length(digits) >= 11) digits = "<redacted-number>"
                out = out digits ch
                digits = ""
            }
        }
        if (length(digits) >= 11) digits = "<redacted-number>"
        return out digits
    }
    {
        line = $0
        key = ""
        if (match(line, /^[[:space:]]*\"[^\"]+\"[[:space:]]*:/)) {
            key = substr(line, RSTART, RLENGTH)
            sub(/^[[:space:]]*\"/, "", key)
            sub(/\"[[:space:]]*:$/, "", key)
            if (secret_field(key)) line = mask_json(line)
        } else if (index(line, "=") > 0) {
            key = substr(line, 1, index(line, "=") - 1)
            if (secret_field(key)) line = mask_assignment(line)
        }
        line = mask_long_numbers(line)
        print line
    }'
}

emit() {
    printf '%s\n' "$*"
}

section() {
    emit
    emit "===== $* ====="
}

run_command() {
    diag_label="$1"
    shift
    section "$diag_label"
    diag_output=$("$@" 2>&1)
    diag_rc=$?
    emit "exit_code=$diag_rc"
    if [ -n "$diag_output" ]; then
        printf '%s\n' "$diag_output"
    else
        emit "<no output>"
    fi
}

collect_release() {
    if [ -r /etc/openwrt_release ]; then
        cat /etc/openwrt_release
    else
        echo "openwrt_release_unavailable=1"
    fi
}

collect_mdm_methods() {
    ubus -v list zwrt_zte_mdm.api 2>/dev/null |
        sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p'
}

collect_mqtt_methods() {
    ubus -v list zwrt_mqtt.api 2>/dev/null |
        sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p'
}

collect_card_iccid_api() {
    if ubus -v list zwrt_zte_mdm.api 2>/dev/null | grep -q '"get_card_iccid"'; then
        ubus -t 4 call zwrt_zte_mdm.api get_card_iccid '{}'
    else
        echo "method_unavailable=1"
    fi
}

collect_seecom_hosts() {
    if [ -r /etc/hosts ]; then
        data=$(grep -n -i -E 'seecom|flymodem' /etc/hosts 2>/dev/null)
        [ -n "$data" ] && printf '%s\n' "$data" || echo "<no matching hosts entries>"
    else
        echo "hosts_unavailable=1"
    fi
    if pidof zte_mqtt_sdk_st >/dev/null 2>&1; then
        echo "zte_mqtt_sdk_st_running=1"
    else
        echo "zte_mqtt_sdk_st_running=0"
    fi
}

json_get() {
    printf '%s' "$1" | jsonfilter -e "@.$2" 2>/dev/null | head -n 1
}

json_type() {
    printf '%s' "$1" | jsonfilter -t "@.$2" 2>/dev/null | head -n 1
}

collect_card_fingerprint() {
    sim_json=$(ubus -t 4 call zwrt_zte_mdm.api get_sim_info '{}' 2>/dev/null)
    card_id=$(json_get "$sim_json" sim_iccid)
    card_id_digits=$(printf '%s' "$card_id" | tr -cd '0-9')
    card_id_length=${#card_id_digits}
    card_issuer_prefix=$(printf '%.8s' "$card_id_digits")

    echo "card_flag_type=$(json_type "$sim_json" seecom_card_flag)"
    echo "card_flag_value=$(json_get "$sim_json" seecom_card_flag)"
    echo "carrier_type=$(json_get "$sim_json" seecom_card_carrier_type)"
    echo "operator=$(json_get "$sim_json" Operator)"
    echo "mcc=$(json_get "$sim_json" mdm_mcc)"
    echo "mnc=$(json_get "$sim_json" mdm_mnc)"
    echo "gid1=$(json_get "$sim_json" sim_gid1)"
    echo "gid1_string=$(json_get "$sim_json" sim_gid1_string)"
    echo "spn_name_data=$(json_get "$sim_json" spn_name_data)"
    echo "spn_b1_flag=$(json_get "$sim_json" spn_b1_flag)"
    echo "spn_b2_flag=$(json_get "$sim_json" spn_b2_flag)"
    echo "card_issuer_prefix=${card_issuer_prefix:-unknown}"
    echo "card_id_length=${card_id_length:-0}"
    echo "sim_atr=$(uci -q get zwrt_zte_mdm.sim_info.sim_atr 2>/dev/null)"
    echo "uci_card_flag=$(uci -q get zwrt_zte_mdm.sim_info.seecom_card_flag 2>/dev/null)"
    echo "uci_carrier_type=$(uci -q get zwrt_zte_mdm.sim_info.seecom_card_carrier_type 2>/dev/null)"
    echo "uci_card_operator=$(uci -q get zwrt_zte_mdm.sim_info.card_operator 2>/dev/null)"
    echo "uci_reset_refresh_flag=$(uci -q get zwrt_zte_mdm.sim_info.reset_refresh_flag 2>/dev/null)"
}

emit_card_shape() {
    shape_name="$1"
    shape_digits=$(printf '%s' "$2" | tr -cd '0-9')
    shape_length=${#shape_digits}
    shape_prefix=$(printf '%.8s' "$shape_digits")
    echo "${shape_name}_prefix=${shape_prefix:-unknown}"
    echo "${shape_name}_length=${shape_length:-0}"
}

collect_detection_matrix() {
    known_atr="3B9F11801FC78031E073FE211B57378660C90200215C"
    known_prefix="89860487"
    sim_json=$(ubus -t 4 call zwrt_zte_mdm.api get_sim_info '{}' 2>/dev/null)
    flag_type=$(json_type "$sim_json" seecom_card_flag)
    flag_value=$(json_get "$sim_json" seecom_card_flag)
    api_card=$(json_get "$sim_json" sim_iccid)
    api_card_digits=$(printf '%s' "$api_card" | tr -cd '0-9')
    api_prefix=$(printf '%.8s' "$api_card_digits")
    api_length=${#api_card_digits}
    atr=$(uci -q get zwrt_zte_mdm.sim_info.sim_atr 2>/dev/null | tr '[:lower:]' '[:upper:]' | tr -cd '0-9A-F')
    slot_fingerprint_match=0
    for slot_key in simcard_0_iccid simcard_1_iccid; do
        slot_card=$(uci -q get "zwrt_zte_mdm.sim_info.$slot_key" 2>/dev/null | tr -cd '0-9')
        slot_prefix=$(printf '%.8s' "$slot_card")
        slot_length=${#slot_card}
        if [ "$slot_prefix" = "$known_prefix" ] && [ "$slot_length" = "20" ]; then
            slot_fingerprint_match=1
            break
        fi
    done

    flag_value_match=0
    flag_string_match=0
    case "$flag_value" in 1|2) flag_value_match=1 ;; esac
    if [ "$flag_type" = "string" ] && [ "$flag_value_match" = "1" ]; then
        flag_string_match=1
    fi
    atr_match=0
    prefix_match=0
    length_match=0
    fingerprint_match=0
    [ "$atr" = "$known_atr" ] && atr_match=1
    [ "$api_prefix" = "$known_prefix" ] && prefix_match=1
    [ "$api_length" = "20" ] && length_match=1
    if [ "$atr_match" = "1" ] && [ "$prefix_match" = "1" ] && [ "$length_match" = "1" ]; then
        fingerprint_match=1
    fi

    legacy_detector_match=0
    updated_detector_match=0
    relaxed_flag_match=0
    if [ "$flag_string_match" = "1" ] || [ "$fingerprint_match" = "1" ]; then
        legacy_detector_match=1
    fi
    if [ "$flag_value_match" = "1" ] || [ "$fingerprint_match" = "1" ] ||
       { [ "$atr_match" = "1" ] && [ "$length_match" = "1" ] && [ "$slot_fingerprint_match" = "1" ]; }; then
        updated_detector_match=1
    fi
    if [ "$flag_value_match" = "1" ] || [ "$fingerprint_match" = "1" ]; then
        relaxed_flag_match=1
    fi

    echo "flag_type=${flag_type:-missing}"
    echo "flag_value=${flag_value:-missing}"
    echo "flag_value_is_1_or_2=$flag_value_match"
    echo "flag_is_supported_string=$flag_string_match"
    echo "known_atr_match=$atr_match"
    echo "known_card_prefix_match=$prefix_match"
    echo "card_length_20_match=$length_match"
    echo "known_fingerprint_match=$fingerprint_match"
    echo "physical_slot_fingerprint_match=$slot_fingerprint_match"
    echo "legacy_release_detector_match=$legacy_detector_match"
    echo "updated_detector_match=$updated_detector_match"
    echo "relaxed_numeric_flag_detector_match=$relaxed_flag_match"
    echo "devui_manual_display=$(sed -n '1p' /data/plugins/u60pro-devui/flymodem-display.conf 2>/dev/null | tr -d '[:space:]')"
    if [ "$atr_match" = "1" ] && [ "$length_match" = "1" ] &&
       [ "$slot_fingerprint_match" = "1" ] && [ "$prefix_match" != "1" ]; then
        echo "likely_issue=carrier_profile_changed_current_iccid"
    elif [ "$flag_value_match" != "1" ] && [ "$fingerprint_match" != "1" ]; then
        echo "likely_issue=unrecognized_card_batch_or_vendor_state"
    elif [ "$updated_detector_match" = "1" ]; then
        echo "likely_issue=installed_controller_or_ui_cache"
    else
        echo "likely_issue=unknown"
    fi

    emit_card_shape "api_primary_card" "$api_card"
    emit_card_shape "api_secondary_card" "$(json_get "$sim_json" sim2_iccid)"
    emit_card_shape "uci_current_card" "$(uci -q get zwrt_zte_mdm.sim_info.current_sim_iccid 2>/dev/null)"
    emit_card_shape "uci_primary_card" "$(uci -q get zwrt_zte_mdm.sim_info.sim_iccid 2>/dev/null)"
    emit_card_shape "uci_slot0_card" "$(uci -q get zwrt_zte_mdm.sim_info.simcard_0_iccid 2>/dev/null)"
    emit_card_shape "uci_slot1_card" "$(uci -q get zwrt_zte_mdm.sim_info.simcard_1_iccid 2>/dev/null)"
}

collect_controller_samples() {
    controller=
    for path in \
        /data/plugins/u60pro-devui/ui/functions/fmsimpin.sh \
        /data/plugins/u60pro-devui/functions/fmsimpin.sh; do
        if [ -r "$path" ]; then
            controller="$path"
            break
        fi
    done
    if [ -z "$controller" ]; then
        echo "controller_not_found=1"
        return
    fi
    echo "controller_path=$controller"
    ls -l "$controller" 2>/dev/null
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$controller" 2>/dev/null
    fi
    sample=1
    while [ "$sample" -le 3 ]; do
        echo "--- status_sample=$sample ---"
        sh "$controller" status 2>&1
        sample=$((sample + 1))
        [ "$sample" -gt 3 ] || sleep 2
    done
}

collect_detection_log() {
    for path in \
        /data/plugins/u60pro-devui/plugin-detect.log \
        /tmp/devui-fmswitch-action.log; do
        echo "--- path=$path ---"
        if [ -r "$path" ]; then
            tail -n 80 "$path"
        else
            echo "missing_or_unreadable=1"
        fi
    done
}

collect_vendor_references() {
    found=0
    for root in /www /etc /usr/lib/lua; do
        [ -d "$root" ] || continue
        data=$(grep -R -n -E 'seecom_card_flag|seecom_card_carrier_type|sim_change_pin_mode|mqtt_st_card_type_msg' "$root" 2>/dev/null | head -n 80)
        if [ -n "$data" ]; then
            printf '%s\n' "$data"
            found=1
        fi
    done
    [ "$found" = "1" ] || echo "<no matching vendor references>"
}

collect_devui_flycat_assets() {
    for path in \
        /data/plugins/u60pro-devui/ui/functions/fmswitch.html \
        /data/plugins/u60pro-devui/ui/functions/fmsimpin.sh \
        /data/plugins/u60pro-devui/functions/fmswitch.html \
        /data/plugins/u60pro-devui/functions/fmsimpin.sh; do
        if [ -e "$path" ]; then
            if [ -r "$path" ]; then
                echo "asset=readable path=$path"
            else
                echo "asset=not_readable path=$path"
            fi
        else
            echo "asset=missing path=$path"
        fi
    done
}

collect_relevant_uci() {
    found=0
    for package in zwrt_zte_mdm zte_mdm; do
        data=$(uci -q show "$package" 2>/dev/null | grep -Ei 'seecom|feimao|flycat|sim|card|slot|pin|provision|carrier|operator|st_')
        if [ -n "$data" ]; then
            printf '%s\n' "$data"
            found=1
        fi
    done
    [ "$found" = "1" ] || echo "<no matching UCI entries>"
}

collect_related_logs() {
    if ! command -v logread >/dev/null 2>&1; then
        echo "logread_unavailable=1"
        return
    fi
    data=$(logread 2>/dev/null | tail -n 600 | grep -Ei 'seecom|feimao|flycat|sim_change_pin|st_card_type|sim.*card|card.*sim')
    if [ -n "$data" ]; then
        printf '%s\n' "$data"
    else
        echo "<no matching recent log entries>"
    fi
}

collect_related_paths() {
    for root in /tmp /var/run /data; do
        [ -d "$root" ] || continue
        find "$root" -maxdepth 3 \( -iname '*seecom*' -o -iname '*feimao*' -o -iname '*flycat*' -o -iname '*sim*card*' \) -print 2>/dev/null
    done | head -n 100
}

{
    emit "Feimao/Seecom SIM diagnostic report"
    emit "collector_version=3"
    emit "read_only=1"
    emit "generated_at=$(date '+%F %T %z')"
    emit "warning=Sensitive identifiers are automatically redacted; review before public sharing."

    run_command "uname" uname -a
    run_command "OpenWrt release" collect_release
    run_command "board info" ubus -t 4 call system board '{}'

    run_command "zwrt_zte_mdm.api method names" collect_mdm_methods
    run_command "zwrt_mqtt.api method names" collect_mqtt_methods
    run_command "Seecom host and service state" collect_seecom_hosts
    run_command "MQTT card list state" ubus -t 8 call zwrt_mqtt.api get_auth_simcardlist '{}'
    run_command "get_card_iccid" collect_card_iccid_api
    run_command "derived card fingerprint" collect_card_fingerprint
    run_command "detector decision matrix" collect_detection_matrix
    run_command "installed Flymodem UI assets" collect_devui_flycat_assets
    run_command "get_sim_info" ubus -t 4 call zwrt_zte_mdm.api get_sim_info '{}'
    run_command "get_sim_info_before" ubus -t 4 call zwrt_zte_mdm.api get_sim_info_before '{}'
    run_command "sim_get_slot" ubus -t 4 call zwrt_zte_mdm.api sim_get_slot '{}'
    run_command "zte_get_current_slot_info" ubus -t 4 call zwrt_zte_mdm.api zte_get_current_slot_info '{}'
    run_command "get_zwrt_common_info" ubus -t 4 call zwrt_zte_mdm.api get_zwrt_common_info '{}'
    run_command "network info" ubus -t 4 call zte_nwinfo_api nwinfo_get_netinfo '{}'

    run_command "relevant UCI entries" collect_relevant_uci
    run_command "recent related logs" collect_related_logs
    run_command "related runtime paths" collect_related_paths
    run_command "installed controller samples" collect_controller_samples
    run_command "DevUI Flymodem detection logs" collect_detection_log
    run_command "vendor implementation references" collect_vendor_references

    if [ -r /data/plugins/u60pro-devui/ui/functions/fmsimpin.sh ]; then
        run_command "installed fmsimpin status" sh /data/plugins/u60pro-devui/ui/functions/fmsimpin.sh status
    elif [ -r /data/plugins/u60pro-devui/functions/fmsimpin.sh ]; then
        run_command "installed fmsimpin status" sh /data/plugins/u60pro-devui/functions/fmsimpin.sh status
    else
        section "installed fmsimpin status"
        emit "controller_not_found=1"
    fi

    section "end"
    emit "report_complete=1"
} | redact >"$OUTPUT"

printf 'Diagnostic report written to: %s\n' "$OUTPUT"
printf 'Please review it once, then send the complete file back to the maintainer.\n'
