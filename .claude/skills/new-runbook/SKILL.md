---
name: new-runbook
description: "Erstellt ein neues Azure Automation Runbook mit korrektem PowerShell Verb-Noun Naming und Scaffold-Struktur. Nutze diesen Skill wenn der User 'neues Runbook', 'Runbook erstellen', 'neues Automation Script', 'scaffold runbook', 'Runbook anlegen', 'neuer Ordner fuer Runbook' oder 'weiteres Runbook' erwaehnt. Auch aktiv wenn der User eine Automatisierungsidee beschreibt die als Azure Automation Runbook umgesetzt werden soll."
---

# Neues Azure Automation Runbook anlegen

Dieser Skill fuehrt durch das Erstellen eines neuen Runbooks: Use Case besprechen, korrekten PowerShell-Namen waehlen, Scaffold generieren.

## Ablauf

### 1. Use Case klaeren

Frage den User:
- **Was** soll das Runbook automatisieren?
- **Welche Datenquelle** wird benoetigt? (Graph API, Azure Resource Manager, Exchange Online, etc.)
- **Was ist die Aktion?** (Bericht, Sync, Alert, Bereinigung, etc.)
- **Wer wird benachrichtigt** oder was ist der Output?

### 2. Runbook-Name vorschlagen

Schlage 2-3 Namen im Format `Verb-Noun` vor. Dabei gelten zwei harte Regeln:

**Regel 1: Nur PowerShell Approved Verbs verwenden.**

Die gaengigsten fuer Automation Runbooks:

| Verb | Wann verwenden |
|------|----------------|
| `Invoke` | Allgemeine Aktion ausfuehren, Monitoring, Checks |
| `Sync` | Abgleich zwischen zwei Systemen (Quelle → Ziel) |
| `Export` | Daten exportieren / Bericht erstellen |
| `Send` | Benachrichtigung, Mail, Webhook |
| `Update` | Bestehende Objekte aendern |
| `Remove` | Aufraeum-Jobs, Bereinigung |
| `Get` | Reine Datenabfrage |
| `Set` | Konfiguration setzen |
| `New` | Objekte anlegen |
| `Test` | Pruefung / Validierung |
| `Grant` | Berechtigungen vergeben |
| `Revoke` | Berechtigungen entziehen |
| `Enable` | Aktivieren |
| `Disable` | Deaktivieren |
| `Import` | Daten importieren |
| `Backup` | Sicherung erstellen |
| `Restore` | Wiederherstellung |
| `Protect` | Schutz aktivieren |
| `Measure` | Metriken / Statistiken |

Vollstaendige Liste: https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands

**Regel 2: Noun ist ein praegnanter PascalCase-Begriff.**
- Gut: `LicenseReport`, `SharedMailboxMembers`, `StaleGuestAccounts`
- Schlecht: `TheLicenseReportForM365`, `Data`, `Stuff`

**Beispiele fuer typische Kombinationen:**

| Use Case | Vorschlag |
|----------|-----------|
| Lizenzbericht per Mail | `Export-LicenseReport` |
| Inaktive Gaeste bereinigen | `Remove-StaleGuestAccounts` |
| Gruppenmitglieder abgleichen | `Sync-GroupMembers` |
| Service Account Passwoerter pruefen | `Test-ServiceAccountCredentials` |
| Shared Mailbox Berechtigungen setzen | `Grant-SharedMailboxAccess` |

### 3. Name bestaetigen lassen

Zeige die Vorschlaege mit kurzer Begruendung und lass den User waehlen oder anpassen. Pruefe dass der finale Name:
- Ein Approved Verb verwendet
- PascalCase Verb-Noun Format hat (`^[A-Z][a-zA-Z]+-[A-Z][a-zA-Z]+$`)

### 4. Scaffold ausfuehren

Fuehre das Scaffold-Script aus dem Repo-Root aus:

```bash
cd /Users/hug/Desktop/YOLO-WORKBENCH/automation-runbooks && ./scaffold.sh <RunbookName>
```

### 5. Naechste Schritte kommunizieren

Nach dem Scaffold hat der User einen fertigen Ordner. Weise auf die TODOs hin:

1. **`<Name>.ps1`** — Runbook-Logik implementieren (das Geruest mit DryRun steht schon)
2. **`.env.example`** — Runbook-spezifische Parameter ergaenzen
3. **`grant-permissions.sh`** — `PERMISSIONS` Array auf die benoetigten Graph Permissions anpassen
4. **`setup.sh`** — Schedule-Parameter im `az rest` Body anpassen
5. **`test.sh`** — Runbook-Parameter im `az automation runbook start` Aufruf ergaenzen
6. **`README.md`** — Neues Runbook in der Repo-README dokumentieren

Biete an, direkt mit der Implementierung der Runbook-Logik zu starten. Nutze dabei den `ms-graph-endpoint-research` Skill falls Graph API Calls benoetigt werden.
