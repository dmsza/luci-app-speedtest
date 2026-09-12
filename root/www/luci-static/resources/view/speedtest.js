'use strict';
'require view';
'require rpc';
'require ui';

var callGetServers = rpc.declare({
    object: 'luci.speedtest',
    method: 'get_servers'
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

function formatBandwidth(bytesPerSecond) {
    return typeof bytesPerSecond === 'number' && isFinite(bytesPerSecond) ?
        (bytesPerSecond * 8 / 1000000).toFixed(2) + ' Mbps' : '-';
}

function formatLatency(latency) {
    return typeof latency === 'number' && isFinite(latency) ?
        latency.toFixed(2) + ' ms' : '-';
}

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
        var serverReply = data[0] && typeof data[0] === 'object' ? data[0] : {};
        var servers = Array.isArray(serverReply.servers) ? serverReply.servers : [];
        var history = Array.isArray(data[1]) ? data[1].slice().sort(function(a, b) {
            var aTime = Date.parse(a && a.timestamp);
            var bTime = Date.parse(b && b.timestamp);

            if (isNaN(aTime))
                return isNaN(bTime) ? 0 : 1;
            if (isNaN(bTime))
                return -1;

            return bTime - aTime;
        }) : [];

        var selectEl = E('select', { 'class': 'cbi-input-select', 'id': 'server_select' }, [
            E('option', { 'value': '' }, servers.length ? '-- Select Server --' :
                (serverReply.error || 'Error retrieving server list'))
        ]);

        if (!servers.length)
            selectEl.options[0].disabled = true;

        servers.forEach(function(s) {
            var label = s.name + ' | ' + s.location + ' | ' + s.id;
            selectEl.appendChild(E('option', { 'value': s.id }, label));
        });

        var statusEl = E('span', { 'style': 'margin-left: 10px; font-weight: bold;' }, '');

        var tableRows = history.map(function(row) {
            var server = row.server || {};
            var download = row.download || {};
            var upload = row.upload || {};
            var downloadLatency = download.latency || {};
            var uploadLatency = upload.latency || {};
            var result = row.result || {};
            var serverParts = [server.name, server.location, server.id].filter(function(value) {
                return value !== undefined && value !== null && value !== '';
            });
            var serverLabel = serverParts.length ? serverParts.join(' | ') : '-';
            var packetLoss = typeof row.packetLoss === 'number' && isFinite(row.packetLoss) ?
                row.packetLoss.toFixed(1) + '%' : '-';

            return E('tr', { 'class': 'cbi-section-table-row' }, [
                E('td', { 'class': 'td' }, row.timestamp || '-'),
                E('td', { 'class': 'td' }, serverLabel),
                E('td', { 'class': 'td' }, row.isp || '-'),
                E('td', { 'class': 'td' }, formatBandwidth(download.bandwidth)),
                E('td', { 'class': 'td' }, formatLatency(downloadLatency.iqm)),
                E('td', { 'class': 'td' }, formatBandwidth(upload.bandwidth)),
                E('td', { 'class': 'td' }, formatLatency(uploadLatency.iqm)),
                E('td', { 'class': 'td' }, packetLoss),
                E('td', { 'class': 'td' }, (result.url && /^https?:\/\//i.test(result.url)) ?
                    E('a', { 'href': result.url, 'target': '_blank', 'rel': 'noopener noreferrer' }, 'View Result') : '-')
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
        // Set the DOM property explicitly. Passing a false boolean attribute
        // through E() may still leave the HTML disabled attribute present.
        btnGo.disabled = servers.length === 0;

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
                        E('th', { 'class': 'th' }, 'Server Name'),
                        E('th', { 'class': 'th' }, 'ISP'),
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
                        E('td', { 'class': 'td', 'colspan': 9, 'style': 'text-align: center;' }, 'No test history available.')
                    ])
                ])
            ])
        ]);
    }
});
