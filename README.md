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
├── invoke-helpdesk-mailbox-monitor/
│   ├── Invoke-HelpdeskMailboxMonitor.ps1
│   ├── setup.sh
│   ├── test.sh
│   ├── grant-permissions.sh
│   └── .env.example
├── scaffold.sh
├── README.md
├── CONTRIBUTING.md
└── CLAUDE.md
```

Jedes Runbook lebt in einem eigenen Ordner mit allen Companion-Scripts und eigener `.env`.

### Runtime Environment

Alle Runbooks laufen in der **gemeinsamen PowerShell-7.4-Runtime** des Automation Accounts
(`RUNTIME_ENV` in der `.env`, in Prod `PowerShell-7-4`). `setup.sh` legt keine eigene Runtime an,
sondern prueft nur, ob die Runtime existiert, PowerShell 7.4 ist und die Module aus
`REQUIRED_MODULES` enthaelt – sonst bricht es mit einer Meldung ab. Fehlende Module werden
zentral in der gemeinsamen Runtime installiert.

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
- Gemeinsame Runtime Environment (PowerShell 7.4) mit `Microsoft.Graph.Authentication`
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

# 3. Runtime pruefen, Runbook + Schedule deployen
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
- Gemeinsame Runtime Environment (PowerShell 7.4) mit `Microsoft.Graph.Authentication`, `Microsoft.Graph.Groups`, `Microsoft.Graph.Users`
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

# 3. Runtime pruefen, Runbook + Schedule deployen
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

---

### [`Invoke-HelpdeskMailboxMonitor`](./invoke-helpdesk-mailbox-monitor/Invoke-HelpdeskMailboxMonitor.ps1)

Ueberwacht den Posteingang des Ticketsystem-Postfachs. Das Ticketsystem holt Mails dort ab
und verschiebt sie in einen Ordner – der Posteingang ist im Normalbetrieb also (fast) leer.
Liegen dort mindestens `MinMessageCount` Mails, die aelter als `ThresholdMinutes` sind,
haengt der Crawler vermutlich und es geht ein Alert raus.

#### Alert-Logik

Der Zustand wird in der Automation-Variable `HelpdeskBacklogAlertActive` gespeichert,
damit waehrend einer Stoerung nicht jede Stunde eine neue Mail kommt:

| Haengende Mails ≥ Schwelle | Alert bereits aktiv | Aktion |
|---|---|---|
| ja | nein | ⚠ Alert-Mail (mit Liste der Mails), Variable → `true` |
| ja | ja | – (Stoerung haelt an) |
| nein | ja | ✓ Entwarnungs-Mail, Variable → `false` |
| nein | nein | – |

> **Alert-Empfaenger ≠ ueberwachtes Postfach.** Ein Alert an `helpdesk@` wuerde selbst
> im haengenden Posteingang liegen bleiben. Das Runbook warnt, wenn das passiert.

> **Intervall:** Azure Automation Schedules laufen minimal stuendlich. Ein Ausfall faellt
> daher nach 5–65 Minuten auf. Fuer kuerzere Intervalle weitere Schedules mit versetzter
> Startzeit (z. B. :15, :30, :45) anlegen und mit dem Runbook verknuepfen.

#### Voraussetzungen

- Azure Automation Account mit **System Assigned Managed Identity**
- Gemeinsame Runtime Environment (PowerShell 7.4) mit `Microsoft.Graph.Authentication`
- Graph API Permissions (Application):
  | Permission | Zweck |
  |---|---|
  | `Mail.ReadBasic.All` | Posteingang lesen (nur Metadaten – kein Body, keine Anhaenge) |
  | `Mail.Send` | Alerts versenden |
- Shared Mailbox oder User-Mailbox als Absender
- Empfohlen: Die Mail-Permissions gelten tenantweit. Per
  [RBAC for Applications](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac)
  in Exchange Online auf das Helpdesk- und das Absender-Postfach einschraenken.

#### Setup

```bash
cd invoke-helpdesk-mailbox-monitor

# 1. .env aus Vorlage erstellen und befuellen
cp .env.example .env

# 2. Graph Permissions setzen (braucht Global Admin)
./grant-permissions.sh

# 3. Runtime pruefen, Runbook + Zustands-Variable + stuendlichen Schedule deployen
./setup.sh

# 4. Testlauf (DryRun – kein Mail, Zustand wird nicht gespeichert)
./test.sh

# 5. Live-Lauf
./test.sh live
```

#### Parameter

| Parameter | Default | Beschreibung |
|---|---|---|
| `MailboxUpn` | – | Ueberwachtes Postfach (z. B. `helpdesk@…`) |
| `SenderMailbox` | – | Absender-Mailbox (UPN) |
| `AlertRecipients` | – | Alert-Empfaenger, kommagetrennt. Auch die Mailadresse eines Teams-Kanals (`…@de.teams.ms`) – Alerts erscheinen dann als Post im Kanal |
| `ThresholdMinutes` | `5` | Ab welchem Alter eine Mail als "haengt" gilt |
| `MinMessageCount` | `1` | Ab wie vielen haengenden Mails alarmiert wird |
| `StateVariableName` | `HelpdeskBacklogAlertActive` | Automation-Variable fuer den Alert-Zustand |
| `DryRun` | `$true` | Wenn `$true`: kein Mail, Zustand wird nicht gespeichert |

---

## Neues Runbook anlegen

```bash
./scaffold.sh Verb-Noun   # z. B. ./scaffold.sh Invoke-LicenseReport → invoke-license-report/
```

