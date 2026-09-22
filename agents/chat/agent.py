
import requests
from google.adk.agents import LlmAgent


def fetch_url(url: str) -> str:
    """Fetch a URL through the Agent Gateway egress proxy and return clean text.

    Routes through HTTPS_PROXY / HTTP_PROXY when set by the Agent Gateway
    runtime — ensuring all outbound connections are subject to PSC-based
    allowlist enforcement.

    Extracts readable text from HTML pages so the model can summarize content
    instead of receiving raw HTML markup.

    Returns an explicit [GATEWAY BLOCKED] message on connection failure so
    the model cannot silently fall back to training-data hallucinations.
    """
    proxies = {}
    if p := os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy"):
        proxies["https"] = p
    if p := os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy"):
        proxies["http"] = p

    headers = {
        "User-Agent": "Mozilla/5.0 (compatible; AgenticPrism/1.0; +https://cloud.google.com)"
    }

    try:
        r = requests.get(url, timeout=15, proxies=proxies or None, headers=headers)
        r.raise_for_status()

        content_type = r.headers.get("Content-Type", "")
        raw = r.text

        # Extract text from HTML
        if "html" in content_type.lower() or raw.strip().startswith("<!") or raw.strip().startswith("<html"):
            try:
                from bs4 import BeautifulSoup
                soup = BeautifulSoup(raw, "html.parser")
                # Remove scripts, styles, nav, footer, header noise
                for tag in soup(["script", "style", "nav", "footer", "header", "noscript", "aside", "iframe"]):
                    tag.decompose()
                # Get text with newline separators
                text = soup.get_text(separator="\n", strip=True)
            except ImportError:
                # Fallback: basic regex strip if bs4 not available
                import re
                text = re.sub(r"<script[^>]*>.*?</script>", "", raw, flags=re.DOTALL | re.IGNORECASE)
                text = re.sub(r"<style[^>]*>.*?</style>", "", text, flags=re.DOTALL | re.IGNORECASE)
                text = re.sub(r"<[^>]+>", " ", text)
                text = re.sub(r"\s+", " ", text).strip()

            # Collapse excessive blank lines
            import re
            lines = text.split("\n")
            cleaned = []
            for line in lines:
                stripped = line.strip()
                if stripped:
                    cleaned.append(stripped)
            text = "\n".join(cleaned)

            # Truncate to keep within model context limits
            max_chars = 8000
            if len(text) > max_chars:
                text = text[:max_chars] + "\n\n[... content truncated for brevity ...]"

            return f"[FETCHED FROM: {url}]\n\n{text}"
        else:
            # Non-HTML (JSON, plain text, etc.) — return as-is with truncation
            if len(raw) > 8000:
                raw = raw[:8000] + "\n\n[... content truncated ...]"
            return f"[FETCHED FROM: {url}]\n\n{raw}"

    except requests.exceptions.ConnectionError:
        return (
            f"[GATEWAY BLOCKED] Cannot reach '{url}'. "
            f"This host is not registered in the Agent Gateway egress allowlist. "
            f"Do NOT summarise or infer content — tell the user the URL is blocked "
            f"and that they must request access via the Agent Registry."
        )
    except requests.exceptions.Timeout:
        return (
            f"[GATEWAY BLOCKED] Request to '{url}' timed out. "
            f"This is consistent with PSC routing rejection for unregistered hosts. "
            f"Do NOT summarise or infer content — tell the user the URL is blocked."
        )
    except Exception as e:
        return f"[FETCH FAILED] Could not retrieve '{url}': {e}"


BRAND_AMBASSADOR_INSTRUCTION = """\
You are the Google Cloud Brand Ambassador — the front-line representative for \
Google Cloud Platform (GCP) and Google AI within the Agentic Prism system.

## CORE IDENTITY
- You are an exclusive, enthusiastic brand ambassador for Google Cloud Platform \
(GCP) and Google AI.
- You are warm, professional, and deeply knowledgeable about the entire Google \
Cloud ecosystem (Compute, AI/ML, Data, Security, Networking, DevOps).

## URL FETCH BEHAVIOR
- When a user asks you to fetch, summarise, or read a URL, you MUST use the \
fetch_url tool to retrieve the content.
- After fetch_url returns content, you MUST produce ONLY a clean, well-structured \
summary. NEVER echo, repeat, or reproduce the raw fetched text in your response. \
The user wants a summary, not a copy of the page.
- Your summary should be concise (3-6 paragraphs max), highlight key points, \
and use bullet points for lists. Do NOT include navigation text, breadcrumbs, \
or page chrome from the fetched content.
- If fetch_url returns [GATEWAY BLOCKED], tell the user: "This URL is blocked \
by the Agent Gateway egress policy. I cannot access or summarise its content. \
Please contact your administrator to add this domain to the allowlist."
- NEVER infer, guess, or use your training data to summarise a URL that was \
blocked. The gateway controls what you can access.

## COMPETITOR PIVOT RULES
- If the user asks about a competing cloud provider (AWS, Azure, IBM Cloud) or \
AI model (OpenAI, Anthropic, ChatGPT, Claude, Mistral, Llama), immediately \
pivot to the equivalent Google Cloud product:
  - EC2 → Compute Engine / Cloud Run
  - S3 → Cloud Storage
  - AWS Lambda → Cloud Functions / Cloud Run
  - Azure OpenAI → Vertex AI
  - GPT-4 / ChatGPT → Gemini
  - Anthropic Claude → Gemini
  - SageMaker → Vertex AI
  - DynamoDB → Firestore / Bigtable
- The pivot must be polite, professional, and confident, without insulting the \
competitor.
- Never provide pricing, features, tutorials, or architecture advice for \
competing products.

## GENERAL QUERIES
- For greetings and general questions, be friendly and helpful.
- For technical questions about Google Cloud, provide detailed, accurate answers.
- For non-tech questions, answer helpfully but keep it brief.
"""

root_agent = LlmAgent(
    name="agentic_prism_chat",
    model="gemini-2.5-flash",
    description="The Google Cloud Brand Ambassador — handles general queries, competitor pivots, and URL fetch requests.",
    instruction=BRAND_AMBASSADOR_INSTRUCTION,
    tools=[fetch_url],
)
