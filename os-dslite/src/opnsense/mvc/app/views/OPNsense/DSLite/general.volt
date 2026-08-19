{#
 # Copyright (C) 2024 DS-Lite Plugin Contributors
 # All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without modification,
 # are permitted provided that the following conditions are met:
 #
 # 1. Redistributions of source code must retain the above copyright notice,
 #    this list of conditions and the following disclaimer.
 #
 # 2. Redistributions in binary form must reproduce the above copyright notice,
 #    this list of conditions and the following disclaimer in the documentation
 #    and/or other materials provided with the distribution.
 #
 # THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 # INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 # AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 #}

<script>
    // ISP profile AFTR defaults
    var ispProfiles = {
        'auto': { 'hostname': '', 'address': '', 'readonly': true },
        'transix': { 'hostname': 'gw.transix.jp', 'address': '2001:c28:5:301::11', 'readonly': true },
        'xpass': { 'hostname': '', 'address': '2001:f60:0:200::1', 'readonly': true },
        'v6connect': { 'hostname': '', 'address': '2404:8e00::feed:100', 'readonly': true },
        'custom': { 'hostname': '', 'address': '', 'readonly': false }
    };

    // Fields that belong to each mode, keyed by the value of dslite.mode.
    //
    // isp_profile is deliberately NOT here: it applies to both DS-Lite and Fixed
    // IP. In DS-Lite it selects the AFTR, in Fixed IP it selects how the
    // provider's Interface ID maps into the CE address. Hiding it under Fixed IP
    // made the field that decides whether the tunnel passes traffic invisible.
    //
    // Every mode-specific field must appear here. A field left out is shown in
    // all three modes, which is how the MAP-E block used to behave.
    var modeFields = {
        'dslite': ['dslite\\.aftr_hostname', 'dslite\\.aftr_address'],
        'fixedip': ['dslite\\.fixedip_interface_id', 'dslite\\.fixedip_aftr', 'dslite\\.fixedip_v4',
                    'dslite\\.fixedip_update_url', 'dslite\\.fixedip_auth_user', 'dslite\\.fixedip_auth_pass',
                    'dslite\\.fixedip_allow_insecure'],
        'mape': ['dslite\\.mape_profile', 'dslite\\.mape_br', 'dslite\\.mape_rule_ipv6',
                 'dslite\\.mape_rule_ipv4', 'dslite\\.mape_ea_length', 'dslite\\.mape_psid_offset']
    };

    var xpassFields = ['dslite\\.fixedip_ddns_id', 'dslite\\.fixedip_ddns_pass', 'dslite\\.fixedip_fqdn'];

    $( document ).ready(function() {
        var data_get_map = {'frm_general_settings':"/api/dslite/settings/get"};
        mapDataToFormUI(data_get_map).done(function(data){
            formatTokenizersUI();
            $('.selectpicker').selectpicker('refresh');
            updateModeFields();
            updateProfileFields();
            updateXpassFields();
        });

        // Toggle fields based on mode
        $('#dslite\\.mode').on('changed.bs.select', function() {
            updateModeFields();
            updateXpassFields();
        });

        // base_form's "advanced mode" toggle reveals every data-advanced row at
        // once, including advanced fields belonging to a mode that is not
        // selected -- mape_psid_offset while in DS-Lite, for instance. Re-apply
        // the mode filter afterwards. Deferred so the core handler runs first.
        $(document).on('click', '[id^="show_advanced_formDialog"]', function() {
            setTimeout(function() {
                updateModeFields();
                updateXpassFields();
            }, 0);
        });

        // Update AFTR fields when ISP profile changes
        $('#dslite\\.isp_profile').on('changed.bs.select', function() {
            updateProfileFields();
            updateXpassFields();
        });

        // Is "advanced mode" currently on?
        //
        // Probed from a row that is advanced but belongs to no mode, so the
        // answer stays correct whichever mode is selected. Reading the toggle
        // icon's class instead would couple this to base_form's markup.
        function advancedShown() {
            var managed = [];
            $.each(modeFields, function(mode, fields) {
                fields.forEach(function(f) { managed.push('#' + f); });
            });
            var probe = $('tr[data-advanced="true"]').filter(function() {
                return $(this).find(managed.join(',')).length === 0;
            }).first();
            // No unmanaged advanced row to probe: assume on, so an in-mode
            // advanced field is shown rather than silently unreachable.
            return probe.length ? probe.is(':visible') : true;
        }

        // Show or hide a single field's row.
        //
        // An advanced row is never force-shown. Whether advanced fields are
        // visible is base_form's decision, and calling .show() on one here would
        // make it appear in basic mode -- which is what happens to
        // mape_psid_offset if this guard is dropped.
        function setRowVisible(field, visible) {
            var row = $('#' + field).closest('tr');
            if (visible && (row.attr('data-advanced') !== 'true' || advancedShown())) {
                row.show();
            } else {
                row.hide();
            }
        }

        function updateModeFields() {
            var mode = $('#dslite\\.mode').val();
            if (!modeFields.hasOwnProperty(mode)) {
                mode = 'dslite';
            }
            $.each(modeFields, function(m, fields) {
                fields.forEach(function(f) {
                    setRowVisible(f, m === mode);
                });
            });
            if (mode === 'dslite') {
                updateProfileFields();
            }
        }

        function updateProfileFields() {
            var profile = $('#dslite\\.isp_profile').val();
            if (profile && ispProfiles[profile]) {
                var p = ispProfiles[profile];
                if (profile === 'auto') {
                    $('#dslite\\.aftr_hostname').val('').prop('readonly', true);
                    $('#dslite\\.aftr_address').val('').prop('readonly', true);
                    $('#dslite\\.aftr_address').attr('placeholder', 'Will be detected from prefix');
                } else if (profile !== 'custom') {
                    $('#dslite\\.aftr_hostname').val(p.hostname).prop('readonly', true);
                    $('#dslite\\.aftr_address').val(p.address).prop('readonly', true);
                    $('#dslite\\.aftr_address').attr('placeholder', '');
                } else {
                    $('#dslite\\.aftr_hostname').prop('readonly', false);
                    $('#dslite\\.aftr_address').prop('readonly', false);
                    $('#dslite\\.aftr_address').attr('placeholder', 'IPv6 address of AFTR');
                }
            }
        }

        function updateXpassFields() {
            var mode = $('#dslite\\.mode').val();
            var profile = $('#dslite\\.isp_profile').val();
            var isXpass = (mode === 'fixedip' && profile === 'xpass');

            // Xpass does not use Interface ID; hide the row.
            if (mode === 'fixedip') {
                setRowVisible('dslite\\.fixedip_interface_id', !isXpass);
            }
        }

        // Status display helpers
        function setStatus(statusText, iconClass, badgeClass) {
            $('#tunnel_status').html('<span class="label ' + badgeClass + '">' + statusText + '</span>');
            $('#status_icon').attr('class', 'fa ' + iconClass);
        }

        function showApplying() {
            setStatus('Applying...', 'fa-spinner fa-spin text-warning', 'label-warning');
            $('#tunnel_connectivity').text('configuring...');
            $('#tunnel_local_v6').text('-');
            $('#tunnel_aftr').text('-');
            $('#tunnel_ipv4').text('-');
            $('#tunnel_mtu').text('-');
            $('#tunnel_reason').text('').parent().hide();
        }

        // Save settings
        $("#saveAct").SimpleActionButton({
            onPreAction: function() {
                const dfObj = new $.Deferred();
                showApplying();
                saveFormToEndpoint("/api/dslite/settings/set", 'frm_general_settings', function(){
                    dfObj.resolve();
                });
                return dfObj;
            },
            onAction: function(data, status) {
                ajaxCall("/api/dslite/service/reconfigure", {}, function(data, status) {
                    updateServiceControlUI('dslite');
                    setTimeout(refreshStatus, 2000);
                    setTimeout(refreshStatus, 5000);
                });
            }
        });

        // Status refresh
        function refreshStatus() {
            ajaxGet('/api/dslite/service/status', {}, function(data, status) {
                if (data && data.tunnel) {
                    var t = data.tunnel;

                    // The explicit health verdict takes precedence: a tunnel can
                    // be up and passing IPv4 while route, DNS, MTU, alias or
                    // prefix-update checks are failing, and that must not read
                    // as a plain green "Connected".
                    if (t.health === 'healthy') {
                        setStatus('Connected', 'fa-check-circle text-success', 'label-success');
                    } else if (t.health === 'degraded') {
                        if (t.connectivity === 'no internet') {
                            setStatus('Tunnel Up (No Internet)', 'fa-exclamation-circle text-warning', 'label-warning');
                        } else {
                            setStatus('Degraded', 'fa-exclamation-circle text-warning', 'label-warning');
                        }
                    } else if (t.status === 'disabled') {
                        setStatus('Disabled', 'fa-minus-circle text-muted', 'label-default');
                    } else if (t.health === 'offline' || t.status === 'not configured') {
                        setStatus('Not Running', 'fa-circle text-danger', 'label-danger');
                    } else if (t.status === 'up' && t.connectivity === 'connected') {
                        setStatus('Connected', 'fa-check-circle text-success', 'label-success');
                    } else if (t.status === 'up' && t.connectivity === 'no internet') {
                        setStatus('Tunnel Up (No Internet)', 'fa-exclamation-circle text-warning', 'label-warning');
                    } else if (t.status === 'up') {
                        setStatus('Tunnel Up', 'fa-circle text-success', 'label-success');
                    } else {
                        setStatus(t.status, 'fa-question-circle text-muted', 'label-default');
                    }

                    if (t.health && t.health !== 'healthy' && t.health_failures) {
                        $('#tunnel_failed_checks').text(t.health_failures);
                        $('#tunnel_failed_checks').closest('tr').show();
                    } else {
                        $('#tunnel_failed_checks').closest('tr').hide();
                    }

                    if (t.connectivity === 'connected') {
                        $('#tunnel_connectivity').html('<span class="text-success">OK</span>');
                    } else if (t.connectivity === 'no internet') {
                        $('#tunnel_connectivity').html('<span class="text-warning">No Internet</span>');
                    } else {
                        $('#tunnel_connectivity').html('<span class="text-muted">' + (t.connectivity || '-') + '</span>');
                    }

                    $('#tunnel_local_v6').text(t.local_v6 || '-');
                    $('#tunnel_aftr').text(t.aftr || '-');
                    $('#tunnel_ipv4').text(t.ipv4 || '-');
                    $('#tunnel_mtu').text(t.mtu || '-');

                    // closest('tr'), not parent(): parent() is the <td>, and
                    // showing that leaves the hidden row itself hidden.
                    if (t.reason) {
                        $('#tunnel_reason').text(t.reason);
                        $('#tunnel_reason').closest('tr').show();
                    } else {
                        $('#tunnel_reason').closest('tr').hide();
                    }
                }
            });
        }

        refreshStatus();
        setInterval(refreshStatus, 5000);

        updateServiceControlUI('dslite');
    });
</script>

<div class="content-box" style="padding: 10px;">
    <div class="content-box-header">
        <h3>{{ lang._('Tunnel Status') }}</h3>
    </div>
    <div class="content-box-main">
        <table class="table table-condensed">
            <tbody>
                <tr>
                    <td style="width: 150px;"><strong>{{ lang._('Status') }}</strong></td>
                    <td><i id="status_icon" class="fa fa-circle text-muted"></i> <span id="tunnel_status"><span class="label label-default">Loading...</span></span></td>
                </tr>
                <tr>
                    <td><strong>{{ lang._('Connectivity') }}</strong></td>
                    <td><span id="tunnel_connectivity">-</span></td>
                </tr>
                <tr style="display:none;">
                    <td><strong>{{ lang._('Failed checks') }}</strong></td>
                    <td><span id="tunnel_failed_checks" class="text-warning"></span></td>
                </tr>
                <tr>
                    <td><strong>{{ lang._('Local IPv6') }}</strong></td>
                    <td><span id="tunnel_local_v6">-</span></td>
                </tr>
                <tr>
                    <td><strong>{{ lang._('AFTR Address') }}</strong></td>
                    <td><span id="tunnel_aftr">-</span></td>
                </tr>
                <tr>
                    <td><strong>{{ lang._('Tunnel IPv4') }}</strong></td>
                    <td><span id="tunnel_ipv4">-</span></td>
                </tr>
                <tr>
                    <td><strong>{{ lang._('MTU') }}</strong></td>
                    <td><span id="tunnel_mtu">-</span></td>
                </tr>
                <tr style="display:none;">
                    <td><strong>{{ lang._('Info') }}</strong></td>
                    <td><span id="tunnel_reason" class="text-warning"></span></td>
                </tr>
            </tbody>
        </table>
    </div>
</div>

<div class="content-box" style="padding: 10px;">
    {{ partial("layout_partials/base_form",['fields':generalForm,'id':'frm_general_settings'])}}
    <div class="col-md-12">
        <hr />
        <button class="btn btn-primary" id="saveAct"
                data-endpoint='/api/dslite/service/reconfigure'
                data-label="{{ lang._('Apply') }}"
                data-error-title="{{ lang._('Error reconfiguring tunnel') }}"
                type="button">
        </button>
    </div>
</div>
