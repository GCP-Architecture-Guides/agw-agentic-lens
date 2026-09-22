# Patch Dockerfile: layers updated backend files onto the existing PRD Glass UI image.
FROM us-central1-docker.pkg.dev/YOUR_PROJECT_ID/prism-glass-ui/ai-prism-agent-glass-ui@sha256:a49df4e63e0c5d1f58b79d59554b53ae72cfdb4af80a020c0e9df9634ae3c3f7

# Overwrite only the changed files
COPY glass_ui_api.py /app/glass_ui_api.py
COPY backend /app/backend

# Patch frontend demo scenarios (remove PII, add SGP + Prompt Injection)
COPY patch_scenarios.sh /tmp/patch_scenarios.sh
RUN sh /tmp/patch_scenarios.sh && rm /tmp/patch_scenarios.sh
