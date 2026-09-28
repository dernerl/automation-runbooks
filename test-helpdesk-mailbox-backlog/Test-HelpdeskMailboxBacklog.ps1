<# Modules Requires
    Microsoft.Graph.Authentication
#>
<#
.SYNOPSIS
    Prueft ob sich im Posteingang des Ticketsystem-Postfachs Mails stauen (Crawler haengt).

.DESCRIPTION
    Das Ticketsystem holt Mails aus dem Posteingang ab und verschiebt sie in einen Ordner.
    Der Posteingang ist im Normalbetrieb also (fast) leer. Liegen dort mindestens
    MinMessageCount Mails, die aelter als ThresholdMinutes sind, gilt der Crawler als
    ausgefallen und es geht eine Alert-Mail raus.

    Um Spam waehrend einer laenger andauernden Stoerung zu vermeiden, wird der Zustand in
    der Automation-Variable StateVariableName gespeichert:
      - Stoerung beginnt  → eine Alert-Mail
      - Stoerung haelt an → keine weitere Mail
      - Stoerung behoben  → eine Entwarnungs-Mail

.PARAMETER MailboxUpn
    Ueberwachtes Postfach (Ticketsystem-Eingang).

.PARAMETER SenderMailbox
    UPN des Postfachs, von dem Alerts gesendet werden (braucht Mail.Send Permission).

.PARAMETER AlertRecipients
    Empfaenger der Alerts, kommagetrennt. NICHT das ueberwachte Postfach selbst –
    dort wuerde der Alert ja ebenfalls liegen bleiben.

.PARAMETER ThresholdMinutes
    Ab welchem Alter eine Mail im Posteingang als "haengt" gilt.

.PARAMETER MinMessageCount
    Ab wie vielen haengenden Mails alarmiert wird.

.PARAMETER StateVariableName
    Name der Automation-Variable (bool), die speichert ob gerade ein Alert aktiv ist.

.PARAMETER DryRun
    Wenn gesetzt, werden keine Mails versendet und der Zustand nicht gespeichert.

.NOTES
    Graph Permissions (Application):
    - Mail.ReadBasic.All       (Posteingang lesen – nur Metadaten, kein Body)
    - Mail.Send                (Alerts versenden)

.EXAMPLE
    .\Test-HelpdeskMailboxBacklog.ps1 -MailboxUpn "helpdesk@domain.com" -AlertRecipients "it@domain.com" -DryRun $true
#>

param (
    [Parameter(Mandatory=$false)]
    [string]$MailboxUpn = "helpdesk@domain.com",

    [Parameter(Mandatory=$false)]
    [string]$SenderMailbox = "automation@domain.com",

    [Parameter(Mandatory=$false)]
    [string]$AlertRecipients = "it@domain.com",

    [Parameter(Mandatory=$false)]
    [int]$ThresholdMinutes = 5,

    [Parameter(Mandatory=$false)]
    [int]$MinMessageCount = 1,

    [Parameter(Mandatory=$false)]
    [string]$StateVariableName = "HelpdeskBacklogAlertActive",

    [Parameter(Mandatory=$false)]
    [bool]$DryRun = $true
)

$ErrorActionPreference = "Stop"

if ($DryRun) {
    Write-Output "=== DRY RUN – Es werden keine Mails versendet und kein Zustand gespeichert ==="
}

# ============================================================
# Hilfsfunktionen
# ============================================================

function Get-AllPages {
    param([string]$Uri)
    $allItems = @()
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop
        if ($response.value) { $allItems += @($response.value) }
        $Uri = $response.'@odata.nextLink'
    } while ($Uri)
    # Komma-Operator verhindert Pipeline-Enumeration (PS wuerde 1-Element-Arrays auspacken).
    # Aufrufer OHNE @() verwenden: $result = Get-AllPages ...
    return , $allItems
}

function Send-AlertMail {
    param(
        [string[]]$To,
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
                $To | ForEach-Object { @{ emailAddress = @{ address = $_ } } }
            )
        }
        saveToSentItems = $false
    } | ConvertTo-Json -Depth 10

    if ($DryRun) {
        Write-Output "  [DRYRUN] Mail wuerde gesendet an: $($To -join ', ')"
        Write-Output "  [DRYRUN] Betreff: $Subject"
        return
    }

    try {
        Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/users/$SenderMailbox/sendMail" `
            -Body $payload -ContentType "application/json" -ErrorAction Stop
        Write-Output "  ✓ Mail gesendet an: $($To -join ', ')"
    } catch {
        Write-Error "  Mail-Fehler an $($To -join ', ')`: $($_.Exception.Message)" -ErrorAction Continue
        if ($_.ErrorDetails.Message) {
            Write-Error "  Graph-Error (raw): $($_.ErrorDetails.Message)" -ErrorAction Continue
        }
        throw
    }
}

function ConvertTo-LocalTime {
    param([datetime]$UtcTime)
    $tz = [TimeZoneInfo]::FindSystemTimeZoneById("Europe/Berlin")
    return [TimeZoneInfo]::ConvertTimeFromUtc($UtcTime.ToUniversalTime(), $tz)
}

function Build-MessageTable {
    param([array]$Messages)
    $maxRows = 20
    $rows = foreach ($msg in ($Messages | Select-Object -First $maxRows)) {
        $received = ConvertTo-LocalTime -UtcTime ([datetime]$msg.receivedDateTime)
        $from     = [System.Net.WebUtility]::HtmlEncode("$($msg.from.emailAddress.address)")
        $subject  = [System.Net.WebUtility]::HtmlEncode("$($msg.subject)")
        "<tr><td>$($received.ToString('dd.MM.yyyy HH:mm'))</td><td>$from</td><td>$subject</td></tr>"
    }
    $more = if ($Messages.Count -gt $maxRows) {
        "<p>… und $($Messages.Count - $maxRows) weitere.</p>"
    } else { "" }

    return @"
<table border="1" cellpadding="4" cellspacing="0" style="border-collapse:collapse;font-family:Segoe UI,Arial;font-size:13px">
<tr style="background:#f0f0f0"><th>Eingang</th><th>Absender</th><th>Betreff</th></tr>
$($rows -join "`n")
</table>
$more
"@
}

# ============================================================
# Hauptlogik
# ============================================================

$recipients = @($AlertRecipients -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($recipients.Count -eq 0) {
    throw "AlertRecipients ist leer."
}
if ($recipients -contains $MailboxUpn) {
    Write-Warning "AlertRecipients enthaelt das ueberwachte Postfach $MailboxUpn – Alerts wuerden dort ebenfalls liegen bleiben."
}

Connect-MgGraph -Identity -NoWelcome

try {
    $nowUtc    = (Get-Date).ToUniversalTime()
    $cutoffUtc = $nowUtc.AddMinutes(-$ThresholdMinutes)
    $cutoffStr = $cutoffUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")

    Write-Output "Postfach    : $MailboxUpn"
    Write-Output "Schwelle    : >= $MinMessageCount Mails aelter als $ThresholdMinutes Min (vor $cutoffStr)"

    # Kein $orderby: in Kombination mit $filter drohen InefficientFilter-Fehler → client-seitig sortieren
    $uri = "https://graph.microsoft.com/v1.0/users/$MailboxUpn/mailFolders/inbox/messages" +
           "?`$filter=receivedDateTime lt $cutoffStr" +
           "&`$select=subject,from,receivedDateTime" +
           "&`$top=100"

    $stuck = Get-AllPages -Uri $uri
    $stuck = @($stuck | Sort-Object { [datetime]$_.receivedDateTime })

    Write-Output "Haengend    : $($stuck.Count)"

    $backlog = $stuck.Count -ge $MinMessageCount

    # Zustand der letzten Laeufe
    $alertActive = [bool](Get-AutomationVariable -Name $StateVariableName)
    Write-Output "Alert aktiv : $alertActive (vorheriger Lauf)"

    if ($backlog -and -not $alertActive) {
        $oldest   = ConvertTo-LocalTime -UtcTime ([datetime]$stuck[0].receivedDateTime)
        $ageMin   = [int]($nowUtc - ([datetime]$stuck[0].receivedDateTime).ToUniversalTime()).TotalMinutes
        Write-Output "→ Stoerung erkannt – sende Alert"

        $body = @"
<p><b>Der Ticketsystem-Crawler scheint nicht mehr zu laufen.</b></p>
<p>Im Posteingang von <b>$MailboxUpn</b> liegen <b>$($stuck.Count)</b> Mails, die aelter als $ThresholdMinutes Minuten sind.<br>
Aelteste Mail: $($oldest.ToString('dd.MM.yyyy HH:mm')) (vor ca. $ageMin Min).</p>
$(Build-MessageTable -Messages $stuck)
<p>Bitte den Mail-Abruf des Ticketsystems pruefen. Sobald der Posteingang wieder abgearbeitet ist, kommt eine Entwarnung.</p>
"@
        Send-AlertMail -To $recipients -Subject "⚠ Ticketsystem: $($stuck.Count) Mails haengen im Posteingang $MailboxUpn" -HtmlBody $body

        if (-not $DryRun) { Set-AutomationVariable -Name $StateVariableName -Value $true }
    }
    elseif (-not $backlog -and $alertActive) {
        Write-Output "→ Stoerung behoben – sende Entwarnung"

        $body = @"
<p><b>Entwarnung:</b> Der Posteingang von <b>$MailboxUpn</b> wird wieder abgearbeitet.</p>
<p>Aktuell liegen $($stuck.Count) Mails laenger als $ThresholdMinutes Minuten im Posteingang (Schwelle: $MinMessageCount).</p>
"@
        Send-AlertMail -To $recipients -Subject "✓ Ticketsystem: Posteingang $MailboxUpn wird wieder abgearbeitet" -HtmlBody $body

        if (-not $DryRun) { Set-AutomationVariable -Name $StateVariableName -Value $false }
    }
    elseif ($backlog) {
        Write-Output "→ Stoerung haelt an – Alert wurde bereits gesendet"
    }
    else {
        Write-Output "→ Alles ok"
    }
}
finally {
    Disconnect-MgGraph | Out-Null
}
