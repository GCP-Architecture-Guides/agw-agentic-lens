# ------------------------------------------------------------------------------
# 5. AGENT DEPLOYMENT SCRIPTS (PYTHON SDK)
# ------------------------------------------------------------------------------
# Auto-generate the deployment script for the chat-agent based on Terraform variables
# We generate a Python script because the gcloud CLI natively lacks the `reasoning-engines` command in this environment.
# ------------------------------------------------------------------------------
# 6. AGENT DEPLOYMENT SCRIPTS (PYTHON SDK)
# ------------------------------------------------------------------------------
# Gated by var.create_agent (default: true).
# Set create_agent = false in terraform.tfvars when consuming this repo as a
# Terraform module and deploying your own agent separately via CONSUMING.md.
# ------------------------------------------------------------------------------
resource "local_file" "deploy_agent_script" {
  count           = var.create_agent ? 1 : 0
  filename        = "${path.module}/scripts/deploy_chat_agent.sh"
  content         = <<-EOT
#!/usr/bin/env bash
set -euo pipefail

# Project root = the folder containing this scripts/ directory (mod-agw-foundation-pub/).
# The deployable agent source lives at agents/chat-agent/ inside the project root.
SCRIPT_DIR="$( cd "$( dirname "$0" )" &> /dev/null && pwd )"
SCRIPT_WORKSPACE="$( dirname "$SCRIPT_DIR" )"  # = mod-agw-foundation-pub/

# All relative paths below are relative to SCRIPT_WORKSPACE (the project root).
cd "$SCRIPT_WORKSPACE"

echo "Checking if .venv exists..."
if [[ ! -x ".venv/bin/python" ]]; then
    python3 -m venv .venv
fi

# ---------------------------------------------------------------------------
# PRE-FLIGHT: Validate that agents/chat-agent/requirements.txt has pinned
# versions. Unpinned packages in the RE container install LATEST, which may:
#   - Change the Agent Pydantic model → ValidationError on startup
#   - Change internal transport → .pth patch interceptors don't fire
# See KNOWN_ISSUES.md #008 for full root cause.
# ---------------------------------------------------------------------------
echo "Pre-flight: Checking requirements.txt version pins..."
REQS_FILE="agents/chat-agent/requirements.txt"
PIN_ERRORS=0
for pkg in "google-adk" "google-cloud-aiplatform"; do
    if ! grep -qE "^$${pkg}[^=!<>]*(==|>=.*,<)" "$REQS_FILE" 2>/dev/null; then
        echo "  ❌ '$${pkg}' in $REQS_FILE is UNPINNED — must use == or bounded >= ... , <"
        PIN_ERRORS=$${PIN_ERRORS:-0}
        PIN_ERRORS=$((PIN_ERRORS + 1))
    fi
done
if [ "$${PIN_ERRORS:-0}" -gt 0 ]; then
    echo ""
    echo "  FATAL: Unpinned dependencies will cause container startup failure."
    echo "  The RE container runs 'pip install -r requirements.txt' at startup."
    echo "  See KNOWN_ISSUES.md #008 for root cause and fix."
    exit 1
fi
echo "  ✅ Version pins OK."

echo "Installing ADK and requirements (pinned to known-working versions)..."
# IMPORTANT: Do NOT unpin these versions. The .pth monkey-patch that injects
# agentGatewayConfig was written for google-cloud-aiplatform==1.149.0.
# Newer versions changed the internal transport (agentplatform.Client) and the
# patch interceptors (AuthorizedSession + httpx + GAPIC class) no longer fire,
# causing ALL 4 org policy constraints to be violated (400 FAILED_PRECONDITION).
# See KNOWN_ISSUES.md #008.
.venv/bin/pip install -i https://pypi.org/simple -q --no-deps "google-adk==1.31.1"
.venv/bin/pip install -i https://pypi.org/simple -q "google-cloud-aiplatform[adk,agent_engines]==1.149.0" "requests" "pydantic"

export AGENT_GATEWAY_INGRESS="projects/${var.project_id}/locations/${var.location}/agentGateways/${var.prefix}-ingress-gateway"
export AGENT_GATEWAY_EGRESS="projects/${var.project_id}/locations/${var.location}/agentGateways/${var.prefix}-egress-gateway"

# ---------------------------------------------------------------------------
# PRE-DEPLOY CLEANUP: Delete any existing Reasoning Engines with the same
# display name. adk deploy agent_engine always creates a NEW RE — it has no
# upsert / update path. Without this step, each deploy adds a duplicate instance.
# force=true deletes child session resources automatically.
# ---------------------------------------------------------------------------
echo "Checking for existing Reasoning Engines named '${var.agent_name}'..."
.venv/bin/python - <<'PYEOF'
import sys, time
import google.auth
import google.auth.transport.requests
import requests as http

PROJECT  = "${var.project_id}"
LOCATION = "${var.location}"
NAME     = "${var.agent_name}"

creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
creds.refresh(google.auth.transport.requests.Request())
token = creds.token

base = f"https://{LOCATION}-aiplatform.googleapis.com/v1beta1/projects/{PROJECT}/locations/{LOCATION}/reasoningEngines"
resp = http.get(base, headers={"Authorization": f"Bearer {token}"})
resp.raise_for_status()
engines = resp.json().get("reasoningEngines", [])
matches = [e for e in engines if e.get("displayName") == NAME]

if not matches:
    print(f"  No existing engines named '{NAME}' — clean slate.")
    sys.exit(0)

for engine in matches:
    resource_name = engine["name"]
    created = engine.get("createTime", "unknown")
    print(f"  Deleting: {resource_name}  (created: {created})")
    del_resp = http.delete(
        f"https://{LOCATION}-aiplatform.googleapis.com/v1beta1/{resource_name}?force=true",
        headers={"Authorization": f"Bearer {token}"},
    )
    if del_resp.status_code in (200, 204):
        op = del_resp.json()
        if op.get("done"):
            print(f"  ✅ Deleted synchronously.")
        else:
            op_name = op.get("name", "")
            print(f"  ⏳ Delete in progress: {op_name}. Waiting up to 90s...")
            for _ in range(18):
                time.sleep(5)
                poll = http.get(
                    f"https://{LOCATION}-aiplatform.googleapis.com/v1beta1/{op_name}",
                    headers={"Authorization": f"Bearer {token}"},
                )
                if poll.json().get("done"):
                    print(f"  ✅ Deleted.")
                    break
            else:
                print(f"  ⚠️  Delete did not complete in 90s — continuing anyway.")
    else:
        print(f"  ⚠️  Delete returned HTTP {del_resp.status_code}: {del_resp.text}")

print("  Cleanup complete.")
PYEOF

# ---------------------------------------------------------------------------
# Inject correct project into agents/chat-agent/.env so GatewayAgent uses the
# right project inside the Reasoning Engine runtime.
# The adk CLI bundles .env files from the agent directory into the deployment.
# ---------------------------------------------------------------------------
echo "Writing agents/chat-agent/.env with project env vars..."
cat > agents/chat-agent/.env << 'ENVEOF'
GCP_PROJECT_ID=${var.project_id}
GOOGLE_CLOUD_PROJECT=${var.project_id}
GOOGLE_CLOUD_LOCATION=${var.location}
AGENT_GATEWAY_INGRESS=projects/${var.project_id}/locations/${var.location}/agentGateways/${var.prefix}-ingress-gateway
AGENT_GATEWAY_EGRESS=projects/${var.project_id}/locations/${var.location}/agentGateways/${var.prefix}-egress-gateway
# OTEL mTLS FIX (Layer 1): RE containers have mTLS certs — prevents SSL context corruption.
GOOGLE_API_USE_MTLS_ENDPOINT=never
# OTEL TCP-BLOCK FIX (Layer 2): telemetry.googleapis.com not in PSC routing — fail fast.
OTEL_EXPORTER_OTLP_TIMEOUT=2000
OTEL_BSP_EXPORT_TIMEOUT_MILLIS=2000
OTEL_BSP_SCHEDULE_DELAY_MILLIS=15000
# aiohttp SINGLETON FIX (Layer 3): disables mTLS aiohttp path, forces httpx per-loop client.
GOOGLE_API_USE_CLIENT_CERTIFICATE=false
ENVEOF
echo "  GCP_PROJECT_ID=${var.project_id}"
echo "  AGENT_GATEWAY_INGRESS=projects/${var.project_id}/locations/${var.location}/agentGateways/${var.prefix}-ingress-gateway"
echo "  OTEL 3-layer fix vars written"

echo "Applying ADK monkey-patch for org policy bypass..."
.venv/bin/python scripts/patch_sdk_for_rest_create.py --ingress "$AGENT_GATEWAY_INGRESS" --egress "$AGENT_GATEWAY_EGRESS" --agent-name "${var.agent_name}" --venv .venv


# ---------------------------------------------------------------------------
# COMPLIANCE CHECK: agent.py must import GatewayAgent from the gateway_agent SDK.
# Fails the build immediately if bare Agent() is used — ensures telemetry,
# GlobalGemini routing, and query() registration are always enforced.
# ---------------------------------------------------------------------------
echo "Running GatewayAgent compliance check..."
if ! .venv/bin/python - <<'PYEOF'
import ast, sys
try:
    tree = ast.parse(open("agents/chat-agent/agent.py").read())
except FileNotFoundError:
    print("  ❌ agents/chat-agent/agent.py not found")
    sys.exit(1)
uses_gateway = any(
    (isinstance(n, ast.ImportFrom) and n.module and "gateway_agent" in n.module)
    or (isinstance(n, ast.Import) and any("gateway_agent" in a.name for a in n.names))
    for n in ast.walk(tree)
)
if not uses_gateway:
    print("  ❌ Gateway Compliance Error: agent.py must import GatewayAgent from the gateway_agent SDK.")
    print("     Replace: from google.adk.agents import Agent")
    print("     With:    from gateway_agent import GatewayAgent")
    sys.exit(1)
print("  ✅ Compliance check passed — GatewayAgent SDK detected.")
PYEOF
then
    exit 1
fi

# ---------------------------------------------------------------------------
# SDK BUNDLE: Copy lib/gateway_agent/ into agents/chat-agent/ so adk deploy
# includes it in the Reasoning Engine deployment package.
# The source of truth stays in mod-agw-foundation-pub/lib/gateway_agent/.
# This copy is temporary — cleaned up immediately after deploy.
# ---------------------------------------------------------------------------
SDK_SRC="lib/gateway_agent"
SDK_DST="agents/chat-agent/gateway_agent"

echo "Applying contextSpec injection patch (prevents platform memoryBankConfig auto-injection)..."
.venv/bin/python scripts/patch_add_context_spec.py --venv .venv
if [[ -d "$SDK_SRC" ]]; then
    echo "Bundling GatewayAgent SDK into agents/chat-agent/ for deployment..."
    cp -r "$SDK_SRC" "$SDK_DST"
    echo "  ✅ Copied lib/gateway_agent → agents/chat-agent/gateway_agent"
else
    echo "  ❌ SDK source not found at $SDK_SRC — cannot bundle GatewayAgent"
    exit 1
fi

echo "Deploying ADK Agent natively..."
DEPLOY_TMPLOG=$(mktemp /tmp/adk_deploy_XXXXXX.log)
.venv/bin/adk deploy agent_engine \
  --project="${var.project_id}" \
  --region="${var.location}" \
  --display_name="${var.agent_name}" \
  --description="A foundational chat agent demonstrating security integrations." \
  agents/chat-agent 2>&1 | tee "$DEPLOY_TMPLOG"

DEPLOY_EXIT=$${PIPESTATUS[0]}

# ---------------------------------------------------------------------------
# SDK CLEANUP: Remove the temporary copy from agents/chat-agent/.
# ---------------------------------------------------------------------------
echo "Cleaning up bundled SDK copy..."
rm -rf "$SDK_DST"
echo "  ✅ Removed agents/chat-agent/gateway_agent (cleaned up after deploy)"

if [ "$DEPLOY_EXIT" -ne 0 ]; then
  echo "  ❌ adk deploy failed with exit code $DEPLOY_EXIT — stopping."
  exit "$DEPLOY_EXIT"
fi

# ---------------------------------------------------------------------------
# Post-deploy: strip server-injected contextSpec.memoryBankConfig.
# ---------------------------------------------------------------------------
echo "Stripping server-injected contextSpec from the new RE..."
PATCH_TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null)

NEW_RE_ID=$(grep -oP 'reasoningEngines/\K[0-9]+' "$DEPLOY_TMPLOG" | tail -1)
rm -f "$DEPLOY_TMPLOG"

if [ -z "$NEW_RE_ID" ]; then
  echo "  RE ID not found in deploy output — falling back to API list..."
  NEW_RE_ID=$(
    curl -s -H "Authorization: Bearer $PATCH_TOKEN" \
      "https://${var.location}-aiplatform.googleapis.com/v1beta1/projects/${var.project_id}/locations/${var.location}/reasoningEngines" \
    | python3 -c "
import json,sys
engines = json.load(sys.stdin).get('reasoningEngines', [])
matches = [e for e in engines if e.get('displayName') == '${var.agent_name}']
if matches:
    latest = sorted(matches, key=lambda e: e.get('createTime',''), reverse=True)[0]
    print(latest['name'].split('/')[-1])
" 2>/dev/null
  )
fi

if [ -n "$NEW_RE_ID" ]; then
  echo "  RE ID: $NEW_RE_ID — patching contextSpec..."
  PATCH_RESULT=$(
    curl -s -X PATCH \
      -H "Authorization: Bearer $PATCH_TOKEN" \
      -H "Content-Type: application/json" \
      "https://${var.location}-aiplatform.googleapis.com/v1beta1/projects/${var.project_id}/locations/${var.location}/reasoningEngines/$NEW_RE_ID?updateMask=contextSpec" \
      -d '{"contextSpec": null}'
  )
  echo "  PATCH sent — response: $(echo $PATCH_RESULT | head -c 200)"

  # Wait for RE to become ACTIVE after contextSpec strip (up to 150s)
  echo "  Waiting for RE $NEW_RE_ID to become ACTIVE..."
  RE_STATE="UNKNOWN"
  for i in $(seq 1 30); do
    sleep 5
    RE_STATE=$(
      curl -s -H "Authorization: Bearer $PATCH_TOKEN" \
        "https://${var.location}-aiplatform.googleapis.com/v1beta1/projects/${var.project_id}/locations/${var.location}/reasoningEngines/$NEW_RE_ID" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state','UNKNOWN'))" 2>/dev/null
    )
    echo "  [attempt $i/30] state=$RE_STATE"
    if [ "$RE_STATE" = "ACTIVE" ]; then
      echo "  ✅ RE is ACTIVE — contextSpec stripped successfully."
      break
    fi
  done
  if [ "$RE_STATE" != "ACTIVE" ]; then
    echo "  ⚠️  RE did not reach ACTIVE in 150s — final state: $RE_STATE"
    echo "  ⚠️  Check Cloud Logging for startup errors."
  fi
else
  echo "  ⚠️  Could not locate RE — contextSpec PATCH skipped. Check deploy logs."
fi

echo "Verifying — listing deployed Reasoning Engines..."
.venv/bin/python - <<'PYEOF'
import google.auth, google.auth.transport.requests, requests as http
PROJECT  = "${var.project_id}"
LOCATION = "${var.location}"
NAME     = "${var.agent_name}"
creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
creds.refresh(google.auth.transport.requests.Request())
base = f"https://{LOCATION}-aiplatform.googleapis.com/v1beta1/projects/{PROJECT}/locations/{LOCATION}/reasoningEngines"
engines = http.get(base, headers={"Authorization": f"Bearer {creds.token}"}).json().get("reasoningEngines", [])
matches = [e for e in engines if e.get("displayName") == NAME]
if len(matches) == 1:
    print(f"  ✅ Exactly 1 engine deployed: {matches[0]['name']}")
elif len(matches) == 0:
    print(f"  ❌ No engine found with name '{NAME}' — deploy may have failed.")
else:
    print(f"  ⚠️  {len(matches)} engines found with name '{NAME}' — unexpected duplicate!")
    for m in matches:
        print(f"     {m['name']}  (created: {m.get('createTime','?')})")
PYEOF
EOT
  file_permission = "0755"
}

# Pin explicitly to var.project_id — avoids reading wrong project if provider
# default differs from the module's target project.
data "google_project" "project" {
  project_id = var.project_id
}

# Staging bucket for Vertex AI RE deployments.
# Gated by create_agent — only needed when this module provisions the agent.
# Note: No prefix needed in name — per-team model means one deployment per project.
resource "google_storage_bucket" "vertex_staging" {
  count                       = var.create_agent ? 1 : 0
  name                        = "${var.project_id}-staging"
  location                    = var.location
  uniform_bucket_level_access = true
  force_destroy               = true
  project                     = var.project_id
}

resource "google_storage_bucket_iam_member" "vertex_ai_staging_read" {
  count  = var.create_agent ? 1 : 0
  bucket = google_storage_bucket.vertex_staging[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-aiplatform.iam.gserviceaccount.com"
}
