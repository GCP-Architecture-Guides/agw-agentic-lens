
"""
Quality and Security Reviewer agent — safe config loader.
Loads root_agent.yaml and passes only LlmAgentConfig-allowed fields to avoid Pydantic ValidationError.
"""
import os


def _vertex_agent_engine_env_bootstrap() -> None:
    os.environ["GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES"] = "false"
    for _k in ("GOOGLE_API_KEY", "GEMINI_API_KEY", "GOOGLE_AI_API_KEY"):
        os.environ.pop(_k, None)
    os.environ["GOOGLE_GENAI_USE_VERTEXAI"] = "true"
    _cur_proj = (os.environ.get("GOOGLE_CLOUD_PROJECT") or "").strip()
    _gcp_id = (os.environ.get("GCP_PROJECT_ID") or "").strip()
    if _gcp_id and (_cur_proj.isdigit() or not _cur_proj):
        os.environ["GOOGLE_CLOUD_PROJECT"] = _gcp_id
    _gcp_loc = (
        os.environ.get("GCP_LOCATION") or os.environ.get("REGION") or "us-west1"
    ).strip()
    _cur_loc = (os.environ.get("GOOGLE_CLOUD_LOCATION") or "").strip()
    if _gcp_loc and (
        not _cur_loc or (_cur_loc == "global" and _gcp_loc != "global")
    ):
        os.environ["GOOGLE_CLOUD_LOCATION"] = _gcp_loc


_vertex_agent_engine_env_bootstrap()


def _early_vertex_init() -> None:
    project = (os.environ.get("GCP_PROJECT_ID") or os.environ.get("GOOGLE_CLOUD_PROJECT") or "").strip()
    location = (
        os.environ.get("GCP_LOCATION")
        or os.environ.get("GOOGLE_CLOUD_LOCATION")
        or os.environ.get("REGION")
        or "us-west1"
    ).strip()
    if not project:
        return
    from vertex_init import init_vertexai
    init_vertexai(project, location)


_early_vertex_init()

import yaml
from google.adk.agents import LlmAgent, config_agent_utils
from google.adk.agents.llm_agent_config import LlmAgentConfig

from lens_department_hooks import attach_lens_tracing_to_agent
from telemetry import init_otel

DEFAULT_MODEL = "gemini-2.5-flash"
_ALLOWED_KEYS = frozenset(LlmAgentConfig.model_fields)


def _sanitize_agent_name(sanitized: dict, default: str) -> None:
    """Convert kebab-case to valid Python identifier (hyphens -> underscores)."""
    name = sanitized.get("name")
    sanitized["name"] = (name if isinstance(name, str) else default).replace("-", "_")


def _safe_load_root_agent(config_path: str) -> LlmAgent:
    return config_agent_utils.from_config(os.path.abspath(config_path))


init_otel("agentic_lens_eng_quality_and_security_reviewer")
root_agent = _safe_load_root_agent(os.path.join(os.path.dirname(__file__), "root_agent.yaml"))
attach_lens_tracing_to_agent(
    root_agent,
    span_name="lens.engineering.reviewer.llm",
    department="engineering",
    agent_role="quality_and_security_reviewer",
)
