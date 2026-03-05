# automation-runbooks

Azure Automation Runbooks (PowerShell 7) für Entra ID / Microsoft 365.

---

## Runbooks

### [`Invoke-ServiceAccountMonitor`](./Invoke-ServiceAccountMonitor.ps1)

Prüft täglich alle User-Accounts in einer Entra-Gruppe auf fehlgeschlagene Sign-ins
(interactive + non-interactive) und benachrichtigt den hinterlegten Sponsor.
Ist kein Sponsor eingetragen, geht der Alert an eine Helpdesk-Adresse.

#### Alert-Logik

| Situation | "Kein Sponsor"-Alert | "Login-Fehler"-Alert |
|---|---|---|
| Sponsor ✓, kein Fehler | – | – |
| Sponsor ✓, Fehler | – | → Sponsor |
| Kein Sponsor, kein Fehler | → Helpdesk | – |
| Kein Sponsor, Fehler | → Helpdesk | → Helpdesk |

**Hintergrund:** Kerberos Seamless SSO und andere Service-Account-basierte Flows
können lautlos brechen wenn eine Conditional Access Policy greift. Dieses Runbook
macht solche Fehler frühzeitig sichtbar.

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
- Sponsor-Feld der Service Accounts befüllt (`Entra Portal → User → Sponsors`)

#### Setup

```bash
# 1. .env aus Vorlage erstellen und befüllen
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
| `LookbackHours` | `24` | Wie viele Stunden zurück geprüft wird |
| `DryRun` | `$true` | Wenn `$true`: kein Mail, nur Log-Output |

#### Bekannte Entra Error Codes

| Code | Bedeutung |
|---|---|
| `53003` | Conditional Access Policy blockiert den Login |
| `50057` | Account deaktiviert |
| `50072` | MFA Registrierung erforderlich |
| `50126` | Falsches Passwort / Credentials ungültig |
| `50097` | Device Authentication erforderlich |
