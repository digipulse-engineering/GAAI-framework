#!/usr/bin/env node
/**
 * delivery-router.mjs — model routing for the Delivery pipeline.
 *
 * Roles are stable; models are replaceable resources. This engine names no
 * model and no provider: everything concrete lives in delivery-routing.json.
 * Replacing a model, a whole harness, or the ordering of a role's candidates
 * is a config edit — never a change here and never a change in the daemon.
 *
 * The selection algorithm is deliberately an ordered walk, not a scorer:
 *
 *   for candidate in ordered_candidates(role):
 *     model available?          no -> skip
 *     harness AVAILABLE?        no -> skip
 *     capability >= floor?      no -> skip
 *     contributed to what this
 *       step evaluates?         yes -> skip   (absolute; never relaxed)
 *     select, stop
 *   otherwise BLOCKED_NO_ELIGIBLE_MODEL
 *
 * The last gate is the one that must never be traded away. A quota outage on
 * one provider is a reason to try another candidate — never a reason to let a
 * model grade its own homework.
 *
 * Node stdlib only — no dependencies (ships in the OSS substrate).
 */

import {
  readFileSync, writeFileSync, mkdirSync, existsSync, statSync, realpathSync,
} from 'node:fs';
import { dirname, join, resolve as pathResolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  resolveLedgerPath, readLedger, recordContribution,
  contributorTokens, contributorsOf, isContributor, recordBlocked,
} from './delivery-provenance.mjs';

const __filename = fileURLToPath(import.meta.url);
const CORE_ROOT = pathResolve(dirname(__filename), '..', '..');   // .gaai/core

// ── Capability lattice ──────────────────────────────────────────────────────
export const CAPABILITY_RANK = Object.freeze({ WORKER: 1, STRONG: 2, FRONTIER: 3 });
export const HARNESS_STATES = Object.freeze(['AVAILABLE', 'QUOTA_EXHAUSTED', 'UNAVAILABLE']);
export const EFFORT_DEFAULT = 'high';
export const EFFORT_ESCALATED = 'xhigh';
/** Ordered, so a per-seat override can raise effort but never quietly lower it. */
export const EFFORT_RANK = Object.freeze({ low: 1, medium: 2, high: 3, xhigh: 4, max: 5 });

/** Why a candidate was passed over. PROVENANCE_CONFLICT is the absolute one. */
export const SKIP = Object.freeze({
  UNKNOWN_MODEL: 'UNKNOWN_MODEL',
  MODEL_UNAVAILABLE: 'MODEL_UNAVAILABLE',
  HARNESS_QUOTA_EXHAUSTED: 'HARNESS_QUOTA_EXHAUSTED',
  HARNESS_UNAVAILABLE: 'HARNESS_UNAVAILABLE',
  CAPABILITY_BELOW_MINIMUM: 'CAPABILITY_BELOW_MINIMUM',
  HARNESS_FEATURE_MISSING: 'HARNESS_FEATURE_MISSING',
  PROVENANCE_CONFLICT: 'PROVENANCE_CONFLICT',
  PRIOR_ATTEMPT_FAILED: 'PRIOR_ATTEMPT_FAILED',
  NOT_PINNED: 'NOT_PINNED',
});

// ───────────────────────────────────────────────────────────────────────────
// Config
// ───────────────────────────────────────────────────────────────────────────

/**
 * Config entries, minus the `_`-prefixed keys used for inline commentary.
 * The config is the place operators reason about routing, so it has to be
 * documentable in place; a `_why` on a role must not read as a role named
 * `_why`.
 */
function cfgEntries(obj) {
  return Object.entries(obj || {}).filter(([k]) => !k.startsWith('_'));
}

/**
 * Resolution order: explicit path > $GAAI_ROUTING_CONFIG > project override >
 * OSS default. The project override lets a repo re-point aliases or re-order
 * candidates without editing (and later fighting a sync of) the OSS substrate.
 * @param {string} [explicitPath]
 * @returns {{path: string, config: object}}
 */
export function loadConfig(explicitPath) {
  // A path the operator named explicitly must exist. Falling through to a
  // different policy file because the named one is missing would route under
  // rules nobody asked for, and look like it worked.
  for (const named of [explicitPath, process.env.GAAI_ROUTING_CONFIG]) {
    if (named && !existsSync(named)) throw new Error(`routing config not found: ${named}`);
  }

  const candidates = [];
  if (explicitPath) candidates.push(explicitPath);
  if (process.env.GAAI_ROUTING_CONFIG) candidates.push(process.env.GAAI_ROUTING_CONFIG);
  const projectRoot = process.env.PROJECT_DIR || process.cwd();
  candidates.push(join(projectRoot, '.gaai', 'project', 'contexts', 'config', 'delivery-routing.json'));
  candidates.push(join(CORE_ROOT, 'config', 'delivery-routing.json'));

  for (const p of candidates) {
    if (!p || !existsSync(p)) continue;
    let parsed;
    try {
      parsed = JSON.parse(readFileSync(p, 'utf8'));
    } catch (err) {
      throw new Error(`routing config is not valid JSON: ${p}: ${err.message}`);
    }
    return { path: p, config: parsed };
  }
  throw new Error(`no routing config found (looked at: ${candidates.filter(Boolean).join(', ')})`);
}

/**
 * Structural validation. Returns problems rather than throwing so `doctor` can
 * print all of them at once.
 * @param {object} cfg
 * @returns {{errors: string[], warnings: string[]}}
 */
export function validateConfig(cfg) {
  const errors = [];
  const warnings = [];
  if (!cfg || typeof cfg !== 'object') return { errors: ['config is not an object'], warnings };
  const harnesses = Object.fromEntries(cfgEntries(cfg.harnesses));
  const models = Object.fromEntries(cfgEntries(cfg.models));
  const roles = Object.fromEntries(cfgEntries(cfg.roles));

  if (Object.keys(harnesses).length === 0) errors.push('config.harnesses is empty');
  if (Object.keys(models).length === 0) errors.push('config.models is empty');
  if (Object.keys(roles).length === 0) errors.push('config.roles is empty');

  const byConcrete = new Map();
  for (const [id, m] of cfgEntries(models)) {
    if (!m.concrete_model) errors.push(`model ${id}: missing concrete_model`);
    if (!m.harness) errors.push(`model ${id}: missing harness`);
    else if (!harnesses[m.harness]) errors.push(`model ${id}: unknown harness ${m.harness}`);
    if (!CAPABILITY_RANK[m.capability]) {
      errors.push(`model ${id}: capability must be one of ${Object.keys(CAPABILITY_RANK).join('|')}`);
    }
    if (m.concrete_model) {
      const peers = byConcrete.get(m.concrete_model) || [];
      peers.push(id);
      byConcrete.set(m.concrete_model, peers);
    }
  }
  for (const [concrete, ids] of byConcrete) {
    if (ids.length > 1) {
      warnings.push(
        `aliases ${ids.join(', ')} all resolve to ${concrete} — they count as ONE contributor, `
        + 'so a role listing several of them has fewer independent candidates than it appears to',
      );
    }
  }

  for (const [role, r] of cfgEntries(roles)) {
    if (!CAPABILITY_RANK[r.minimum_capability]) {
      errors.push(`role ${role}: minimum_capability must be one of ${Object.keys(CAPABILITY_RANK).join('|')}`);
    }
    if (!Array.isArray(r.candidates) || r.candidates.length === 0) {
      errors.push(`role ${role}: candidates must be a non-empty array`);
      continue;
    }
    for (const c of r.candidates) {
      if (!models[c]) errors.push(`role ${role}: candidate ${c} is not in the model registry`);
    }
    const floor = CAPABILITY_RANK[r.minimum_capability] || 0;
    const above = r.candidates.filter((c) => models[c] && CAPABILITY_RANK[models[c].capability] >= floor);
    if (above.length === 0) {
      errors.push(`role ${role}: no candidate meets minimum_capability ${r.minimum_capability}`);
    }
    if (Array.isArray(r.evaluates) && r.evaluates.length > 0 && above.length < 2) {
      warnings.push(
        `role ${role} evaluates ${r.evaluates.join('+')} but has only ${above.length} candidate(s) at or above `
        + `${r.minimum_capability} — one provenance conflict away from BLOCKED_NO_ELIGIBLE_MODEL`,
      );
    }
  }
  return { errors, warnings };
}

// ───────────────────────────────────────────────────────────────────────────
// Harness availability
// ───────────────────────────────────────────────────────────────────────────

function harnessStatusDir() {
  return process.env.GAAI_HARNESS_STATUS_DIR
    || join(process.cwd(), '.delivery-locks', 'harness-status');
}

/** PATH lookup without spawning a shell. */
function onPath(bin) {
  if (!bin) return false;
  const parts = (process.env.PATH || '').split(':').filter(Boolean);
  for (const dir of parts) {
    const full = join(dir, bin);
    try {
      const st = statSync(full);
      if (st.isFile()) return true;
    } catch { /* not here */ }
  }
  return false;
}

/**
 * Resolves a harness's state.
 *
 * Order: env pin > recorded status file (QUOTA_EXHAUSTED expires on its TTL)
 * > binary probe. The env pin exists so an operator — or a test — can assert a
 * state the daemon has not observed yet.
 *
 * @param {string} harness
 * @param {object} cfg
 * @returns {{status: string, source: string, reason: string, until: string|null}}
 */
export function resolveHarnessStatus(harness, cfg) {
  const envKey = `GAAI_HARNESS_STATUS_${harness.toUpperCase()}`;
  const pinned = process.env[envKey];
  if (pinned) {
    const up = pinned.trim().toUpperCase();
    if (HARNESS_STATES.includes(up)) return { status: up, source: envKey, reason: '', until: null };
    return { status: 'UNAVAILABLE', source: envKey, reason: `invalid value ${pinned}`, until: null };
  }

  const file = join(harnessStatusDir(), `${harness}.json`);
  if (existsSync(file)) {
    try {
      const rec = JSON.parse(readFileSync(file, 'utf8'));
      const status = String(rec.status || '').toUpperCase();
      if (HARNESS_STATES.includes(status) && status !== 'AVAILABLE') {
        const until = rec.until ? Date.parse(rec.until) : NaN;
        const expired = Number.isFinite(until) && until <= Date.now();
        if (!expired) {
          return { status, source: file, reason: rec.reason || '', until: rec.until || null };
        }
      }
    } catch {
      // A malformed status file must not brick routing: fall through to the
      // probe. Failing OPEN is safe here because harness state is only ever an
      // availability question — it can never grant an ineligible model a turn.
    }
  }

  const probe = cfg?.harnesses?.[harness]?.probe;
  if (probe && !onPath(probe)) {
    return { status: 'UNAVAILABLE', source: 'probe', reason: `${probe} not on PATH`, until: null };
  }
  return { status: 'AVAILABLE', source: probe ? 'probe' : 'default', reason: '', until: null };
}

/**
 * Records a harness state. QUOTA_EXHAUSTED gets a TTL so a spent quota heals
 * itself instead of permanently retiring a provider.
 * @param {string} harness
 * @param {string} status
 * @param {{ttlSec?: number, reason?: string}} [opts]
 * @returns {{path: string, record: object}}
 */
export function setHarnessStatus(harness, status, opts = {}) {
  const up = String(status).toUpperCase();
  if (!HARNESS_STATES.includes(up)) {
    throw new Error(`unknown harness status ${status} (expected ${HARNESS_STATES.join('|')})`);
  }
  const dir = harnessStatusDir();
  mkdirSync(dir, { recursive: true });
  const path = join(dir, `${harness}.json`);
  const now = Date.now();
  const ttl = Number(opts.ttlSec || 0);
  const record = {
    harness,
    status: up,
    reason: opts.reason || '',
    since: new Date(now).toISOString(),
    until: up === 'AVAILABLE' || !ttl ? null : new Date(now + ttl * 1000).toISOString(),
  };
  writeFileSync(path, `${JSON.stringify(record, null, 2)}\n`, 'utf8');
  return { path, record };
}

/**
 * Result subtypes that mean the session ran into one of its own ceilings — a
 * turn cap, a spend cap, a structured-output retry cap. A session that hit one
 * of these was being answered right up to the cap, which is the opposite of an
 * out-of-budget provider, whatever earlier events in the log said.
 */
export const LOCAL_CAP_SUBTYPES = Object.freeze([
  'error_max_turns', 'error_max_budget_usd', 'error_max_structured_output_retries',
]);

/** `rate_limit_event` statuses under which the provider is still serving. */
const RATE_LIMIT_SERVING_STATUSES = new Set(['allowed', 'allowed_warning']);

/**
 * Reads a failed phase's log for evidence that a harness is out of budget.
 *
 * Only structured evidence counts. A phase log carries everything the agent
 * said, read and ran, and an agent working on rate limiting or credentials
 * writes "429" and "rate_limit" all day without the provider refusing a single
 * request. So the classifier reads the stream's own status events and the
 * error objects the harness raised, and never the free text inside assistant,
 * user or tool-result content:
 *
 *   1. how the session ended — the final `result` event. A session that ended
 *      on a local cap (max turns, max spend, ...) is not out of budget, and
 *      that verdict outranks anything the log said on the way there;
 *   2. the provider's last verdict — the most recent `rate_limit_event`, when
 *      its status is not one under which the provider still serves;
 *   3. the last error the harness raised, and the terminal result when it is
 *      itself an error — read for a structured `code`/`type`/status first,
 *      then for a known message.
 *
 * Signatures stay configuration because every provider words this differently
 * and the wording changes; they only ever run against error messages the
 * harness itself raised. A 5xx or a timeout is still not a quota signal, and
 * mis-parking a harness still costs real capacity.
 *
 * When the provider says when it will resume, that beats a flat backoff. A
 * default one-hour park against a reset that is a day and a half out would
 * wake the harness dozens of times, each waking costing a real phase spawn to
 * fail the same way.
 *
 * @param {string} logText
 * @param {object} cfg
 * @param {string} [harness]
 * @returns {{matched: boolean, signature: string|null, via: string|null,
 *            resetAt: string|null, resetRaw: string|null,
 *            terminal: string|null, localCap: boolean}}
 */
export function observeQuota(logText, cfg, harness = '') {
  const perHarness = cfg?.harnesses?.[harness]?.quota_detection;
  const shared = cfg?.quota_detection || {};
  const signatures = perHarness?.signatures || shared.signatures || [];
  const hints = perHarness?.reset_hints || shared.reset_hints || [];
  const codes = perHarness?.codes || shared.codes || [];

  const events = parseEvents(String(logText || ''));
  const result = findLast(events, (e) => e.type === 'result');
  const terminal = result && typeof result.subtype === 'string' ? result.subtype : null;
  const none = {
    matched: false, signature: null, via: null, resetAt: null, resetRaw: null, terminal, localCap: false,
  };

  // 1. How the session ended.
  if (terminal && LOCAL_CAP_SUBTYPES.includes(terminal)) return { ...none, localCap: true };

  // 2. The provider's last verdict. It carries the reset time itself, so it
  //    beats every message-based hint.
  const verdict = findLast(events, (e) => e.type === 'rate_limit_event');
  if (verdict) {
    const info = verdict.rate_limit_info && typeof verdict.rate_limit_info === 'object'
      ? verdict.rate_limit_info : verdict;
    const status = typeof info.status === 'string' ? info.status.toLowerCase() : '';
    if (status && !RATE_LIMIT_SERVING_STATUSES.has(status)) {
      const at = epochToIso(info.resetsAt ?? info.resets_at);
      return {
        ...none, matched: true, via: 'rate_limit_event', signature: `rate_limit_event:${status}`,
        resetAt: at, resetRaw: at,
      };
    }
  }

  // 3. The last error the harness raised, plus the terminal result when it is
  //    itself an error. A structured code wins over the prose.
  const evidence = [];
  const lastError = findLast(events, (e) => e.type !== 'result' && errorEvidence(e) !== null);
  if (lastError) evidence.push(errorEvidence(lastError));
  if (result && result.is_error === true) evidence.push(resultEvidence(result));

  const wanted = new Set(codes.map((c) => String(c).toLowerCase()));
  let signature = null;
  let via = null;
  for (const ev of evidence) {
    const hit = ev.codes.find((c) => wanted.has(c.toLowerCase()));
    if (hit) { signature = hit; via = 'code'; break; }
  }
  const texts = evidence.flatMap((ev) => ev.texts);
  if (!signature) {
    for (const sig of signatures) {
      let re;
      try { re = new RegExp(sig, 'i'); } catch { continue; }
      if (texts.some((t) => re.test(t))) { signature = sig; via = 'signature'; break; }
    }
  }
  if (!signature) return none;

  const text = texts.join('\n');
  for (const hint of hints) {
    let m;
    try { m = text.match(new RegExp(hint, 'i')); } catch { continue; }
    if (!m || !m[1]) continue;
    // Providers write dates for humans ("Aug 20th"), which Date.parse rejects
    // over the ordinal suffix alone.
    const cleaned = m[1].replace(/(\d+)(st|nd|rd|th)\b/gi, '$1').trim();
    const at = Date.parse(cleaned);
    if (Number.isFinite(at) && at > Date.now()) {
      return { ...none, matched: true, signature, via, resetAt: new Date(at).toISOString(), resetRaw: m[1].trim() };
    }
  }
  return { ...none, matched: true, signature, via };
}

/**
 * The JSON events in a phase log. A phase log is the harness's event stream
 * with stderr merged in, so prose lines and a line cut by the tail window both
 * occur; neither is an event.
 * @param {string} text
 * @returns {object[]}
 */
function parseEvents(text) {
  const events = [];
  for (const line of text.split('\n')) {
    const t = line.trim();
    if (!t.startsWith('{')) continue;
    let parsed;
    try { parsed = JSON.parse(t); } catch { continue; }
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) events.push(parsed);
  }
  return events;
}

function findLast(events, pred) {
  for (let i = events.length - 1; i >= 0; i -= 1) {
    if (pred(events[i])) return events[i];
  }
  return null;
}

/** Provider reset stamps arrive as epoch seconds, occasionally milliseconds. */
function epochToIso(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return null;
  const ms = n > 1e11 ? n : n * 1000;
  return ms > Date.now() ? new Date(ms).toISOString() : null;
}

/**
 * The error a harness event raised, if it raised one: structured
 * `code`/`type`/status fields and the provider's own message text. This is the
 * whole allow-list of where evidence may come from — an error event, an API
 * retry notice, an error item in an item stream, an error object hung on an
 * event, or an event-level error class. Every other field of every other event
 * is content the model or a tool produced, and never counts.
 * @param {object} event
 * @returns {{codes: string[], texts: string[]}|null}
 */
function errorEvidence(event) {
  if (!event || typeof event !== 'object') return null;
  const type = typeof event.type === 'string' ? event.type : '';
  const codes = [];
  const texts = [];
  const take = (obj, depth = 0) => {
    if (!obj || typeof obj !== 'object' || depth > 3) return;
    for (const k of ['code', 'type', 'error_type', 'error_code']) {
      if (typeof obj[k] === 'string') codes.push(obj[k]);
    }
    for (const k of ['status', 'error_status', 'status_code', 'api_error_status']) {
      if (Number.isFinite(obj[k])) codes.push(String(obj[k]));
    }
    if (typeof obj.error === 'string') codes.push(obj.error);   // an error class, never prose
    if (typeof obj.message === 'string') texts.push(obj.message);
    if (obj.error && typeof obj.error === 'object') take(obj.error, depth + 1);
  };

  if (type === 'error' || type.endsWith('.failed')
      || (type === 'system' && typeof event.subtype === 'string' && event.subtype.startsWith('api_'))) {
    take(event);                                   // the event is the error
  } else if (event.item && typeof event.item === 'object' && event.item.type === 'error') {
    take(event.item);                              // an error item in an item stream
  } else if (typeof event.error === 'string') {
    codes.push(event.error);                       // event-level error class on a message
  } else if (event.error && typeof event.error === 'object') {
    take(event.error);                             // an error object hung on the event
  }
  return codes.length || texts.length ? { codes, texts } : null;
}

/**
 * What the terminal `result` says about the failure: the API status the
 * session ended on and the harness's own error strings. Never the transcript.
 * @param {object} result
 * @returns {{codes: string[], texts: string[]}}
 */
function resultEvidence(result) {
  const codes = [];
  const texts = [];
  if (Number.isFinite(result.api_error_status)) codes.push(String(result.api_error_status));
  if (Array.isArray(result.errors)) {
    for (const e of result.errors) if (typeof e === 'string') texts.push(e);
  }
  if (typeof result.result === 'string') texts.push(result.result);
  return { codes, texts };
}

// ── Circuit breaker ────────────────────────────────────────────────────────
// The backstop for everything the matching above cannot see. A provider can
// reword its error, ship it localised, or fail in a way nobody anticipated; a
// harness that keeps failing is unusable whether or not we can explain why.

function breakerPath(harness) {
  return join(harnessStatusDir(), `${harness}.failures.json`);
}

/** @returns {{consecutive: number}} */
export function readBreaker(harness) {
  try {
    const rec = JSON.parse(readFileSync(breakerPath(harness), 'utf8'));
    return { consecutive: Number(rec.consecutive) || 0 };
  } catch {
    return { consecutive: 0 };
  }
}

export function writeBreaker(harness, consecutive) {
  mkdirSync(harnessStatusDir(), { recursive: true });
  writeFileSync(breakerPath(harness),
    `${JSON.stringify({ harness, consecutive, updated_at: new Date().toISOString() }, null, 2)}\n`, 'utf8');
}

/** Backoff bounds. A park shorter than a minute churns; one longer than a week
 *  is almost certainly a misparse and would retire a provider silently. */
export const QUOTA_TTL_MIN_SEC = 60;
export const QUOTA_TTL_MAX_SEC = 7 * 24 * 3600;

// ───────────────────────────────────────────────────────────────────────────
// Effort
// ───────────────────────────────────────────────────────────────────────────

/**
 * `high` is the default. `xhigh` is reserved for the cases where more thinking
 * is the actual remedy — not sprinkled everywhere, where it only buys latency.
 *
 * Note for provenance: raising effort does NOT make a model a different model.
 * @param {{highRisk?: boolean, afterCapabilityFailure?: boolean, reviewerEscalate?: boolean,
 *          unresolvedAmbiguity?: boolean, longHorizon?: boolean}} ctx
 * @returns {{level: string, triggers: string[]}}
 */
export function resolveEffort(ctx = {}) {
  const triggers = [];
  if (ctx.highRisk) triggers.push('HIGH_RISK');
  if (ctx.afterCapabilityFailure) triggers.push('PRIOR_CAPABILITY_FAILURE');
  if (ctx.reviewerEscalate) triggers.push('REVIEWER_ESCALATE');
  if (ctx.unresolvedAmbiguity) triggers.push('UNRESOLVED_AMBIGUITY');
  if (ctx.longHorizon) triggers.push('LONG_HORIZON');
  return { level: triggers.length ? EFFORT_ESCALATED : EFFORT_DEFAULT, triggers };
}

/**
 * Clamps a requested effort level to what the model declares, then expresses it
 * the way the harness wants it (env vars or extra argv).
 * @returns {{level: string, env: Record<string,string>, args: string[], clamped: boolean}}
 */
export function expressEffort(level, model, harnessCfg) {
  const supported = Array.isArray(model.supported_effort_levels) && model.supported_effort_levels.length
    ? model.supported_effort_levels
    : [EFFORT_DEFAULT];
  let effective = level;
  let clamped = false;
  if (!supported.includes(level)) {
    effective = supported.includes(EFFORT_DEFAULT) ? EFFORT_DEFAULT : supported[supported.length - 1];
    clamped = true;
  }
  const spec = harnessCfg?.effort;
  const value = spec?.values?.[effective];
  if (!spec || !value) return { level: effective, env: {}, args: [], clamped };
  if (spec.mode === 'env') return { level: effective, env: { ...value }, args: [], clamped };
  if (spec.mode === 'arg') return { level: effective, env: {}, args: [...value], clamped };
  return { level: effective, env: {}, args: [], clamped };
}

// ───────────────────────────────────────────────────────────────────────────
// Selection
// ───────────────────────────────────────────────────────────────────────────

/**
 * The exclusion set for a step. Normally the role's declared `evaluates`
 * kinds, with one policy addition the config cannot express:
 *
 * PLAN final verification (§8). If B reviewed A's plan and A remediated using
 * B's feedback, B has shaped the plan it would be validating. So the final
 * verifier excludes PLAN contributors AND everyone whose review feedback fed
 * the remediation.
 *
 * @param {object} roleCfg
 * @param {string} pass
 * @returns {string[]}
 */
export function evaluationKinds(roleCfg, pass) {
  const kinds = new Set(Array.isArray(roleCfg.evaluates) ? roleCfg.evaluates : []);
  if (pass === 'final_verification') kinds.add('PLAN_REVIEW');
  return [...kinds];
}

/**
 * Ordered-candidate selection. Returns the full walk, including why each
 * skipped candidate was skipped, so the decision is auditable after the fact.
 *
 * @param {object} args
 * @param {string} args.role
 * @param {object} args.config
 * @param {object} args.ledger
 * @param {string[]} [args.excludeIds]     aliases already tried this step (capability failures)
 * @param {string} [args.pass]             'default' | 'final_verification'
 * @param {object} [args.effortCtx]
 * @param {string} [args.pin]              operator pin; still subject to every gate
 * @param {(h: string) => object} [args.harnessResolver]
 * @returns {object} decision
 */
export function selectCandidate(args) {
  const {
    role, config, ledger, excludeIds = [], pass = 'default',
    effortCtx = {}, pin = '', harnessResolver = null, requireFeatures = [],
  } = args;

  // A role that is absent, commentary, or malformed must block cleanly. Throwing
  // here would take down a phase handler for a config typo, turning an operator
  // error into an outage.
  const roleCfg = config.roles?.[role];
  const usable = roleCfg && !role.startsWith('_') && Array.isArray(roleCfg.candidates);
  if (!usable) {
    return {
      status: 'BLOCKED_NO_ELIGIBLE_MODEL',
      blocked_class: 'CONFIG',
      role,
      reason: roleCfg
        ? `role ${role} is malformed in the routing config (no candidates array)`
        : `role ${role} is not defined in the routing config`,
      considered: [],
    };
  }

  const kinds = evaluationKinds(roleCfg, pass);
  const tokens = contributorTokens(ledger, kinds);
  const floor = CAPABILITY_RANK[roleCfg.minimum_capability] || 0;
  const disabled = new Set(
    (process.env.GAAI_MODEL_DISABLE || '').split(',').map((s) => s.trim()).filter(Boolean),
  );
  const priorAttempts = new Set(excludeIds);
  const resolveH = harnessResolver || ((h) => resolveHarnessStatus(h, config));
  const harnessCache = new Map();
  const considered = [];
  let sawCapabilityFloorSkip = false;
  let sawProvenanceSkip = false;

  for (const id of roleCfg.candidates) {
    const model = config.models?.[id];
    if (!model) { considered.push({ id, skipped: SKIP.UNKNOWN_MODEL }); continue; }
    const cand = { id, ...model };

    if (pin && id !== pin) { considered.push({ id, skipped: SKIP.NOT_PINNED }); continue; }
    if (priorAttempts.has(id)) { considered.push({ id, skipped: SKIP.PRIOR_ATTEMPT_FAILED }); continue; }
    if (model.available === false || disabled.has(id)) {
      considered.push({ id, skipped: SKIP.MODEL_UNAVAILABLE });
      continue;
    }

    // A harness that cannot give the step the tools it needs is not a cheaper
    // option, it is a different job. Skip rather than quietly run the phase
    // with less than it asked for.
    const features = config.harnesses?.[model.harness]?.features;
    const missing = requireFeatures.filter((f) => !(Array.isArray(features) && features.includes(f)));
    if (missing.length) {
      considered.push({ id, skipped: SKIP.HARNESS_FEATURE_MISSING, detail: missing.join('+') });
      continue;
    }

    if (!harnessCache.has(model.harness)) harnessCache.set(model.harness, resolveH(model.harness));
    const hstat = harnessCache.get(model.harness);
    if (hstat.status === 'QUOTA_EXHAUSTED') {
      considered.push({ id, skipped: SKIP.HARNESS_QUOTA_EXHAUSTED, detail: hstat.reason || '' });
      continue;
    }
    if (hstat.status !== 'AVAILABLE') {
      considered.push({ id, skipped: SKIP.HARNESS_UNAVAILABLE, detail: hstat.reason || '' });
      continue;
    }

    // A model below the seat's floor passes only where the operator has named it
    // in this role's `overrides` with a reason — and only one class below, so a
    // waiver can express "this model plus more thinking is good enough here" but
    // never "anything will do". Everything else is the silent downgrade the
    // capability floor exists to prevent.
    const override = roleCfg.overrides?.[id];
    const rank = CAPABILITY_RANK[model.capability] || 0;
    let waived = '';
    if (rank < floor) {
      const declared = typeof override?.capability_waiver === 'string' && override.capability_waiver.trim();
      if (declared && rank >= floor - 1) {
        waived = override.capability_waiver.trim();
      } else {
        sawCapabilityFloorSkip = true;
        considered.push({ id, skipped: SKIP.CAPABILITY_BELOW_MINIMUM });
        continue;
      }
    }

    // Absolute. Nothing above this line — no outage, no exhausted quota, no
    // "everything else is down" — is allowed to reach past it.
    if (kinds.length && isContributor(cand, tokens)) {
      sawProvenanceSkip = true;
      considered.push({ id, skipped: SKIP.PROVENANCE_CONFLICT, detail: kinds.join('+') });
      continue;
    }

    const wanted = resolveEffort(effortCtx);
    // The seat may demand more thinking from this particular model — that is the
    // whole point of seating a lesser model in a decision role. It can raise the
    // level, never lower one a trigger already asked for.
    let level = wanted.level;
    const seatEffort = override?.effort;
    if (seatEffort && (EFFORT_RANK[seatEffort] || 0) > (EFFORT_RANK[level] || 0)) {
      level = seatEffort;
      wanted.triggers.push(`SEAT_OVERRIDE:${role}`);
    }
    const effort = expressEffort(level, model, config.harnesses?.[model.harness]);
    return {
      status: 'SELECTED',
      role,
      pass,
      model_id: id,
      concrete_model: model.concrete_model,
      harness: model.harness,
      capability: model.capability,
      minimum_capability: roleCfg.minimum_capability,
      effort: effort.level,
      effort_requested: level,
      capability_waived: waived || null,
      effort_clamped: effort.clamped,
      effort_triggers: wanted.triggers,
      effort_env: effort.env,
      effort_args: effort.args,
      evaluates: kinds,
      excluded_contributors: kinds.length ? [...new Set(kinds.flatMap((k) => contributorsOf(ledger, k)))] : [],
      considered,
    };
  }

  // The class decides what the daemon does next, so it has to name the thing
  // that would actually fix it. A provenance block is a structural shortage of
  // independent models; a capability block is a policy refusal to downgrade;
  // availability is an outage.
  //
  // The mixed case is the one that matters and the one that is easy to get
  // wrong: some candidates were contributors AND some were merely offline.
  // Waiting genuinely resolves that, so it is retryable — calling it structural
  // would fail a story that a returning provider would have completed. Only a
  // block with no offline candidate at all is truly structural.
  const sawAvailabilitySkip = considered.some(
    (c) => c.skipped === SKIP.HARNESS_QUOTA_EXHAUSTED
        || c.skipped === SKIP.HARNESS_UNAVAILABLE
        || c.skipped === SKIP.MODEL_UNAVAILABLE,
  );
  let blockedClass = 'AVAILABILITY';
  if (sawProvenanceSkip && !sawAvailabilitySkip) blockedClass = 'PROVENANCE';
  else if (sawCapabilityFloorSkip && !sawAvailabilitySkip) blockedClass = 'CAPABILITY_FLOOR';
  if (pin) blockedClass = considered.every((c) => c.skipped === SKIP.NOT_PINNED) ? 'CONFIG' : blockedClass;

  return {
    status: 'BLOCKED_NO_ELIGIBLE_MODEL',
    blocked_class: blockedClass,
    role,
    pass,
    minimum_capability: roleCfg.minimum_capability,
    evaluates: kinds,
    excluded_contributors: kinds.length ? [...new Set(kinds.flatMap((k) => contributorsOf(ledger, k)))] : [],
    reason: blockedClass === 'CAPABILITY_FLOOR'
      ? `only models below ${roleCfg.minimum_capability} remain for ${role}; refusing to downgrade silently`
      : blockedClass === 'PROVENANCE'
        ? `every candidate for ${role} contributed to ${kinds.join('+')}; this needs another independent `
          + 'model in the registry, not another attempt'
        : sawProvenanceSkip
          ? `every candidate for ${role} either contributed to ${kinds.join('+')} or is offline; `
            + 'retryable once a provider returns'
          : `no candidate for ${role} is currently available`,
    considered,
  };
}

/**
 * Dry-runs the nominal pipeline and reports what each step would get.
 *
 * This exists because the interesting failures are structural, not transient,
 * and they are invisible while every provider is healthy. A pipeline that
 * spends one model producing the plan, a second reviewing it and a third
 * writing the code has spent three; the lane that evaluates plan AND code then
 * needs a FOURTH independent model. With a single provider's three models that
 * lane is not merely unlucky, it is arithmetically unservable — and the honest
 * place to learn that is a config check, not a stalled story at 3am.
 *
 * @param {object} config
 * @param {(h: string) => object} harnessResolver
 * @returns {{steps: Array, blocked: string[]}}
 */
export function simulatePipeline(config, harnessResolver) {
  const ledger = { contributions: [] };
  const contribute = (artifact, id) => {
    const m = config.models?.[id];
    if (!m) return;
    ledger.contributions.push({ artifact, model_id: id, concrete_model: m.concrete_model });
  };

  // The nominal flow, and what each successful step contributes.
  const flow = [
    { role: 'PLAN_PRODUCER', contributes: 'PLAN' },
    { role: 'PLAN_REVIEWER', contributes: 'PLAN' },   // approving a plan makes you its co-author
    { role: 'IMPL', contributes: 'CODE' },
    { role: 'QA_CODE', contributes: null },
    { role: 'QA_REQUIREMENTS', contributes: null },
    { role: 'QA_PLAN', contributes: null },
  ];

  const steps = [];
  const blocked = [];
  for (const { role, contributes } of flow) {
    if (!config.roles?.[role]) continue;
    const d = selectCandidate({ role, config, ledger, harnessResolver });
    if (d.status === 'SELECTED') {
      steps.push({
        role, model_id: d.model_id, harness: d.harness,
        effort: d.effort, capability_waived: d.capability_waived,
      });
      if (contributes) contribute(contributes, d.model_id);
    } else {
      steps.push({ role, blocked_class: d.blocked_class, reason: d.reason });
      blocked.push(role);
    }
  }
  return { steps, blocked };
}

/**
 * Runs the simulation with every provider healthy, then once per provider with
 * that provider removed. Answers "what still works if X is not there?" —
 * whatever the reason X is not there.
 */
export function resilienceReport(config) {
  const harnesses = cfgEntries(config.harnesses).map(([h]) => h);
  const scenarios = { all_available: () => ({ status: 'AVAILABLE' }) };
  for (const h of harnesses) {
    scenarios[`without_${h}`] = (x) => (x === h
      ? { status: 'UNAVAILABLE', reason: `${h} removed for this scenario` }
      : { status: 'AVAILABLE' });
  }
  const out = {};
  for (const [name, resolver] of Object.entries(scenarios)) {
    const sim = simulatePipeline(config, resolver);
    out[name] = {
      blocked: sim.blocked,
      steps: sim.steps.map((s) => (s.model_id
        ? `${s.role} -> ${s.model_id} / ${s.effort} (${s.harness})${s.capability_waived ? ' [waiver]' : ''}`
        : `${s.role} -> BLOCKED ${s.blocked_class}`)),
    };
  }
  return out;
}

// ───────────────────────────────────────────────────────────────────────────
// Verdict aggregation
// ───────────────────────────────────────────────────────────────────────────

/**
 * Deterministic aggregation over QA lanes — FAIL beats ESCALATE beats PASS.
 * No model is invoked to reinterpret verdicts.
 *
 * A required lane that did not report is ESCALATE, never an implicit pass:
 * an unevaluated lane is unknown, and unknown is exactly what a human is for.
 *
 * @param {Record<string,string>} lanes
 * @param {string[]} requiredLanes
 * @returns {{verdict: string, reason: string, lanes: object, missing: string[], invalid: string[]}}
 */
export function aggregateVerdict(lanes, requiredLanes) {
  const valid = ['PASS', 'FAIL', 'ESCALATE'];
  const missing = [];
  const invalid = [];
  const normalized = {};
  for (const [k, v] of Object.entries(lanes || {})) {
    const up = String(v).toUpperCase();
    if (!valid.includes(up)) invalid.push(k);
    normalized[k] = up;
  }
  for (const lane of requiredLanes) {
    if (!(lane in normalized)) missing.push(lane);
  }

  const required = requiredLanes.map((l) => normalized[l]).filter(Boolean);
  let verdict;
  let reason;
  if (required.includes('FAIL')) {
    verdict = 'FAIL';
    reason = `lane(s) ${requiredLanes.filter((l) => normalized[l] === 'FAIL').join(', ')} returned FAIL`;
  } else if (invalid.length) {
    verdict = 'ESCALATE';
    reason = `lane(s) ${invalid.join(', ')} returned an unrecognised verdict`;
  } else if (missing.length) {
    verdict = 'ESCALATE';
    reason = `required lane(s) ${missing.join(', ')} did not report`;
  } else if (required.includes('ESCALATE')) {
    verdict = 'ESCALATE';
    reason = `lane(s) ${requiredLanes.filter((l) => normalized[l] === 'ESCALATE').join(', ')} returned ESCALATE`;
  } else {
    verdict = 'PASS';
    reason = 'all required lanes returned PASS';
  }
  return { verdict, reason, lanes: normalized, missing, invalid };
}

// ───────────────────────────────────────────────────────────────────────────
// CLI
// ───────────────────────────────────────────────────────────────────────────

const USAGE = `delivery-router.mjs — Delivery model routing

  select      --role <ROLE> --story <ID> [--exclude a,b] [--pin <alias>]
              [--pass default|final_verification] [--require-feature <name>]
              [--high-risk]
              [--after-capability-failure] [--escalate] [--ambiguity]
              [--long-horizon] [--format json|sh]
              exit 0 = SELECTED, 3 = BLOCKED_NO_ELIGIBLE_MODEL

  record      --story <ID> --artifact PLAN|PLAN_REVIEW|CODE|QA
              (--model-id <alias> | --concrete-model <model> [--harness <name>])
              [--role <ROLE>] [--note <text>]

  check-independent --story <ID> --role <ROLE> --concrete-model <model>
              is an operator-pinned model independent of what this step
              evaluates? exit 0 = independent, 3 = it contributed

  record-blocked --story <ID> --role <ROLE> [--blocked-class C] [--reason R] [--trace T]
              record a step that could not be routed; a block leaves no
              contributor, so without this it leaves no trace at all

  contributors --story <ID> [--artifact <kind>] [--format json|sh]

  harness-status get --harness <name>
  harness-status set --harness <name> --status AVAILABLE|QUOTA_EXHAUSTED|UNAVAILABLE
              [--ttl-sec N] [--reason <text>]

  harness-observe --harness <name> --log <path> [--ttl-sec N]
              call after a FAILED phase. Parks the harness on a structured error
              code, else on a known message, else once it has failed enough
              times in a row that the reason stops mattering. Honours a
              provider-stated resume time. exit 0 = parked, 1 = not parked

  harness-success --harness <name>
              call after a SUCCESSFUL phase; clears the failure count

  aggregate   --lane NAME=PASS|FAIL|ESCALATE [--lane ...] [--format json|sh]

  doctor      validate the config and report live harness state

Common: --config <path> --ledger <path>
`;

function parseArgv(argv) {
  const opts = { _: [], lanes: {} };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith('--')) { opts._.push(a); continue; }
    switch (a) {
      case '--role': opts.role = argv[++i]; break;
      case '--story': opts.story = argv[++i]; break;
      case '--config': opts.config = argv[++i]; break;
      case '--ledger': opts.ledger = argv[++i]; break;
      case '--artifact': opts.artifact = argv[++i]; break;
      case '--model-id': opts.modelId = argv[++i]; break;
      case '--concrete-model': opts.concreteModel = argv[++i]; break;
      case '--note': opts.note = argv[++i]; break;
      case '--effort': opts.effort = argv[++i]; break;
      case '--attempt': opts.attempt = argv[++i]; break;
      case '--waived': opts.waived = argv[++i]; break;
      case '--duration-ms': opts.durationMs = argv[++i]; break;
      case '--trace': opts.trace = argv[++i]; break;
      case '--blocked-class': opts.blockedClass = argv[++i]; break;
      case '--harness': opts.harness = argv[++i]; break;
      case '--status': opts.status = argv[++i]; break;
      case '--ttl-sec': opts.ttlSec = Number(argv[++i]); break;
      case '--reason': opts.reason = argv[++i]; break;
      case '--log': opts.log = argv[++i]; break;
      case '--exclude': opts.exclude = argv[++i]; break;
      case '--pin': opts.pin = argv[++i]; break;
      case '--require-feature': (opts.requireFeatures ||= []).push(argv[++i]); break;
      case '--pass': opts.pass = argv[++i]; break;
      case '--format': opts.format = argv[++i]; break;
      case '--lane': {
        const kv = argv[++i] || '';
        const idx = kv.indexOf('=');
        if (idx > 0) opts.lanes[kv.slice(0, idx)] = kv.slice(idx + 1);
        break;
      }
      case '--high-risk': opts.highRisk = true; break;
      case '--after-capability-failure': opts.afterCapabilityFailure = true; break;
      case '--escalate': opts.reviewerEscalate = true; break;
      case '--ambiguity': opts.unresolvedAmbiguity = true; break;
      case '--long-horizon': opts.longHorizon = true; break;
      case '--help': case '-h': opts.help = true; break;
      default: opts._.push(a);
    }
  }
  return opts;
}

/** Single-quoted shell literal — the only safe way to hand these to `eval`. */
function shQuote(v) {
  return `'${String(v).replace(/'/g, `'\\''`)}'`;
}

function emitSh(pairs) {
  return Object.entries(pairs).map(([k, v]) => `${k}=${shQuote(v)}`).join('\n');
}

function selectToSh(d) {
  const envPairs = Object.entries(d.effort_env || {}).map(([k, v]) => `${k}=${v}`).join(' ');
  return emitSh({
    GAAI_ROUTE_STATUS: d.status,
    GAAI_ROUTE_ROLE: d.role || '',
    GAAI_ROUTE_MODEL_ID: d.model_id || '',
    GAAI_ROUTE_MODEL: d.concrete_model || '',
    GAAI_ROUTE_HARNESS: d.harness || '',
    GAAI_ROUTE_CAPABILITY: d.capability || '',
    GAAI_ROUTE_EFFORT: d.effort || '',
    GAAI_ROUTE_EFFORT_ENV: envPairs,
    GAAI_ROUTE_EFFORT_ARGS: (d.effort_args || []).join(' '),
    GAAI_ROUTE_WAIVED: d.capability_waived || '',
    GAAI_ROUTE_BLOCKED_CLASS: d.blocked_class || '',
    GAAI_ROUTE_REASON: d.reason || '',
    GAAI_ROUTE_EXCLUDED: (d.excluded_contributors || []).join(','),
    GAAI_ROUTE_TRACE: (d.considered || []).map((c) => `${c.id}:${c.skipped}`).join(','),
  });
}

function main(argv) {
  const cmd = argv[0];
  const opts = parseArgv(argv.slice(1));
  if (!cmd || opts.help || cmd === 'help') { process.stdout.write(USAGE); return 0; }
  const fmt = opts.format || 'json';

  if (cmd === 'select') {
    if (!opts.role || !opts.story) { process.stderr.write('select requires --role and --story\n'); return 2; }
    const { config } = loadConfig(opts.config);
    const ledgerPath = resolveLedgerPath(opts.story, { explicitPath: opts.ledger });
    const ledger = readLedger(ledgerPath, opts.story);
    const roleCfg = config.roles?.[opts.role] || {};
    const kinds = evaluationKinds(roleCfg, opts.pass || 'default');
    if (ledger.corrupt && kinds.length) {
      // Evaluation without a trustworthy contributor list is exactly the thing
      // the invariant forbids. Fail closed.
      const d = {
        status: 'BLOCKED_NO_ELIGIBLE_MODEL',
        blocked_class: 'PROVENANCE',
        role: opts.role,
        reason: `provenance ledger unreadable (${ledgerPath}) — refusing to route an evaluation step blind`,
        considered: [],
      };
      process.stdout.write(fmt === 'sh' ? `${selectToSh(d)}\n` : `${JSON.stringify(d, null, 2)}\n`);
      return 3;
    }
    const decision = selectCandidate({
      role: opts.role,
      config,
      ledger,
      excludeIds: (opts.exclude || '').split(',').map((s) => s.trim()).filter(Boolean),
      pass: opts.pass || 'default',
      pin: opts.pin || '',
      requireFeatures: opts.requireFeatures || [],
      effortCtx: {
        highRisk: opts.highRisk,
        afterCapabilityFailure: opts.afterCapabilityFailure,
        reviewerEscalate: opts.reviewerEscalate,
        unresolvedAmbiguity: opts.unresolvedAmbiguity,
        longHorizon: opts.longHorizon,
      },
    });
    process.stdout.write(fmt === 'sh' ? `${selectToSh(decision)}\n` : `${JSON.stringify(decision, null, 2)}\n`);
    return decision.status === 'SELECTED' ? 0 : 3;
  }

  if (cmd === 'record') {
    if (!opts.story || !opts.artifact || (!opts.modelId && !opts.concreteModel)) {
      process.stderr.write('record requires --story, --artifact and --model-id or --concrete-model\n');
      return 2;
    }
    const { config } = loadConfig(opts.config);
    const model = opts.modelId ? config.models?.[opts.modelId] : null;
    // A contributor that is not in the registry still contributed, and still
    // has to be excluded from evaluating its own work — a story pinned to an
    // off-registry provider is the common case. Record it by concrete model
    // under a synthetic alias; eligibility matches on the concrete model, so
    // the exclusion holds even if that model is added to the registry later.
    if (opts.modelId && !model && !opts.concreteModel) {
      process.stderr.write(`record: unknown model alias ${opts.modelId} (pass --concrete-model for an off-registry contributor)\n`);
      return 2;
    }
    const concrete = model ? model.concrete_model : opts.concreteModel;
    const alias = opts.modelId || `external:${opts.concreteModel}`;
    const ledgerPath = resolveLedgerPath(opts.story, { explicitPath: opts.ledger });
    const { recorded } = recordContribution(ledgerPath, {
      storyId: opts.story,
      artifact: opts.artifact,
      modelId: alias,
      concreteModel: concrete,
      harness: model ? model.harness : (opts.harness || ''),
      role: opts.role || '',
      effort: opts.effort || '',
      attempt: opts.attempt || '',
      capabilityWaived: opts.waived || '',
      durationMs: opts.durationMs || 0,
      fallbackTrace: opts.trace || '',
      note: opts.note || '',
    });
    process.stdout.write(`${JSON.stringify({ recorded, ledger_path: ledgerPath }, null, 2)}\n`);
    return 0;
  }

  if (cmd === 'check-independent') {
    // An operator pin bypasses candidate ordering. It must not bypass the one
    // gate that is absolute: a pinned model that contributed to what this step
    // evaluates would be judging its own work, which no override short of
    // switching routing off entirely is allowed to arrange quietly.
    if (!opts.story || !opts.role || !opts.concreteModel) {
      process.stderr.write('check-independent requires --story, --role and --concrete-model\n');
      return 2;
    }
    const { config } = loadConfig(opts.config);
    const roleCfg = config.roles?.[opts.role] || {};
    const kinds = evaluationKinds(roleCfg, opts.pass || 'default');
    if (!kinds.length) {
      process.stdout.write(`${JSON.stringify({ independent: true, evaluates: [] }, null, 2)}\n`);
      return 0;
    }
    const ledgerPath = resolveLedgerPath(opts.story, { explicitPath: opts.ledger });
    const ledger = readLedger(ledgerPath, opts.story);
    if (ledger.corrupt) {
      process.stdout.write(`${JSON.stringify({
        independent: false, reason: 'provenance ledger unreadable — cannot prove independence',
      }, null, 2)}\n`);
      return 3;
    }
    const tokens = contributorTokens(ledger, kinds);

    // Resolve the pin to every identity it could name: a registry alias, a
    // concrete model, or a vendor CLI spelling. An operator writes whichever is
    // handiest, and the handiest is usually the CLI's own short name.
    const pin = opts.concreteModel;
    const identities = new Set([pin]);
    for (const [id, m] of cfgEntries(config.models)) {
      const spellings = [id, m.concrete_model, ...(m.cli_aliases || [])];
      if (spellings.includes(pin)) spellings.forEach((x) => x && identities.add(x));
    }

    // A pin that resolves to nothing known is not thereby innocent. The gate can
    // only clear a model it can identify, so an unresolvable spelling means
    // independence CANNOT BE PROVEN — which fails closed, exactly as the shell
    // contract promises. Failing open here would let the most natural spelling
    // of the implementer's own model walk past the one absolute rule.
    const known = identities.size > 1;
    if (!known) {
      process.stdout.write(`${JSON.stringify({
        independent: false,
        reason: `pin "${pin}" matches no registry alias, concrete model or CLI spelling `
          + '— independence cannot be proven',
        evaluates: kinds,
      }, null, 2)}\n`);
      return 3;
    }

    const conflict = [...identities].some((x) => isContributor({ id: x, concrete_model: x }, tokens));
    process.stdout.write(`${JSON.stringify({
      independent: !conflict,
      evaluates: kinds,
      contributors: [...new Set(kinds.flatMap((k) => contributorsOf(ledger, k)))],
    }, null, 2)}\n`);
    return conflict ? 3 : 0;
  }

  if (cmd === 'record-blocked') {
    if (!opts.story || !opts.role) {
      process.stderr.write('record-blocked requires --story and --role\n');
      return 2;
    }
    const ledgerPath = resolveLedgerPath(opts.story, { explicitPath: opts.ledger });
    recordBlocked(ledgerPath, {
      storyId: opts.story,
      role: opts.role,
      blockedClass: opts.blockedClass || '',
      reason: opts.reason || '',
      trace: opts.trace || '',
    });
    process.stdout.write(`${JSON.stringify({ recorded: true, ledger_path: ledgerPath }, null, 2)}\n`);
    return 0;
  }

  if (cmd === 'contributors') {
    if (!opts.story) { process.stderr.write('contributors requires --story\n'); return 2; }
    const ledgerPath = resolveLedgerPath(opts.story, { explicitPath: opts.ledger });
    const ledger = readLedger(ledgerPath, opts.story);
    const kinds = opts.artifact ? [opts.artifact] : ['PLAN', 'PLAN_REVIEW', 'CODE', 'QA'];
    const out = {};
    for (const k of kinds) out[k] = contributorsOf(ledger, k);
    if (fmt === 'sh') {
      process.stdout.write(`${emitSh({
        GAAI_PROVENANCE_CORRUPT: ledger.corrupt ? '1' : '0',
        ...Object.fromEntries(kinds.map((k) => [`GAAI_CONTRIB_${k}`, out[k].join(',')])),
      })}\n`);
    } else {
      process.stdout.write(`${JSON.stringify({ corrupt: ledger.corrupt, contributors: out }, null, 2)}\n`);
    }
    return ledger.corrupt ? 3 : 0;
  }

  if (cmd === 'harness-status') {
    const sub = opts._[0] || 'get';
    if (!opts.harness) { process.stderr.write('harness-status requires --harness\n'); return 2; }
    const { config } = loadConfig(opts.config);
    if (sub === 'set') {
      if (!opts.status) { process.stderr.write('harness-status set requires --status\n'); return 2; }
      const ttl = opts.ttlSec || (String(opts.status).toUpperCase() === 'QUOTA_EXHAUSTED'
        ? Number(config.quota_backoff_sec || 3600) : 0);
      const { path, record } = setHarnessStatus(opts.harness, opts.status, { ttlSec: ttl, reason: opts.reason });
      process.stdout.write(`${JSON.stringify({ path, ...record }, null, 2)}\n`);
      return 0;
    }
    const st = resolveHarnessStatus(opts.harness, config);
    if (fmt === 'sh') {
      process.stdout.write(`${emitSh({ GAAI_HARNESS: opts.harness, GAAI_HARNESS_STATE: st.status })}\n`);
    } else {
      process.stdout.write(`${JSON.stringify({ harness: opts.harness, ...st }, null, 2)}\n`);
    }
    return st.status === 'AVAILABLE' ? 0 : 3;
  }

  if (cmd === 'harness-success') {
    // Any success clears the breaker. A harness that is working is working,
    // whatever it did on the previous story.
    if (!opts.harness) { process.stderr.write('harness-success requires --harness\n'); return 2; }
    writeBreaker(opts.harness, 0);
    process.stdout.write(`${JSON.stringify({ harness: opts.harness, consecutive: 0 }, null, 2)}\n`);
    return 0;
  }

  if (cmd === 'harness-observe') {
    if (!opts.harness || !opts.log) {
      process.stderr.write('harness-observe requires --harness and --log\n');
      return 2;
    }
    const { config } = loadConfig(opts.config);
    let text = '';
    try {
      // Tail only: a quota notice lands at the end, and phase logs are large.
      const buf = readFileSync(opts.log);
      text = buf.subarray(Math.max(0, buf.length - 65536)).toString('utf8');
    } catch (err) {
      process.stderr.write(`harness-observe: cannot read ${opts.log}: ${err.message}\n`);
      return 2;
    }
    const obs = observeQuota(text, config, opts.harness);
    if (!obs.matched && obs.localCap) {
      // The session ran into one of its own ceilings. That is a verdict on the
      // story, not on the harness — which was answering right up to the cap —
      // so it neither parks the harness nor counts toward the breaker.
      process.stdout.write(`${JSON.stringify({
        matched: false, via: 'result', terminal: obs.terminal,
        consecutive: readBreaker(opts.harness).consecutive,
      }, null, 2)}\n`);
      return 1;
    }
    if (!obs.matched) {
      // Nothing recognisable in the log. That is not proof the harness is
      // healthy — only that we cannot explain this failure. Count it, and park
      // the harness once it has failed enough times in a row that the reason
      // stops mattering.
      const breaker = config.quota_detection?.circuit_breaker || {};
      const threshold = Number(breaker.consecutive_failures || 0);
      const consecutive = readBreaker(opts.harness).consecutive + 1;
      writeBreaker(opts.harness, consecutive);
      if (threshold > 0 && consecutive >= threshold) {
        const ttl = Math.min(QUOTA_TTL_MAX_SEC,
          Math.max(QUOTA_TTL_MIN_SEC, Number(breaker.park_sec || 900)));
        const { record } = setHarnessStatus(opts.harness, 'UNAVAILABLE', {
          ttlSec: ttl,
          reason: `${consecutive} consecutive phase failures (cause unrecognised)`,
        });
        process.stdout.write(`${JSON.stringify({
          matched: false, via: 'circuit_breaker', consecutive, ttl_sec: ttl, until: record.until,
        }, null, 2)}\n`);
        return 0;
      }
      process.stdout.write(`${JSON.stringify({
        matched: false, consecutive, threshold, terminal: obs.terminal,
      }, null, 2)}\n`);
      return 1;
    }
    writeBreaker(opts.harness, 0);   // a recognised, explained park supersedes the count
    let ttl = Number(opts.ttlSec || 0);
    if (!ttl && obs.resetAt) ttl = Math.ceil((Date.parse(obs.resetAt) - Date.now()) / 1000);
    if (!ttl) ttl = Number(config.quota_backoff_sec || 3600);
    ttl = Math.min(QUOTA_TTL_MAX_SEC, Math.max(QUOTA_TTL_MIN_SEC, ttl));
    const reason = obs.resetRaw
      ? `${obs.signature} (provider resumes ${obs.resetRaw})`
      : String(obs.signature);
    const { record } = setHarnessStatus(opts.harness, 'QUOTA_EXHAUSTED', { ttlSec: ttl, reason });
    process.stdout.write(`${JSON.stringify({
      matched: true, via: obs.via, signature: obs.signature, reset_raw: obs.resetRaw,
      ttl_sec: ttl, until: record.until,
    }, null, 2)}\n`);
    return 0;
  }

  if (cmd === 'aggregate') {
    const { config } = loadConfig(opts.config);
    const required = config.verdict?.required_lanes || Object.keys(opts.lanes);
    const result = aggregateVerdict(opts.lanes, required);
    if (fmt === 'sh') {
      process.stdout.write(`${emitSh({
        GAAI_QA_VERDICT: result.verdict,
        GAAI_QA_VERDICT_REASON: result.reason,
        GAAI_QA_MISSING_LANES: result.missing.join(','),
      })}\n`);
    } else {
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    }
    return 0;
  }

  if (cmd === 'doctor') {
    const { path, config } = loadConfig(opts.config);
    const { errors, warnings } = validateConfig(config);
    const harnesses = {};
    for (const [h] of cfgEntries(config.harnesses)) {
      harnesses[h] = resolveHarnessStatus(h, config);
    }
    const resilience = resilienceReport(config);
    for (const [name, r] of Object.entries(resilience)) {
      if (r.blocked.length) {
        warnings.push(`scenario ${name}: ${r.blocked.join(', ')} cannot be served`);
      }
    }
    const report = {
      config_path: path,
      errors,
      warnings,
      resilience,
      harnesses,
      models: Object.fromEntries(cfgEntries(config.models).map(([id, m]) => [id, {
        concrete_model: m.concrete_model,
        harness: m.harness,
        capability: m.capability,
        available: m.available !== false,
        harness_status: harnesses[m.harness]?.status || 'UNKNOWN',
      }])),
      roles: Object.fromEntries(cfgEntries(config.roles).map(([r, v]) => [r, {
        minimum_capability: v.minimum_capability,
        evaluates: v.evaluates || [],
        candidates: v.candidates,
      }])),
    };
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return errors.length ? 2 : 0;
  }

  process.stderr.write(`unknown command: ${cmd}\n\n${USAGE}`);
  return 2;
}

// Compare physical paths: Node resolves the loaded module through filesystem
// symlinks, while argv preserves the caller's spelling. On macOS, for example,
// `/tmp/x.mjs` can load as `/private/tmp/x.mjs`; lexical resolution alone then
// skips main(), returns 0 and emits nothing. Resolution failure is import-like,
// never permission to execute a CLI entry point.
let isMain = false;
if (process.argv[1]) {
  try {
    isMain = realpathSync(process.argv[1]) === realpathSync(__filename);
  } catch {
    isMain = false;
  }
}
if (isMain) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`delivery-router: ${err.message}\n`);
    process.exitCode = 2;
  }
}
