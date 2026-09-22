# Organization Policy Guardrails for Secure Agentic AI Deployments

## Enforcing Agent Identity, Observability, and Network Governance on Vertex AI Agent Engine

---

## Executive Summary

As enterprises adopt agentic AI systems on Google Cloud, ensuring consistent security, observability, and network governance becomes critical — especially when multiple teams deploy autonomous agents that make API calls, access data, and interact with external services.

This document outlines **three custom Organization Policies** that establish a **secure agentic perimeter** for Vertex AI Agent Engine (Reasoning Engine) deployments. These policies enforce:

| Policy | What It Enforces | Why It Matters |
|--------|-----------------|----------------|
| **Agent Identity** | Every agent runs with a unique SPIFFE-based identity | Zero-trust, per-agent auditability |
| **OTEL Telemetry & Metadata Tags** | Mandatory observability and organizational tagging | Token-level cost attribution, traceability |
| **Agent Gateway Config** | All traffic flows through managed ingress/egress gateways | Network perimeter control, TLS inspection, DLP |

> [!IMPORTANT]
> These policies are enforced at the **Organization level** using Google Cloud's Custom Organization Policy Constraints. Once applied, they apply to every `CREATE` and `UPDATE` operation on `aiplatform.googleapis.com/ReasoningEngine` — no agent can bypass them, regardless of which tool or SDK is used to deploy.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    GCP Organization Policy Layer                │
│                                                                 │
│  ┌──────────────┐  ┌──────────────────┐  ┌───────────────────┐  │
│  │ Agent Identity│  │ OTEL + Metadata  │  │ Gateway Config    │  │
│  │ Constraint   │  │ Constraint       │  │ Constraint        │  │
│  └──────┬───────┘  └────────┬─────────┘  └────────┬──────────┘  │
│         │                   │                      │            │
│         └───────────────────┼──────────────────────┘            │
│                             │                                   │
│                    ┌────────▼────────┐                          │
│                    │  Vertex AI API  │                          │
│                    │ CREATE / UPDATE │                          │
│                    │ ReasoningEngine │                          │
│                    └────────┬────────┘                          │
│                             │ ✓ All 3 policies pass            │
│                             ▼                                   │
│                    ┌─────────────────┐                          │
│                    │  Agent Engine   │                          │
│                    │  (Deployed)     │                          │
│                    └─────────────────┘                          │
└─────────────────────────────────────────────────────────────────┘
```

> [!NOTE]
> All three constraints use Google Cloud's [Custom Organization Policy](https://cloud.google.com/resource-manager/docs/organization-policy/creating-managing-custom-constraints) service, evaluated via CEL (Common Expression Language) on every API request before the resource is created or updated.

---

## Policy 1: Enforce Agent Identity

### Problem

By default, Vertex AI Reasoning Engines can be deployed with `USER_IDENTITY` — meaning the agent runs as the deploying user's identity. This creates:
- **Privilege escalation risk**: The agent inherits the deployer's full permissions.
- **No per-agent auditability**: All agents appear as the same principal in audit logs.
- **Shared credential exposure**: Compromising one agent compromises the user's identity.

### Solution

Enforce `AGENT_IDENTITY` mode, which assigns each agent a unique **SPIFFE-based identity** (`principal://agents.googleapis.com/...`). This enables:
- **Zero-trust**: Each agent has exactly the permissions it needs — no more.
- **Per-agent audit trail**: Every API call in Cloud Audit Logs is attributed to the specific agent.
- **Blast radius containment**: A compromised agent cannot escalate to user-level privileges.

### Constraint Definition

```yaml
name: organizations/{ORG_ID}/customConstraints/custom.EnforceAgentIdentityForReasoningEngine
resourceTypes:
  - aiplatform.googleapis.com/ReasoningEngine
methodTypes:
  - CREATE
  - UPDATE
condition: >
  resource.spec.identityType == "AGENT_IDENTITY"
actionType: ALLOW
displayName: Enforce AGENT_IDENTITY for Reasoning Engines
description: >
  Ensures all Reasoning Engines are deployed with a unique Agent Identity
  (SPIFFE-based) instead of inheriting the deployer's user identity.
```

### Deployment Commands

```bash
# 1. Register the custom constraint at the organization level
gcloud org-policies set-custom-constraint enforce-agent-identity.yaml

# 2. Enforce it on the target project (or folder/org)
gcloud org-policies set-policy policy-enforce-agent-identity.yaml
```

### Companion IAM Policy (Optional — Strict Mode)

For maximum enforcement, a companion constraint can restrict IAM bindings to only accept Agent Identity principals:

```yaml
name: organizations/{ORG_ID}/customConstraints/custom.enforceAgentIdentityOnly
resourceTypes:
  - iam.googleapis.com/AllowPolicy
methodTypes:
  - CREATE
  - UPDATE
condition: >
  resource.bindings.exists(b, b.members.exists(m,
    !MemberSubjectStartsWith(m, ["principal://agents.", "principalSet://agents."])))
actionType: DENY
displayName: Enforce Agent Identity for IAM Roles
description: >
  Only Agent Identity principals can be granted IAM roles.
  Standard service accounts, users, and groups are denied.
```

> [!WARNING]
> The IAM companion policy is strict — it blocks granting roles to *any* non-agent principal. Apply it only to projects/folders dedicated to agentic workloads, not to shared infrastructure projects.

---

## Policy 2: Enforce OTEL Telemetry & Organizational Metadata Tags

### Problem

Without mandatory telemetry, organizations face:
- **No visibility** into token consumption per agent, department, or team.
- **No cost attribution**: Cannot charge back API usage to business units.
- **No anomaly detection**: Cannot identify runaway agents or prompt injection attacks.
- **No compliance audit trail**: Cannot prove what an agent did, when, and at what cost.

### Solution

Enforce that every Reasoning Engine is deployed with:
1. **OpenTelemetry enabled** — captures LLM invocations, token counts, and latencies.
2. **Organizational metadata tags** — attributes every trace/metric to a named agent, department, team, and role.

### Required Environment Variables

| Variable | Purpose | Example Value |
|----------|---------|---------------|
| `GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY` | Enables the built-in OTEL exporter | `true` |
| `agent_name` | Unique agent identifier | `eng_coder` |
| `agent_description` | Human-readable purpose | `Generates IaC code` |
| `agent_department` | Business unit ownership | `Engineering` |
| `agent_team` | Team responsible | `Platform-Security` |
| `agent_role` | Functional role | `code_generator` |

### Constraint Definition

```yaml
name: organizations/{ORG_ID}/customConstraints/custom.EnforceReasoningEngineOtelConfig
resourceTypes:
  - aiplatform.googleapis.com/ReasoningEngine
methodTypes:
  - CREATE
  - UPDATE
condition: >-
  has(resource.spec.deploymentSpec.env) &&
  resource.spec.deploymentSpec.env.exists(e,
    e.name == "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY") &&
  resource.spec.deploymentSpec.env.exists(e, e.name == "agent_name") &&
  resource.spec.deploymentSpec.env.exists(e, e.name == "agent_description") &&
  resource.spec.deploymentSpec.env.exists(e, e.name == "agent_department") &&
  resource.spec.deploymentSpec.env.exists(e, e.name == "agent_team") &&
  resource.spec.deploymentSpec.env.exists(e, e.name == "agent_role")
actionType: ALLOW
displayName: Enforce OTEL Config with Metadata Tags for Reasoning Engines
description: >
  Ensures all Reasoning Engines deploy with OpenTelemetry enabled and
  required organizational metadata tags for cost attribution and audit.
```

### Deployment Commands

```bash
# 1. Register the custom constraint
gcloud org-policies set-custom-constraint enforce-otel-config.yaml

# 2. Enforce it on the target project
gcloud org-policies set-policy policy-enforce-otel-config.yaml
```

### What This Enables

Once enforced, Cloud Monitoring and Cloud Trace dashboards can answer:

- *"How many tokens did the Engineering department consume this month?"*
- *"Which agent is responsible for the cost spike on Tuesday?"*
- *"What was the average latency for the `eng_coder` agent last week?"*
- *"Are any agents exceeding their token budget?"*

---

## Policy 3: Enforce Agent Gateway Configuration (Ingress & Egress)

### Problem

Without network governance, agents deployed on Vertex AI can:
- **Call any external API** — no egress control, data exfiltration risk.
- **Accept requests from any source** — no ingress authentication.
- **Bypass DLP and security scanning** — no TLS inspection point.
- **Evade audit** — no central logging of agent-to-external traffic.

### Solution

Enforce that every Reasoning Engine is deployed with **Agent Gateway** configuration, establishing a dual-gate security perimeter:

| Gateway | Direction | Purpose |
|---------|-----------|---------|
| **Ingress Gateway** (`clientToAgentConfig`) | Client → Agent | Authenticates callers, enforces Semantic Governance Policies (SGP), rate limiting |
| **Egress Gateway** (`agentToAnywhereConfig`) | Agent → External | Controls outbound destinations, enables TLS inspection, DLP scanning via Model Armor |

### Constraint Definition

```yaml
name: organizations/{ORG_ID}/customConstraints/custom.EnforceReasoningEngineAgentGatewayConfig
resourceTypes:
  - aiplatform.googleapis.com/ReasoningEngine
methodTypes:
  - CREATE
  - UPDATE
condition: >-
  !has(resource.spec.deploymentSpec) ||
  !has(resource.spec.deploymentSpec.agentGatewayConfig) ||
  !has(resource.spec.deploymentSpec.agentGatewayConfig.clientToAgentConfig) ||
  !has(resource.spec.deploymentSpec.agentGatewayConfig.agentToAnywhereConfig)
actionType: DENY
displayName: Enforce Ingress and Egress Gateway for Reasoning Engines
description: >
  Reasoning Engines must be deployed with both Ingress (clientToAgentConfig)
  and Egress (agentToAnywhereConfig) gateways defined in deploymentSpec.
```

### Deployment Commands

```bash
# 1. Register the custom constraint
gcloud org-policies set-custom-constraint enforce-agent-gateway-config.yaml

# 2. Enforce it on the target project
gcloud org-policies set-policy policy-enforce-agent-gateway-config.yaml
```

### Gateway Config Structure

When the policy is enforced, every Reasoning Engine deployment must include:

```json
{
  "spec": {
    "deploymentSpec": {
      "agentGatewayConfig": {
        "clientToAgentConfig": {
          "agentGateway": "projects/{PROJECT}/locations/{REGION}/agentGateways/{INGRESS_GW}"
        },
        "agentToAnywhereConfig": {
          "agentGateway": "projects/{PROJECT}/locations/{REGION}/agentGateways/{EGRESS_GW}"
        }
      }
    }
  }
}
```

---

## Terraform Automation

All three policies are codified as Terraform and can be applied in a single `terraform apply`:

```hcl
# 05_org_policies.tf — Three custom constraints + three enforcement policies

resource "google_org_policy_custom_constraint" "agent_gateway_config" {
  name           = "custom.${local.safe_prefix}EnforceReasoningEngineAgentGatewayConfig"
  parent         = "organizations/${var.organization_id}"
  action_type    = "ALLOW"
  condition      = "has(resource.spec.deploymentSpec.agentGatewayConfig.agentToAnywhereConfig)"
  method_types   = ["CREATE", "UPDATE"]
  resource_types = ["aiplatform.googleapis.com/ReasoningEngine"]
}

resource "google_org_policy_custom_constraint" "agent_identity" {
  name           = "custom.${local.safe_prefix}EnforceAgentIdentityForReasoningEngine"
  parent         = "organizations/${var.organization_id}"
  action_type    = "ALLOW"
  condition      = "resource.spec.identityType == \"AGENT_IDENTITY\""
  method_types   = ["CREATE", "UPDATE"]
  resource_types = ["aiplatform.googleapis.com/ReasoningEngine"]
}

resource "google_org_policy_custom_constraint" "otel_config" {
  name           = "custom.${local.safe_prefix}EnforceReasoningEngineOtelConfig"
  parent         = "organizations/${var.organization_id}"
  action_type    = "ALLOW"
  condition      = <<-CEL
    has(resource.spec.deploymentSpec.env) &&
    resource.spec.deploymentSpec.env.exists(e,
      e.name == "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY") &&
    resource.spec.deploymentSpec.env.exists(e, e.name == "agent_name") &&
    resource.spec.deploymentSpec.env.exists(e, e.name == "agent_department") &&
    resource.spec.deploymentSpec.env.exists(e, e.name == "agent_team") &&
    resource.spec.deploymentSpec.env.exists(e, e.name == "agent_role")
  CEL
  method_types   = ["CREATE", "UPDATE"]
  resource_types = ["aiplatform.googleapis.com/ReasoningEngine"]
}

# Enforce all three at the project level
resource "google_org_policy_policy" "enforce_agent_gateway_config" {
  name   = "projects/${var.project_id}/policies/${google_org_policy_custom_constraint.agent_gateway_config.name}"
  parent = "projects/${var.project_id}"
  spec { rules { enforce = "TRUE" } }
}

resource "google_org_policy_policy" "enforce_agent_identity" {
  name   = "projects/${var.project_id}/policies/${google_org_policy_custom_constraint.agent_identity.name}"
  parent = "projects/${var.project_id}"
  spec { rules { enforce = "TRUE" } }
}

resource "google_org_policy_policy" "enforce_otel_config" {
  name   = "projects/${var.project_id}/policies/${google_org_policy_custom_constraint.otel_config.name}"
  parent = "projects/${var.project_id}"
  spec { rules { enforce = "TRUE" } }
}
```

> [!TIP]
> A `time_sleep` resource with `create_duration = "180s"` is recommended between constraint creation and policy enforcement to handle eventual consistency in the Organization Policy API.

---

## Verification & Testing

### What Happens When an Agent Violates a Policy?

The Vertex AI API returns a **400 Bad Request** with a clear policy violation message:

```
Operation denied by custom org policy:
  ["customConstraints/custom.EnforceAgentIdentityForReasoningEngine"]:
  Ensures Reasoning Engines are deployed with AGENT_IDENTITY.
```

### Recommended Test Matrix

| Test Case | Expected Result |
|-----------|----------------|
| Deploy with `identityType: USER_IDENTITY` | ❌ **Blocked** by Agent Identity policy |
| Deploy without `GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY` | ❌ **Blocked** by OTEL policy |
| Deploy without `agent_department` tag | ❌ **Blocked** by OTEL policy |
| Deploy without `agentGatewayConfig` | ❌ **Blocked** by Gateway policy |
| Deploy with only ingress gateway (no egress) | ❌ **Blocked** by Gateway policy |
| Deploy with all three requirements satisfied | ✅ **Allowed** |

---

## Summary: Defense in Depth

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Organization Level                         │
│                                                                     │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │              Custom Organization Policies                   │   │
│   │                                                             │   │
│   │  ┌─────────────┐ ┌──────────────┐ ┌─────────────────────┐  │   │
│   │  │   Agent      │ │    OTEL +    │ │  Agent Gateway      │  │   │
│   │  │   Identity   │ │  Metadata    │ │  Ingress + Egress   │  │   │
│   │  │   (SPIFFE)   │ │    Tags      │ │  (Dual-Gate)        │  │   │
│   │  └──────┬───────┘ └──────┬───────┘ └──────────┬──────────┘  │   │
│   │         │                │                     │            │   │
│   │         ▼                ▼                     ▼            │   │
│   │   Per-agent        Token-level          Network perimeter   │   │
│   │   audit trail      cost attribution     TLS inspection      │   │
│   │   Zero-trust       Anomaly detection    DLP / Model Armor   │   │
│   │   Blast radius     Compliance proof     Egress control      │   │
│   └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│         Enforced on every CREATE and UPDATE — no exceptions          │
└─────────────────────────────────────────────────────────────────────┘
```

### Prerequisites

| Requirement | Details |
|-------------|---------|
| **API** | `orgpolicy.googleapis.com` enabled on the project |
| **IAM** | `roles/orgpolicy.policyAdmin` on the org or folder |
| **Agent Gateway** | Ingress and Egress gateways pre-created via Terraform |
| **Terraform Provider** | `google` provider ≥ 5.x with `google_org_policy_custom_constraint` support |

> [!NOTE]
> These policies are evaluated at the **API layer** — they apply regardless of whether agents are deployed via the ADK CLI, Terraform, REST API, or any custom tooling. This makes them the strongest enforcement mechanism available for agentic governance on Google Cloud.
