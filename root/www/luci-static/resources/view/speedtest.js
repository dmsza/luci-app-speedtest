'use strict';
'require view';
'require rpc';
'require ui';

var callGetServers = rpc.declare({
    object: 'luci.speedtest',
    method: 'get_servers',
    expect: { servers: [] }
});

var callRunTest = rpc.declare({
    object: 'luci.speedtest',
    method: 'run_test',
    params: ['server_id', 'server_name']
    // No `expect` here on purpose: expect:{status:''} would pluck out only
    // the status field and drop the accompanying "error" field entirely,
    // so a failed run always showed "Unknown error" regardless of cause.
});

var callGetHistory = rpc.declare({
    object: 'luci.speedtest',
    method: 'get_history',
    expect: { history: [] }
});

return view.extend({
    handleSaveApply: null,
    handleSave: null,
    handleReset: null,

    addFooter: function() {
        return E([]);
    },

    load: function() {
        return Promise.all([
            callGetServers(),
            callGetHistory()
        ]);
    },

    render: function(data) {
        var servers = Array.isArray(data[0]) ? data[0] : [];
        var history = Array.isArray(data[1]) ? data[1] : [];

        var selectEl = E('select', { 'class': 'cbi-input-select', 'id': 'server_select' }, [
            E('option', { 'value': '' }, '-- Select Server --')
        ]);

        servers.forEach(function(s) {
            var label = s.name + ' | ' + s.location + ' | ' + s.id;
            selectEl.appendChild(E('option', { 'value': s.id }, label));
        });

        var statusEl = E('span', { 'style': 'margin-left: 10px; font-weight: bold;' }, '');

        var tableRows = history.map(function(row) {
            return E('tr', { 'class': 'cbi-section-table-row' }, [
                E('td', { 'class': 'td' }, row.timestamp),
                E('td', { 'class': 'td' }, row.server || '-'),
                E('td', { 'class': 'td' }, row.download),
                E('td', { 'class': 'td' }, row.download_latency),
                E('td', { 'class': 'td' }, row.upload),
                E('td', { 'class': 'td' }, row.upload_latency),
                E('td', { 'class': 'td' }, row.packet_loss),
                E('td', { 'class': 'td' }, (row.result_url && /^https?:\/\//i.test(row.result_url)) ?
                    E('a', { 'href': row.result_url, 'target': '_blank', 'rel': 'noopener noreferrer' }, 'View Result') : '-')
            ]);
        });

        var btnGo = E('button', {
            'class': 'cbi-button cbi-button-action',
            'click': ui.createHandlerFn(this, function() {
                var serverId = selectEl.value;
                var selectedOpt = selectEl.options[selectEl.selectedIndex];
                var serverName = selectedOpt ? selectedOpt.text : '';

                if (!serverId) {
                    ui.addNotification(null, E('p', 'Please select a server before pressing Go!'), 'error');
                    return;
                }

                selectEl.disabled = true;
                btnGo.disabled = true;
                statusEl.textContent = ' Running SpeedTest... Please wait...';

                return callRunTest(serverId, serverName).then(function(res) {
                    selectEl.disabled = false;
                    btnGo.disabled = false;
                    if (res && typeof res === 'object' && res.status === 'ok') {
                        statusEl.textContent = ' Test finished!';
                        location.reload();
                    } else if (res && typeof res === 'object' && res.error) {
                        statusEl.textContent = ' Test failed: ' + res.error;
                    } else {
                        // Unexpected reply shape (e.g. a bare ubus error code) -
                        // still surface something rather than claiming success.
                        statusEl.textContent = ' Test failed: unexpected response (' + JSON.stringify(res) + ')';
                    }
                }).catch(function(err) {
                    selectEl.disabled = false;
                    btnGo.disabled = false;
                    statusEl.textContent = ' RPC Error: ' + (err.message || err);
                });
            })
        }, 'Go!');

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, 'SpeedTest'),
            E('div', { 'class': 'cbi-section' }, [
                E('div', { 'class': 'cbi-value' }, [
                    E('label', { 'class': 'cbi-value-title' }, 'Server List'),
                    E('div', { 'class': 'cbi-value-field' }, [
                        selectEl,
                        ' ',
                        btnGo,
                        statusEl
                    ])
                ])
            ]),
            E('h3', {}, 'SpeedTest History'),
            E('table', { 'class': 'table cbi-section-table' }, [
                E('thead', {}, [
                    E('tr', { 'class': 'cbi-section-table-titles' }, [
                        E('th', { 'class': 'th' }, 'Timestamp'),
                        E('th', { 'class': 'th' }, 'Server'),
                        E('th', { 'class': 'th' }, 'Download'),
                        E('th', { 'class': 'th' }, 'Download Latency'),
                        E('th', { 'class': 'th' }, 'Upload'),
                        E('th', { 'class': 'th' }, 'Upload Latency'),
                        E('th', { 'class': 'th' }, 'Packet Loss'),
                        E('th', { 'class': 'th' }, 'Result URL')
                    ])
                ]),
                E('tbody', {}, tableRows.length > 0 ? tableRows : [
                    E('tr', { 'class': 'cbi-section-table-row' }, [
                        E('td', { 'class': 'td', 'colspan': 8, 'style': 'text-align: center;' }, 'No test history available.')
                    ])
                ])
            ])
        ]);
    }
});
