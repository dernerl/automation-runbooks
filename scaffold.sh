#!/usr/bin/env bash
# =============================================================================
# Scaffold – Neues Runbook erstellen
# =============================================================================
# Erstellt die komplette Ordnerstruktur fuer ein neues Runbook:
#   <dir-name>/
#   ├── <RunbookName>.ps1
#   ├── setup.sh
#   ├── test.sh
#   ├── grant-permissions.sh
#   └── .env.example
#
# Usage:
#   ./scaffold.sh <RunbookName>
#   ./scaffold.sh Invoke-LicenseReport
#   ./scaffold.sh Sync-SharedMailboxMembers
# =============================================================================
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: ./scaffold.sh <RunbookName>"
    echo ""
    echo "  RunbookName muss PowerShell Verb-Noun Format haben."
    echo "  Beispiel: Invoke-LicenseReport, Sync-SharedMailboxMembers"
    exit 1
fi

RUNBOOK_NAME="$1"

# Validate Verb-Noun format
if ! echo "$RUNBOOK_NAME" | grep -qE '^[A-Z][a-zA-Z]+-[A-Z][a-zA-Z]+$'; then
    echo "FEHLER: '$RUNBOOK_NAME' ist kein gueltiges Verb-Noun Format."
    echo "  Erwartet: PascalCase-PascalCase (z.B. Invoke-LicenseReport)"
    exit 1
fi

# Directory name: lowercase with hyphens
DIR_NAME=$(echo "$RUNBOOK_NAME" | sed 's/\([A-Z]\)/-\1/g' | sed 's/^-//' | tr '[:upper:]' '[:lower:]')

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$SCRIPT_DIR/$DIR_NAME"

if [ -d "$TARGET_DIR" ]; then
    echo "FEHLER: Ordner '$DIR_NAME' existiert bereits."
    exit 1
fi

echo "============================================"
echo " Scaffold: $RUNBOOK_NAME"
echo " Ordner:   $DIR_NAME/"
echo "============================================"
echo ""

mkdir -p "$TARGET_DIR"

# ==== .env.example ====
cat > "$TARGET_DIR/.env.example" << 'ENVEOF'
# =============================================================================
# __RUNBOOK_NAME__ – Konfiguration
# Kopiere diese Datei nach .env und fuelle die Werte aus.
# .env wird NICHT ins Repository committed (siehe .gitignore).
# =============================================================================

# Azure Infrastruktur
SUBSCRIPTION_ID="your-subscription-id"
RG="rg-your-resource-group"
AA="aa-your-automation-account"
LOCATION="westeurope"
MI_OBJECT_ID="your-managed-identity-object-id"

# Runbook
RUNBOOK_NAME="__RUNBOOK_NAME__"
RUNTIME_ENV="__RUNTIME_ENV__"

# Schedule (UTC)
SCHEDULE_NAME="__SCHEDULE_NAME__"
SCHEDULE_HOUR="07"        # 07:00 UTC = 08:00 MEZ

# --- Runbook-spezifische Parameter hier ergaenzen ---
# PARAM_1="value"
# PARAM_2="value"
ENVEOF

# Generate runtime-env and schedule names
RUNTIME_ENV="psenv-${DIR_NAME}"
SCHEDULE_NAME="daily-${DIR_NAME}"

sed -i '' "s/__RUNBOOK_NAME__/$RUNBOOK_NAME/g" "$TARGET_DIR/.env.example"
sed -i '' "s/__RUNTIME_ENV__/$RUNTIME_ENV/g" "$TARGET_DIR/.env.example"
sed -i '' "s/__SCHEDULE_NAME__/$SCHEDULE_NAME/g" "$TARGET_DIR/.env.example"

echo "  ✓ .env.example"

# ==== Runbook .ps1 ====
cat > "$TARGET_DIR/$RUNBOOK_NAME.ps1" << PSEOF
<# Modules Requires
    Microsoft.Graph.Authentication
#>
<#
.SYNOPSIS
    TODO: Beschreibung ergaenzen.

.DESCRIPTION
    TODO: Detaillierte Beschreibung ergaenzen.

.PARAMETER DryRun
    Wenn gesetzt, werden keine Aenderungen vorgenommen. Es wird nur angezeigt, was passieren wuerde.

.EXAMPLE
    .\\${RUNBOOK_NAME}.ps1 -DryRun \$true
#>

param (
    [Parameter(Mandatory=\$false)]
    [bool]\$DryRun = \$true
)

if (\$DryRun) {
    Write-Output "=== DRY RUN – Es werden keine Aenderungen vorgenommen ==="
}

# Anmelden bei Microsoft Graph mit Managed Identity
Connect-MgGraph -Identity

# --- Runbook-Logik hier ---


# Abmelden von Microsoft Graph
Disconnect-MgGraph
PSEOF
echo "  ✓ $RUNBOOK_NAME.ps1"

# ==== setup.sh ====
cat > "$TARGET_DIR/setup.sh" << 'SETUPEOF'
#!/usr/bin/env bash
# =============================================================================
# __RUNBOOK_NAME__ – Setup via Azure CLI
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

# === 4. Schedule ===
echo ""
echo "=== 4. Schedule anlegen (taeglich ${SCHEDULE_HOUR}:00 UTC) ==="
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
    echo "✓ Schedule erstellt"
else
    echo "  Schedule '$SCHEDULE_NAME' existiert bereits"
fi

# TODO: Schedule-Parameter an Runbook anpassen
az rest \
    --method PUT \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Automation/automationAccounts/${AA}/jobSchedules/$(uuidgen | tr '[:upper:]' '[:lower:]')?api-version=2023-11-01" \
    --headers "Content-Type=application/json" \
    --body "{
        \"properties\": {
            \"runbook\":  { \"name\": \"$RUNBOOK_NAME\" },
            \"schedule\": { \"name\": \"$SCHEDULE_NAME\" },
            \"parameters\": {
                \"DryRun\": \"false\"
            }
        }
    }" --output none
echo "✓ Schedule mit Runbook verknuepft"

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
SETUPEOF
echo "  ✓ setup.sh"

# ==== test.sh ====
cat > "$TARGET_DIR/test.sh" << 'TESTEOF'
#!/usr/bin/env bash
# =============================================================================
# __RUNBOOK_NAME__ – Testlauf (DryRun)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "FEHLER: .env nicht gefunden."
    exit 1
fi
source "$SCRIPT_DIR/.env"

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
    --parameters DryRun="$DRYRUN" \
    --query "jobId" -o tsv 2>/dev/null)

echo "Job ID: $JOB_ID"
echo ""

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
TESTEOF

sed -i '' "s/__RUNBOOK_NAME__/$RUNBOOK_NAME/g" "$TARGET_DIR/test.sh"
echo "  ✓ test.sh"

# ==== grant-permissions.sh ====
cat > "$TARGET_DIR/grant-permissions.sh" << 'GRANTEOF'
#!/usr/bin/env bash
# =============================================================================
# __RUNBOOK_NAME__ – Graph API Permissions fuer Managed Identity
# =============================================================================
# Benoetigt: Global Admin oder Privileged Role Administrator
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "FEHLER: .env nicht gefunden."
    exit 1
fi
source "$SCRIPT_DIR/.env"

az account set --subscription "$SUBSCRIPTION_ID"

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

# TODO: Permissions an das Runbook anpassen
PERMISSIONS=(
    "User.Read.All"
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
GRANTEOF

sed -i '' "s/__RUNBOOK_NAME__/$RUNBOOK_NAME/g" "$TARGET_DIR/grant-permissions.sh"
echo "  ✓ grant-permissions.sh"

# Make scripts executable
chmod +x "$TARGET_DIR/setup.sh" "$TARGET_DIR/test.sh" "$TARGET_DIR/grant-permissions.sh"

echo ""
echo "============================================"
echo " ✓ Scaffold abgeschlossen!"
echo "============================================"
echo ""
echo " Ordner: $DIR_NAME/"
echo ""
echo " Naechste Schritte:"
echo "   1. $RUNBOOK_NAME.ps1 – Logik implementieren"
echo "   2. .env.example – Runbook-spezifische Parameter ergaenzen"
echo "   3. grant-permissions.sh – PERMISSIONS Array anpassen"
echo "   4. setup.sh – Schedule-Parameter anpassen"
echo "   5. test.sh – Runbook-Parameter ergaenzen"
echo "   6. README.md – Neues Runbook dokumentieren"
echo ""
