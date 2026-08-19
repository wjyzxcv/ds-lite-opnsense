# Summary of Changes for xpass / ARTERIA Networks Support

## Background
- Deployment: xpass 1G plan with direct ONT→OPNsense connection (no HGW / no Hikari Denwa)
- xpass uses RA/SLAAC mode (NEC Example 1) with query-based DDNS + HTTP Basic auth  
- CE address = SLAAC-assigned global IPv6 on WAN directly (no Interface ID used)  
- DDNS server presents expired/self-signed cert → requires `-k` flag when "Allow insecure" enabled

## Files Modified

### lib.sh
- Added `xpass_provisioning()` function — triggers only when ISP Profile is explicitly set to "xpass" (no auto-detection)
- In `dslite_authed_get()`: added hybrid auth handler for xpass — constructs query string with DDNS-ID/DDNS-PASS/FQDN + CE IPv6, uses netrc-based HTTP Basic auth (BASIC-ID/BASIC-PASS), respects "Allow insecure update URL" flag with `-k` curl option; returns error if xpass profile active but DDNS fields missing
- In `get_wan_ipv6()`: added sorting before selection for deterministic address choice when multiple globals exist

### configure.sh
- Added xpass branch: skips Interface ID requirement, uses `get_wan_ipv6()` as CE address (not fixedip_local_v6())
- Validates required fields for xpass: AFTR, Fixed IPv4, DDNS-ID, DDNS-PASS, FQDN, Update URL — exits with error if any missing
- Warns (non-fatal) if WAN has multiple unique global IPv6 addresses; CE is picked deterministically by sort order
- Transix/enabler path unchanged

### prefix_update.sh
- For periodic DDNS refresh every 30 min: uses `xpass_provisioning()` to select CE address source (`get_wan_ipv6()` for xpass, existing logic for others)
- Validates DDNS fields exist before attempting update; exits silently if missing (cron-safe)

### DSLite.xml (line 25)
- Added "xpass" option (Xpass / ARTERIA Networks) to ISP Profile dropdown

### general.xml
- Added DDNS-ID, DDNS-PASS, FQDN fields under Fixed IP section — each gated with `<showIf>` for xpass profile only
- Restored missing `<type>text</type>` on fixedip_interface_id field

### general.volt (line ~150)
- Simplified `updateXpassFields()`: hides Interface ID row via JS when xpass selected; DDNS fields are hidden/shown by XML-level showIf conditions instead of JS

## Behavior Summary
- RA/SLAAC mode: CE address = global IPv6 assigned to WAN interface directly  
- Query format: `?d=FQDN&p=DDNS-PASSWORD&a=<CE_IPV6>&u=DDNS_ID` with HTTP Basic auth using BASIC-ID/BASIC-PASS  
- No Interface ID required; no fixed IPv4 prefix assumed — uses SLAAC-assigned address for tunnel registration

## Known Quirks / Notes
- Plugin reports "degraded" status: xpass prefix update API returns HTML instead of plain text response, causing parse failure (but registration succeeds correctly)
- TCP MSS clamp must be set to ~1200 on gif0 due to path MTU constraints through the tunnel (~1236 actual path MTU); default 1460 MTU works with MSS clamping enabled
