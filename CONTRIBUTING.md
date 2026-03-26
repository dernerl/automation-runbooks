# Contributing

Du hast eine Idee fuer ein neues Azure Automation Runbook? Beitraege sind willkommen!

## Neues Runbook vorschlagen

Oeffne ein [GitHub Issue](../../issues/new) mit:

- **Was** soll das Runbook tun?
- **Warum** wird es gebraucht? (Use Case, Pain Point)
- **Welche Graph API Permissions** werden voraussichtlich benoetigt?

## Runbook beisteuern

### Voraussetzungen

- PowerShell 7.4 Kenntnisse
- Zugang zu einem Azure Automation Account (Test-Umgebung)
- Verstaendnis der Microsoft Graph API

### Schnellstart mit Scaffold

Das Scaffold-Script erstellt die komplette Ordnerstruktur fuer ein neues Runbook:

```bash
./scaffold.sh Invoke-MeinNeuesRunbook
```

Der Name muss im PowerShell **Verb-Noun** Format sein und ein [Approved Verb](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands) verwenden.

> **Claude Code User:** Nutze `/new-runbook` — der Skill hilft beim Naming und fuehrt das Scaffold automatisch aus.

### Struktur

Das Scaffold erstellt folgenden Unterordner:

```
mein-neues-runbook/
├── Mein-NeuesRunbook.ps1    # Das Runbook selbst
├── setup.sh                  # Deploy-Script (Runbook + Runtime + Schedule)
├── test.sh                   # Test-Script (DryRun + Live)
├── grant-permissions.sh      # Graph Permissions zuweisen
└── .env.example              # Beispiel-Konfiguration (keine echten Werte!)
```

### Coding-Konventionen

- **PowerShell:** PascalCase Funktionen, `Verb-Noun` Naming, `-ErrorAction Stop`
- **Logging:** `Write-Output` (Info), `Write-Warning` (Warnung), `Write-Error` (Fehler)
- **DryRun:** Jedes Runbook muss einen `[bool]$DryRun = $true` Parameter haben (safe by default)
- **Graph API:** `Invoke-MgGraphRequest` mit Pagination (`Get-AllPages` Helper)
- **Bash:** `set -euo pipefail`, sauberes Quoting
- **Commits:** Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`), englisch

### Checkliste

Bevor du einen PR erstellst:

- [ ] `[bool]$DryRun = $true` Parameter vorhanden
- [ ] DryRun-Modus getestet (keine Seiteneffekte)
- [ ] Live-Modus getestet
- [ ] `setup.sh` und `test.sh` vorhanden
- [ ] Benoetigte Graph Permissions in `grant-permissions.sh` dokumentiert
- [ ] `.env.example` mit allen benoetigten Variablen
- [ ] README.md um das neue Runbook ergaenzt
- [ ] Keine Secrets im Code (`.env` ist in `.gitignore`)

### Workflow

1. Fork das Repo
2. Erstelle dein Runbook nach dem Pattern oben
3. Teste lokal mit `./test.sh`
4. Oeffne einen Pull Request mit Beschreibung des Use Cases

## Fragen?

Oeffne ein Issue — wir helfen gerne weiter.
