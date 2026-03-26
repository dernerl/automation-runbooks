#!/usr/bin/env bash
# =============================================================================
# Manage Teams Team – Testlauf (DryRun)
# Startet das Runbook und pollt bis zum Ende.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "FEHLER: .env nicht gefunden."
    exit 1
fi
source "$SCRIPT_DIR/.env"

# DryRun per Argument ueberschreibbar: ./test.sh live
DRYRUN="true"
if [ "${1:-}" == "live" ]; then
    DRYRUN="false"
    echo "! LIVE-Modus – Aenderungen werden tatsaechlich durchgefuehrt!"
fi

az account set --subscription "$SUBSCRIPTION_ID"

echo "=== Starte Runbook (DryRun=$DRYRUN) ==="
JOB_ID=$(az automation runbook start \
    --resource-group "$RG" \
    --automation-account-name "$AA" \
    --name "$RUNBOOK_NAME" \
    --parameters \
        DryRun="$DRYRUN" \
        EntraGroupNames="$ENTRA_GROUP_NAMES" \
        TeamsGroupName="$TEAMS_GROUP_NAME" \
        AutomationUserName="$AUTOMATION_USER_NAME" \
    --query "jobId" -o tsv 2>/dev/null)

echo "Job ID: $JOB_ID"
echo ""

# ==== Status pollen ====
echo "=== Warte auf Abschluss ==="
while true; do
    STATUS=$(az automation job show \
        --resource-group "$RG" \
        --automation-account-name "$AA" \
        --job-name "$JOB_ID" \
        --query "status" -o tsv 2>/dev/null)

    echo "  Status: $STATUS"

    if [[ "$STATUS" != "Running" && "$STATUS" != "New" && "$STATUS" != "Queued" && "$STATUS" != "Activating" && -n "$STATUS" ]]; then
        break
    fi
    sleep 10
done

echo ""
echo "=== Output ($STATUS) ==="
az rest \
    --method GET \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Automation/automationAccounts/${AA}/jobs/${JOB_ID}/streams?api-version=2019-06-01" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for s in data.get('value', []):
    props = s.get('properties', {})
    stype = props.get('streamType', '')
    text  = props.get('summary', '')
    if text:
        prefix = '  !' if stype == 'Error' else '  '
        print(f'{prefix}[{stype}] {text}')
"

echo ""
[ "$STATUS" == "Completed" ] && echo "✓ Runbook erfolgreich" || echo "! Runbook fehlgeschlagen – Status: $STATUS"
