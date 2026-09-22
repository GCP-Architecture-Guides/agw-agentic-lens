
"""
X-Ray Librarian — Secure Fetcher.
Loads the root agent from src.librarian (tools + system prompt).
"""
import os
import sys

_agent_root = os.path.dirname(os.path.abspath(__file__))
if _agent_root not in sys.path:
    sys.path.insert(0, _agent_root)

from src.librarian import get_root_agent

root_agent = get_root_agent(os.path.join(_agent_root, "root_agent.yaml"))
