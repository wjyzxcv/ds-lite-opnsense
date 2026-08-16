#!/bin/sh

# DS-Lite shared library functions
# Reads configuration from OPNsense XML config

# Default tunnel unit. get_config() replaces this with the configured one.
# It is deliberately a fixed unit rather than one allocated by
# "ifconfig gif create": OPNsense registers this interface and firewall/NAT
# rules reference it by name, so a unit that changes across reboots would
# silently repoint those rules at another device. Collisions are detected and
# reported instead (see tunnel_is_ours), and the admin picks a free unit.
TUNNEL_IF="gif0"
CONFIG_XML="/conf/config.xml"

# FreeBSD ping(8) expresses -W in MILLISECONDS (unlike Linux, where it is
# seconds). Every probe in this plugin must use this value, not a bare "2".
PING_WAIT_MS=2000

# Runtime state. Everything under /var/run is cleared on reboot, which is the
# correct lifetime for "what did we install into the running kernel".
STATE_LOCAL_V6="/var/run/dslite_local_tunnel_v6"        # "<device> <address>"
STATE_OWNED_IF="/var/run/dslite_owned_tunnel"           # "<ifname> <local_v6> <remote_v6>"
STATE_OWNED_ROUTE="/var/run/dslite_owned_route"         # "<iface|gw> <gateway|-> <ifname>"
STATE_PREFIX_UPDATE="/var/run/dslite_prefix_update_status"  # "<epoch> <rc> <code>"

# Deliberately NOT under /var/run: this records provider-side state, which
# outlives a reboot. Losing it only costs one redundant registration, so /var/db
# is the right trade even where RAM disks make it volatile.
STATE_LAST_CE="/var/db/dslite_last_ce"                  # "<ce address>"

# Maximum age of a prefix-update result before health reports it as stale.
# Must be comfortably larger than the cron interval in dslite_cron().
PREFIX_UPDATE_MAX_AGE=5400

# Known ISP AFTR addresses (fallback only - prefer auto-detection)
AFTR_TRANSIX="2001:c28:5:301::11"
AFTR_XPASS="2001:f60:0:200::1"
AFTR_V6CONNECT="2404:8e00::feed:100"

# freebit "enabler" fixed-IP service (fcs.enabler.ne.jp). The BR lives in the
# same 2404:9200:225:100::/64 as the v6plus MAP-E BR below, so match on the /64
# rather than a single address: the per-subscriber BR differs by the low byte
# (::64 for v6plus, ::65 for the fixed-IP IPIP service observed in the field).
BR_ENABLER_NET="2404:9200:225:100:"

# Prefix-to-AFTR mapping table for Japanese DS-Lite ISPs
# Format: prefix/len|aftr_address (pipe-delimited to avoid IPv6 colon conflict)
# Sources: UDM-Pro config, community documentation, ISP specifications
AFTR_MAP="
2001:c28::/32|2001:c28:5:301::11
2405:6580::/28|2001:c28:5:301::11
2405:6500::/24|2001:c28:5:301::11
2409:10::/30|2001:c28:5:301::11
2409:250::/30|2001:c28:5:301::11
2001:f60::/32|2001:f60:0:200::1
2404:8e00::/32|2404:8e00::feed:100
2404:8e01::/32|2404:8e00::feed:101
"

# ---------------------------------------------------------------------------
# MAP-E (RFC 7597) -- EXPERIMENTAL
#
# Service-wide constants only. The per-subscriber Basic Mapping Rule (the rule
# IPv6/IPv4 prefixes and the EA-bits length) differs per assigned prefix and is
# NOT published by the VNEs -- operators hold it internally, and the values in
# community write-ups are one subscriber's rule, not a table. Shipping a guessed
# mapping would put the CE's source ports outside its assigned port set, which
# the BR silently drops and which presents as a routing fault. So only values
# that genuinely apply to the whole service live here.
#
# Format: profile|br_ipv6|psid_offset
MAPE_PROFILES="
v6plus|2404:9200:225:100::64|4
"

# Look up a MAP-E profile. Sets MAPE_P_BR and MAPE_P_OFFSET.
# Uses a temp file rather than a pipe: a piped while-loop runs in a subshell,
# so assignments to the caller's variables would be lost (same reason
# detect_aftr_from_prefix does this).
mape_profile_lookup() {
    local want="$1" name br offset tmpfile
    MAPE_P_BR=""
    MAPE_P_OFFSET=""
    [ -n "${want}" ] || return 1

    tmpfile="/tmp/dslite_mape_profiles.tmp"
    printf '%s\n' "${MAPE_PROFILES}" > "${tmpfile}"
    while IFS='|' read -r name br offset; do
        [ -n "${name}" ] || continue
        if [ "${name}" = "${want}" ]; then
            MAPE_P_BR="${br}"
            MAPE_P_OFFSET="${offset}"
            break
        fi
    done < "${tmpfile}"
    rm -f "${tmpfile}"

    [ -n "${MAPE_P_BR}" ]
}

# Does this pf support MAP-E port sets? Parse-only, nothing is loaded.
# Without it a nat rule would translate to ports outside our assigned set and
# the BR would drop the traffic, so this must fail loudly rather than degrade.
mape_pf_supported() {
    printf 'nat on lo0 from any to any -> 192.0.2.1 map-e-portset 6/8/0\n' \
        | pfctl -n -f - >/dev/null 2>&1
}

# Derive the MAP-E parameters for this CE from its delegated prefix and the BMR.
# Usage: mape_derive <pd_prefix> <rule_ipv6> <rule_ipv4> <ea_length> <psid_offset>
# Prints: "<ipv4> <psid> <psid_len> <ce_ipv6> <port_ranges> <ports_total>"
# Returns non-zero when the prefix does not fall inside the rule, which is the
# safety property that lets an incomplete profile set fail cleanly instead of
# producing a plausible but wrong port set.
mape_derive() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$1" "$2" "$3" "$4" "$5" <<'PYEOF' 2>/dev/null
import sys, ipaddress

pd_s, rule6_s, rule4_s, ea_s, off_s = sys.argv[1:6]

pd = ipaddress.ip_network(pd_s, strict=False)
rule6 = ipaddress.ip_network(rule6_s, strict=False)
rule4 = ipaddress.ip_network(rule4_s, strict=False)
o = int(ea_s)            # EA-bits length
a = int(off_s)           # PSID offset

n = rule6.prefixlen      # rule IPv6 prefix length
r = rule4.prefixlen      # rule IPv4 prefix length

# The delegated prefix must sit inside the rule prefix and be long enough to
# carry the EA bits, otherwise this rule simply does not describe this CE.
if not (pd.network_address in rule6 and pd.prefixlen >= n + o):
    sys.exit(1)
if not (0 <= o <= 48 and 0 <= a <= 16):
    sys.exit(1)

# EA bits sit immediately after the rule prefix (RFC 7597 s5.2).
ea = (int(pd.network_address) >> (128 - n - o)) & ((1 << o) - 1)

p = min(32 - r, o)       # IPv4 suffix bits carried in the EA field
k = o - p                # PSID bits
if k < 0 or a + k > 16:
    sys.exit(1)

ipv4 = ipaddress.IPv4Address(int(rule4.network_address) | (ea >> k))
psid = ea & ((1 << k) - 1)

# MAP CE address (RFC 7597 s6): interface identifier is
# 16 zero bits | the IPv4 address | the PSID.
iid = (int(ipv4) << 16) | psid
ce = ipaddress.IPv6Address((int(pd.network_address) >> 64 << 64) | iid)

# Port set: ports are A(a bits) | PSID(k bits) | j(m bits). j=0 is skipped so
# the well-known ports stay out of every CE's set.
m = 16 - a - k
ranges = (1 << a) - 1 if a > 0 else 1
total = ranges * (1 << m)

print("%s %d %d %s %d %d" % (ipv4, psid, k, ce, ranges, total))
PYEOF
}

# Emit the contiguous port ranges of a MAP-E port set, one "start end" per line.
# Used for reporting; pf derives the same set itself from map-e-portset.
mape_port_ranges() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$1" "$2" "$3" <<'PYEOF' 2>/dev/null
import sys
a, k, psid = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
m = 16 - a - k
for j in range(1 if a > 0 else 0, 1 << a):
    start = (j << (16 - a)) | (psid << m)
    print("%d %d" % (start, start + (1 << m) - 1))
PYEOF
}

# Read a value from the OPNsense config XML
# Usage: config_get "xpath"
config_get() {
    local xpath="$1"
    /usr/local/bin/xmllint --xpath "string(${xpath})" "${CONFIG_XML}" 2>/dev/null
}

# Convert an IPv6 address to a fully expanded 32-char hex string
# e.g. 2405:6586:9c00:: -> 240565869c00000000000000000000000
ipv6_to_hex() {
    local addr="$1"
    # Remove prefix length if present
    addr=$(echo "${addr}" | sed 's|/.*||')
    # Use printf through a small python one-liner for reliable expansion
    # Fallback to manual expansion if python not available
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import sys, ipaddress
a = ipaddress.ip_address(sys.argv[1])
print(format(int(a), '032x'))
" "${addr}" 2>/dev/null
        return
    fi
    # Manual expansion: replace :: with enough 0s, then expand each group
    echo "${addr}" | awk -F: '{
        # Count non-empty groups
        n = 0; for(i=1;i<=NF;i++) if($i!="") n++
        out = ""
        for(i=1;i<=NF;i++) {
            if($i == "" && i>1 && i<NF) {
                for(j=0;j<8-n;j++) out = out "0000"
            } else if($i != "") {
                out = out sprintf("%04s", $i)
            }
        }
        gsub(/ /, "0", out)
        print out
    }'
}

# Check if an IPv6 address matches a prefix
# Usage: ipv6_prefix_match "address" "prefix/len"
ipv6_prefix_match() {
    local addr_hex prefix_hex
    local addr="$1"
    local prefix="$2"
    local prefixlen=$(echo "${prefix}" | sed 's|.*/||')
    local prefixaddr=$(echo "${prefix}" | sed 's|/.*||')

    addr_hex=$(ipv6_to_hex "${addr}")
    prefix_hex=$(ipv6_to_hex "${prefixaddr}")

    if [ -z "${addr_hex}" ] || [ -z "${prefix_hex}" ]; then
        return 1
    fi

    # Compare the first prefixlen/4 hex chars (rough, works for /16,/24,/28,/30,/32)
    local hexchars=$(( prefixlen / 4 ))
    local addr_part=$(echo "${addr_hex}" | cut -c1-${hexchars})
    local prefix_part=$(echo "${prefix_hex}" | cut -c1-${hexchars})

    [ "${addr_part}" = "${prefix_part}" ]
}

# Auto-detect AFTR address from delegated prefix using prefix-to-AFTR mapping
# This is the primary discovery mechanism for Japanese DS-Lite ISPs
detect_aftr_from_prefix() {
    local pd_prefix="$1"
    if [ -z "${pd_prefix}" ]; then
        return 1
    fi

    local prefix_addr
    prefix_addr=$(echo "${pd_prefix}" | sed 's|/.*||')

    # Write map to temp file and use redirect instead of pipe
    # (pipe creates subshell which loses echo output)
    local _result=""
    local _tmpfile="/tmp/dslite_aftr_map.tmp"
    echo "${AFTR_MAP}" > "${_tmpfile}"
    while IFS='|' read -r map_prefix map_aftr; do
        # Skip empty lines
        [ -z "${map_prefix}" ] && continue
        # Remove leading/trailing whitespace
        map_prefix=$(echo "${map_prefix}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        map_aftr=$(echo "${map_aftr}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "${map_prefix}" ] && continue

        if ipv6_prefix_match "${prefix_addr}" "${map_prefix}"; then
            _result="${map_aftr}"
            break
        fi
    done < "${_tmpfile}"
    rm -f "${_tmpfile}"

    if [ -n "${_result}" ]; then
        echo "${_result}"
        return 0
    fi
    return 1
}

# Try DNS resolution for AFTR hostname
resolve_aftr_dns() {
    local hostname="$1"
    if [ -z "${hostname}" ]; then
        return 1
    fi

    # Use drill (available on FreeBSD/OPNsense)
    local result
    result=$(drill AAAA "${hostname}" 2>/dev/null | grep -A1 "ANSWER SECTION" | \
        grep "AAAA" | awk '{print $NF}' | head -1)

    if [ -n "${result}" ]; then
        echo "${result}"
        return 0
    fi
    return 1
}

# Get DS-Lite configuration values
get_config() {
    DSLITE_ENABLED=$(config_get "//OPNsense/dslite/enabled")
    ISP_PROFILE=$(config_get "//OPNsense/dslite/isp_profile")
    WAN_INTERFACE=$(config_get "//OPNsense/dslite/wan_interface")
    AFTR_ADDRESS=$(config_get "//OPNsense/dslite/aftr_address")
    AFTR_HOSTNAME=$(config_get "//OPNsense/dslite/aftr_hostname")
    B4_ADDRESS=$(config_get "//OPNsense/dslite/b4_address")
    AFTR_V4_ADDRESS=$(config_get "//OPNsense/dslite/aftr_v4_address")
    MTU=$(config_get "//OPNsense/dslite/mtu")
    MSS_CLAMP=$(config_get "//OPNsense/dslite/mss_clamp")
    NAT_ENABLED=$(config_get "//OPNsense/dslite/nat_enabled")
    FIXEDIP_ALLOW_INSECURE=$(config_get "//OPNsense/dslite/fixedip_allow_insecure")

    # Read here as well as in configure.sh: fixedip_provider() resolves the
    # provider from the BR address when the profile is left on auto, and it is
    # reachable from status/diagnostics paths that never source configure.sh.
    FIXEDIP_AFTR=$(config_get "//OPNsense/dslite/fixedip_aftr")

    # Tunnel unit. Anything that is not a plain gif unit name falls back to the
    # default rather than reaching ifconfig, so a malformed config value cannot
    # turn into an argument we did not intend.
    TUNNEL_IF=$(config_get "//OPNsense/dslite/tunnel_interface")
    case "${TUNNEL_IF}" in
        gif[0-9]|gif[0-9][0-9]) ;;
        *) TUNNEL_IF="gif0" ;;
    esac

    # Defaults
    B4_ADDRESS="${B4_ADDRESS:-192.0.0.2}"
    AFTR_V4_ADDRESS="${AFTR_V4_ADDRESS:-192.0.0.1}"
    MTU="${MTU:-1460}"
    MSS_CLAMP="${MSS_CLAMP:-1420}"
    NAT_ENABLED="${NAT_ENABLED:-1}"
    FIXEDIP_ALLOW_INSECURE="${FIXEDIP_ALLOW_INSECURE:-0}"

    # AFTR discovery priority:
    # 1. Explicit address in config (user override)
    # 2. Auto-detect from PD prefix (prefix-to-AFTR mapping)
    # 3. DNS resolution of AFTR hostname
    # 4. ISP profile hardcoded fallback
    if [ -z "${AFTR_ADDRESS}" ]; then
        # Try auto-detection from PD prefix
        local pd_prefix
        pd_prefix=$(get_pd_prefix)
        if [ -n "${pd_prefix}" ]; then
            local detected
            detected=$(detect_aftr_from_prefix "${pd_prefix}")
            if [ -n "${detected}" ]; then
                AFTR_ADDRESS="${detected}"
                logger -t dslite "Auto-detected AFTR ${AFTR_ADDRESS} from prefix ${pd_prefix}"
            fi
        fi
    fi

    if [ -z "${AFTR_ADDRESS}" ] && [ -n "${AFTR_HOSTNAME}" ]; then
        # Try DNS resolution
        local resolved
        resolved=$(resolve_aftr_dns "${AFTR_HOSTNAME}")
        if [ -n "${resolved}" ]; then
            AFTR_ADDRESS="${resolved}"
            logger -t dslite "Resolved AFTR ${AFTR_ADDRESS} from hostname ${AFTR_HOSTNAME}"
        fi
    fi

    if [ -z "${AFTR_ADDRESS}" ]; then
        # Fallback to ISP profile hardcoded address
        case "${ISP_PROFILE}" in
            transix)  AFTR_ADDRESS="${AFTR_TRANSIX}" ;;
            xpass)    AFTR_ADDRESS="${AFTR_XPASS}" ;;
            v6connect) AFTR_ADDRESS="${AFTR_V6CONNECT}" ;;
        esac
        if [ -n "${AFTR_ADDRESS}" ]; then
            logger -t dslite "Using fallback AFTR ${AFTR_ADDRESS} from ISP profile ${ISP_PROFILE}"
        fi
    fi
}

# Get the WAN interface's global IPv6 address
get_wan_ipv6() {
    local wan_if
    # Resolve OPNsense interface name to real device name
    wan_if=$(config_get "//interfaces/${WAN_INTERFACE}/if")
    if [ -z "${wan_if}" ]; then
        wan_if="${WAN_INTERFACE}"
    fi

    # Get the first global scope IPv6 address
    ifconfig "${wan_if}" 2>/dev/null | \
        grep "inet6" | grep -v "fe80" | grep -v "::1" | \
        head -1 | awk '{print $2}' | sed 's/%.*$//'
}

# ---------------------------------------------------------------------------
# Fixed IP: how the provider's "Interface ID" maps into the CE address.
#
# Two incompatible readings exist among the VNEs, and choosing the wrong one
# produces an address the AFTR rejects with ICMPv6 destination unreachable
# code 5 (source address failed ingress/egress policy). The tunnel still comes
# up, so this presents as a silent blackhole rather than a configuration error.
#
#   host    The ID is the low 64 bits of the CE, OR'd into the /64 the WAN sits
#           in. transix documents it this way: the registration mail gives
#           "::feed or 0000:0000:0000:feed" -- four groups, exactly 64 bits.
#
#   subnet  The ID is a subnet selector aligned to the delegated prefix
#           boundary (shifted left by 64 - prefixlen). Original behaviour, kept
#           as the default so existing deployments are untouched.
#
# Keyed off the ISP profile rather than sniffed from the ID: ::feed is a legal
# value under both readings, so the input itself cannot disambiguate.
# ---------------------------------------------------------------------------
# Which provider's conventions apply. transix differs from the v6 Connect
# family in more than one place -- the Interface ID reading and the update
# server's auth transport -- so resolve it once and derive both from it.
fixedip_provider() {
    local pd detected

    case "${ISP_PROFILE}" in
        transix) echo "transix" ; return ;;
        enabler) echo "enabler" ; return ;;
        auto)    ;;
        *)       echo "generic" ; return ;;
    esac

    # "auto" is the default the operator gets by never touching the dropdown,
    # so it must not quietly resolve to the wrong provider.
    #
    # The BR address is checked before the prefix table because it is the one
    # value the operator copies verbatim from the provisioning mail. enabler
    # hands out prefixes from 240b::/20, which is shared with several other
    # services, so the delegated prefix cannot identify it.
    case "${FIXEDIP_AFTR}" in
        ${BR_ENABLER_NET}*) echo "enabler" ; return ;;
    esac

    # Reuse the prefix table that already drives AFTR auto-detection.
    pd=$(get_pd_prefix)
    if [ -n "${pd}" ]; then
        detected=$(detect_aftr_from_prefix "${pd}")
        if [ "${detected}" = "${AFTR_TRANSIX}" ]; then
            echo "transix"
            return
        fi
    fi

    echo "generic"
}

fixedip_iid_placement() {
    case "$(fixedip_provider)" in
        transix|enabler) echo "host" ;;
        *)               echo "subnet" ;;
    esac
}

# How the update server expects credentials.
#
#   query  transix and enabler take them as URL parameters and identify the CE
#          from the request's source address. transix answers 400/"NG" to
#          anything else -- notably it never issues a 401, so challenge-response
#          auth silently never sends the credentials at all. enabler answers a
#          bare "OK".
#
#   basic  RFC 7617 via netrc, which is what the v6 Connect family uses.
fixedip_auth_style() {
    case "$(fixedip_provider)" in
        transix|enabler) echo "query" ;;
        *)               echo "basic" ;;
    esac
}

# Parameter names for the query auth style, as "<user_param> <pass_param>".
# The two providers that use query auth disagree on the spelling, and sending
# the wrong pair authenticates as nobody: enabler still answers "OK" because it
# treats the request as an anonymous route reset, so this fails silently.
fixedip_auth_params() {
    case "$(fixedip_provider)" in
        enabler) echo "user pass" ;;
        *)       echo "username password" ;;
    esac
}

# Derive the tunnel-local (CE) IPv6 address from the provider's Interface ID.
# Echoes nothing when it cannot be computed; the caller decides the fallback.
fixedip_local_v6() {
    local iid="$1"
    local placement base

    [ -n "${iid}" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1

    placement=$(fixedip_iid_placement)

    if [ "${placement}" = "host" ]; then
        # Anchor on the WAN's own /64: that is the prefix the AFTR expects
        # traffic to be sourced from and what the provider-side registration
        # binds to. The delegated prefix is only a fallback for the first-boot
        # ordering case where the WAN has no global address yet.
        base=$(get_wan_ipv6)
        [ -n "${base}" ] || base=$(get_pd_prefix)
        [ -n "${base}" ] || return 1
    else
        base=$(get_pd_prefix)
        [ -n "${base}" ] || return 1
    fi

    python3 -c '
import sys, ipaddress

base, iid_s, placement = sys.argv[1], sys.argv[2], sys.argv[3]

def parse_iid(s):
    try:
        return int(ipaddress.ip_address(s))
    except ValueError:
        # Providers also print the ID as bare low-64 groups rather than a
        # compressed address -- transix gives "::feed or 0000:0000:0000:feed".
        # Anchor the bare form at the low end so both spellings agree.
        return int(ipaddress.ip_address("::" + s.lstrip(":")))

iid = parse_iid(iid_s)

if placement == "host":
    # Accept either an address or a prefix as the anchor.
    if "/" in base:
        anchor = int(ipaddress.ip_network(base, strict=False).network_address)
    else:
        anchor = int(ipaddress.ip_address(base))
    mask64 = (1 << 64) - 1
    combined = (anchor >> 64 << 64) | (iid & mask64)
else:
    prefix = ipaddress.ip_network(base, strict=False)
    shift = 64 - prefix.prefixlen
    if shift > 0:
        iid = iid << shift
    combined = int(prefix.network_address) | iid

print(str(ipaddress.ip_address(combined)))
' "${base}" "${iid}" "${placement}" 2>/dev/null
}

# Get DHCPv6-PD prefix from OPNsense temp files or interface addresses
get_pd_prefix() {
    local wan_if
    wan_if=$(config_get "//interfaces/${WAN_INTERFACE}/if")
    wan_if="${wan_if:-${WAN_INTERFACE}}"

    # Method 1: OPNsense stores DHCPv6-PD prefix in /tmp/<if>_prefixv6
    local prefix_file="/tmp/${wan_if}_prefixv6"
    if [ -f "${prefix_file}" ]; then
        cat "${prefix_file}" 2>/dev/null | head -1 | grep -o '[0-9a-f:]*::/[0-9]*'
        return
    fi

    # Method 2: query ifctl for PD info
    local ifctl_result
    ifctl_result=$(/usr/local/sbin/ifctl -i "${wan_if}" -6pd -l 2>/dev/null)
    if [ -n "${ifctl_result}" ] && [ -f "${ifctl_result}" ]; then
        cat "${ifctl_result}" 2>/dev/null | head -1 | grep -o '[0-9a-f:]*::/[0-9]*'
        return
    fi

    # Method 3: Derive prefix from global IPv6 on any interface
    # NTT IPoE delegates PD to LAN, so check all interfaces for a global address
    # and extract the /56 prefix from it
    local global_addr
    global_addr=$(ifconfig -a 2>/dev/null | grep "inet6 2" | grep -v "fe80" | grep -v "::1" | \
        head -1 | awk '{print $2}' | sed 's/%.*$//')
    if [ -n "${global_addr}" ] && command -v python3 >/dev/null 2>&1; then
        python3 -c "
import sys, ipaddress
addr = ipaddress.ip_address(sys.argv[1])
# Extract /56 network prefix
net = ipaddress.ip_network(str(addr) + '/56', strict=False)
print(str(net))
" "${global_addr}" 2>/dev/null
        return
    fi

    # Method 3 fallback without python: rough extraction
    if [ -n "${global_addr}" ]; then
        # Take the first 14 hex chars (56 bits = 14 nibbles) of expanded address
        local prefix_part
        prefix_part=$(echo "${global_addr}" | sed 's/::.*//; s/:[0-9a-f]*:[0-9a-f]*:[0-9a-f]*$//')
        if [ -n "${prefix_part}" ]; then
            echo "${prefix_part}::/56"
            return
        fi
    fi
}

# Check if tunnel interface exists and is configured
tunnel_exists() {
    ifconfig "${TUNNEL_IF}" >/dev/null 2>&1
}

# Escape an arbitrary string for use inside a JSON string literal.
# Control characters are dropped (tabs become spaces, newlines become \n) so
# that provider-controlled data can never break the generated document.
json_escape() {
    printf '%s' "$1" \
        | tr -d '\000-\010\013-\037\177' \
        | tr '\011' ' ' \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | awk '{ if (NR > 1) printf "\\n"; printf "%s", $0 }'
}

# Resolve the configured tunnel mode ("dslite" or "fixedip").
get_mode() {
    local mode
    mode=$(config_get "//OPNsense/dslite/mode")
    printf '%s' "${mode:-dslite}"
}

# The AFTR/BR endpoint the current configuration would build a tunnel to.
# In Fixed IP mode this comes from the member-specific field, otherwise from
# the AFTR discovery chain already run by get_config().
get_expected_aftr() {
    local mode br
    mode=$(get_mode)
    case "${mode}" in
        fixedip)
            config_get "//OPNsense/dslite/fixedip_aftr"
            ;;
        mape)
            br=$(config_get "//OPNsense/dslite/mape_br")
            if [ -z "${br}" ]; then
                # Fall back to the profile's BR when the field is left blank.
                if mape_profile_lookup "$(config_get "//OPNsense/dslite/mape_profile")"; then
                    br="${MAPE_P_BR}"
                fi
            fi
            printf '%s' "${br}"
            ;;
        *)
            printf '%s' "${AFTR_ADDRESS}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Authenticated prefix update transport
# ---------------------------------------------------------------------------

# Detect xpass DDNS-style provisioning.
# Xpass uses a hybrid format: query params with DDNS credentials + CE IPv6,
# plus HTTP Basic auth for request authentication.
xpass_provisioning() {
    [ "${ISP_PROFILE}" = "xpass" ] && return 0
    case "${FIXEDIP_UPDATE_URL:-}" in
        *ddns.vbbnet.jp*) return 0 ;;
    esac
    return 1
}

# Perform the authenticated prefix-update request.
# Usage: dslite_authed_get <url> <user> <pass> <allow_insecure> [source_addr]
# Writes the response body to stdout. Returns curl's exit status, or 2 when the
# request was refused because credentials would have been sent insecurely.
#
# Credentials go through a mode-0600 netrc so they never appear in argv, and
# certificate verification is never disabled for an https:// endpoint.
dslite_authed_get() {
    local url="$1" user="$2" pass="$3" allow="$4" source_addr="$5"
    local netrc out rc sep ddns_id ddns_pass fqdn

    [ -n "${url}" ] || return 2

    case "${url}" in
        https://*)
            ;;
        *)
            if [ "${allow}" = "1" ]; then
                logger -t dslite "WARNING: sending prefix-update credentials over an insecure URL (${url})"
            else
                logger -t dslite "ERROR: refusing to send credentials to non-HTTPS update URL (${url}). Enable 'Allow insecure update URL' only if your ISP offers no HTTPS endpoint."
                return 2
            fi
            ;;
    esac

    # --max-time bounds a server that accepts the connection and then stalls;
    # --connect-timeout alone does not.
    #
    # source_addr binds the request to the CE address. transix derives the
    # registration from the source address, so an unbound request would either
    # be rejected or register the wrong address; harmless for providers that
    # ignore it.

    # Xpass DDNS-style provisioning: hybrid query params + basic auth
    if xpass_provisioning && [ -n "${source_addr}" ]; then
        ddns_id=$(config_get "//OPNsense/dslite/fixedip_ddns_id")
        ddns_pass=$(config_get "//OPNsense/dslite/fixedip_ddns_pass")
        fqdn=$(config_get "//OPNsense/dslite/fixedip_fqdn")

        if [ -n "${ddns_id}" ] && [ -n "${ddns_pass}" ] && [ -n "${fqdn}" ]; then
            netrc=$(umask 077; mktemp /tmp/dslite-netrc.XXXXXX) || return 2
            chmod 600 "${netrc}"
            printf 'default\nlogin %s\npassword %s\n' "${user}" "${pass}" > "${netrc}"

            local curl_insecure=""
            [ "${allow}" = "1" ] && curl_insecure="-k"

            out=$(curl -6 ${curl_insecure} -s --connect-timeout 5 --max-time 20 \
                  ${source_addr:+--interface "${source_addr}"} \
                  --netrc-file "${netrc}" \
                  "${url}?d=$(urlencode "${fqdn}")&p=$(urlencode "${ddns_pass}")&a=${source_addr}&u=$(urlencode "${ddns_id}")" 2>&1)
            rc=$?
            rm -f "${netrc}"

            printf '%s' "${out}"
            return ${rc}
        fi
    fi

    if [ "$(fixedip_auth_style)" = "query" ]; then
        # Providers publish the endpoint with its own query string attached
        # (enabler's provisioning mail gives ".../update?user=...&pass=..."),
        # so a hardcoded "?" would produce a second one and the server would
        # read the whole tail as one malformed parameter value.
        case "${url}" in
            *\?*) sep="&" ;;
            *)    sep="?" ;;
        esac
        set -- $(fixedip_auth_params)
        out=$(curl -6 -s --connect-timeout 5 --max-time 20 \
              ${source_addr:+--interface "${source_addr}"} \
              "${url}${sep}${1}=$(urlencode "${user}")&${2}=$(urlencode "${pass}")" 2>&1)
        rc=$?
    else
        netrc=$(umask 077; mktemp /tmp/dslite-netrc.XXXXXX) || return 2
        chmod 600 "${netrc}"
        printf 'default\nlogin %s\npassword %s\n' "${user}" "${pass}" > "${netrc}"

        out=$(curl -6 -s --connect-timeout 5 --max-time 20 \
              ${source_addr:+--interface "${source_addr}"} \
              --netrc-file "${netrc}" "${url}" 2>&1)
        rc=$?
        rm -f "${netrc}"
    fi

    printf '%s' "${out}"
    return ${rc}
}

# Percent-encode a credential for use in a query string. Passwords are operator
# supplied and may legitimately contain & or =, which would otherwise be parsed
# as parameter separators and silently corrupt the request.
urlencode() {
    local s="$1" out="" c

    # Kept to shell builtins on purpose: FreeBSD awk has no strtonum(), and
    # this runs on a base system with no scripting dependencies guaranteed.
    while [ -n "${s}" ]; do
        c=${s%"${s#?}"}
        s=${s#?}
        case "${c}" in
            [A-Za-z0-9._~-]) out="${out}${c}" ;;
            *)               out="${out}$(printf '%%%02X' "'${c}")" ;;
        esac
    done

    printf '%s' "${out}"
}

# Register the CE address with the provider, but only when it actually changed.
#
# The provider binds the fixed IPv4 to whatever CE it last saw, so re-sending an
# unchanged address achieves nothing and only spends quota against the update
# server. The periodic job runs every 30 minutes; without this guard that is ~48
# registrations a day for a value that changes on the order of never.
#
# Usage: fixedip_register_if_changed <url> <user> <pass> <allow_insecure> <ce>
fixedip_register_if_changed() {
    local url="$1" user="$2" pass="$3" allow="$4" ce="$5"
    local last out rc code

    [ -n "${url}" ] && [ -n "${user}" ] || return 0

    last=$(cat "${STATE_LAST_CE}" 2>/dev/null)
    if [ -n "${ce}" ] && [ "${ce}" = "${last}" ]; then
        # Still stamp the result. Health ages the stored outcome out and reports
        # "stale" past PREFIX_UPDATE_MAX_AGE, so a deliberately skipped call must
        # not be indistinguishable from an updater that has stopped running.
        write_prefix_update_state 0 "nochg"
        return 0
    fi

    logger -t dslite "CE changed (${last:-none} -> ${ce}), registering with ${url}"
    out=$(dslite_authed_get "${url}" "${user}" "${pass}" "${allow}" "${ce}")
    rc=$?
    code=$(printf '%s' "${out}" | awk '{print $1; exit}')
    write_prefix_update_state "${rc}" "${code}"
    logger -t dslite "Prefix update response: ${out}"

    # Only remember a CE the provider actually accepted, so a failure retries on
    # the next tick instead of being latched as done.
    if [ "${rc}" = "0" ]; then
        case "${code}" in
            good|nochg|OK|ok) printf '%s\n' "${ce}" > "${STATE_LAST_CE}" ;;
        esac
    fi

    return ${rc}
}

# Record a prefix-update outcome for the status/diagnostics pages.
# Usage: write_prefix_update_state <rc> <code>
write_prefix_update_state() {
    printf '%s %s %s\n' "$(date +%s)" "$1" "${2:-curl-error}" > "${STATE_PREFIX_UPDATE}"
}

# ---------------------------------------------------------------------------
# WAN /128 tunnel-local alias lifecycle
# (concept ported from unchained-llc/os-ocnfixedip, BSD-2-Clause; reworked to
#  be transactional and to remember which device owns the alias)
# ---------------------------------------------------------------------------

# Resolve the configured WAN interface to its real device name (e.g. igb0).
get_wan_if_device() {
    local wan_if
    wan_if=$(config_get "//interfaces/${WAN_INTERFACE}/if")
    [ -n "${wan_if}" ] || wan_if="${WAN_INTERFACE}"
    printf '%s' "${wan_if}"
}

# True when <device> currently carries <address> as an inet6 address.
iface_has_v6() {
    ifconfig "$1" 2>/dev/null | awk '/inet6 / {gsub(/%.*/,"",$2); print $2}' | grep -qx "$2"
}

# Load the managed alias state into ALIAS_DEV / ALIAS_ADDR.
# Returns non-zero when no usable state exists. Understands the legacy
# address-only format written by earlier versions.
read_alias_state() {
    ALIAS_DEV=""
    ALIAS_ADDR=""
    [ -f "${STATE_LOCAL_V6}" ] || return 1
    read -r ALIAS_DEV ALIAS_ADDR < "${STATE_LOCAL_V6}" 2>/dev/null || return 1
    if [ -z "${ALIAS_ADDR}" ]; then
        ALIAS_ADDR="${ALIAS_DEV}"
        ALIAS_DEV=""
    fi
    [ -n "${ALIAS_ADDR}" ]
}

# Remove one managed alias. Returns 0 only when the address is confirmed gone
# (including the cases where the device or the address never existed).
drop_alias() {
    local dev="$1" addr="$2"
    [ -n "${dev}" ] && [ -n "${addr}" ] || return 0
    ifconfig "${dev}" >/dev/null 2>&1 || return 0
    iface_has_v6 "${dev}" "${addr}" || return 0

    ifconfig "${dev}" inet6 "${addr}" -alias 2>/dev/null
    if iface_has_v6 "${dev}" "${addr}"; then
        logger -t dslite "WARNING: failed to remove WAN /128 alias ${addr} on ${dev}"
        return 1
    fi
    logger -t dslite "Removed WAN /128 alias ${addr} on ${dev}"
    return 0
}

# Ensure a /128 tunnel-local alias exists on the WAN device, first removing a
# previously-managed alias when the device or the address changed.
#
# Returns 0 only when the address is verified present on the expected device;
# callers must abort tunnel replacement on a non-zero return. State is written
# after verification, never before, so it always describes reality.
manage_wan_alias() {
    local new_v6="$1" wan_if="$2" prev_dev

    [ -n "${new_v6}" ] && [ -n "${wan_if}" ] || return 1
    if ! ifconfig "${wan_if}" >/dev/null 2>&1; then
        logger -t dslite "ERROR: WAN device ${wan_if} not present, cannot manage /128 alias"
        return 1
    fi

    if read_alias_state; then
        prev_dev="${ALIAS_DEV:-${wan_if}}"
        if [ "${prev_dev}" != "${wan_if}" ] || [ "${ALIAS_ADDR}" != "${new_v6}" ]; then
            # Keep the state file on failure so a later run can retry.
            drop_alias "${prev_dev}" "${ALIAS_ADDR}" || return 1
        fi
    fi

    if ! iface_has_v6 "${wan_if}" "${new_v6}"; then
        ifconfig "${wan_if}" inet6 "${new_v6}"/128 alias 2>/dev/null
        if ! iface_has_v6 "${wan_if}" "${new_v6}"; then
            logger -t dslite "ERROR: failed to add WAN /128 alias ${new_v6} on ${wan_if}"
            return 1
        fi
        logger -t dslite "Added WAN /128 alias ${new_v6} on ${wan_if}"
    fi

    printf '%s %s\n' "${wan_if}" "${new_v6}" > "${STATE_LOCAL_V6}"
    return 0
}

# Remove the managed /128 alias (teardown, or when leaving Fixed IP mode).
# The recorded device wins over the caller's guess so that a WAN change still
# cleans up the old device. State is cleared only once removal is confirmed.
remove_wan_alias() {
    local fallback_dev="$1" dev

    if ! read_alias_state; then
        rm -f "${STATE_LOCAL_V6}"
        return 0
    fi

    dev="${ALIAS_DEV:-${fallback_dev}}"
    if drop_alias "${dev}" "${ALIAS_ADDR}"; then
        rm -f "${STATE_LOCAL_V6}"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Tunnel / default-route ownership
#
# Nothing is torn down unless we can prove we created it. A gif interface or a
# default route that predates the plugin belongs to somebody else.
# ---------------------------------------------------------------------------

record_owned_tunnel() {
    printf '%s %s %s\n' "$1" "$2" "$3" > "${STATE_OWNED_IF}"
}

# "iface <ifname>" for an interface route, "gw <address> <ifname>" otherwise.
record_owned_route() {
    printf '%s %s %s\n' "$1" "${2:--}" "$3" > "${STATE_OWNED_ROUTE}"
}

# Read the live tunnel endpoints of <device> into TUN_LOCAL / TUN_REMOTE.
read_tunnel_endpoints() {
    local ifdata
    TUN_LOCAL=""
    TUN_REMOTE=""
    ifdata=$(ifconfig "$1" 2>/dev/null) || return 1
    TUN_LOCAL=$(printf '%s' "${ifdata}" | awk '/tunnel inet6/ {gsub(/%.*/,"",$3); print $3; exit}')
    TUN_REMOTE=$(printf '%s' "${ifdata}" | awk '/tunnel inet6/ {gsub(/%.*/,"",$5); print $5; exit}')
    return 0
}

# True when <device> is a gif tunnel this plugin created.
#
# Preferred proof is the ownership state file written at creation time. When it
# is absent (upgrade from a version that did not record ownership, or /var/run
# cleared) we fall back to matching the live remote endpoint against the AFTR
# the current configuration would use. With neither, we claim nothing.
tunnel_is_ours() {
    local dev="$1" sdev want_local want_remote expected_aftr

    ifconfig "${dev}" >/dev/null 2>&1 || return 1
    read_tunnel_endpoints "${dev}" || return 1

    if [ -f "${STATE_OWNED_IF}" ]; then
        read -r sdev want_local want_remote < "${STATE_OWNED_IF}" 2>/dev/null || return 1
        [ "${sdev}" = "${dev}" ] || return 1
        [ "${TUN_LOCAL}" = "${want_local}" ] && [ "${TUN_REMOTE}" = "${want_remote}" ]
        return $?
    fi

    expected_aftr=$(get_expected_aftr)
    [ -n "${expected_aftr}" ] || return 1
    [ "${TUN_REMOTE}" = "${expected_aftr}" ]
}

# The address of the IPv4 gateway OPNsense has on the tunnel interface, empty
# when there is none.
#
# Giving the tunnel a gateway under System > Gateways is what makes monitoring
# and failover to a second WAN possible, and it makes OPNsense want to maintain
# the IPv4 default route itself. The two must agree on the route's shape or they
# overwrite each other on every interface event: system_default_route() compares
# the gateway address of the installed route against the one it wants, so a
# route installed as "via this interface" never matches and is replaced, while
# one installed via this address matches and is left alone.
#
# Standing aside entirely is not an option: at boot rc.bootup runs
# system_routing_configure() before the 'vpn' hook that builds the tunnel, so
# OPNsense refuses the gateway as addressless and installs nothing. If the
# plugin also installed nothing the box would come up without a default route.
#
# 'dslite' is the interface key this plugin registers in dslite_interfaces();
# the gateway_item stores that key rather than the device name.
OPNSENSE_GW_XPATH="/opnsense/OPNsense/Gateways/gateway_item[interface='dslite'][ipprotocol='inet'][not(disabled='1')]"

opnsense_gateway_address() {
    config_get "${OPNSENSE_GW_XPATH}/gateway"
}

# The address dpinger monitors for that gateway, empty when no host route for it
# is wanted.
#
# dpinger reaches its monitor over a host route pinned to the gateway. Without
# it the probes follow the default route instead, which after a failover is a
# different WAN entirely: the tunnel would be reported up because some other
# link answered, and it would never fail back. Rebuilding the tunnel drops that
# route along with everything else through the device, so it has to be put back.
#
# Mirrors dpinger's own conditions -- no route when monitoring is off, when
# monitor_noroute is set, or when the monitor is the gateway itself.
opnsense_gateway_monitor() {
    local monitor

    [ "$(config_get "${OPNSENSE_GW_XPATH}/monitor_noroute")" = "1" ] && return 0
    [ "$(config_get "${OPNSENSE_GW_XPATH}/monitor_disable")" = "1" ] && return 0

    monitor=$(config_get "${OPNSENSE_GW_XPATH}/monitor")
    [ -n "${monitor}" ] || return 0
    [ "${monitor}" = "$(opnsense_gateway_address)" ] && return 0

    printf '%s' "${monitor}"
}

# Delete the default route only when it is still the one we installed.
# A route that has since moved elsewhere belongs to the system again.
remove_owned_default_route() {
    local kind sgw sif cur_gw cur_if route_info

    if [ ! -f "${STATE_OWNED_ROUTE}" ]; then
        logger -t dslite "No recorded default-route ownership; leaving the system default route untouched"
        return 0
    fi
    read -r kind sgw sif < "${STATE_OWNED_ROUTE}" 2>/dev/null || return 0

    route_info=$(route -n get default 2>/dev/null)
    cur_gw=$(printf '%s' "${route_info}" | awk -F': ' '/gateway:/ {gsub(/[[:space:]]/,"",$2); print $2; exit}')
    cur_if=$(printf '%s' "${route_info}" | awk -F': ' '/interface:/ {gsub(/[[:space:]]/,"",$2); print $2; exit}')

    if [ -z "${route_info}" ]; then
        rm -f "${STATE_OWNED_ROUTE}"
        return 0
    fi

    if [ -n "${sif}" ] && [ "${sif}" != "-" ] && [ "${cur_if}" != "${sif}" ]; then
        logger -t dslite "Default route is via ${cur_if:-unknown}, not our ${sif}; not deleting it"
        rm -f "${STATE_OWNED_ROUTE}"
        return 0
    fi

    if [ "${kind}" = "gw" ] && [ -n "${sgw}" ] && [ "${sgw}" != "-" ] && [ "${cur_gw}" != "${sgw}" ]; then
        logger -t dslite "Default gateway is ${cur_gw:-unknown}, not our ${sgw}; not deleting it"
        rm -f "${STATE_OWNED_ROUTE}"
        return 0
    fi

    if route delete default >/dev/null 2>&1; then
        logger -t dslite "Removed the DS-Lite default route (${kind} ${sgw} ${sif})"
    fi
    rm -f "${STATE_OWNED_ROUTE}"
}
