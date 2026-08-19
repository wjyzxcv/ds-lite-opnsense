#!/bin/sh

# DS-Lite / Fixed IP diagnostics script
# Endpoint checks: tunnel state / route / alias / DNS / IPv4 / IPv6 /
# CE->AFTR reachability / MTU probes / prefix update (Fixed IP).
# Ported from unchained-llc/os-ocnfixedip (BSD-2-Clause), adapted for DS-Lite.
#
# This action is READ-ONLY. It reports the stored result of the last prefix
# update rather than performing one, so that opening or refreshing the
# diagnostics page never changes provider-side state or spends credentials.
# A live update is a separate, explicit action: "configctl dslite prefix_update".

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib.sh"

get_config

MODE=$(get_mode)
FIXEDIP_UPDATE_URL=$(config_get "//OPNsense/dslite/fixedip_update_url")
FIXEDIP_AUTH_USER=$(config_get "//OPNsense/dslite/fixedip_auth_user")

resolve_name="one.one.one.one"
resolve_a_status="untested";    resolve_a_answer="-"
resolve_aaaa_status="untested"; resolve_aaaa_answer="-"

inet_target="1.1.1.1";      inet_source="-";  inet_status="untested";  inet_rtt="-"
ipv6_target="2606:4700:4700::1111"; ipv6_source="-"; ipv6_status="untested"; ipv6_rtt="-"

ce_source=""; br_target=""; ce_to_br_status="untested"; ce_to_br_rtt="-"
wan_alias_if="-"; wan_alias_status="untested"

prefix_update_target="-"; prefix_update_status="untested"; prefix_update_result="-"
prefix_update_age="-"
tunnel_state_status="untested"; tunnel_state_detail="tunnel interface not checked"

route_target="-"; route_gateway="-"; route_iface="-"; route_status="untested"
mtu_expected="${MTU:-1460}"; mtu_actual="-"; mtu_status="untested"
mtu_probe_payload="-"; mtu_probe_status="untested"; mtu_probe_rtt="-"
mtu_frag_payload="-"; mtu_frag_status="untested"; mtu_frag_rtt="-"

# DNS A/AAAA
if command -v drill >/dev/null 2>&1; then
    resolve_a_answer=$(drill "${resolve_name}" A 2>/dev/null | awk '/\tIN\tA\t/ {print $5; exit}')
    resolve_aaaa_answer=$(drill "${resolve_name}" AAAA 2>/dev/null | awk '/\tIN\tAAAA\t/ {print $5; exit}')
elif command -v host >/dev/null 2>&1; then
    resolve_a_answer=$(host -t A "${resolve_name}" 2>/dev/null | awk '/has address/ {print $NF; exit}')
    resolve_aaaa_answer=$(host -t AAAA "${resolve_name}" 2>/dev/null | awk '/has IPv6 address/ {print $NF; exit}')
else
    resolve_a_status="skipped"; resolve_aaaa_status="skipped"
fi
[ "${resolve_a_status}" = "skipped" ] || { [ -n "${resolve_a_answer}" ] && resolve_a_status="ok" || { resolve_a_status="ng"; resolve_a_answer="-"; }; }
[ "${resolve_aaaa_status}" = "skipped" ] || { [ -n "${resolve_aaaa_answer}" ] && resolve_aaaa_status="ok" || { resolve_aaaa_status="ng"; resolve_aaaa_answer="-"; }; }

if tunnel_exists; then
    ifdata=$(ifconfig "${TUNNEL_IF}" 2>/dev/null)
    tunnel_ipv4=$(printf '%s' "${ifdata}" | awk '/inet / {print $2; exit}')
    mtu_actual=$(printf '%s' "${ifdata}" | sed -n 's/.*mtu \([0-9]*\).*/\1/p' | head -1)

    if printf '%s' "${ifdata}" | grep -q "UP" && printf '%s' "${ifdata}" | grep -q "RUNNING"; then
        tunnel_state_status="ok"; tunnel_state_detail="${TUNNEL_IF} is UP/RUNNING"
    else
        tunnel_state_status="ng"; tunnel_state_detail="${TUNNEL_IF} is not RUNNING"
    fi

    if [ -n "${mtu_actual}" ] && [ "${mtu_actual}" = "${mtu_expected}" ]; then
        mtu_status="ok"
    elif [ -n "${mtu_actual}" ]; then
        mtu_status="ng"
    else
        mtu_status="ng"; mtu_actual="-"
    fi

    remote_v6=$(printf '%s' "${ifdata}" | awk '/tunnel inet6/ {print $5; exit}')
    local_v6=$(printf '%s' "${ifdata}" | awk '/tunnel inet6/ {print $3; exit}')
    br_target="${remote_v6:-$(get_expected_aftr)}"
    ce_source="${local_v6}"
    if [ -z "${ce_source}" ] && read_alias_state; then
        ce_source="${ALIAS_ADDR}"
    fi

    # WAN /128 alias (Fixed IP and MAP-E both place one on the WAN device)
    if [ "${MODE}" = "fixedip" ] || [ "${MODE}" = "mape" ]; then
        wan_alias_if=$(get_wan_if_device)
        if [ -n "${ce_source}" ] && [ -n "${wan_alias_if}" ] && ifconfig "${wan_alias_if}" >/dev/null 2>&1; then
            if iface_has_v6 "${wan_alias_if}" "${ce_source}"; then
                wan_alias_status="ok"
            else
                wan_alias_status="ng"
            fi
        else
            wan_alias_status="skipped"
        fi
    else
        wan_alias_status="skipped"
    fi

    if [ -n "${tunnel_ipv4}" ]; then
        inet_source="${tunnel_ipv4}"
        inet_ping_out=$(ping -c 1 -W "${PING_WAIT_MS}" -S "${tunnel_ipv4}" "${inet_target}" 2>&1)
        if [ $? -eq 0 ]; then
            inet_status="ok"
            inet_rtt=$(printf '%s' "${inet_ping_out}" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
            [ -n "${inet_rtt}" ] || inet_rtt="-"
        else
            inet_status="ng"
        fi

        if [ -n "${mtu_actual}" ] && [ "${mtu_actual}" -ge 1280 ] 2>/dev/null; then
            # Base MTU probe on MSS clamp (effective limit) rather than nominal tunnel MTU.
            effective_mss="${MSS_CLAMP:-${MTU:-1460}}"
            mtu_probe_payload=$(( effective_mss - 8 ))
            mtu_probe_out=$(ping -D -c 1 -W "${PING_WAIT_MS}" -S "${tunnel_ipv4}" -s "${mtu_probe_payload}" "${inet_target}" 2>&1)
            if [ $? -eq 0 ]; then
                mtu_probe_status="ok"
                mtu_probe_rtt=$(printf '%s' "${mtu_probe_out}" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
                [ -n "${mtu_probe_rtt}" ] || mtu_probe_rtt="-"
            else
                mtu_probe_status="ng"
            fi
            # Xpass path does not handle oversized fragmented packets; skip for xpass profile.
            if ! xpass_provisioning; then
                mtu_frag_payload=$(( mtu_actual + 100 - 28 ))
                mtu_frag_out=$(ping -c 1 -W "${PING_WAIT_MS}" -S "${tunnel_ipv4}" -s "${mtu_frag_payload}" "${inet_target}" 2>&1)
                if [ $? -eq 0 ]; then
                    mtu_frag_status="ok"
                    mtu_frag_rtt=$(printf '%s' "${mtu_frag_out}" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
                    [ -n "${mtu_frag_rtt}" ] || mtu_frag_rtt="-"
                else
                    mtu_frag_status="ng"
                fi
            else
                mtu_frag_status="skipped"
            fi
        else
            mtu_probe_status="skipped"; mtu_frag_status="skipped"
        fi
    else
        inet_status="skipped"; mtu_probe_status="skipped"; mtu_frag_status="skipped"
    fi

    # CE -> AFTR/BR
    if [ -n "${ce_source}" ] && [ -n "${br_target}" ]; then
        ce_br_out=$(ping -6 -c 1 -W "${PING_WAIT_MS}" -S "${ce_source}" "${br_target}" 2>&1)
        if [ $? -eq 0 ]; then
            ce_to_br_status="ok"
            ce_to_br_rtt=$(printf '%s' "${ce_br_out}" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
            [ -n "${ce_to_br_rtt}" ] || ce_to_br_rtt="-"
        else
            ce_to_br_status="ng"
        fi
    elif [ -z "${br_target}" ]; then
        ce_to_br_status="not-configured"
    else
        ce_to_br_status="skipped"
    fi

    # IPv6 internet from CE
    if [ -n "${ce_source}" ]; then
        ipv6_source="${ce_source}"
        ipv6_out=$(ping -6 -c 1 -W "${PING_WAIT_MS}" -S "${ce_source}" "${ipv6_target}" 2>&1)
        if [ $? -eq 0 ]; then
            ipv6_status="ok"
            ipv6_rtt=$(printf '%s' "${ipv6_out}" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
            [ -n "${ipv6_rtt}" ] || ipv6_rtt="-"
        else
            ipv6_status="ng"
        fi
    else
        ipv6_status="skipped"
    fi
else
    tunnel_state_status="skipped"; tunnel_state_detail="${TUNNEL_IF} does not exist"
    wan_alias_status="skipped"; mtu_status="skipped"; inet_status="skipped"
    mtu_probe_status="skipped"; mtu_frag_status="skipped"; ce_to_br_status="skipped"; ipv6_status="skipped"
fi

# Default route
route_info=$(route -n get default 2>/dev/null)
if [ -n "${route_info}" ]; then
    route_gateway=$(printf '%s' "${route_info}" | awk -F': ' '/gateway:/ {print $2; exit}')
    route_iface=$(printf '%s' "${route_info}" | awk -F': ' '/interface:/ {print $2; exit}')
    if [ "${MODE}" = "dslite" ]; then
        route_target="${AFTR_V4_ADDRESS:-192.0.0.1}"
        if [ "${route_gateway}" = "${route_target}" ] && [ "${route_iface}" = "${TUNNEL_IF}" ]; then
            route_status="ok"
        else
            route_status="ng"
        fi
    else
        route_target="interface:${TUNNEL_IF}"
        if [ "${route_iface}" = "${TUNNEL_IF}" ]; then
            route_status="ok"
        else
            route_status="ng"
        fi
    fi
else
    route_status="ng"
fi

# Prefix update: report the stored result of the last run. Performing a live
# authenticated request here would make merely opening this page change
# provider-side state; use the explicit "Run prefix update" action instead.
if [ "${MODE}" = "fixedip" ] && [ -n "${FIXEDIP_UPDATE_URL}" ] && [ -n "${FIXEDIP_AUTH_USER}" ]; then
    prefix_update_target="${FIXEDIP_UPDATE_URL}"
    if [ -f "${STATE_PREFIX_UPDATE}" ]; then
        read -r pu_ts pu_rc pu_code < "${STATE_PREFIX_UPDATE}" 2>/dev/null
        case "${pu_ts}" in
            ''|*[!0-9]*) pu_ts=0 ;;
        esac
        prefix_update_result="${pu_code:--}"

        if [ "${pu_rc}" = "0" ]; then
            # Two response vocabularies are in play: the DynDNS-style endpoints
            # answer good/nochg, transix answers OK (and NG on failure).
            # Xpass returns HTML on success — stored as [HTML_response].
            case "${pu_code}" in
                good|nochg|OK|ok|\[HTML_response\]) prefix_update_status="ok" ;;
                *) prefix_update_status="ng" ;;
            esac
        else
            prefix_update_status="ng"
        fi

        pu_now=$(date +%s)
        if [ "${pu_ts}" -gt 0 ] && [ "${pu_ts}" -le "${pu_now}" ]; then
            prefix_update_age=$(( pu_now - pu_ts ))
            if [ "${prefix_update_age}" -gt "${PREFIX_UPDATE_MAX_AGE}" ]; then
                # A stored success this old means the periodic job is not running.
                prefix_update_status="stale"
            fi
            prefix_update_age="${prefix_update_age}s"
        else
            prefix_update_status="stale"
            prefix_update_age="unknown"
        fi
    else
        prefix_update_status="untested"
        prefix_update_result="no update recorded yet"
    fi
else
    prefix_update_status="not-configured"
fi

# Escape every dynamic value before interpolation. Several of these are derived
# from data we do not control -- provider responses, DNS answers, ifconfig
# output -- and an unescaped quote or backslash would produce a document the
# controller cannot json_decode(), leaving the page with no usable response.
for _f in \
    MODE tunnel_state_status tunnel_state_detail \
    route_target route_gateway route_iface route_status \
    wan_alias_if ce_source wan_alias_status br_target ce_to_br_status ce_to_br_rtt \
    prefix_update_target prefix_update_status prefix_update_result prefix_update_age \
    inet_source inet_target inet_status inet_rtt \
    ipv6_source ipv6_target ipv6_status ipv6_rtt \
    resolve_name resolve_a_status resolve_a_answer resolve_aaaa_status resolve_aaaa_answer \
    mtu_expected mtu_actual mtu_status \
    mtu_probe_payload mtu_probe_status mtu_probe_rtt \
    mtu_frag_payload mtu_frag_status mtu_frag_rtt
do
    eval "_v=\${${_f}}"
    eval "${_f}=\$(json_escape \"\${_v}\")"
done

printf '{"mode":"%s","checks":{"tunnel_state":{"status":"%s","detail":"%s"},"default_route":{"target":"%s","gateway":"%s","interface":"%s","status":"%s"},"wan_alias":{"interface":"%s","source":"%s","status":"%s"},"ce_to_aftr":{"source":"%s","target":"%s","status":"%s","rtt_ms":"%s"},"prefix_update":{"target":"%s","status":"%s","result":"%s","age":"%s"},"internet_v4":{"source":"%s","target":"%s","status":"%s","rtt_ms":"%s"},"internet_v6":{"source":"%s","target":"%s","status":"%s","rtt_ms":"%s"},"resolve_a":{"target":"%s","status":"%s","answer":"%s"},"resolve_aaaa":{"target":"%s","status":"%s","answer":"%s"},"mtu":{"expected":"%s","actual":"%s","status":"%s"},"mtu_probe":{"target":"%s","payload":"%s","status":"%s","rtt_ms":"%s"},"mtu_fragmentation":{"target":"%s","payload":"%s","status":"%s","rtt_ms":"%s"}}}' \
    "${MODE}" \
    "${tunnel_state_status}" "${tunnel_state_detail}" \
    "${route_target}" "${route_gateway}" "${route_iface}" "${route_status}" \
    "${wan_alias_if}" "${ce_source}" "${wan_alias_status}" \
    "${ce_source}" "${br_target}" "${ce_to_br_status}" "${ce_to_br_rtt}" \
    "${prefix_update_target}" "${prefix_update_status}" "${prefix_update_result}" "${prefix_update_age}" \
    "${inet_source}" "${inet_target}" "${inet_status}" "${inet_rtt}" \
    "${ipv6_source}" "${ipv6_target}" "${ipv6_status}" "${ipv6_rtt}" \
    "${resolve_name}" "${resolve_a_status}" "${resolve_a_answer}" \
    "${resolve_name}" "${resolve_aaaa_status}" "${resolve_aaaa_answer}" \
    "${mtu_expected}" "${mtu_actual}" "${mtu_status}" \
    "${inet_target}" "${mtu_probe_payload}" "${mtu_probe_status}" "${mtu_probe_rtt}" \
    "${inet_target}" "${mtu_frag_payload}" "${mtu_frag_status}" "${mtu_frag_rtt}"
