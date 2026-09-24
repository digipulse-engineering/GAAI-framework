/**
 * nested-claude-spawn-routing.test.js
 *
 * Proxy-mode routing tests for nested-claude-spawn.js.
 * Covers the proxy-mode compatibility matrix: direct/proxy/proxy+secondary modes,
 * model/provider intent forwarding, and --strict-mcp-config injection.
 *
 * Run with:
 *   node --test .gaai/core/adapters/claude-code/__tests__/nested-claude-spawn-routing.test.js
 */

import { describe, test, before, after, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { writeFileSync, mkdtempSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

import {
  _setSpawnFn,
  _resetSpawnFn,
  runImpl,
} from '../nested-claude-spawn.js';

import { _setLogPath, _resetLogPath } from '../runtime-routing-logger.js';

// ---------------------------------------------------------------------------
// Mock child process helper (mirrors nested-claude-spawn.test.js pattern)
// ---------------------------------------------------------------------------

function createMockChild({ exitCode = 0, stdoutData = '', stderrData = '', delay = 10 } = {}) {
  const child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.exitCode = null;
  child.kill = () => {
    setImmediate(() => { child.exitCode = null; child.emit('close', null); });
  };
  process.nextTick(() => {
    if (stderrData) child.stderr.emit('data', Buffer.from(stderrData));
    if (stdoutData) child.stdout.emit('data', Buffer.from(stdoutData));
    setTimeout(() => { child.exitCode = exitCode; child.emit('close', exitCode); }, delay);
  });
  return child;
}

// ---------------------------------------------------------------------------
// Spawn-capture helper: installs _setSpawnFn to record all calls.
// Returns the calls array. Each entry: { binPath, args, env }.
// ---------------------------------------------------------------------------

function setupSpawnCapture({ perCallFn } = {}) {
  const calls = [];
  _setSpawnFn((binPath, spawnArgs, spawnOpts) => {
    const entry = { binPath, args: spawnArgs, env: spawnOpts.env };
    calls.push(entry);
    if (perCallFn) return perCallFn(calls.length - 1, entry);
    return createMockChild({ exitCode: 0, stdoutData: '## QA\nall good.' });
  });
  return calls;
}

// ---------------------------------------------------------------------------
// Environment helpers
// ---------------------------------------------------------------------------

const PROXY_URL  = 'http://127.0.0.1:8787';
const IMPL_URL   = 'https://api.z.ai/coding/paas/v4';
const IMPL_AUTH  = 'test-impl-token';
const IMPL_MODEL = 'glm-4.6';

// All vars this test file touches — saved and restored around the suite.
const ROUTING_VARS = [
  'GAAI_IMPL_BASE_URL',
  'GAAI_IMPL_AUTH_TOKEN',
  'GAAI_IMPL_MODEL',
  'GAAI_IMPL_MODEL_FALLBACK',
  'GAAI_CLAUDE_PROXY_BASE_URL',
  'ANTHROPIC_BASE_URL',
];

// Retired GAAI Cloud execution metadata — injected only as hostile input in
// the regression tests below, never as live routing-contract state. Kept
// separate from ROUTING_VARS so a leaked value cannot masquerade as routing
// state in an unrelated test.
const RETIRED_VARS = ['GAAI_NESTED_KEEP_MCP', 'GAAI_WORKSPACE_ID', 'GAAI_ORG_ID'];

function setProxyEnv() { process.env.GAAI_CLAUDE_PROXY_BASE_URL = PROXY_URL; }

function setImplEnv() {
  process.env.GAAI_IMPL_BASE_URL   = IMPL_URL;
  process.env.GAAI_IMPL_AUTH_TOKEN = IMPL_AUTH;
  process.env.GAAI_IMPL_MODEL      = IMPL_MODEL;
}

function clearRoutingEnv() {
  for (const k of ROUTING_VARS) delete process.env[k];
}

function clearRetiredEnv() {
  for (const k of RETIRED_VARS) delete process.env[k];
}

// ---------------------------------------------------------------------------
// Suite state
// ---------------------------------------------------------------------------

let savedRoutingVars = {};
let savedRetiredVars = {};
let savedPath;
let fakeBinDir;
let tmpLog;

// ---------------------------------------------------------------------------
// Suite setup: save ambient routing env, inject fake `claude` binary so
// findCLI() succeeds without the real Claude Code CLI being installed.
// ---------------------------------------------------------------------------

before(() => {
  // Save and clear all ambient routing env vars so developer's real env
  // (e.g. ANTHROPIC_BASE_URL pointing at a local GAAI gateway) does not
  // contaminate assertions.
  for (const k of ROUTING_VARS) {
    savedRoutingVars[k] = process.env[k];
    delete process.env[k];
  }
  for (const k of RETIRED_VARS) {
    savedRetiredVars[k] = process.env[k];
    delete process.env[k];
  }

  // Inject a fake `claude` binary — content doesn't matter, _setSpawnFn intercepts
  fakeBinDir = mkdtempSync(join(tmpdir(), 'gaai-routing-test-claude-'));
  const fakeClaude = join(fakeBinDir, 'claude');
  writeFileSync(fakeClaude, '#!/bin/sh\nexec true\n', { mode: 0o755 });
  savedPath = process.env.PATH;
  process.env.PATH = fakeBinDir + (savedPath ? ':' + savedPath : '');

  // Redirect routing log to avoid contaminating real logs
  tmpLog = join(fakeBinDir, 'runtime-routing.jsonl');
  _setLogPath(tmpLog);
});

after(() => {
  process.env.PATH = savedPath;
  _resetLogPath();
  // Restore all saved routing env vars
  for (const k of ROUTING_VARS) {
    if (savedRoutingVars[k] !== undefined) {
      process.env[k] = savedRoutingVars[k];
    } else {
      delete process.env[k];
    }
  }
  for (const k of RETIRED_VARS) {
    if (savedRetiredVars[k] !== undefined) {
      process.env[k] = savedRetiredVars[k];
    } else {
      delete process.env[k];
    }
  }
});

// Ensure each test starts with a clean routing env (prevents inter-test leakage)
beforeEach(() => { clearRoutingEnv(); clearRetiredEnv(); });

afterEach(() => {
  _resetSpawnFn();
  clearRoutingEnv();
  clearRetiredEnv();
});

// ---------------------------------------------------------------------------
// Helpers: invoke runImpl on a specific path
// ---------------------------------------------------------------------------

async function runImplPrimary() {
  return runImpl({
    implModelTag: 'primary',
    prompt:       'test-prompt',
    reportPath:   '',
    storyId:      'proxy-routing-test',
    logFile:      tmpLog,
  });
}

async function runImplSecondary() {
  return runImpl({
    implModelTag: null,
    prompt:       'test-prompt',
    reportPath:   '',
    storyId:      'proxy-routing-test',
    logFile:      tmpLog,
  });
}

// ===========================================================================
// AC1 — No proxy, no GAAI_IMPL_*: primary direct behavior unchanged
// ===========================================================================

describe('AC1 — no proxy, no GAAI_IMPL_* (primary direct, behavior unchanged)', () => {

  test('primary child env: ANTHROPIC_BASE_URL not injected when no proxy configured', async () => {
    // Precondition: no proxy vars (clearRoutingEnv in beforeEach guarantees this)
    const calls = setupSpawnCapture();
    await runImplPrimary();
    assert.equal(calls.length, 1, 'exactly one spawn call');
    assert.equal(calls[0].env.GAAI_CLAUDE_PROXY_BASE_URL, undefined,
      'GAAI_CLAUDE_PROXY_BASE_URL must not be set in child env when absent from parent');
    assert.notEqual(calls[0].env.ANTHROPIC_BASE_URL, PROXY_URL,
      'ANTHROPIC_BASE_URL must not be set to PROXY_URL when no proxy configured');
  });

  test('primary child env: CLAUDECODE blanked (nested Claude Code detection bypass)', async () => {
    const calls = setupSpawnCapture();
    await runImplPrimary();
    assert.equal(calls[0].env.CLAUDECODE, '', 'CLAUDECODE must be empty string');
  });

});

// ===========================================================================
// AC1 — No proxy, GAAI_IMPL_* configured: existing direct secondary behavior preserved
// ===========================================================================

describe('AC1 — no proxy, GAAI_IMPL_* configured (direct secondary unchanged)', () => {

  test('buildChildEnv: GAAI_IMPL_BASE_URL → ANTHROPIC_BASE_URL', async () => {
    setImplEnv();
    const calls = setupSpawnCapture();
    await runImplSecondary();
    assert.ok(calls.length >= 1, 'at least one spawn call');
    assert.equal(calls[0].env.ANTHROPIC_BASE_URL, IMPL_URL,
      'ANTHROPIC_BASE_URL must be set to GAAI_IMPL_BASE_URL in direct secondary mode');
  });

  test('buildChildEnv: GAAI_IMPL_AUTH_TOKEN → ANTHROPIC_AUTH_TOKEN', async () => {
    setImplEnv();
    const calls = setupSpawnCapture();
    await runImplSecondary();
    assert.equal(calls[0].env.ANTHROPIC_AUTH_TOKEN, IMPL_AUTH,
      'ANTHROPIC_AUTH_TOKEN must be set from GAAI_IMPL_AUTH_TOKEN');
  });

  test('buildChildEnv: GAAI_IMPL_MODEL → ANTHROPIC_DEFAULT_OPUS_MODEL', async () => {
    setImplEnv();
    const calls = setupSpawnCapture();
    await runImplSecondary();
    assert.equal(calls[0].env.ANTHROPIC_DEFAULT_OPUS_MODEL, IMPL_MODEL,
      'ANTHROPIC_DEFAULT_OPUS_MODEL must be set from GAAI_IMPL_MODEL');
  });

});

// ===========================================================================
// AC2 — Proxy + GAAI_IMPL_*: proxy wins for transport, intent still forwarded
// ===========================================================================

describe('AC2 — proxy + GAAI_IMPL_* (proxy wins for ANTHROPIC_BASE_URL)', () => {

  test('buildChildEnv: ANTHROPIC_BASE_URL = proxy URL, not GAAI_IMPL_BASE_URL', async () => {
    setImplEnv();
    setProxyEnv();
    const calls = setupSpawnCapture();
    await runImplSecondary();
    assert.ok(calls.length >= 1, 'at least one spawn call');
    assert.equal(calls[0].env.ANTHROPIC_BASE_URL, PROXY_URL,
      'ANTHROPIC_BASE_URL must be proxy URL (not GAAI_IMPL_BASE_URL) when proxy is configured');
    assert.notEqual(calls[0].env.ANTHROPIC_BASE_URL, IMPL_URL,
      'ANTHROPIC_BASE_URL must not be GAAI_IMPL_BASE_URL when proxy is configured');
  });

  test('buildChildEnv: GAAI_IMPL_AUTH_TOKEN still forwarded to ANTHROPIC_AUTH_TOKEN', async () => {
    setImplEnv();
    setProxyEnv();
    const calls = setupSpawnCapture();
    await runImplSecondary();
    assert.equal(calls[0].env.ANTHROPIC_AUTH_TOKEN, IMPL_AUTH,
      'ANTHROPIC_AUTH_TOKEN must still be set from GAAI_IMPL_AUTH_TOKEN in proxy mode');
  });

  test('buildChildEnv: GAAI_IMPL_MODEL still forwarded to ANTHROPIC_DEFAULT_OPUS_MODEL', async () => {
    setImplEnv();
    setProxyEnv();
    const calls = setupSpawnCapture();
    await runImplSecondary();
    assert.equal(calls[0].env.ANTHROPIC_DEFAULT_OPUS_MODEL, IMPL_MODEL,
      'ANTHROPIC_DEFAULT_OPUS_MODEL must still be set from GAAI_IMPL_MODEL in proxy mode');
  });

});

// ===========================================================================
// AC3 — Model/provider intent observable via env, not prompt text
// ===========================================================================

describe('AC3 — Impl model intent observable via deterministic env (not prompt text)', () => {

  test('GAAI_IMPL_MODEL expressed as ANTHROPIC_DEFAULT_OPUS_MODEL in secondary child env', async () => {
    setImplEnv();
    const calls = setupSpawnCapture();
    await runImplSecondary();
    assert.equal(calls[0].env.ANTHROPIC_DEFAULT_OPUS_MODEL, IMPL_MODEL,
      'Model intent must be in ANTHROPIC_DEFAULT_OPUS_MODEL, observable to the subprocess');
  });

  test('proxy mode: GAAI_IMPL_MODEL still in child env for gateway to read', async () => {
    setImplEnv();
    setProxyEnv();
    const calls = setupSpawnCapture();
    await runImplSecondary();
    // Inherited from parent env (not deleted by buildChildEnv) — gateway can read it
    assert.equal(calls[0].env.GAAI_IMPL_MODEL, IMPL_MODEL,
      'GAAI_IMPL_MODEL must be present in child env for gateway observability');
    // Also mapped to ANTHROPIC_DEFAULT_OPUS_MODEL for API-level routing
    assert.equal(calls[0].env.ANTHROPIC_DEFAULT_OPUS_MODEL, IMPL_MODEL,
      'ANTHROPIC_DEFAULT_OPUS_MODEL must also express model intent');
  });

});

// ===========================================================================
// AC4 — Primary path in proxy mode: buildPrimaryChildEnv forwards proxy
// ===========================================================================

describe('AC4 — buildPrimaryChildEnv in proxy mode (no GAAI_IMPL_*)', () => {

  test('GAAI_CLAUDE_PROXY_BASE_URL → ANTHROPIC_BASE_URL in primary child env', async () => {
    setProxyEnv();
    const calls = setupSpawnCapture();
    await runImplPrimary();
    assert.equal(calls.length, 1, 'exactly one spawn call on explicit primary path');
    assert.equal(calls[0].env.ANTHROPIC_BASE_URL, PROXY_URL,
      'buildPrimaryChildEnv must set ANTHROPIC_BASE_URL to proxy URL when GAAI_CLAUDE_PROXY_BASE_URL is set');
  });

  test('no proxy → ANTHROPIC_BASE_URL not injected by buildPrimaryChildEnv', async () => {
    // clearRoutingEnv() in beforeEach ensures GAAI_CLAUDE_PROXY_BASE_URL is absent
    const calls = setupSpawnCapture();
    await runImplPrimary();
    // buildPrimaryChildEnv must not add a proxy URL when none is configured
    assert.equal(calls[0].env.ANTHROPIC_BASE_URL, undefined,
      'ANTHROPIC_BASE_URL must remain undefined when no proxy is configured');
  });

  test('proxy mode: --strict-mcp-config injected for primary subprocess', async () => {
    setProxyEnv();
    const calls = setupSpawnCapture();
    await runImplPrimary();
    assert.ok(calls[0].args.includes('--strict-mcp-config'),
      '--strict-mcp-config must be in primary spawn args when proxy is a non-Anthropic host');
  });

});

// ===========================================================================
// AC5 — Fallback paths in proxy mode preserve proxy transport
// ===========================================================================

describe('AC5 — proxy mode fallback: primary fallback preserves ANTHROPIC_BASE_URL=proxy', () => {

  test('secondary failure in proxy mode → primary fallback uses proxy URL', async () => {
    setImplEnv();
    setProxyEnv();

    const calls = setupSpawnCapture({
      perCallFn: (idx) => {
        if (idx === 0) {
          // Secondary attempt → fail with auth error to trigger fallback
          return createMockChild({ exitCode: 1, stderrData: '401 Unauthorized' });
        }
        // Primary fallback → succeed
        return createMockChild({ exitCode: 0, stdoutData: '## QA\nPASSED.' });
      },
    });

    await runImplSecondary();

    assert.ok(calls.length >= 2,
      'must have at least 2 spawn calls (secondary + primary fallback)');

    // Secondary call must use proxy URL
    assert.equal(calls[0].env.ANTHROPIC_BASE_URL, PROXY_URL,
      'secondary spawn must use proxy URL for ANTHROPIC_BASE_URL');

    // Primary fallback must also use proxy (not fall back to direct Anthropic)
    assert.equal(calls[1].env.ANTHROPIC_BASE_URL, PROXY_URL,
      'primary fallback spawn must preserve proxy URL (no silent wrong-upstream routing)');
  });

  test('primary fallback must not switch to GAAI_IMPL_BASE_URL (gateway bypass forbidden)', async () => {
    setImplEnv();
    setProxyEnv();

    const calls = setupSpawnCapture({
      perCallFn: (idx) => {
        if (idx === 0) return createMockChild({ exitCode: 1, stderrData: 'connection refused' });
        return createMockChild({ exitCode: 0, stdoutData: '## QA\nPASSED.' });
      },
    });

    await runImplSecondary();

    assert.ok(calls.length >= 2, 'fallback must occur');
    assert.notEqual(calls[1].env.ANTHROPIC_BASE_URL, IMPL_URL,
      'primary fallback must not route through GAAI_IMPL_BASE_URL (would bypass gateway)');
  });

  test('proxy-only mode (no GAAI_IMPL_*): single primary spawn uses proxy URL', async () => {
    setProxyEnv();
    // No GAAI_IMPL_* → resolveMode Row 5 → primary path
    const calls = setupSpawnCapture();
    await runImplSecondary();
    assert.equal(calls.length, 1, 'single primary spawn call');
    assert.equal(calls[0].env.ANTHROPIC_BASE_URL, PROXY_URL,
      'primary subprocess must use proxy URL when GAAI_CLAUDE_PROXY_BASE_URL is set');
  });

});

// ===========================================================================
// buildSpawnArgs — isNonAnthropicShim: --strict-mcp-config injection
// ===========================================================================

describe('buildSpawnArgs — isNonAnthropicShim (--strict-mcp-config injection)', () => {

  test('ANTHROPIC_BASE_URL = non-anthropic host → --strict-mcp-config injected', async () => {
    process.env.ANTHROPIC_BASE_URL = PROXY_URL;
    const calls = setupSpawnCapture();
    await runImplPrimary();
    assert.ok(calls[0].args.includes('--strict-mcp-config'),
      '--strict-mcp-config must be injected when ANTHROPIC_BASE_URL is non-Anthropic');
  });

  test('GAAI_CLAUDE_PROXY_BASE_URL set (no ANTHROPIC_BASE_URL) → --strict-mcp-config injected', async () => {
    // Operator uses only GAAI_CLAUDE_PROXY_BASE_URL; ANTHROPIC_BASE_URL absent from parent
    // clearRoutingEnv() in beforeEach ensures ANTHROPIC_BASE_URL is absent
    setProxyEnv();
    const calls = setupSpawnCapture();
    await runImplPrimary();
    assert.ok(calls[0].args.includes('--strict-mcp-config'),
      '--strict-mcp-config must be injected when GAAI_CLAUDE_PROXY_BASE_URL is a non-Anthropic host');
  });

  test('ANTHROPIC_BASE_URL = https://api.anthropic.com → --strict-mcp-config NOT injected', async () => {
    process.env.ANTHROPIC_BASE_URL = 'https://api.anthropic.com';
    const calls = setupSpawnCapture();
    await runImplPrimary();
    assert.ok(!calls[0].args.includes('--strict-mcp-config'),
      '--strict-mcp-config must NOT be injected when targeting official Anthropic endpoint');
  });

  test('no proxy vars → --strict-mcp-config NOT injected', async () => {
    // clearRoutingEnv() in beforeEach ensures both ANTHROPIC_BASE_URL and
    // GAAI_CLAUDE_PROXY_BASE_URL are absent
    const calls = setupSpawnCapture();
    await runImplPrimary();
    assert.ok(!calls[0].args.includes('--strict-mcp-config'),
      '--strict-mcp-config must NOT be injected when no proxy is configured');
  });

  test('retired GAAI_NESTED_KEEP_MCP=1 has no effect — strict flag still injected in proxy mode', async () => {
    setProxyEnv();
    process.env.GAAI_NESTED_KEEP_MCP = '1';
    const calls = setupSpawnCapture();
    await runImplPrimary();
    assert.ok(calls[0].args.includes('--strict-mcp-config'),
      '--strict-mcp-config has no opt-out; the retired GAAI_NESTED_KEEP_MCP variable must not suppress it');
  });

  test('retired GAAI_NESTED_KEEP_MCP with any value has no effect', async () => {
    setProxyEnv();
    for (const value of ['0', '', 'true', 'yes']) {
      process.env.GAAI_NESTED_KEEP_MCP = value;
      const calls = setupSpawnCapture();
      await runImplPrimary();
      assert.ok(calls[0].args.includes('--strict-mcp-config'),
        `--strict-mcp-config must still be injected when GAAI_NESTED_KEEP_MCP=${JSON.stringify(value)}`);
      _resetSpawnFn();
    }
  });

});

// ===========================================================================
// AC3/AC6 — retired GAAI_WORKSPACE_ID / GAAI_ORG_ID: no reach into spawn
// argv, child env or the normalized result shape (QA cycle-1 F1 fix — the
// handle-artefact assertions in nested-claude-spawn.test.js proved this
// indirectly; AC3/AC6 name argv/env/result explicitly, so this suite proves
// those channels directly against the capture harness already in this file)
// ===========================================================================

const KNOWN_RESULT_FIELDS = new Set([
  'trace_id', 'success', 'exit_code', 'error_reason', 'impl_report_path',
  'model_actual', 'duration_ms', 'model_requested', 'model_fallback_triggered',
  'provider_base_url', 'telemetry', 'session_id', 'terminal_receipt',
  'observation_window_expired', 'log_emit_failed',
]);

describe('retired GAAI_WORKSPACE_ID / GAAI_ORG_ID — no reach into argv, env or result', () => {

  test('injected workspace/org values do not appear in spawn argv; MCP access not broadened', async () => {
    process.env.GAAI_WORKSPACE_ID = 'ws-example';
    process.env.GAAI_ORG_ID = 'org-example';
    const calls = setupSpawnCapture();
    await runImplPrimary();
    const argvJoined = calls[0].args.join(' ');
    assert.ok(!argvJoined.includes('ws-example'),
      'spawn argv must not contain the injected GAAI_WORKSPACE_ID value');
    assert.ok(!argvJoined.includes('org-example'),
      'spawn argv must not contain the injected GAAI_ORG_ID value');
    assert.ok(!calls[0].args.includes('--mcp-config'),
      'injected workspace/org identity must not broaden MCP access via an explicit --mcp-config flag');
  });

  test('injected workspace/org values are scrubbed from the child environment (primary path)', async () => {
    process.env.GAAI_WORKSPACE_ID = 'ws-example';
    process.env.GAAI_ORG_ID = 'org-example';
    const calls = setupSpawnCapture();
    await runImplPrimary();
    assert.equal(calls[0].env.GAAI_WORKSPACE_ID, undefined,
      'GAAI_WORKSPACE_ID must be scrubbed from the child environment');
    assert.equal(calls[0].env.GAAI_ORG_ID, undefined,
      'GAAI_ORG_ID must be scrubbed from the child environment');
  });

  test('injected workspace/org values are scrubbed on the secondary→primary fallback spawn too', async () => {
    process.env.GAAI_WORKSPACE_ID = 'ws-example';
    process.env.GAAI_ORG_ID = 'org-example';
    setImplEnv();

    const calls = setupSpawnCapture({
      perCallFn: (idx) => {
        if (idx === 0) return createMockChild({ exitCode: 1, stderrData: '401 Unauthorized' });
        return createMockChild({ exitCode: 0, stdoutData: '## QA\nPASSED.' });
      },
    });

    await runImplSecondary();

    assert.ok(calls.length >= 2, 'fallback must occur (secondary + primary)');
    for (const call of calls) {
      assert.equal(call.env.GAAI_WORKSPACE_ID, undefined,
        'GAAI_WORKSPACE_ID must be scrubbed on every spawn path, including the primary fallback');
      assert.equal(call.env.GAAI_ORG_ID, undefined,
        'GAAI_ORG_ID must be scrubbed on every spawn path, including the primary fallback');
      const argvJoined = call.args.join(' ');
      assert.ok(!argvJoined.includes('ws-example') && !argvJoined.includes('org-example'),
        'neither injected value may appear in argv on any spawn in the fallback chain');
    }
  });

  test('injected workspace/org values add no field to the normalized SpawnResult', async () => {
    process.env.GAAI_WORKSPACE_ID = 'ws-example';
    process.env.GAAI_ORG_ID = 'org-example';
    setupSpawnCapture();
    const result = await runImplPrimary();
    for (const key of Object.keys(result)) {
      assert.ok(KNOWN_RESULT_FIELDS.has(key),
        `SpawnResult must not gain a new field from injected workspace/org env; unexpected key: ${key}`);
    }
    assert.ok(!('workspace_id' in result), 'SpawnResult must not carry workspace_id');
    assert.ok(!('org_id' in result), 'SpawnResult must not carry org_id');
  });

  test('injected workspace/org values add no field or value to the routing record', async () => {
    process.env.GAAI_WORKSPACE_ID = 'ws-routing-record-example';
    process.env.GAAI_ORG_ID = 'org-routing-record-example';
    setupSpawnCapture();
    await runImplPrimary();

    const logContents = readFileSync(tmpLog, 'utf8');
    assert.ok(!logContents.includes('ws-routing-record-example'),
      'routing log must not contain the injected GAAI_WORKSPACE_ID value');
    assert.ok(!logContents.includes('org-routing-record-example'),
      'routing log must not contain the injected GAAI_ORG_ID value');

    const records = logContents
      .trim()
      .split('\n')
      .filter((line) => line.trim().startsWith('{'))
      .map((line) => JSON.parse(line));
    const record = records[records.length - 1];
    assert.ok(record, 'runImpl must append a structured routing record');
    assert.ok(!('workspace_id' in record), 'routing record must not carry workspace_id');
    assert.ok(!('org_id' in record), 'routing record must not carry org_id');
  });

});

// ===========================================================================
// Source scans — retired GAAI Cloud execution metadata must not reappear
// ===========================================================================

const __dirnameHere = dirname(fileURLToPath(import.meta.url));
const ADAPTER_SRC_PATH = join(__dirnameHere, '..', 'nested-claude-spawn.js');
const DAEMON_DOC_PATH  = join(__dirnameHere, '..', '..', '..', 'compat', 'commands', 'gaai-oss', 'daemon.md');

describe('source scans — no retired Cloud execution metadata', () => {

  test('nested-claude-spawn.js source contains no GAAI_NESTED_KEEP_MCP', () => {
    const src = readFileSync(ADAPTER_SRC_PATH, 'utf8');
    assert.ok(!src.includes('GAAI_NESTED_KEEP_MCP'),
      'nested-claude-spawn.js must not reference the retired GAAI_NESTED_KEEP_MCP variable');
  });

  test('daemon.md documents no retired variable and no GAAI Cloud exception', () => {
    const doc = readFileSync(DAEMON_DOC_PATH, 'utf8');
    assert.ok(!doc.includes('GAAI_NESTED_KEEP_MCP'),
      'daemon.md must not document the retired GAAI_NESTED_KEEP_MCP variable');
    assert.ok(!/gaai cloud/i.test(doc),
      'daemon.md must not name a GAAI Cloud exception, connector or workspace input');
  });

});

// ===========================================================================
// Phase-agent tool denials — the impl child is denied forge-write commands
// ===========================================================================
//
// A defence-in-depth belt, not a security boundary (see PHASE_DENIED_TOOLS in
// the adapter). The expected list is spelled out here rather than imported, so
// the test states the contract instead of echoing the implementation.

const EXPECTED_DENIED_TOOLS = [
  'Bash(git push *)',
  'Bash(gh pr create *)',
  'Bash(gh pr merge *)',
  'Bash(gh pr edit *)',
  'Bash(gh pr close *)',
  'Bash(gh pr ready *)',
  'Bash(gh pr comment *)',
];
const DISPATCH_SRC_PATH = join(__dirnameHere, '..', '..', '..', 'scripts', 'daemon-dispatch.sh');

function deniedToolsFromArgv(args) {
  const i = args.indexOf('--disallowedTools');
  if (i < 0) return null;
  const values = [];
  for (let j = i + 1; j < args.length && !args[j].startsWith('-'); j++) values.push(args[j]);
  return { values, next: args[i + 1 + values.length] };
}

describe('phase-agent tool denials — impl child argv', () => {

  for (const [label, run] of [['primary', runImplPrimary], ['secondary', runImplSecondary]]) {
    test(`${label} route passes --disallowedTools with the full forge-write list`, async () => {
      if (label === 'secondary') setImplEnv();
      const calls = setupSpawnCapture();
      await run();
      assert.ok(calls.length >= 1, 'the child must have been spawned');
      for (const call of calls) {
        const denied = deniedToolsFromArgv(call.args);
        assert.ok(denied, '--disallowedTools must be present on every impl spawn');
        assert.deepEqual(denied.values, EXPECTED_DENIED_TOOLS);
        assert.ok(typeof denied.next === 'string' && denied.next.startsWith('-'),
          'the variadic list must be terminated by an option, never by a positional');
        assert.ok(call.args.includes('--dangerously-skip-permissions'));
      }
    });
  }

  test('read-only forge queries stay allowed (QA and impl may read CI)', async () => {
    const calls = setupSpawnCapture();
    await runImplPrimary();
    const denied = deniedToolsFromArgv(calls[0].args);
    assert.ok(denied, '--disallowedTools must be present');
    const joined = denied.values.join('\n');
    for (const readOnly of ['gh pr view', 'gh pr checks', 'gh pr list', 'gh run', 'gh api']) {
      assert.ok(!joined.includes(readOnly), `${readOnly} must not be denied`);
    }
  });

  test('daemon-dispatch.sh applies the same list to the plan and QA invocations', () => {
    const src = readFileSync(DISPATCH_SRC_PATH, 'utf8');
    const m = src.match(/^GAAI_PHASE_DENIED_TOOLS=\(\n([\s\S]*?)\n\)$/m);
    assert.ok(m, 'GAAI_PHASE_DENIED_TOOLS array must exist in daemon-dispatch.sh');
    const shellList = m[1].split('\n').map(l => l.trim()).filter(Boolean)
      .map(l => l.replace(/^"|"$/g, ''));
    assert.deepEqual(shellList, EXPECTED_DENIED_TOOLS);
    const uses = src.match(/--disallowedTools "\$\{GAAI_PHASE_DENIED_TOOLS\[@\]\}"/g) || [];
    assert.equal(uses.length, 2, 'exactly the plan and QA invocations carry the list');
  });

});
