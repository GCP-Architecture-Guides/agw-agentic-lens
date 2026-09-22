#!/usr/bin/env bash
# Agentic-Prism Deployment Controller — deploy agents in parallel.
# 1. Source versions.env
# 2. Remove leftover agents/*_tmp* staging dirs
# 3. Inject MODEL_VERSION into all agent.yaml files
# 4. Optionally skip agents that already have an engine (SKIP_EXISTING=1)
# 5. Ensure identity_type=AGENT_IDENTITY (per-agent identity, no shared service account)
# 6. For each agent: if an engine with same display_name exists, pass --agent_engine_id so ADK UPDATES instead of CREATES (avoids duplicates).
# 7. Deploy selected agents in parallel (limit: DEPLOY_PARALLEL, default 8)
#
# Usage (from repo root):
#   ./deploy.sh                        # Deploy ALL agents
#   ./deploy.sh xray_manager xray_librarian ...   # Deploy only listed agents
#   SKIP_EXISTING=1 ./deploy.sh        # Deploy only agents that don't already exist
#   SKIP_EXISTING=1 ./deploy.sh xray_manager xray_librarian xray_architect xray_specialist xray_auditor  # X-Ray only, skip existing
#
# Optional: DEPLOY_PARALLEL=4 ./deploy.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
# Canonical agent source only. Legacy agents live in old_files/agents/ — do not deploy from there.
AGENTS_DIR="$ROOT_DIR/agentic-lens/agents"
ADK_DIR="$ROOT_DIR/agentic-lens"
MAX_PARALLEL="${DEPLOY_PARALLEL:-8}"
DEBUG_LOG="$ROOT_DIR/.cursor/debug-0ff22e.log"
_debug_log() { python3 -c "import json,time,sys; d=json.loads(sys.argv[4]) if len(sys.argv)>4 and sys.argv[4] else {}; open('$DEBUG_LOG','a').write(json.dumps({'sessionId':'0ff22e','location':sys.argv[2],'message':sys.argv[1],'data':d,'timestamp':int(time.time()*1000),'hypothesisId':sys.argv[3]})+\n')" "$1" "$2" "$3" "${4:-{}}" 2>/dev/null || true; }
# #region agent log
# #endregion

if [[ "$AGENTS_DIR" == *"old_files"* ]]; then
  echo "ERROR: AGENTS_DIR must not point at old_files. Use agentic-lens/agents only."
  exit 1
fi

# Full roster: Supervisor + Chat + Department Heads (eng_lead, xray_manager, events) + specialists
# MODEL_VERSION (e.g. gemini-3.0-pro) is injected into each agent.yaml during deploy
# Agent folder names use underscores (project standard).
AGENTS=("supervisor" "chat" "eng_lead" "eng_scout" "eng_coder" "eng_quality_and_security_reviewer" "xray_manager" "xray_librarian" "xray_architect" "xray_specialist" "xray_auditor" "events")
ALL_AGENTS=("${AGENTS[@]}")

# ---------------------------------------------------------------------------
# 1. Source Config
# ---------------------------------------------------------------------------
if [[ ! -f "$ROOT_DIR/versions.env" ]]; then
  echo "ERROR: versions.env not found at $ROOT_DIR/versions.env"
  exit 1
fi
# shellcheck source=versions.env
source "$ROOT_DIR/versions.env"

if [[ -z "$MODEL_VERSION" ]]; then
  echo "ERROR: MODEL_VERSION not set in versions.env"
  exit 1
fi
if [[ -z "$PROJECT_ID" ]]; then
  echo "ERROR: PROJECT_ID not set in versions.env"
  exit 1
fi
if [[ -z "$REGION" ]]; then
  echo "ERROR: REGION not set in versions.env"
  exit 1
fi

# Resolve ORG_ID for IAM principal (session roles); required for deploy_one IAM bindings
export ORG_ID="${ORG_ID:-}"
# Export gateway paths so _gateway_patch.py (venv .pth hook) picks them up
export AGENT_GATEWAY_INGRESS="${AGENT_GATEWAY_INGRESS:-}"
export AGENT_GATEWAY_EGRESS="${AGENT_GATEWAY_EGRESS:-}"
if [[ -z "$ORG_ID" ]]; then
  ORG_ID=$(gcloud projects describe "$PROJECT_ID" --format='value(parent)' 2>/dev/null | sed -n 's|^organizations/||p' || true)
fi
if [[ -z "$ORG_ID" ]]; then
  echo "WARNING: ORG_ID not set and could not be resolved from project. Session IAM bindings may fail."
fi

# ---------------------------------------------------------------------------
# 2. Apply ADK patch if venv exists (avoids ImportError in deployed engines)
# ---------------------------------------------------------------------------
if [[ -x "$ROOT_DIR/agentic-lens/.venv/bin/python" && -f "$ROOT_DIR/scripts/patch_adk_config_agent_utils.py" ]]; then
  "$ROOT_DIR/agentic-lens/.venv/bin/python" "$ROOT_DIR/scripts/patch_adk_config_agent_utils.py" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 3. Clean up leftover staging dirs
# ---------------------------------------------------------------------------
if [[ -d "$AGENTS_DIR" ]]; then
  for stale in "$AGENTS_DIR"/*_tmp*; do
    if [[ -d "$stale" ]]; then
      echo "   Removing leftover staging dir: $(basename "$stale")"
      rm -rf "$stale"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 4. Agent list: from args (deploy only these) or ALL_AGENTS
# ---------------------------------------------------------------------------
if [[ $# -ge 1 ]]; then
  AGENTS=("$@")
  echo "Deploying only requested agents (${#AGENTS[@]}): ${AGENTS[*]}"
else
  AGENTS=("${ALL_AGENTS[@]}")
fi

# ---------------------------------------------------------------------------
# 5. Skip existing: if SKIP_EXISTING=1, remove agents that already have an engine
# ---------------------------------------------------------------------------
if [[ -n "${SKIP_EXISTING:-}" ]] && [[ "${SKIP_EXISTING}" != "0" ]]; then
  existing=""
  if [[ -x "$ROOT_DIR/agentic-lens/.venv/bin/python" ]]; then
    existing=$("$ROOT_DIR/agentic-lens/.venv/bin/python" "$ROOT_DIR/scripts/list_existing_agent_engines.py" 2>/dev/null || true)
  else
    existing=$(python3 "$ROOT_DIR/scripts/list_existing_agent_engines.py" 2>/dev/null || true)
  fi
  if [[ -n "$existing" ]]; then
    to_deploy=()
    for agent in "${AGENTS[@]}"; do
      # Skip if display_name exact match or normalized (hyphen→underscore) matches agent or agentic_lens_<agent>
      norm_existing=$(echo "$existing" | tr '-' '_')
      if echo "$existing" | grep -Fxq "$agent" 2>/dev/null \
         || echo "$norm_existing" | grep -Fxq "$agent" 2>/dev/null \
         || echo "$norm_existing" | grep -Fxq "agentic_lens_${agent}" 2>/dev/null; then
        echo "   Skipping $agent (already exists)"
      else
        to_deploy+=("$agent")
      fi
    done
    AGENTS=("${to_deploy[@]}")
  fi
fi

if [[ ${#AGENTS[@]} -eq 0 ]]; then
  echo "No agents to deploy (all already exist or list empty)."
  exit 0
fi

# #region agent log
_debug_log "deploy_agents_ready" "deploy.sh:before_config" "ENTRY" "{\"n_agents\":${#AGENTS[@]},\"project_id\":\"$PROJECT_ID\",\"region\":\"$REGION\"}"
# #endregion

# ---------------------------------------------------------------------------
# 5. Inject MODEL_VERSION and ensure AGENT_IDENTITY for each agent
# ---------------------------------------------------------------------------
ADK_CMD="adk"
if [[ -x "$ADK_DIR/.venv/bin/adk" ]]; then
  ADK_CMD="$ADK_DIR/.venv/bin/adk"
fi

# Per-agent model is set in each agent.yaml (Flash-for-speed vs Pro-for-reasoning). Do NOT overwrite.
# Flash: supervisor, eng_scout, eng_quality_and_security_reviewer, events, chat. Pro: eng_coder, xray_manager (+ X-Ray sub-agents).
echo "Using per-agent model from agent.yaml (gemini-2.5-flash | gemini-2.5-pro)..."

# CMEK: resolve per-department key for an agent (one key ring per department in us-west1).
get_cmek_key_for_agent() {
  local agent="$1"
  case "$agent" in
    supervisor) echo "${AGENT_ENGINE_KMS_KEY_SUPERVISOR:-}" ;;
    chat) echo "${AGENT_ENGINE_KMS_KEY_CHAT:-}" ;;
    eng_lead|eng_scout|eng_coder|eng_quality_and_security_reviewer) echo "${AGENT_ENGINE_KMS_KEY_ENGINEERING:-}" ;;
    xray_manager|xray_librarian|xray_architect|xray_specialist|xray_auditor) echo "${AGENT_ENGINE_KMS_KEY_XRAY:-}" ;;
    events) echo "${AGENT_ENGINE_KMS_KEY_EVENTS:-}" ;;
    *) echo "" ;;
  esac
}

echo "Ensuring identity_type=AGENT_IDENTITY, deployment config, tracing env_vars, and per-department CMEK..."
DEPLOY_CONFIG='{"min_instances": 1, "max_instances": 2, "resource_limits": {"cpu": "4", "memory": "8Gi"}, "container_concurrency": 2}'
for agent in "${AGENTS[@]}"; do
  agent_dir="$AGENTS_DIR/$agent"
  if [[ -d "$agent_dir" ]]; then
    config_file="$agent_dir/.agent_engine_config.json"
    kms_key="$(get_cmek_key_for_agent "$agent")"
    # Plan: single key for all agents when AGENT_ENGINE_KMS_KEY_NAME is set
    if [[ -n "${AGENT_ENGINE_KMS_KEY_NAME:-}" ]]; then
      kms_key="${AGENT_ENGINE_KMS_KEY_NAME}"
    fi
    if [[ -x "$ADK_DIR/.venv/bin/python" ]]; then
      "$ADK_DIR/.venv/bin/python" -c '
import json, sys
path = sys.argv[1]
deploy_cfg = json.loads(sys.argv[2])
kms_key = (sys.argv[3] or "").strip() if len(sys.argv) > 3 else ""
proj_id = sys.argv[5].strip()
region = sys.argv[6].strip()
try:
  with open(path) as f: c = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
  c = {}
c["identity_type"] = "AGENT_IDENTITY"
c["min_instances"] = deploy_cfg["min_instances"]
c["max_instances"] = deploy_cfg["max_instances"]
c["resource_limits"] = deploy_cfg["resource_limits"]
c["container_concurrency"] = deploy_cfg["container_concurrency"]
c["env_vars"] = {**(c.get("env_vars") or {}), "PYTHONPATH": f"/code/{sys.argv[4].strip()}_staged", "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY": "true", "OTEL_SEMCONV_STABILITY_OPT_IN": "gen_ai_latest_experimental", "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT": "EVENT_ONLY", "GOOGLE_GENAI_USE_VERTEXAI": "true"}
# agent_gateway_config is preserved — gemini-corp-ingress/egress-gateway required for governed access
if kms_key:
  c["encryption_spec"] = {"kms_key_name": kms_key}
else:
  c.pop("encryption_spec", None)
with open(path, "w") as f: json.dump(c, f, indent=2)
' "$config_file" "$DEPLOY_CONFIG" "$kms_key" "$agent" "$PROJECT_ID" "$REGION" 2>/dev/null || true
    else
      base_json="{\"identity_type\": \"AGENT_IDENTITY\", \"min_instances\": 1, \"max_instances\": 2, \"resource_limits\": {\"cpu\": \"4\", \"memory\": \"8Gi\"}, \"container_concurrency\": 2, \"env_vars\": {\"PYTHONPATH\": \"/code/${agent}_staged\", \"GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY\": \"true\", \"OTEL_SEMCONV_STABILITY_OPT_IN\": \"gen_ai_latest_experimental\", \"OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT\": \"EVENT_ONLY\", \"GOOGLE_GENAI_USE_VERTEXAI\": \"true\"}}"
      echo "${base_json}" > "$config_file"
      if [[ -n "$kms_key" ]]; then
        python3 -c "
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
d[\"encryption_spec\"] = {\"kms_key_name\": sys.argv[2]}
with open(sys.argv[1], \"w\") as f: json.dump(d, f, indent=2)
" "$config_file" "$kms_key" 2>/dev/null || true
      else
        python3 -c "
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
d.pop(\"encryption_spec\", None)
with open(sys.argv[1], \"w\") as f: json.dump(d, f, indent=2)
" "$config_file" 2>/dev/null || true
      fi
    fi
  fi
done

# Events concierge: Vertex RAG corpus/project/location must be in Agent Engine env (containers don't load .env).
if [[ -f "$ROOT_DIR/.env" && -d "$AGENTS_DIR/events" ]]; then
  _merge_py="$ROOT_DIR/scripts/merge_events_rag_env.py"
  if [[ -f "$_merge_py" ]]; then
    if [[ -x "$ADK_DIR/.venv/bin/python" ]]; then
      "$ADK_DIR/.venv/bin/python" "$_merge_py" "$ROOT_DIR/.env" "$AGENTS_DIR/events/.agent_engine_config.json" || true
    else
      python3 "$_merge_py" "$ROOT_DIR/.env" "$AGENTS_DIR/events/.agent_engine_config.json" || true
    fi
  fi
fi

# Department heads (eng_lead, xray_manager) call peer engines by resource name; agent identity
# cannot rely on ReasoningEngine.list() at runtime — inject IDs before deploy.
_merge_peer="$ROOT_DIR/scripts/merge_peer_engine_env.py"
if [[ -f "$_merge_peer" ]]; then
  if [[ -x "$ADK_DIR/.venv/bin/python" ]]; then
    "$ADK_DIR/.venv/bin/python" "$_merge_peer" "$ROOT_DIR" || true
  else
    python3 "$_merge_peer" "$ROOT_DIR" || true
  fi
fi

# All agents: GCP_PROJECT_ID / GCP_LOCATION / REGION / GOOGLE_GENAI_USE_VERTEXAI in env (runtime bootstrap mirrors GOOGLE_CLOUD_*).
_merge_agent_vertex="$ROOT_DIR/scripts/merge_engineering_vertex_env.py"
if [[ -f "$_merge_agent_vertex" ]]; then
  if [[ -x "$ADK_DIR/.venv/bin/python" ]]; then
    "$ADK_DIR/.venv/bin/python" "$_merge_agent_vertex" "$ROOT_DIR" || true
  else
    python3 "$_merge_agent_vertex" "$ROOT_DIR" || true
  fi
fi

if [[ "${SKIP_PREFLIGHT:-0}" == "1" ]]; then
  echo "SKIP_PREFLIGHT=1 — skipping preflight_vertex_env (greenfield step 1: peers not deployed yet)."
elif [[ -x "$ROOT_DIR/agentic-lens/.venv/bin/python" ]]; then
  "$ROOT_DIR/agentic-lens/.venv/bin/python" "$ROOT_DIR/scripts/preflight_vertex_env.py" || {
    echo "Preflight failed (GCP/Vertex env or eng_lead peer IDs). Fix merge scripts / versions.env then retry."
    exit 1
  }
else
  python3 "$ROOT_DIR/scripts/preflight_vertex_env.py" || {
    echo "Preflight failed (GCP/Vertex env or eng_lead peer IDs). Fix merge scripts / versions.env then retry."
    exit 1
  }
fi

# Optional: verify CMEK key reference (single key or per department)
if [[ -n "${AGENT_ENGINE_KMS_KEY_NAME:-}" ]]; then
  echo "CMEK: using single key for all agents: ${AGENT_ENGINE_KMS_KEY_NAME##*/}"
elif [[ -n "${AGENT_ENGINE_KMS_KEY_SUPERVISOR:-}${AGENT_ENGINE_KMS_KEY_CHAT:-}${AGENT_ENGINE_KMS_KEY_ENGINEERING:-}${AGENT_ENGINE_KMS_KEY_XRAY:-}${AGENT_ENGINE_KMS_KEY_EVENTS:-}" ]]; then
  echo "CMEK key assignment (per department):"
  for agent in "${AGENTS[@]}"; do
    if [[ -d "$AGENTS_DIR/$agent" ]]; then
      key="$(get_cmek_key_for_agent "$agent")"
      if [[ -n "$key" ]]; then
        echo "  $agent -> ${key##*/}"
      fi
    fi
  done
fi

# ---------------------------------------------------------------------------
# 6. Deploy selected agents in parallel (max DEPLOY_PARALLEL at a time)
# ---------------------------------------------------------------------------
result_dir=$(mktemp -d)
trap 'rm -rf "$result_dir"' EXIT

deploy_one() {
  local agent="$1"
  local deploy_out sup_bundle deploy_root deploy_relpath
  deploy_out=$(mktemp)
  sup_bundle=""
  deploy_root="$ADK_DIR"
  deploy_relpath="agents/$agent"
  # #region agent log
  _debug_log "deploy_one_enter" "deploy.sh:deploy_one" "H1_H2" "{\"agent\":\"$agent\"}"
  # #endregion
  # If an engine with this display_name already exists, pass its ID so ADK UPDATES instead of CREATES (avoids duplicates).
  # Set FORCE_CREATE=1 to skip lookup and force a fresh CREATE (e.g. when old engine is stuck in gateway bind/unbind).
  existing_id=""
  if [[ "${FORCE_CREATE:-}" == "1" ]]; then
    echo "   [FORCE_CREATE] Skipping existing engine lookup — will create fresh."
  elif [[ -x "$ROOT_DIR/agentic-lens/.venv/bin/python" ]]; then
    existing_id=$("$ROOT_DIR/agentic-lens/.venv/bin/python" "$ROOT_DIR/scripts/get_agent_engine_id.py" "$agent" 2>/dev/null || true)
  else
    existing_id=$(python3 "$ROOT_DIR/scripts/get_agent_engine_id.py" "$agent" 2>/dev/null || true)
  fi
  # #region agent log
  _debug_log "get_engine_id_done" "deploy.sh:after_get_id" "H1" "{\"agent\":\"$agent\",\"has_existing_id\":${#existing_id}}"
  # #endregion
  adk_extra=""
  if [[ -n "$existing_id" ]]; then
    adk_extra="--agent_engine_id=$existing_id"
  fi
  # #region agent log
  _debug_log "adk_deploy_start" "deploy.sh:before_adk" "H2" "{\"agent\":\"$agent\"}"
  # #endregion
  # Per-agent timeout so one hung deploy does not block forever (H2: adk deploy can hang with no error).
  ADK_TIMEOUT="${ADK_DEPLOY_TIMEOUT:-900}"
  if command -v timeout >/dev/null 2>&1 && [[ "$ADK_TIMEOUT" -gt 0 ]]; then
    adk_wrap="timeout $ADK_TIMEOUT"
  else
    adk_wrap=""
  fi
  # Supervisor sub_agents load from peer_agents.* (see root_agent.yaml). ADK only uploads the
  # supervisor folder, so we vendor department packages under supervisor/peer_agents/ in a temp tree.
  if [[ "$agent" == "supervisor" ]]; then
    echo "   [bundle] Vendoring department agents into supervisor/peer_agents/ for Vertex..."
    sup_bundle=$(mktemp -d)
    mkdir -p "$sup_bundle/ws/agents"
    if [[ -f "$ADK_DIR/adk.yaml" ]]; then
      cp -a "$ADK_DIR/adk.yaml" "$sup_bundle/ws/"
    fi
    if [[ -f "$AGENTS_DIR/__init__.py" ]]; then
      cp -a "$AGENTS_DIR/__init__.py" "$sup_bundle/ws/agents/"
    fi
    rm -rf "$sup_bundle/ws/agents/supervisor"
    cp -a "$AGENTS_DIR/supervisor" "$sup_bundle/ws/agents/supervisor"
    mkdir -p "$sup_bundle/ws/agents/supervisor/peer_agents"
    : >"$sup_bundle/ws/agents/supervisor/peer_agents/__init__.py"
    for sub in eng_lead eng_scout eng_coder eng_quality_and_security_reviewer xray_manager xray_librarian xray_architect xray_specialist xray_auditor events chat; do
      if [[ -d "$AGENTS_DIR/$sub" ]]; then
        rm -rf "$sup_bundle/ws/agents/supervisor/peer_agents/$sub"
        cp -a "$AGENTS_DIR/$sub" "$sup_bundle/ws/agents/supervisor/peer_agents/"
      fi
    done
    find "$sup_bundle/ws/agents/supervisor" -type d -name '*_tmp*' -exec rm -rf {} + 2>/dev/null || true
    # Union of requirements (supervisor + all vendored peers) for container pip install.
    {
      for sub in supervisor eng_lead eng_scout eng_coder eng_quality_and_security_reviewer xray_manager xray_librarian xray_architect xray_specialist xray_auditor events chat; do
        [[ -f "$AGENTS_DIR/$sub/requirements.txt" ]] || continue
        cat "$AGENTS_DIR/$sub/requirements.txt"
        echo
      done
    } | grep -v '^[[:space:]]*#' | sed '/^[[:space:]]*$/d' | sort -u > "$sup_bundle/ws/agents/supervisor/requirements.txt"
    deploy_root="$sup_bundle/ws"
    deploy_relpath="agents/supervisor"
  fi
  if (cd "$deploy_root" && $adk_wrap "$ADK_CMD" deploy agent_engine --project="$PROJECT_ID" --region="$REGION" --temp_folder="${agent}_staged" $adk_extra "$deploy_relpath" 2>&1) > "$deploy_out"; then
    if grep -qE "Failed to create Agent Engine|failed to start and cannot serve traffic|'code': 13|Please refer to our documentation.*troubleshooting|Deploy failed|not available in region" "$deploy_out" 2>/dev/null; then
      cat "$deploy_out" >&2
      rm -f "$deploy_out"
      [[ -n "$sup_bundle" ]] && rm -rf "$sup_bundle"
      return 1
    fi
    # Success: Extract engine ID and grant session roles (fixes 498 session error)
    engine_full_id=$(grep -oE "projects/[0-9]+/locations/[a-z0-9-]+/reasoningEngines/[0-9]+" "$deploy_out" | head -n1 || true)
    if [[ -n "$engine_full_id" && -n "${ORG_ID:-}" ]]; then
      # Grant session roles to the engine-specific principal (ORG_ID from versions.env or gcloud)
      principal="principal://agents.global.org-${ORG_ID}.system.id.goog/resources/aiplatform/$engine_full_id"
      echo "   [IAM] Granting session roles to $engine_full_id..."
      gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$principal" --role="projects/$PROJECT_ID/roles/reasoningEngineSessionUser" --condition=None >/dev/null 2>&1 || true
      gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$principal" --role="roles/aiplatform.user" --condition=None >/dev/null 2>&1 || true
      gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$principal" --role="roles/serviceusage.serviceUsageConsumer" --condition=None >/dev/null 2>&1 || true
      gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$principal" --role="roles/cloudtrace.agent" --condition=None >/dev/null 2>&1 || true
      echo "   [IAM] Granting Secret Manager role to $engine_full_id..."
      gcloud secrets add-iam-policy-binding github-pat-token --member="$principal" --role="roles/secretmanager.secretAccessor" --project="$PROJECT_ID" >/dev/null 2>&1 || true
    fi
  else
    # #region agent log
    _debug_log "adk_deploy_done" "deploy.sh:adk_fail" "H2" "{\"agent\":\"$agent\",\"success\":false}"
    # #endregion
    cat "$deploy_out" >&2
    rm -f "$deploy_out"
    [[ -n "$sup_bundle" ]] && rm -rf "$sup_bundle"
    return 1
  fi
  # #region agent log
  _debug_log "adk_deploy_done" "deploy.sh:adk_ok" "H2" "{\"agent\":\"$agent\",\"success\":true}"
  # #endregion
  rm -f "$deploy_out"
  [[ -n "$sup_bundle" ]] && rm -rf "$sup_bundle"
  return 0
}

deploy_one_with_result() {
  local agent="$1"
  echo "🚀 Deploying: $agent"
  if deploy_one "$agent"; then
    echo "ok" > "$result_dir/$agent"
    echo "✅ $agent"
  else
    echo "fail" > "$result_dir/$agent"
    echo "❌ $agent"
    return 1
  fi
}

export ADK_DIR ADK_CMD PROJECT_ID REGION AGENTS_DIR result_dir ORG_ID DEBUG_LOG
export -f deploy_one deploy_one_with_result _debug_log

# ----- PRE-FLIGHT GUARDRAILS -----
_preflight_script="$ROOT_DIR/scripts/run_preflight_guardrails.py"
if [[ -f "$_preflight_script" ]]; then
  if [[ -x "$ADK_DIR/.venv/bin/python" ]]; then
    "$ADK_DIR/.venv/bin/python" "$_preflight_script" "$AGENTS_DIR" "${AGENTS[@]}" || exit 1
  else
    python3 "$_preflight_script" "$AGENTS_DIR" "${AGENTS[@]}" || exit 1
  fi
fi
# ---------------------------------

echo "Deploying ${#AGENTS[@]} agents in parallel (max $MAX_PARALLEL at a time)..."
# #region agent log
_debug_log "parallel_loop_start" "deploy.sh:loop_start" "H3_H4" "{\"n_agents\":${#AGENTS[@]}}"
# #endregion
for agent in "${AGENTS[@]}"; do
  while [[ $(jobs -r 2>/dev/null | wc -l) -ge $MAX_PARALLEL ]]; do
    sleep 2
  done
  ( deploy_one_with_result "$agent" ) &
done
# #region agent log
_debug_log "wait_start" "deploy.sh:before_wait" "H4" "{}"
# #endregion
wait
# #region agent log
_debug_log "wait_done" "deploy.sh:after_wait" "H4" "{}"
# #endregion

failed_agents=()
for agent in "${AGENTS[@]}"; do
  if [[ -f "$result_dir/$agent" ]] && [[ "$(cat "$result_dir/$agent")" == "fail" ]]; then
    failed_agents+=("$agent")
  fi
done

# POST-DEPLOY: Always re-run merge_peer_engine_env now that all attempted engines
# are live (even on partial failure). The pre-deploy call finds stale/blank IDs
# because it runs before engines are replaced. This second call resolves IDs from
# the freshly deployed engines so Cloud Run always gets correct peer configs.
echo ""
echo "🔗 Re-merging peer engine IDs from freshly deployed engines..."
if [[ -f "$_merge_peer" ]]; then
  if [[ -x "$ADK_DIR/.venv/bin/python" ]]; then
    "$ADK_DIR/.venv/bin/python" "$_merge_peer" "$ROOT_DIR" && \
      echo "✅ Peer engine IDs updated." || \
      echo "⚠️  merge_peer_engine_env: some IDs still missing (non-fatal)."
  else
    python3 "$_merge_peer" "$ROOT_DIR" && \
      echo "✅ Peer engine IDs updated." || \
      echo "⚠️  merge_peer_engine_env: some IDs still missing (non-fatal)."
  fi
fi

echo ""
if [[ ${#failed_agents[@]} -eq 0 ]]; then
  echo "✅ All agents deployed successfully."
else
  echo "❌ Failed agents (${#failed_agents[@]}): ${failed_agents[*]}"
  echo "   Check Logs Explorer: Resource type = Vertex AI Reasoning Engine. Run: ./scripts/fetch_deploy_errors.sh 1"
  exit 1
fi
