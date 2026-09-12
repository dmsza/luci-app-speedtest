'use strict';

import { access, mkdir, popen, readfile, rename, rmdir, writefile } from 'fs';

const SPEEDTEST_BIN  = '/usr/bin/speedtest';
const STATE_DIR      = '/var/lib/luci-app-speedtest';
const HISTORY_FILE   = STATE_DIR + '/history.json';
const HISTORY_TMP    = STATE_DIR + '/history.json.tmp';
const LOCK_DIR       = '/var/run/luci-app-speedtest.lock';
const HISTORY_MAX    = 200;   // capped entry count, bounds tmpfs growth
const HISTORY_MAX_BYTES = 262144;
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
// The CLI has used different headers and separators across releases, so rows
// are recognized by their numeric ID rather than a particular header line.
function parse_server_list(output) {
	const servers = [];

	for (let line in split(output, '\n')) {
		const t = trim(line);

		if (!match(t, /^[0-9]/))
			continue;

		const idm = match(t, /^([0-9]+)[) \t]+(.+)/);
		if (!idm)
			continue;

		const rest = trim(idm[2]);
		const parts = split(rest, /[ \t]{2,}/);

		if (length(parts) >= 2)
			push(servers, { id: idm[1], name: trim(parts[0]), location: trim(parts[1]) });
	}

	return servers;
}

function load_history() {
	if (!access(HISTORY_FILE, 'r'))
		return [];

	const raw = readfile(HISTORY_FILE, HISTORY_MAX_BYTES);

	if (!raw)
		return [];

	try {
		const data = json(raw);
		if (type(data) != 'array')
			return [];

		const history = [];
		for (let entry in data) {
			if (type(entry) == 'object')
				push(history, entry);
			if (length(history) >= HISTORY_MAX)
				break;
		}
		return history;
	} catch (e) {
		return [];
	}
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
		type(entry.download) == 'object' &&
		type(entry.upload) == 'object' &&
		type(entry.server) == 'object' &&
		type(entry.result) == 'object';
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
				if (!server_id)
					return { status: 'error', error: 'No server ID selected' };

				if (!match(server_id, /^[0-9]+$/))
					return { status: 'error', error: 'Invalid server ID' };

				if (!access(SPEEDTEST_BIN, 'x'))
					return { status: 'error', error: SPEEDTEST_BIN + ' not found' };

				if (!acquire_lock())
					return { status: 'error', error: 'A speed test is already running' };

				const cmd = sprintf('%s --accept-license --accept-gdpr --format=json -s %s 2>&1', SPEEDTEST_BIN, server_id);
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

				let result;
				try {
					result = json(output);
				} catch (e) {
					release_lock();
					return { status: 'error', error: 'could not parse JSON speedtest output' };
				}

				if (!valid_history_entry(result)) {
					release_lock();
					return { status: 'error', error: 'invalid JSON speedtest result' };
				}

				const history = load_history();
				push(history, result);
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
