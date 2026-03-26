#!/usr/bin/env bash
# =============================================================================
# Manage Teams Team – Graph API Permissions fuer Managed Identity
# =============================================================================
# Benoetigt: Global Admin oder Privileged Role Administrator
#
# Vergibt folgende Application Permissions an die Managed Identity:
#   - Group.ReadWrite.All       → Gruppenmitglieder lesen und aendern
#   - User.Read.All             → User-Details aufloesen
#   - TeamSettings.ReadWrite.All → Teams-Gruppen verwalten
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "FEHLER: .env nicht gefunden."
    exit 1
fi
source "$SCRIPT_DIR/.env"

az account set --subscription "$SUBSCRIPTION_ID"

# Managed Identity Object ID live aus dem AA holen (Fallback auf .env)
ACTUAL_MI=$(az automation account show \
    --resource-group "$RG" --name "$AA" \
    --query "identity.principalId" -o tsv 2>/dev/null || echo "")
MI_ID="${ACTUAL_MI:-$MI_OBJECT_ID}"

echo "============================================"
echo " Graph Permissions – Managed Identity"
echo "============================================"
echo " Automation Account : $AA"
echo " Managed Identity   : $MI_ID"
echo ""

GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
GRAPH_SP_ID=$(az ad sp show --id "$GRAPH_APP_ID" --query id -o tsv)

PERMISSIONS=(
    "Group.ReadWrite.All"
    "User.Read.All"
    "TeamSettings.ReadWrite.All"
)

for PERM in "${PERMISSIONS[@]}"; do
    ROLE_ID=$(az ad sp show --id "$GRAPH_APP_ID" \
        --query "appRoles[?value=='$PERM'].id" -o tsv)

    if [ -z "$ROLE_ID" ]; then
        echo "  ! '$PERM' – Rolle nicht gefunden, ueberspringe"
        continue
    fi

    EXISTING=$(az rest --method GET \
        --url "https://graph.microsoft.com/v1.0/servicePrincipals/$MI_ID/appRoleAssignments" \
        --query "value[?appRoleId=='$ROLE_ID'].id" -o tsv 2>/dev/null || echo "")

    if [ -n "$EXISTING" ]; then
        echo "  ✓ $PERM (bereits vorhanden)"
    else
        az rest --method POST \
            --url "https://graph.microsoft.com/v1.0/servicePrincipals/$MI_ID/appRoleAssignments" \
            --headers "Content-Type=application/json" \
            --body "{
                \"principalId\": \"$MI_ID\",
                \"resourceId\":  \"$GRAPH_SP_ID\",
                \"appRoleId\":   \"$ROLE_ID\"
            }" --output none
        echo "  ✓ $PERM – zugewiesen"
    fi
done

echo ""
echo "✓ Fertig. Bitte 2-5 Minuten warten bevor du das Runbook testest."
