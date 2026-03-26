#!/usr/bin/env bash
# =============================================================================
# Manage Teams Team – Setup via Azure CLI
# =============================================================================
# Voraussetzungen:
#   - az CLI eingeloggt (az login)
#   - .env Datei befuellt (Vorlage: .env.example)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==== .env laden ====
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "FEHLER: .env nicht gefunden."
    echo "Bitte .env.example nach .env kopieren und ausfuellen."
    exit 1
fi
# shellcheck source=.env
source "$SCRIPT_DIR/.env"

echo "============================================"
echo " Manage Teams Team – Setup"
echo "============================================"
echo " Subscription : $SUBSCRIPTION_ID"
echo " Resource Group: $RG"
echo " Automation AA : $AA"
echo " Location      : $LOCATION"
echo ""

# ==== Subscription setzen ====
az account set --subscription "$SUBSCRIPTION_ID"
echo "✓ Subscription gesetzt"

# =============================================================================
echo ""
echo "=== 1. Managed Identity pruefen ==="
# =============================================================================
ACTUAL_MI=$(az automation account show \
    --resource-group "$RG" --name "$AA" \
    --query "identity.principalId" -o tsv 2>/dev/null)

if [ -z "$ACTUAL_MI" ]; then
    echo "  ! Keine Managed Identity – aktiviere System Assigned..."
    az automation account update \
        --resource-group "$RG" --name "$AA" \
        --assign-identity SystemAssigned --output none
    ACTUAL_MI=$(az automation account show \
        --resource-group "$RG" --name "$AA" \
        --query "identity.principalId" -o tsv)
fi

echo "✓ Managed Identity: $ACTUAL_MI"
echo ""
echo "  Graph Permissions werden NICHT hier gesetzt."
echo "  → Fuehre grant-permissions.sh als Global Admin aus (einmalig)."

# =============================================================================
echo ""
echo "=== 2. Runtime Environment ($RUNTIME_ENV, PS 7.4) ==="
# =============================================================================
RUNTIME_EXISTS=$(az automation runtime-environment list \
    --resource-group "$RG" --automation-account-name "$AA" \
    --query "[?name=='$RUNTIME_ENV'].name" -o tsv 2>/dev/null || echo "")

if [ -z "$RUNTIME_EXISTS" ]; then
    az automation runtime-environment create \
        --resource-group "$RG" \
        --automation-account-name "$AA" \
        --name "$RUNTIME_ENV" \
        --location "$LOCATION" \
        --language PowerShell \
        --version 7.4 \
        --output none
    echo "✓ Runtime Environment erstellt"
else
    echo "  Runtime Environment '$RUNTIME_ENV' existiert bereits"
fi

# Microsoft.Graph Module installieren
for PKG in "Microsoft.Graph.Authentication" "Microsoft.Graph.Groups" "Microsoft.Graph.Users"; do
    PKG_URI=$(curl -Ls -o /dev/null -w "%{url_effective}" \
        "https://www.powershellgallery.com/api/v2/package/$PKG")

    echo "  Installiere: $PKG"
    az automation runtime-environment package create \
        --resource-group "$RG" \
        --automation-account-name "$AA" \
        --runtime-environment-name "$RUNTIME_ENV" \
        --name "$PKG" \
        --content-uri "$PKG_URI" \
        --output none
    echo "✓ $PKG installiert"
done

# =============================================================================
echo ""
echo "=== 3. Runbook deployen ==="
# =============================================================================
PS1_FILE="$SCRIPT_DIR/Manage-TeamsTeam.ps1"

if ! az automation runbook show \
    --resource-group "$RG" --automation-account-name "$AA" \
    --name "$RUNBOOK_NAME" &>/dev/null 2>&1; then

    az automation runbook create \
        --resource-group "$RG" \
        --automation-account-name "$AA" \
        --name "$RUNBOOK_NAME" \
        --type PowerShell \
        --location "$LOCATION" \
        --output none
    echo "✓ Runbook angelegt"
fi

az automation runbook replace-content \
    --resource-group "$RG" \
    --automation-account-name "$AA" \
    --name "$RUNBOOK_NAME" \
    --content @"$PS1_FILE"
echo "✓ Runbook-Inhalt hochgeladen"

# Runtime Environment zuweisen (API 2024-10-23 zwingend!)
az rest \
    --method PATCH \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Automation/automationAccounts/${AA}/runbooks/${RUNBOOK_NAME}?api-version=2024-10-23" \
    --headers "Content-Type=application/json" \
    --body "{\"properties\":{\"runtimeEnvironment\":\"$RUNTIME_ENV\"}}" \
    --output none
echo "✓ Runtime Environment zugewiesen"

az automation runbook publish \
    --resource-group "$RG" \
    --automation-account-name "$AA" \
    --name "$RUNBOOK_NAME" \
    --output none
echo "✓ Runbook publiziert"

# =============================================================================
echo ""
echo "=== 4. Schedule anlegen (taeglich ${SCHEDULE_HOUR}:00 UTC) ==="
# =============================================================================
SCHEDULE_EXISTS=$(az automation schedule list \
    --resource-group "$RG" --automation-account-name "$AA" \
    --query "[?name=='$SCHEDULE_NAME'].name" -o tsv 2>/dev/null || echo "")

if [ -z "$SCHEDULE_EXISTS" ]; then
    START_TIME=$(date -u -v+1d "+%Y-%m-%dT${SCHEDULE_HOUR}:00:00+00:00" 2>/dev/null || \
                 date -u -d "tomorrow" "+%Y-%m-%dT${SCHEDULE_HOUR}:00:00+00:00")

    az automation schedule create \
        --resource-group "$RG" \
        --automation-account-name "$AA" \
        --name "$SCHEDULE_NAME" \
        --frequency Day \
        --interval 1 \
        --start-time "$START_TIME" \
        --time-zone "UTC" \
        --output none
    echo "✓ Schedule erstellt: taeglich ${SCHEDULE_HOUR}:00 UTC"
else
    echo "  Schedule '$SCHEDULE_NAME' existiert bereits"
fi

# Schedule mit Runbook verknuepfen
az rest \
    --method PUT \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Automation/automationAccounts/${AA}/jobSchedules/$(uuidgen | tr '[:upper:]' '[:lower:]')?api-version=2023-11-01" \
    --headers "Content-Type=application/json" \
    --body "{
        \"properties\": {
            \"runbook\":  { \"name\": \"$RUNBOOK_NAME\" },
            \"schedule\": { \"name\": \"$SCHEDULE_NAME\" },
            \"parameters\": {
                \"EntraGroupNames\": \"$ENTRA_GROUP_NAMES\",
                \"TeamsGroupName\":  \"$TEAMS_GROUP_NAME\",
                \"AutomationUserName\": \"$AUTOMATION_USER_NAME\",
                \"DryRun\":          \"false\"
            }
        }
    }" --output none
echo "✓ Schedule mit Runbook verknuepft (Parameter aus .env)"

# =============================================================================
echo ""
echo "============================================"
echo " Setup abgeschlossen!"
echo "============================================"
echo ""
echo " Naechste Schritte:"
echo "   1. WICHTIG: 5 Min warten (Graph Permissions brauchen Zeit)"
echo "   2. Testlauf (DryRun): ./test.sh"
echo "   3. Live-Lauf:         ./test.sh live"
echo ""
