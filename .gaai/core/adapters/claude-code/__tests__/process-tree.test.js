/**
 * process-tree.test.js
 *
 * Integration coverage for the two paths that terminate a runner's process tree.
 *
 * These need real processes. Every double in nested-claude-spawn.test.js is an
 * EventEmitter with a stubbed `kill` and no `pid`, so `_killTree` always takes its
 * direct-signal fallback and the group-signal path never executes there. The same
 * blind spot covers the parent 'exit' and signal handlers, which cannot be
 * exercised in-process without killing the test runner.
 *
 * The behaviour under test is what stops long-lived workers accumulating on a
 * delivery host: signalling the runner alone leaves its descendants orphaned.
 *
 * Skipped on Windows, which has no process groups — the production code takes its
 * documented fallback there and there is nothing group-shaped to assert.
 *
 * Run with: node --test .gaai/core/adapters/claude-code/__tests__/process-tree.test.js
 */

import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn as realSpawn, execFileSync } from 'node:child_process';
import { writeFileSync, mkdtempSync, chmodSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

import { _setSpawnFn, _resetSpawnFn, _spawnWithTimerOverride } from '../nested-claude-spawn.js';

const ADAPTER = join(dirname(fileURLToPath(import.meta.url)), '..', 'nested-claude-spawn.js');
const WINDOWS = process.platform === 'win32';

let dir;

/** A marker unique to one test run, so pgrep can find only our own strays. */
function marker(name) {
  return `gaai-tree-test-${name}-${process.pid}`;
}

/** Pids of live processes whose argv carries `needle`. Empty when none. */
function livePids(needle) {
  try {
    return execFileSync('pgrep', ['-f', needle], { encoding: 'utf8' })
      .split('\n').map(s => s.trim()).filter(Boolean);
  } catch {
    return []; // pgrep exits non-zero when nothing matches
  }
}

function reap(needle) {
  for (const pid of livePids(needle)) {
    try { process.kill(Number(pid), 'SIGKILL'); } catch { /* already gone */ }
  }
}

/**
 * Resolves true once nothing matches `needle`, false if still alive at the deadline.
 *
 * Deliberately independent of the spawn promise. When descendants are NOT reaped
 * they hold the runner's stdout open, so the close event never fires and the promise
 * never settles — awaiting it would turn a failure into a hung suite. Polling the
 * observable state instead makes the failure an assertion, which is what a
 * regression here should look like.
 */
async function waitGone(needle, timeoutMs = 8_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (livePids(needle).length === 0) return true;
    await new Promise(r => setTimeout(r, 100));
  }
  return livePids(needle).length === 0;
}

/**
 * Resolves true once something matches `needle`, false if nothing has appeared by
 * the deadline. Process start-up latency varies by host (a loaded delivery host took
 * ~650ms to show the descendant), so a fixed sleep before the precondition races.
 */
async function waitPresent(needle, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (livePids(needle).length > 0) return true;
    await new Promise(r => setTimeout(r, 50));
  }
  return livePids(needle).length > 0;
}

/**
 * Writes a stub runner plus the long-lived descendant it spawns, and returns the
 * stub's path. The stub does not trap signals: dying itself is exactly the case
 * where a descendant would be orphaned unless the whole group is signalled.
 *
 * The descendant is its own script rather than a bare `sleep`, because the search
 * below matches on argv and a bare `sleep 120` carries nothing identifying. An
 * earlier revision put the marker in a shell comment, which the shell discards —
 * the search then only ever matched the stub, so the assertion held whether or not
 * descendants were reaped. Mutation-testing the group signal is what exposed it.
 */
function writeStub(needle) {
  const descendant = join(dir, `desc-${needle}.sh`);
  writeFileSync(descendant, '#!/bin/bash\nsleep 120\n', 'utf8');
  chmodSync(descendant, 0o755);

  const path = join(dir, `stub-${needle}.sh`);
  writeFileSync(path, [
    '#!/bin/bash',
    `echo '{"type":"system","subtype":"init","session_id":"sess-${needle}"}'`,
    `"${descendant}" &`,
    'wait',
    ''].join('\n'), 'utf8');
  chmodSync(path, 0o755);
  return path;
}

/** Matches the descendant only — never the stub that spawned it. */
function descendantNeedle(needle) {
  return `desc-${needle}.sh`;
}

describe('nested-claude-spawn — process tree termination', { skip: WINDOWS }, () => {

  before(() => { dir = mkdtempSync(join(tmpdir(), 'gaai-tree-test-')); });
  after(() => { _resetSpawnFn(); try { rmSync(dir, { recursive: true, force: true }); } catch {} });

  test('killing a timed-out run reaps its descendants, not just the runner', async () => {
    const needle = marker('timeout');
    const stub = writeStub(needle);
    try {
      _setSpawnFn((_bin, _args, opts) => realSpawn(stub, [], opts));

      // A short grace, not zero: an orphaned descendant holds stdout open so the
      // close event never fires, and the budget is what turns that into a clean
      // assertion failure instead of a hung suite.
      process.env.GAAI_RUNNER_POLL_BUDGET_MS = '300';
      process.env.GAAI_IMPL_BASE_URL   = 'https://test.example.com';
      process.env.GAAI_IMPL_AUTH_TOKEN = 'test-token-do-not-log';
      process.env.GAAI_IMPL_MODEL      = 'test-model';

      const started = _spawnWithTimerOverride(
        'prompt', '', [], { globalTimeoutMs: 60_000, heartbeatTimeoutMs: 3_000 }
      );

      // The heartbeat window must outlast the descendant's start-up, so the kill
      // lands on a running tree rather than racing its creation.
      const desc = descendantNeedle(needle);
      assert.equal(await waitPresent(desc, 2_500), true,
        'precondition: the descendant must be running before the kill');

      assert.equal(await waitGone(desc), true,
        'the descendant must be reaped with the tree — signalling the runner alone orphans it');

      // Only now is the promise safe to await: with the tree gone, stdout is closed.
      const r = await started;
      assert.equal(r.success, false);
      assert.equal(r.error_reason, 'HEARTBEAT_TIMEOUT');
    } finally {
      delete process.env.GAAI_RUNNER_POLL_BUDGET_MS;
      _resetSpawnFn();
      reap(needle);
    }
  });

  test('a signalled wrapper reaps its tree and keeps its own exit status', async () => {
    const needle = marker('sigterm');
    const stub = writeStub(needle);
    const runner = join(dir, 'runner.mjs');
    // The parent signal handler cannot be exercised in-process — it re-raises and
    // would take the test runner with it. So the wrapper runs as its own process
    // and we signal that.
    writeFileSync(runner, `
import { spawn as realSpawn } from 'node:child_process';
const m = await import(${JSON.stringify(ADAPTER)});
m._setSpawnFn((_b, _a, opts) => realSpawn(${JSON.stringify(stub)}, [], opts));
process.env.GAAI_IMPL_BASE_URL = 'https://test.example.com';
process.env.GAAI_IMPL_AUTH_TOKEN = 't';
process.env.GAAI_IMPL_MODEL = 'm';
await m._spawnWithTimerOverride('p', '', [], { globalTimeoutMs: 120000, heartbeatTimeoutMs: 120000 });
`, 'utf8');

    try {
      const wrapper = realSpawn(process.execPath, [runner], { stdio: 'ignore' });
      const desc = descendantNeedle(needle);
      assert.equal(await waitPresent(desc), true,
        'precondition: the descendant must be running before the wrapper is signalled');

      const exit = new Promise(res => wrapper.on('exit', (code, signal) => res({ code, signal })));
      wrapper.kill('SIGTERM');
      const { code, signal } = await exit;

      // Re-raising rather than exiting outright is what preserves this: the daemon
      // classifies on the wrapper's status, so a handler that swallowed SIGTERM
      // would silently change how a killed phase is reported.
      assert.ok(signal === 'SIGTERM' || code === 143,
        `wrapper must die of SIGTERM, got code=${code} signal=${signal}`);

      assert.equal(await waitGone(desc), true,
        'wrapper death must not strand the tree it spawned');
    } finally {
      reap(needle);
    }
  });

});
