'use strict';

import { access, mkdir, popen, readfile, rename, rmdir, unlink, writefile } from 'fs';

const SPEEDTEST_BIN  = '/usr/bin/speedtest';
const STATE_DIR      = '/var/lib/luci-app-speedtest';
const HISTORY_FILE   = STATE_DIR + '/history.json';
const HISTORY_TMP    = STATE_DIR + '/history.json.tmp';
const SERVERS_FILE   = STATE_DIR + '/servers.json';
const SERVERS_TMP    = STATE_DIR + '/servers.json.tmp';
const LOCK_DIR       = '/var/run/luci-app-speedtest.lock';
const HISTORY_MAX    = 200;   // capped entry count, bounds tmpfs growth
const HISTORY_MAX_BYTES = 262144;
const LIST_TIMEOUT   = 30;    // seconds allowed for the -L server list fetch
const TEST_TIMEOUT   = 60;    // seconds allowed for a single test run

// Run a command asynchronously and supervise it from ucode. This avoids
// relying on the optional BusyBox `timeout` applet.
function run_capture(cmd, timeout_secs, output_file, error_file) {
	unlink(output_file);
	unlink(error_file);

	const launcher = popen(sprintf('( exec %s ) >%s 2>%s & echo $!',
		cmd, output_file, error_file), 'r');
	if (!launcher)
		return { rc: -1, output: '' };

	const pid_text = trim(launcher.read('all') ?? '');
	launcher.close();
	const pid = int(pid_text);

	if (!pid) {
		unlink(output_file);
		unlink(error_file);
		return { rc: -1, output: '' };
	}

	const deadline = time() + timeout_secs;
	let timed_out = false;

	while (access('/proc/' + pid, 'f') && time() < deadline)
		system('sleep 1');

	if (access('/proc/' + pid, 'f')) {
		timed_out = true;
		system(sprintf('kill -TERM %d 2>/dev/null', pid));
		system(sprintf('kill -KILL %d 2>/dev/null', pid));
	}

	const output = readfile(output_file, HISTORY_MAX_BYTES) ?? '';
	const error = readfile(error_file, HISTORY_MAX_BYTES) ?? '';
	unlink(output_file);
	unlink(error_file);

	return { rc: timed_out ? -9 : 0, output: output, error: error };
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

function valid_servers(servers) {
	if (type(servers) != 'array' || !length(servers))
		return false;

	for (let server in servers) {
		if (type(server) != 'object' ||
			type(server.id) != 'string' ||
			type(server.name) != 'string' ||
			type(server.location) != 'string')
			return false;
	}

	return true;
}

function load_cached_servers() {
	if (!access(SERVERS_FILE, 'r'))
		return null;

	const raw = readfile(SERVERS_FILE, HISTORY_MAX_BYTES);
	if (!raw)
		return null;

	try {
		const cache = json(raw);
		if (type(cache) != 'object' ||
			type(cache.timestamp) != 'int' ||
			(time() - cache.timestamp) >= 86400 ||
			!valid_servers(cache.servers))
			return null;

		return cache.servers;
	} catch (e) {
		return null;
	}
}

function save_cached_servers(servers) {
	mkdir(STATE_DIR, 0700);
	return !!writefile(SERVERS_TMP, {
		timestamp: time(),
		servers: servers
	}) && !!rename(SERVERS_TMP, SERVERS_FILE);
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

function parse_speedtest_json(output) {
	for (let line in split(output, '\n')) {
		const candidate = trim(line);
		if (!candidate || candidate[0] != '{')
			continue;

		try {
			const result = json(candidate);
			if (type(result) == 'object')
				return result;
		} catch (e) {
			// Continue in case the CLI emitted another non-JSON line.
		}
	}

	return null;
}

const methods = {
	'luci.speedtest': {
		get_servers: {
			call: function() {
				if (!access(SPEEDTEST_BIN, 'x'))
					return { servers: [], error: 'speedtest binary not found' };

				const cached = load_cached_servers();
				if (cached)
					return { servers: cached };

				const cmd = sprintf('%s -L --accept-license --accept-gdpr', SPEEDTEST_BIN);
				const capture = run_capture(cmd, LIST_TIMEOUT,
					'/tmp/luci-app-speedtest-servers.out',
					'/tmp/luci-app-speedtest-servers.err');
				const rc = capture.rc;
				const output = capture.output;
				const servers = parse_server_list(output);

				if (!length(servers)) {
					let reason;
					if (rc == 124 || rc == -9)
						reason = sprintf('timed out after %ds', LIST_TIMEOUT);
					else if (rc == 0)
						reason = 'no servers returned';
					else
						reason = sprintf('speedtest exited with code %d', rc);
					return { servers: [], error: reason };
				}

				save_cached_servers(servers);
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

				const cmd = sprintf('%s --accept-license --accept-gdpr --format=json -s %s',
					SPEEDTEST_BIN, server_id);
				const capture = run_capture(cmd, TEST_TIMEOUT,
					'/tmp/luci-app-speedtest-test.out',
					'/tmp/luci-app-speedtest-test.err');
				const rc = capture.rc;
				const output = capture.output;
				const error = capture.error;

				if (rc != 0) {
					release_lock();
					return { status: 'error', error: 'Error executing speedtest CLI. Try again.' };
				}

				const result = parse_speedtest_json(output);
				if (!result) {
					release_lock();
					return { status: 'error', error: 'Error executing speedtest CLI. Try again.' };
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
