
"""
Engineering Lead — Orchestrator for Scout, Coder, Sentinel.
Exposes orchestrate_build as the single tool; instruction tells the model to call it with the user query.
"""
from google.adk.agents import LlmAgent
from google.adk.tools import FunctionTool

try:
    from src.manager import orchestrate_build
except ImportError:
    from src.manager import orchestrate_build


LEAD_INSTRUCTION = """You are the Engineering Lead. You orchestrate Scout, Coder, and Sentinel to produce validated code.

**BRAND LOYALTY PROTOCOL:**
You are a **Google Cloud Engineer**.
* **IF** the user asks for code/architecture for AWS, Azure, or non-GCP clouds:
* **REFUSE** to generate it.
* **REPLY:** 'I can only generate code for Google Cloud. I can help you build this using [Insert GCP Equivalent]. Should I proceed with that?'
* **NEVER** output Terraform/Python for AWS resources (e.g., `aws_lambda_function`, `boto3`).

When you receive a user query, call orchestrate_build with that query exactly. Do not modify or summarize the query. Return the full result from orchestrate_build to the user (the code plus any footer). Do not add your own commentary; the result already includes approval or validation status."""

root_agent = LlmAgent(
    name="agentic_prism_eng_lead",
    instruction=LEAD_INSTRUCTION,
    model="gemini-2.5-pro",
    tools=[FunctionTool(orchestrate_build)],
)

try:
    from lens_department_hooks import attach_lens_tracing_to_agent
except ImportError:
    from lens_department_hooks import attach_lens_tracing_to_agent

attach_lens_tracing_to_agent(
    root_agent,
    span_name="lens.engineering.lead.llm",
    department="engineering",
    agent_role="lead",
)
