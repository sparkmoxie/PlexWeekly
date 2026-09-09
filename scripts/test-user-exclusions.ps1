[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$windowsLibrary = Join-Path $root 'platforms/windows/User-Exclusions.ps1'
. $windowsLibrary

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected
    )

    if ([string]$Actual -ne [string]$Expected) {
        throw "$Name expected '$Expected' but received '$Actual'."
    }
    Write-Host "[PASS] $Name"
}

$users = @(
    [PSCustomObject]@{ UserId = '10'; FriendlyName = 'Alpha'; Username = 'alpha'; Email = 'alpha@example.com'; Eligible = $true },
    [PSCustomObject]@{ UserId = '20'; FriendlyName = 'Beta'; Username = 'beta'; Email = 'beta@example.com'; Eligible = $true },
    [PSCustomObject]@{ UserId = '30'; FriendlyName = 'Gamma'; Username = 'gamma'; Email = ''; Eligible = $false }
)

$keep = ConvertFrom-TautWeeklyExcludedSelection -Selection '' -Users $users -CurrentExcludedUserIds @('20', 'legacy')
Assert-Equal -Name 'Blank selection keeps current IDs' -Actual (@($keep.UserIds) -join ',') -Expected '20,legacy'

$clear = ConvertFrom-TautWeeklyExcludedSelection -Selection 'none' -Users $users -CurrentExcludedUserIds @('20', 'legacy')
Assert-Equal -Name 'none clears all IDs' -Actual (@($clear.UserIds) -join ',') -Expected ''

$replace = ConvertFrom-TautWeeklyExcludedSelection -Selection '1,3' -Users $users -CurrentExcludedUserIds @('20', 'legacy')
Assert-Equal -Name 'Rows replace known IDs and preserve unavailable IDs' -Actual (@($replace.UserIds) -join ',') -Expected 'legacy,10,30'

$range = ConvertFrom-TautWeeklyExcludedSelection -Selection '1-2,2' -Users $users
Assert-Equal -Name 'Ranges and duplicate rows are normalized' -Actual (@($range.UserIds) -join ',') -Expected '10,20'

$invalid = ConvertFrom-TautWeeklyExcludedSelection -Selection '0' -Users $users
Assert-Equal -Name 'Out-of-range rows are rejected' -Actual ([bool]$invalid.Valid) -Expected $false

$nameRows = @(
    [PSCustomObject]@{ user_id = '7'; friendly_name = 'Server Owner' },
    [PSCustomObject]@{ user_id = '145330906'; friendly_name = 'Remote Viewer' },
    [PSCustomObject]@{ user_id = '42'; friendly_name = 'Local' },
    [PSCustomObject]@{ user_id = '0'; friendly_name = 'Local' }
)
$detailRows = @(
    [PSCustomObject]@{
        user_id = '7'; username = 'owner'; email = 'owner@example.com'
        is_active = 1; do_notify = 0
    },
    [PSCustomObject]@{
        user_id = '42'; username = 'local-profile'; email = 'local-profile@example.com'
        is_active = 1; do_notify = 1
    },
    [PSCustomObject]@{
        user_id = 0; username = 'Local'; email = 'reserved@example.com'
        is_active = 1; do_notify = 1
    }
)
$mergedUsers = @(ConvertTo-TautWeeklySelectableUsers -Names $nameRows -DetailedUsers $detailRows)
Assert-Equal -Name 'Bulk and name rosters are merged by stable ID without Local user zero' -Actual $mergedUsers.Count -Expected 3
$owner = $mergedUsers | Where-Object UserId -eq '7' | Select-Object -First 1
$viewer = $mergedUsers | Where-Object UserId -eq '145330906' | Select-Object -First 1
Assert-Equal -Name 'Name roster supplies missing friendly name' -Actual $owner.FriendlyName -Expected 'Server Owner'
Assert-Equal -Name 'Legacy Tautulli notification state does not suppress delivery eligibility' -Actual ([bool]$owner.Eligible) -Expected $true
Assert-Equal -Name 'Name-only user remains selectable' -Actual $viewer.FriendlyName -Expected 'Remote Viewer'
Assert-Equal -Name 'Name-only user is not marked delivery-eligible' -Actual ([bool]$viewer.Eligible) -Expected $false
Assert-Equal -Name 'Name-only user reports unavailable details' -Actual ([bool]$viewer.DetailsAvailable) -Expected $false
$namedLocal = $mergedUsers | Where-Object UserId -eq '42' | Select-Object -First 1
Assert-Equal -Name 'A real profile named Local remains selectable and eligible' -Actual ($namedLocal.FriendlyName -eq 'Local' -and $namedLocal.Eligible) -Expected $true
foreach ($localId in @(0, '0', '000')) {
    $localRow = [PSCustomObject]@{ user_id = $localId; friendly_name = 'Renamed reserved user'; username = 'Local'; email = 'reserved@example.com'; is_active = 1; do_notify = 1 }
    $localOnly = @(ConvertTo-TautWeeklySelectableUsers -Names @($localRow) -DetailedUsers @($localRow))
    Assert-Equal -Name "Reserved numeric/string zero '$localId' never becomes selectable even with email" -Actual $localOnly.Count -Expected 0
}

$script:userApiCalls = New-Object System.Collections.Generic.List[string]
function Invoke-TautWeeklyUserApi {
    param(
        [string]$TautulliUrl,
        [string]$ApiKey,
        [string]$Command,
        [hashtable]$Parameters = @{}
    )
    $script:userApiCalls.Add($Command)
    if ($Command -eq 'get_user_names') { return $nameRows }
    if ($Command -eq 'get_users') { return $detailRows }
    throw "Unexpected user API command: $Command"
}
$apiUsers = @(Get-TautWeeklySelectableUsers -TautulliUrl 'http://tautulli.example.test:8181' -ApiKey 'test-key')
Assert-Equal -Name 'Roster uses two bulk API calls' -Actual ($script:userApiCalls -join ',') -Expected 'get_user_names,get_users'
Assert-Equal -Name 'Bulk API roster remains selectable without reserved Local' -Actual $apiUsers.Count -Expected 3

function Invoke-TautWeeklyUserApi {
    param(
        [string]$TautulliUrl,
        [string]$ApiKey,
        [string]$Command,
        [hashtable]$Parameters = @{}
    )
    if ($Command -eq 'get_user_names') { return $nameRows }
    throw 'Simulated get_users rejection'
}
$fallbackUsers = @(Get-TautWeeklySelectableUsers -TautulliUrl 'http://tautulli.example.test:8181' -ApiKey 'test-key')
Assert-Equal -Name 'Names remain selectable when details fail without reserved Local' -Actual $fallbackUsers.Count -Expected 3
Assert-Equal -Name 'Fallback keeps only real stable user IDs' -Actual (($fallbackUsers.UserId | Sort-Object) -join ',') -Expected '145330906,42,7'

$libraryPaths = @(
    $windowsLibrary,
    (Join-Path $root 'platforms/nas-docker/app/User-Exclusions.ps1'),
    (Join-Path $root 'platforms/mac-docker/app/User-Exclusions.ps1')
)
$managerPaths = @(
    (Join-Path $root 'platforms/windows/Manage-User-Exclusions.ps1'),
    (Join-Path $root 'platforms/nas-docker/app/Manage-User-Exclusions.ps1'),
    (Join-Path $root 'platforms/mac-docker/app/Manage-User-Exclusions.ps1')
)

foreach ($group in @($libraryPaths, $managerPaths)) {
    $canonical = ((Get-Content -LiteralPath $group[0] -Raw -Encoding UTF8) -replace "`r`n", "`n").TrimEnd()
    foreach ($path in $group | Select-Object -Skip 1) {
        $candidate = ((Get-Content -LiteralPath $path -Raw -Encoding UTF8) -replace "`r`n", "`n").TrimEnd()
        Assert-Equal -Name "Cross-platform copy matches $([IO.Path]::GetFileName($group[0]))" -Actual $candidate -Expected $canonical
    }
}

Write-Host '[PASS] User-exclusion selection behavior is valid.'
