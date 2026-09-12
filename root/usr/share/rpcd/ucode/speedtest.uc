'use strict';

import { access, mkdir, popen, readfile, rename, rmdir, unlink, writefile } from 'fs';

const SPEEDTEST_BIN  = '/usr/bin/speedtest';
const STATE_DIR      = '/var/lib/luci-app-speedtest';
const HISTORY_FILE   = STATE_DIR + '/history.json';
const HISTORY_TMP    = STATE_DIR + '/history.json.tmp';
const DEBUG_FILE     = STATE_DIR + '/debug.log';
const TEST_OUT       = STATE_DIR + '/test.out';
const TEST_ERR       = STATE_DIR + '/test.err';
const TEST_STATUS    = STATE_DIR + '/test.status';
const TEST_STARTED   = STATE_DIR + '/test.started';
const TEST_PID       = STATE_DIR + '/test.pid';
const SERVERS_FILE   = STATE_DIR + '/servers.json';
const SERVERS_TMP    = STATE_DIR + '/servers.json.tmp';
const LOCK_DIR       = '/var/run/luci-app-speedtest.lock';
const LOCK_PID       = LOCK_DIR + '/pid';
const HISTORY_MAX    = 200;   // capped entry count, bounds tmpfs growth
const HISTORY_MAX_BYTES = 262144;
const LIST_TIMEOUT   = 30;    // seconds allowed for the -L server list fetch
const TEST_TIMEOUT   = 60;    // seconds allowed for a single test run

// Run a command asynchronously and supervise it from ucode. This avoids
// relying on the optional BusyBox `timeout` applet.
function run_capture(cmd, timeout_secs, output_file, error_file, status_file) {
	unlink(output_file);
	unlink(error_file);
	unlink(status_file);

	const launcher = popen(sprintf('( %s; echo $? >%s ) >%s 2>%s & echo $!',
		cmd, status_file, output_file, error_file), 'r');
	if (!launcher)
		return { rc: -1, output: '' };

	const pid_text = trim(launcher.read('all') ?? '');
	launcher.close();
	const pid = int(pid_text);

	if (!pid) {
		unlink(output_file);
		unlink(error_file);
		unlink(status_file);
		return { rc: -1, output: '' };
	}

	writefile(LOCK_PID, pid);

	const deadline = time() + timeout_secs;
	let timed_out = false;

	while (!access(status_file, 'r') && time() < deadline)
		system('sleep 1');

	if (!access(status_file, 'r')) {
		timed_out = true;
		system(sprintf('kill -TERM %d 2>/dev/null', pid));
		system(sprintf('kill -KILL %d 2>/dev/null', pid));
	}

	const output = readfile(output_file, HISTORY_MAX_BYTES) ?? '';
	const error = readfile(error_file, HISTORY_MAX_BYTES) ?? '';
	const status = readfile(status_file, 32);
	unlink(output_file);
	unlink(error_file);
	unlink(status_file);
	unlink(LOCK_PID);

	return {
		rc: timed_out ? -9 : int(trim(status ?? '')),
		output: output,
		error: error
	};
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

function append_debug(message) {
	mkdir(STATE_DIR, 0700);
	const previous = readfile(DEBUG_FILE, HISTORY_MAX_BYTES) ?? '';
	writefile(DEBUG_FILE, previous + message + '\n');
}

function save_debug_output(output, error) {
	mkdir(STATE_DIR, 0700);
	writefile(DEBUG_FILE, (output || '') + (error || ''));
}

function release_lock() {
	unlink(LOCK_PID);
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

function finish_test() {
	const status = readfile(TEST_STATUS, 32);
	if (!status) {
		append_debug('DEBUG phase=finish status=missing');
		return { status: 'running' };
	}

	const output = readfile(TEST_OUT, HISTORY_MAX_BYTES) ?? '';
	const error = readfile(TEST_ERR, HISTORY_MAX_BYTES) ?? '';
	const rc = int(trim(status));
	save_debug_output(output, error);
	append_debug(sprintf('DEBUG phase=finish status=%d output_bytes=%d error_bytes=%d',
		rc, length(output), length(error)));
	unlink(TEST_OUT);
	unlink(TEST_ERR);
	unlink(TEST_STATUS);
	unlink(TEST_STARTED);
	unlink(TEST_PID);
	release_lock();

	if (rc != 0) {
		append_debug(sprintf('DEBUG phase=finish result=cli_error rc=%d', rc));
		return { status: 'error', error: 'Error executing speedtest CLI. Try again.' };
	}

	const result = parse_speedtest_json(output);
	if (!result) {
		append_debug('DEBUG phase=parse result=missing_json');
		return { status: 'error', error: 'Error executing speedtest CLI. Try again.' };
	}
	append_debug('DEBUG phase=parse result=json_object');

	if (!valid_history_entry(result)) {
		append_debug('DEBUG phase=parse result=invalid_schema');
		return { status: 'error', error: 'Error executing speedtest CLI. Try again.' };
	}
	append_debug('DEBUG phase=parse result=valid_schema');

	append_debug('DEBUG phase=history result=loading');
	const history = load_history();
	append_debug(sprintf('DEBUG phase=history result=loaded entries=%d', length(history)));
	push(history, result);
	append_debug(sprintf('DEBUG phase=history result=appended entries=%d', length(history)));
	if (!save_history(history)) {
		append_debug('DEBUG phase=history result=save_failed');
		return { status: 'error', error: 'could not save test history' };
	}

	append_debug('DEBUG phase=history result=saved');
	return { status: 'ok' };
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
	if (mkdir(LOCK_DIR, 0700))
		return true;

	const pid = int(trim(readfile(LOCK_PID) ?? ''));
	if (pid && access('/proc/' + pid, 'f'))
		return false;

	// Recover from a stale lock left by an interrupted request or an older
	// version that did not record the worker PID.
	rmdir(LOCK_DIR);
	return mkdir(LOCK_DIR, 0700);
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
					'/tmp/luci-app-speedtest-servers.err',
					'/tmp/luci-app-speedtest-servers.status');
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

				unlink(TEST_OUT);
				unlink(TEST_ERR);
				unlink(TEST_STATUS);
				unlink(TEST_PID);
				writefile(TEST_STARTED, time());
				append_debug(sprintf('DEBUG phase=launch server_id=%s', server_id));
				const cmd = sprintf('( %s --accept-license --accept-gdpr --format=json -s %s; echo $? >%s ) >%s 2>%s & echo $! >%s',
					SPEEDTEST_BIN, server_id, TEST_STATUS, TEST_OUT, TEST_ERR, TEST_PID);
				const launcher = popen(cmd, 'r');
				if (!launcher) {
					append_debug('DEBUG phase=launch result=popen_failed');
					release_lock();
					return { status: 'error', error: 'Error executing speedtest CLI. Try again.' };
				}

				launcher.close();
				let launch_wait = 0;
				while (!access(TEST_PID, 'r') && launch_wait < 2) {
					system('sleep 1');
					launch_wait++;
				}
				const pid = int(trim(readfile(TEST_PID) ?? ''));
				if (!pid) {
					append_debug('DEBUG phase=launch result=pid_missing');
					release_lock();
					return { status: 'error', error: 'Error executing speedtest CLI. Try again.' };
				}

				writefile(LOCK_PID, pid);
				append_debug(sprintf('DEBUG phase=launch result=started pid=%d', pid));
				return { status: 'started' };
			}
		},

		get_test_status: {
			call: function() {
				if (!access(LOCK_DIR, 'f'))
					return { status: 'idle', error: null };

				const started = int(trim(readfile(TEST_STARTED) ?? ''));
				const pid = int(trim(readfile(LOCK_PID) ?? ''));
				if (started && time() - started >= TEST_TIMEOUT && pid) {
					append_debug(sprintf('DEBUG phase=watchdog result=timeout pid=%d elapsed=%d',
						pid, time() - started));
					system(sprintf('kill -TERM %d 2>/dev/null; kill -KILL %d 2>/dev/null', pid, pid));
					writefile(TEST_STATUS, 124);
				}

				try {
					return finish_test();
				} catch (e) {
					unlink(TEST_OUT);
					unlink(TEST_ERR);
					unlink(TEST_STATUS);
					unlink(TEST_STARTED);
					unlink(TEST_PID);
					append_debug(sprintf('DEBUG phase=status result=exception error=%s', e));
					release_lock();
					return { status: 'error', error: 'Error executing speedtest CLI. Try again.' };
				}
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
