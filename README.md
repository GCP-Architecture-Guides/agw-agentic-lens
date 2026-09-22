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

## Multi-Agent Architecture

This project implements a **hierarchical multi-agent system** with 13 specialized agents organized into departments. Each agent is deployed as its own Reasoning Engine with independent SPIFFE identity, OTEL telemetry, and gateway routing.

### Agent Hierarchy

```
                              ┌──────────────────┐
                              │    Supervisor     │  gemini-2.5-flash
                              │  (Orchestrator)   │  Routes to departments
                              └────────┬─────────┘
                    ┌──────────────────┼──────────────────┐
                    │                  │                    │
          ┌─────────▼────────┐ ┌──────▼────────┐ ┌───────▼────────┐
          │   Engineering    │ │   X-Ray        │ │     Chat       │
          │   Department     │ │   Department   │ │   (Direct)     │
          └─────────┬────────┘ └──────┬────────┘ └───────┬────────┘
                    │                  │                    │
      ┌─────────────┼──────────┐     │              ┌─────▼─────────┐
      │             │          │     │              │ Brand         │
┌─────▼──────┐ ┌───▼────┐ ┌───▼──┐  │              │ Ambassador   │
│ eng_scout  │ │eng_coder│ │eng_  │  │              │ gemini-2.5-  │
│ Research   │ │IaC Code │ │sent. │  │              │ flash        │
│ 2.5-flash  │ │2.5-pro  │ │2.5-  │  │              └──────────────┘
└────────────┘ └────────┘ │flash │  │
                          └──────┘  │
              ┌────────┐            │
              │eng_qsr │      ┌─────┼──────────────┐
              │Review  │      │     │              │
              │2.5-flash│ ┌───▼────┐│┌────────┐┌───▼─────┐┌──────────┐
              └────────┘ │xray_   │││xray_   ││xray_    ││xray_     │
                         │architect│││specialist│auditor  ││librarian │
                         │2.5-pro ││└────────┘└─────────┘└──────────┘
                         └────────┘│ 2.5-pro    2.5-pro    (default)
                                   │
                             ┌─────▼──────┐
                             │xray_manager│
                             │2.5-pro     │
                             └────────────┘
```

### Agent Roster

| Agent | Model | Department | Role |
|-------|-------|------------|------|
| **supervisor** | `gemini-2.5-flash` | — | Top-level orchestrator, routes queries to department heads |
| **eng_lead** | `gemini-2.5-pro` | Engineering | Department head, coordinates engineering specialists |
| **eng_scout** | `gemini-2.5-flash` | Engineering | Research & discovery — finds GCP docs and architecture patterns |
| **eng_coder** | `gemini-2.5-pro` | Engineering | Generates Terraform / IaC code for GCP solutions |
| **eng_sentinel** | `gemini-2.5-flash` | Engineering | Security & compliance checks on generated code |
| **eng_quality_and_security_reviewer** | `gemini-2.5-flash` | Engineering | Code review with security focus |
| **xray_manager** | `gemini-2.5-pro` | X-Ray | Department head, coordinates architecture review specialists |
| **xray_architect** | `gemini-2.5-pro` | X-Ray | Deep architecture analysis and recommendations |
| **xray_specialist** | `gemini-2.5-pro` | X-Ray | Specialized domain expertise |
| **xray_auditor** | `gemini-2.5-pro` | X-Ray | Compliance and audit review |
| **xray_librarian** | (inherited) | X-Ray | Knowledge base and documentation management |
| **chat** | `gemini-2.5-flash` | Direct | Google Cloud brand ambassador with governed egress |
| **events** | `gemini-2.5-flash` | Direct | Event and conference information agent |

### Inter-Agent Communication

All 13 agents are deployed as independent Reasoning Engines. The supervisor agent orchestrates by calling department heads, who in turn delegate to specialists:

```
User → Supervisor → eng_lead → eng_scout (research)
                              → eng_coder (generate)
                              → eng_sentinel (validate)
                              → eng_quality_and_security_reviewer (review)

User → Supervisor → xray_manager → xray_architect (analyze)
                                  → xray_specialist (deep dive)
                                  → xray_auditor (compliance)
                                  → xray_librarian (reference)
```

Every inter-agent call flows through the **egress gateway**, subject to Model Armor content scanning, SGP semantic evaluation, and PSC routing enforcement.

### Agent Example — Chat Agent with Governed Egress

> **Code**: [`agents/chat/agent.py`](agents/chat/agent.py)

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
    name="agentic_prism_chat",
    model="gemini-2.5-flash",
    description="The Google Cloud Brand Ambassador.",
    instruction=BRAND_AMBASSADOR_INSTRUCTION,
    tools=[fetch_url],
)
```

**Key patterns**:
- `fetch_url` explicitly routes through `HTTPS_PROXY` / `HTTP_PROXY` set by the gateway runtime
- Returns `[GATEWAY BLOCKED]` on `ConnectionError` — prevents hallucination fallback
- The agent instructs the model to **never infer content** for blocked URLs

---

## Glass UI — Frontend Application

> **Code**: [`ui/`](ui/)

The system includes a web-based **Glass UI** built on FastAPI that provides a polished chat interface for interacting with the multi-agent system.

### Architecture

```
┌────────────────────┐        ┌─────────────────────┐
│   Browser          │        │  Cloud Run           │
│   (Glass UI SPA)   │───────▶│  glass_ui_api.py     │
│                    │        │                       │
│  • Chat interface  │        │  • FastAPI backend    │
│  • Demo scenarios  │        │  • Routes to agents   │
│  • Agent selector  │        │  • Landing bypass     │
└────────────────────┘        │  • Health checks      │
                              └──────────┬────────────┘
                                         │
                              ┌──────────▼────────────┐
                              │  Vertex AI Agent       │
                              │  Engine (via           │
                              │  Ingress Gateway)      │
                              └────────────────────────┘
```

### UI Features
- **Agent Selector** — Switch between Chat, Engineering, and X-Ray agents
- **Demo Scenarios** — Pre-built prompts showcasing governance features
- **Streaming Responses** — Real-time streaming from Reasoning Engines
- **Landing Form Bypass** — Auto-dismisses welcome forms for demo environments

### Build & Deploy

```bash
# Build the patched UI image
gcloud builds submit . \
  --config=cloudbuild.yaml \
  --project=YOUR_PROJECT_ID

# Deploy to Cloud Run
gcloud run deploy your-ui-service \
  --image=REGION-docker.pkg.dev/YOUR_PROJECT_ID/your-registry/your-image:latest \
  --region=YOUR_REGION \
  --project=YOUR_PROJECT_ID
```

---

## Deployment Pipeline

> **Script**: [`scripts/deploy.sh`](scripts/deploy.sh)

The deploy script handles the complete lifecycle for all 13 agents:

```
┌──────────────────────────────────────────────────────────┐
│                    deploy.sh Pipeline                      │
│                                                            │
│  1. Source versions.env (PROJECT_ID, REGION, MODEL)        │
│  2. Clean up stale staging directories                     │
│  3. Inject MODEL_VERSION into agent.yaml files             │
│  4. Pre-flight: version pin validation                     │
│  5. GatewayAgent SDK compliance check                      │
│  6. For each agent (parallel, up to 8):                    │
│     a. Check for existing RE with same name                │
│     b. Pass --agent_engine_id for UPDATE (not CREATE)      │
│     c. adk deploy agent_engine                             │
│     d. Post-deploy: strip contextSpec                      │
│     e. Grant AGENT_IDENTITY IAM bindings                   │
│  7. Re-merge peer engine IDs for inter-agent routing       │
│  8. Report results                                         │
└──────────────────────────────────────────────────────────┘
```

### Configuration

```bash
# versions.env.example
PROJECT_ID=YOUR_PROJECT_ID
REGION=us-east1
ORG_ID=YOUR_ORG_ID
MODEL_VERSION=gemini-2.5-pro
AGENT_GATEWAY_INGRESS=projects/YOUR_PROJECT_NUMBER/locations/us-east1/agentGateways/your-prefix-ingress-gateway
AGENT_GATEWAY_EGRESS=projects/YOUR_PROJECT_NUMBER/locations/us-east1/agentGateways/your-prefix-egress-gateway
```

### Deploy Commands

```bash
# Deploy ALL agents (parallel)
./scripts/deploy.sh

# Deploy specific agents only
./scripts/deploy.sh supervisor chat eng_lead eng_coder

# Skip agents that already exist
SKIP_EXISTING=1 ./scripts/deploy.sh

# Deploy X-Ray department only
./scripts/deploy.sh xray_manager xray_architect xray_specialist xray_auditor xray_librarian
```

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

### 3. Deploy agents

```bash
# Configure
cp versions.env.example versions.env
# Edit versions.env with your project details

# Deploy all 13 agents
./scripts/deploy.sh
```

### 4. Deploy the UI

```bash
# Build and deploy Glass UI to Cloud Run
cd ui/
gcloud builds submit . --project=YOUR_PROJECT_ID
```

### 5. Verify governance

```bash
./scripts/verify_policies.sh YOUR_ORG_ID YOUR_PROJECT_ID your-prefix
```

---

## Repository Structure

```
.
├── README.md                                    # This file
├── LICENSE                                      # Apache 2.0
├── versions.env.example                         # Configuration template
│
├── agents/                                      # All 13 agents (business logic only)
│   ├── supervisor/                              # Top-level orchestrator
│   │   ├── agent.py                             # Routes to department heads
│   │   ├── agent.yaml                           # ADK config
│   │   └── requirements.txt
│   ├── chat/                                    # Brand ambassador + governed egress
│   │   ├── agent.py
│   │   └── requirements.txt
│   ├── eng_lead/                                # Engineering department head
│   ├── eng_scout/                               # Research & discovery
│   ├── eng_coder/                               # IaC code generation
│   ├── eng_sentinel/                            # Security validation
│   ├── eng_quality_and_security_reviewer/       # Code review
│   ├── xray_manager/                            # X-Ray department head
│   ├── xray_architect/                          # Architecture analysis
│   ├── xray_specialist/                         # Domain expertise
│   ├── xray_auditor/                            # Compliance review
│   ├── xray_librarian/                          # Knowledge management
│   └── events/                                  # Event information
│
├── terraform/
│   └── foundation/                              # Complete Terraform module
│       ├── 01_apis.tf                           # 20+ API enablements
│       ├── 02_network.tf                        # VPC, PSC, Agent Gateways, SGP networking
│       ├── 03_security_and_gateways.tf          # Model Armor, DLP, SGP, IAP policies
│       ├── 04_observability.tf                  # Dashboards, alerts, notification channels
│       ├── 05_org_policies.tf                   # 3 custom org policy constraints
│       ├── 06_agent_provisioning.tf             # Automated agent deploy script generation
│       ├── variables.tf                         # 40+ configurable parameters
│       ├── outputs.tf                           # Gateway names, constraint names
│       ├── providers.tf                         # Google provider config
│       └── terraform.tfvars.example             # Template with placeholder values
│
├── ui/                                          # Glass UI (FastAPI + SPA)
│   ├── glass_ui_api.py                          # FastAPI backend (1200+ lines)
│   ├── Dockerfile                               # Container build
│   └── patch_scenarios.sh                       # Demo scenario customization
│
├── docs/
│   └── org-policy-guardrails.md                 # Detailed org policy documentation
│
└── scripts/
    ├── deploy.sh                                # Multi-agent deploy pipeline
    └── verify_policies.sh                       # Post-deploy verification
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
