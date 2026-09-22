
"""
Events agent — Conference Concierge.
Uses the RAG tool (retrieve_event_info) to ground answers in the corpus.
"""
import os
import yaml
from google.adk.agents import LlmAgent
from google.adk.tools import FunctionTool

from src.tools import retrieve_event_info

DEFAULT_MODEL = "gemini-2.5-flash"
_AGENT_YAML = os.path.join(os.path.dirname(__file__), "agent.yaml")


def _load_agent_config() -> dict:
    """Load name, model, description, instruction from agent.yaml."""
    with open(_AGENT_YAML, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def _build_root_agent() -> LlmAgent:
    """Build the Concierge LlmAgent with RAG tool and instruction from agent.yaml."""
    data = _load_agent_config()
    return LlmAgent(
        name=data.get("name", "events"),
        description=data.get("description", "Conference Concierge"),
        model=data.get("model", DEFAULT_MODEL),
        instruction=data.get("instruction", ""),
        tools=[FunctionTool(retrieve_event_info)],
    )


class EventsAgent:
    def __init__(self):
        self._agent = _build_root_agent()

    def query(self, input: str, **kwargs):
        """Query the events agent."""
        return self._agent.query(input, **kwargs)

root_agent = EventsAgent()
