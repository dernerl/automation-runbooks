#!/usr/bin/env bash
# =============================================================================
# Service Account Monitor – Setup via Azure CLI
# =============================================================================
# Voraussetzungen:
#   - az CLI eingeloggt (az login)
#   - .env Datei befüllt (Vorlage: .env.example)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==== .env laden ====
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "FEHLER: .env nicht gefunden."
    echo "Bitte .env.example nach .env kopieren und ausfüllen."
    exit 1
fi
# shellcheck source=.env
source "$SCRIPT_DIR/.env"

echo "============================================"
echo " Service Account Monitor – Setup"
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
echo "=== 1. Managed Identity prüfen ==="
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
echo "  → Führe grant-permissions.sh als Global Admin aus (einmalig)."

# =============================================================================
echo ""
echo "=== 2. Runtime Environment pruefen ($RUNTIME_ENV) ==="
# Runbooks nutzen die gemeinsame PowerShell-7.4-Runtime des Automation Accounts –
# es wird bewusst KEINE eigene Runtime pro Runbook angelegt. Hier nur pruefen,
# ob sie existiert und die benoetigten Module enthaelt.
REQUIRED_MODULES=("Microsoft.Graph.Authentication")
RUNTIME_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Automation/automationAccounts/${AA}/runtimeEnvironments/${RUNTIME_ENV}"

RUNTIME_VERSION=$(az rest --method GET \
    --url "${RUNTIME_URL}?api-version=2024-10-23" \
    --query "join(' ', [properties.runtime.language, properties.runtime.version])" -o tsv 2>/dev/null || echo "")

if [ -z "$RUNTIME_VERSION" ]; then
    echo "FEHLER: Runtime Environment '$RUNTIME_ENV' existiert nicht in '$AA'."
    echo "  RUNTIME_ENV in .env auf die gemeinsame PowerShell-7.4-Runtime des Accounts setzen."
    exit 1
fi
if [ "$RUNTIME_VERSION" != "PowerShell 7.4" ]; then
    echo "FEHLER: '$RUNTIME_ENV' ist '$RUNTIME_VERSION', erwartet 'PowerShell 7.4'."
    exit 1
fi

INSTALLED=$(az rest --method GET \
    --url "${RUNTIME_URL}/packages?api-version=2024-10-23" \
    --query "value[].name" -o tsv)
MISSING=0
for PKG in "${REQUIRED_MODULES[@]}"; do
    if grep -qix "$PKG" <<< "$INSTALLED"; then
        echo "  ✓ $PKG"
    else
        echo "  ! $PKG fehlt"
        MISSING=1
    fi
done
if [ "$MISSING" -eq 1 ]; then
    echo "FEHLER: Fehlende Module in der gemeinsamen Runtime '$RUNTIME_ENV' installieren"
    echo "  (Portal → Automation Account → Runtime Environments → $RUNTIME_ENV → Packages)."
    exit 1
fi
echo "✓ Runtime Environment '$RUNTIME_ENV' ($RUNTIME_VERSION) OK"

# =============================================================================
echo ""
echo "=== 4. Runbook deployen ==="
# =============================================================================
PS1_FILE="$SCRIPT_DIR/Invoke-ServiceAccountMonitor.ps1"

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
echo "=== 5. Schedule anlegen (täglich ${SCHEDULE_HOUR}:00 UTC) ==="
# =============================================================================
SCHEDULE_EXISTS=$(az automation schedule list \
    --resource-group "$RG" --automation-account-name "$AA" \
    --query "[?name=='$SCHEDULE_NAME'].name" -o tsv 2>/dev/null || echo "")

if [ -z "$SCHEDULE_EXISTS" ]; then
    # Startzeit = morgen um SCHEDULE_HOUR:00 UTC
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
    echo "✓ Schedule erstellt: täglich ${SCHEDULE_HOUR}:00 UTC"
else
    echo "  Schedule '$SCHEDULE_NAME' existiert bereits"
fi

# Schedule mit Runbook verknüpfen
az rest \
    --method PUT \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Automation/automationAccounts/${AA}/jobSchedules/$(uuidgen | tr '[:upper:]' '[:lower:]')?api-version=2023-11-01" \
    --headers "Content-Type=application/json" \
    --body "{
        \"properties\": {
            \"runbook\":  { \"name\": \"$RUNBOOK_NAME\" },
            \"schedule\": { \"name\": \"$SCHEDULE_NAME\" },
            \"parameters\": {
                \"SenderMailbox\": \"$SENDER_MAILBOX\",
                \"HelpdeskMail\":  \"$HELPDESK_MAIL\",
                \"GroupName\":     \"$GROUP_NAME\",
                \"DryRun\":        \"false\"
            }
        }
    }" --output none
echo "✓ Schedule mit Runbook verknüpft (Parameter aus .env)"

# =============================================================================
echo ""
echo "============================================"
echo " Setup abgeschlossen!"
echo "============================================"
echo ""
echo " Nächste Schritte:"
echo "   1. WICHTIG: 5 Min warten (Graph Permissions brauchen Zeit)"
echo "   2. Testlauf (DryRun):"

cat << EOF

   az automation runbook start \\
     --resource-group "$RG" \\
     --automation-account-name "$AA" \\
     --name "$RUNBOOK_NAME" \\
     --parameters DryRun=true SenderMailbox="$SENDER_MAILBOX" HelpdeskMail="$HELPDESK_MAIL" GroupName="$GROUP_NAME"

EOF

echo "   3. Job-Output prüfen (Job-ID aus obigem Output):"
echo "      → Siehe test.sh für automatisches Polling"
echo ""
echo "   4. Sponsor-Feld in Entra ID befüllen:"
echo "      Entra Portal → Users → [Service Account] → Sponsors"
echo ""
