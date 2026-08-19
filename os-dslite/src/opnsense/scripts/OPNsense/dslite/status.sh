#!/bin/sh

# DS-Lite / Fixed IP tunnel status script (health-aware)
# Health-check design ported from unchained-llc/os-ocnfixedip (BSD-2-Clause),
# adapted for the DS-Lite plugin (DS-Lite + Fixed IP modes).
#
# This endpoint is polled every five seconds by the settings page and on every
# dashboard widget tick, so the active network probes are cached: passive state
# (interface, route, alias, stored results) is always read fresh, while pings
# are re-run at most once per HEALTH_CACHE_TTL seconds and are invalidated
# whenever the tunnel's identity changes.

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/lib.sh"

get_config

MODE=$(get_mode)
FIXEDIP_UPDATE_URL=$(config_get "//OPNsense/dslite/fixedip_update_url")
FIXEDIP_AUTH_USER=$(config_get "//OPNsense/dslite/fixedip_auth_user")

HEALTH_CACHE="/var/run/dslite_health_cache"
HEALTH_CACHE_TTL=30

append_failure() {
    if [ -z "${health_failures}" ]; then
        health_failures="$1"
    else
        health_failures="${health_failures},$1"
    fi
}

append_probe_failure() {
    if [ -z "${probe_failures}" ]; then
        probe_failures="$1"
    else
        probe_failures="${probe_failures},$1"
    fi
}

emit() {
    printf '{"tunnel":{"status":"%s","connectivity":"%s","health":"%s","health_failures":"%s","mode":"%s","local_v6":"%s","aftr":"%s","ipv4":"%s","mtu":"%s","interface":"%s","reason":"%s"}}' \
        "$(json_escape "$1")" "$(json_escape "$2")" "$(json_escape "$3")" "$(json_escape "$4")" \
        "$(json_escape "$5")" "$(json_escape "$6")" "$(json_escape "$7")" "$(json_escape "$8")" \
        "$(json_escape "$9")" "$(json_escape "${10}")" "$(json_escape "${11}")"
}

if tunnel_exists; then
    ifdata=$(ifconfig "${TUNNEL_IF}" 2>/dev/null)
    # Same test as diagnostics.sh: an interface that is RUNNING but not UP is
    # not usable, and the two pages must not disagree about what "up" means.
    status="down"
    if printf '%s' "${ifdata}" | grep -q "UP" && printf '%s' "${ifdata}" | grep -q "RUNNING"; then
        status="up"
    fi

    local_v6=$(echo "${ifdata}" | awk '/tunnel inet6/ {gsub(/%.*/,"",$3); print $3; exit}')
    remote_v6=$(echo "${ifdata}" | awk '/tunnel inet6/ {gsub(/%.*/,"",$5); print $5; exit}')
    ipv4=$(echo "${ifdata}" | awk '/inet / {print $2; exit}')
    mtu_val=$(echo "${ifdata}" | sed -n 's/.*mtu \([0-9]*\).*/\1/p' | head -1)

    connectivity="untested"
    reason=""
    health="degraded"
    health_failures=""
    probe_failures=""

    br_v6_target="${remote_v6:-$(get_expected_aftr)}"
    ce_source="${local_v6}"
    if [ -z "${ce_source}" ] && read_alias_state; then
        ce_source="${ALIAS_ADDR}"
    fi

    # ---------------------------------------------------------------------
    # Passive checks: cheap, always evaluated fresh.
    # ---------------------------------------------------------------------

    # 1) Tunnel state
    [ "${status}" = "up" ] || append_failure "tunnel_state"

    # 2) Default route via the tunnel (DS-Lite also expects gateway AFTR_V4_ADDRESS)
    route_info=$(route -n get default 2>/dev/null)
    route_gateway=$(printf '%s' "${route_info}" | awk -F': ' '/gateway:/ {gsub(/[[:space:]]/,"",$2); print $2; exit}')
    route_iface=$(printf '%s' "${route_info}" | awk -F': ' '/interface:/ {gsub(/[[:space:]]/,"",$2); print $2; exit}')
    if [ "${route_iface}" != "${TUNNEL_IF}" ]; then
        append_failure "default_route"
    elif [ "${MODE}" = "dslite" ] && [ -n "${AFTR_V4_ADDRESS}" ] && [ "${route_gateway}" != "${AFTR_V4_ADDRESS}" ]; then
        append_failure "default_route"
    fi

    # 3) MTU configured vs actual
    expected_mtu="${MTU:-1460}"
    if [ -z "${mtu_val}" ] || [ "${mtu_val}" != "${expected_mtu}" ]; then
        append_failure "mtu"
    fi

    # 4) WAN /128 alias presence. Fixed IP puts the tunnel-local address there,
    #    MAP-E puts the derived CE address there; DS-Lite uses a native one.
    if [ "${MODE}" = "fixedip" ] || [ "${MODE}" = "mape" ]; then
        wan_if_device=$(get_wan_if_device)
        if [ -n "${ce_source}" ] && [ -n "${wan_if_device}" ] && ifconfig "${wan_if_device}" >/dev/null 2>&1; then
            iface_has_v6 "${wan_if_device}" "${ce_source}" || append_failure "wan_alias"
        else
            append_failure "wan_alias"
        fi
    fi

    # 5) Prefix update last result (Fixed IP only). A stored success that is
    #    older than PREFIX_UPDATE_MAX_AGE means the periodic job is not running,
    #    so it must not keep reporting healthy forever.
    if [ "${MODE}" = "fixedip" ] && [ -n "${FIXEDIP_UPDATE_URL}" ] && [ -n "${FIXEDIP_AUTH_USER}" ]; then
        if [ -f "${STATE_PREFIX_UPDATE}" ]; then
            read -r pts prc pcode < "${STATE_PREFIX_UPDATE}" 2>/dev/null
            case "${pts}" in
                ''|*[!0-9]*) pts=0 ;;
            esac
            pnow=$(date +%s)
            if [ "${prc}" != "0" ]; then
                append_failure "prefix_update"
            else
                # DynDNS-style endpoints answer good/nochg; transix answers OK.
                # Xpass returns HTML on success — stored as [HTML_response].
                case "${pcode}" in
                    good|nochg|OK|ok|\[HTML_response\]) : ;;
                    *) append_failure "prefix_update" ;;
                esac
            fi
            if [ "${pts}" -eq 0 ] || [ "${pts}" -gt "${pnow}" ] ||
               [ $(( pnow - pts )) -gt "${PREFIX_UPDATE_MAX_AGE}" ]; then
                append_failure "prefix_update_stale"
            fi
        else
            append_failure "prefix_update"
        fi
    fi

    # 6) DNS resolution (uses the resolver cache, so it stays in the hot path)
    resolve_answer=""
    if command -v drill >/dev/null 2>&1; then
        resolve_answer=$(drill one.one.one.one A 2>/dev/null | awk '/\tIN\tA\t/ {print $5; exit}')
    elif command -v host >/dev/null 2>&1; then
        resolve_answer=$(host -t A one.one.one.one 2>/dev/null | awk '/has address/ {print $NF; exit}')
    fi
    [ -n "${resolve_answer}" ] || append_failure "dns"

    # ---------------------------------------------------------------------
    # Active probes: cached, since each one can block for PING_WAIT_MS.
    # ---------------------------------------------------------------------

    cache_key="${ipv4},${ce_source},${br_v6_target},${mtu_val},${MODE}"
    now=$(date +%s)
    cache_hit=0

    if [ -f "${HEALTH_CACHE}" ]; then
        { read -r c_time; read -r c_key; read -r c_conn; read -r c_fail; read -r c_reason; } < "${HEALTH_CACHE}" 2>/dev/null
        case "${c_time}" in
            ''|*[!0-9]*) c_time=0 ;;
        esac
        if [ "${c_key}" = "${cache_key}" ] && [ "${c_time}" -le "${now}" ] &&
           [ $(( now - c_time )) -lt "${HEALTH_CACHE_TTL}" ]; then
            cache_hit=1
            connectivity="${c_conn}"
            probe_failures="${c_fail}"
            reason="${c_reason}"
        fi
    fi

    if [ "${cache_hit}" != "1" ]; then
        if [ -z "${ipv4}" ]; then
            connectivity="no internet"
            reason="No IPv4 address on tunnel interface"
            append_probe_failure "internet"
            append_probe_failure "ipv6_internet"
            append_probe_failure "mtu_probe"
            append_probe_failure "mtu_fragmentation"
        else
            # CE -> BR/AFTR reachability. Evaluated on its own: an AFTR that
            # filters ICMPv6 echo must not be able to mask working IPv4.
            br_ok=0
            if [ -z "${br_v6_target}" ] || [ -z "${ce_source}" ]; then
                append_probe_failure "ce_to_br"
            elif ping -6 -c 1 -W "${PING_WAIT_MS}" -S "${ce_source}" "${br_v6_target}" >/dev/null 2>&1; then
                br_ok=1
            else
                append_probe_failure "ce_to_br"
            fi

            # IPv4 Internet through the tunnel, independent of the BR probe.
            if ping -c 1 -W "${PING_WAIT_MS}" -S "${ipv4}" 1.1.1.1 >/dev/null 2>&1; then
                connectivity="connected"
            else
                connectivity="no internet"
                append_probe_failure "internet"
                if [ "${br_ok}" = "1" ]; then
                    reason="AFTR reachable but IPv4 Internet ping failed (1.1.1.1)"
                elif [ -z "${br_v6_target}" ]; then
                    reason="AFTR/BR endpoint not known"
                elif [ -z "${ce_source}" ]; then
                    reason="CE source IPv6 unavailable"
                else
                    reason="AFTR unreachable from CE (${ce_source} -> ${br_v6_target})"
                fi
            fi

            if [ -n "${ce_source}" ]; then
                ping -6 -c 1 -W "${PING_WAIT_MS}" -S "${ce_source}" 2606:4700:4700::1111 >/dev/null 2>&1 ||
                    append_probe_failure "ipv6_internet"
            else
                append_probe_failure "ipv6_internet"
            fi

            if [ -n "${mtu_val}" ] && [ "${mtu_val}" -ge 1280 ] 2>/dev/null; then
                # Base MTU probe on MSS clamp (effective limit) rather than nominal tunnel MTU.
                effective_mss="${MSS_CLAMP:-${MTU:-1460}}"
                probe=$(( effective_mss - 8 ))
                if [ "${probe}" -gt 0 ] 2>/dev/null; then
                    ping -D -c 1 -W "${PING_WAIT_MS}" -S "${ipv4}" -s "${probe}" 1.1.1.1 >/dev/null 2>&1 ||
                        append_probe_failure "mtu_probe"
                else
                    append_probe_failure "mtu_probe"
                fi
                # Xpass path does not handle oversized fragmented packets; skip for xpass profile.
                if ! xpass_provisioning; then
                    frag=$(( mtu_val + 100 - 28 ))
                    ping -c 1 -W "${PING_WAIT_MS}" -S "${ipv4}" -s "${frag}" 1.1.1.1 >/dev/null 2>&1 ||
                        append_probe_failure "mtu_fragmentation"
                fi
            else
                append_probe_failure "mtu_probe"
                append_probe_failure "mtu_fragmentation"
            fi
        fi

        printf '%s\n%s\n%s\n%s\n%s\n' \
            "${now}" "${cache_key}" "${connectivity}" "${probe_failures}" "${reason}" > "${HEALTH_CACHE}"
    fi

    # Merge the cached probe verdicts into the composite failure list.
    if [ -n "${probe_failures}" ]; then
        if [ -z "${health_failures}" ]; then
            health_failures="${probe_failures}"
        else
            health_failures="${health_failures},${probe_failures}"
        fi
    fi

    if [ -z "${health_failures}" ] && [ "${status}" = "up" ] && [ "${connectivity}" = "connected" ]; then
        health="healthy"
    else
        health="degraded"
    fi

    emit "${status}" "${connectivity}" "${health}" "${health_failures}" "${MODE}" \
         "${local_v6}" "${br_v6_target}" "${ipv4}" "${mtu_val}" "${TUNNEL_IF}" "${reason}"
else
    rm -f "${HEALTH_CACHE}"
    if [ "${DSLITE_ENABLED}" = "1" ]; then
        pd_prefix=$(get_pd_prefix)
        if [ -z "${pd_prefix}" ]; then
            reason="Waiting for IPv6 prefix delegation"
        elif [ -z "${AFTR_ADDRESS}" ] && [ "${MODE}" = "dslite" ]; then
            reason="Could not determine AFTR address"
        else
            reason="Not started - click Apply"
        fi
        emit "not configured" "offline" "offline" "tunnel_state" "${MODE}" \
             "-" "-" "-" "-" "${TUNNEL_IF}" "${reason}"
    else
        emit "disabled" "offline" "offline" "" "${MODE}" \
             "-" "-" "-" "-" "${TUNNEL_IF}" "Service is disabled"
    fi
fi
