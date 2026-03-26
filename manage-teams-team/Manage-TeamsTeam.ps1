<# Modules Requires 
    Microsoft.Graph
    Microsoft.Graph.Authentication
    Microsoft.Graph.Groups
    Microsoft.Graph.Users

Permissions Requires
    TeamSettings.ReadWrite.All
#>
<#
.SYNOPSIS
    Beschreibt das Skript und seine Funktion.

.DESCRIPTION
    Dieses Skript fügt Mitglieder einer Entra-Gruppe zu einer Teams-Gruppe hinzu und entfernt Mitglieder, die nicht mehr in der Entra-Gruppe sind.

.PARAMETER EntraGroupNames
    Namen der Entra-Quellgruppen (eine oder mehrere). Mitglieder aller Gruppen werden vereinigt.

.PARAMETER TeamsGroupName
    Name der Ziel-Teams-Gruppe. 

.PARAMETER AutomationUserName
    UPN des Automation-Service-Accounts, der bei Änderungen ignoriert wird. 

.PARAMETER DryRun
    Wenn gesetzt, werden keine Änderungen vorgenommen. Es wird nur angezeigt, welche Mitglieder hinzugefügt oder entfernt werden würden.

.EXAMPLE
    .\Manage-TeamsTeam.ps1 -EntraGroupNames "Gruppe-A","Gruppe-B" -TeamsGroupName "Team Homeoffice" -DryRun
    Zeigt an, welche Änderungen vorgenommen werden würden, ohne diese tatsächlich durchzuführen.

#>

param (
    [Parameter(Mandatory=$false)]
    [string]$EntraGroupNames,

    [Parameter(Mandatory=$false)]
    [string]$TeamsGroupName,

    [Parameter(Mandatory=$false)]
    [string]$AutomationUserName,

    [Parameter(Mandatory=$false)]
    [bool]$DryRun = $true
)

# Azure Automation uebergibt Arrays als Komma-separierten String
$groupNameList = @($EntraGroupNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if ($DryRun) {
    Write-Output "=== DRY RUN – Es werden keine Änderungen vorgenommen ==="
}

# Anmelden bei Microsoft Graph mit Managed Identity
Connect-MgGraph -Identity

# Teams Team abrufen
$teamsGroup = Get-MgGroup -Filter "displayName eq '$TeamsGroupName'"

# Automation User abrufen
$automationUser = Get-MgUser -Filter "UserPrincipalName eq '$AutomationUserName'"

# Mitglieder aller Entra-Gruppen sammeln (Vereinigung)
$entraGroupMemberIds = @()
foreach ($groupName in $groupNameList) {
    $entraGroup = Get-MgGroup -Filter "displayName eq '$groupName'"
    if (-not $entraGroup) {
        Write-Warning "Entra-Gruppe '$groupName' nicht gefunden – überspringe."
        continue
    }
    Write-Output "Lese Mitglieder aus Entra-Gruppe: $groupName"
    $members = Get-MgGroupMember -GroupId $entraGroup.Id -All
    if ($members) {
        $entraGroupMemberIds += @($members.Id)
    }
}
$entraGroupMemberIds = @($entraGroupMemberIds | Select-Object -Unique)

# Hole die Mitglieder der Teams-Gruppe
$teamsGroupMembers = Get-MgGroupMember -GroupId $teamsGroup.Id -All
if ($teamsGroupMembers) {
    $teamsGroupMemberIds = @($teamsGroupMembers.Id)
} else {
    $teamsGroupMemberIds = @()
}

# Füge Mitglieder zur Teams-Gruppe hinzu, die in der Entra-Gruppe sind, aber nicht in der Teams-Gruppe
foreach ($memberId in $entraGroupMemberIds) {
    if (-not $teamsGroupMemberIds.Contains($memberId) -and $memberId -ne $automationUser.Id) {
        $user = Get-MgUser -UserId $memberId -Property "DisplayName,UserPrincipalName" -ErrorAction SilentlyContinue
        $label = if ($user) { "$($user.DisplayName) ($($user.UserPrincipalName))" } else { $memberId }
        if ($DryRun) {
            Write-Output "[DRY RUN] Würde hinzufügen: $label"
        } else {
            New-MgGroupMember -GroupId $teamsGroup.Id -DirectoryObjectId $memberId
            Write-Output "Hinzugefügt: $label"
        }
    }
}

# Entferne Mitglieder aus der Teams-Gruppe, die nicht mehr in der Entra-Gruppe sind
foreach ($memberId in $teamsGroupMemberIds) {
    if (-not $entraGroupMemberIds.Contains($memberId) -and $memberId -ne $automationUser.Id) {
        $user = Get-MgUser -UserId $memberId -Property "DisplayName,UserPrincipalName" -ErrorAction SilentlyContinue
        $label = if ($user) { "$($user.DisplayName) ($($user.UserPrincipalName))" } else { $memberId }
        if ($DryRun) {
            Write-Output "[DRY RUN] Würde entfernen: $label"
        } else {
            Remove-MgGroupMemberByRef -GroupId $teamsGroup.Id -DirectoryObjectId $memberId
            Write-Output "Entfernt: $label"
        }
    }
}

# Abmelden von Microsoft Graph
Disconnect-MgGraph