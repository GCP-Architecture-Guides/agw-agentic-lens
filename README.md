# Agentic Governance on Google Cloud — Agent Gateway Foundation

**End-to-end security, observability, and network governance for AI agents deployed on Vertex AI Agent Engine.**

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

---

## What This Repository Provides

This repository is a **production-ready Terraform foundation** that creates a fully governed environment for deploying AI agents on [Vertex AI Agent Engine](https://cloud.google.com/vertex-ai/docs/reasoning-engine/overview) (Reasoning Engine). It implements **defense-in-depth** across six layers:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                     Agent Gateway Governance Stack                          │
│                                                                              │
│  ┌───────────────┐ ┌──────────────────┐ ┌──────────────────────────────┐    │
│  │ Org Policies   │ │  Agent Gateway   │ │  Security & Content Policies │    │
│  │ (3 Custom)     │ │  Ingress+Egress  │ │  Model Armor + DLP + SGP    │    │
│  └───────┬───────┘ └────────┬─────────┘ └──────────────┬───────────────┘    │
│          │                  │                            │                   │
│  ┌───────┴───────┐ ┌───────┴──────────┐ ┌──────────────┴───────────────┐    │
│  │ IAM & IAP     │ │  Observability   │ │  Agent Provisioning          │    │
│  │ Identity Ctrl │ │  Dashboards +    │ │  GatewayAgent SDK +          │    │
│  │               │ │  Alerts          │ │  Automated Deploy            │    │
│  └───────────────┘ └──────────────────┘ └──────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Table of Contents

- [Architecture](#architecture)
- [Governance Layers](#governance-layers)
  - [1. Organization Policies](#1-organization-policies)
  - [2. Agent Gateway (Ingress & Egress)](#2-agent-gateway-ingress--egress)
  - [3. Model Armor & DLP](#3-model-armor--dlp)
  - [4. Semantic Governance Policies (SGP)](#4-semantic-governance-policies-sgp)
  - [5. IAM & Identity Controls](#5-iam--identity-controls)
  - [6. Observability & Alerting](#6-observability--alerting)
- [Agent Example](#agent-example)
- [Quick Start](#quick-start)
- [Repository Structure](#repository-structure)
- [Prerequisites](#prerequisites)

---

## Architecture

```
                          ┌─────────────────────┐
                          │     Clients /        │
                          │     Applications     │
                          └──────────┬──────────┘
                                     │
                          ┌──────────▼──────────┐
                          │   Ingress Gateway    │ ← IAP (identity) + Model Armor (content)
                          │   CLIENT_TO_AGENT    │   + Prompt Injection filter
                          └──────────┬──────────┘
                                     │
                     ┌───────────────▼───────────────┐
                     │       Vertex AI Agent Engine   │
                     │       (Reasoning Engine)       │
                     │                                 │
                     │  ┌──────────────────────────┐  │
                     │  │  Agent (GatewayAgent SDK) │  │
                     │  │  • AGENT_IDENTITY         │  │
                     │  │  • OTEL telemetry enabled │  │
                     │  │  • Metadata tags attached │  │
                     │  └──────────────────────────┘  │
                     └───────────────┬───────────────┘
                                     │
                          ┌──────────▼──────────┐
                          │   Egress Gateway     │ ← Model Armor + SGP (semantic)
                          │   AGENT_TO_ANYWHERE  │   + PSC allowlist
                          │                      │
                          │  ┌────────────────┐  │
                          │  │ PSC Network    │  │
                          │  │ Attachment     │  │
                          │  └────────────────┘  │
                          └──────────┬──────────┘
                                     │
                          ┌──────────▼──────────┐
                          │  Allowed External    │
                          │  APIs Only           │
                          │  (googleapis.com)    │
                          └─────────────────────┘
```

---

## Governance Layers

### 1. Organization Policies

> **Terraform**: [`terraform/foundation/05_org_policies.tf`](terraform/foundation/05_org_policies.tf)
> **Docs**: [`docs/org-policy-guardrails.md`](docs/org-policy-guardrails.md)

Three custom Organization Policy constraints enforced on **every** `CREATE` and `UPDATE` to `aiplatform.googleapis.com/ReasoningEngine`:

| Constraint | CEL Condition | What It Blocks |
|-----------|---------------|----------------|
| **Agent Identity** | `resource.spec.identityType == "AGENT_IDENTITY"` | Agents using `USER_IDENTITY` (privilege escalation risk) |
| **OTEL + Metadata** | `env.exists(e, e.name == "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY")` + 5 tag checks | Agents without telemetry or organizational tags |
| **Gateway Config** | `has(resource.spec.deploymentSpec.agentGatewayConfig.agentToAnywhereConfig)` | Agents without egress gateway routing |

**How it works**: These constraints use [Custom Organization Policy](https://cloud.google.com/resource-manager/docs/organization-policy/creating-managing-custom-constraints) with CEL expressions. They are evaluated at the API layer — no agent can bypass them, regardless of the deployment tool (ADK CLI, Terraform, REST API).

```yaml
# Example: Agent Identity constraint
name: organizations/{ORG_ID}/customConstraints/custom.EnforceAgentIdentityForReasoningEngine
resourceTypes:
  - aiplatform.googleapis.com/ReasoningEngine
methodTypes:
  - CREATE
  - UPDATE
condition: 'resource.spec.identityType == "AGENT_IDENTITY"'
actionType: ALLOW
```

When violated, the API returns:
```
Operation denied by custom org policy:
  ["customConstraints/custom.EnforceAgentIdentityForReasoningEngine"]:
  Ensures Reasoning Engines are deployed with AGENT_IDENTITY.
```

---

### 2. Agent Gateway (Ingress & Egress)

> **Terraform**: [`terraform/foundation/02_network.tf`](terraform/foundation/02_network.tf)

The Agent Gateway is a Google-managed, dual-gate security perimeter:

| Gateway | Direction | Resource Type | Purpose |
|---------|-----------|---------------|---------|
| **Ingress** | Client → Agent | `CLIENT_TO_AGENT` | Authenticates callers, enforces content policies on incoming prompts |
| **Egress** | Agent → External | `AGENT_TO_ANYWHERE` | Controls outbound traffic, enables TLS inspection, DLP scanning |

```hcl
# Ingress Gateway
resource "google_network_services_agent_gateway" "ingress_gateway" {
  name     = "${var.prefix}-ingress-gateway"
  location = var.location
  google_managed {
    governed_access_path = "CLIENT_TO_AGENT"
  }
}

# Egress Gateway with PSC Network Attachment
resource "google_network_services_agent_gateway" "egress_gateway" {
  name     = "${var.prefix}-egress-gateway"
  location = var.location
  google_managed {
    governed_access_path = "AGENT_TO_ANYWHERE"
  }
  network_config {
    egress {
      network_attachment = google_compute_network_attachment.psc_network_attachment.id
    }
  }
}
```

**Key design**: The egress gateway uses a **PSC (Private Service Connect) network attachment** for routing. Hosts not registered in the PSC routing table are unreachable — deny-by-default at the network layer.

---

### 3. Model Armor & DLP

> **Terraform**: [`terraform/foundation/03_security_and_gateways.tf`](terraform/foundation/03_security_and_gateways.tf)

Model Armor provides **content-level authorization** on both ingress and egress gateways:

```
┌──────────────────────────────────────────────────┐
│              Model Armor Template                 │
│                                                    │
│  ┌──────────────────┐  ┌───────────────────────┐  │
│  │ Prompt Injection  │  │ Responsible AI (RAI)  │  │
│  │ & Jailbreak       │  │ • Hate Speech         │  │
│  │ Detection         │  │ • Harassment          │  │
│  │ (HIGH confidence) │  │ • Sexually Explicit   │  │
│  │                   │  │ • Dangerous Content   │  │
│  └──────────────────┘  └───────────────────────┘  │
│                                                    │
│  ┌──────────────────┐  ┌───────────────────────┐  │
│  │ DLP / SDP        │  │ Malicious URI         │  │
│  │ • SSN            │  │ Filter                │  │
│  │ • Credit Card    │  │                       │  │
│  │ • GCP Credentials│  │                       │  │
│  │ • Medical (ICD)  │  │                       │  │
│  └──────────────────┘  └───────────────────────┘  │
└──────────────────────────────────────────────────┘
```

**Authz policy attachment**:
```hcl
# Attach Model Armor to Ingress Gateway
resource "google_network_security_authz_policy" "ingress_ma_policy" {
  name           = "${var.prefix}-ma-policy"
  action         = "CUSTOM"
  policy_profile = "CONTENT_AUTHZ"
  target {
    resources = [google_network_services_agent_gateway.ingress_gateway.id]
  }
  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.ma_extension.id]
    }
  }
}
```

**DLP info types scanned**: SSN, email addresses, GCP API keys, GCP credentials, credit card numbers, blood types, FDA/ICD codes, medical terms.

---

### 4. Semantic Governance Policies (SGP)

> **Terraform**: [`terraform/foundation/02_network.tf`](terraform/foundation/02_network.tf) (network), [`terraform/foundation/03_security_and_gateways.tf`](terraform/foundation/03_security_and_gateways.tf) (policy)

SGP provides **AI-native content governance** — it understands the semantic intent of agent communications, not just pattern matching.

**Infrastructure**:
```
┌────────────────────┐     ┌──────────────────────┐
│  Egress Gateway    │────▶│  SGP Engine           │
│                    │     │  (Vertex AI RE)        │
│  CONTENT_AUTHZ     │     │                        │
│  policy attached   │     │  Evaluates semantic    │
│                    │     │  rules on ALL outbound │
│                    │     │  agent traffic          │
└────────────────────┘     └──────────┬─────────────┘
                                      │ PSC
                           ┌──────────▼─────────────┐
                           │  Private DNS Zone       │
                           │  sgp.internal.gemini-   │
                           │  corp → PSC IP          │
                           └────────────────────────┘
```

**SGP connectivity chain** (Terraform-provisioned):
1. **SGP Engine** — Auto-provisioned Reasoning Engine with governance rules
2. **PSC Network Attachment** — Private connectivity from egress gateway to SGP
3. **Private DNS Zone** — `sgp.internal.gemini-corp` resolves to the PSC endpoint
4. **Authz Extension + Policy** — Attached to the egress gateway with `CONTENT_AUTHZ` profile

```hcl
# SGP authz policy — evaluates ALL outbound content semantically
resource "google_network_security_authz_policy" "egress_sgp_policy" {
  name           = "${var.prefix}-sgp-egress-policy"
  action         = "CUSTOM"
  policy_profile = "CONTENT_AUTHZ"
  target {
    resources = [google_network_services_agent_gateway.egress_gateway.id]
  }
  # NOTE: SGP CONTENT_AUTHZ does NOT support http_rules —
  # it evaluates ALL outbound content semantically by design.
}
```

---

### 5. IAM & Identity Controls

> **Terraform**: [`terraform/foundation/03_security_and_gateways.tf`](terraform/foundation/03_security_and_gateways.tf)

#### Agent Identity (SPIFFE)

Every agent runs with a unique `AGENT_IDENTITY` — a SPIFFE-based principal (`principal://agents.googleapis.com/...`). This enables:
- **Per-agent audit trails** in Cloud Audit Logs
- **Zero-trust IAM** — each agent gets only the permissions it needs
- **Blast radius containment** — compromising one agent doesn't expose others

#### IAP (Identity-Aware Proxy) on Ingress Gateway

Optional but recommended — gates **who** can call the gateway before content policies evaluate **what** they're sending:

```hcl
# IAP Extension — delegates access decisions to IAP
resource "google_network_services_authz_extension" "iap_extension" {
  count   = var.iap_enabled ? 1 : 0
  name    = "${var.prefix}-iap-extension"
  service = "iap.googleapis.com"     # Global endpoint (not regional)
  timeout = "1s"
  metadata = {
    iapPolicyVersion = "V1"          # Required — fails without this
  }
}

# IAP Policy on Ingress Gateway
resource "google_network_security_authz_policy" "ingress_iap_policy" {
  count          = var.iap_enabled ? 1 : 0
  action         = "CUSTOM"
  policy_profile = "REQUEST_AUTHZ"   # Identity check (not content)
  target {
    resources = [google_network_services_agent_gateway.ingress_gateway.id]
  }
}
```

**Combined pattern** (recommended by Google Cloud docs):

| Layer | Policy Profile | Extension | Purpose |
|-------|---------------|-----------|---------|
| 1 | `REQUEST_AUTHZ` | IAP | **Who** can access the gateway |
| 2 | `CONTENT_AUTHZ` | Model Armor | **What** content is allowed through |
| 3 | `CONTENT_AUTHZ` | SGP | **Semantic** governance on agent output |

#### Vertex AI Audit Logs

Data Access audit logs are enabled for `aiplatform.googleapis.com` (both `DATA_READ` and `DATA_WRITE`), capturing every prompt and response in Cloud Audit Logs.

---

### 6. Observability & Alerting

> **Terraform**: [`terraform/foundation/04_observability.tf`](terraform/foundation/04_observability.tf)

Three observability modules provide comprehensive monitoring:

#### Agent Observability (`agent_observability`)
Token-level monitoring and cost attribution per agent, powered by the OTEL metadata tags enforced by org policy.

| Alert | Trigger | Purpose |
|-------|---------|---------|
| **Baseline Spike** | Agent token usage exceeds N% above its rolling baseline | Detect prompt injection loops |
| **Runaway Loop** | Agent makes >N LLM calls with >M tokens in T seconds | Stop infinite agent loops |
| **Project Surge** | Total project token usage exceeds threshold | Budget protection |
| **Absolute Ceiling** | Single agent exceeds hard token limit | Per-agent guardrail |
| **Error Correlation** | High tokens + high errors simultaneously | Detect retry storms |
| **Zero Traffic** | Agent receives no traffic for T seconds | Availability monitoring |

#### Gateway Observability (`gateway_observability`)
Monitors ingress/egress gateway traffic patterns, latencies, and error rates.

#### Model Armor Security Alerts (`lens_model_armor`)
Real-time alerting on security events:
- **Prompt injection attempts** detected by Model Armor
- **DLP violations** — PII found in prompts/responses
- **RAI violations** — harmful content detected
- Alerts can be sent to **Google Chat**, **Slack**, or **email**

#### Org-Wide Observability (`org_observability`)
Optional cross-project monitoring scope for organizations managing multiple agent projects.

**Dashboard queries powered by OTEL metadata tags:**
```
# "How many tokens did the Engineering department consume this month?"
fetch aiplatform.googleapis.com/agent_engine
| filter metric.agent_department == "Engineering"
| group_by [metric.agent_name], sum(value.token_count)

# "Which agent is causing the cost spike?"
fetch aiplatform.googleapis.com/agent_engine
| group_by [metric.agent_name, metric.agent_team], sum(value.total_tokens)
| sort -sum_total_tokens
| top 5
```

---

## Agent Example

> **Code**: [`agents/chat/agent.py`](agents/chat/agent.py)

A clean, production-ready ADK agent that demonstrates all governance integrations:

```python
from google.adk.agents import LlmAgent

def fetch_url(url: str) -> str:
    """Fetch a URL through the Agent Gateway egress proxy.
    
    Routes through HTTPS_PROXY when set by the Agent Gateway runtime.
    Returns [GATEWAY BLOCKED] on connection failure so the model
    cannot silently fall back to training-data hallucinations.
    """
    # ... routes through egress gateway PSC allowlist ...

root_agent = LlmAgent(
    name="chat_agent",
    model="gemini-2.5-flash",
    description="A GCP brand ambassador with governed egress.",
    instruction=BRAND_AMBASSADOR_INSTRUCTION,
    tools=[fetch_url],
)
```

**Key patterns**:
- `fetch_url` explicitly routes through `HTTPS_PROXY` / `HTTP_PROXY` set by the gateway runtime
- Returns `[GATEWAY BLOCKED]` on `ConnectionError` — prevents hallucination fallback
- The agent instructs the model to **never infer content** for blocked URLs

---

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/GCP-Architecture-Guides/agw-agentic-lens.git
cd agw-agentic-lens/terraform/foundation

cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values:
#   project_id, organization_id, location, prefix
```

### 2. Deploy the foundation

```bash
terraform init
terraform plan
terraform apply
```

This creates (~10 minutes):
- VPC with PSC subnets
- Ingress + Egress Agent Gateways
- Model Armor templates with DLP
- SGP engine with private DNS
- Observability dashboards & alerts
- Organization Policy constraints
- Optional: IAP on ingress gateway

### 3. Deploy your agent

```bash
# The foundation generates a deploy script:
./scripts/deploy_chat_agent.sh
```

### 4. Verify governance

```bash
./scripts/verify_policies.sh YOUR_ORG_ID YOUR_PROJECT_ID your-prefix
```

---

## Repository Structure

```
.
├── README.md                                    # This file
├── LICENSE                                      # Apache 2.0
│
├── terraform/
│   └── foundation/                              # Complete Terraform module
│       ├── 01_apis.tf                           # 20+ API enablements
│       ├── 02_network.tf                        # VPC, PSC, Agent Gateways, SGP networking
│       ├── 03_security_and_gateways.tf          # Model Armor, DLP, SGP, IAP policies
│       ├── 04_observability.tf                  # Dashboards, alerts, notification channels
│       ├── 05_org_policies.tf                   # 3 custom org policy constraints
│       ├── 06_agent_provisioning.tf             # Automated agent deploy script generation
│       ├── variables.tf                         # All configurable parameters
│       ├── outputs.tf                           # Gateway names, constraint names
│       ├── providers.tf                         # Google provider config
│       └── terraform.tfvars.example             # Template with placeholder values
│
├── agents/
│   └── chat/                                    # Example ADK agent
│       ├── agent.py                             # Clean agent with governed egress
│       └── requirements.txt                     # Pinned dependencies
│
├── docs/
│   └── org-policy-guardrails.md                 # Detailed org policy documentation
│
└── scripts/
    └── verify_policies.sh                       # Post-deploy verification script
```

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **Terraform** | >= 1.5 |
| **Google Provider** | >= 5.0 (with `google-beta` for Agent Gateway resources) |
| **APIs** | 20+ APIs (auto-enabled by `01_apis.tf`) |
| **IAM** | `roles/owner` on the project, `roles/orgpolicy.policyAdmin` on the org |
| **GCP Region** | Must support: Agent Engine, Agent Gateway, Model Armor, SGP |
| **Agent SDK** | `google-adk >= 1.5.0`, `google-cloud-aiplatform >= 1.149.0` |

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **AGENT_IDENTITY enforced** | Prevents privilege escalation; enables per-agent audit trails |
| **Egress deny-by-default** | PSC routing means unregistered hosts are unreachable at network layer |
| **Model Armor on INPUT only** | Vertex AI wraps `:streamQuery` responses in gRPC-HTTP transcoding that falsely triggers PI/Jailbreak filter. Model response safety relies on Gemini's built-in harm filters |
| **SGP without http_rules** | SGP `CONTENT_AUTHZ` evaluates ALL content semantically — http_rules are not supported by the API |
| **IAP on ingress only** | IAP on egress BREAKS outbound calls — RE containers don't carry IAP tokens on outbound requests |
| **OTEL metadata tags** | 5 required tags enable cost attribution by agent/department/team without custom instrumentation |

---

## License

```
Copyright 2024 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
