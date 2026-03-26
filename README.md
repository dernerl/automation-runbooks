# automation-runbooks

Azure Automation Runbooks (PowerShell 7) fuer Entra ID / Microsoft 365.

## Repo-Struktur

```
automation-runbooks/
├── service-account-monitor/
│   ├── Invoke-ServiceAccountMonitor.ps1
│   ├── setup.sh
│   ├── test.sh
│   ├── grant-permissions.sh
│   └── .env.example
├── manage-teams-team/
│   ├── Manage-TeamsTeam.ps1
│   ├── setup.sh
│   ├── test.sh
│   ├── grant-permissions.sh
│   └── .env.example
├── README.md
├── CONTRIBUTING.md
└── CLAUDE.md
```

Jedes Runbook lebt in einem eigenen Ordner mit allen Companion-Scripts und eigener `.env`.

---

## Runbooks

### [`Invoke-ServiceAccountMonitor`](./service-account-monitor/Invoke-ServiceAccountMonitor.ps1)

Prueft taeglich alle User-Accounts in einer Entra-Gruppe auf fehlgeschlagene Sign-ins
(interactive + non-interactive) und benachrichtigt den hinterlegten Sponsor.
Ist kein Sponsor eingetragen, geht der Alert an eine Helpdesk-Adresse.

#### Alert-Logik

| Situation | "Kein Sponsor"-Alert | "Login-Fehler"-Alert |
|---|---|---|
| Sponsor ✓, kein Fehler | – | – |
| Sponsor ✓, Fehler | – | → Sponsor |
| Kein Sponsor (Cloud-only), kein Fehler | → Helpdesk | – |
| Kein Sponsor (Cloud-only), Fehler | → Helpdesk | → Helpdesk |
| Kein Sponsor (on-prem synced), kein Fehler | – | – |
| Kein Sponsor (on-prem synced), Fehler | – | → Helpdesk |

> **On-prem synced Accounts:** Das Sponsor-Feld ist in Entra ID nur fuer Cloud-only
> Accounts beschreibbar. Bei on-prem synced Accounts wird daher kein "Kein Sponsor"-Alert
> gesendet — das Feld kann dort nicht befuellt werden. Login-Fehler-Alerts gehen
> in diesem Fall direkt an den Helpdesk.

**Hintergrund:** Kerberos Seamless SSO und andere Service-Account-basierte Flows
koennen lautlos brechen wenn eine Conditional Access Policy greift. Dieses Runbook
macht solche Fehler fruehzeitig sichtbar.

#### Voraussetzungen

- Azure Automation Account mit **System Assigned Managed Identity**
- Runtime Environment **PowerShell 7.4** mit `Microsoft.Graph.Authentication`
- Graph API Permissions (Application):
  | Permission | Zweck |
  |---|---|
  | `AuditLog.Read.All` | Sign-in Logs lesen |
  | `Group.Read.All` | Gruppe + Members lesen |
  | `User.Read.All` | Sponsor-Feld lesen |
  | `Mail.Send` | Alerts versenden |
- Shared Mailbox oder User-Mailbox als Absender
- Entra-Gruppe `Conditional Access Service Accounts` (Name konfigurierbar)
- Sponsor-Feld der Service Accounts befuellt (`Entra Portal → User → Sponsors`)

#### Setup

```bash
cd service-account-monitor

# 1. .env aus Vorlage erstellen und befuellen
cp .env.example .env

# 2. Graph Permissions setzen (braucht Global Admin)
./grant-permissions.sh

# 3. Runbook + Runtime + Schedule deployen
./setup.sh

# 4. Testlauf (DryRun – kein Mail)
./test.sh

# 5. Live-Lauf
./test.sh live
```

#### Parameter

| Parameter | Default | Beschreibung |
|---|---|---|
| `GroupName` | `Conditional Access Service Accounts` | Entra-Gruppe mit den Service Accounts |
| `SenderMailbox` | – | Absender-Mailbox (UPN) |
| `HelpdeskMail` | – | Fallback wenn kein Sponsor hinterlegt |
| `LookbackHours` | `24` | Wie viele Stunden zurueck geprueft wird |
| `DryRun` | `$true` | Wenn `$true`: kein Mail, nur Log-Output |

#### Bekannte Entra Error Codes

| Code | Bedeutung |
|---|---|
| `53003` | Conditional Access Policy blockiert den Login |
| `50057` | Account deaktiviert |
| `50072` | MFA Registrierung erforderlich |
| `50126` | Falsches Passwort / Credentials ungueltig |
| `50097` | Device Authentication erforderlich |
| `700003` | Device object was not found (Token/Geraete-Problem) |

---

### [`Manage-TeamsTeam`](./manage-teams-team/Manage-TeamsTeam.ps1)

Synchronisiert die Mitglieder einer oder mehrerer Entra-Gruppen in eine Teams-Gruppe.
Mitglieder, die in mindestens einer der Quell-Gruppen sind, werden hinzugefuegt.
Mitglieder, die in keiner Quell-Gruppe mehr enthalten sind, werden entfernt.
Ein Automation-User kann per Parameter ausgeschlossen werden.

#### Voraussetzungen

- Azure Automation Account mit **System Assigned Managed Identity**
- Graph API Permissions (Application):
  | Permission | Zweck |
  |---|---|
  | `Group.ReadWrite.All` | Gruppenmitglieder lesen und aendern |
  | `User.Read.All` | User-Details aufloesen |
  | `TeamSettings.ReadWrite.All` | Teams-Gruppen verwalten |

#### Setup

```bash
cd manage-teams-team

# 1. .env aus Vorlage erstellen und befuellen
cp .env.example .env

# 2. Graph Permissions setzen (braucht Global Admin)
./grant-permissions.sh

# 3. Runbook + Runtime + Schedule deployen
./setup.sh

# 4. Testlauf (DryRun)
./test.sh

# 5. Live-Lauf
./test.sh live
```

#### Parameter

| Parameter | Typ | Beschreibung |
|---|---|---|
| `EntraGroupNames` | `string[]` | Eine oder mehrere Entra-Quellgruppen |
| `TeamsGroupName` | `string` | Ziel-Teams-Gruppe |
| `AutomationUserName` | `string` | UPN des Automation-Accounts (wird ignoriert) |
| `DryRun` | `bool` | Wenn `$true`: keine Aenderungen, nur Log-Output |

#### Beispiel

```powershell
# DryRun – zeigt nur an, was passieren wuerde
.\Manage-TeamsTeam.ps1 -EntraGroupNames "Gruppe-A","Gruppe-B" -TeamsGroupName "Team Homeoffice" -DryRun $true

# Live – fuehrt Aenderungen durch
.\Manage-TeamsTeam.ps1 -EntraGroupNames "Gruppe-A","Gruppe-B","Gruppe-C" -TeamsGroupName "Team Homeoffice" -DryRun $false
```
