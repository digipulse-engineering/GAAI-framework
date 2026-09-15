/**
 * delivery-router.fixture.mjs — behaviour tests for Delivery model routing.
 *
 * The suite is organised around the guarantees, not the functions: ordered
 * fallback, capability floors, the absolute no-self-evaluation invariant, the
 * PLAN remediation rule, effort policy, and deterministic verdict aggregation.
 *
 * Run: node --test .gaai/core/scripts/tests/delivery-router.fixture.mjs
 */

import { describe, test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import {
  mkdtempSync, rmSync, writeFileSync, mkdirSync, readFileSync, symlinkSync, existsSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);

const HERE = dirname(fileURLToPath(import.meta.url));
const LIB = join(HERE, '..', 'lib');

const {
  loadConfig, validateConfig, selectCandidate, resolveEffort, expressEffort,
  aggregateVerdict, evaluationKinds, resolveHarnessStatus, setHarnessStatus,
  observeQuota, readBreaker, writeBreaker, simulatePipeline, resilienceReport,
  CAPABILITY_RANK, EFFORT_RANK, SKIP, QUOTA_TTL_MIN_SEC, QUOTA_TTL_MAX_SEC,
} = await import(join(LIB, 'delivery-router.mjs'));

const {
  readLedger, recordContribution, contributorTokens, isContributor, recordBlocked,
  latestContributor,
} = await import(join(LIB, 'delivery-provenance.mjs'));

// The shipped config is the contract under test — a routing rule that only
// holds for a bespoke fixture proves nothing about the daemon's behaviour.
const SHIPPED_CONFIG_PATH = join(LIB, '..', '..', 'config', 'delivery-routing.json');
const { config: SHIPPED } = loadConfig(SHIPPED_CONFIG_PATH);

const allUp = () => ({ status: 'AVAILABLE', source: 'test', reason: '', until: null });
/** Routable roles — the config allows `_`-prefixed keys for inline commentary. */
const ROLES = Object.keys(SHIPPED.roles).filter((r) => !r.startsWith('_'));
const down = (...names) => (h) => (names.includes(h)
  ? { status: 'QUOTA_EXHAUSTED', source: 'test', reason: 'test quota', until: null }
  : allUp());

let tmp;
beforeEach(() => { tmp = mkdtempSync(join(tmpdir(), 'gaai-router-')); });
afterEach(() => { rmSync(tmp, { recursive: true, force: true }); });

const ledgerPath = () => join(tmp, 'story.provenance.json');
const contribute = (artifact, modelId, cfg = SHIPPED) => recordContribution(ledgerPath(), {
  storyId: 'ROUTER-TEST-STORY',
  artifact,
  modelId,
  concreteModel: cfg.models[modelId].concrete_model,
  harness: cfg.models[modelId].harness,
});
const ledger = () => readLedger(ledgerPath(), 'ROUTER-TEST-STORY');
const pick = (role, extra = {}) => selectCandidate({
  role, config: SHIPPED, ledger: ledger(), harnessResolver: allUp, ...extra,
});

// ───────────────────────────────────────────────────────────────────────────
describe('CLI entry identity', () => {
  const routerPath = join(LIB, 'delivery-router.mjs');
  const cliEnv = () => {
    const env = { ...process.env };
    delete env.GAAI_ROUTING_CONFIG;
    delete env.GAAI_MODEL_DISABLE;
    for (const key of Object.keys(env)) {
      if (key.startsWith('GAAI_HARNESS_STATUS_')) delete env[key];
    }
    for (const harness of Object.keys(SHIPPED.harnesses)) {
      if (!harness.startsWith('_')) {
        env[`GAAI_HARNESS_STATUS_${harness.toUpperCase()}`] = 'AVAILABLE';
      }
    }
    return env;
  };

  test('executes through a symlinked directory path', () => {
    const alias = join(tmp, 'lib-alias');
    symlinkSync(LIB, alias, 'dir');

    const result = spawnSync(process.execPath, [
      join(alias, 'delivery-router.mjs'),
      'select', '--role', 'PLAN_PRODUCER', '--story', 'SYMLINK-CLI', '--format', 'sh',
      '--config', SHIPPED_CONFIG_PATH, '--ledger', join(tmp, 'cli.provenance.json'),
    ], { encoding: 'utf8', env: cliEnv() });

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /^GAAI_ROUTE_STATUS='SELECTED'$/m);
    assert.notEqual(result.stdout.length, 0);
  });

  test('importing the module does not execute the CLI', () => {
    const source = `await import(${JSON.stringify(pathToFileURL(routerPath).href)});`;
    const result = spawnSync(process.execPath, ['--input-type=module', '--eval', source], {
      encoding: 'utf8',
      env: cliEnv(),
    });

    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, '');
    assert.equal(result.stderr, '');
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('shipped configuration', () => {
  test('validates with no errors', () => {
    const { errors } = validateConfig(SHIPPED);
    assert.deepEqual(errors, []);
  });

  test('every role declares a capability floor its candidates can meet', () => {
    for (const role of ROLES) {
      const r = SHIPPED.roles[role];
      const floor = CAPABILITY_RANK[r.minimum_capability];
      const ok = r.candidates.filter((c) => CAPABILITY_RANK[SHIPPED.models[c].capability] >= floor);
      assert.ok(ok.length > 0, `${role} has no candidate at or above ${r.minimum_capability}`);
    }
  });

  test('the engine names no model or provider', () => {
    const src = readFileSync(join(LIB, 'delivery-router.mjs'), 'utf8');
    for (const alias of Object.keys(SHIPPED.models)) {
      assert.ok(!src.includes(alias), `engine hardcodes registry alias ${alias}`);
    }
    for (const m of Object.values(SHIPPED.models)) {
      assert.ok(!src.includes(m.concrete_model), `engine hardcodes concrete model ${m.concrete_model}`);
    }
    for (const h of Object.keys(SHIPPED.harnesses)) {
      assert.ok(!new RegExp(`['"\`]${h}['"\`]`).test(src), `engine hardcodes harness ${h}`);
    }
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('ordered candidates', () => {
  test('picks the first candidate when everything is up', () => {
    const d = pick('PLAN_PRODUCER');
    assert.equal(d.status, 'SELECTED');
    assert.equal(d.model_id, SHIPPED.roles.PLAN_PRODUCER.candidates[0]);
  });

  test('skips to the next candidate when a harness is quota-exhausted', () => {
    const first = SHIPPED.roles.PLAN_PRODUCER.candidates[0];
    const d = pick('PLAN_PRODUCER', { harnessResolver: down(SHIPPED.models[first].harness) });
    assert.equal(d.status, 'SELECTED');
    assert.notEqual(d.model_id, first);
    assert.equal(d.considered[0].skipped, SKIP.HARNESS_QUOTA_EXHAUSTED);
  });

  test('skips a model the registry marks unavailable', () => {
    const first = SHIPPED.roles.IMPL.candidates[0];
    const cfg = structuredClone(SHIPPED);
    cfg.models[first].available = false;
    const d = selectCandidate({ role: 'IMPL', config: cfg, ledger: ledger(), harnessResolver: allUp });
    assert.equal(d.status, 'SELECTED');
    assert.notEqual(d.model_id, first);
    assert.equal(d.considered[0].skipped, SKIP.MODEL_UNAVAILABLE);
  });

  test('a candidate that already failed on capability is not retried', () => {
    const first = SHIPPED.roles.IMPL.candidates[0];
    const d = pick('IMPL', { excludeIds: [first] });
    assert.equal(d.status, 'SELECTED');
    assert.notEqual(d.model_id, first);
    assert.equal(d.considered[0].skipped, SKIP.PRIOR_ATTEMPT_FAILED);
  });

  test('exhausting the list blocks rather than wrapping around', () => {
    const d = pick('PLAN_PRODUCER', { excludeIds: SHIPPED.roles.PLAN_PRODUCER.candidates });
    assert.equal(d.status, 'BLOCKED_NO_ELIGIBLE_MODEL');
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('no self-evaluation (absolute)', () => {
  test('the PLAN producer cannot review its own plan', () => {
    const producer = pick('PLAN_PRODUCER').model_id;
    contribute('PLAN', producer);
    const reviewer = pick('PLAN_REVIEWER');
    assert.equal(reviewer.status, 'SELECTED');
    assert.notEqual(reviewer.model_id, producer);
    assert.ok(reviewer.excluded_contributors.includes(producer));
  });

  test('an implementer cannot judge its own code', () => {
    const impl = pick('IMPL').model_id;
    contribute('CODE', impl);
    for (const lane of ['QA_CODE', 'QA_REQUIREMENTS', 'QA_PLAN']) {
      const d = pick(lane);
      assert.equal(d.status, 'SELECTED', `${lane} should still find someone`);
      assert.notEqual(d.model_id, impl, `${lane} selected the implementer`);
    }
  });

  test('an exhausted quota elsewhere never unlocks the producer', () => {
    const producer = pick('PLAN_PRODUCER').model_id;
    contribute('PLAN', producer);
    // Everything except the producer's own harness is down.
    const others = new Set(Object.values(SHIPPED.models).map((m) => m.harness));
    others.delete(SHIPPED.models[producer].harness);
    const d = pick('PLAN_REVIEWER', { harnessResolver: down(...others) });
    // Either an independent model is found or the step blocks. The producer is
    // never the answer, whatever else is unavailable.
    if (d.status === 'SELECTED') assert.notEqual(d.model_id, producer);
    else assert.equal(d.status, 'BLOCKED_NO_ELIGIBLE_MODEL');
  });

  test('two aliases sharing one concrete model count as one contributor', () => {
    const cfg = structuredClone(SHIPPED);
    const [a, b] = cfg.roles.QA_CODE.candidates;
    cfg.models[b].concrete_model = cfg.models[a].concrete_model;  // same underlying model
    contribute('CODE', a, cfg);
    const d = selectCandidate({ role: 'QA_CODE', config: cfg, ledger: ledger(), harnessResolver: allUp });
    assert.notEqual(d.model_id, b, 'alias rename let the same model grade its own work');
  });

  test('effort and harness do not create a second identity', () => {
    const impl = pick('IMPL').model_id;
    contribute('CODE', impl);
    const tokens = contributorTokens(ledger(), ['CODE']);
    const sameModelOtherHarness = {
      id: 'some_other_alias',
      concrete_model: SHIPPED.models[impl].concrete_model,
    };
    assert.ok(isContributor(sameModelOtherHarness, tokens));
  });

  test('every QA lane excludes the implementer', () => {
    // Founder policy: the QA model may be the one that produced the PLAN, but
    // never the one that wrote the code. Judging whether someone else's code
    // matches your plan is a different act from judging your own code — and the
    // failure this cannot catch, that the plan was wrong, is what
    // QA_REQUIREMENTS covers, where the Story is normative and the PLAN is not.
    for (const lane of ['QA_CODE', 'QA_REQUIREMENTS', 'QA_PLAN']) {
      assert.ok(evaluationKinds(SHIPPED.roles[lane], 'default').includes('CODE'),
        `${lane} would let the implementer grade its own code`);
    }
  });

  test('the plan author may serve a QA lane, the implementer may not', () => {
    const producer = pick('PLAN_PRODUCER').model_id;
    contribute('PLAN', producer);
    const impl = pick('IMPL').model_id;
    contribute('CODE', impl);
    for (const lane of ['QA_CODE', 'QA_REQUIREMENTS', 'QA_PLAN']) {
      const d = pick(lane);
      assert.equal(d.status, 'SELECTED');
      assert.notEqual(d.model_id, impl, `${lane} seated the implementer`);
    }
  });

  test('a malformed or commentary role blocks instead of throwing', () => {
    // A config typo must cost a blocked step, never a crashed phase handler.
    for (const bogus of ['_doc', 'NO_SUCH_ROLE']) {
      const d = selectCandidate({ role: bogus, config: SHIPPED, ledger: ledger(), harnessResolver: allUp });
      assert.equal(d.status, 'BLOCKED_NO_ELIGIBLE_MODEL');
      assert.equal(d.blocked_class, 'CONFIG');
    }
  });

  test('an operator pin cannot seat a contributor', () => {
    // A pin skips candidate ordering. It does not get to skip the one gate that
    // is absolute — otherwise "absolute" is a claim the environment can quietly
    // refute. Pin a model that IS eligible by ordering but HAS contributed, so
    // provenance is the only thing that can refuse it.
    const author = SHIPPED.roles.QA_PLAN.candidates[0];
    contribute('CODE', author);
    const d = selectCandidate({
      role: 'QA_PLAN', config: SHIPPED, ledger: ledger(), harnessResolver: allUp, pin: author,
    });
    assert.equal(d.status, 'BLOCKED_NO_ELIGIBLE_MODEL');
    assert.ok(
      d.considered.some((c) => c.id === author && c.skipped === SKIP.PROVENANCE_CONFLICT),
      'the pin was refused for some other reason than authorship',
    );
  });

  test('an operator pin on an independent model is honoured', () => {
    const author = SHIPPED.roles.QA_PLAN.candidates[0];
    contribute('CODE', author);
    const other = SHIPPED.roles.QA_PLAN.candidates.find((c) => c !== author);
    const d = selectCandidate({
      role: 'QA_PLAN', config: SHIPPED, ledger: ledger(), harnessResolver: allUp, pin: other,
    });
    assert.equal(d.status, 'SELECTED');
    assert.equal(d.model_id, other);
  });

  test('a pin naming a model outside the role is refused, not silently widened', () => {
    const outside = Object.keys(SHIPPED.models)
      .find((id) => !id.startsWith('_') && !SHIPPED.roles.QA_PLAN.candidates.includes(id));
    if (!outside) return;
    const d = selectCandidate({
      role: 'QA_PLAN', config: SHIPPED, ledger: ledger(), harnessResolver: allUp, pin: outside,
    });
    assert.equal(d.status, 'BLOCKED_NO_ELIGIBLE_MODEL');
  });

  test('blocks rather than seating a contributor when nobody independent remains', () => {
    for (const c of SHIPPED.roles.QA_CODE.candidates) contribute('CODE', c);
    const d = pick('QA_CODE');
    assert.equal(d.status, 'BLOCKED_NO_ELIGIBLE_MODEL');
    assert.equal(d.blocked_class, 'PROVENANCE');
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('the independence gate under attack', () => {
  // Every vector below was proposed by an adversarial reviewer after the gate
  // was found failing OPEN on the single likeliest operator input. They are
  // kept as tests because the fix was wrong twice before it was right.
  const { execFileSync } = require('node:child_process');
  const cli = (args) => {
    try {
      execFileSync(process.execPath, [join(LIB, 'delivery-router.mjs'), ...args],
        { stdio: 'pipe', env: { ...process.env, PROJECT_DIR: join(LIB, '..', '..', '..', '..') } });
      return 'ALLOW';
    } catch { return 'REFUSE'; }
  };
  const ledgerFile = () => join(tmp, 'attack.json');
  const authored = (args) => cli(['record', '--story', 'S', '--artifact', 'CODE',
    ...args, '--ledger', ledgerFile()]);
  const pin = (spelling) => cli(['check-independent', '--story', 'S', '--role', 'QA_PLAN',
    '--concrete-model', spelling, '--ledger', ledgerFile()]);

  test('every spelling of the implementer is refused', () => {
    authored(['--model-id', 'claude_worker']);
    for (const spelling of ['claude_worker', 'claude-sonnet-5', 'sonnet']) {
      assert.equal(pin(spelling), 'REFUSE', `spelling "${spelling}" walked past the gate`);
    }
  });

  test('an off-registry contributor is still refused under its own name', () => {
    authored(['--concrete-model', 'some-external-model']);
    assert.equal(pin('some-external-model'), 'REFUSE');
  });

  test('an independent model is still allowed, by alias or concrete name', () => {
    authored(['--model-id', 'claude_worker']);
    assert.equal(pin('claude-opus-5'), 'ALLOW');
    assert.equal(pin('opus'), 'ALLOW');
  });

  test('a spelling the registry cannot resolve fails closed', () => {
    // Including near-misses like case variants: the gate clears what it can
    // identify, and refuses what it cannot. Both directions of that are safe;
    // only the reverse would be a hole.
    authored(['--model-id', 'claude_worker']);
    for (const spelling of ['Sonnet', ' sonnet ', 'a-model-nobody-declared']) {
      assert.equal(pin(spelling), 'REFUSE', `unresolvable "${spelling}" was cleared`);
    }
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('PLAN remediation rule (producer A, reviewer B, verifier C)', () => {
  test('the reviewer whose feedback shaped v2 cannot sign off on v2', () => {
    const a = pick('PLAN_PRODUCER').model_id;
    contribute('PLAN', a);
    const b = pick('PLAN_REVIEWER').model_id;
    // B rejected and its feedback fed A's remediation.
    contribute('PLAN_REVIEW', b);
    const c = pick('PLAN_REVIEWER', { pass: 'final_verification' });
    assert.equal(c.status, 'SELECTED');
    assert.notEqual(c.model_id, a, 'the author verified its own plan');
    assert.notEqual(c.model_id, b, 'the reviewer verified a plan it shaped');
  });

  test('final verification widens, never narrows, the exclusion set', () => {
    const normal = evaluationKinds(SHIPPED.roles.PLAN_REVIEWER, 'default');
    const final = evaluationKinds(SHIPPED.roles.PLAN_REVIEWER, 'final_verification');
    for (const k of normal) assert.ok(final.includes(k));
    assert.ok(final.includes('PLAN_REVIEW'));
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('capability floor', () => {
  test('a below-floor model is never SILENTLY substituted', () => {
    // With every at-floor model gone, one of two things may happen, and no
    // third: either the step blocks, or a below-floor model takes the seat with
    // a declared waiver and the raised effort that justifies it. What must never
    // happen is the quiet downgrade — a lesser model in the seat, at ordinary
    // effort, with nothing in the decision record saying so.
    const cfg = structuredClone(SHIPPED);
    for (const c of cfg.roles.QA_CODE.candidates) {
      if (CAPABILITY_RANK[cfg.models[c].capability] >= CAPABILITY_RANK.FRONTIER) {
        cfg.models[c].available = false;
      }
    }
    const d = selectCandidate({ role: 'QA_CODE', config: cfg, ledger: ledger(), harnessResolver: allUp });
    if (d.status === 'SELECTED') {
      assert.ok(d.capability_waived, 'a below-floor model took the seat with no declared waiver');
      assert.equal(d.effort, 'xhigh', 'a waived seat ran at ordinary effort');
    } else {
      assert.ok(d.considered.some((c) => c.skipped === SKIP.CAPABILITY_BELOW_MINIMUM));
    }
  });

  test('stripping the declaration restores the hard floor', () => {
    const cfg = structuredClone(SHIPPED);
    for (const c of cfg.roles.QA_CODE.candidates) {
      if (CAPABILITY_RANK[cfg.models[c].capability] >= CAPABILITY_RANK.FRONTIER) {
        cfg.models[c].available = false;
      }
    }
    delete cfg.roles.QA_CODE.overrides;
    const d = selectCandidate({ role: 'QA_CODE', config: cfg, ledger: ledger(), harnessResolver: allUp });
    assert.equal(d.status, 'BLOCKED_NO_ELIGIBLE_MODEL');
    assert.equal(d.blocked_class, 'AVAILABILITY');
  });

  test('IMPL accepts a STRONG model where QA would not', () => {
    const worker = SHIPPED.roles.IMPL.candidates
      .find((c) => SHIPPED.models[c].capability === 'STRONG');
    assert.ok(worker, 'fixture expects at least one STRONG candidate on IMPL');
    assert.equal(pick('IMPL').model_id, worker);
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('harness features', () => {
  test('a harness that cannot carry a required feature is skipped', () => {
    const needsMcp = pick('PLAN_PRODUCER', { requireFeatures: ['mcp'] });
    assert.equal(needsMcp.status, 'SELECTED');
    assert.ok(
      (SHIPPED.harnesses[needsMcp.harness].features || []).includes('mcp'),
      'routed to a harness that does not declare mcp',
    );
  });

  test('the requirement changes the pick, not just the trace', () => {
    const free = pick('PLAN_PRODUCER');
    const gated = pick('PLAN_PRODUCER', { requireFeatures: ['mcp'] });
    const freeHarnessHasMcp = (SHIPPED.harnesses[free.harness].features || []).includes('mcp');
    if (!freeHarnessHasMcp) {
      assert.notEqual(gated.model_id, free.model_id);
      assert.equal(gated.considered[0].skipped, SKIP.HARNESS_FEATURE_MISSING);
    }
  });

  test('an unsatisfiable requirement blocks rather than downgrading', () => {
    const d = pick('PLAN_PRODUCER', { requireFeatures: ['a-feature-no-harness-has'] });
    assert.equal(d.status, 'BLOCKED_NO_ELIGIBLE_MODEL');
    assert.ok(d.considered.every((c) => c.skipped === SKIP.HARNESS_FEATURE_MISSING));
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('seating a model below the floor', () => {
  // The floor exists to stop a silent downgrade. A waiver is the opposite of
  // silent: named model, named role, stated reason, and the raised effort that
  // is the reason the exception is acceptable at all.
  const floorOf = (role) => CAPABILITY_RANK[SHIPPED.roles[role].minimum_capability];
  const belowFloor = (role, id) => (CAPABILITY_RANK[SHIPPED.models[id].capability] || 0) < floorOf(role);

  test('every below-floor seat in the shipped config is compensated with raised effort', () => {
    for (const role of ROLES) {
      const overrides = SHIPPED.roles[role].overrides || {};
      for (const [id, ov] of Object.entries(overrides)) {
        if (!ov.capability_waiver) continue;
        assert.ok(belowFloor(role, id), `${role}/${id} has a waiver it does not need`);
        assert.ok(
          (EFFORT_RANK[ov.effort] || 0) > EFFORT_RANK.high,
          `${role}/${id} sits below the floor without raised effort to compensate`,
        );
      }
    }
  });

  test('a waiver applies only to the role that declares it', () => {
    // Find a role with a waiver, and a role without one for the same model.
    const cfg = structuredClone(SHIPPED);
    const waivedRole = ROLES.find((r) => Object.values(cfg.roles[r].overrides || {})
      .some((o) => o.capability_waiver));
    assert.ok(waivedRole, 'fixture expects at least one declared waiver');
    const waivedId = Object.entries(cfg.roles[waivedRole].overrides)
      .find(([, o]) => o.capability_waiver)[0];

    const otherRole = ROLES.find((r) => r !== waivedRole
      && CAPABILITY_RANK[cfg.roles[r].minimum_capability] > CAPABILITY_RANK[cfg.models[waivedId].capability]
      && !(cfg.roles[r].overrides || {})[waivedId]);
    if (!otherRole) return;   // nothing to contrast against in this config
    cfg.roles[otherRole].candidates = [waivedId];
    const d = selectCandidate({ role: otherRole, config: cfg, ledger: ledger(), harnessResolver: allUp });
    assert.equal(d.status, 'BLOCKED_NO_ELIGIBLE_MODEL',
      'a waiver leaked into a role that never declared it');
  });

  test('a waiver reaches one class below the floor, not two', () => {
    const cfg = structuredClone(SHIPPED);
    const role = 'QA_CODE';
    const weak = 'a_much_weaker_model';
    cfg.models[weak] = {
      concrete_model: 'weak-1', harness: 'claude', capability: 'WORKER',
      available: true, supported_effort_levels: ['high', 'xhigh'],
    };
    cfg.roles[role].candidates = [weak];
    cfg.roles[role].overrides = { [weak]: { effort: 'xhigh', capability_waiver: 'let me in' } };
    const d = selectCandidate({ role, config: cfg, ledger: ledger(), harnessResolver: allUp });
    assert.equal(d.status, 'BLOCKED_NO_ELIGIBLE_MODEL',
      'a waiver let a model two classes below the floor into a seat');
  });

  test('an undeclared below-floor model is still skipped', () => {
    const cfg = structuredClone(SHIPPED);
    const role = 'QA_CODE';
    const below = Object.keys(cfg.models).find((id) => !id.startsWith('_') && belowFloor(role, id));
    if (!below) return;
    cfg.roles[role].candidates = [below];
    delete cfg.roles[role].overrides;
    const d = selectCandidate({ role, config: cfg, ledger: ledger(), harnessResolver: allUp });
    assert.equal(d.status, 'BLOCKED_NO_ELIGIBLE_MODEL');
    assert.equal(d.considered[0].skipped, SKIP.CAPABILITY_BELOW_MINIMUM);
  });

  test('a seat override raises effort but never lowers what a trigger asked for', () => {
    const cfg = structuredClone(SHIPPED);
    const role = 'QA_CODE';
    const id = cfg.roles[role].candidates[0];
    cfg.roles[role].overrides = { [id]: { effort: 'high' } };
    const d = selectCandidate({
      role, config: cfg, ledger: ledger(), harnessResolver: allUp,
      effortCtx: { highRisk: true },
    });
    assert.equal(d.effort, 'xhigh', 'a seat override downgraded a high-risk delivery');
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('reasoning effort', () => {
  test('defaults to high with no triggers', () => {
    assert.equal(resolveEffort({}).level, 'high');
    assert.equal(pick('IMPL').effort, 'high');
  });

  for (const trigger of ['highRisk', 'afterCapabilityFailure', 'reviewerEscalate',
    'unresolvedAmbiguity', 'longHorizon']) {
    test(`escalates to xhigh on ${trigger}`, () => {
      assert.equal(resolveEffort({ [trigger]: true }).level, 'xhigh');
      assert.equal(pick('IMPL', { effortCtx: { [trigger]: true } }).effort, 'xhigh');
    });
  }

  test('is expressed the way each harness declares it', () => {
    for (const [id, m] of Object.entries(SHIPPED.models)) {
      const e = expressEffort('high', m, SHIPPED.harnesses[m.harness]);
      const expressed = Object.keys(e.env).length > 0 || e.args.length > 0;
      assert.ok(expressed, `${id} produced no effort expression for its harness`);
    }
  });

  test('every declared level names itself in its own expression', () => {
    // Catches the expensive typo: a level wired to another level's value, which
    // would run every routed call at the wrong depth and look perfectly fine.
    for (const [name, h] of Object.entries(SHIPPED.harnesses)) {
      for (const [level, value] of Object.entries(h.effort?.values || {})) {
        const rendered = Array.isArray(value)
          ? value.join(' ')
          : Object.entries(value).map(([k, v]) => `${k}=${v}`).join(' ');
        assert.ok(
          rendered.includes(level),
          `harness ${name}: the ${level} expression (${rendered}) does not carry ${level}`,
        );
      }
    }
  });

  test('clamps to what the model supports instead of sending an unknown level', () => {
    const m = { concrete_model: 'x', harness: 'h', supported_effort_levels: ['high'] };
    const e = expressEffort('xhigh', m, { effort: { mode: 'env', values: { high: { K: '1' } } } });
    assert.equal(e.level, 'high');
    assert.equal(e.clamped, true);
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('harness availability', () => {
  test('a recorded quota state hides the harness until its TTL expires', () => {
    process.env.GAAI_HARNESS_STATUS_DIR = join(tmp, 'hs');
    delete process.env.GAAI_HARNESS_STATUS_CLAUDE;
    try {
      setHarnessStatus('claude', 'QUOTA_EXHAUSTED', { ttlSec: 600, reason: 'test' });
      assert.equal(resolveHarnessStatus('claude', SHIPPED).status, 'QUOTA_EXHAUSTED');
      setHarnessStatus('claude', 'QUOTA_EXHAUSTED', { ttlSec: -1, reason: 'expired' });
      assert.notEqual(resolveHarnessStatus('claude', SHIPPED).status, 'QUOTA_EXHAUSTED');
    } finally {
      delete process.env.GAAI_HARNESS_STATUS_DIR;
    }
  });

  test('an env pin overrides everything else', () => {
    process.env.GAAI_HARNESS_STATUS_CLAUDE = 'UNAVAILABLE';
    try {
      assert.equal(resolveHarnessStatus('claude', SHIPPED).status, 'UNAVAILABLE');
    } finally {
      delete process.env.GAAI_HARNESS_STATUS_CLAUDE;
    }
  });

  test('a harness whose binary is absent is UNAVAILABLE', () => {
    const cfg = structuredClone(SHIPPED);
    const [name] = Object.keys(cfg.harnesses);
    cfg.harnesses[name].probe = 'gaai-definitely-not-a-real-binary';
    assert.equal(resolveHarnessStatus(name, cfg).status, 'UNAVAILABLE');
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('out-of-budget detection', () => {
  // The fixture carries a real provider's wording verbatim (host, thread id and
  // year neutralised). It exists because the first version of this detection
  // was written against imagined phrasing — it looked for "usage limit reached"
  // while the provider actually says "You've hit your usage limit", so a spent
  // quota went undetected and every phase kept spawning against a dead harness.
  const fixture = (name) => readFileSync(join(HERE, 'fixtures', `${name}.log`), 'utf8');

  test('recognises a real out-of-budget message', () => {
    const obs = observeQuota(fixture('harness-quota-exhausted'), SHIPPED, 'codex');
    assert.equal(obs.matched, true);
  });

  test('recovers the provider-stated resume time', () => {
    const obs = observeQuota(fixture('harness-quota-exhausted'), SHIPPED, 'codex');
    assert.ok(obs.resetAt, 'no resume time recovered');
    // Parsed, not echoed: a human-written date with an ordinal suffix.
    assert.ok(Date.parse(obs.resetAt) > Date.now());
    assert.match(obs.resetRaw, /\d+(st|nd|rd|th)/i);
  });

  test('does not park a harness for a transient failure', () => {
    const obs = observeQuota(fixture('harness-transient-failure'), SHIPPED, 'codex');
    assert.equal(obs.matched, false);
  });

  test('an empty log is not evidence of anything', () => {
    assert.equal(observeQuota('', SHIPPED, 'codex').matched, false);
  });

  test('every configured signature is a valid regex', () => {
    const d = SHIPPED.quota_detection || {};
    for (const sig of [...(d.signatures || []), ...(d.reset_hints || [])]) {
      assert.doesNotThrow(() => new RegExp(sig, 'i'), `unparseable pattern: ${sig}`);
    }
  });

  test('a parked harness disappears from every role', () => {
    const parked = down('codex');
    for (const role of ROLES) {
      const d = pick(role, { harnessResolver: parked });
      if (d.status === 'SELECTED') {
        assert.notEqual(SHIPPED.models[d.model_id].harness, 'codex');
      }
    }
  });

  test('a structured error code is preferred over the prose', () => {
    const log = '{"type":"turn.failed","error":{"code":"rate_limit_reached","message":"opaque"}}';
    const obs = observeQuota(log, SHIPPED, 'codex');
    assert.equal(obs.matched, true);
    assert.equal(obs.via, 'code', 'fell back to prose matching with a code available');
  });

  test('a code is read from the payload, not scraped out of prose', () => {
    // The distinction matters: matching codes against free text is signature
    // matching wearing a different hat, and inherits all of its fuzziness.
    const log = '{"type":"error","message":"see the docs on someunknown_code_xyz"}';
    const cfg = structuredClone(SHIPPED);
    cfg.quota_detection.codes = ['someunknown_code_xyz'];
    cfg.quota_detection.signatures = [];
    assert.equal(observeQuota(log, cfg, 'codex').matched, false);
  });

  // The second real failure was of the detection itself. The phase under review
  // was about rate limiting, so the agent's own transcript carried every
  // signature word — in its reasoning, its grep, and a tool result echoing a
  // 429 error object verbatim — while the session actually ended on its turn
  // cap. Matching the log tail as prose parked a healthy harness for an hour.
  const HARNESS = Object.keys(SHIPPED.harnesses).find((h) => !h.startsWith('_'));
  const failedOnSomethingElse = '{"type":"result","subtype":"error_during_execution","is_error":true,'
    + '"num_turns":7,"errors":["process exited"],"api_error_status":null}';

  test('a session that ran out of turns is not out of budget, whatever the transcript says', () => {
    const obs = observeQuota(fixture('harness-max-turns-noisy'), SHIPPED, HARNESS);
    assert.equal(obs.matched, false);
    assert.equal(obs.localCap, true);
    assert.equal(obs.terminal, 'error_max_turns');
  });

  test('signature words inside assistant, user and tool-result content never count', () => {
    // The same transcript, ending in a failure the transcript does not explain.
    const transcript = fixture('harness-max-turns-noisy').split('\n')
      .filter((l) => !l.includes('"type":"result"'));
    const log = [...transcript, failedOnSomethingElse].join('\n');
    assert.equal(observeQuota(log, SHIPPED, HARNESS).matched, false);
  });

  test('a turn cap outranks a rate-limit verdict recorded earlier in the same log', () => {
    const log = [
      '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected"}}',
      '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":101}',
    ].join('\n');
    const obs = observeQuota(log, SHIPPED, HARNESS);
    assert.equal(obs.matched, false);
    assert.equal(obs.localCap, true);
  });

  test('a rejected rate-limit verdict parks the harness and carries its own reset', () => {
    const obs = observeQuota(fixture('harness-rate-limit-rejected'), SHIPPED, HARNESS);
    assert.equal(obs.matched, true);
    assert.equal(obs.via, 'rate_limit_event');
    assert.ok(obs.resetAt && Date.parse(obs.resetAt) > Date.now(), 'reset stamp not recovered');
  });

  test('a serving rate-limit status is not a verdict, even beside a rejected overage', () => {
    // A live event under an allowed status still carries "overageStatus":
    // "rejected" — a substring match on the word would park a serving harness.
    const resets = Math.floor(Date.now() / 1000) + 3600;
    const log = [
      `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":${resets},"overageStatus":"rejected"}}`,
      `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":${resets},"overageStatus":"rejected"}}`,
      failedOnSomethingElse,
    ].join('\n');
    assert.equal(observeQuota(log, SHIPPED, HARNESS).matched, false);
  });

  test('the most recent verdict wins over an earlier rejection', () => {
    const log = [
      '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected"}}',
      '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}',
      failedOnSomethingElse,
    ].join('\n');
    assert.equal(observeQuota(log, SHIPPED, HARNESS).matched, false);
  });

  test('a 429 the harness itself raised parks the harness', () => {
    const log = [
      '{"type":"system","subtype":"api_retry","attempt":3,"max_retries":3,"retry_delay_ms":8000,"error_status":429,"error":"rate_limit"}',
      '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":4,"errors":["API Error: 429 rate limit"],"api_error_status":429}',
    ].join('\n');
    const obs = observeQuota(log, SHIPPED, HARNESS);
    assert.equal(obs.matched, true);
    assert.equal(obs.via, 'code');
  });

  test('an event-level error class counts; the same words in the content do not', () => {
    const content = '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"rate_limit 429 quota exceeded"}]}}';
    assert.equal(observeQuota(content, SHIPPED, HARNESS).matched, false);
    const flagged = '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"opaque"}]},"error":"rate_limit"}';
    assert.equal(observeQuota(flagged, SHIPPED, HARNESS).matched, true);
  });

  test('a transient error raised last is not rescued by an older quota error', () => {
    const log = [
      '{"type":"error","message":"You\'ve hit your usage limit."}',
      '{"type":"turn.failed","error":{"message":"request failed after 3 attempts: ECONNRESET"}}',
    ].join('\n');
    assert.equal(observeQuota(log, SHIPPED, HARNESS).matched, false);
  });

  test('backoff bounds keep a park useful and reversible', () => {
    assert.ok(QUOTA_TTL_MIN_SEC >= 60, 'a sub-minute park just churns');
    assert.ok(QUOTA_TTL_MAX_SEC <= 30 * 24 * 3600, 'a park this long retires a provider silently');
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('harness-observe marks only on structured evidence', () => {
  // What the daemon actually calls after a failed phase, end to end: the
  // classification above, then the status file the next spawn will route on.
  const routerPath = join(LIB, 'delivery-router.mjs');
  const HARNESS = Object.keys(SHIPPED.harnesses).find((h) => !h.startsWith('_'));
  const statusDir = () => join(tmp, 'hs');
  const statusFile = () => join(statusDir(), `${HARNESS}.json`);
  const observe = (log) => spawnSync(process.execPath, [
    routerPath, 'harness-observe', '--harness', HARNESS, '--log', log, '--config', SHIPPED_CONFIG_PATH,
  ], { encoding: 'utf8', env: { ...process.env, GAAI_HARNESS_STATUS_DIR: statusDir() } });
  const logFixture = (name) => join(HERE, 'fixtures', `${name}.log`);

  beforeEach(() => { process.env.GAAI_HARNESS_STATUS_DIR = statusDir(); });
  afterEach(() => { delete process.env.GAAI_HARNESS_STATUS_DIR; });

  test('a noisy transcript ending on the turn cap leaves the harness in rotation', () => {
    const r = observe(logFixture('harness-max-turns-noisy'));
    assert.equal(r.status, 1, r.stdout + r.stderr);
    assert.match(r.stdout, /"terminal": "error_max_turns"/);
    assert.equal(existsSync(statusFile()), false, 'harness was marked');
  });

  test('a turn-cap exit does not count toward the breaker either', () => {
    writeBreaker(HARNESS, 1);
    observe(logFixture('harness-max-turns-noisy'));
    assert.equal(readBreaker(HARNESS).consecutive, 1);
  });

  test('a rejected rate-limit verdict marks the harness with an expiry', () => {
    const r = observe(logFixture('harness-rate-limit-rejected'));
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stdout, /"via": "rate_limit_event"/);
    const rec = JSON.parse(readFileSync(statusFile(), 'utf8'));
    assert.equal(rec.status, 'QUOTA_EXHAUSTED');
    assert.ok(Date.parse(rec.until) > Date.now(), 'park has no future expiry');
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('resilience when detection fails entirely', () => {
  // Everything above depends on recognising what a provider said. This does not.
  const breaker = () => SHIPPED.quota_detection.circuit_breaker;

  beforeEach(() => { process.env.GAAI_HARNESS_STATUS_DIR = join(tmp, 'hs'); });
  afterEach(() => { delete process.env.GAAI_HARNESS_STATUS_DIR; });

  test('the config ships a breaker at all', () => {
    assert.ok(Number(breaker().consecutive_failures) > 0,
      'without a threshold, an unrecognised failure mode bleeds forever');
    assert.ok(Number(breaker().park_sec) > 0);
  });

  test('the threshold tolerates a story-specific failure before blaming the harness', () => {
    assert.ok(Number(breaker().consecutive_failures) >= 2,
      'parking a healthy harness on one bad story costs real capacity');
  });

  test('the park is short enough to be a bleed-stop, not a retirement', () => {
    assert.ok(Number(breaker().park_sec) <= 3600);
  });

  test('the count survives across calls and resets on success', () => {
    writeBreaker('someharness', 0);
    assert.equal(readBreaker('someharness').consecutive, 0);
    writeBreaker('someharness', 2);
    assert.equal(readBreaker('someharness').consecutive, 2);
    writeBreaker('someharness', 0);
    assert.equal(readBreaker('someharness').consecutive, 0);
  });

  test('an unreadable counter reads as zero rather than throwing', () => {
    // A corrupt counter must not take the daemon down; the worst it can cost is
    // a later park, and the invariant never depended on it.
    mkdirSync(join(tmp, 'hs'), { recursive: true });
    writeFileSync(join(tmp, 'hs', 'broken.failures.json'), 'not json', 'utf8');
    assert.equal(readBreaker('broken').consecutive, 0);
  });

  test('parking every harness still leaves producing roles a path', () => {
    // Total outage must degrade, not deadlock: the phases that evaluate nothing
    // fall back to their legacy model, so the pipeline keeps moving.
    const allDown = () => ({ status: 'UNAVAILABLE', source: 'test', reason: 'all down', until: null });
    const d = pick('PLAN_PRODUCER', { harnessResolver: allDown });
    assert.equal(d.status, 'BLOCKED_NO_ELIGIBLE_MODEL');
    assert.equal(d.blocked_class, 'AVAILABILITY',
      'a total outage must read as retryable, never as a structural failure');
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('provenance ledger', () => {
  test('re-recording the same contribution is a no-op', () => {
    const first = contribute('PLAN', 'claude_strong');
    const again = contribute('PLAN', 'claude_strong');
    assert.equal(first.recorded, true);
    assert.equal(again.recorded, false);
    assert.equal(ledger().contributions.length, 1);
  });

  test('a remediating model joins the contributor list, it does not replace it', () => {
    contribute('CODE', 'claude_worker');
    contribute('CODE', 'codex_frontier');
    const tokens = contributorTokens(ledger(), ['CODE']);
    assert.ok(isContributor({ id: 'claude_worker', concrete_model: SHIPPED.models.claude_worker.concrete_model }, tokens));
    assert.ok(isContributor({ id: 'codex_frontier', concrete_model: SHIPPED.models.codex_frontier.concrete_model }, tokens));
  });

  test('the record carries every field a deferred question will need', () => {
    // The reason to write these now: a question deferred is answerable from
    // history, but a field never written is not. Deferring the ANALYSIS is
    // cheap; deferring the RECORDING destroys the history the analysis needs.
    recordContribution(ledgerPath(), {
      storyId: 'S', artifact: 'PLAN', modelId: 'claude_strong',
      concreteModel: 'x', harness: 'h', role: 'PLAN_PRODUCER', effort: 'xhigh',
      capabilityWaived: 'declared', durationMs: 1234, fallbackTrace: 'a:QUOTA',
    });
    const c = ledger().contributions[0];
    for (const field of ['role', 'model_id', 'effort', 'capability_waived',
      'duration_ms', 'fallback_trace']) {
      assert.ok(field in c, `record cannot answer questions about ${field}`);
    }
    assert.equal(c.duration_ms, 1234);
  });

  test('a blocked step leaves a trace even though it leaves no contributor', () => {
    recordBlocked(ledgerPath(), {
      storyId: 'S', role: 'QA_PLAN', blockedClass: 'PROVENANCE', reason: 'all contributed',
    });
    const l = ledger();
    assert.equal(l.blocked.length, 1);
    assert.equal(l.blocked[0].blocked_class, 'PROVENANCE');
    // Blocks are the rarest routing events; losing them loses the signal.
    recordContribution(ledgerPath(), {
      storyId: 'S', artifact: 'PLAN', modelId: 'claude_strong', concreteModel: 'x',
    });
    assert.equal(ledger().blocked.length, 1, 'a later contribution erased the block record');
  });

  test('distinct attempts are distinct rows, so a retry is not a no-op', () => {
    // Collapsing attempts made the ledger unable to say who produced the verdict
    // on disk NOW: a model recorded on an earlier failed attempt made its own
    // later successful run a no-op, and a membership check could then accept a
    // stale evaluator.
    const rec = (model, attempt) => recordContribution(ledgerPath(), {
      storyId: 'S', artifact: 'QA', modelId: model, concreteModel: `c-${model}`, attempt,
    });
    assert.equal(rec('b', 'attempt-1').recorded, true);
    assert.equal(rec('a', 'attempt-2').recorded, true);
    assert.equal(rec('b', 'attempt-3').recorded, true, 'B retrying was collapsed into its earlier row');
    assert.equal(ledger().contributions.length, 3);
  });

  test('the same model in the same attempt is still de-duplicated', () => {
    const rec = () => recordContribution(ledgerPath(), {
      storyId: 'S', artifact: 'QA', modelId: 'b', concreteModel: 'c-b', attempt: 'attempt-1',
    });
    assert.equal(rec().recorded, true);
    assert.equal(rec().recorded, false, 'a repeated write inside one attempt inflated the ledger');
  });

  test('latest contributor answers "who produced this", exclusion still unions all', () => {
    const rec = (model, attempt) => recordContribution(ledgerPath(), {
      storyId: 'S', artifact: 'CODE', modelId: model, concreteModel: `c-${model}`, attempt,
    });
    rec('first', 'a1'); rec('second', 'a2');
    assert.equal(latestContributor(ledger(), 'CODE').model_id, 'second');
    const tokens = contributorTokens(ledger(), ['CODE']);
    for (const m of ['first', 'second']) {
      assert.ok(isContributor({ id: m, concrete_model: `c-${m}` }, tokens),
        `${m} escaped the exclusion set`);
    }
  });

  test('a corrupt ledger is reported, never silently read as empty', () => {
    mkdirSync(dirname(ledgerPath()), { recursive: true });
    writeFileSync(ledgerPath(), '{ this is not json', 'utf8');
    assert.equal(ledger().corrupt, true);
    assert.throws(() => contribute('PLAN', 'claude_strong'), /corrupt/);
  });

  test('a missing ledger reads as empty, not corrupt', () => {
    const l = readLedger(join(tmp, 'nope.json'), 'ROUTER-TEST-STORY');
    assert.equal(l.corrupt, false);
    assert.deepEqual(l.contributions, []);
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('pipeline resilience', () => {
  // The interesting failures here are structural and invisible while every
  // provider is healthy. A pipeline that spends one model on the plan, a second
  // reviewing it and a third on the code has spent three — so a lane excluding
  // all of them needs a fourth. That is arithmetic, not luck, and the place to
  // learn it is a config check rather than a stalled story.
  const up = () => ({ status: 'AVAILABLE' });
  const withoutHarness = (name) => (h) => ({ status: h === name ? 'UNAVAILABLE' : 'AVAILABLE' });

  test('the nominal pipeline is fully served with everything up', () => {
    const { blocked } = simulatePipeline(SHIPPED, up);
    assert.deepEqual(blocked, []);
  });

  test('the nominal pipeline survives the loss of any single provider', () => {
    for (const h of Object.keys(SHIPPED.harnesses).filter((k) => !k.startsWith('_'))) {
      const { blocked, steps } = simulatePipeline(SHIPPED, withoutHarness(h));
      assert.deepEqual(blocked, [], `losing ${h} blocks ${blocked.join(', ')}: ${JSON.stringify(steps)}`);
    }
  });

  test('QA never lands on the implementer in any single-provider outage', () => {
    for (const h of [null, ...Object.keys(SHIPPED.harnesses).filter((k) => !k.startsWith('_'))]) {
      const { steps } = simulatePipeline(SHIPPED, h ? withoutHarness(h) : up);
      const impl = steps.find((x) => x.role === 'IMPL')?.model_id;
      for (const lane of ['QA_CODE', 'QA_REQUIREMENTS', 'QA_PLAN']) {
        const got = steps.find((x) => x.role === lane)?.model_id;
        if (got && impl) {
          assert.notEqual(got, impl, `${lane} graded its own code with ${h || 'all'} scenario`);
        }
      }
    }
  });

  test('a below-floor model never takes a decision seat at ordinary effort', () => {
    // The compensation has to hold in the scenarios where it actually gets used,
    // not just where it is declared.
    for (const h of [null, ...Object.keys(SHIPPED.harnesses).filter((k) => !k.startsWith('_'))]) {
      const { steps } = simulatePipeline(SHIPPED, h ? withoutHarness(h) : up);
      for (const step of steps) {
        if (!step.model_id) continue;
        const floor = CAPABILITY_RANK[SHIPPED.roles[step.role].minimum_capability];
        if ((CAPABILITY_RANK[SHIPPED.models[step.model_id].capability] || 0) < floor) {
          assert.ok(step.capability_waived, `${step.role} seated ${step.model_id} with no waiver`);
          assert.equal(step.effort, 'xhigh',
            `${step.role} seated below-floor ${step.model_id} at ${step.effort}`);
        }
      }
    }
  });

  test('the reviewer comes from another model family while both providers are up', () => {
    // The producer's blind spots are inherited from its training, and a sibling
    // model inherits the same ones. Nothing but this ordering enforces that —
    // provenance only guarantees a different MODEL, not a different family.
    const { steps } = simulatePipeline(SHIPPED, up);
    const prod = steps.find((x) => x.role === 'PLAN_PRODUCER');
    const rev = steps.find((x) => x.role === 'PLAN_REVIEWER');
    assert.ok(prod?.harness && rev?.harness);
    assert.notEqual(rev.harness, prod.harness,
      'the plan reviewer shares a provider with the producer while an independent one was available');
  });

  test('the plan producer and its reviewer are never the same model', () => {
    for (const h of [null, ...Object.keys(SHIPPED.harnesses).filter((k) => !k.startsWith('_'))]) {
      const { steps } = simulatePipeline(SHIPPED, h ? withoutHarness(h) : up);
      const prod = steps.find((x) => x.role === 'PLAN_PRODUCER')?.model_id;
      const rev = steps.find((x) => x.role === 'PLAN_REVIEWER')?.model_id;
      if (prod && rev) assert.notEqual(rev, prod, `the producer reviewed its own plan (${h || 'all'})`);
    }
  });

  test('the report covers every provider, so no outage is unexamined', () => {
    const report = resilienceReport(SHIPPED);
    assert.ok(report.all_available);
    for (const h of Object.keys(SHIPPED.harnesses).filter((k) => !k.startsWith('_'))) {
      assert.ok(report[`without_${h}`], `no scenario for losing ${h}`);
    }
  });

  test('a registry too small for the pipeline is reported, not discovered later', () => {
    // Strip the config to one provider's three models and drop the QA policy
    // back to excluding the plan as well: the lane becomes unservable, and the
    // simulation has to say so.
    const cfg = structuredClone(SHIPPED);
    for (const [id, m] of Object.entries(cfg.models)) {
      if (!id.startsWith('_') && m.harness !== 'claude') delete cfg.models[id];
    }
    for (const r of Object.values(cfg.roles)) {
      if (Array.isArray(r.candidates)) r.candidates = r.candidates.filter((c) => cfg.models[c]);
    }
    cfg.roles.QA_PLAN.evaluates = ['PLAN', 'CODE'];
    const { blocked } = simulatePipeline(cfg, up);
    assert.ok(blocked.includes('QA_PLAN'),
      'three models cannot serve a lane that excludes plan and code contributors both');
  });
});

// ───────────────────────────────────────────────────────────────────────────
describe('verdict aggregation', () => {
  const required = SHIPPED.verdict.required_lanes;
  const all = (v) => Object.fromEntries(required.map((l) => [l, v]));

  test('all PASS is PASS', () => {
    assert.equal(aggregateVerdict(all('PASS'), required).verdict, 'PASS');
  });

  test('any FAIL wins over ESCALATE', () => {
    const lanes = { ...all('PASS'), [required[0]]: 'FAIL', [required[1]]: 'ESCALATE' };
    assert.equal(aggregateVerdict(lanes, required).verdict, 'FAIL');
  });

  test('any ESCALATE without a FAIL is ESCALATE', () => {
    const lanes = { ...all('PASS'), [required[0]]: 'ESCALATE' };
    assert.equal(aggregateVerdict(lanes, required).verdict, 'ESCALATE');
  });

  test('a lane that did not report escalates instead of passing', () => {
    const lanes = all('PASS');
    delete lanes[required[0]];
    const r = aggregateVerdict(lanes, required);
    assert.equal(r.verdict, 'ESCALATE');
    assert.deepEqual(r.missing, [required[0]]);
  });

  test('an unrecognised verdict escalates', () => {
    const lanes = { ...all('PASS'), [required[0]]: 'probably fine' };
    assert.equal(aggregateVerdict(lanes, required).verdict, 'ESCALATE');
  });
});
