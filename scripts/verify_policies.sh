#!/bin/bash
# =============================================================================
# verify_policies.sh — Verify Organization Policy enforcement
# =============================================================================
# Usage: ./verify_policies.sh <ORG_ID> <PROJECT_ID> <PREFIX>
# Example: ./verify_policies.sh 123456789 my-project myorg
# =============================================================================

set -euo pipefail

ORG_ID="${1:?Usage: $0 <ORG_ID> <PROJECT_ID> <PREFIX>}"
PROJECT_ID="${2:?Usage: $0 <ORG_ID> <PROJECT_ID> <PREFIX>}"
PREFIX="${3:?Usage: $0 <ORG_ID> <PROJECT_ID> <PREFIX>}"

echo "============================================"
echo " Verifying Org Policy Constraints"
echo " Org: ${ORG_ID} | Project: ${PROJECT_ID}"
echo "============================================"
echo ""

echo "--- Custom Constraints (Organization Level) ---"
gcloud org-policies list-custom-constraints \
  --organization="${ORG_ID}" \
  --format='table(name,actionType,resourceTypes)' \
  --filter="name:${PREFIX}"

echo ""
echo "--- Enforcement Policies (Project Level) ---"
gcloud org-policies list \
  --project="${PROJECT_ID}" \
  --format='table(constraint,spec.rules[0].enforce)' \
  --filter="constraint:${PREFIX}"

echo ""
echo "--- Detailed Constraint Definitions ---"
for CONSTRAINT in \
  "custom.${PREFIX}EnforceAgentIdentityForReasoningEngine" \
  "custom.${PREFIX}EnforceReasoningEngineOtelConfig" \
  "custom.${PREFIX}EnforceReasoningEngineAgentGatewayConfig"; do
  echo ""
  echo ">> ${CONSTRAINT}"
  gcloud org-policies describe-custom-constraint "${CONSTRAINT}" \
    --organization="${ORG_ID}" 2>/dev/null || echo "   (not found)"
done

echo ""
echo "============================================"
echo " Verification complete."
echo "============================================"
