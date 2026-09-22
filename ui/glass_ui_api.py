import logging
import os
import time
import uuid
from collections import deque
from typing import Any, Deque, Dict, List, Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from starlette.middleware.gzip import GZipMiddleware
from pydantic import BaseModel

from backend.guard import SecurityGuard
from backend.model_armor import scan_prompt
from backend.debug_session_ndjson import prism_debug_log
from backend.agent_engine_client import (
    VERTEX_SESSION_RESPONSE_KEY,
    get_lens_api_ingress_span_links,
    is_agent_engine_configured,
    get_supervisor_routing,
    call_agent_engine,
    get_engine_id_map,
)
from backend.lens_request_context import (
    get_lens_request_id,
    reset_lens_api_root_span_context,
    reset_lens_request_id,
    set_lens_api_root_span_context,
    set_lens_request_id,
)
from backend.telemetry import (
    init_otel,
    get_tracer,
    inject_w3c_headers,
    with_lens_request_id_marker,
    with_lens_trace_marker,
)
try:
    from opentelemetry.trace import Status, StatusCode
except Exception:
    class StatusCode:
        ERROR = "ERROR"

    class Status:
        def __init__(self, _code):
            self.code = _code
from backend import feedback as feedback_backend
from backend.structured_log import log_event

logger = logging.getLogger(__name__)
init_otel("agentic_lens_glass_ui_api")
tracer = get_tracer("agentic_lens")

app = FastAPI(
    title="Agentic Prism Glass UI API",
    version="0.2.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.add_middleware(GZipMiddleware, minimum_size=512)


_guard = SecurityGuard()
_DISABLE_SECURITY_GUARD = os.getenv("DISABLE_SECURITY_GUARD", "").strip().lower() in ("1", "true", "yes")


TELEMETRY_ICON_MAP: Dict[str, str] = {
    "info": "ℹ️",
    "security": "🔒",
    "supervisor": "🟡",
    "engineering": "🟢",
    "events": "🔵",
    "xray": "🟣",
    "chat": "🟠",
}

_MAX_LOGS_PER_SESSION = 400
_MAX_HISTORY_PER_SESSION = 20


class TelemetryEntry(BaseModel):
    timestamp: str
    icon: str
    type: str
    message: str
    payload: Optional[Dict[str, Any]] = None
    turn: int


class HistoryItem(BaseModel):
    prompt: str
    department: str
    turn: int
    timestamp: str


class SourceItem(BaseModel):
    title: str
    link: Optional[str] = None
    snippet: Optional[str] = None


class LogsResponse(BaseModel):
    session_id: str
    entries: List[TelemetryEntry]


class HistoryResponse(BaseModel):
    session_id: str
    items: List[HistoryItem]


_sessions: Dict[str, Dict[str, Any]] = {}

# Optional Firestore persistence for session logs (survives restarts / multi-instance). Set GLASS_UI_LOGS_FIRESTORE_DATABASE to enable.
_LOGS_FIRESTORE_DATABASE = os.environ.get("GLASS_UI_LOGS_FIRESTORE_DATABASE", "").strip()
_LOGS_FIRESTORE_COLLECTION = "glass_ui_session_logs"

# Engineering execution log delimiters (must match eng_lead manager.py)
_PRISM_EXEC_LOG_START = "<!-- PRISM_EXECUTION_LOG -->"
_PRISM_EXEC_LOG_END = "<!-- /PRISM_EXECUTION_LOG -->"
_PRISM_SESSION_MARKER_PREFIX = "<!-- PRISM_SESSION_ID:"
_PRISM_SESSION_MARKER_SUFFIX = "-->"


def _get_firestore_client():
    """Return Firestore client for logs persistence, or None if not configured."""
    if not _LOGS_FIRESTORE_DATABASE:
        return None
    try:
        from google.cloud import firestore
        project = (os.getenv("GCP_PROJECT_ID") or os.getenv("GOOGLE_CLOUD_PROJECT") or "").strip()
        if not project:
            return None
        return firestore.Client(project=project, database=_LOGS_FIRESTORE_DATABASE)
    except Exception:
        return None


def _persist_session_logs(session_id: str, entries: List[TelemetryEntry]) -> None:
    """Write session log entries to Firestore. No-op if Firestore not configured."""
    client = _get_firestore_client()
    if not client:
        return
    try:
        doc_ref = client.collection(_LOGS_FIRESTORE_COLLECTION).document(session_id)
        doc_ref.set({
            "entries": [e.model_dump() for e in entries],
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })
    except Exception:
        pass  # Don't fail the request if persistence fails


def _load_session_logs(session_id: str) -> Optional[List[TelemetryEntry]]:
    """Load session log entries from Firestore. Returns None if not found or not configured."""
    client = _get_firestore_client()
    if not client:
        return None
    try:
        doc_ref = client.collection(_LOGS_FIRESTORE_COLLECTION).document(session_id)
        doc = doc_ref.get()
        if not doc or not doc.exists:
            return None
        data = doc.to_dict()
        entries_data = data.get("entries") or []
        return [TelemetryEntry.model_validate(e) for e in entries_data if isinstance(e, dict)]
    except Exception:
        return None


def _parse_prism_execution_log(response: str) -> tuple[str, List[str]]:
    """
    Extract PRISM_EXECUTION_LOG block from agent responses (Engineering, X-Ray, etc.).
    Returns (response_without_log_markers, list of log lines).
    """
    if not response or _PRISM_EXEC_LOG_START not in response or _PRISM_EXEC_LOG_END not in response:
        return (response or "", [])
    try:
        start = response.index(_PRISM_EXEC_LOG_START) + len(_PRISM_EXEC_LOG_START)
        end = response.index(_PRISM_EXEC_LOG_END)
        log_block = response[start:end].strip()
        # Remove only the first PRISM_EXECUTION_LOG block from the display text
        display = (response[:response.index(_PRISM_EXEC_LOG_START)].strip() +
                   response[end + len(_PRISM_EXEC_LOG_END):].strip()).strip()
        lines = [line.strip() for line in log_block.split("\n") if line.strip()]
        return (display, lines)
    except (ValueError, AttributeError):
        return (response or "", [])


def _log_prism_exec_failures(
    lines: List[str],
    *,
    session_id: Optional[str],
    department: str,
) -> None:
    """Emit structured logs for Pipeline | … | FAILED | lines (observability, no secrets)."""
    for line in lines:
        if "Pipeline |" in line and "| FAILED |" in line:
            log_event(
                "pipeline_step_failed",
                session_id=session_id,
                department=department,
                detail=line[:400],
            )
            # #region agent log
            if "AUTH_401" in line or "401" in line:
                prism_debug_log(
                    "H-F",
                    "glass_ui_api.py:_log_prism_exec_failures",
                    "pipeline_auth_or_401_line",
                    {"department": department, "detail": line[:380]},
                )
            # #endregion


def _events_answer_is_rag_no_hit(answer: str) -> bool:
    t = (answer or "").lower()
    return "no relevant information" in t


def _engineering_scout_dead_end_hint(answer: str) -> Optional[str]:
    """Append short guidance when Engineering returns a known Scout/plan failure stub."""
    a = (answer or "").strip()
    if not a:
        return None
    low = a.lower()
    if low.startswith("[scout returned no plan") or low.startswith("[scout returned no architecture"):
        return (
            "\n\n---\nIf this persists: retry shortly, shorten the request, or verify Vertex/Grounding "
            "and Scout (eng_scout) configuration in your project."
        )
    return None


def _with_prism_session_marker(message: str, session_id: Optional[str]) -> str:
    """
    Attach a hidden session marker so department managers can propagate
    the same ADK session_id into internal sub-agent hops.
    """
    if not session_id:
        return message
    if message.startswith(_PRISM_SESSION_MARKER_PREFIX):
        return message
    return f"{_PRISM_SESSION_MARKER_PREFIX}{session_id}{_PRISM_SESSION_MARKER_SUFFIX}\n{message}"


def _with_ingress_w3c_marker(message: str) -> str:
    """Attach W3C trace context from the active ``lens.api.query`` span for Vertex parenting (no-op if no span)."""
    carrier = inject_w3c_headers()
    tp = carrier.get("traceparent")
    ts = carrier.get("tracestate")
    return with_lens_trace_marker(message, tp, ts)


def _supervisor_user_message(message: str) -> str:
    """W3C trace + hidden ``lens.request_id`` for Supervisor (markers stripped before LLM in router)."""
    out = _with_ingress_w3c_marker(message)
    return with_lens_request_id_marker(out, get_lens_request_id())


def _department_user_message(message: str, session_id: Optional[str]) -> str:
    """PRISM session + W3C trace + ``lens.request_id`` (strip order in agents: RID, TP, TS, PRISM)."""
    out = _with_prism_session_marker(message, session_id)
    out = _with_ingress_w3c_marker(out)
    return with_lens_request_id_marker(out, get_lens_request_id())


def _engineering_display_response(raw: str) -> str:
    """
    When the Quality and Security Reviewer approved, show only the final approved code (last fenced block + footer),
    not any earlier incorrect code. When validation failed, show the code and error as-is.
    """
    if not raw or not raw.strip():
        return raw
    text = raw.strip()
    if "✅ Approved" not in text:
        return text
    # Multiple fenced blocks: keep only the last one and the footer
    if text.count("```") < 4:
        return text
    last_close = text.rfind("```")
    if last_close == -1:
        return text
    last_open = text.rfind("```", 0, last_close)
    if last_open == -1:
        return text
    return text[last_open:].strip()


def _ensure_session(session_id: Optional[str]) -> str:
    sid = session_id or str(uuid.uuid4())
    if sid not in _sessions:
        _sessions[sid] = {
            "logs": deque(maxlen=_MAX_LOGS_PER_SESSION),
            "history": deque(maxlen=_MAX_HISTORY_PER_SESSION),
            "turn": 0,
            "ae_vertex_sessions": {},
        }
    else:
        _sessions[sid].setdefault("ae_vertex_sessions", {})
    return sid


def _vertex_engine_session_cache(sess: Dict[str, Any]) -> Dict[str, str]:
    """Per–UI-session cache: Agent Engine resource name -> Vertex session id."""
    return sess.setdefault("ae_vertex_sessions", {})


def _migrate_session_state(old_session_id: str, new_session_id: str) -> None:
    """
    Move local API state from old session key to new session key.
    Used when Agent Engine canonical session differs from incoming session.
    """
    if not old_session_id or not new_session_id or old_session_id == new_session_id:
        return

    old_sess = _sessions.get(old_session_id)
    if not old_sess:
        _ensure_session(new_session_id)
        return

    new_sess = _sessions.get(new_session_id)
    if not new_sess:
        _sessions[new_session_id] = old_sess
        _sessions.pop(old_session_id, None)
        return

    # Merge conservatively to avoid losing logs/history if both keys exist.
    old_logs = list(old_sess.get("logs") or [])
    new_logs = list(new_sess.get("logs") or [])
    merged_logs: Deque[TelemetryEntry] = deque(maxlen=_MAX_LOGS_PER_SESSION)
    for entry in old_logs + new_logs:
        merged_logs.append(entry)

    old_hist = list(old_sess.get("history") or [])
    new_hist = list(new_sess.get("history") or [])
    merged_hist: Deque[HistoryItem] = deque(maxlen=_MAX_HISTORY_PER_SESSION)
    for entry in old_hist + new_hist:
        merged_hist.append(entry)

    new_sess["logs"] = merged_logs
    new_sess["history"] = merged_hist
    new_sess["turn"] = max(int(old_sess.get("turn", 0)), int(new_sess.get("turn", 0)))
    _sessions.pop(old_session_id, None)


def _append_log(
    session_id: str,
    *,
    message: str,
    log_type: str = "info",
    payload: Optional[Dict[str, Any]] = None,
    turn: Optional[int] = None,
) -> TelemetryEntry:
    sess = _sessions.setdefault(
        session_id,
        {"logs": deque(maxlen=_MAX_LOGS_PER_SESSION), "history": deque(maxlen=_MAX_HISTORY_PER_SESSION), "turn": 0},
    )
    ts = time.strftime("%H:%M:%S")
    icon = TELEMETRY_ICON_MAP.get(log_type, TELEMETRY_ICON_MAP["info"])
    tval = turn if turn is not None else max(sess.get("turn", 0), 1)
    entry = TelemetryEntry(
        timestamp=ts,
        icon=icon,
        type=log_type,
        message=message,
        payload=payload,
        turn=tval,
    )
    sess["logs"].append(entry)
    return entry


def _add_history_item(session_id: str, prompt: str, department: str, turn: int) -> None:
    sess = _sessions.setdefault(
        session_id,
        {"logs": deque(maxlen=_MAX_LOGS_PER_SESSION), "history": deque(maxlen=_MAX_HISTORY_PER_SESSION), "turn": 0},
    )
    ts = time.strftime("%H:%M:%S")
    sess["history"].appendleft(
        HistoryItem(prompt=prompt, department=department, turn=turn, timestamp=ts)
    )


def _target_agent_to_department(target_agent: Optional[str]) -> str:
    if not target_agent:
        return "Chat"
    t = target_agent.lower()
    if "eng" in t:
        return "Engineering"
    if "event" in t:
        return "Events"
    if "xray" in t:
        return "X-Ray"
    return "Chat"


def _parse_sources_block(text: str) -> List[SourceItem]:
    if "### SOURCES ###" not in text:
        return []
    try:
        _, block = text.split("### SOURCES ###", 1)
    except ValueError:
        return []
    block = block.strip()
    if not block:
        return []
    # Very lightweight parsing: lines starting with **Title** and optional Link:/Snippet:
    items: List[SourceItem] = []
    current_title: Optional[str] = None
    current_link: Optional[str] = None
    current_snippet_lines: List[str] = []
    for raw_line in block.splitlines():
        line = raw_line.strip()
        if line.startswith("**") and "**" in line[2:]:
            # flush previous
            if current_title:
                items.append(
                    SourceItem(
                        title=current_title,
                        link=current_link,
                        snippet="\n".join(current_snippet_lines).strip() or None,
                    )
                )
            title = line.strip("*").strip()
            current_title = title
            current_link = None
            current_snippet_lines = []
            continue
        if line.lower().startswith("link:"):
            current_link = line.split(":", 1)[1].strip() or None
            continue
        if line:
            current_snippet_lines.append(line)
    if current_title:
        items.append(
            SourceItem(
                title=current_title,
                link=current_link,
                snippet="\n".join(current_snippet_lines).strip() or None,
            )
        )
    return items


class MessageItem(BaseModel):
    role: str
    content: str


class QueryRequest(BaseModel):
    messages: Optional[List[MessageItem]] = None
    message: Optional[str] = None
    session_id: Optional[str] = None
    armor_enabled: Optional[bool] = None
    armor_level: Optional[str] = None  # "off" | "medium" | "high"


class QueryResponse(BaseModel):
    session_id: Optional[str] = None
    lens_request_id: Optional[str] = None  # Same as lens.request_id on spans; for Trace/log correlation
    answer: str
    department: Optional[str] = None
    target_agent: Optional[str] = None
    execution_log: List[str] = []
    sources: List[SourceItem] = []
    blocked_by_armor: bool = False
    guard_blocked: bool = False
    # Log entries for this session (so Live System Logs work across Cloud Run instances)
    session_logs: List[TelemetryEntry] = []


def _execute_query_request(req: QueryRequest) -> QueryResponse:
    t0 = time.perf_counter()
    if req.messages and len(req.messages) > 0:
        user_input = req.messages[-1].content.strip()
    else:
        user_input = (req.message or "").strip()
    
    if not user_input:
        raise HTTPException(status_code=400, detail="message is required")

    # Resolve canonical ADK session + turn
    session_id = _ensure_session(req.session_id)
    sess = _sessions[session_id]
    ae_vertex = _vertex_engine_session_cache(sess)
    sess["turn"] = sess.get("turn", 0) + 1
    current_turn: int = sess["turn"]
    log_event("query_start", session_id=session_id, turn=current_turn)

    # Security level from request (default medium, allow off/high).
    # IMPORTANT: Model Armor is ALWAYS enforced at the backend level regardless
    # of the frontend toggle. The UI toggle is ignored — every request must be
    # scanned by Model Armor before reaching any Reasoning Engine.
    security_level = (req.armor_level or "medium").lower()
    # NOTE: req.armor_enabled is intentionally ignored. All requests go through MA.

    execution_log: List[str] = []

    def add_exec_step(step: str) -> None:
        execution_log.append(step)

    _append_log(
        session_id,
        message=f"📝 New Query #{current_turn}: \"{user_input[:80]}{'...' if len(user_input) > 80 else ''}\"",
        log_type="info",
        payload=None,
        turn=current_turn,
    )

    # Model Armor
    if security_level != "off":
        armor_result = scan_prompt(user_input, security_level)
        if not armor_result.get("safe", True):
            reason = armor_result.get("reason", "Policy Violation")
            _append_log(
                session_id,
                message=f"🛡️ Model Armor: BLOCKED ({reason})",
                log_type="security",
                payload=armor_result,
                turn=current_turn,
            )
            add_exec_step("Step 1 | Security | Model Armor: blocked request")
            return QueryResponse(
                session_id=session_id,
                lens_request_id=get_lens_request_id(),
                answer=f"🚫 **Blocked by Model Armor:** {reason}",
                blocked_by_armor=True,
                execution_log=execution_log,
                session_logs=list(sess["logs"]),
            )
        template = armor_result.get("template", "security-medium")
        summary = armor_result.get("armor_summary") or "Passed"
        # Update user_input with sanitized (de-identified) prompt if present
        sanitized_prompt = armor_result.get("sanitized_prompt")
        if sanitized_prompt and sanitized_prompt != user_input:
            user_input = sanitized_prompt
            _append_log(
                session_id,
                message=f"🛡️ Model Armor: Prompt de-identified: {user_input[:80]}",
                log_type="security",
                payload=None,
                turn=current_turn,
            )
        _append_log(
            session_id,
            message=f"🛡️ Model Armor: Passed (template: {template})",
            log_type="security",
            payload=armor_result,
            turn=current_turn,
        )
        _append_log(
            session_id,
            message=f"🛡️ Filters: {summary}",
            log_type="security",
            payload=None,
            turn=current_turn,
        )
        # Accurate status: distinguish "scan passed" from "scan skipped"
        if armor_result.get("ran", True):
            add_exec_step("Step 1 | Security | Model Armor: scan passed")
        else:
            skip = armor_result.get("skip_reason", "unknown")
            add_exec_step(f"Step 1 | Security | Model Armor: SKIPPED ({skip})")
    else:
        add_exec_step("Step 1 | Security | Model Armor: disabled")

    # Security Guard removed — enforcement handled by Model Armor + Agent Gateway SGP.

    # Default values
    routed_department = "Chat"
    final_response = ""
    target_agent: Optional[str] = None

    engine_ok = is_agent_engine_configured()
    if not engine_ok:
        error_msg = "Agent Engine is offline or not configured."
        _append_log(
            session_id,
            message=f"⚠️ {error_msg}",
            log_type="supervisor",
            payload=None,
            turn=current_turn,
        )
        add_exec_step("Step 2 | Supervisor | Engine unavailable")
        return QueryResponse(
            session_id=session_id,
            lens_request_id=get_lens_request_id(),
            answer=f"⚠️ **Routing Error:** {error_msg}",
            department="Supervisor",
            target_agent="agentic_lens_supervisor",
            execution_log=execution_log,
            session_logs=list(sess["logs"]),
        )
    if engine_ok:
        _append_log(
            session_id,
            message="🕵️ Supervisor is analyzing intent...",
            log_type="supervisor",
            payload=None,
            turn=current_turn,
        )
        add_exec_step("Step 2 | Supervisor | Analyzing intent")

        # Pass canonical ADK session_id for end-to-end continuity and GCP session visibility.
        _sr_kw: Dict[str, Any] = {}
        _srl = get_lens_api_ingress_span_links()
        if _srl:
            _sr_kw["links"] = _srl
        with tracer.start_as_current_span("lens.supervisor.routing", **_sr_kw) as span:
            span.set_attribute("agent.system", "agentic_lens")
            span.set_attribute("department", "supervisor")
            span.set_attribute("agent.role", "supervisor")
            _lr2 = get_lens_request_id()
            if _lr2:
                span.set_attribute("lens.request_id", _lr2)
            routing_data = get_supervisor_routing(
                user_message=_supervisor_user_message(user_input),
                user_id="prism-ui",
                engine_session_id=ae_vertex.get("supervisor"),
            )
            v_sup_sid = routing_data.pop(VERTEX_SESSION_RESPONSE_KEY, None)
            if v_sup_sid:
                ae_vertex["supervisor"] = v_sup_sid

        if routing_data.get("agent") == "BLOCK":
            resp = routing_data.get("response", "Blocked by Supervisor") or ""
            normalized = resp.strip()
            transient_failure = (
                not normalized
                or normalized == "No response from Supervisor."
                or "Agent Engine error" in normalized
                or "Supervisor timeout while contacting Agent Engine" in normalized
                or "Supervisor Agent Engine not configured" in normalized
            )
            if transient_failure:
                error_msg = "Supervisor routing is temporarily unavailable. Please try again."
                _append_log(
                    session_id,
                    message=f"⚠️ {error_msg}",
                    log_type="supervisor",
                    payload=None,
                    turn=current_turn,
                )
                add_exec_step("Step 3 | Supervisor | Routing Error")
                return QueryResponse(
                    session_id=session_id,
                    lens_request_id=get_lens_request_id(),
                    answer=f"⚠️ **Routing Error:** {error_msg}",
                    department="Supervisor",
                    target_agent="agentic_lens_supervisor",
                    execution_log=execution_log,
                    session_logs=list(sess["logs"]),
                )
            else:
                _append_log(
                    session_id,
                    message=f"🛡️ Supervisor Block: {resp}",
                    log_type="security",
                    payload=None,
                    turn=current_turn,
                )
                add_exec_step("Step 3 | Supervisor | Blocked by policy")
                return QueryResponse(
                    session_id=session_id,
                    lens_request_id=get_lens_request_id(),
                    answer=resp,
                    department="Chat",
                    execution_log=execution_log,
                    session_logs=list(sess["logs"]),
                )

        if (routing_data.get("direct_response") or "").strip():
            direct_response = (routing_data.get("direct_response") or "").strip()
            routed_department = "Supervisor"
            target_agent = "agentic_lens_supervisor"
            final_response = direct_response
            _append_log(
                session_id,
                message="Supervisor returned direct response (single-hop).",
                log_type="supervisor",
                payload=None,
                turn=current_turn,
            )
            add_exec_step("Step 3 | Supervisor | Direct response returned")
        else:
            direct_response = ""
            target_agent = routing_data.get("target_agent", "chat")
            forwarded_query = routing_data.get("forwarded_query", user_input)
            routed_department = _target_agent_to_department(target_agent)
            _append_log(
                session_id,
                message=f"Supervisor: Routed query to {routed_department} Department",
                log_type="supervisor",
                payload=None,
                turn=current_turn,
            )
            add_exec_step(f"Step 3 | Supervisor | Routing to {routed_department}")

            engine_map = get_engine_id_map()
            target_engine_id: Optional[str] = None

            if target_agent in engine_map:
                target_engine_id = engine_map[target_agent]
            elif f"agentic_lens_{target_agent}" in engine_map:
                target_engine_id = engine_map[f"agentic_lens_{target_agent}"]

            if not target_engine_id:
                if "eng" in target_agent:
                    target_engine_id = engine_map.get("agentic_lens_eng_lead")
                elif "xray" in target_agent:
                    target_engine_id = engine_map.get("agentic_lens_xray_manager")
                elif "event" in target_agent:
                    target_engine_id = engine_map.get("agentic_lens_events")
                elif "chat" in target_agent:
                    target_engine_id = engine_map.get("agentic_lens_chat")

            if not target_engine_id:
                _append_log(
                    session_id,
                    message="⚠️ No Agent Engine is configured for the routed target agent.",
                    log_type="info",
                    payload=None,
                    turn=current_turn,
                )
                final_response = (
                    "⚠️ No Agent Engine is configured for the routed target agent. "
                    "Ask your admin to deploy the required department engines."
                )
            else:
                _append_log(
                    session_id,
                    message=f"📞 Invoking {routed_department} Engine...",
                    log_type=target_agent or "info",
                    payload=None,
                    turn=current_turn,
                )
                add_exec_step(f"Step 4 | {routed_department} | Engine invoked")
                _dept_kw: Dict[str, Any] = {}
                _dept_lk = get_lens_api_ingress_span_links()
                if _dept_lk:
                    _dept_kw["links"] = _dept_lk
                with tracer.start_as_current_span("lens.department.invoke", **_dept_kw) as span:
                    span.set_attribute("agent.system", "agentic_lens")
                    span.set_attribute("department", routed_department.lower())
                    span.set_attribute("agent.role", target_agent or "unknown")
                    span.set_attribute("handoff.target_agent", target_agent or "unknown")
                    _lr3 = get_lens_request_id()
                    if _lr3:
                        span.set_attribute("lens.request_id", _lr3)
                    span.set_attribute("session.id", (session_id or "")[:80])
                    if target_engine_id:
                        span.set_attribute(
                            "vertex.engine_id",
                            target_engine_id.rsplit("/", 1)[-1][:120],
                        )
                    # #region agent log
                    prism_debug_log(
                        "H-D",
                        "glass_ui_api.py:_execute_query_request",
                        "department_invoke",
                        {
                            "routed_department": routed_department,
                            "target_agent": target_agent or "",
                            "engine_suffix": (target_engine_id or "").rsplit("/", 1)[-1][:80],
                            "chat_map_suffix": (engine_map.get("agentic_lens_chat") or "").rsplit("/", 1)[-1][:80],
                            "eng_map_suffix": (engine_map.get("agentic_lens_eng_lead") or "").rsplit("/", 1)[-1][:80],
                        },
                    )
                    # #endregion
                    final_response, v_engine_sid = call_agent_engine(
                        engine_id=target_engine_id,
                        user_message=_department_user_message(forwarded_query, session_id),
                        user_id="prism-ui",
                        engine_session_id=ae_vertex.get(target_engine_id),
                    )
                    if v_engine_sid:
                        ae_vertex[target_engine_id] = v_engine_sid
                # Avoid false positives (e.g. "0 Errors found" from QA) — only real failure shapes.
                _fr = (final_response or "").strip()
                _raw = final_response or ""
                _engine_hard_failure = (
                    _fr.startswith("🚨")
                    or _fr.startswith("Error:")
                    or "Pipeline | FAILED" in _raw
                    or "| FAILED |" in _raw
                )
                if _engine_hard_failure:
                    _append_log(
                        session_id,
                        message=f"⚠️ {routed_department} Error: {final_response[:100]}...",
                        log_type="info",
                        payload=None,
                        turn=current_turn,
                    )
                    add_exec_step(f"Step 5 | {routed_department} | Error from engine")
                else:
                    _append_log(
                        session_id,
                        message=f"✅ {routed_department} responded successfully.",
                        log_type=target_agent or "info",
                        payload=None,
                        turn=current_turn,
                    )
                    add_exec_step(f"Step 5 | {routed_department} | Response received")

    # Strip PRISM_EXECUTION_LOG from display text and surface pipeline diagnostics in execution_log.
    if routed_department == "Engineering" and (final_response or "").strip():
        display_response, exec_log_lines = _parse_prism_execution_log(final_response)
        if exec_log_lines:
            execution_log.extend(exec_log_lines)
            _log_prism_exec_failures(exec_log_lines, session_id=session_id, department=routed_department)
        final_response = _engineering_display_response(display_response)
    elif routed_department == "X-Ray" and (final_response or "").strip():
        display_response, exec_log_lines = _parse_prism_execution_log(final_response)
        if exec_log_lines:
            execution_log.extend(exec_log_lines)
            _log_prism_exec_failures(exec_log_lines, session_id=session_id, department=routed_department)
        final_response = display_response
        # PRISM block only (no narrative): distinguish engine failures from Glass stream unpack issues.
        if not (final_response or "").strip() and exec_log_lines:
            any_fail = any("| FAILED |" in ln for ln in exec_log_lines)
            answer_ok = any(
                "auditor | OK" in ln
                or "specialist | OK" in ln
                or "gemini_fallback | OK" in ln
                or "specialist_fallback | OK" in ln
                for ln in exec_log_lines
            )
            routing_ok_only = any("| OK |" in ln for ln in exec_log_lines) and not answer_ok
            if any_fail and not answer_ok:
                final_response = (
                    "X-Ray could not produce answer text: peer engines failed or returned empty streams "
                    "(see **Execution steps**). Redeploy **xray_manager** (includes in-process Gemini fallback) "
                    "and confirm **xray_auditor** / **xray_specialist** engines are healthy, then retry."
                )
            elif routing_ok_only:
                final_response = (
                    "X-Ray pipeline steps progressed, but no answer text reached the UI. "
                    "Redeploy **xray_manager** with the latest stream collector or retry once."
                )
            else:
                final_response = (
                    "X-Ray returned no answer text; see **Execution steps** for pipeline details."
                )

    answer_raw = final_response or "⚠️ Empty response from Agent Engine."
    sources: List[SourceItem] = _parse_sources_block(answer_raw)
    if "### SOURCES ###" in answer_raw:
        answer_clean = answer_raw.split("### SOURCES ###", 1)[0].strip()
    else:
        answer_clean = answer_raw

    if routed_department == "Engineering":
        _eng_hint = _engineering_scout_dead_end_hint(answer_clean)
        if _eng_hint:
            answer_clean = answer_clean + _eng_hint

    if routed_department == "Events" and _events_answer_is_rag_no_hit(answer_clean):
        execution_log.append(
            "Pipeline | RAG | NO_HIT | code=NO_CORPUS_TEXT | msg=model answer indicates empty retrieval"
        )
        log_event(
            "events_rag_no_hit",
            session_id=session_id,
            department=routed_department,
        )

    _add_history_item(session_id, prompt=user_input, department=routed_department, turn=current_turn)

    duration_ms = (time.perf_counter() - t0) * 1000
    log_event("query_done", session_id=session_id, department=routed_department, duration_ms=round(duration_ms, 2))

    session_logs_list = list(sess["logs"])
    _persist_session_logs(session_id, session_logs_list)

    return QueryResponse(
        session_id=session_id,
        lens_request_id=get_lens_request_id(),
        answer=answer_clean,
        department=routed_department,
        target_agent=target_agent,
        execution_log=execution_log,
        sources=sources,
        blocked_by_armor=False,
        guard_blocked=False,
        session_logs=session_logs_list,
    )


@app.post("/api/query", response_model=QueryResponse)
async def query(req: QueryRequest) -> QueryResponse:
    rid = str(uuid.uuid4())
    tok_rid = set_lens_request_id(rid)
    try:
        with tracer.start_as_current_span("lens.api.query") as span:
            span.set_attribute("agent.system", "agentic_lens")
            span.set_attribute("department", "api")
            span.set_attribute("agent.role", "ingress")
            span.set_attribute("lens.request_id", rid)
            span.set_attribute("session.id", ((req.session_id or "")[:80]))
            span.set_attribute("http.route", "/api/query")
            tok_api = set_lens_api_root_span_context(span.get_span_context())
            try:
                return _execute_query_request(req)
            except HTTPException as e:
                if e.status_code >= 500:
                    span.record_exception(e)
                    span.set_status(Status(StatusCode.ERROR))
                raise
            except Exception as e:
                span.record_exception(e)
                span.set_status(Status(StatusCode.ERROR))
                logger.exception("Unhandled error in /api/query")
                raise HTTPException(
                    status_code=500,
                    detail=f"{type(e).__name__}: {str(e)[:800]}",
                ) from e
            finally:
                reset_lens_api_root_span_context(tok_api)
    finally:
        reset_lens_request_id(tok_rid)


@app.get("/healthz")
@app.get("/healthz/")
@app.get("/api/healthz")
async def health(deep: bool = Query(False, alias="deep")) -> dict:
    """Liveness: always 200. With ?deep=1, checks Supervisor config and returns 503 if unhealthy."""
    if not deep:
        return {"status": "ok"}
    project = (os.getenv("GCP_PROJECT_ID") or os.getenv("GOOGLE_CLOUD_PROJECT") or "").strip()
    engine_ok = is_agent_engine_configured()
    if not project or not engine_ok:
        raise HTTPException(
            status_code=503,
            detail=f"Unhealthy: project={'set' if project else 'missing'}, supervisor_configured={engine_ok}",
        )
    return {"status": "ok", "project": project, "supervisor_configured": True}


# ---------------------------------------------------------------------------
# UI Configuration: provides runtime flags for the frontend SPA
# ---------------------------------------------------------------------------
_SKIP_LANDING_FORM = os.getenv("SKIP_LANDING_FORM", "").strip().lower() in ("1", "true", "yes")


class UiConfigResponse(BaseModel):
    skip_landing_form: bool


@app.get("/api/config", response_model=UiConfigResponse)
async def ui_config() -> UiConfigResponse:
    """Return runtime UI configuration flags.

    The frontend calls this on mount to decide whether to show the
    welcome / telemetry landing form or skip straight to the main app.
    Set env var ``SKIP_LANDING_FORM=true`` to bypass the form.
    """
    return UiConfigResponse(skip_landing_form=_SKIP_LANDING_FORM)


# Base paths for frontend (used by SPA fallback and static mount at end)
_BASE_DIR = os.path.dirname(os.path.abspath(__file__))
_FRONTEND_DIR = os.path.join(_BASE_DIR, "frontend")


@app.get("/api/logs", response_model=LogsResponse)
async def get_logs(session_id: str = Query(..., alias="sessionId"), limit: int = Query(200, ge=1, le=_MAX_LOGS_PER_SESSION)) -> LogsResponse:
    sid = _ensure_session(session_id)
    # Prefer Firestore so logs work across instances and restarts
    loaded = _load_session_logs(sid)
    if loaded is not None:
        entries = loaded[-limit:]
    else:
        sess = _sessions.get(sid) or {}
        logs: Deque[TelemetryEntry] = sess.get("logs") or deque()
        entries = list(logs)[-limit:]
    return LogsResponse(session_id=sid, entries=entries)


@app.get("/api/history", response_model=HistoryResponse)
async def get_history(session_id: str = Query(..., alias="sessionId"), limit: int = Query(10, ge=1, le=_MAX_HISTORY_PER_SESSION)) -> HistoryResponse:
    sid = _ensure_session(session_id)
    sess = _sessions.get(sid) or {}
    hist: Deque[HistoryItem] = sess.get("history") or deque()
    items = list(hist)[:limit]
    return HistoryResponse(session_id=sid, items=items)


class FeedbackRequest(BaseModel):
    session_id: Optional[str] = None
    turn: Optional[int] = None
    user_query: str
    department: str
    answer: str
    rating: Optional[int] = None
    comments: Optional[str] = None
    issue_type: Optional[str] = None
    routing_correct: Optional[bool] = None
    correct_department: Optional[str] = None


class FeedbackResponse(BaseModel):
    ok: bool


@app.post("/api/feedback", response_model=FeedbackResponse)
async def submit_feedback(req: FeedbackRequest) -> FeedbackResponse:
    ok = True
    # Response quality feedback
    if (
        req.rating is not None
        or (req.comments and req.comments.strip())
        or (req.issue_type and req.issue_type.strip())
    ):
        ok_resp = feedback_backend.save_response_feedback(
            user_query=req.user_query,
            department=req.department,
            response_content=req.answer[:500],
            rating=req.rating or 0,
            feedback_text=req.comments or "",
            issue_type=req.issue_type or "",
        )
        ok = ok and ok_resp

    # Optional routing correction
    if req.routing_correct is False and req.correct_department:
        ok_route = feedback_backend.save_routing_feedback(
            user_query=req.user_query,
            routed_to=req.department,
            should_route_to=req.correct_department,
            reason=req.comments or "",
        )
        ok = ok and ok_route

    return FeedbackResponse(ok=ok)


# ---------------------------------------------------------------------------
# Welcome & Telemetry landing: stream demo usage to BigQuery (ADC, no key file)
# ---------------------------------------------------------------------------
_BQ_DATASET = "prism_telemetry"
_BQ_TABLE = "demo_usage_logs"


def _stream_telemetry_to_bigquery(
    timestamp_utc: str,
    usage_type: str,
    user_email: str,
    customer_name: Optional[str],
    opportunity_link: Optional[str],
) -> bool:
    """Stream one row to prism_telemetry.demo_usage_logs. Uses ADC. Returns True if insert succeeded."""
    project = (os.getenv("GCP_PROJECT_ID") or os.getenv("GOOGLE_CLOUD_PROJECT") or "").strip()
    if not project:
        log_event("telemetry_bq_skip", {"reason": "no_project"})
        return False
    try:
        from google.cloud import bigquery
        client = bigquery.Client(project=project)
        table_id = f"{project}.{_BQ_DATASET}.{_BQ_TABLE}"
        row = {
            "timestamp": timestamp_utc,
            "usage_type": usage_type,
            "user_email": user_email,
            "customer_name": (customer_name or "").strip() or None,
            "opportunity_link": (opportunity_link or "").strip() or None,
        }
        errors = client.insert_rows_json(table_id, [row])
        if errors:
            log_event("telemetry_bq_insert_errors", {"errors": errors})
            return False
        return True
    except Exception as e:
        log_event("telemetry_bq_exception", {"message": str(e)})
        return False


class TelemetrySubmitRequest(BaseModel):
    usage_type: str  # "Customer" | "Personal"
    user_email: str
    customer_name: Optional[str] = None
    opportunity_link: Optional[str] = None


class TelemetrySubmitResponse(BaseModel):
    ok: bool


@app.post("/api/telemetry", response_model=TelemetrySubmitResponse)
async def submit_telemetry(req: TelemetrySubmitRequest) -> TelemetrySubmitResponse:
    """Record demo usage in BigQuery. On BQ failure we still return 200 so the user can proceed."""
    from datetime import datetime, timezone
    ts = datetime.now(timezone.utc).isoformat()
    usage_type = (req.usage_type or "").strip() or "Personal"
    user_email = (req.user_email or "").strip()
    customer_name = req.customer_name if usage_type == "Customer" else None
    opportunity_link = req.opportunity_link if usage_type == "Customer" else None
    inserted = _stream_telemetry_to_bigquery(
        timestamp_utc=ts,
        usage_type=usage_type,
        user_email=user_email,
        customer_name=customer_name,
        opportunity_link=opportunity_link,
    )
    return TelemetrySubmitResponse(ok=True)

# ---------------------------------------------------------------------------
# SPA Fallback: serve built React frontend, with optional form bypass injection
# ---------------------------------------------------------------------------
_BYPASS_SCRIPT = """<script>
// Injected by backend: SKIP_LANDING_FORM=true
// Three-layer bypass for the landing / telemetry form:
//   Layer 1 – localStorage: pre-set the key React checks on mount
//   Layer 2 – MutationObserver: auto-submit the form if it renders anyway
//   Layer 3 – CSS: hide the form container while React boots
(function(){
  // --- Layer 1: localStorage ---
  var k="lens_telemetry_submitted";
  var now=Date.now();
  try {
    var existing=localStorage.getItem(k);
    var valid=false;
    if(existing){try{var o=JSON.parse(existing);valid=o&&o.submitted===true&&typeof o.submittedAt==="number"&&typeof o.lastActivityAt==="number";}catch(e){}}
    if(!valid){localStorage.setItem(k,JSON.stringify({submitted:true,submittedAt:now,lastActivityAt:now}));}
    else{localStorage.setItem(k,JSON.stringify({submitted:true,submittedAt:JSON.parse(existing).submittedAt,lastActivityAt:now}));}
  } catch(e) { console.warn("[SKIP_LANDING_FORM] localStorage error:", e); }

  // --- Layer 2: MutationObserver auto-dismiss ---
  // If the form renders despite Layer 1 (e.g. stale service-worker cache),
  // find the submit button and click it automatically.
  var dismissed=false;
  function tryDismiss(root) {
    if(dismissed) return;
    // Only target buttons inside landing/form containers — NOT scenario demo chips
    var containers = (root||document).querySelectorAll('[data-landing-form], [class*="Landing"], [class*="landing"], [class*="Onboard"], [class*="onboard"], [class*="Welcome"], [class*="welcome"], form');
    if(containers.length===0) return;
    for(var ci=0;ci<containers.length;ci++){
      var btns = containers[ci].querySelectorAll('button[type="submit"], button');
      for(var i=0;i<btns.length;i++){
        var txt=(btns[i].textContent||"").toLowerCase();
        if(txt.indexOf("start")>-1||txt.indexOf("submit")>-1||txt.indexOf("continue")>-1||txt.indexOf("get started")>-1||txt.indexOf("let")>-1){
          var inputs=containers[ci].querySelectorAll('input[required],select[required]');
          for(var j=0;j<inputs.length;j++){
            if(!inputs[j].value){
              if(inputs[j].tagName==="SELECT"){inputs[j].selectedIndex=1;}
              else{
                var nativeInputValueSetter=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;
                nativeInputValueSetter.call(inputs[j],'Auto-bypassed');
                inputs[j].dispatchEvent(new Event('input',{bubbles:true}));
                inputs[j].dispatchEvent(new Event('change',{bubbles:true}));
              }
            }
          }
          dismissed=true;
          setTimeout(function(){btns[i].click();},100);
          return;
        }
      }
    }
  }
  if(typeof MutationObserver!=="undefined"){
    var obs=new MutationObserver(function(muts){
      tryDismiss(document);
      // Stop observing after 15 seconds regardless
    });
    // Start observing once DOM is ready
    var startObs=function(){
      obs.observe(document.body||document.documentElement,{childList:true,subtree:true});
      // Also try immediately in case form already rendered
      setTimeout(function(){tryDismiss(document);},500);
      setTimeout(function(){tryDismiss(document);},2000);
      // Clean up after 15s
      setTimeout(function(){obs.disconnect();},15000);
    };
    if(document.body){startObs();}
    else{document.addEventListener("DOMContentLoaded",startObs);}
  }

  // --- Layer 3: CSS hide (removed once React takes over) ---
  var style=document.createElement("style");
  style.id="skip-landing-css";
  style.textContent="[data-landing-form],[data-testid*=landing],[class*=Landing],[class*=landing],[class*=Onboard],[class*=onboard]{opacity:0!important;pointer-events:none!important;position:absolute!important;height:0!important;overflow:hidden!important;}";
  (document.head||document.documentElement).appendChild(style);
  // Remove CSS override after 10s to avoid hiding anything permanently
  setTimeout(function(){var s=document.getElementById("skip-landing-css");if(s)s.remove();},10000);
})();
</script>"""

# Cache the patched index.html so we don't re-read + inject on every request.
_PATCHED_INDEX_HTML: Optional[str] = None


def _get_index_html() -> Optional[str]:
    """Return (possibly patched) index.html contents, cached after first read."""
    global _PATCHED_INDEX_HTML
    if _PATCHED_INDEX_HTML is not None:
        return _PATCHED_INDEX_HTML
    index_path = os.path.join(_FRONTEND_DIR, "index.html")
    if not os.path.isfile(index_path):
        import sys; sys.stderr.write(f"[FORM_BYPASS] index.html NOT FOUND at {index_path}\n"); sys.stderr.flush()
        return None
    with open(index_path, "r", encoding="utf-8") as f:
        html = f.read()
    import sys
    sys.stderr.write(f"[FORM_BYPASS] _SKIP_LANDING_FORM={_SKIP_LANDING_FORM}, html_len={len(html)}, has_script={'<script' in html}\n")
    sys.stderr.flush()
    if _SKIP_LANDING_FORM:
        # Inject bypass script right before the first <script> tag so it runs
        # before the React bundle and sets localStorage before React mounts.
        html = html.replace("<script", _BYPASS_SCRIPT + "\n    <script", 1)
        sys.stderr.write(f"[FORM_BYPASS] INJECTED bypass script. patched_len={len(html)}, contains_Layer1={'Layer 1' in html}\n")
        sys.stderr.flush()
    else:
        sys.stderr.write("[FORM_BYPASS] SKIP_LANDING_FORM is FALSE — bypass NOT applied!\n")
        sys.stderr.flush()
    _PATCHED_INDEX_HTML = html
    return _PATCHED_INDEX_HTML


@app.get("/{full_path:path}")
async def spa_fallback(full_path: str):
    """
    Serve static files from frontend dir, or index.html for SPA deep links.
    When SKIP_LANDING_FORM is enabled, index.html is served with an injected
    script that pre-sets localStorage so the welcome form is bypassed.
    """
    if not os.path.isdir(_FRONTEND_DIR):
        raise HTTPException(status_code=404, detail="Not Found")
    if full_path:
        # Resolve under frontend dir and avoid path traversal
        safe_path = os.path.normpath(os.path.join(_FRONTEND_DIR, full_path))
        if not safe_path.startswith(os.path.realpath(_FRONTEND_DIR)):
            pass  # fall through to index.html
        elif os.path.isfile(safe_path):
            return FileResponse(safe_path)
    # Serve index.html (patched if SKIP_LANDING_FORM is set)
    html = _get_index_html()
    if html is None:
        raise HTTPException(status_code=404, detail="Not Found")
    from fastapi.responses import HTMLResponse
    return HTMLResponse(
        content=html,
        headers={"Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"},
    )
