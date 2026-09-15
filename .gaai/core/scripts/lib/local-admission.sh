#!/usr/bin/env bash
# Portable local admission orchestration. Project policy remains base-held;
# this adapter only resolves, executes fixed argv, rechecks and seals evidence.

LOCAL_ADMISSION_OUTCOME=""
LOCAL_ADMISSION_RECEIPT_PATH=""

_local_admission_cleanup() { rm -rf "$1" 2>/dev/null || true; }

_local_admission_seal() {
  local executor="$1" boundary="$2" story="$3" plan="$4" results="$5"
  local results_digest="$6" binding_digest="$7" outcome="$8" limit="$9" receipt_dir="${10}"
  local tmp_receipt="${receipt_dir}/.local-admission-${story}-${boundary}.tmp.$$"
  local seal_rc
  LOCAL_ADMISSION_RECEIPT_PATH="${receipt_dir}/.local-admission-${story}-${boundary}.json"
  rm -f "$tmp_receipt" 2>/dev/null || true
  if node "$executor" --mode seal --boundary "$boundary" --story-id "$story" \
      --plan "$plan" --results "$results" --outcome "$outcome" \
      --results-digest "$results_digest" --binding-digest "$binding_digest" \
      --max-bytes "$limit" --output "$tmp_receipt"; then
    seal_rc=0
  else
    seal_rc=$?
  fi
  if (( seal_rc != 0 )); then
    if (( seal_rc == 3 )); then LOCAL_ADMISSION_OUTCOME="blocked:receipt_too_large"
    else LOCAL_ADMISSION_OUTCOME="blocked:receipt_seal_failed"; fi
    rm -f "$tmp_receipt" "$LOCAL_ADMISSION_RECEIPT_PATH" 2>/dev/null || true
    LOCAL_ADMISSION_RECEIPT_PATH=""; return 1
  fi
  if ! mv "$tmp_receipt" "$LOCAL_ADMISSION_RECEIPT_PATH" 2>/dev/null; then
    LOCAL_ADMISSION_OUTCOME="blocked:receipt_write_failed"
    rm -f "$tmp_receipt" "$LOCAL_ADMISSION_RECEIPT_PATH" 2>/dev/null || true
    LOCAL_ADMISSION_RECEIPT_PATH=""; return 1
  fi
}

_local_admission_reject_with_plan() {
  local executor="$1" boundary="$2" story="$3" plan="$4" results="$5"
  local outcome="$6" limit="$7" receipt_dir="$8"
  local results_digest binding_digest
  printf '[]\n' > "$results" 2>/dev/null || return 1
  results_digest=$(node -e 'process.stdout.write(require("crypto").createHash("sha256").update("[]").digest("hex"))') || return 1
  binding_digest=$(node -e 'const p=require(process.argv[1]);process.stdout.write(p.binding_digest||"")' "$plan") || return 1
  _local_admission_seal "$executor" "$boundary" "$story" "$plan" "$results" \
    "$results_digest" "$binding_digest" "$outcome" "$limit" "$receipt_dir"
}

# Record why an admission run was judged stale, next to the receipts.
#
# "stale_evidence" is reported for three different situations: the re-resolve
# produced no output at all, it produced output with no binding_digest, or it
# produced a binding that differs from the bound one. Only the third is actual
# staleness. The three are indistinguishable downstream, the verify path deletes
# the receipt, and the scratch directory is removed — so a blocked run leaves
# nothing that says which happened, or whether the base moved at all.
#
# Evidence only: no gate semantics, no outcome renamed, failures ignored.
_local_admission_note_stale() {
  local receipt_dir="$1" story="$2" boundary="$3" stage="$4"
  local bound="$5" observed="$6" summary_file="$7"
  local bound_base="$8" bound_head="$9" fresh_base="${10}" fresh_head="${11}"
  local note="${receipt_dir}/.local-admission-${story}-${boundary}.stale.json" why reason=""
  # When the re-resolve rejected the candidate, the resolver wrote its reason
  # into the summary file. That word — candidate_unsealed, repository_mismatch,
  # candidate_stale — is the finding, so it travels with the note.
  [[ -s "$summary_file" ]] && reason=$(node -e 'try{const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(s.status==="resolved"?"":String(s.reason||""))}catch{}' "$summary_file" 2>/dev/null || true)
  if [[ ! -s "$summary_file" ]]; then why=resolver_no_output
  elif [[ -z "$observed" ]]; then why=resolver_no_binding
  elif [[ "$bound_base" != "$fresh_base" ]]; then why=base_advanced
  elif [[ "$bound_head" != "$fresh_head" ]]; then why=head_advanced
  else why=binding_differs_without_ref_change; fi
  ( umask 077; printf '{"story":"%s","boundary":"%s","stage":"%s","why":"%s","resolver_reason":"%s",' \
      "$story" "$boundary" "$stage" "$why" "$reason"
    printf '"bound_binding":"%s","observed_binding":"%s",' "$bound" "$observed"
    printf '"bound_base":"%s","fresh_base":"%s","bound_head":"%s","fresh_head":"%s",' \
      "$bound_base" "$fresh_base" "$bound_head" "$fresh_head"
    printf '"recorded_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ) > "$note" 2>/dev/null || true
  printf '[LOCAL-ADMISSION] story=%s boundary=%s stale_reason=%s resolver_reason=%s note=%s\n' \
    "$story" "$boundary" "$why" "${reason:-none}" "$note"
}

_local_admission_resolve() {
  local resolver="$1" repo="$2" base_ref="$3" base_sha="$4" head_sha="$5"
  local policy="$6" risk="$7" output="$8"
  local args=(--repo "$repo" --base-ref "$base_ref" --base-sha "$base_sha"
    --head-sha "$head_sha" --policy "$policy" --output "$output")
  [[ -n "$risk" ]] && args+=(--risk-inputs "$risk")
  node "$resolver" "${args[@]}"
}

_run_local_admission() {
  local boundary="$1" story="$2" repo="$3" base_ref="$4" receipt_dir="$5"
  local lib_dir resolver executor policy risk limit result_limit result_bytes limits scratch plan fresh verify results target_receipt seal_plan seal_binding
  local base_sha head_sha binding_digest results_digest fresh_base fresh_head fresh_summary fresh_binding verify_summary verify_binding reason outcome
  LOCAL_ADMISSION_OUTCOME="blocked:unknown"; LOCAL_ADMISSION_RECEIPT_PATH=""
  case "$boundary" in pre_qa|final) ;; *) LOCAL_ADMISSION_OUTCOME="blocked:boundary_invalid"; return 1 ;; esac
  [[ "$story" =~ ^[A-Za-z0-9._-]+$ ]] \
    || { LOCAL_ADMISSION_OUTCOME="blocked:story_id_invalid"; return 1; }
  for tool in git node mktemp mkdir mv rm; do command -v "$tool" >/dev/null 2>&1 \
    || { LOCAL_ADMISSION_OUTCOME="blocked:runtime_missing:${tool}"; return 1; }; done
  mkdir -p "$receipt_dir" 2>/dev/null \
    || { LOCAL_ADMISSION_OUTCOME="blocked:receipt_storage_unavailable"; return 1; }
  target_receipt="${receipt_dir}/.local-admission-${story}-${boundary}.json"
  rm -f "$target_receipt" 2>/dev/null \
    || { LOCAL_ADMISSION_OUTCOME="blocked:receipt_storage_unavailable"; return 1; }
  policy="${GAAI_LOCAL_ADMISSION_POLICY_PATH:-.gaai/project/ci/local-admission.json}"
  risk="${GAAI_LOCAL_ADMISSION_RISK_INPUTS_PATH:-}"
  [[ -z "$risk" || -f "$risk" ]] \
    || { LOCAL_ADMISSION_OUTCOME="blocked:risk_inputs_missing"; return 1; }
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/gaai-local-admission.XXXXXX") \
    || { LOCAL_ADMISSION_OUTCOME="blocked:temporary_storage_unavailable"; return 1; }
  chmod 700 "$scratch" 2>/dev/null || { LOCAL_ADMISSION_OUTCOME="blocked:temporary_storage_unavailable"; _local_admission_cleanup "$scratch"; return 1; }
  plan="$scratch/plan.json"; fresh="$scratch/fresh.json"; verify="$scratch/verify.json"; results="$scratch/results.json"
  # Node canonicalizes symlinked entrypoint paths before exposing import.meta.url.
  # Resolve the shell-side path physically too, otherwise aliases such as macOS
  # /var -> /private/var make the resolver/executor CLI guards silently skip main().
  lib_dir=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
  resolver="$lib_dir/local-admission-resolver.mjs"; executor="$lib_dir/local-admission-executor.mjs"

  if ! git -C "$repo" fetch origin "$base_ref" --quiet 2>/dev/null; then
    LOCAL_ADMISSION_OUTCOME="blocked:base_fetch_failed"; _local_admission_cleanup "$scratch"; return 1
  fi
  base_sha=$(git -C "$repo" rev-parse "origin/$base_ref" 2>/dev/null) \
    && head_sha=$(git -C "$repo" rev-parse HEAD 2>/dev/null) \
    || { LOCAL_ADMISSION_OUTCOME="blocked:candidate_unresolvable"; _local_admission_cleanup "$scratch"; return 1; }
  _local_admission_resolve "$resolver" "$repo" "$base_ref" "$base_sha" "$head_sha" \
    "$policy" "$risk" "$plan" >/dev/null 2>&1 || true
  if [[ ! -s "$plan" ]] || [[ "$(node -e 'const p=require(process.argv[1]);process.stdout.write(p.status||"")' "$plan" 2>/dev/null)" != resolved ]]; then
    reason=$(node -e 'const p=require(process.argv[1]);process.stdout.write(p.reason||"resolver_failed")' "$plan" 2>/dev/null || echo resolver_failed)
    LOCAL_ADMISSION_OUTCOME="blocked:${reason}"
    _local_admission_cleanup "$scratch"; return 1
  fi
  limits=$(node -e 'const p=require(process.argv[1]);console.log(`${p.limits?.max_receipt_bytes||""}\t${p.limits?.max_result_bytes||""}`)' "$plan" 2>/dev/null || true)
  IFS=$'\t' read -r limit result_limit <<<"$limits"
  [[ "$limit" =~ ^[1-9][0-9]*$ && "$result_limit" =~ ^[1-9][0-9]*$ ]] \
    || { LOCAL_ADMISSION_OUTCOME="blocked:policy_limits_invalid"; _local_admission_cleanup "$scratch"; return 1; }
  binding_digest=$(node -e 'const p=require(process.argv[1]);process.stdout.write(p.binding_digest)' "$plan")
  seal_plan="$plan"; seal_binding="$binding_digest"
  if ! results_digest=$(node "$executor" --mode execute --plan "$plan" --repo "$repo" --output "$results"); then
    LOCAL_ADMISSION_OUTCOME="blocked:execution_failed"
    _local_admission_reject_with_plan "$executor" "$boundary" "$story" "$plan" "$results" \
      "$LOCAL_ADMISSION_OUTCOME" "$limit" "$receipt_dir" || true
    _local_admission_cleanup "$scratch"; return 1
  fi
  result_bytes=$(node -e 'const fs=require("fs");const s=fs.readFileSync(process.argv[1],"utf8").trimEnd();process.stdout.write(String(Buffer.byteLength(s)))' "$results" 2>/dev/null || true)
  if [[ ! "$result_bytes" =~ ^[0-9]+$ || "$result_bytes" -gt "$result_limit" ]]; then
    LOCAL_ADMISSION_OUTCOME="blocked:results_too_large"
    _local_admission_seal "$executor" "$boundary" "$story" "$plan" "$results" \
      "$results_digest" "$binding_digest" "$LOCAL_ADMISSION_OUTCOME" "$limit" "$receipt_dir" || true
    _local_admission_cleanup "$scratch"; return 1
  fi
  if ! git -C "$repo" fetch origin "$base_ref" --quiet 2>/dev/null; then
    outcome="blocked:base_fetch_failed"
  else
    fresh_base=$(git -C "$repo" rev-parse "origin/$base_ref" 2>/dev/null || true)
    fresh_head=$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)
    fresh_summary=$(_local_admission_resolve "$resolver" "$repo" "$base_ref" "$fresh_base" "$fresh_head" \
      "$policy" "$risk" "$fresh" 2>/dev/null || true)
    fresh_binding=$(node -e 'const s=JSON.parse(process.argv[1]||"{}");process.stdout.write(s.binding_digest||"")' "$fresh_summary" 2>/dev/null || true)
    if [[ ! -s "$fresh" || -z "$fresh_binding" || "$fresh_binding" != "$binding_digest" ]]; then
      _local_admission_note_stale "$receipt_dir" "$story" "$boundary" post_run \
        "$binding_digest" "$fresh_binding" "$fresh" \
        "$base_sha" "$head_sha" "$fresh_base" "$fresh_head" || true
      outcome="blocked:stale_evidence"
    else
      seal_plan="$fresh"; seal_binding="$fresh_binding"
      outcome=$(node -e 'const r=require(process.argv[1]);const o=r.find(x=>x.outcome!=="passed")?.outcome;process.stdout.write(o?`blocked:command_${o}`:"pass")' "$results")
    fi
  fi
  LOCAL_ADMISSION_OUTCOME="$outcome"
  _local_admission_seal "$executor" "$boundary" "$story" "$seal_plan" "$results" \
    "$results_digest" "$seal_binding" "$outcome" "$limit" "$receipt_dir" || { _local_admission_cleanup "$scratch"; return 1; }
  if git -C "$repo" fetch origin "$base_ref" --quiet 2>/dev/null; then
    fresh_base=$(git -C "$repo" rev-parse "origin/$base_ref" 2>/dev/null || true)
    fresh_head=$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)
    verify_summary=$(_local_admission_resolve "$resolver" "$repo" "$base_ref" "$fresh_base" "$fresh_head" \
      "$policy" "$risk" "$verify" 2>/dev/null || true)
    verify_binding=$(node -e 'const s=JSON.parse(process.argv[1]||"{}");process.stdout.write(s.binding_digest||"")' "$verify_summary" 2>/dev/null || true)
  fi
  if [[ -z "${verify_binding:-}" || "$verify_binding" != "$seal_binding" ]]; then
    _local_admission_note_stale "$receipt_dir" "$story" "$boundary" post_seal \
      "$seal_binding" "${verify_binding:-}" "$verify" \
      "$base_sha" "$head_sha" "$fresh_base" "$fresh_head" || true
    LOCAL_ADMISSION_OUTCOME="blocked:stale_evidence"
    rm -f "$LOCAL_ADMISSION_RECEIPT_PATH" 2>/dev/null || true; LOCAL_ADMISSION_RECEIPT_PATH=""
    _local_admission_cleanup "$scratch"; return 1
  fi
  _local_admission_cleanup "$scratch"
  printf '[LOCAL-ADMISSION] story=%s boundary=%s outcome=%s receipt=%s\n' \
    "$story" "$boundary" "$LOCAL_ADMISSION_OUTCOME" "$LOCAL_ADMISSION_RECEIPT_PATH"
  [[ "$LOCAL_ADMISSION_OUTCOME" == pass ]]
}
