
"""
X-Ray Auditor — Safe config loader.
Filters deployment metadata so LlmAgent never receives forbidden fields.
"""
import os
import yaml
from google.adk.agents import LlmAgent
from google.adk.agents.llm_agent_config import LlmAgentConfig

DEFAULT_MODEL = "gemini-2.5-pro"
_ALLOWED_KEYS = frozenset(LlmAgentConfig.model_fields)


def _sanitize_agent_name(sanitized: dict, default: str) -> None:
    """Convert kebab-case to valid Python identifier (hyphens -> underscores)."""
    name = sanitized.get("name")
    sanitized["name"] = (name if isinstance(name, str) else default).replace("-", "_")


def _safe_load_root_agent(config_path: str) -> LlmAgent:
    abs_path = os.path.abspath(config_path)
    with open(abs_path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    sanitized = {k: v for k, v in data.items() if k in _ALLOWED_KEYS}
    sanitized["model"] = sanitized.get("model") or DEFAULT_MODEL
    _sanitize_agent_name(sanitized, "xray_auditor")
    config = LlmAgentConfig.model_validate(sanitized)
    # Note: We use LlmAgent.from_config instead of a custom class if standard behavior is sufficient.
    # If custom logic is needed, we can define a SafeLlmAgent alias or subclass.
    return LlmAgent.from_config(config, abs_path)


root_agent = _safe_load_root_agent(os.path.join(os.path.dirname(__file__), "root_agent.yaml"))
