/**
 * nested-claude-spawn.js
 *
 * Single-file routing module for the Implementation phase of the GAAI Delivery Loop.
 * Serves as the SINGLE SOURCE OF TRUTH for all routing decisions (primary and secondary).
 *
 * Architecture (E131S02 — DEC-72, DEC-13, DEC-69):
 *   The routing decision is a deterministic function of (impl_model_tag, env state).
 *   Both primary and secondary execution paths go through subprocess isolation —
 *   the agent has no routing decision to interpret from a prompt.
 *
 * Resolution rules (DEC-72 five-row matrix):
 *   | impl_model_tag | env configured | mode      |
 *   |----------------|----------------|-----------|
 *   | 'primary'      | any            | primary   |  ← explicit opt-out
 *   | 'secondary'    | yes            | secondary |  ← explicit opt-in
 *   | 'secondary'    | no             | primary   |  ← warn + silent fallback
 *   | 'absent'/null  | yes            | secondary |  ← env-driven default (DEC-72)
 *   | 'absent'/null  | no             | primary   |  ← OSS non-regression (E94 D-0)
 *
 * Entry points:
 *   - runImpl(opts)          — new high-level API; deterministic routing + audit emit (E131S02+)
 *   - spawnNestedClaude(...) — legacy secondary-only API; preserved for backward compat (AC6)
 *
 * Observability: logPhase() from runtime-routing-logger is called internally by runImpl().
 *   The delivery agent no longer needs to emit phase:impl records from the workflow prompt.
 *
 * Obsolescence: Retire this file when Anthropic ships native multi-provider routing —
 *   tracked in github.com/anthropics/claude-code issue #38698.
 *
 * Community workaround: `CLAUDECODE=""` required to bypass parent-process env inheritance that
 *   blocks nested spawn — see anthropics/claude-code #28339, #25803, #28407.
 *
 * ToS caveat: secondary provider account ToS must permit programmatic API; parent OAuth Max Plan
 *   terms respected by process isolation.
 */

import { spawn as _childSpawn } from 'node:child_process';
import {
  existsSync, appendFileSync, mkdirSync,
  writeFileSync, readFileSync, readdirSync, unlinkSync,
} from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { logPhase, formatPhaseStdout } from './runtime-routing-logger.js';

const _NESTED_REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', '..');
const _FAIL_DEBUG_PATH  = join(_NESTED_REPO_ROOT, '.gaai', 'project', 'contexts', 'logs', 'nested-fail-debug.jsonl');
const _HANDLE_DIR_DEFAULT = join(_NESTED_REPO_ROOT, '.gaai', 'project', 'contexts', 'logs', 'runner-handles');

// ---------------------------------------------------------------------------
// Spawn injection seam (for tests only)
// ---------------------------------------------------------------------------

let _spawnFn = _childSpawn;

/** @internal — for tests only */
export function _setSpawnFn(fn) { _spawnFn = fn; }

/** @internal — for tests only */
export function _resetSpawnFn() { _spawnFn = _childSpawn; }

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const GLOBAL_TIMEOUT_MS    = 14_400_000; // 4 hours
const HEARTBEAT_TIMEOUT_MS =  1_800_000; // 30 minutes
const SIGKILL_GRACE_MS     =      5_000; // 5 seconds
// The turn ceiling is the operator's, not this file's. The daemon documents
// GAAI_MAX_TURNS as the primary safety net and already resolves it; this phase was
// the one place that ignored it and applied a constant instead, so a Story whose
// implementation genuinely needs more work stopped mid-edit at a number the
// operator could not see or change. A malformed or absent setting falls back to the
// previous constant rather than removing the ceiling.
const MAX_TURNS = (() => {
  const raw = process.env.GAAI_IMPL_MAX_TURNS || process.env.MAX_TURNS || '';
  const parsed = Number.parseInt(raw, 10);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : 150;
})();

// An expiring observation window is NOT proof the run ended. The child emits its
// terminal receipt as a stream-json `{"type":"result"}` event; until that receipt
// (or the child's own exit) is observed, the run is still in flight. Expiry
// therefore demotes the wrapper to poll mode against the retained handle instead
// of killing outright — see spawnCore()'s enterPollMode(). Killing on expiry alone
// reported successful long runs as failures, discarded the session_id that would
// have allowed correlation, and truncated the output to whatever had arrived.
const POLL_INTERVAL_MS     =     30_000; // handle probe cadence while in poll mode
const ACTIVITY_FLUSH_MS    =     10_000; // how often last_activity_at is persisted

/**
 * Poll budget once an observation window expires. Defaults to one extra heartbeat
 * window, which bounds the cost of the grace period at the same order as the window
 * that just expired. Setting the override to 0 restores kill-on-expiry.
 * @param {number} heartbeatTimeoutMs
 * @returns {number}
 */
function _pollBudgetMs(heartbeatTimeoutMs) {
  const raw = process.env.GAAI_RUNNER_POLL_BUDGET_MS;
  if (raw !== undefined && raw !== '') {
    const override = Number(raw);
    if (Number.isFinite(override) && override >= 0) return override;
  }
  return heartbeatTimeoutMs;
}

/** Directory holding one JSON handle record per in-flight runner process. */
function _handleDir() {
  return process.env.GAAI_RUNNER_HANDLE_DIR || _HANDLE_DIR_DEFAULT;
}

// ---------------------------------------------------------------------------
// JSDoc typedef for SpawnResult
// ---------------------------------------------------------------------------

/**
 * @typedef {Object} SpawnResult
 * @property {string}       trace_id          - UUID identifying this spawn execution
 * @property {boolean}      success           - true if the child exited 0 and produced the artefact
 * @property {number|null}  exit_code         - raw process exit code, or null if killed/missing
 * @property {string|null}  error_reason      - one of the classified error codes, or null on success
 * @property {string|null}  impl_report_path  - path to impl report file if it exists, else null
 * @property {string|null}  model_actual      - model string extracted from child stdout JSON, or null
 * @property {number}       duration_ms       - wall-clock ms from spawn to close
 * @property {string}       model_requested   - value of GAAI_IMPL_MODEL at spawn time
 * @property {boolean}      model_fallback_triggered - true iff model_actual !== model_requested
 * @property {string}       provider_base_url - value of GAAI_IMPL_BASE_URL at spawn time (no token)
 * @property {{ context_size_at_spawn?: number, compact_events_count?: number,
 *              retry_429_count?: number, nested_session_completed?: boolean }|null} telemetry
 *   Secondary-mode telemetry for capability-matrix decision baseline (E131S08).
 *   null for primary-path invocations or when collectTelemetry was not requested.
 *   context_size_at_spawn: absent if no assistant event with input_tokens was found.
 *   compact_events_count/retry_429_count/nested_session_completed: always present (may be 0/false).
 * @property {string|null}  session_id        - session_id announced by the child, or null if never observed
 * @property {boolean}      terminal_receipt  - true iff the child emitted its terminal stream-json `result` event
 * @property {boolean}      observation_window_expired - true iff an observation window expired and the run was
 *   polled against its retained handle rather than concluded on the spot
 */

// ---------------------------------------------------------------------------
// Private helper: findCLI
// ---------------------------------------------------------------------------

/**
 * Resolves the `claude` binary path by scanning PATH entries.
 * @returns {string|null} Absolute path to the claude binary, or null if not found.
 */
function findCLI() {
  const pathEnv = process.env.PATH || '';
  const dirs = pathEnv.split(process.platform === 'win32' ? ';' : ':');
  const candidates = process.platform === 'win32'
    ? ['claude.cmd', 'claude.exe']
    : ['claude'];

  for (const dir of dirs) {
    for (const name of candidates) {
      const full = join(dir, name);
      try {
        if (existsSync(full)) {
          return full;
        }
      } catch {
        // skip unreadable dirs
      }
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Private helper: buildChildEnv (secondary path — remaps GAAI_IMPL_* vars)
// ---------------------------------------------------------------------------

/**
 * Constructs the child process environment for the secondary subprocess path.
 * Maps GAAI_IMPL_* vars to Anthropic SDK vars, clears parent OAuth/key vars.
 * NEVER logs token values.
 * @returns {Record<string,string>} The environment object for the child.
 */
function buildChildEnv() {
  const env = { ...process.env };

  // Required: bypass nested Claude Code detection
  env.CLAUDECODE = '';

  // Claude CLI transport is independent from Impl provider routing. A daemon-scoped
  // proxy wins for ANTHROPIC_BASE_URL; otherwise the existing direct Impl provider
  // mapping is preserved for backward compatibility.
  if (env.GAAI_CLAUDE_PROXY_BASE_URL) {
    env.ANTHROPIC_BASE_URL = env.GAAI_CLAUDE_PROXY_BASE_URL;
  } else if (env.GAAI_IMPL_BASE_URL) {
    env.ANTHROPIC_BASE_URL = env.GAAI_IMPL_BASE_URL;
  }
  if (env.GAAI_IMPL_AUTH_TOKEN)    { env.ANTHROPIC_AUTH_TOKEN           = env.GAAI_IMPL_AUTH_TOKEN; }
  if (env.GAAI_IMPL_MODEL)         { env.ANTHROPIC_DEFAULT_OPUS_MODEL   = env.GAAI_IMPL_MODEL; }
  if (env.GAAI_IMPL_MODEL_FALLBACK){ env.ANTHROPIC_DEFAULT_SONNET_MODEL = env.GAAI_IMPL_MODEL_FALLBACK; }

  // Haiku-class model mapping for Task tool sub-agents spawned during impl.
  // Without this, Claude Code defaults to a Haiku model id that the secondary
  // provider may not recognise — silent failure or sub-agent stall. All Z.AI
  // guides (official docs + community wrappers) consistently recommend
  // glm-4.5-air for the Haiku tier. Operator can override via GAAI_IMPL_MODEL_HAIKU.
  if (env.GAAI_IMPL_MODEL_HAIKU) {
    env.ANTHROPIC_DEFAULT_HAIKU_MODEL = env.GAAI_IMPL_MODEL_HAIKU;
  } else if (!env.ANTHROPIC_DEFAULT_HAIKU_MODEL) {
    env.ANTHROPIC_DEFAULT_HAIKU_MODEL = 'glm-4.5-air';
  }

  // Apply Z.AI vendor-recommended Claude Code compat settings for GLM. Each
  // setting respects an operator override : if already set in the parent env,
  // we don't touch it. Sources :
  //   - API_TIMEOUT_MS=3000000 (50 min) : Z.AI docs — GLM responses slower
  //     than Anthropic's, default 10 min triggers premature timeouts.
  //   - CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 : matches GLM-class real ceiling.
  //     Claude Code's autocompact threshold is internally capped at ~83% of the
  //     configured window, so 200K yields a compact trigger around 167K, leaving
  //     33K of headroom before the model's hard limit. Earlier hack inflated to
  //     229K to push the trigger to ~190K, but empirical evidence (E135S02
  //     2026-05-05 — agent died at event 14 in "compacting" status) showed
  //     this leaves only 10K headroom — too tight, single long response or
  //     post-compact summary refill overflows. Reset to 200K (Z.AI vendor
  //     baseline) trades slightly earlier compact for structural safety.
  //     Operator override preserved.
  if (!env.API_TIMEOUT_MS) {
    env.API_TIMEOUT_MS = '3000000';
  }
  if (!env.CLAUDE_CODE_AUTO_COMPACT_WINDOW) {
    env.CLAUDE_CODE_AUTO_COMPACT_WINDOW = '200000';
  }

  // Claude Code proxy / gateway compat flags (we ARE a gateway here — Z.AI's
  // /api/anthropic shim translates between Anthropic API protocol and GLM).
  // Each flag is explicitly recommended by Anthropic's Claude Code docs for
  // gateway / non-first-party-provider scenarios. Operator override preserved.
  //
  //   - CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 : strips anthropic-beta
  //     headers and beta tool-schema fields that gateways reject with
  //     "Unexpected value(s) for the anthropic-beta header" errors.
  //   - DISABLE_INTERLEAVED_THINKING=1 : prevents the interleaved-thinking
  //     beta header from being sent. Gateways that don't support interleaved
  //     thinking typically error or silently strip the field, causing
  //     downstream parser divergence.
  //   - CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1 : disables the
  //     non-streaming fallback when a streaming request fails mid-stream.
  //     Gateways often cause the fallback to produce duplicate tool
  //     execution — better to propagate the streaming error to the retry
  //     layer than to double-execute.
  if (!env.CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS) {
    env.CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = '1';
  }
  if (!env.DISABLE_INTERLEAVED_THINKING) {
    env.DISABLE_INTERLEAVED_THINKING = '1';
  }
  if (!env.CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK) {
    env.CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK = '1';
  }

  // Remove parent auth credentials to prevent credential leakage / conflict
  delete env.CLAUDE_CODE_OAUTH_TOKEN;
  delete env.ANTHROPIC_API_KEY;
  delete env.CLAUDE_API_KEY;

  // Retired GAAI Cloud execution metadata must never reach the child process
  delete env.GAAI_WORKSPACE_ID;
  delete env.GAAI_ORG_ID;

  return env;
}

// ---------------------------------------------------------------------------
// Private helper: buildPrimaryChildEnv (primary path — keeps parent auth)
// ---------------------------------------------------------------------------

/**
 * Constructs the child process environment for the primary subprocess path.
 * Bypasses nested Claude Code detection but preserves parent auth credentials.
 * Does NOT remap GAAI_IMPL_* vars — the subprocess uses the operator's own account.
 * @returns {Record<string,string>} The environment object for the child.
 */
function buildPrimaryChildEnv() {
  const env = { ...process.env };

  // Required: bypass nested Claude Code detection
  env.CLAUDECODE = '';

  // Retired GAAI Cloud execution metadata must never reach the child process
  delete env.GAAI_WORKSPACE_ID;
  delete env.GAAI_ORG_ID;

  // When a daemon-scoped Claude proxy is configured, the primary subprocess must
  // also route through the proxy so there is no silent wrong-upstream routing.
  // In daemon mode this is idempotent (daemon already exports ANTHROPIC_BASE_URL
  // from GAAI_CLAUDE_PROXY_BASE_URL), but explicit forwarding here ensures correct
  // behavior when the module is invoked outside the daemon (tests, direct CLI).
  if (env.GAAI_CLAUDE_PROXY_BASE_URL) {
    env.ANTHROPIC_BASE_URL = env.GAAI_CLAUDE_PROXY_BASE_URL;
  }

  // Parent auth credentials (CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY, etc.) are kept
  // GAAI_IMPL_* vars are NOT remapped — subprocess uses operator's own Claude account

  return env;
}

// ---------------------------------------------------------------------------
// Private helper: buildSpawnArgs
// ---------------------------------------------------------------------------

/**
 * Builds the argv array for the claude child process.
 * @param {string}   prompt
 * @param {string[]} extraArgs
 * @param {string}   [model='opus']              - --model value passed to claude CLI
 * @param {boolean}  [includeFallbackModel=true] - include --fallback-model when GAAI_IMPL_MODEL_FALLBACK is set
 * @returns {string[]}
 */
function buildSpawnArgs(prompt, extraArgs, model = 'opus', includeFallbackModel = true) {
  // --strict-mcp-config: when ANTHROPIC_BASE_URL points to a non-Anthropic shim
  // (e.g. z.ai's /api/anthropic GLM compat layer), Claude Code's plugin/MCP
  // discovery payload at session init includes a `role:"system"` entry in
  // messages[] that OpenAI-style shims reject with HTTP 422 on the very first
  // call. --strict-mcp-config limits MCP discovery to the explicit --mcp-config
  // and avoids the rejected init payload. No-op when targeting anthropic.com.
  //
  // --strict-mcp-config is a function of transport only: any non-Anthropic
  // base URL injects it, unconditionally, with no opt-out. There is exactly
  // one provider-neutral contract here.
  // Check both ANTHROPIC_BASE_URL (already set in parent) and GAAI_CLAUDE_PROXY_BASE_URL
  // (set by operator, not yet propagated to ANTHROPIC_BASE_URL in parent process).
  // Without this fallback, --strict-mcp-config would not be injected when the operator
  // uses GAAI_CLAUDE_PROXY_BASE_URL alone and the parent process has no ANTHROPIC_BASE_URL.
  const _effectiveBaseUrl =
    process.env.ANTHROPIC_BASE_URL || process.env.GAAI_CLAUDE_PROXY_BASE_URL || '';
  const isNonAnthropicShim = Boolean(
    _effectiveBaseUrl && !_effectiveBaseUrl.includes('anthropic.com')
  );
  const injectStrictMcp = isNonAnthropicShim;
  return [
    '-p', prompt,
    '--no-session-persistence',
    '--dangerously-skip-permissions',  // nested child cannot answer permission prompts; would hang forever
    '--output-format', 'stream-json',
    '--verbose',
    '--model', model,
    '--max-turns', String(MAX_TURNS),
    ...(injectStrictMcp ? ['--strict-mcp-config'] : []),
    ...extraArgs,
    ...(includeFallbackModel && process.env.GAAI_IMPL_MODEL_FALLBACK ? ['--fallback-model', 'sonnet'] : []),
  ];
}

// ---------------------------------------------------------------------------
// Private helper: classifyError
// ---------------------------------------------------------------------------

/**
 * Classifies the failure reason from exit code, stderr, stdout and an optional preset reason.
 * Priority order is documented inline.
 * @param {number|null}  exitCode
 * @param {string}       stderr
 * @param {string}       stdout
 * @param {string|null}  presetReason  - TIMEOUT or HEARTBEAT_TIMEOUT if already determined
 * @param {string|null}  implReportPath
 * @returns {string} One of the error reason codes.
 */
function classifyError(exitCode, stderr, stdout, presetReason, implReportPath) {
  // 1. Preset reason (timer-triggered kill)
  if (presetReason) return presetReason;

  // 2. Auth failures
  if (/401|403|invalid_api_key|authentication/i.test(stderr)) return 'AUTH_FAILED';

  // 3. Network / endpoint failures
  if (/ECONNREFUSED|ENOTFOUND|ETIMEDOUT|network|dns/i.test(stderr)) return 'ENDPOINT_UNREACHABLE';

  // 4. Nested Claude Code detection bug
  if (/running inside Claude Code|cannot be launched inside another Claude Code session/i.test(stderr)) {
    return 'CLAUDECODE_BUG';
  }

  // 5. Exited 0 — primary success signal is impl_report file presence (ground truth).
  //    Completion markers in stdout are a heuristic fallback for cases where no
  //    implReportPath is provided (e.g., unit tests). In real delivery, what matters
  //    is that the child WROTE the artefact file, regardless of what it said in stdout.
  //    (Fix 2026-04-19 after E63S03 PARSE_ERROR'd despite 7KB impl-report.md being written.)
  if (exitCode === 0 && implReportPath) {
    if (existsSync(implReportPath)) {
      // File written — treat as success regardless of stdout markers.
      // Caller's `success` field is `exit_code === 0 && implReportPath && existsSync(implReportPath)`,
      // which remains satisfied here; no error_reason needed.
      return null; // success path
    }
    // File NOT written — real failure. Distinguish marker-absent (parser issue?)
    // from marker-present (agent described but didn't write).
    const hasCompletionMarker = stdout.includes('## QA') || stdout.includes('## Implementation') || stdout.includes('impl_report');
    if (!hasCompletionMarker) return 'PARSE_ERROR';
    return 'NO_ARTEFACT_PRODUCED';
  }

  // 5b. Exited 0 but NO implReportPath given (e.g., unit tests) — fall back to markers.
  if (exitCode === 0 && !implReportPath) {
    const hasCompletionMarker = stdout.includes('## QA') || stdout.includes('## Implementation') || stdout.includes('impl_report');
    if (!hasCompletionMarker) return 'PARSE_ERROR';
  }

  // 7. Non-zero exit
  if (exitCode !== 0) return 'EXIT_CODE_NON_ZERO';

  // Should not reach here (success path is handled before classifyError is called)
  return 'UNKNOWN';
}

// ---------------------------------------------------------------------------
// Private helper: extractModelActual
// ---------------------------------------------------------------------------

/**
 * Scans stdout for a JSON line containing a `model` field.
 * Claude Code `-p` output may include JSONL assistant messages.
 * @param {string} stdout
 * @returns {string|null}
 */
function extractModelActual(stdout) {
  for (const line of stdout.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    try {
      const obj = JSON.parse(trimmed);
      if (typeof obj.model === 'string') return obj.model;
    } catch {
      // not valid JSON, skip
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Private helper: collectSecondaryTelemetry (E131S08)
// ---------------------------------------------------------------------------

/**
 * Parses stream-json stdout to collect four secondary-mode telemetry fields.
 * Best-effort — fields that cannot be computed are omitted.
 *
 * Fields (secondary mode only — capability-matrix decision baseline):
 *   context_size_at_spawn   — input_tokens from the last assistant event (integer)
 *   compact_events_count    — count of system.subtype="compact_boundary" events (integer)
 *   retry_429_count         — count of system.subtype="api_retry" with error_status=429 (integer)
 *   nested_session_completed — true iff stop_reason ∈ {end_turn, stop_sequence} (boolean)
 *
 * All fields are integers or boolean — DEC-65 token-guard cannot trigger on them.
 *
 * @param {string} stdout - raw stream-json stdout from the nested claude -p invocation
 * @returns {{ fields: object, missing: string[] }}
 *   fields  — successfully-collected telemetry values
 *   missing — names of fields that could not be computed
 */
function collectSecondaryTelemetry(stdout) {
  const fields  = {};
  const missing = [];

  let lastInputTokens  = null;
  let compactCount     = 0;
  let retryCount       = 0;
  let sessionCompleted = false;

  try {
    for (const line of stdout.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed.startsWith('{')) continue;
      try {
        const obj = JSON.parse(trimmed);
        if (obj.type === 'assistant') {
          if (typeof obj.message?.usage?.input_tokens === 'number') {
            lastInputTokens = obj.message.usage.input_tokens;
          }
          const stop = obj.message?.stop_reason;
          if (stop === 'end_turn' || stop === 'stop_sequence') sessionCompleted = true;
        } else if (obj.type === 'system') {
          if (obj.subtype === 'compact_boundary') compactCount++;
          else if (obj.subtype === 'api_retry' && obj.error_status === 429) retryCount++;
        }
      } catch { /* skip unparseable line */ }
    }
  } catch (e) {
    // Outer-loop failure — all fields unavailable
    missing.push('context_size_at_spawn', 'compact_events_count', 'retry_429_count', 'nested_session_completed');
    return { fields, missing };
  }

  if (lastInputTokens !== null) {
    fields.context_size_at_spawn = lastInputTokens;
  } else {
    missing.push('context_size_at_spawn');
  }
  fields.compact_events_count     = compactCount;
  fields.retry_429_count          = retryCount;
  fields.nested_session_completed = sessionCompleted;

  return { fields, missing };
}

// ---------------------------------------------------------------------------
// Private helper: _makeLogFlusher
// ---------------------------------------------------------------------------

/**
 * Returns a line-oriented flusher that appends complete stdout lines to `logFile`.
 * Returns a no-op flusher when logFile is falsy.
 * @param {string} [logFile] - Path to append stream-json lines to.
 * @returns {{ flush(chunk: Buffer|string): void }}
 */
function _makeLogFlusher(logFile) {
  if (!logFile) return { flush() {} };
  let partial = '';
  let warnEmitted = false;
  return {
    flush(chunk) {
      const text = typeof chunk === 'string' ? chunk : chunk.toString('utf8');
      const combined = partial + text;
      const lines = combined.split('\n');
      partial = lines.pop(); // last element is incomplete (or '' if text ended with \n)
      if (lines.length === 0) return;
      const toWrite = lines.join('\n') + '\n';
      try {
        appendFileSync(logFile, toWrite, { encoding: 'utf8', flag: 'a' });
      } catch (e) {
        if (!warnEmitted) {
          process.stderr.write(`[nested-claude-spawn] WARNING: cannot append to log file ${logFile} (${e.code || e.message})\n`);
          warnEmitted = true;
        }
      }
    },
  };
}

// ---------------------------------------------------------------------------
// Private helpers: runner handle persistence + process-tree control
// ---------------------------------------------------------------------------

/**
 * Absolute path of the handle record for one spawn.
 * @param {string} traceId
 * @returns {string}
 */
function _handlePath(traceId) {
  return join(_handleDir(), `${traceId}.json`);
}

/**
 * Persists (or refreshes) the handle record for an in-flight run. Best-effort:
 * a failure to persist must never take down the run it describes.
 *
 * The record is what makes a run recoverable after the wrapper loses sight of it —
 * it is written as soon as the child exists, refreshed the moment the child's
 * session_id is known, and removed only once the run reaches a terminal state.
 * A record left behind therefore means "this run never concluded observably".
 *
 * @param {string} traceId
 * @param {object} record - Serialisable handle fields (merged over the identity fields).
 * @returns {string|null} Path written, or null when persistence failed.
 */
function _writeHandle(traceId, record) {
  const path = _handlePath(traceId);
  try {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, JSON.stringify({ trace_id: traceId, ...record }, null, 2) + '\n', 'utf8');
    return path;
  } catch (e) {
    process.stderr.write(`[nested-claude-spawn] WARNING: cannot persist handle ${path} (${e.code || e.message})\n`);
    return null;
  }
}

/**
 * Removes a handle record. Best-effort — an absent file is not an error.
 * @param {string} traceId
 */
function _clearHandle(traceId) {
  try { unlinkSync(_handlePath(traceId)); } catch { /* already gone */ }
}

/**
 * Liveness probe for a pid. Signal 0 performs permission + existence checks
 * without delivering a signal.
 * @param {number} pid
 * @returns {boolean}
 */
function _isAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; }
  catch (e) { return e.code === 'EPERM'; }
}

/**
 * Signals the child AND its descendants.
 *
 * A delivery phase spawns a heavy subprocess tree (test runners, build servers,
 * whatever the project's commands invoke). Signalling the child pid alone leaves
 * every descendant orphaned, which is how long-lived workers accumulate on the
 * host across timeouts and retries. The child is spawned into its own process
 * group so a negative-pid signal reaches the whole tree; the direct signal stays
 * as the fallback for platforms without process groups and for injected test doubles.
 *
 * @param {import('node:child_process').ChildProcess} child
 * @param {NodeJS.Signals} signal
 */
function _killTree(child, signal) {
  const pid = child.pid;
  if (process.platform !== 'win32' && Number.isInteger(pid) && pid > 0) {
    try { process.kill(-pid, signal); return; }
    catch { /* no process group (or already reaped) — fall through */ }
  }
  try { child.kill(signal); } catch { /* already dead */ }
}

/**
 * Extracts the two stream-json facts the wrapper must not lose: the session_id
 * announced at init, and the terminal `result` receipt that ends the run.
 * Tolerant by design — non-JSON and partial lines are skipped, never thrown on.
 *
 * @param {string} text - One or more complete stdout lines.
 * @param {{ sessionId: string|null, terminalReceipt: object|null }} state - Mutated in place.
 */
function _scanStreamEvents(text, state) {
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    let obj;
    try { obj = JSON.parse(trimmed); } catch { continue; }
    if (!state.sessionId && typeof obj.session_id === 'string' && obj.session_id) {
      state.sessionId = obj.session_id;
    }
    if (obj.type === 'result') state.terminalReceipt = obj;
  }
}

/**
 * Age past which a handle is disbelieved regardless of pid liveness. No legitimate
 * run outlives its own ceiling plus a grace window, so beyond this the pid is far
 * more likely to have been recycled than to still belong to the recorded run.
 */
function _handleMaxAgeMs() {
  const raw = process.env.GAAI_RUNNER_HANDLE_MAX_AGE_MS;
  if (raw !== undefined && raw !== '') {
    const override = Number(raw);
    if (Number.isFinite(override) && override > 0) return override;
  }
  return GLOBAL_TIMEOUT_MS + HEARTBEAT_TIMEOUT_MS;
}

/**
 * Reconciles persisted handles against the processes actually running.
 *
 * Recovery re-launches a phase from its recorded state; without this check it
 * cannot tell "the previous runner died" from "the previous runner is still
 * working", and re-launching in the second case spawns a duplicate against the
 * same worktree. Call this before deciding to re-launch.
 *
 * @param {{ reap?: boolean }} [opts]
 *   reap — SIGKILL the process group of handles still alive (default false: report only).
 * @returns {{ live: object[], stale: object[], expired: object[], unreadable: string[] }}
 *   live       — handle records whose pid is still running and whose age is plausible
 *   stale      — handle records whose pid is gone (their files are removed)
 *   expired    — records too old to be believed, pid notwithstanding (files removed,
 *                processes left strictly alone — see below)
 *   unreadable — paths that could not be parsed (left in place for inspection)
 */
export function reconcileHandles({ reap = false } = {}) {
  const dir = _handleDir();
  const out = { live: [], stale: [], expired: [], unreadable: [] };
  const maxAgeMs = _handleMaxAgeMs();
  const now = Date.now();
  let entries;
  try { entries = readdirSync(dir); } catch { return out; }

  for (const name of entries) {
    if (!name.endsWith('.json')) continue;
    const path = join(dir, name);
    let record;
    try { record = JSON.parse(readFileSync(path, 'utf8')); }
    catch { out.unreadable.push(path); continue; }

    // A handle written by an older build may still carry retired GAAI Cloud
    // execution metadata; never surface it from reconciliation.
    delete record.workspace_id;
    delete record.org_id;

    if (!_isAlive(record.pid)) {
      out.stale.push(record);
      try { unlinkSync(path); } catch { /* already gone */ }
      continue;
    }

    // A SIGKILLed wrapper never clears its handle, so the record outlives the run.
    // Once the OS recycles that pid, a liveness probe alone reports it live forever
    // and recovery refuses to relaunch the story for good. Age breaks that deadlock.
    // Crucially the process is NOT signalled here: on this branch the pid most
    // likely belongs to something unrelated, and killing it would be the real damage.
    const startedAt = Date.parse(record.started_at ?? '');
    if (Number.isFinite(startedAt) && (now - startedAt) > maxAgeMs) {
      out.expired.push(record);
      try { unlinkSync(path); } catch { /* already gone */ }
      continue;
    }

    out.live.push(record);
    if (reap) {
      if (process.platform !== 'win32') {
        try { process.kill(-record.pid, 'SIGKILL'); } catch { /* no group */ }
      }
      try { process.kill(record.pid, 'SIGKILL'); } catch { /* already gone */ }
      try { unlinkSync(path); } catch { /* already gone */ }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Core spawn logic (shared between all public exports)
// ---------------------------------------------------------------------------

/**
 * Core implementation: spawns a nested claude process with configurable env, model, and timeouts.
 * @param {string}   prompt
 * @param {string}   implReportPath
 * @param {string[]} extraArgs
 * @param {number}   globalTimeoutMs
 * @param {number}   heartbeatTimeoutMs
 * @param {string}   logFile
 * @param {Function} [envFn=buildChildEnv]          - returns the child process env object
 * @param {string}   [model='opus']                 - --model value passed to claude CLI
 * @param {boolean}  [includeFallbackModel=true]    - include --fallback-model when GAAI_IMPL_MODEL_FALLBACK is set
 * @param {boolean}  [collectTelemetry=false]       - parse stdout for secondary-mode telemetry fields (E131S08)
 * @param {string}   [cwd='']                       - cwd for child process (worktree path); empty = inherit parent cwd
 * @returns {Promise<SpawnResult>}
 */
function spawnCore(prompt, implReportPath, extraArgs, globalTimeoutMs, heartbeatTimeoutMs, logFile,
                   envFn = buildChildEnv, model = 'opus', includeFallbackModel = true, collectTelemetry = false,
                   cwd = '', context = {}) {
  const traceId   = randomUUID();
  const startMs   = Date.now();
  const modelReq  = process.env.GAAI_IMPL_MODEL   || '';
  const baseUrl   = process.env.GAAI_IMPL_BASE_URL || '';

  // What this run belongs to. A handle that cannot name its own story forces
  // consumers to infer identity from the worktree path, which is a string-shape
  // guess rather than a fact. Explicit context wins; the daemon exports the same
  // story id into the child env, which covers callers that pass nothing.
  const identity = {
    story_id: context.storyId || process.env.GAAI_STORY_ID || null,
    phase:    context.phase   || 'impl',
  };

  // Log spawn start — never log token values
  console.log(`[nested-claude-spawn] spawn trace_id=${traceId} model=${modelReq} url=${baseUrl}`);

  return new Promise((resolve) => {
    // Resolve claude binary
    const claudePath = findCLI();
    if (!claudePath) {
      const duration = Date.now() - startMs;
      console.log(`[nested-claude-spawn] CLAUDECODE_BUG: claude binary not found trace_id=${traceId}`);
      resolve({
        trace_id:         traceId,
        success:          false,
        exit_code:        null,
        error_reason:     'CLAUDECODE_BUG',
        impl_report_path: null,
        model_actual:     null,
        duration_ms:      duration,
        model_requested:  modelReq,
        model_fallback_triggered: false,
        provider_base_url:       baseUrl,
        telemetry:               null,
        session_id:              null,
        terminal_receipt:        false,
        observation_window_expired: false,
      });
      return;
    }

    const args  = buildSpawnArgs(prompt, extraArgs, model, includeFallbackModel);
    const env   = envFn();
    const spawnOpts = { env, shell: false, stdio: ['ignore', 'pipe', 'pipe'] };
    if (cwd) spawnOpts.cwd = cwd;
    // Own process group so descendants can be signalled as a tree (see _killTree).
    // Never unref'd — the parent keeps the pipes and stays attached for the receipt.
    if (process.platform !== 'win32') spawnOpts.detached = true;
    const child = _spawnFn(claudePath, args, spawnOpts);

    const stdoutChunks = [];
    const stderrChunks = [];
    let presetReason   = null;
    let killed         = false;

    let globalTimer    = null;
    let heartbeatTimer = null;
    let pollTimer      = null;
    let pollDeadline   = 0;
    let pollReason     = null;
    let inPollMode     = false;
    let everPolled     = false;
    // The global window is a hard ceiling, so it is held as an absolute instant
    // rather than as a one-shot timer. A timer alone was defeated two ways: it
    // fires once, so firing while a heartbeat poll was already running was
    // swallowed by enterPollMode's guard, and any later stdout byte left poll mode
    // and re-armed only the heartbeat. Either way nothing bounded the run again.
    const globalDeadline = startMs + globalTimeoutMs;
    const logFlusher   = _makeLogFlusher(logFile);
    const streamState  = { sessionId: null, terminalReceipt: null };
    const pollBudgetMs = _pollBudgetMs(heartbeatTimeoutMs);
    let scanBuffer     = '';
    let lastActivityAt = startMs;
    let activityFlushAt = 0;

    // Command identity, deliberately narrow: the resolved binary and the model.
    // The argv is never recorded — it carries the prompt, and a handle file is
    // not a place to put prompt content.
    const command = { bin: basename(claudePath), model };

    // Handle record — written before any window can expire, so a run is never
    // unrecoverable, and refreshed as soon as the session_id is announced.
    _writeHandle(traceId, {
      ...identity,
      command,
      pid:         child.pid ?? null,
      session_id:  null,
      state:       'running',
      started_at:  new Date(startMs).toISOString(),
      last_activity_at: new Date(startMs).toISOString(),
      log_file:    logFile || null,
      report_path: implReportPath || null,
      cwd:         cwd || null,
    });

    function refreshHandle(state, extra = {}) {
      _writeHandle(traceId, {
        ...identity,
        command,
        last_activity_at: new Date(lastActivityAt).toISOString(),
        pid:         child.pid ?? null,
        session_id:  streamState.sessionId,
        state,
        started_at:  new Date(startMs).toISOString(),
        log_file:    logFile || null,
        report_path: implReportPath || null,
        cwd:         cwd || null,
        ...extra,
      });
    }

    // Wrapper death must not strand the tree it spawned. The child now has its own
    // process group, so it no longer dies with us by default. 'exit' covers the
    // orderly path; the signal handlers cover the one the daemon actually uses, and
    // they re-raise so the wrapper's own exit status keeps its usual meaning.
    const onParentExit = () => _killTree(child, 'SIGKILL');
    const onParentSignal = (sig) => {
      _killTree(child, 'SIGKILL');
      process.removeListener('SIGTERM', onParentSignal);
      process.removeListener('SIGINT',  onParentSignal);
      process.kill(process.pid, sig);
    };
    process.once('exit', onParentExit);
    process.once('SIGTERM', onParentSignal);
    process.once('SIGINT',  onParentSignal);

    function clearTimers() {
      if (globalTimer)    { clearTimeout(globalTimer);    globalTimer    = null; }
      if (heartbeatTimer) { clearTimeout(heartbeatTimer); heartbeatTimer = null; }
      if (pollTimer)      { clearTimeout(pollTimer);      pollTimer      = null; }
    }

    function killChild(reason) {
      if (killed) return;
      killed       = true;
      presetReason = reason;
      console.log(`[nested-claude-spawn] killing child tree reason=${reason} trace_id=${traceId} session_id=${streamState.sessionId ?? 'unknown'}`);
      refreshHandle('killed', { kill_reason: reason });
      _killTree(child, 'SIGTERM');
      setTimeout(() => _killTree(child, 'SIGKILL'), SIGKILL_GRACE_MS);
    }

    /**
     * An observation window expired. The run is not concluded by that fact alone,
     * so retain the handle and probe it until a terminal receipt, the child's own
     * exit, or the poll budget running out — only the last of which is a kill.
     */
    function enterPollMode(reason) {
      if (killed) return;
      if (pollBudgetMs <= 0) { killChild(reason); return; }

      // Already polling: nothing to do. The active poll already carries a bounded
      // deadline, and exitPollMode() refuses to leave poll mode past the ceiling,
      // so the run stays bounded whichever window opened it.
      if (inPollMode) return;

      inPollMode   = true;
      everPolled   = true;
      pollReason   = reason;
      // Grace never extends past the ceiling plus one budget — that sum is the
      // absolute end of the run.
      pollDeadline = Math.min(Date.now() + pollBudgetMs, globalDeadline + pollBudgetMs);
      console.log(`[nested-claude-spawn] observation window expired reason=${reason} trace_id=${traceId} session_id=${streamState.sessionId ?? 'unknown'} — polling handle for terminal receipt (budget_ms=${pollBudgetMs})`);
      refreshHandle('polling', { poll_reason: reason });
      schedulePoll();
    }

    function schedulePoll() {
      const remaining = pollDeadline - Date.now();
      if (pollTimer) clearTimeout(pollTimer);
      pollTimer = setTimeout(pollOnce, Math.max(1, Math.min(POLL_INTERVAL_MS, remaining)));
    }

    function pollOnce() {
      if (killed || !inPollMode) return;

      // Still inside the budget: keep the handle and keep waiting. A child that
      // exits on its own fires 'close', which clears these timers.
      if (Date.now() < pollDeadline) { schedulePoll(); return; }

      // Budget spent. 'close' only fires once every holder of the child's stdout
      // is gone, so a lingering descendant can keep it pending indefinitely — the
      // budget is what stops that from becoming an unbounded wait.
      if (streamState.terminalReceipt) {
        console.log(`[nested-claude-spawn] terminal receipt in hand, tree still holding stdout — reaping trace_id=${traceId} session_id=${streamState.sessionId ?? 'unknown'}`);
      } else {
        console.log(`[nested-claude-spawn] no terminal receipt within poll budget trace_id=${traceId} session_id=${streamState.sessionId ?? 'unknown'}`);
      }
      killChild(pollReason);
    }

    function exitPollMode() {
      if (!inPollMode) return;
      // Past the hard ceiling, resumed output no longer buys time. Without this a
      // child chatty enough to stay under the heartbeat could run unbounded.
      if (Date.now() >= globalDeadline) return;
      inPollMode = false;
      if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
      console.log(`[nested-claude-spawn] output resumed — leaving poll mode trace_id=${traceId}`);
      refreshHandle('running');
    }

    function resetHeartbeat() {
      if (heartbeatTimer) { clearTimeout(heartbeatTimer); }
      heartbeatTimer = setTimeout(() => enterPollMode('HEARTBEAT_TIMEOUT'), heartbeatTimeoutMs);
    }

    // Start timers. The global window goes through poll mode too, so a run that is
    // genuinely finishing is not cut off at the line — but globalDeadline, not this
    // timer, is what enforces the ceiling.
    globalTimer    = setTimeout(() => enterPollMode('TIMEOUT'), globalTimeoutMs);
    resetHeartbeat();

    child.stdout.on('data', (chunk) => {
      logFlusher.flush(chunk);
      stdoutChunks.push(chunk);
      // Scan complete lines only — a chunk boundary can land mid-JSON, and a
      // session_id split across two chunks is exactly the identifier we must not lose.
      scanBuffer += typeof chunk === 'string' ? chunk : chunk.toString('utf8');
      const lastNewline = scanBuffer.lastIndexOf('\n');
      if (lastNewline >= 0) {
        const hadSession = streamState.sessionId;
        _scanStreamEvents(scanBuffer.slice(0, lastNewline + 1), streamState);
        scanBuffer = scanBuffer.slice(lastNewline + 1);
        if (!hadSession && streamState.sessionId) refreshHandle(inPollMode ? 'polling' : 'running');
      }
      // Liveness as an observed fact, not an inference from the file's mtime.
      // Flushed on an interval rather than per chunk: a chatty run emits far too
      // often to justify a write each time, and consumers only need the field
      // accurate to the order of the windows they compare it against.
      lastActivityAt = Date.now();
      if (lastActivityAt - activityFlushAt >= ACTIVITY_FLUSH_MS) {
        activityFlushAt = lastActivityAt;
        refreshHandle(inPollMode ? 'polling' : 'running');
      }
      exitPollMode();
      resetHeartbeat();
    });

    child.stderr.on('data', (chunk) => {
      stderrChunks.push(chunk);
    });

    child.on('close', (code) => {
      clearTimers();
      inPollMode = false;
      process.removeListener('exit',    onParentExit);
      process.removeListener('SIGTERM', onParentSignal);
      process.removeListener('SIGINT',  onParentSignal);
      _clearHandle(traceId);

      const stdout     = Buffer.concat(stdoutChunks).toString('utf8');
      const stderr     = Buffer.concat(stderrChunks).toString('utf8');
      const duration   = Date.now() - startMs;
      const modelActual = extractModelActual(stdout);

      // Final authoritative scan over the whole stream — the incremental scan is
      // an optimisation for the live path, this is what the outcome is decided on.
      _scanStreamEvents(stdout, streamState);
      const receipt   = streamState.terminalReceipt;
      const receiptOk = !!receipt && receipt.is_error !== true;

      // Determine completion marker presence
      const hasCompletionMarker = stdout.includes('## QA') || stdout.includes('## Implementation') || stdout.includes('impl_report');
      const reportExists = implReportPath ? existsSync(implReportPath) : false;

      // Success primary signal is artefact file existence (ground truth) when implReportPath
      // is given — the child's responsibility is to WRITE the file, not to emit stdout markers.
      // When no implReportPath is given (e.g., unit tests), fall back to completion markers.
      // (Updated 2026-04-19 after E63S03 PARSE_ERROR'd despite 7KB impl-report.md being written.)
      //
      // A clean terminal receipt counts alongside exit 0: when the wrapper had to
      // stop watching and later signalled the tree, the exit code reports our kill,
      // not the run. Receipt plus artefact means the work landed — grading that as
      // a failure is the defect this path exists to prevent.
      const success = (code === 0 || receiptOk) && (implReportPath
        ? reportExists
        : hasCompletionMarker);

      let errorReason = null;
      if (!success) {
        errorReason = classifyError(code, stderr, stdout, presetReason, implReportPath);
      }

      // Forensic dump on EXIT_CODE_NON_ZERO catch-all — stderr/stdout aren't
      // otherwise persisted. Without this, diagnosing why GLM (or any secondary
      // provider) crashed requires re-running. File is gitignored (.gaai/project/contexts/logs/).
      if (errorReason === 'EXIT_CODE_NON_ZERO') {
        try {
          mkdirSync(dirname(_FAIL_DEBUG_PATH), { recursive: true });
          appendFileSync(_FAIL_DEBUG_PATH, JSON.stringify({
            ts: new Date().toISOString(),
            trace_id: traceId,
            exit_code: code,
            duration_ms: duration,
            model_requested: modelReq,
            model_actual: modelActual,
            base_url: baseUrl,
            stderr_tail: stderr.slice(-4000),
            stdout_tail: stdout.slice(-4000),
          }) + '\n', 'utf8');
        } catch (e) {
          process.stderr.write(`[nested-claude-spawn] WARNING: fail-debug dump failed: ${e.message}\n`);
        }
      }

      const modelFallbackTriggered = !!(modelActual && modelActual !== modelReq);

      // Collect secondary-mode telemetry when requested (primary path: no-op, AC5)
      let telemetry = null;
      if (collectTelemetry) {
        const { fields, missing } = collectSecondaryTelemetry(stdout);
        for (const fieldName of missing) {
          process.stderr.write(`[nested-claude-spawn] WARNING: telemetry field ${fieldName} unavailable: no matching event in stream-json\n`);
        }
        telemetry = fields;
      }

      console.log(`[nested-claude-spawn] done trace_id=${traceId} session_id=${streamState.sessionId ?? 'unknown'} success=${success} reason=${errorReason} terminal_receipt=${!!receipt} polled=${everPolled} duration_ms=${duration}`);

      resolve({
        trace_id:         traceId,
        success,
        exit_code:        code,
        error_reason:     errorReason,
        impl_report_path: (success && implReportPath) ? implReportPath : null,
        model_actual:     modelActual,
        duration_ms:      duration,
        model_requested:  modelReq,
        model_fallback_triggered: modelFallbackTriggered,
        provider_base_url:       baseUrl,
        telemetry,
        session_id:              streamState.sessionId,
        terminal_receipt:        !!receipt,
        observation_window_expired: everPolled,
      });
    });
  });
}

// ---------------------------------------------------------------------------
// @internal resolveMode — pure routing decision helper (AC10, DEC-72)
// ---------------------------------------------------------------------------

/**
 * Determines the Implementation phase routing mode from the story tag and env state.
 * Pure function — no I/O, no env mutation, no side effects. Exported for E131S03 tests.
 *
 * Implements the DEC-72 five-row decision matrix deterministically.
 * The 'absent' sentinel string and null are treated identically (no backlog tag supplied).
 *
 * @internal — exported for E131S03 unit tests only; production callers use runImpl().
 *
 * @param {'primary'|'secondary'|'absent'|null|undefined} implModelTag
 *   Value of the story's impl_model field. Use 'absent' or null/undefined when no tag exists.
 * @param {{ hasBaseUrl: boolean, hasAuthToken: boolean, hasModel: boolean }} envState
 *   Snapshot of the three required GAAI_IMPL_* env vars (no direct process.env access).
 * @returns {{ mode: 'primary'|'secondary', tag_recorded: 'primary'|'secondary'|'absent' }}
 *   mode        — which subprocess path to use
 *   tag_recorded — the impl_model_tag value written to the audit log record
 */
export function resolveMode(implModelTag, envState) {
  const tag = implModelTag ?? null;
  // Normalize: 'absent' sentinel and null both mean "no tag supplied"
  const normalized = (tag === 'absent' || tag === null) ? null : tag;
  const tag_recorded = normalized === null ? 'absent' : normalized;
  const envConfigured = envState.hasBaseUrl && envState.hasAuthToken && envState.hasModel;

  // Row 1: explicit opt-out — always primary regardless of env
  if (normalized === 'primary') {
    return { mode: 'primary', tag_recorded: 'primary' };
  }

  // Row 2: explicit opt-in to secondary + env configured → secondary.
  // Secondary route is OPT-IN at the story level (`impl_model: secondary` in
  // the backlog item) rather than env-driven default. Rationale: third-party
  // Anthropic-compat shims observed empirically not to honor cache_control nor
  // return cache_read_input_tokens in usage, causing the client-side context
  // tracker to saturate at the declared window threshold and trigger
  // rapid_refill_breaker on cross-cutting stories regardless of prompt size.
  // Universal fallback (AC3) cascades to primary on secondary failure but
  // creates double-burn vs direct primary route. Stories that opt-in to
  // secondary explicitly accept the rapid_refill risk and the cascade cost.
  if (normalized === 'secondary' && envConfigured) {
    return { mode: 'secondary', tag_recorded };
  }

  // Row 3: explicit secondary but env missing → primary (caller emits warn)
  if (normalized === 'secondary' && !envConfigured) {
    return { mode: 'primary', tag_recorded };
  }

  // Row 4 (DEFAULT, env configured): no tag + secondary env configured → secondary.
  // Default routing reflects the project routing decision currently in force.
  // Rationale : when context-engineering at the prompt layer (e.g., compact-window
  // headroom, directive wording internalized by the model) mitigates the
  // rapid_refill_breaker risk on the secondary path, the cost-reliability balance
  // favors secondary as default — typically ~70% cost reduction vs primary while
  // remaining reliable enough for routine work. Universal fallback (AC3) absorbs
  // failures by cascading to primary. Stories that require primary opt-out via
  // explicit `impl_model: primary`.
  if (normalized === null && envConfigured) {
    return { mode: 'secondary', tag_recorded };
  }

  // Row 5 (DEFAULT, env missing): no tag + env not configured → primary.
  // Cannot route to secondary without GAAI_IMPL_BASE_URL / AUTH_TOKEN / MODEL.
  return { mode: 'primary', tag_recorded };
}

// ---------------------------------------------------------------------------
// Private helper: _emitLog — wraps logPhase with best-effort error handling (AC5)
// ---------------------------------------------------------------------------

/**
 * Calls logPhase() and catches any synchronous exception (token guard, missing field, I/O).
 * Writes a WARNING to stderr on failure. Never propagates the exception to the caller.
 * @param {object|null} [telemetry=null] - secondary-mode telemetry fields to spread into the log record (AC1/AC2)
 * @returns {boolean} true if the emit failed, false on success.
 */
function _emitLog({ traceId, storyId, provider, modelActual, durationMs, fallbackReason, tagRecorded, telemetry = null }) {
  try {
    logPhase({
      trace_id:        traceId,
      story_id:        storyId,
      phase:           'impl',
      provider,
      model:           modelActual ?? '',
      duration_ms:     durationMs,
      fallback_reason: fallbackReason,
      impl_model_tag:  tagRecorded,
      ...(telemetry !== null ? telemetry : {}),
    });
    return false;
  } catch (e) {
    process.stderr.write(`[nested-claude-spawn] WARNING: routing log emit failed: ${e.message}\n`);
    return true;
  }
}

// ---------------------------------------------------------------------------
// Public export: runImpl — deterministic routing + audit emit (E131S02+)
// ---------------------------------------------------------------------------

/**
 * Runs the Implementation phase with deterministic routing.
 *
 * Single entry point for both primary and secondary subprocess paths. The routing
 * decision is resolved by resolveMode() — a pure function — so identical inputs
 * always produce identical routing outcomes regardless of agent prompt interpretation.
 *
 * Emits exactly one `phase: impl` record on success; two records when secondary
 * fails and primary fallback is invoked (per DEC-72 atomic-binary fallback). Never throws.
 *
 * Constraining DECs: DEC-72 (routing matrix), DEC-13 (client-side execution),
 *   DEC-69 (deterministic hard gate), DEC-65 (token guard in logPhase).
 *
 * @param {{
 *   implModelTag: 'primary'|'secondary'|'absent'|null|undefined,
 *   prompt:       string,
 *   reportPath:   string,
 *   storyId:      string,
 *   extraArgs?:   string[],
 *   logFile?:     string,
 * }} opts
 * @returns {Promise<SpawnResult & { log_emit_failed: boolean }>}
 *   log_emit_failed — true if any routing log emit threw (best-effort; never a spawn failure)
 */
/**
 * --model value for the primary Impl route.
 *
 * The Delivery router owns model choice per role and hands its pick down as
 * GAAI_IMPL_PRIMARY_MODEL. Absent that — routing disabled, blocked, or a direct
 * caller — this keeps the historical default so behaviour is unchanged.
 * @returns {string}
 */
function primaryModel() {
  return process.env.GAAI_IMPL_PRIMARY_MODEL?.trim() || 'sonnet';
}

export async function runImpl({ implModelTag, prompt, reportPath, storyId, extraArgs = [], logFile = '', worktreePath = '' }) {
  const envState = {
    hasBaseUrl:   !!(process.env.GAAI_IMPL_BASE_URL?.trim()),
    hasAuthToken: !!(process.env.GAAI_IMPL_AUTH_TOKEN?.trim()),
    hasModel:     !!(process.env.GAAI_IMPL_MODEL?.trim()),
  };

  const { mode, tag_recorded } = resolveMode(implModelTag, envState);

  // Warn when caller explicitly opted in to secondary but env is missing
  if (implModelTag === 'secondary' && mode === 'primary') {
    console.warn(
      'IMPL_ROUTING_ENV_MISSING: expected GAAI_IMPL_BASE_URL|GAAI_IMPL_AUTH_TOKEN|GAAI_IMPL_MODEL; ' +
      'falling back to primary.'
    );
    process.stdout.write('⚠ impl_model=secondary but GAAI_IMPL_* env vars missing; using primary.\n');
  }

  if (mode === 'secondary') {
    // Secondary path: spawn with secondary env (GAAI_IMPL_* remapped to Anthropic SDK vars)
    const result = await spawnCore(
      prompt, reportPath, extraArgs,
      GLOBAL_TIMEOUT_MS, HEARTBEAT_TIMEOUT_MS, logFile,
      buildChildEnv, 'opus', /* includeFallbackModel */ true, /* collectTelemetry */ true,
      worktreePath, { storyId }
    );

    const logFailed = _emitLog({
      traceId:        result.trace_id,
      storyId,
      provider:       'secondary',
      modelActual:    result.model_actual ?? (process.env.GAAI_IMPL_MODEL || ''),
      durationMs:     result.duration_ms,
      fallbackReason: null,
      tagRecorded:    tag_recorded,
      telemetry:      result.telemetry,
    });

    if (!result.success) {
      // Universal fallback to primary — exactly one retry, no recursion (AC3)
      const fallbackReason = result.error_reason;
      process.stdout.write(
        formatPhaseStdout('impl', 'secondary',
          result.model_actual ?? (process.env.GAAI_IMPL_MODEL || ''), fallbackReason)
      );

      const primaryResult = await spawnCore(
        prompt, reportPath, extraArgs,
        GLOBAL_TIMEOUT_MS, HEARTBEAT_TIMEOUT_MS, logFile,
        buildPrimaryChildEnv, primaryModel(), /* includeFallbackModel */ false,
        /* collectTelemetry */ false, worktreePath, { storyId }
      );

      const primaryLogFailed = _emitLog({
        traceId:        result.trace_id,  // shared trace_id across both attempt log lines
        storyId,
        provider:       'primary',
        modelActual:    primaryResult.model_actual ?? 'sonnet',
        durationMs:     primaryResult.duration_ms,
        fallbackReason,
        tagRecorded:    tag_recorded,
      });

      process.stdout.write(
        formatPhaseStdout('impl', 'primary', primaryResult.model_actual ?? 'sonnet', null)
      );

      return { ...primaryResult, log_emit_failed: logFailed || primaryLogFailed };
    }

    // Secondary success
    process.stdout.write(
      formatPhaseStdout('impl', 'secondary',
        result.model_actual ?? (process.env.GAAI_IMPL_MODEL || ''), null)
    );
    return { ...result, log_emit_failed: logFailed };
  }

  // Primary path: explicit opt-out or env missing — no fallback attempted (AC4)
  const result = await spawnCore(
    prompt, reportPath, extraArgs,
    GLOBAL_TIMEOUT_MS, HEARTBEAT_TIMEOUT_MS, logFile,
    buildPrimaryChildEnv, primaryModel(), /* includeFallbackModel */ false,
    /* collectTelemetry */ false, worktreePath, { storyId }
  );

  const logFailed = _emitLog({
    traceId:        result.trace_id,
    storyId,
    provider:       'primary',
    modelActual:    result.model_actual ?? 'sonnet',
    durationMs:     result.duration_ms,
    fallbackReason: null,
    tagRecorded:    tag_recorded,
  });

  process.stdout.write(
    formatPhaseStdout('impl', 'primary', result.model_actual ?? 'sonnet', null)
  );

  return { ...result, log_emit_failed: logFailed };
}

// ---------------------------------------------------------------------------
// Public export: spawnNestedClaude (legacy secondary-only API — preserved AC6)
// ---------------------------------------------------------------------------

/**
 * Spawns a nested `claude -p` process using the secondary provider env vars.
 * Returns a SpawnResult — never throws.
 *
 * @deprecated Use runImpl() for new callers. This function is preserved for
 *   backward compatibility (AC6/AC7) — it supports the secondary path only.
 *
 * @param {string}   prompt          - The prompt to pass to `claude -p`
 * @param {string}   implReportPath  - Expected path to the impl-report artefact
 * @param {string[]} [extraArgs=[]]  - Additional argv to append
 * @returns {Promise<SpawnResult>}
 */
export async function spawnNestedClaude(prompt, implReportPath, extraArgs = [], logFile = '', worktreePath = '') {
  // Guard: required env vars
  const missing = [];
  if (!process.env.GAAI_IMPL_BASE_URL)   missing.push('GAAI_IMPL_BASE_URL');
  if (!process.env.GAAI_IMPL_AUTH_TOKEN) missing.push('GAAI_IMPL_AUTH_TOKEN');
  if (!process.env.GAAI_IMPL_MODEL)      missing.push('GAAI_IMPL_MODEL');

  if (missing.length > 0) {
    const traceId = randomUUID();
    console.log(`[nested-claude-spawn] ENV_MISSING vars=${missing.join(',')} trace_id=${traceId}`);
    return {
      trace_id:         traceId,
      success:          false,
      exit_code:        null,
      error_reason:     'ENV_MISSING',
      impl_report_path: null,
      model_actual:     null,
      duration_ms:      0,
      model_requested:  process.env.GAAI_IMPL_MODEL   || '',
      model_fallback_triggered: false,
      provider_base_url:       process.env.GAAI_IMPL_BASE_URL || '',
      session_id:              null,
      terminal_receipt:        false,
      observation_window_expired: false,
    };
  }

  return spawnCore(prompt, implReportPath, extraArgs, GLOBAL_TIMEOUT_MS, HEARTBEAT_TIMEOUT_MS, logFile,
    buildChildEnv, 'opus', /* includeFallbackModel */ true, /* collectTelemetry */ false, worktreePath);
}

// ---------------------------------------------------------------------------
// Secondary export: _spawnWithTimerOverride (for tests only)
// ---------------------------------------------------------------------------

/**
 * Same as spawnNestedClaude but with overridable timeout values.
 * @internal — for tests only
 *
 * @param {string}   prompt
 * @param {string}   implReportPath
 * @param {string[]} extraArgs
 * @param {{ globalTimeoutMs?: number, heartbeatTimeoutMs?: number }} overrides
 * @returns {Promise<SpawnResult>}
 */
export async function _spawnWithTimerOverride(prompt, implReportPath, extraArgs, overrides = {}, logFile = '') {
  // Guard: required env vars (same as spawnNestedClaude)
  const missing = [];
  if (!process.env.GAAI_IMPL_BASE_URL)   missing.push('GAAI_IMPL_BASE_URL');
  if (!process.env.GAAI_IMPL_AUTH_TOKEN) missing.push('GAAI_IMPL_AUTH_TOKEN');
  if (!process.env.GAAI_IMPL_MODEL)      missing.push('GAAI_IMPL_MODEL');

  if (missing.length > 0) {
    const traceId = randomUUID();
    return {
      trace_id:         traceId,
      success:          false,
      exit_code:        null,
      error_reason:     'ENV_MISSING',
      impl_report_path: null,
      model_actual:     null,
      duration_ms:      0,
      model_requested:  process.env.GAAI_IMPL_MODEL   || '',
      model_fallback_triggered: false,
      provider_base_url:       process.env.GAAI_IMPL_BASE_URL || '',
      session_id:              null,
      terminal_receipt:        false,
      observation_window_expired: false,
    };
  }

  const gMs = overrides.globalTimeoutMs    ?? GLOBAL_TIMEOUT_MS;
  const hMs = overrides.heartbeatTimeoutMs ?? HEARTBEAT_TIMEOUT_MS;
  return spawnCore(prompt, implReportPath, extraArgs, gMs, hMs, logFile);
}

// ---------------------------------------------------------------------------
// CLI entry point — enables bash-native invocation by delivery agents
// ---------------------------------------------------------------------------
//
// Legacy usage (backward compatible — routes to spawnNestedClaude, AC7):
//   node .gaai/core/adapters/claude-code/nested-claude-spawn.js \
//     --prompt-file /path/to/impl-prompt.md \
//     --report-path /path/to/impl-report.md
//
// New usage (routes to runImpl — deterministic routing + internal audit emit):
//   node .gaai/core/adapters/claude-code/nested-claude-spawn.js \
//     --prompt-file /path/to/impl-prompt.md \
//     --report-path /path/to/impl-report.md \
//     --story-id E99S01 \
//     [--impl-model-tag primary|secondary|absent]
//
// Result: JSON SpawnResult printed to stdout on exit 0; exits 1 on invocation error.
// When --story-id is provided: uses runImpl() — deterministic routing + internal audit log.
// When --story-id is absent:   uses spawnNestedClaude() — legacy secondary-only path (AC7).
// AC12: audit log emission uses logPhase() library (imported above), not a separate CLI spawn.

async function _cli() {
  const args = process.argv.slice(2);
  const opts = {};
  for (let i = 0; i < args.length; i++) {
    const k = args[i];
    if (k === '--prompt-file' || k === '--prompt') opts.promptFile = args[++i];
    else if (k === '--prompt-inline') opts.promptInline = args[++i];
    else if (k === '--report-path') opts.reportPath = args[++i];
    else if (k === '--extra-arg') { (opts.extraArgs ||= []).push(args[++i]); }
    else if (k === '--log-file') opts.logFile = args[++i];
    else if (k === '--story-id') opts.storyId = args[++i];
    else if (k === '--impl-model-tag') opts.implModelTag = args[++i];
    else if (k === '--worktree-path') opts.worktreePath = args[++i];
    else if (k === '--reconcile-handles') opts.reconcileHandles = true;
    else if (k === '--reap') opts.reap = true;
    else if (k === '--help' || k === '-h') {
      process.stdout.write(`Usage: node nested-claude-spawn.js [options]

Options:
  --prompt-file <path>       Read prompt text from file (preferred for large prompts)
  --prompt-inline <txt>      Pass prompt inline (for short prompts only)
  --report-path <path>       Path where the nested claude -p will write impl-report.md
  --story-id <id>            Story ID for audit log (enables runImpl path)
  --impl-model-tag <tag>     Routing tag: primary|secondary|absent (default: absent)
  --extra-arg <arg>          Append extra argv to child (repeatable)
  --log-file <path>          Append child stdout stream-json lines to this log file
  --reconcile-handles        Report in-flight runner handles and prune dead ones, then exit
  --reap                     With --reconcile-handles: also SIGKILL the tree of live handles
  --help, -h                 Show this help

When --story-id is provided: uses runImpl() — deterministic routing + internal audit log emit.
When --story-id is absent:   uses spawnNestedClaude() — legacy secondary-only path (AC7).

Output: SpawnResult JSON on stdout. Exit 1 on invocation error.
`);
      process.exit(0);
    }
  }

  if (!opts.logFile && process.env.GAAI_DELIVERY_LOG_FILE) {
    opts.logFile = process.env.GAAI_DELIVERY_LOG_FILE;
  }

  // Reconciliation is a standalone maintenance mode — it spawns nothing and
  // needs none of the run arguments below.
  if (opts.reconcileHandles) {
    const report = reconcileHandles({ reap: !!opts.reap });
    process.stdout.write(JSON.stringify(report, null, 2) + '\n');
    process.exit(0);
  }

  if (!opts.reportPath) {
    console.error('ERROR: --report-path is required');
    process.exit(1);
  }
  let prompt = '';
  if (opts.promptFile) {
    try { prompt = readFileSync(opts.promptFile, 'utf8'); }
    catch (e) { console.error(`ERROR: cannot read --prompt-file ${opts.promptFile}: ${e.message}`); process.exit(1); }
  } else if (opts.promptInline) {
    prompt = opts.promptInline;
  } else {
    console.error('ERROR: --prompt-file or --prompt-inline is required');
    process.exit(1);
  }

  let result;
  if (opts.storyId) {
    // New path: runImpl() — deterministic routing, internal audit log emit (AC7)
    result = await runImpl({
      implModelTag: opts.implModelTag ?? null,
      prompt,
      reportPath:   opts.reportPath,
      storyId:      opts.storyId,
      extraArgs:    opts.extraArgs || [],
      logFile:      opts.logFile || '',
      worktreePath: opts.worktreePath || '',
    });
  } else {
    // Legacy path: spawnNestedClaude() — backward compat (AC7)
    result = await spawnNestedClaude(prompt, opts.reportPath, opts.extraArgs || [], opts.logFile || '', opts.worktreePath || '');
  }

  process.stdout.write(JSON.stringify(result, null, 2) + '\n');
  // Exit 0 regardless of result.success — the caller reads success from the JSON.
  process.exit(0);
}

// Detect direct invocation (not import) and run CLI
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  _cli().catch(e => {
    console.error(`FATAL: ${e.message}`);
    process.exit(1);
  });
}
