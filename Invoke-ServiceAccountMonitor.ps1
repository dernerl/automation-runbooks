<#
.SYNOPSIS
    Service Account Sign-in Monitor

.DESCRIPTION
    Prüft täglich alle Accounts in "Conditional Access Service Accounts" auf
    fehlgeschlagene Sign-ins (interactive + non-interactive) und benachrichtigt
    den Sponsor des Accounts. Falls kein Sponsor hinterlegt → Helpdesk-Mail.

.PARAMETER GroupName
    Name der Entra-Gruppe mit den Service Accounts. Default: "Conditional Access Service Accounts"

.PARAMETER SenderMailbox
    UPN des Postfachs, von dem Alerts gesendet werden (braucht Mail.Send Permission).

.PARAMETER HelpdeskMail
    Fallback-Adresse wenn kein Sponsor hinterlegt ist.

.PARAMETER LookbackHours
    Wie viele Stunden zurück geprüft wird. Default: 24

.PARAMETER DryRun
    Wenn gesetzt, werden keine Mails gesendet. Default: $true

.NOTES
    Benötigte Graph Permissions (Application):
    - AuditLog.Read.All        (Sign-in Logs lesen)
    - Group.Read.All           (Gruppe + Members lesen)
    - User.Read.All            (Sponsor-Feld lesen)
    - Mail.Send                (Alerts versenden)
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$GroupName = "Conditional Access Service Accounts",

    [Parameter(Mandatory=$false)]
    [string]$SenderMailbox = "automation@domain.com",

    [Parameter(Mandatory=$false)]
    [string]$HelpdeskMail = "helpdesk@domain.com",

    [Parameter(Mandatory=$false)]
    [int]$LookbackHours = 24,

    [bool]$DryRun = $true
)

# ==== Verbindung ====
try {
    Connect-MgGraph -Identity -NoWelcome -ErrorAction Stop
    Write-Output "✓ Graph-Verbindung hergestellt"
} catch {
    Write-Error "Verbindung fehlgeschlagen: $($_.Exception.Message)"
    throw
}

# ==== Hilfsfunktionen ====

function Get-AllPages {
    param([string]$Uri)
    $allItems = @()
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop
        if ($response.value) { $allItems += @($response.value) }
        $Uri = $response.'@odata.nextLink'
    } while ($Uri)
    # Rückgabe immer als Array – Aufrufer muss $result = @(Get-AllPages ...) verwenden
    # damit PS bei 1 Element kein Hashtable zurückgibt (Pipeline-Enumeration-Gotcha)
    return , $allItems  # Komma-Operator verhindert Pipeline-Enumeration
}

function Send-AlertMail {
    param(
        [string]$To,
        [string]$Subject,
        [string]$HtmlBody
    )

    $payload = @{
        message = @{
            subject = $Subject
            body = @{
                contentType = "HTML"
                content     = $HtmlBody
            }
            toRecipients = @(
                @{ emailAddress = @{ address = $To } }
            )
        }
        saveToSentItems = $false
    } | ConvertTo-Json -Depth 10

    if ($DryRun) {
        Write-Output "  [DRYRUN] Mail würde gesendet an: $To"
        Write-Output "  [DRYRUN] Betreff: $Subject"
        return
    }

    try {
        Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/users/$SenderMailbox/sendMail" `
            -Body $payload -ContentType "application/json" -ErrorAction Stop
        Write-Output "  ✓ Mail gesendet an: $To"
    } catch {
        Write-Error "  Mail-Fehler an $To`: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            $detail = $_.ErrorDetails.Message | ConvertFrom-Json
            Write-Error "  Graph-Error: $($detail.error.code) – $($detail.error.message)"
        }
    }
}

function Build-ErrorTable {
    param([array]$SignIns)
    $rows = $SignIns | Select-Object -First 5 | ForEach-Object {
        $type = if ($_.isInteractive -eq $true) { "Interactive" } else { "Non-Interactive" }
        "<tr>
            <td style='padding:4px 8px'>$($_.createdDateTime)</td>
            <td style='padding:4px 8px'>$($_.status.errorCode)</td>
            <td style='padding:4px 8px'>$($_.status.failureReason)</td>
            <td style='padding:4px 8px'>$($_.appDisplayName)</td>
            <td style='padding:4px 8px'>$type</td>
        </tr>"
    }
    return $rows -join "`n"
}

# ==== Gruppe finden ====
try {
    $groupResponse = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$GroupName'&`$select=id,displayName" `
        -ErrorAction Stop

    if (-not $groupResponse.value -or $groupResponse.value.Count -eq 0) {
        throw "Gruppe '$GroupName' nicht gefunden"
    }
    $group = $groupResponse.value[0]
    Write-Output "✓ Gruppe: $($group.displayName) [$($group.id)]"
} catch {
    Write-Error "Gruppe nicht gefunden: $($_.Exception.Message)"
    throw
}

# ==== Members holen (nur User-Objekte, keine Gruppen/Devices/SPNs) ====
$members = Get-AllPages -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/microsoft.graph.user?`$select=id,displayName,userPrincipalName,mail"
Write-Output "✓ $($members.Count) Service Account(s) in Gruppe"

if ($members.Count -eq 0) {
    Write-Output "Keine Members – Runbook beendet."
    Disconnect-MgGraph | Out-Null
    return
}

# ==== Zeitfenster ====
$since    = (Get-Date).ToUniversalTime().AddHours(-$LookbackHours)
$sinceStr = $since.ToString("yyyy-MM-ddTHH:mm:ssZ")
Write-Output "Prüfzeitraum: letzte $LookbackHours Stunden (seit $sinceStr)"

# ==== Zähler ====
$statsOk        = 0
$statsAlert     = 0
$statsNoSponsor = 0

# ==== Pro Account prüfen ====
foreach ($member in $members) {
    $upn    = $member.userPrincipalName
    $userId = $member.id

    Write-Output ""
    Write-Output "--- $upn ---"

    # Sponsor immer prüfen (unabhängig von Sign-in-Status)
    $sponsorMail    = $null
    $sponsorDisplay = $null
    try {
        $sponsorsResp = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/users/$userId/sponsors?`$select=id,displayName,mail,userPrincipalName" `
            -ErrorAction Stop
        if ($sponsorsResp.value -and $sponsorsResp.value.Count -gt 0) {
            $sponsor        = $sponsorsResp.value[0]
            $sponsorDisplay = $sponsor.displayName
            $sponsorMail    = if ($sponsor.mail) { $sponsor.mail } else { $sponsor.userPrincipalName }
            Write-Output "  Sponsor: $sponsorDisplay ($sponsorMail)"
        } else {
            Write-Output "  ! Kein Sponsor hinterlegt"
            $statsNoSponsor++
        }
    } catch {
        Write-Warning "  Sponsor-Feld nicht abrufbar: $($_.Exception.Message)"
    }

    $failedSignIns = [System.Collections.Generic.List[object]]::new()

    # Interactive Sign-ins mit Fehler
    try {
        $uri = "https://graph.microsoft.com/v1.0/auditLogs/signIns?" +
               "`$filter=userId eq '$userId'" +
               " and createdDateTime ge $sinceStr" +
               " and status/errorCode ne 0" +
               " and isInteractive eq true" +
               "&`$select=id,createdDateTime,status,appDisplayName,ipAddress,isInteractive" +
               "&`$top=25"
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        if ($resp.value) { $failedSignIns.AddRange([object[]]@($resp.value)) }
        Write-Output "  Interactive Fehler: $($resp.value.Count)"
    } catch {
        Write-Warning "  Fehler bei interactive Sign-in Abfrage: $($_.Exception.Message)"
    }

    # Non-interactive Sign-ins mit Fehler (Kerberos SSO, token refresh etc.)
    try {
        $uri = "https://graph.microsoft.com/v1.0/auditLogs/signIns?" +
               "`$filter=userId eq '$userId'" +
               " and createdDateTime ge $sinceStr" +
               " and status/errorCode ne 0" +
               " and isInteractive eq false" +
               "&`$select=id,createdDateTime,status,appDisplayName,ipAddress,isInteractive" +
               "&`$top=25"
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        if ($resp.value) { $failedSignIns.AddRange([object[]]@($resp.value)) }
        Write-Output "  Non-Interactive Fehler: $($resp.value.Count)"
    } catch {
        Write-Warning "  Fehler bei non-interactive Sign-in Abfrage: $($_.Exception.Message)"
    }

    # ==== Kein Sponsor → eigener Alert an Helpdesk ====
    if (-not $sponsorMail) {
        $sponsorSubject = "[Service Account] Kein Sponsor hinterlegt: $upn"
        $sponsorBody    = @"
<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px">
<h2 style="color:#e67e00">Service Account ohne Sponsor</h2>
<p>Für den folgenden Service Account ist kein Sponsor in Entra ID hinterlegt:</p>
<table style="border-collapse:collapse;margin-bottom:16px">
  <tr><th style="text-align:left;padding:4px 8px;background:#f0f0f0">Account</th>
      <td style="padding:4px 8px">$upn</td></tr>
</table>
<p>Bitte das <b>Sponsors-Feld</b> in Entra ID befüllen:<br/>
   Entra Portal → Users → $upn → Sponsors</p>
<p>Ohne Sponsor landen künftige Login-Alerts hier beim Helpdesk statt bei der zuständigen Person.</p>
<p style="color:#888;font-size:12px">Automatischer Alert – Azure Automation | Service Account Monitor</p>
</body></html>
"@
        Send-AlertMail -To $HelpdeskMail -Subject $sponsorSubject -HtmlBody $sponsorBody
    }

    if ($failedSignIns.Count -eq 0) {
        Write-Output "  ✓ Keine fehlgeschlagenen Logins"
        $statsOk++
        continue
    }

    Write-Output "  ! $($failedSignIns.Count) fehlgeschlagene Sign-in(s)"
    foreach ($s in $failedSignIns | Select-Object -First 3) {
        Write-Output "    [$($s.createdDateTime)] Code $($s.status.errorCode) – $($s.status.failureReason) | App: $($s.appDisplayName)"
    }

    # ==== Login-Alert: Sponsor oder Helpdesk als Fallback ====
    $recipient = if ($sponsorMail) { $sponsorMail } else { $HelpdeskMail }

    $noSponsorNote = if (-not $sponsorMail) {
        "<p style='color:#c00;border:1px solid #c00;padding:8px'>
            <b>Hinweis:</b> Für diesen Service Account ist kein Sponsor hinterlegt.
            Bitte das Sponsor-Feld in Entra ID befüllen, damit künftige Alerts direkt
            an die zuständige Person gehen.
        </p>"
    } else { "" }

    $errorTable = Build-ErrorTable -SignIns $failedSignIns

    $subject = "[Service Account Alert] $upn – $($failedSignIns.Count) fehlgeschlagene Sign-in(s)"
    $body    = @"
<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px">
<h2 style="color:#c00">Service Account Alert</h2>

<p>Für den folgenden Service Account wurden in den letzten <b>$LookbackHours Stunden</b>
fehlgeschlagene Anmeldeversuche registriert:</p>

<table style="border-collapse:collapse;margin-bottom:16px">
  <tr><th style="text-align:left;padding:4px 8px;background:#f0f0f0">Account</th>
      <td style="padding:4px 8px">$upn</td></tr>
  <tr><th style="text-align:left;padding:4px 8px;background:#f0f0f0">Anzahl Fehler</th>
      <td style="padding:4px 8px"><b>$($failedSignIns.Count)</b></td></tr>
  <tr><th style="text-align:left;padding:4px 8px;background:#f0f0f0">Prüfzeitraum</th>
      <td style="padding:4px 8px">$sinceStr bis jetzt</td></tr>
</table>

<h3>Fehlgeschlagene Sign-ins (max. 5)</h3>
<table border="1" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px">
  <tr style="background:#f0f0f0">
    <th style="padding:4px 8px">Zeitpunkt (UTC)</th>
    <th style="padding:4px 8px">Fehlercode</th>
    <th style="padding:4px 8px">Fehlergrund</th>
    <th style="padding:4px 8px">Applikation</th>
    <th style="padding:4px 8px">Typ</th>
  </tr>
  $errorTable
</table>

$noSponsorNote

<p>Bitte prüfen Sie, ob der Account weiterhin korrekt konfiguriert ist und ob
Conditional Access Policies oder Passwort/Zertifikat angepasst werden müssen.</p>

<p style="color:#888;font-size:12px">
  Automatischer Alert – Azure Automation | Service Account Monitor<br/>
  Bei Fragen: $HelpdeskMail
</p>
</body></html>
"@

    Send-AlertMail -To $recipient -Subject $subject -HtmlBody $body
    $statsAlert++
}

# ==== Zusammenfassung ====
Write-Output ""
Write-Output "=== Zusammenfassung ==="
Write-Output "  Accounts geprüft     : $($members.Count)"
Write-Output "  Ohne Fehler          : $statsOk"
Write-Output "  Ohne Sponsor         : $statsNoSponsor (immer geprüft)"
Write-Output "  Alerts ausgelöst     : $statsAlert"
if ($DryRun) { Write-Output "  [DRYRUN] Es wurden keine Mails tatsächlich versendet" }

Disconnect-MgGraph | Out-Null
Write-Output "✓ Runbook abgeschlossen"