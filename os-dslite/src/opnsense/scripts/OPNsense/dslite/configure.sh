#!/bin/sh

# DS-Lite / Fixed IP tunnel configuration script
# Creates gif tunnel interface for IPv4-in-IPv6 encapsulation
#
# Invocation: no argument for the hook-driven path (boot, WAN renewal, Apply),
# "restart" to tear down first, "start" from the service control.

SCRIPT_DIR=$(dirname "$0")

# Serialize concurrent invocations. rc.newwanip, a config save and the service
# control can all fire at once; a wall-clock comparison is not serialization.
LOCK_FILE="/var/run/dslite_configure.lock"
if [ -z "${DSLITE_CONFIGURE_LOCKED}" ] && [ -x /usr/bin/lockf ]; then
    DSLITE_CONFIGURE_LOCKED=1
    export DSLITE_CONFIGURE_LOCKED
    exec /usr/bin/lockf -k -t 120 "${LOCK_FILE}" "$0" "$@"
fi

. "${SCRIPT_DIR}/lib.sh"

# Load configuration
get_config

ACTION="$1"
STAMP_FILE="/var/run/dslite_configure.stamp"

# Coalesce redundant hook-driven runs. Only the asynchronous path is debounced:
# an explicit start/restart, and any run following a failure, must always do the
# work. The stamp is written after a successful run, never before, so a failed
# attempt can never suppress the retry that fixes it.
case "${ACTION}" in
    restart|start)
        ;;
    *)
        if [ -f "${STAMP_FILE}" ]; then
            LAST=$(cat "${STAMP_FILE}" 2>/dev/null)
            case "${LAST}" in
                ''|*[!0-9]*) LAST=0 ;;
            esac
            NOW=$(date +%s)
            # A backwards clock step would otherwise suppress work indefinitely.
            if [ "${LAST}" -le "${NOW}" ] && [ $(( NOW - LAST )) -lt 3 ]; then
                logger -t dslite "Skipping duplicate configure trigger"
                exit 0
            fi
        fi
        ;;
esac

# Check if we should tear down first (restart)
if [ "${ACTION}" = "restart" ]; then
    "${SCRIPT_DIR}/teardown.sh"
fi

# Bail out if not enabled
if [ "${DSLITE_ENABLED}" != "1" ]; then
    logger -t dslite "DS-Lite is disabled, tearing down any existing tunnel"
    "${SCRIPT_DIR}/teardown.sh"
    exit 0
fi

# Determine tunnel parameters based on mode
TUNNEL_MODE=$(get_mode)

WAN_IF=$(get_wan_if_device)

if [ "${TUNNEL_MODE}" = "fixedip" ]; then
    # Fixed IP mode: use member-specific parameters from Asahi Net / v6 Connect
    FIXEDIP_INTERFACE_ID=$(config_get "//OPNsense/dslite/fixedip_interface_id")
    FIXEDIP_AFTR=$(config_get "//OPNsense/dslite/fixedip_aftr")
    FIXEDIP_V4=$(config_get "//OPNsense/dslite/fixedip_v4")
    FIXEDIP_UPDATE_URL=$(config_get "//OPNsense/dslite/fixedip_update_url")
    FIXEDIP_AUTH_USER=$(config_get "//OPNsense/dslite/fixedip_auth_user")
    FIXEDIP_AUTH_PASS=$(config_get "//OPNsense/dslite/fixedip_auth_pass")

    AFTR_ADDRESS="${FIXEDIP_AFTR}"
    B4_ADDRESS="${FIXEDIP_V4}"
    AFTR_V4_ADDRESS=""

    # Xpass uses actual SLAAC-assigned address directly (no Interface ID derivation).
    if xpass_provisioning; then
        if [ -z "${FIXEDIP_AFTR}" ] || [ -z "${FIXEDIP_V4}" ]; then
            logger -t dslite "ERROR: Fixed IP mode requires AFTR endpoint and Fixed IPv4 address"
            exit 1
        fi

        # Wait for SLAAC-assigned global IPv6 on WAN interface.
        LOCAL_V6=$(get_wan_ipv6)
        if [ -z "${LOCAL_V6}" ]; then
            for attempt in 1 2 3 4 5 6; do
                logger -t dslite "Waiting for SLAAC-assigned IPv6 (attempt ${attempt}/6)..."
                sleep 5
                LOCAL_V6=$(get_wan_ipv6)
                [ -n "${LOCAL_V6}" ] && break
            done
        fi

        if [ -z "${LOCAL_V6}" ]; then
            logger -t dslite "ERROR: No global IPv6 address found on WAN interface for xpass tunnel"
            exit 1
        fi

        logger -t dslite "Xpass mode: using SLAAC-assigned CE address ${LOCAL_V6}"
    else
        # Transix/Enabler: Interface ID required, combined with prefix via provider-specific placement.
        if [ -z "${FIXEDIP_INTERFACE_ID}" ] || [ -z "${FIXEDIP_AFTR}" ] || [ -z "${FIXEDIP_V4}" ]; then
            logger -t dslite "ERROR: Fixed IP mode requires Interface ID, AFTR endpoint, and Fixed IPv4 address"
            exit 1
        fi

        # Combine the provider's Interface ID with our prefix to form the routable
        # tunnel source. How the ID maps in is provider-specific; see
        # fixedip_iid_placement() in lib.sh for why this cannot be inferred.
        #
        # The anchor does not exist yet at boot -- DHCPv6 and PD land after the
        # interface is up -- and deriving early would produce a CE the AFTR refuses
        # while the tunnel still comes up, i.e. a silent blackhole. Retry on the
        # same cadence as the DS-Lite and MAP-E branches.
        LOCAL_V6=$(fixedip_local_v6 "${FIXEDIP_INTERFACE_ID}")
        if [ -z "${LOCAL_V6}" ]; then
            for attempt in 1 2 3 4 5 6; do
                logger -t dslite "Waiting for IPv6 prefix delegation (attempt ${attempt}/6)..."
                sleep 5
                LOCAL_V6=$(fixedip_local_v6 "${FIXEDIP_INTERFACE_ID}")
                [ -n "${LOCAL_V6}" ] && break
            done
        fi

        # Fallback: no prefix available yet, or no python3. The operator may also
        # have entered a full address rather than an ID, in which case this is
        # already correct.
        if [ -z "${LOCAL_V6}" ]; then
            LOCAL_V6="${FIXEDIP_INTERFACE_ID}"
            logger -t dslite "Could not derive CE address from Interface ID; using ${LOCAL_V6} verbatim"
        else
            logger -t dslite "CE address ${LOCAL_V6} derived from Interface ID ${FIXEDIP_INTERFACE_ID} ($(fixedip_iid_placement) placement)"
        fi
    fi

    # Assign/refresh the tunnel-local /128 on WAN, cleaning up any stale alias.
    # A failure here means the tunnel source address does not exist, so the
    # replacement tunnel would be unusable: stop before destroying the working
    # one rather than after.
    if ! manage_wan_alias "${LOCAL_V6}" "${WAN_IF}"; then
        logger -t dslite "ERROR: could not establish WAN /128 alias ${LOCAL_V6} on ${WAN_IF}; leaving the existing tunnel untouched"
        exit 1
    fi
    sleep 1

    # Refresh the provider-side registration, but only if the CE actually moved.
    # A reconfigure is not evidence that it did: the tunnel is rebuilt on every
    # WAN renewal, and the delegated prefix usually survives those unchanged.
    # Credentials never go over an unverified connection.
    fixedip_register_if_changed "${FIXEDIP_UPDATE_URL}" "${FIXEDIP_AUTH_USER}" \
        "${FIXEDIP_AUTH_PASS}" "${FIXEDIP_ALLOW_INSECURE}" "${LOCAL_V6}"

    logger -t dslite "Fixed IP mode: local=${LOCAL_V6} aftr=${AFTR_ADDRESS} ipv4=${B4_ADDRESS}"
elif [ "${TUNNEL_MODE}" = "mape" ]; then
    # MAP-E (RFC 7597) -- EXPERIMENTAL.
    MAPE_PROFILE=$(config_get "//OPNsense/dslite/mape_profile")
    MAPE_BR=$(config_get "//OPNsense/dslite/mape_br")
    MAPE_RULE_IPV6=$(config_get "//OPNsense/dslite/mape_rule_ipv6")
    MAPE_RULE_IPV4=$(config_get "//OPNsense/dslite/mape_rule_ipv4")
    MAPE_EA_LENGTH=$(config_get "//OPNsense/dslite/mape_ea_length")
    MAPE_PSID_OFFSET=$(config_get "//OPNsense/dslite/mape_psid_offset")

    # A profile supplies only the service-wide constants; the rule prefixes and
    # EA length are per-subscriber and must come from the operator.
    if [ -n "${MAPE_PROFILE}" ] && [ "${MAPE_PROFILE}" != "custom" ]; then
        if mape_profile_lookup "${MAPE_PROFILE}"; then
            [ -n "${MAPE_BR}" ] || MAPE_BR="${MAPE_P_BR}"
            [ -n "${MAPE_PSID_OFFSET}" ] || MAPE_PSID_OFFSET="${MAPE_P_OFFSET}"
        else
            logger -t dslite "WARNING: unknown MAP-E profile '${MAPE_PROFILE}'"
        fi
    fi
    MAPE_PSID_OFFSET="${MAPE_PSID_OFFSET:-6}"

    if [ -z "${MAPE_BR}" ] || [ -z "${MAPE_RULE_IPV6}" ] || [ -z "${MAPE_RULE_IPV4}" ] ||
       [ -z "${MAPE_EA_LENGTH}" ]; then
        logger -t dslite "ERROR: MAP-E mode requires BR address, rule IPv6 prefix, rule IPv4 prefix and EA-bits length"
        exit 1
    fi

    # Without map-e-portset, pf would translate to source ports outside our
    # assigned set and the BR would silently drop the traffic. Refuse rather
    # than bring up a tunnel that looks fine and does not pass packets.
    if ! mape_pf_supported; then
        logger -t dslite "ERROR: this pf does not support map-e-portset; MAP-E requires a FreeBSD base with RFC 7597 NAT port selection"
        exit 1
    fi

    PD_PREFIX=$(get_pd_prefix)
    if [ -z "${PD_PREFIX}" ]; then
        for attempt in 1 2 3 4 5 6; do
            logger -t dslite "Waiting for IPv6 prefix delegation (attempt ${attempt}/6)..."
            sleep 5
            PD_PREFIX=$(get_pd_prefix)
            [ -n "${PD_PREFIX}" ] && break
        done
    fi
    if [ -z "${PD_PREFIX}" ]; then
        logger -t dslite "ERROR: MAP-E needs the delegated IPv6 prefix to derive the IPv4 address and PSID"
        exit 1
    fi

    # Derivation refuses when the delegated prefix does not fall inside the
    # rule, so a wrong rule fails here instead of producing a plausible but
    # incorrect port set.
    MAPE_DERIVED=$(mape_derive "${PD_PREFIX}" "${MAPE_RULE_IPV6}" "${MAPE_RULE_IPV4}" \
        "${MAPE_EA_LENGTH}" "${MAPE_PSID_OFFSET}")
    if [ -z "${MAPE_DERIVED}" ]; then
        logger -t dslite "ERROR: MAP-E rule does not match the delegated prefix ${PD_PREFIX} (rule ${MAPE_RULE_IPV6} ea=${MAPE_EA_LENGTH} offset=${MAPE_PSID_OFFSET})"
        exit 1
    fi

    set -- ${MAPE_DERIVED}
    MAPE_IPV4="$1"
    MAPE_PSID="$2"
    MAPE_PSID_LEN="$3"
    MAPE_CE="$4"
    MAPE_RANGES="$5"
    MAPE_PORTS="$6"

    AFTR_ADDRESS="${MAPE_BR}"
    B4_ADDRESS="${MAPE_IPV4}"
    AFTR_V4_ADDRESS=""
    LOCAL_V6="${MAPE_CE}"

    if ! manage_wan_alias "${LOCAL_V6}" "${WAN_IF}"; then
        logger -t dslite "ERROR: could not establish WAN /128 alias ${LOCAL_V6} on ${WAN_IF}; leaving the existing tunnel untouched"
        exit 1
    fi
    sleep 1

    logger -t dslite "MAP-E mode: ce=${MAPE_CE} br=${MAPE_BR} ipv4=${MAPE_IPV4} psid=${MAPE_PSID}/${MAPE_PSID_LEN} offset=${MAPE_PSID_OFFSET} (${MAPE_PORTS} ports in ${MAPE_RANGES} ranges)"
else
    # Standard DS-Lite mode
    if [ -z "${AFTR_ADDRESS}" ]; then
        logger -t dslite "ERROR: No AFTR address configured or resolved"
        exit 1
    fi

    # A native global address on the WAN is preferred. Any /128 we manage
    # ourselves is dropped first so that a Fixed IP -> DS-Lite mode change does
    # not leave a stale alias behind, and cannot be picked as the source.
    if read_alias_state; then
        if ! remove_wan_alias "${WAN_IF}"; then
            logger -t dslite "ERROR: could not remove the managed WAN /128 alias; aborting"
            exit 1
        fi
    fi

    # Get WAN IPv6 address (global scope)
    LOCAL_V6=$(get_wan_ipv6)

    # If no global address, try to derive one from DHCPv6-PD prefix
    if [ -z "${LOCAL_V6}" ]; then
        logger -t dslite "No global IPv6 on WAN, attempting to derive from PD prefix"
        # PD may not be ready at boot, so retry for a while.
        for attempt in 1 2 3 4 5 6; do
            PD_PREFIX=$(get_pd_prefix)
            if [ -n "${PD_PREFIX}" ]; then
                BASE_PREFIX=$(echo "${PD_PREFIX}" | sed 's|/.*||; s/::$//')
                LOCAL_V6="${BASE_PREFIX}::1"
                if ! manage_wan_alias "${LOCAL_V6}" "${WAN_IF}"; then
                    logger -t dslite "ERROR: could not establish WAN /128 alias ${LOCAL_V6} on ${WAN_IF}"
                    exit 1
                fi
                sleep 1
                break
            fi
            logger -t dslite "Waiting for IPv6 prefix delegation (attempt ${attempt}/6)..."
            sleep 5
        done
    fi

    if [ -z "${LOCAL_V6}" ]; then
        logger -t dslite "ERROR: No global IPv6 address found on WAN interface (${WAN_INTERFACE})"
        exit 1
    fi

    logger -t dslite "DS-Lite mode: local=${LOCAL_V6} aftr=${AFTR_ADDRESS}"
fi

# Fixed IP and MAP-E both put a single public IPv4 on the tunnel and route via
# the interface; DS-Lite uses the RFC 6333 B4/AFTR point-to-point pair.
case "${TUNNEL_MODE}" in
    fixedip|mape) TUNNEL_P2P=1 ;;
    *) TUNNEL_P2P=0 ;;
esac

# Tear down the existing tunnel, but only when it is ours. A gif unit belonging to
# another consumer must not be hijacked.
if tunnel_exists; then
    if tunnel_is_ours "${TUNNEL_IF}"; then
        logger -t dslite "Removing existing tunnel interface ${TUNNEL_IF}"
        ifconfig "${TUNNEL_IF}" destroy 2>/dev/null
    else
        logger -t dslite "ERROR: ${TUNNEL_IF} exists but was not created by this plugin; refusing to take it over. Pick a free gif unit under Interfaces > DS-Lite (Tunnel Interface), or remove the conflicting tunnel."
        exit 1
    fi
fi
rm -f "${STATE_OWNED_IF}"

# Create gif tunnel interface
if ! ifconfig "${TUNNEL_IF}" create; then
    logger -t dslite "ERROR: Failed to create ${TUNNEL_IF}"
    exit 1
fi

# Configure IPv6 tunnel endpoints (IPv4-in-IPv6)
if ! ifconfig "${TUNNEL_IF}" inet6 tunnel "${LOCAL_V6}" "${AFTR_ADDRESS}"; then
    logger -t dslite "ERROR: Failed to set tunnel endpoints"
    ifconfig "${TUNNEL_IF}" destroy 2>/dev/null
    exit 1
fi

# Claim ownership as soon as the endpoints are in place, so that a teardown
# after a partial failure still knows this interface is ours to remove.
record_owned_tunnel "${TUNNEL_IF}" "${LOCAL_V6}" "${AFTR_ADDRESS}"

# Configure IPv4 addresses on tunnel
if [ "${TUNNEL_P2P}" = "1" ]; then
    # Fixed IP / MAP-E: assign the public IPv4 as point-to-point on the tunnel
    ifconfig "${TUNNEL_IF}" inet "${B4_ADDRESS}" "${B4_ADDRESS}" netmask 255.255.255.255
    logger -t dslite "IPv4 ${B4_ADDRESS} assigned to ${TUNNEL_IF}"
else
    # DS-Lite: standard B4/AFTR point-to-point (RFC 6333)
    ifconfig "${TUNNEL_IF}" inet "${B4_ADDRESS}" "${AFTR_V4_ADDRESS}" netmask 255.255.255.248
fi

# Set MTU
ifconfig "${TUNNEL_IF}" mtu "${MTU}"

# Bring interface up
ifconfig "${TUNNEL_IF}" up

logger -t dslite "Tunnel ${TUNNEL_IF} created via ${AFTR_ADDRESS}"

# Install the default IPv4 route through the tunnel. Our own previous route is
# withdrawn first; "route change" then adjusts an existing foreign route in
# place rather than blindly deleting whatever is in the table.
#
# When OPNsense has a gateway on the tunnel it maintains the default route too,
# and the only job left here is to make sure one exists at all: rebuilding the
# tunnel drops every route through it, and at boot OPNsense configures routing
# before the tunnel exists. So fill a vacuum, using the gateway's own address so
# that the route matches what OPNsense would install and survives its next pass.
#
# Never overwrite a default route that is already there. It is either the one
# OPNsense installed, or -- after a failover -- the second WAN's, and stealing
# that one back would undo the failover this gateway exists to enable.
OPNSENSE_GW=$(opnsense_gateway_address)
if [ -n "${OPNSENSE_GW}" ]; then
    if [ -n "$(route -n get default 2>/dev/null)" ]; then
        rm -f "${STATE_OWNED_ROUTE}"
        logger -t dslite "A default IPv4 route is already present; leaving it to OPNsense"
    elif route add default "${OPNSENSE_GW}" 2>/dev/null; then
        record_owned_route "gw" "${OPNSENSE_GW}" "${TUNNEL_IF}"
        logger -t dslite "Default IPv4 route set via ${OPNSENSE_GW} to match the OPNsense gateway on ${TUNNEL_IF}"
    else
        logger -t dslite "WARNING: Failed to add default route via ${OPNSENSE_GW}"
    fi

    # dpinger's monitor route went down with the old tunnel. Put it back, or its
    # probes follow the default route and report on whichever WAN owns it.
    OPNSENSE_MON=$(opnsense_gateway_monitor)
    if [ -n "${OPNSENSE_MON}" ]; then
        route delete -host -inet "${OPNSENSE_MON}" >/dev/null 2>&1
        if route add -host -inet "${OPNSENSE_MON}" "${OPNSENSE_GW}" >/dev/null 2>&1; then
            logger -t dslite "Monitor host route ${OPNSENSE_MON} via ${OPNSENSE_GW} restored"
        else
            logger -t dslite "WARNING: Failed to restore monitor host route ${OPNSENSE_MON}"
        fi
    fi

    # Start the monitor daemon if it is not already probing this gateway.
    #
    # At boot OPNsense configures gateway monitoring before the 'vpn' hook builds
    # the tunnel, so dpinger finds no usable interface for a gateway that lives on
    # it and skips that gateway entirely -- and nothing revisits the decision once
    # the tunnel appears. The result is a gateway with correct routes, a working
    # path and no dpinger at all, which the GUI reports as Offline with "~" for
    # loss and delay. Failover cannot trigger, exactly as if the gateway had been
    # disabled.
    #
    # Restoring the host route above is not enough on its own: that route is what
    # keeps the probes pinned to this tunnel, but something has to be probing.
    OPNSENSE_GW_NAME=$(config_get "${OPNSENSE_GW_XPATH}/name")
    if [ -n "${OPNSENSE_GW_NAME}" ] &&
       ! pgrep -qf "dpinger .*-i ${OPNSENSE_GW_NAME} " 2>/dev/null; then
        if [ -x /usr/local/sbin/pluginctl ]; then
            logger -t dslite "No dpinger instance for gateway ${OPNSENSE_GW_NAME}; reconfiguring monitors"
            /usr/local/sbin/pluginctl -c monitor >/dev/null 2>&1 &
        else
            logger -t dslite "WARNING: gateway ${OPNSENSE_GW_NAME} has no dpinger instance and pluginctl is missing; failover will NOT trigger"
        fi
    fi
else
    # No enabled gateway is configured for this interface, so OPNsense is not
    # managing the default route and dpinger is not probing anything here. Say so
    # loudly: the route installed below looks healthy in the routing table but
    # nothing monitors it, so WAN failover cannot trigger. That silence is what
    # made a disabled gateway look like a working tunnel until the link died.
    logger -t dslite "WARNING: no enabled OPNsense gateway on ${TUNNEL_IF}; installing an unmonitored default route -- dpinger cannot probe it and WAN failover will NOT trigger for this tunnel"
    remove_owned_default_route
    if [ -n "$(route -n get default 2>/dev/null)" ]; then
        # Same contract as the gateway branch above: whatever is there is either
        # the system's or the second WAN's after a failover, and taking it back
        # would undo that failover.
        rm -f "${STATE_OWNED_ROUTE}"
        logger -t dslite "A default IPv4 route is already present and is not ours; leaving it alone"
    elif [ "${TUNNEL_P2P}" = "1" ]; then
        # For IPIP tunnel, route via the tunnel interface directly
        if route add default -interface "${TUNNEL_IF}" 2>/dev/null ||
           route change default -interface "${TUNNEL_IF}" 2>/dev/null; then
            record_owned_route "iface" "-" "${TUNNEL_IF}"
            logger -t dslite "Default IPv4 route set via ${TUNNEL_IF}"
        else
            logger -t dslite "WARNING: Failed to add default route via ${TUNNEL_IF}"
        fi
    else
        if route add default "${AFTR_V4_ADDRESS}" 2>/dev/null ||
           route change default "${AFTR_V4_ADDRESS}" 2>/dev/null; then
            record_owned_route "gw" "${AFTR_V4_ADDRESS}" "${TUNNEL_IF}"
            logger -t dslite "Default IPv4 route set via ${AFTR_V4_ADDRESS}"
        else
            logger -t dslite "WARNING: Failed to add default route via ${AFTR_V4_ADDRESS}"
        fi
    fi
fi

# Configure NAT and firewall rules via OPNsense's registered anchors
if [ "${NAT_ENABLED}" = "1" ]; then
    NAT_FILE="/tmp/dslite_nat.conf"
    if [ "${TUNNEL_MODE}" = "mape" ]; then
        # MAP-E: the BR identifies this CE by the source port, so translation
        # must stay inside our assigned port set. map-e-portset makes pf pick
        # ports from exactly the set RFC 7597 derives from offset/len/PSID.
        cat > "${NAT_FILE}" << NATEOF
nat on ${TUNNEL_IF} from any to any -> ${B4_ADDRESS} map-e-portset ${MAPE_PSID_OFFSET}/${MAPE_PSID_LEN}/${MAPE_PSID}
NATEOF
    elif [ "${TUNNEL_MODE}" = "fixedip" ]; then
        # Fixed IP: NAT to the public fixed IP
        cat > "${NAT_FILE}" << NATEOF
nat on ${TUNNEL_IF} from any to any -> ${B4_ADDRESS}
NATEOF
    else
        # DS-Lite: NAT to tunnel interface address
        cat > "${NAT_FILE}" << NATEOF
nat on ${TUNNEL_IF} from any to any -> (${TUNNEL_IF})
NATEOF
    fi

    # Clamp TCP MSS to what the tunnel can actually carry.
    #
    # Without this, a LAN client on a 1500-byte link advertises MSS 1460, the
    # far end sends 1500-byte segments, and they do not fit the tunnel. Recovery
    # depends on PMTUD, which fails whenever the path filters ICMP -- and enough
    # large providers do that the failure is common rather than exotic. The
    # symptom is the confusing one: handshakes succeed and connections then
    # stall, so the host looks reachable while nothing transfers.
    #
    # Clamping on the tunnel fixes it for every client without touching them.
    #
    # "match", never "pass". match applies the scrub and lets evaluation carry on
    # to the real ruleset; pass makes a filtering decision, and with "quick" it
    # short-circuits everything after it. This anchor previously used
    # "pass in quick ... all", which passed every inbound packet arriving on the
    # tunnel and silently disabled WAN filtering altogether: the firewall's
    # default deny never ran, port forwards worked without any accompanying
    # filter rule, and every service bound to 0.0.0.0 -- sshd, the web GUI,
    # AdGuard on :53, ntpd -- was reachable from the internet on the public
    # address. Observed in the wild as established inbound SSH sessions from
    # unknown hosts, and as the GUI insisting the interface had no rules while
    # traffic flowed through it regardless.
    FW_FILE="/tmp/dslite_fw.conf"
    cat > "${FW_FILE}" << FWEOF
match out on ${TUNNEL_IF} all scrub (max-mss ${MSS_CLAMP})
match in on ${TUNNEL_IF} all scrub (max-mss ${MSS_CLAMP})
FWEOF

    # Load into OPNsense's registered anchors
    if pfctl -a "dslite/nat" -f "${NAT_FILE}" 2>/dev/null; then
        logger -t dslite "NAT rules loaded for ${TUNNEL_IF}"
    else
        logger -t dslite "WARNING: Failed to load NAT anchor, trying filter reload"
        configctl filter reload 2>/dev/null
        sleep 1
        pfctl -a "dslite/nat" -f "${NAT_FILE}" 2>/dev/null
    fi

    if pfctl -a "dslite/fw" -f "${FW_FILE}" 2>/dev/null; then
        logger -t dslite "Firewall rules loaded for ${TUNNEL_IF}"
    else
        logger -t dslite "WARNING: Failed to load firewall anchor"
    fi
fi

# Drop any cached health result so the next status poll reflects the new tunnel.
rm -f /var/run/dslite_health_cache

# Mark this run successful. The debounce above only ever suppresses work that
# followed a run which actually completed.
date +%s > "${STAMP_FILE}"

logger -t dslite "Tunnel configuration complete (mode: ${TUNNEL_MODE})"
exit 0
