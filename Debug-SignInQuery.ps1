<#
.SYNOPSIS
    Debug-Script für Sign-in Log Abfragen – zeigt rohe API-Antworten

.DESCRIPTION
    Testet verschiedene Query-Varianten gegen die Graph API und zeigt
    die rohen Ergebnisse, damit wir sehen wo das Problem liegt.

.PARAMETER UserUPN
    UPN des Users, z.B. "helpdesk@servolift.de"

.PARAMETER LookbackHours
    Wie viele Stunden zurückschauen. Default: 48
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$UserUPN,

    [int]$LookbackHours = 48
)

# ==== Setup ====
try {
    Connect-MgGraph -Identity -NoWelcome -ErrorAction Stop
    Write-Output "=== Graph-Verbindung OK ==="
} catch {
    Write-Error "Verbindung fehlgeschlagen: $($_.Exception.Message)"
    throw
}

$since    = (Get-Date).ToUniversalTime().AddHours(-$LookbackHours)
$sinceStr = $since.ToString("yyyy-MM-ddTHH:mm:ssZ")
Write-Output "Zeitfenster: $sinceStr bis jetzt ($LookbackHours Stunden)"
Write-Output ""

# ==== User auflösen ====
Write-Output "=== SCHRITT 1: User auflösen ==="
try {
    $user = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/users/$UserUPN`?`$select=id,displayName,userPrincipalName,onPremisesSyncEnabled" `
        -ErrorAction Stop
    Write-Output "  displayName:           $($user.displayName)"
    Write-Output "  userPrincipalName:     $($user.userPrincipalName)"
    Write-Output "  id (objectId):         $($user.id)"
    Write-Output "  onPremisesSyncEnabled:  $($user.onPremisesSyncEnabled)"
    $userId = $user.id
} catch {
    Write-Error "User nicht gefunden: $($_.Exception.Message)"
    throw
}
Write-Output ""

# ==== Test 1: Direkt im Portal-Stil (ohne Filter auf errorCode) ====
Write-Output "=== TEST 1: Alle Sign-ins (kein errorCode-Filter) ==="
try {
    $uri1 = "https://graph.microsoft.com/v1.0/auditLogs/signIns?" +
            "`$filter=userId eq '$userId' and createdDateTime ge $sinceStr" +
            "&`$select=id,createdDateTime,status,appDisplayName,ipAddress,isInteractive" +
            "&`$orderby=createdDateTime desc" +
            "&`$top=10"
    Write-Output "  URI: $uri1"
    Write-Output ""
    $resp1 = Invoke-MgGraphRequest -Method GET -Uri $uri1 -ErrorAction Stop
    $count1 = if ($resp1.value) { $resp1.value.Count } else { 0 }
    Write-Output "  Ergebnis: $count1 Sign-in(s)"
    if ($resp1.value) {
        foreach ($s in $resp1.value) {
            $type = if ($s.isInteractive -eq $true) { "interactive" } else { "non-interactive" }
            Write-Output "  [$($s.createdDateTime)] errorCode=$($s.status.errorCode) | reason=$($s.status.failureReason) | app=$($s.appDisplayName) | $type"
        }
    }
} catch {
    Write-Error "  FEHLER: $($_.Exception.Message)"
}
Write-Output ""

# ==== Test 2: Mit errorCode ne 0 (OData-Filter) ====
Write-Output "=== TEST 2: OData-Filter status/errorCode ne 0 ==="
try {
    $uri2 = "https://graph.microsoft.com/v1.0/auditLogs/signIns?" +
            "`$filter=userId eq '$userId' and createdDateTime ge $sinceStr and status/errorCode ne 0" +
            "&`$select=id,createdDateTime,status,appDisplayName,ipAddress,isInteractive" +
            "&`$orderby=createdDateTime desc" +
            "&`$top=10"
    Write-Output "  URI: $uri2"
    Write-Output ""
    $resp2 = Invoke-MgGraphRequest -Method GET -Uri $uri2 -ErrorAction Stop
    $count2 = if ($resp2.value) { $resp2.value.Count } else { 0 }
    Write-Output "  Ergebnis: $count2 Sign-in(s)"
    if ($resp2.value) {
        foreach ($s in $resp2.value) {
            Write-Output "  [$($s.createdDateTime)] errorCode=$($s.status.errorCode) | reason=$($s.status.failureReason) | app=$($s.appDisplayName)"
        }
    }
} catch {
    Write-Error "  FEHLER: $($_.Exception.Message)"
}
Write-Output ""

# ==== Test 3: Mit userPrincipalName statt userId ====
Write-Output "=== TEST 3: Filter mit userPrincipalName statt userId ==="
try {
    $uri3 = "https://graph.microsoft.com/v1.0/auditLogs/signIns?" +
            "`$filter=userPrincipalName eq '$UserUPN' and createdDateTime ge $sinceStr" +
            "&`$select=id,createdDateTime,status,appDisplayName,ipAddress,isInteractive,userId,userPrincipalName" +
            "&`$orderby=createdDateTime desc" +
            "&`$top=10"
    Write-Output "  URI: $uri3"
    Write-Output ""
    $resp3 = Invoke-MgGraphRequest -Method GET -Uri $uri3 -ErrorAction Stop
    $count3 = if ($resp3.value) { $resp3.value.Count } else { 0 }
    Write-Output "  Ergebnis: $count3 Sign-in(s)"
    if ($resp3.value) {
        foreach ($s in $resp3.value) {
            $type = if ($s.isInteractive -eq $true) { "interactive" } else { "non-interactive" }
            Write-Output "  [$($s.createdDateTime)] errorCode=$($s.status.errorCode) | reason=$($s.status.failureReason) | app=$($s.appDisplayName) | userId=$($s.userId) | $type"
        }
    }
} catch {
    Write-Error "  FEHLER: $($_.Exception.Message)"
}
Write-Output ""

# ==== Test 4: Beta-Endpoint ====
Write-Output "=== TEST 4: Beta-Endpoint (gleicher Filter wie Test 1) ==="
try {
    $uri4 = "https://graph.microsoft.com/beta/auditLogs/signIns?" +
            "`$filter=userId eq '$userId' and createdDateTime ge $sinceStr" +
            "&`$select=id,createdDateTime,status,appDisplayName,ipAddress,isInteractive" +
            "&`$orderby=createdDateTime desc" +
            "&`$top=10"
    Write-Output "  URI: $uri4"
    Write-Output ""
    $resp4 = Invoke-MgGraphRequest -Method GET -Uri $uri4 -ErrorAction Stop
    $count4 = if ($resp4.value) { $resp4.value.Count } else { 0 }
    Write-Output "  Ergebnis: $count4 Sign-in(s)"
    if ($resp4.value) {
        foreach ($s in $resp4.value) {
            $type = if ($s.isInteractive -eq $true) { "interactive" } else { "non-interactive" }
            Write-Output "  [$($s.createdDateTime)] errorCode=$($s.status.errorCode) | reason=$($s.status.failureReason) | app=$($s.appDisplayName) | $type"
        }
    }
} catch {
    Write-Error "  FEHLER: $($_.Exception.Message)"
}
Write-Output ""

# ==== Test 5: v1.0 signIns mit signInEventTypes (non-interactive explizit) ====
Write-Output "=== TEST 5: v1.0 mit signInEventTypes filter ==="
try {
    $uri5a = "https://graph.microsoft.com/v1.0/auditLogs/signIns?" +
            "`$filter=userId eq '$userId' and createdDateTime ge $sinceStr and signInEventTypes/any(t: t eq 'nonInteractiveUser')" +
            "&`$select=id,createdDateTime,status,appDisplayName,ipAddress,isInteractive,signInEventTypes" +
            "&`$orderby=createdDateTime desc" +
            "&`$top=10"
    Write-Output "  URI: $uri5a"
    Write-Output ""
    $resp5a = Invoke-MgGraphRequest -Method GET -Uri $uri5a -ErrorAction Stop
    $count5a = if ($resp5a.value) { $resp5a.value.Count } else { 0 }
    Write-Output "  Ergebnis: $count5a Sign-in(s)"
    if ($resp5a.value) {
        foreach ($s in $resp5a.value) {
            Write-Output "  [$($s.createdDateTime)] errorCode=$($s.status.errorCode) | reason=$($s.status.failureReason) | app=$($s.appDisplayName) | types=$($s.signInEventTypes -join ',')"
        }
    }
} catch {
    Write-Error "  FEHLER: $($_.Exception.Message)"
}
Write-Output ""

# ==== Test 6: v1.0 signIns mit interactiveUser ====
Write-Output "=== TEST 6: v1.0 mit signInEventTypes interactiveUser ==="
try {
    $uri5b = "https://graph.microsoft.com/v1.0/auditLogs/signIns?" +
            "`$filter=userId eq '$userId' and createdDateTime ge $sinceStr and signInEventTypes/any(t: t eq 'interactiveUser')" +
            "&`$select=id,createdDateTime,status,appDisplayName,ipAddress,isInteractive,signInEventTypes" +
            "&`$orderby=createdDateTime desc" +
            "&`$top=10"
    Write-Output "  URI: $uri5b"
    Write-Output ""
    $resp5b = Invoke-MgGraphRequest -Method GET -Uri $uri5b -ErrorAction Stop
    $count5b = if ($resp5b.value) { $resp5b.value.Count } else { 0 }
    Write-Output "  Ergebnis: $count5b Sign-in(s)"
    if ($resp5b.value) {
        foreach ($s in $resp5b.value) {
            Write-Output "  [$($s.createdDateTime)] errorCode=$($s.status.errorCode) | reason=$($s.status.failureReason) | app=$($s.appDisplayName) | types=$($s.signInEventTypes -join ',')"
        }
    }
} catch {
    Write-Error "  FEHLER: $($_.Exception.Message)"
}
Write-Output ""

# ==== Test 7: Rohes JSON der ersten Antwort (Test 1) für Detailanalyse ====
Write-Output "=== TEST 7: Rohes erstes Sign-in Objekt (aus Test 1) ==="
if ($resp1.value -and $resp1.value.Count -gt 0) {
    $raw = $resp1.value[0]
    Write-Output ($raw | ConvertTo-Json -Depth 5)
} else {
    Write-Output "  Keine Daten aus Test 1 vorhanden"
}
Write-Output ""

# ==== Test 8: Vergleich userId aus Gruppe vs. aus Sign-in Log ====
Write-Output "=== TEST 8: userId-Vergleich ==="
Write-Output "  userId aus User-Objekt:  $userId"
if ($resp3.value -and $resp3.value.Count -gt 0) {
    $logUserId = $resp3.value[0].userId
    Write-Output "  userId aus Sign-in Log:  $logUserId"
    if ($userId -eq $logUserId) {
        Write-Output "  => MATCH"
    } else {
        Write-Output "  => MISMATCH! Das ist das Problem."
    }
} else {
    Write-Output "  Kein Sign-in Log per UPN gefunden – kann nicht vergleichen"
}
Write-Output ""

# ==== Zusammenfassung ====
Write-Output "=== ZUSAMMENFASSUNG ==="
Write-Output "  Test 1 (alle, userId, v1.0):              $count1 Sign-in(s)"
Write-Output "  Test 2 (errorCode ne 0, userId):           $count2 Sign-in(s)"
Write-Output "  Test 3 (alle, userPrincipalName):          $count3 Sign-in(s)"
Write-Output "  Test 4 (alle, userId, beta):               $count4 Sign-in(s)"
Write-Output "  Test 5 (nonInteractiveUser, v1.0):         $count5a Sign-in(s)"
Write-Output "  Test 6 (interactiveUser, v1.0):            $count5b Sign-in(s)"
Write-Output ""
if ($count1 -eq 0 -and $count3 -gt 0) {
    Write-Output "  => DIAGNOSE: userId-Filter liefert nichts, UPN-Filter schon."
    Write-Output "     Wahrscheinlich: userId im Sign-in Log weicht von User-Objekt ab (on-prem sync?)."
} elseif ($count1 -gt 0 -and $count2 -eq 0) {
    Write-Output "  => DIAGNOSE: Sign-ins vorhanden, aber errorCode ne 0 liefert nichts."
    Write-Output "     Die Failures haben errorCode=0 mit failureReason (z.B. CA-Block, Interrupted)."
    Write-Output "     Fix: Client-seitig auf failureReason filtern statt errorCode."
} elseif ($count5a -gt $count1 -or $count5b -gt $count1) {
    Write-Output "  => DIAGNOSE: signInEventTypes-Filter liefert mehr als Standard-Query."
    Write-Output "     v1.0 ohne signInEventTypes gibt nur interactiveUser zurueck!"
    Write-Output "     Fix: signInEventTypes/any(t: t eq 'nonInteractiveUser') im Filter verwenden."
} elseif ($count1 -eq 0 -and $count3 -eq 0 -and $count4 -gt 0) {
    Write-Output "  => DIAGNOSE: Nur Beta-Endpoint liefert Ergebnisse."
    Write-Output "     Sign-in Typ ist in v1.0 nicht enthalten."
} elseif ($count1 -eq 0 -and $count3 -eq 0 -and $count4 -eq 0) {
    Write-Output "  => DIAGNOSE: Kein Endpoint liefert Ergebnisse."
    Write-Output "     Moeglich: AuditLog.Read.All Permission fehlt, oder Logs noch nicht propagiert (bis 2h Delay)."
} else {
    Write-Output "  => Kein eindeutiges Muster. Rohdaten oben pruefen."
}

Disconnect-MgGraph | Out-Null
Write-Output ""
Write-Output "=== Debug abgeschlossen ==="
