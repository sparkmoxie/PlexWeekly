function Invoke-TautWeeklyUserApi {
    param(
        [Parameter(Mandatory = $true)][string]$TautulliUrl,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [Parameter(Mandatory = $true)][string]$Command,
        [hashtable]$Parameters = @{}
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("apikey={0}" -f [Uri]::EscapeDataString($ApiKey))
    $parts.Add("cmd={0}" -f [Uri]::EscapeDataString($Command))
    foreach ($entry in $Parameters.GetEnumerator()) {
        $parts.Add("{0}={1}" -f [Uri]::EscapeDataString([string]$entry.Key), [Uri]::EscapeDataString([string]$entry.Value))
    }

    $uri = "{0}/api/v2?{1}" -f $TautulliUrl.TrimEnd('/'), ($parts -join '&')
    try {
        $raw = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 20
    }
    catch {
        throw "Could not query Tautulli users. Check the Tautulli URL, API key, and network access."
    }

    if ($null -eq $raw -or $null -eq $raw.PSObject.Properties['response']) {
        throw "Tautulli returned an unexpected response while loading users."
    }
    if ([string]$raw.response.result -ne 'success') {
        throw "Tautulli rejected the user lookup request. Check the API key and Tautulli permissions."
    }

    return $raw.response.data
}

function Get-TautWeeklyObjectValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function ConvertTo-TautWeeklySelectableUsers {
    param(
        [AllowNull()][object[]]$Names = @(),
        [AllowNull()][object[]]$DetailedUsers = @()
    )

    $detailsById = @{}
    $friendlyById = @{}
    $ids = New-Object System.Collections.Generic.List[string]
    $seenIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($user in @($DetailedUsers)) {
        $userId = [string](Get-TautWeeklyObjectValue -InputObject $user -Name 'user_id' -Default '')
        if ([string]::IsNullOrWhiteSpace($userId)) { continue }
        $userId = $userId.Trim()
        if ($userId -match '^0+$') { continue }
        if (-not $detailsById.ContainsKey($userId)) { $detailsById[$userId] = $user }
        if ($seenIds.Add($userId)) { $ids.Add($userId) }
    }

    foreach ($name in @($Names)) {
        $userId = [string](Get-TautWeeklyObjectValue -InputObject $name -Name 'user_id' -Default '')
        if ([string]::IsNullOrWhiteSpace($userId)) { continue }
        $userId = $userId.Trim()
        if ($userId -match '^0+$') { continue }
        $friendly = [string](Get-TautWeeklyObjectValue -InputObject $name -Name 'friendly_name' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($friendly)) { $friendlyById[$userId] = $friendly }
        if ($seenIds.Add($userId)) { $ids.Add($userId) }
    }

    $users = New-Object System.Collections.Generic.List[object]
    foreach ($userId in $ids) {
        $detail = if ($detailsById.ContainsKey($userId)) { $detailsById[$userId] } else { $null }
        $username = [string](Get-TautWeeklyObjectValue -InputObject $detail -Name 'username' -Default '')
        $friendlyName = [string](Get-TautWeeklyObjectValue -InputObject $detail -Name 'friendly_name' -Default '')
        if ([string]::IsNullOrWhiteSpace($friendlyName) -and $friendlyById.ContainsKey($userId)) {
            $friendlyName = [string]$friendlyById[$userId]
        }
        if ([string]::IsNullOrWhiteSpace($friendlyName)) { $friendlyName = $username }
        if ([string]::IsNullOrWhiteSpace($friendlyName)) { $friendlyName = "User $userId" }

        $email = [string](Get-TautWeeklyObjectValue -InputObject $detail -Name 'email' -Default '')
        $isActive = [int](Get-TautWeeklyObjectValue -InputObject $detail -Name 'is_active' -Default 0)
        $eligible = $isActive -gt 0 -and -not [string]::IsNullOrWhiteSpace($email)

        $users.Add([PSCustomObject]@{
            UserId = $userId
            FriendlyName = $friendlyName
            Username = $username
            Email = $email
            Eligible = $eligible
            DetailsAvailable = ($null -ne $detail)
        })
    }

    return @($users | Sort-Object FriendlyName, Username, UserId)
}

function Get-TautWeeklySelectableUsers {
    param(
        [Parameter(Mandatory = $true)][string]$TautulliUrl,
        [Parameter(Mandatory = $true)][string]$ApiKey
    )

    $names = @()
    $detailedUsers = @()
    $namesError = ''
    $detailsError = ''

    try {
        $names = @(Invoke-TautWeeklyUserApi -TautulliUrl $TautulliUrl -ApiKey $ApiKey -Command 'get_user_names')
    }
    catch {
        $namesError = [string]$_.Exception.Message
    }

    try {
        $detailedUsers = @(Invoke-TautWeeklyUserApi -TautulliUrl $TautulliUrl -ApiKey $ApiKey -Command 'get_users')
    }
    catch {
        $detailsError = [string]$_.Exception.Message
    }

    if (-not [string]::IsNullOrWhiteSpace($namesError) -and
        -not [string]::IsNullOrWhiteSpace($detailsError)) {
        throw 'Could not load the Tautulli user roster. Check the Tautulli URL, API key, API access, and network connection.'
    }
    if (-not [string]::IsNullOrWhiteSpace($namesError)) {
        Write-Warning 'Tautulli user names were unavailable; using the detailed bulk user list.'
    }
    if (-not [string]::IsNullOrWhiteSpace($detailsError)) {
        Write-Warning 'Detailed Tautulli users were unavailable; users remain selectable by friendly name and stable ID, but delivery eligibility cannot be shown.'
    }

    return @(ConvertTo-TautWeeklySelectableUsers -Names $names -DetailedUsers $detailedUsers)
}

function Get-TautWeeklyUniqueIds {
    param([AllowNull()][object[]]$Values = @())

    $result = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in @($Values)) {
        $id = [string]$value
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $id = $id.Trim()
        if ($seen.Add($id)) { $result.Add($id) }
    }
    return @($result)
}

function ConvertFrom-TautWeeklyExcludedSelection {
    param(
        [AllowNull()][string]$Selection,
        [Parameter(Mandatory = $true)][object[]]$Users,
        [AllowNull()][object[]]$CurrentExcludedUserIds = @()
    )

    $current = @(Get-TautWeeklyUniqueIds -Values $CurrentExcludedUserIds)
    $raw = if ($null -eq $Selection) { '' } else { $Selection.Trim() }

    if ([string]::IsNullOrWhiteSpace($raw) -or $raw -ieq 'keep') {
        return [PSCustomObject]@{ Valid = $true; Message = ''; UserIds = @($current) }
    }
    if ($raw -ieq 'none') {
        return [PSCustomObject]@{ Valid = $true; Message = ''; UserIds = @() }
    }

    $selectedRows = New-Object System.Collections.Generic.List[int]
    $selectedSet = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($tokenValue in @($raw -split ',')) {
        $token = ([string]$tokenValue).Trim()
        if ($token -match '^([0-9]+)-([0-9]+)$') {
            $first = [int]$Matches[1]
            $last = [int]$Matches[2]
            if ($first -lt 1 -or $last -gt $Users.Count -or $first -gt $last) {
                return [PSCustomObject]@{ Valid = $false; Message = "Row range '$token' is outside 1-$($Users.Count)."; UserIds = @() }
            }
            foreach ($row in $first..$last) {
                if ($selectedSet.Add($row)) { $selectedRows.Add($row) }
            }
            continue
        }
        if ($token -notmatch '^[0-9]+$') {
            return [PSCustomObject]@{ Valid = $false; Message = "'$token' is not a row number or range."; UserIds = @() }
        }

        $rowNumber = [int]$token
        if ($rowNumber -lt 1 -or $rowNumber -gt $Users.Count) {
            return [PSCustomObject]@{ Valid = $false; Message = "Row '$token' is outside 1-$($Users.Count)."; UserIds = @() }
        }
        if ($selectedSet.Add($rowNumber)) { $selectedRows.Add($rowNumber) }
    }

    $knownIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($user in $Users) { [void]$knownIds.Add([string]$user.UserId) }

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($id in $current) {
        if (-not $knownIds.Contains($id)) { $result.Add($id) }
    }
    foreach ($row in $selectedRows) {
        $result.Add([string]$Users[$row - 1].UserId)
    }

    return [PSCustomObject]@{
        Valid = $true
        Message = ''
        UserIds = @(Get-TautWeeklyUniqueIds -Values $result)
    }
}

function Read-TautWeeklyExcludedUserIds {
    param(
        [Parameter(Mandatory = $true)][object[]]$Users,
        [AllowNull()][object[]]$CurrentExcludedUserIds = @()
    )

    $current = @(Get-TautWeeklyUniqueIds -Values $CurrentExcludedUserIds)
    $currentSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $current) { [void]$currentSet.Add($id) }

    Write-Host ''
    Write-Host 'Newsletter user exclusions' -ForegroundColor Cyan
    Write-Host 'Saved exclusions block personalized preview, TestEmail, welcome, and SendAll modes.'
    Write-Host 'Included users without a production address can still be previewed or tested safely.'
    Write-Host ''
    Write-Host ('{0,-4} {1,-10} {2,-9} {3,-24} {4,-20} {5}' -f '#', 'Status', 'Delivery', 'Friendly name', 'User ID', 'Email')
    Write-Host ('{0,-4} {1,-10} {2,-9} {3,-24} {4,-20} {5}' -f '--', '----------', '---------', '------------------------', '--------------------', '-----')
    for ($index = 0; $index -lt $Users.Count; $index++) {
        $user = $Users[$index]
        $status = if ($currentSet.Contains([string]$user.UserId)) { 'EXCLUDED' } else { 'included' }
        $delivery = if ([bool]$user.Eligible) { 'eligible' } else { 'skipped*' }
        $email = if ([string]::IsNullOrWhiteSpace([string]$user.Email)) { '(no email)' } else { [string]$user.Email }
        Write-Host ('{0,-4} {1,-10} {2,-9} {3,-24} {4,-20} {5}' -f ($index + 1), $status, $delivery, [string]$user.FriendlyName, [string]$user.UserId, $email)
    }
    Write-Host ''
    Write-Host '* Inactive users and users without email are already skipped. Tautulli notification-agent settings do not control TautWeekly delivery.' -ForegroundColor DarkGray
    Write-Host 'Enter the rows to exclude, for example 2,4-6. This replaces the known-user selection.'
    Write-Host "Press Enter (or type 'keep') to keep it unchanged; type 'none' to clear every exclusion."

    while ($true) {
        $selection = Read-Host 'Rows to exclude'
        $parsed = ConvertFrom-TautWeeklyExcludedSelection -Selection $selection -Users $Users -CurrentExcludedUserIds $current
        if ([bool]$parsed.Valid) { return @($parsed.UserIds) }
        Write-Host ([string]$parsed.Message) -ForegroundColor Yellow
    }
}
