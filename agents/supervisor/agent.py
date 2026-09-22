
from google.adk.agents import LlmAgent
from google.adk.models.llm_request import LlmRequest
from google.adk.models.llm_response import LlmResponse
from google.genai import types
import json
from src.router import reason, ROUTING_PROMPT

def supervisor_before_model_callback(callback_context, llm_request: LlmRequest) -> LlmResponse | None:
    # 1. Extract the user query
    user_query = ""
    for content in reversed(llm_request.contents):
        if content.role == "user":
            for part in content.parts:
                if part.text:
                    user_query = part.text
                    break
            if user_query:
                break
                
    if not user_query:
        return None
        
    # 2. Run the routing logic
    res = reason(user_query, security_level="off", session_id=callback_context.session.id)
    
    # 3. Return serialized response
    content = types.Content(
        role="model",
        parts=[types.Part.from_text(text=json.dumps(res))]
    )
    return LlmResponse(content=content)

class SupervisorAgent(LlmAgent):
    def query(self, message: str, session_id: str = None, **kwargs) -> str:
        import json
        from src.router import reason
        # Delegate to the deterministic router instead of the ADK run method, since this agent doesn't need LLM calls
        res = reason(message, security_level="off", session_id=session_id)
        return json.dumps(res)

    def stream_query(self, message: str, session_id: str = None, **kwargs):
        yield self.query(message=message, session_id=session_id, **kwargs)

root_agent = SupervisorAgent(
    name="agentic_prism_supervisor",
    model="gemini-2.5-flash",
    instruction=ROUTING_PROMPT,
    before_model_callback=supervisor_before_model_callback,
)
