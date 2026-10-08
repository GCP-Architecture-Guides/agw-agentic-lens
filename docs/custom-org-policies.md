# Custom Organization Policies for Agent Engine Governance

> **Replace the following placeholders before applying:**
>
> | Placeholder | Description | Example |
> |------------|-------------|---------|
> | `YOUR_ORG_ID` | Numeric GCP Organization ID | `123456789012` |
> | `YOUR_PROJECT_ID` | Target GCP Project ID | `my-agent-project` |
> | `YOUR_ADMIN_EMAIL` | Admin account email | `admin@example.com` |

---

## Overview

Three custom constraints that enforce governance on **every** Reasoning Engine (Agent Engine) deployment. They are evaluated at the Vertex AI API layer on every `CREATE` and `UPDATE` call — no agent can bypass them regardless of deployment tool (ADK CLI, Terraform, REST API, Console).

```
┌─────────────────────────────────────────────────────────────┐
│              Custom Org Policy Constraints                    │
│                                                               │
│  ┌─────────────────┐ ┌──────────────┐ ┌──────────────────┐  │
│  │ 1. Gateway       │ │ 2. Identity  │ │ 3. OTEL +        │  │
│  │    Config         │ │    Type      │ │    Metadata Tags │  │
│  │                   │ │              │ │                   │  │
│  │ Agent must route  │ │ Must use     │ │ Must enable      │  │
│  │ through egress    │ │ AGENT_       │ │ telemetry +      │  │
│  │ gateway (PSC)     │ │ IDENTITY     │ │ 5 required tags  │  │
│  └─────────────────┘ └──────────────┘ └──────────────────┘  │
│                                                               │
│  Applied to: aiplatform.googleapis.com/ReasoningEngine        │
│  Methods:    CREATE, UPDATE                                   │
│  Action:     ALLOW (only compliant deployments proceed)       │
└─────────────────────────────────────────────────────────────┘
```

---

## Constraint 1: Agent Gateway Config Enforcement

Ensures every Reasoning Engine is deployed with an egress Agent Gateway, routing all outbound traffic through PSC-based network controls.

### YAML Definition

```yaml
# File: constraint-agent-gateway-config.yaml
name: organizations/YOUR_ORG_ID/customConstraints/custom.EnforceReasoningEngineAgentGatewayConfig
resourceTypes:
  - aiplatform.googleapis.com/ReasoningEngine
methodTypes:
  - CREATE
  - UPDATE
condition: >-
  has(resource.spec.deploymentSpec.agentGatewayConfig.agentToAnywhereConfig)
actionType: ALLOW
displayName: "Enforce Agent Gateway Config for Reasoning Engines"
description: >-
  Ensures all Reasoning Engine deployments include an Agent Gateway
  agentToAnywhereConfig (egress gateway). This routes all outbound agent
  traffic through the governed egress gateway with PSC network attachment,
  enabling Model Armor content scanning, SGP semantic evaluation, and
  network-layer allowlist enforcement. Agents deployed without this config
  would have ungoverned internet access.
```

### CEL Condition Explained

```
has(resource.spec.deploymentSpec.agentGatewayConfig.agentToAnywhereConfig)
```

| Field Path | What It Checks |
|-----------|----------------|
| `resource.spec.deploymentSpec` | The deployment specification of the Reasoning Engine |
| `.agentGatewayConfig` | The gateway configuration block must exist |
| `.agentToAnywhereConfig` | Specifically the egress (agent-to-external) gateway must be configured |

> [!IMPORTANT]
> This does NOT check `clientToAgentConfig` (ingress) — only egress. Ingress gateway attachment is optional because some agents may be invoked only by other agents (not directly by clients).

### Apply Commands

```bash
# Step 1: Create the custom constraint at the org level
gcloud org-policies set-custom-constraint constraint-agent-gateway-config.yaml \
  --organization=YOUR_ORG_ID

# Step 2: Enforce it on the target project
cat > policy-agent-gateway-config.yaml << 'EOF'
name: projects/YOUR_PROJECT_ID/policies/custom.EnforceReasoningEngineAgentGatewayConfig
spec:
  rules:
    - enforce: true
EOF

gcloud org-policies set-policy policy-agent-gateway-config.yaml \
  --project=YOUR_PROJECT_ID
```

### What Happens When Violated

```
googleapi: Error 412:
  Operation denied by custom org policy:
  ["customConstraints/custom.EnforceReasoningEngineAgentGatewayConfig"]:
  Ensures all Reasoning Engine deployments include an Agent Gateway
  agentToAnywhereConfig (egress gateway).
```

---

## Constraint 2: Agent Identity Enforcement

Ensures every Reasoning Engine runs with `AGENT_IDENTITY` (SPIFFE-based), not `USER_IDENTITY`.

### YAML Definition

```yaml
# File: constraint-agent-identity.yaml
name: organizations/YOUR_ORG_ID/customConstraints/custom.EnforceAgentIdentityForReasoningEngine
resourceTypes:
  - aiplatform.googleapis.com/ReasoningEngine
methodTypes:
  - CREATE
  - UPDATE
condition: >-
  resource.spec.identityType == "AGENT_IDENTITY"
actionType: ALLOW
displayName: "Enforce AGENT_IDENTITY for Reasoning Engines"
description: >-
  Ensures all Reasoning Engines are deployed with an explicit Agent Identity
  (SPIFFE-based principal: principal://agents.googleapis.com/...) instead of
  User Identity. This enables per-agent audit trails, zero-trust IAM
  (each agent gets only the permissions it needs), and blast radius
  containment (compromising one agent does not expose others).
  USER_IDENTITY allows agents to impersonate the deployer's permissions,
  creating a privilege escalation risk.
```

### CEL Condition Explained

```
resource.spec.identityType == "AGENT_IDENTITY"
```

| Value | Meaning |
|-------|---------|
| `AGENT_IDENTITY` | ✅ Agent runs with its own SPIFFE identity (`principal://agents.global.org-{YOUR_ORG_ID}.system.id.goog/...`) |
| `USER_IDENTITY` | ❌ Agent inherits the deployer's identity — privilege escalation risk |
| (not set) | ❌ Defaults to `USER_IDENTITY` — blocked by this constraint |

> [!WARNING]
> After deploying with `AGENT_IDENTITY`, you must explicitly grant IAM roles to the agent's SPIFFE principal. Without this, the agent will have zero permissions and all API calls will fail with 403.

### Post-Deploy IAM Grants Required

```bash
# After deploying an agent with AGENT_IDENTITY, grant it runtime permissions:
ENGINE_ID="projects/YOUR_PROJECT_ID/locations/YOUR_REGION/reasoningEngines/XXXXXXX"

PRINCIPAL="principal://agents.global.org-YOUR_ORG_ID.system.id.goog/resources/aiplatform/${ENGINE_ID}"

# Core runtime permissions
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="$PRINCIPAL" --role="roles/aiplatform.user" --condition=None

gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="$PRINCIPAL" --role="roles/serviceusage.serviceUsageConsumer" --condition=None

gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="$PRINCIPAL" --role="roles/cloudtrace.agent" --condition=None
```

### Apply Commands

```bash
# Step 1: Create the custom constraint
gcloud org-policies set-custom-constraint constraint-agent-identity.yaml \
  --organization=YOUR_ORG_ID

# Step 2: Enforce on project
cat > policy-agent-identity.yaml << 'EOF'
name: projects/YOUR_PROJECT_ID/policies/custom.EnforceAgentIdentityForReasoningEngine
spec:
  rules:
    - enforce: true
EOF

gcloud org-policies set-policy policy-agent-identity.yaml \
  --project=YOUR_PROJECT_ID
```

---

## Constraint 3: OTEL Telemetry + Metadata Tag Enforcement

Ensures every Reasoning Engine enables OpenTelemetry and includes 5 organizational metadata tags for cost attribution, observability dashboards, and alert routing.

### YAML Definition

```yaml
# File: constraint-otel-config.yaml
name: organizations/YOUR_ORG_ID/customConstraints/custom.EnforceReasoningEngineOtelConfig
resourceTypes:
  - aiplatform.googleapis.com/ReasoningEngine
methodTypes:
  - CREATE
  - UPDATE
condition: >-
  has(resource.spec.deploymentSpec.env)
  && resource.spec.deploymentSpec.env.exists(e, e.name == "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY")
  && resource.spec.deploymentSpec.env.exists(e, e.name == "agent_name")
  && resource.spec.deploymentSpec.env.exists(e, e.name == "agent_description")
  && resource.spec.deploymentSpec.env.exists(e, e.name == "agent_department")
  && resource.spec.deploymentSpec.env.exists(e, e.name == "agent_team")
  && resource.spec.deploymentSpec.env.exists(e, e.name == "agent_role")
actionType: ALLOW
displayName: "Enforce OTEL Config with Metadata Tags for Reasoning Engines"
description: >-
  Ensures all Reasoning Engines deploy with OpenTelemetry telemetry enabled
  and five required organizational metadata tags (agent_name,
  agent_description, agent_department, agent_team, agent_role). These tags
  power the observability dashboards for per-agent token attribution, cost
  monitoring, alert routing, and organizational reporting. Without these,
  agents operate as unattributed black boxes with no visibility into token
  consumption or department-level cost allocation.
```

### CEL Condition Explained

The condition uses 7 `exists()` checks on the environment variable array:

```
has(resource.spec.deploymentSpec.env)                                          # env array must exist
&& resource.spec.deploymentSpec.env.exists(e, e.name == "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY")  # OTEL on
&& resource.spec.deploymentSpec.env.exists(e, e.name == "agent_name")          # Tag 1
&& resource.spec.deploymentSpec.env.exists(e, e.name == "agent_description")   # Tag 2
&& resource.spec.deploymentSpec.env.exists(e, e.name == "agent_department")    # Tag 3
&& resource.spec.deploymentSpec.env.exists(e, e.name == "agent_team")          # Tag 4
&& resource.spec.deploymentSpec.env.exists(e, e.name == "agent_role")          # Tag 5
```

| Env Variable | Purpose | Example Value |
|-------------|---------|---------------|
| `GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY` | Activates OTEL trace/metric export | `true` |
| `agent_name` | Agent display name for dashboards | `eng_coder` |
| `agent_description` | Human-readable purpose | `Generates Terraform IaC code` |
| `agent_department` | Department for cost attribution | `Engineering` |
| `agent_team` | Team for alert routing | `platform-team` |
| `agent_role` | Functional role for grouping | `code-generation` |

> [!NOTE]
> This constraint checks that the env vars **exist** but does not validate their values. An empty string satisfies the constraint. This is intentional — value validation is handled by the observability dashboards and alerting rules, not at the API layer.

### Dashboard Queries These Tags Enable

```
# Per-department token consumption
fetch aiplatform.googleapis.com/agent_engine
| filter metric.agent_department == "Engineering"
| group_by [metric.agent_name], sum(value.token_count)

# Top 5 token-consuming agents
fetch aiplatform.googleapis.com/agent_engine
| group_by [metric.agent_name, metric.agent_team], sum(value.total_tokens)
| sort -sum_total_tokens | top 5

# Alert: Agent using more tokens than its baseline
fetch aiplatform.googleapis.com/agent_engine
| filter metric.agent_name == "eng_coder"
| align rate(15m)
| condition val() > 200% * val(1d)
```

### Apply Commands

```bash
# Step 1: Create the custom constraint
gcloud org-policies set-custom-constraint constraint-otel-config.yaml \
  --organization=YOUR_ORG_ID

# Step 2: Enforce on project
cat > policy-otel-config.yaml << 'EOF'
name: projects/YOUR_PROJECT_ID/policies/custom.EnforceReasoningEngineOtelConfig
spec:
  rules:
    - enforce: true
EOF

gcloud org-policies set-policy policy-otel-config.yaml \
  --project=YOUR_PROJECT_ID
```

---

## Complete Apply Script

Save this as `apply_org_policies.sh`, replace all placeholders, and run with org admin permissions:

```bash
#!/usr/bin/env bash
set -euo pipefail

# ╔════════════════════════════════════════════════════════════════╗
# ║  REPLACE THESE VALUES BEFORE RUNNING                          ║
# ╚════════════════════════════════════════════════════════════════╝
ORG_ID="YOUR_ORG_ID"
PROJECT_ID="YOUR_PROJECT_ID"

echo "════════════════════════════════════════════════════════════════"
echo "  Applying Custom Org Policies for Agent Engine Governance"
echo "  Org: $ORG_ID | Project: $PROJECT_ID"
echo "════════════════════════════════════════════════════════════════"

# --- Constraint 1: Agent Gateway Config ---
echo ""
echo "▶ [1/6] Creating constraint: EnforceReasoningEngineAgentGatewayConfig"
cat > /tmp/constraint-gateway.yaml << EOF
name: organizations/${ORG_ID}/customConstraints/custom.EnforceReasoningEngineAgentGatewayConfig
resourceTypes:
  - aiplatform.googleapis.com/ReasoningEngine
methodTypes:
  - CREATE
  - UPDATE
condition: "has(resource.spec.deploymentSpec.agentGatewayConfig.agentToAnywhereConfig)"
actionType: ALLOW
displayName: "Enforce Agent Gateway Config for Reasoning Engines"
description: "Ensures all Reasoning Engine deployments include an egress Agent Gateway config."
EOF
gcloud org-policies set-custom-constraint /tmp/constraint-gateway.yaml --organization="$ORG_ID"
echo "  ✅ Constraint created"

echo "▶ [2/6] Enforcing on project: $PROJECT_ID"
cat > /tmp/policy-gateway.yaml << EOF
name: projects/${PROJECT_ID}/policies/custom.EnforceReasoningEngineAgentGatewayConfig
spec:
  rules:
    - enforce: true
EOF
gcloud org-policies set-policy /tmp/policy-gateway.yaml --project="$PROJECT_ID"
echo "  ✅ Enforced"

# --- Constraint 2: Agent Identity ---
echo ""
echo "▶ [3/6] Creating constraint: EnforceAgentIdentityForReasoningEngine"
cat > /tmp/constraint-identity.yaml << EOF
name: organizations/${ORG_ID}/customConstraints/custom.EnforceAgentIdentityForReasoningEngine
resourceTypes:
  - aiplatform.googleapis.com/ReasoningEngine
methodTypes:
  - CREATE
  - UPDATE
condition: 'resource.spec.identityType == "AGENT_IDENTITY"'
actionType: ALLOW
displayName: "Enforce AGENT_IDENTITY for Reasoning Engines"
description: "Ensures Reasoning Engines are deployed with AGENT_IDENTITY (SPIFFE), not USER_IDENTITY."
EOF
gcloud org-policies set-custom-constraint /tmp/constraint-identity.yaml --organization="$ORG_ID"
echo "  ✅ Constraint created"

echo "▶ [4/6] Enforcing on project: $PROJECT_ID"
cat > /tmp/policy-identity.yaml << EOF
name: projects/${PROJECT_ID}/policies/custom.EnforceAgentIdentityForReasoningEngine
spec:
  rules:
    - enforce: true
EOF
gcloud org-policies set-policy /tmp/policy-identity.yaml --project="$PROJECT_ID"
echo "  ✅ Enforced"

# --- Constraint 3: OTEL + Metadata Tags ---
echo ""
echo "▶ [5/6] Creating constraint: EnforceReasoningEngineOtelConfig"
cat > /tmp/constraint-otel.yaml << EOF
name: organizations/${ORG_ID}/customConstraints/custom.EnforceReasoningEngineOtelConfig
resourceTypes:
  - aiplatform.googleapis.com/ReasoningEngine
methodTypes:
  - CREATE
  - UPDATE
condition: 'has(resource.spec.deploymentSpec.env) && resource.spec.deploymentSpec.env.exists(e, e.name == "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY") && resource.spec.deploymentSpec.env.exists(e, e.name == "agent_name") && resource.spec.deploymentSpec.env.exists(e, e.name == "agent_description") && resource.spec.deploymentSpec.env.exists(e, e.name == "agent_department") && resource.spec.deploymentSpec.env.exists(e, e.name == "agent_team") && resource.spec.deploymentSpec.env.exists(e, e.name == "agent_role")'
actionType: ALLOW
displayName: "Enforce OTEL Config with Metadata Tags for Reasoning Engines"
description: "Ensures Reasoning Engines deploy with OTEL telemetry and 5 required organizational metadata tags."
EOF
gcloud org-policies set-custom-constraint /tmp/constraint-otel.yaml --organization="$ORG_ID"
echo "  ✅ Constraint created"

echo "▶ [6/6] Enforcing on project: $PROJECT_ID"
cat > /tmp/policy-otel.yaml << EOF
name: projects/${PROJECT_ID}/policies/custom.EnforceReasoningEngineOtelConfig
spec:
  rules:
    - enforce: true
EOF
gcloud org-policies set-policy /tmp/policy-otel.yaml --project="$PROJECT_ID"
echo "  ✅ Enforced"

# --- Verification ---
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Verification"
echo "════════════════════════════════════════════════════════════════"

echo ""
echo "Waiting 30 seconds for propagation..."
sleep 30

for constraint in \
  "custom.EnforceReasoningEngineAgentGatewayConfig" \
  "custom.EnforceAgentIdentityForReasoningEngine" \
  "custom.EnforceReasoningEngineOtelConfig"; do
  
  echo ""
  echo "▶ Checking: $constraint"
  gcloud org-policies describe-custom-constraint "$constraint" --organization="$ORG_ID" 2>&1 | head -5
  echo "  Policy on project:"
  gcloud org-policies describe "$constraint" --project="$PROJECT_ID" 2>&1 | head -5
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  ✅ All 3 custom org policies applied and enforced!"
echo "════════════════════════════════════════════════════════════════"
```

---

## Verification: Test That Policies Block Non-Compliant Deployments

After applying, test with a bare-minimum agent that violates all three constraints:

```bash
# This should FAIL with org policy violation:
gcloud ai reasoning-engines create \
  --display-name="test-ungoverned" \
  --project=YOUR_PROJECT_ID \
  --region=YOUR_REGION

# Expected error:
# Operation denied by custom org policy:
#   ["customConstraints/custom.EnforceAgentIdentityForReasoningEngine",
#    "customConstraints/custom.EnforceReasoningEngineAgentGatewayConfig",
#    "customConstraints/custom.EnforceReasoningEngineOtelConfig"]
```

---

## Required IAM Permissions to Apply

The account running the apply script needs:

| Permission | Role | Scope |
|-----------|------|-------|
| `orgpolicy.customConstraints.create` | `roles/orgpolicy.policyAdmin` | Organization `YOUR_ORG_ID` |
| `orgpolicy.policies.create` | `roles/orgpolicy.policyAdmin` | Project `YOUR_PROJECT_ID` |

```bash
# Grant to your admin account (run by an org super-admin):
gcloud organizations add-iam-policy-binding YOUR_ORG_ID \
  --member="user:YOUR_ADMIN_EMAIL" \
  --role="roles/orgpolicy.policyAdmin"
```
