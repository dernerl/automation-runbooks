#!/usr/bin/env bash
# =============================================================================
# Invoke-HelpdeskMailboxMonitor – Setup via Azure CLI
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "FEHLER: .env nicht gefunden."
    echo "Bitte .env.example nach .env kopieren und ausfuellen."
    exit 1
fi
# shellcheck source=.env
source "$SCRIPT_DIR/.env"

echo "============================================"
echo " $RUNBOOK_NAME – Setup"
echo "============================================"
echo " Subscription : $SUBSCRIPTION_ID"
echo " Resource Group: $RG"
echo " Automation AA : $AA"
echo " Location      : $LOCATION"
echo ""

az account set --subscription "$SUBSCRIPTION_ID"
echo "✓ Subscription gesetzt"

# === 1. Managed Identity pruefen ===
echo ""
echo "=== 1. Managed Identity pruefen ==="
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

# === 2. Runtime Environment ===
echo ""
echo "=== 2. Runtime Environment ($RUNTIME_ENV, PS 7.4) ==="
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

PKG="Microsoft.Graph.Authentication"
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

# === 3. Runbook deployen ===
echo ""
echo "=== 3. Runbook deployen ==="
PS1_FILE="$SCRIPT_DIR/$RUNBOOK_NAME.ps1"

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

# === 4. Zustands-Variable ===
echo ""
echo "=== 4. Automation-Variable ($STATE_VARIABLE_NAME) ==="
VAR_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Automation/automationAccounts/${AA}/variables/${STATE_VARIABLE_NAME}?api-version=2023-11-01"
if az rest --method GET --url "$VAR_URL" --output none 2>/dev/null; then
    echo "  Variable '$STATE_VARIABLE_NAME' existiert bereits"
else
    # Wert ist JSON-serialisiert: false → Get-AutomationVariable liefert [bool]
    az rest \
        --method PUT \
        --url "$VAR_URL" \
        --headers "Content-Type=application/json" \
        --body '{"properties":{"value":"false","isEncrypted":false,"description":"true = Crawler-Alert wurde gesendet, Entwarnung steht aus"}}' \
        --output none
    echo "✓ Variable angelegt (false)"
fi

# === 5. Schedule ===
echo ""
echo "=== 5. Schedule anlegen (stuendlich, zur vollen Stunde) ==="
SCHEDULE_EXISTS=$(az automation schedule list \
    --resource-group "$RG" --automation-account-name "$AA" \
    --query "[?name=='$SCHEDULE_NAME'].name" -o tsv 2>/dev/null || echo "")

if [ -z "$SCHEDULE_EXISTS" ]; then
    # Naechste volle Stunde + 1h (Azure verlangt Startzeit >= 5 Min in der Zukunft)
    START_TIME=$(date -u -v+1H -v+1H "+%Y-%m-%dT%H:00:00+00:00" 2>/dev/null || \
                 date -u -d "+2 hour" "+%Y-%m-%dT%H:00:00+00:00")

    az automation schedule create \
        --resource-group "$RG" \
        --automation-account-name "$AA" \
        --name "$SCHEDULE_NAME" \
        --frequency Hour \
        --interval 1 \
        --start-time "$START_TIME" \
        --time-zone "UTC" \
        --output none
    echo "✓ Schedule erstellt (Start: $START_TIME)"
else
    echo "  Schedule '$SCHEDULE_NAME' existiert bereits"
fi

JOB_SCHEDULE_EXISTS=$(az rest --method GET \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Automation/automationAccounts/${AA}/jobSchedules?api-version=2023-11-01" \
    --query "value[?properties.runbook.name=='$RUNBOOK_NAME' && properties.schedule.name=='$SCHEDULE_NAME'].name" -o tsv 2>/dev/null || echo "")

if [ -z "$JOB_SCHEDULE_EXISTS" ]; then
    az rest \
        --method PUT \
        --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Automation/automationAccounts/${AA}/jobSchedules/$(uuidgen | tr '[:upper:]' '[:lower:]')?api-version=2023-11-01" \
        --headers "Content-Type=application/json" \
        --body "{
            \"properties\": {
                \"runbook\":  { \"name\": \"$RUNBOOK_NAME\" },
                \"schedule\": { \"name\": \"$SCHEDULE_NAME\" },
                \"parameters\": {
                    \"MailboxUpn\":        \"$MAILBOX_UPN\",
                    \"SenderMailbox\":     \"$SENDER_MAILBOX\",
                    \"AlertRecipients\":   \"$ALERT_RECIPIENTS\",
                    \"ThresholdMinutes\":  \"$THRESHOLD_MINUTES\",
                    \"MinMessageCount\":   \"$MIN_MESSAGE_COUNT\",
                    \"StateVariableName\": \"$STATE_VARIABLE_NAME\",
                    \"DryRun\":            \"false\"
                }
            }
        }" --output none
    echo "✓ Schedule mit Runbook verknuepft"
else
    echo "  Schedule bereits mit Runbook verknuepft (Parameter-Aenderung: jobSchedule im Portal loeschen und setup.sh erneut ausfuehren)"
fi

echo ""
echo "============================================"
echo " Setup abgeschlossen!"
echo "============================================"
echo ""
echo " Naechste Schritte:"
echo "   1. grant-permissions.sh ausfuehren (einmalig, Global Admin)"
echo "   2. 5 Min warten (Graph Permissions brauchen Zeit)"
echo "   3. ./test.sh"
echo ""
