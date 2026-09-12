'use strict';

import { access, mkdir, popen, readfile, rename, rmdir, writefile } from 'fs';

const SPEEDTEST_BIN  = '/usr/bin/speedtest';
const STATE_DIR      = '/var/lib/luci-app-speedtest';
const HISTORY_FILE   = STATE_DIR + '/history.json';
const HISTORY_TMP    = STATE_DIR + '/history.json.tmp';
const LOCK_DIR       = '/var/run/luci-app-speedtest.lock';
const LEGACY_HISTORY_FILES = [ '/tmp/speedtest.log', '/etc/speedtest.log' ];
const HISTORY_MAX    = 200;   // capped entry count, bounds tmpfs growth
const HISTORY_MAX_BYTES = 65536;
const LIST_TIMEOUT   = 20;    // seconds allowed for the -L server list fetch
const TEST_TIMEOUT   = 180;   // seconds allowed for a single test run

// `timeout` is a standard busybox applet on OpenWrt, but availability is
// checked rather than assumed so the script degrades gracefully (runs
// without a hard timeout) on a system that lacks it.
const HAVE_TIMEOUT = (system('command -v timeout >/dev/null 2>&1') == 0);

// Runs a shell command, optionally wrapped in `timeout <n>`, and returns
// { rc, output }. rc is the process exit code (or a negative signal number,
// or -1 if the process could not even be started).
function run_capture(cmd, timeout_secs) {
	const full = HAVE_TIMEOUT ? sprintf('timeout %d %s', timeout_secs, cmd) : cmd;
	const proc = popen(full, 'r');

	if (!proc)
		return { rc: -1, output: '' };

	const output = proc.read('all') ?? '';
	const rc = proc.close();

	return { rc: rc, output: output };
}

// Parses `speedtest -L` output into an array of { id, name, location }.
// Mirrors the layout Ookla's CLI prints: a "===" separator line, then one
// row per server with the columns separated by runs of 2+ spaces/tabs.
function parse_server_list(output) {
	const servers = [];
	let in_table = false;

	for (let line in split(output, '\n')) {
		if (match(line, /^===/)) {
			in_table = true;
			continue;
		}

		if (!in_table)
			continue;

		const t = trim(line);

		if (!match(t, /^[0-9]/))
			continue;

		const idm = match(t, /^([0-9]+)/);
		const rest = replace(t, /^[0-9]+[ \t]+/, '');
		const parts = split(rest, /[ \t]{2,}/);

		if (length(parts) >= 2)
			push(servers, { id: idm[1], name: trim(parts[0]), location: trim(parts[1]) });
	}

	return servers;
}

// Parses the text output of a single `speedtest -s <id>` run. Fields default
// to "-" (packet loss to "0.0%") when a line is absent from the output,
// exactly as the previous shell/awk implementation did.
function parse_run_result(output, input_srv) {
	const lines = split(output, '\n');
	let srv = (input_srv && input_srv != '') ? input_srv : '-';
	let dl = '-', dl_lat = '-', ul = '-', ul_lat = '-', pkt = '0.0%', url = '-';

	for (let i = 0; i < length(lines); i++) {
		const line = lines[i];
		let m;

		if (match(line, /Server:/) && (m = match(line, /Server:[ \t]*(.+)/))) {
			const s = replace(trim(m[1]), /[ \t]*\(id.*$/, '');
			if (s != '')
				srv = s;
		}
		else if (match(line, /Download:/) && (m = match(line, /([0-9]+\.[0-9]+)[ \t]+(Mbps|Gbps|Kbps)/))) {
			dl = m[1] + ' ' + m[2];
			if (i + 1 < length(lines)) {
				const lm = match(lines[i + 1], /([0-9]+\.[0-9]+)[ \t]+ms/);
				if (lm)
					dl_lat = lm[1] + ' ms';
			}
		}
		else if (match(line, /Upload:/) && (m = match(line, /([0-9]+\.[0-9]+)[ \t]+(Mbps|Gbps|Kbps)/))) {
			ul = m[1] + ' ' + m[2];
			if (i + 1 < length(lines)) {
				const lm = match(lines[i + 1], /([0-9]+\.[0-9]+)[ \t]+ms/);
				if (lm)
					ul_lat = lm[1] + ' ms';
			}
		}
		else if ((m = match(line, /Packet Loss:[ \t]*([0-9]+\.[0-9]+%)/))) {
			pkt = m[1];
		}
		else if ((m = match(line, /Result URL:[ \t]*(\S+)/))) {
			url = m[1];
		}
	}

	return { srv, dl, dl_lat, ul, ul_lat, pkt, url };
}

function parse_legacy_history(raw) {
	const history = [];

	if (!raw)
		return history;

	const lines = split(raw, '\n');

	for (let i = 1; i < length(lines); i++) {
		const fields = split(trim(lines[i]), ',');

		if (length(fields) != 8)
			continue;

		const entry = {
			timestamp: trim(fields[0]),
			server: trim(fields[1]),
			download: trim(fields[2]),
			download_latency: trim(fields[3]),
			upload: trim(fields[4]),
			upload_latency: trim(fields[5]),
			packet_loss: trim(fields[6]),
			result_url: trim(fields[7])
		};

		if (valid_history_entry(entry))
			push(history, entry);
	}

	return history;
}

// History is stored as a plain JSON array. ucode's native JSON support means
// no CSV escaping/quoting scheme is needed at all (the previous shell
// version's naive CSV format could be corrupted by a comma or backslash in
// a server name; this cannot happen here).
function load_history() {
	if (access(HISTORY_FILE, 'r')) {
		const raw = readfile(HISTORY_FILE, HISTORY_MAX_BYTES);

		if (raw) {
			try {
				const data = json(raw);
				if (type(data) == 'array') {
					const history = [];
					for (let entry in data) {
						if (valid_history_entry(entry))
							push(history, entry);
						if (length(history) >= HISTORY_MAX)
							break;
					}
					return history;
				}
			} catch (e) {
				// Fall through and attempt to import the legacy CSV log.
			}
		}
	}

	for (let path in LEGACY_HISTORY_FILES) {
		if (!access(path, 'r'))
			continue;

		const legacy = parse_legacy_history(readfile(path, HISTORY_MAX_BYTES));
		if (length(legacy)) {
			save_history(legacy);
			return legacy;
		}
	}

	return [];
}

function save_history(history) {
	if (length(history) > HISTORY_MAX)
		history = slice(history, -HISTORY_MAX);

	mkdir(STATE_DIR, 0700);

	if (!writefile(HISTORY_TMP, history) || !rename(HISTORY_TMP, HISTORY_FILE))
		return false;

	return true;
}

function acquire_lock() {
	mkdir(STATE_DIR, 0700);
	return mkdir(LOCK_DIR, 0700);
}

function release_lock() {
	rmdir(LOCK_DIR);
}

function valid_history_entry(entry) {
	return type(entry) == 'object' &&
		type(entry.timestamp) == 'string' &&
		type(entry.server) == 'string' &&
		type(entry.download) == 'string' &&
		type(entry.download_latency) == 'string' &&
		type(entry.upload) == 'string' &&
		type(entry.upload_latency) == 'string' &&
		type(entry.packet_loss) == 'string' &&
		type(entry.result_url) == 'string';
}

function iso_timestamp() {
	const t = localtime();
	return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
		t.year, t.mon, t.mday, t.hour, t.min, t.sec);
}

const methods = {
	'luci.speedtest': {
		get_servers: {
			call: function() {
				if (!access(SPEEDTEST_BIN, 'x'))
					return { servers: [], error: 'speedtest binary not found' };

				const cmd = sprintf('%s -L --accept-license --accept-gdpr 2>/dev/null', SPEEDTEST_BIN);
				const capture = run_capture(cmd, LIST_TIMEOUT);
				const rc = capture.rc;
				const output = capture.output;
				const servers = parse_server_list(output);

				if (rc != 0 && !length(servers)) {
					const reason = (rc == 124 || rc == -9)
						? sprintf('timed out after %ds', LIST_TIMEOUT)
						: sprintf('speedtest exited with code %d', rc);
					return { servers: [], error: reason };
				}

				return { servers };
			}
		},

		run_test: {
			args: { server_id: 'example', server_name: 'example' },
			call: function(request) {
				const server_id = request.args.server_id;
				const server_name = request.args.server_name;

				if (!server_id)
					return { status: 'error', error: 'No server ID selected' };

				if (!match(server_id, /^[0-9]+$/))
					return { status: 'error', error: 'Invalid server ID' };

				if (!access(SPEEDTEST_BIN, 'x'))
					return { status: 'error', error: SPEEDTEST_BIN + ' not found' };

				if (!acquire_lock())
					return { status: 'error', error: 'A speed test is already running' };

				const cmd = sprintf('%s -s %s --accept-license --accept-gdpr 2>&1', SPEEDTEST_BIN, server_id);
				const capture = run_capture(cmd, TEST_TIMEOUT);
				const rc = capture.rc;
				const output = capture.output;

				if (rc != 0) {
					release_lock();
					let err_line;
					if (rc == 124 || rc == -9)
						err_line = sprintf('test timed out after %ds', TEST_TIMEOUT);
					else {
						const lines = filter(split(output, '\n'), length);
						err_line = length(lines) ? lines[-1] : sprintf('speedtest exited with code %d', rc);
					}
					return { status: 'error', error: err_line };
				}

				const parsed = parse_run_result(output, server_name);

				// speedtest exited 0 but nothing recognizable was found: the
				// CLI output format likely changed. Surface this instead of
				// silently logging a row of dashes.
				if (parsed.dl == '-' && parsed.ul == '-') {
					release_lock();
					return { status: 'error', error: 'could not parse speedtest output' };
				}

				const history = load_history();
				push(history, {
					timestamp: iso_timestamp(),
					server: parsed.srv,
					download: parsed.dl,
					download_latency: parsed.dl_lat,
					upload: parsed.ul,
					upload_latency: parsed.ul_lat,
					packet_loss: parsed.pkt,
					result_url: parsed.url
				});
				const saved = save_history(history);
				release_lock();

				if (!saved)
					return { status: 'error', error: 'could not save test history' };

				return { status: 'ok' };
			}
		},

		get_history: {
			call: function() {
				return { history: load_history() };
			}
		}
	}
};

return methods;
