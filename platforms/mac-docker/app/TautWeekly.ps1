param(
    [ValidateSet("ListUsers","VerifyPlex","Preview","PreviewAll","CacheWarm","SendTest","SendTestAll","SendWelcome","SendAll")]
    [string]$Mode = "ListUsers",

    [string]$UserId = "",

    [string]$ConfigPath = $(if (-not [string]::IsNullOrWhiteSpace([string]$env:TAUTWEEKLY_CONFIG)) { [string]$env:TAUTWEEKLY_CONFIG } else { "/data/config.json" }),

    [switch]$NoOpen,

    [string]$ResultPath = "",

    [switch]$ConfirmSendAll,

    [switch]$ConfirmWelcome
)

# TautWeekly for Plex Mac Portable v1.4.0 - Docker Desktop production newsletter engine.
# Uses the current six-state portable production renderer with regression
# previews, latest TV episode backfill, IMDb enrichment, and RT audience %.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion -lt [Version]"7.2") {
    throw "TautWeekly for Plex Mac Portable requires PowerShell 7.2 or newer. Found $($PSVersionTable.PSVersion)."
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:TautWeeklyResultStartedAtUtc = [DateTime]::UtcNow
$script:TautWeeklyResultWritten = $false
$script:TautWeeklyResultWriting = $false
$script:TautWeeklyResultSmtpAcceptedCount = 0
$script:TautWeeklyResultSkippedCount = 0
$script:TautWeeklyResultFailedCount = 0
$script:TautWeeklyResultSmtpFailure = $null
$script:TautWeeklyResultSkipReasons = [ordered]@{
    inactiveOrDeleted = 0
    missingEmail       = 0
    excludedUserId     = 0
    excludedEmail      = 0
}
$script:TautWeeklyResultErrorCategory = "renderer-failed"
$script:TautWeeklyResultGeneratedPreviewFiles = New-Object System.Collections.Generic.List[string]
$script:TautWeeklyResultDeliveryScope = switch ($Mode) {
    "SendTest" { "test" }
    "SendTestAll" { "test" }
    "SendWelcome" { "welcome" }
    "SendAll" { "production" }
    default { "none" }
}

function Write-TautWeeklyStructuredResult {
    param(
        [ValidateSet("succeeded","partial","failed")]
        [string]$Outcome
    )

    if (Get-Command Write-TautWeeklyDeletedItemCacheActivitySummary -ErrorAction SilentlyContinue) {
        Write-TautWeeklyDeletedItemCacheActivitySummary
    }

    if ([string]::IsNullOrWhiteSpace($ResultPath) -or
        $script:TautWeeklyResultWritten -or
        $script:TautWeeklyResultWriting) {
        return
    }

    $script:TautWeeklyResultWriting = $true
    $temporaryPath = ""
    try {
        $resolvedResultPath = [IO.Path]::GetFullPath($ResultPath)
        $resultDirectory = [IO.Path]::GetDirectoryName($resolvedResultPath)
        if ([string]::IsNullOrWhiteSpace($resultDirectory)) {
            throw "Structured result directory is unavailable."
        }
        [IO.Directory]::CreateDirectory($resultDirectory) | Out-Null
        $finishedAtUtc = [DateTime]::UtcNow
        $durationMs = [Math]::Max(0, [int64]($finishedAtUtc - $script:TautWeeklyResultStartedAtUtc).TotalMilliseconds)
        $safePreviewFiles = @(
            $script:TautWeeklyResultGeneratedPreviewFiles |
                ForEach-Object { [IO.Path]::GetFileName([string]$_) } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        $result = [ordered]@{
            schemaVersion = 3
            mode = [string]$Mode
            outcome = $Outcome
            errorCategory = $(if ($Outcome -in @("failed", "partial")) { [string]$script:TautWeeklyResultErrorCategory } else { "" })
            deliveryScope = [string]$script:TautWeeklyResultDeliveryScope
            startedAtUtc = $script:TautWeeklyResultStartedAtUtc.ToString("o")
            finishedAtUtc = $finishedAtUtc.ToString("o")
            durationMs = $durationMs
            smtpAcceptedCount = [Math]::Max(0, [int]$script:TautWeeklyResultSmtpAcceptedCount)
            skippedCount = [Math]::Max(0, [int]$script:TautWeeklyResultSkippedCount)
            failedCount = [Math]::Max(0, [int]$script:TautWeeklyResultFailedCount)
            smtpFailure = $script:TautWeeklyResultSmtpFailure
            skipReasonCounts = $script:TautWeeklyResultSkipReasons
            generatedPreviewFiles = $safePreviewFiles
        }
        $temporaryPath = Join-Path $resultDirectory (".tautweekly-result-{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
        $json = $result | ConvertTo-Json -Depth 4 -Compress
        [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporaryPath -Destination $resolvedResultPath -Force
        $temporaryPath = ""
        $script:TautWeeklyResultWritten = $true
    }
    catch {
        Write-Warning "TautWeekly could not write the sanitized structured result."
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($temporaryPath) -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        $script:TautWeeklyResultWriting = $false
    }
}

function Get-TautWeeklySmtpFailureEvidence {
    param([AllowNull()][object]$Exception)

    $candidate = $Exception
    while ($null -ne $candidate) {
        if ($candidate.GetType().Name -eq 'TautWeeklySmtpException') {
            return [ordered]@{
                category      = [string]$candidate.Category
                stage         = [string]$candidate.Stage
                responseCode  = [Math]::Max(0, [int]$candidate.ResponseCode)
                responseClass = [Math]::Max(0, [int]$candidate.ResponseClass)
                batchFatal    = [bool]$candidate.BatchFatal
                acceptance    = [string]$candidate.Acceptance
            }
        }
        $candidate = $candidate.InnerException
    }
    return $null
}

trap {
    $smtpFailure = Get-TautWeeklySmtpFailureEvidence -Exception $_.Exception
    if ($null -ne $smtpFailure) {
        $script:TautWeeklyResultSmtpFailure = $smtpFailure
        $script:TautWeeklyResultErrorCategory = [string]$smtpFailure.category
        $script:TautWeeklyResultFailedCount = [Math]::Max(1, [int]$script:TautWeeklyResultFailedCount)
    }
    Write-TautWeeklyStructuredResult -Outcome "failed"
    exit 1
}

$ScriptRoot = $PSScriptRoot
. (Join-Path $ScriptRoot "Smtp-Transport.ps1")
$deliveryTimeZone = $null
if ($Mode -eq 'SendAll') {
    . (Join-Path $ScriptRoot "Schedule-Time.ps1")
    $deliveryTimeZone = Get-TautWeeklyScheduleTimeZone
}

function Get-TautWeeklyRunNow {
    if ($null -ne $deliveryTimeZone) {
        return (Get-TautWeeklyScheduleNow -TimeZone $deliveryTimeZone)
    }
    return [DateTimeOffset]::Now
}

function ConvertTo-TautWeeklyRunUnixTime {
    param([DateTime]$LocalTime)
    if ($null -ne $deliveryTimeZone) {
        $utcTime = ConvertTo-TautWeeklyScheduleUtc -TimeZone $deliveryTimeZone -LocalTime $LocalTime
        return ([DateTimeOffset]$utcTime).ToUnixTimeSeconds()
    }
    return ([DateTimeOffset]$LocalTime).ToUnixTimeSeconds()
}

$DataRoot = if (-not [string]::IsNullOrWhiteSpace([string]$env:TAUTWEEKLY_DATA_DIR)) {
    [string]$env:TAUTWEEKLY_DATA_DIR
}
else {
    "/data"
}
$OutputDir = Join-Path $DataRoot "output"
$PosterDir = Join-Path $OutputDir "posters"
$DesignMediaDir = Join-Path $OutputDir "media"
$AssetsDir = Join-Path $DataRoot "assets"
$LogDir = Join-Path $DataRoot "logs"
$StatePath = Join-Path $DataRoot "state.json"
$AccessStatePath = Join-Path $DataRoot "access-state.json"

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
New-Item -ItemType Directory -Force -Path $PosterDir | Out-Null
New-Item -ItemType Directory -Force -Path $DesignMediaDir | Out-Null
New-Item -ItemType Directory -Force -Path $AssetsDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$PreviewAssetsDir = Join-Path $OutputDir "assets"

function Sync-PreviewAssets {
    # Browser previews are served with /data/output as the web root. Keep a
    # real mirrored assets directory under that root so previews work on QNAP,
    # Unraid, Docker Desktop bind mounts, and ordinary Linux Docker volumes.
    if (Test-Path -LiteralPath $PreviewAssetsDir) {
        $existing = Get-Item -LiteralPath $PreviewAssetsDir -Force
        if (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Remove-Item -LiteralPath $PreviewAssetsDir -Force
        }
    }

    New-Item -ItemType Directory -Force -Path $PreviewAssetsDir | Out-Null

    foreach ($asset in Get-ChildItem -LiteralPath $AssetsDir -File -ErrorAction Stop) {
        Copy-Item -LiteralPath $asset.FullName -Destination (Join-Path $PreviewAssetsDir $asset.Name) -Force
    }
}

Sync-PreviewAssets

$LogFile = Join-Path $LogDir ("tautweekly_{0}.log" -f (Get-TautWeeklyRunNow).ToString("yyyyMMdd"))

# Direct-Plex preview caches. These must exist before StrictMode code reads
# them inside Get-DesignPlexContext / Get-DesignPlexMetadata.
$script:DesignPlexContext = $null
$script:DesignPlexMetadataCache = @{}
$script:PlexHostedMetadataCache = @{}
$script:PlexWatchRatingCache = @{}
$script:TautulliDefaultPosterHash = ""

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )
    $line = "{0} [{1}] {2}" -f (Get-TautWeeklyRunNow).ToString("yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-PreviewPublicUrl {
    param([string]$Path)

    $baseUrl = [string]$env:TAUTWEEKLY_PREVIEW_BASE_URL
    if ([string]::IsNullOrWhiteSpace($baseUrl) -or
        [string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    try {
        $relative = [IO.Path]::GetRelativePath($OutputDir, $Path)
        $relative = $relative.Replace([IO.Path]::DirectorySeparatorChar, '/')
        return $baseUrl.TrimEnd('/') + '/' + $relative.TrimStart('/')
    }
    catch {
        return ""
    }
}

function HtmlEncode {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Truncate-Text {
    param(
        [AllowNull()][object]$Text,
        [int]$Length = 180
    )
    if ($null -eq $Text) { return "" }
    $s = ([string]$Text).Trim()
    if ($s.Length -le $Length) { return $s }
    return $s.Substring(0, [Math]::Max(0, $Length - 1)).TrimEnd() + "…"
}

function Safe-Int {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return 0 }
    $n = 0
    if ([int]::TryParse([string]$Value, [ref]$n)) { return $n }
    return 0
}

function Get-OptionalStringProperty {
    param(
        [AllowNull()][object]$InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ""
    }

    return [string]$property.Value
}

function Get-DesignProviderRating {
    param(
        [string]$RatingImage = "",
        [AllowNull()][object]$RatingValue = $null,
        [string]$AudienceImage = "",
        [AllowNull()][object]$AudienceValue = $null
    )

    foreach ($candidate in @(
        [PSCustomObject]@{ Image = $RatingImage; Value = $RatingValue },
        [PSCustomObject]@{ Image = $AudienceImage; Value = $AudienceValue }
    )) {
        $image = ([string]$candidate.Image).Trim().ToLowerInvariant()
        $value = if ($candidate.Value -is [IFormattable]) {
            ([IFormattable]$candidate.Value).ToString($null, [Globalization.CultureInfo]::InvariantCulture).Trim()
        }
        else {
            ([string]$candidate.Value).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($image) -or
            $value -notmatch '^(?:10(?:\.0+)?|[0-9](?:\.[0-9]+)?)$') {
            continue
        }

        $provider = if ($image -like 'imdb://image.rating*') {
            'IMDb'
        }
        elseif ($image -like 'themoviedb://image.rating*' -or
            $image -like 'tmdb://image.rating*') {
            'TMDB'
        }
        elseif ($image -like 'thetvdb://image.rating*' -or
            $image -like 'tvdb://image.rating*') {
            'TVDB'
        }
        else {
            ''
        }

        if (-not [string]::IsNullOrWhiteSpace($provider)) {
            return [PSCustomObject]@{ Provider = $provider; Value = $value }
        }
    }

    return [PSCustomObject]@{ Provider = ''; Value = '' }
}

function Safe-Int64 {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return [int64]0 }
    [int64]$n = 0
    if ([int64]::TryParse([string]$Value, [ref]$n)) { return $n }
    return [int64]0
}

function Format-WatchTime {
    param([int64]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $hours = [Math]::Floor($Seconds / 3600)
    $minutes = [Math]::Floor(($Seconds % 3600) / 60)
    if ($hours -gt 0) {
        return "{0}h {1}m" -f $hours, $minutes
    }
    return "{0}m" -f $minutes
}

function Get-SafeFilePart {
    param([string]$Text)
    $safe = $Text -replace '[\\/:*?"<>|]', '_'
    $safe = $safe -replace '\s+', '_'
    if ([string]::IsNullOrWhiteSpace($safe)) { return "user" }
    return $safe.Trim('_')
}

function Get-TautWeeklyState {
    $firstRun = $null

    if (Test-Path $StatePath) {
        try {
            $state = Get-Content -Path $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $state.PSObject.Properties["FirstRunUtc"] -and
                -not [string]::IsNullOrWhiteSpace([string]$state.FirstRunUtc)) {
                $firstRun = [DateTime]::Parse(
                    [string]$state.FirstRunUtc,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                )
            }
        }
        catch {
            Write-Log "Could not read state.json; rebuilding TautWeekly for Plex state." "WARN"
        }
    }

    if ($null -eq $firstRun) {
        # Preserve install age across this upgrade by using the oldest existing
        # TautWeekly for Plex daily log when one exists.
        $oldestLogDate = $null
        $logFiles = @(Get-ChildItem -Path $LogDir -Filter "tautweekly_*.log" -File -ErrorAction SilentlyContinue)

        foreach ($file in $logFiles) {
            if ($file.BaseName -match '^tautweekly_(\d{8})$') {
                try {
                    $candidate = [DateTime]::ParseExact(
                        $Matches[1],
                        "yyyyMMdd",
                        [Globalization.CultureInfo]::InvariantCulture
                    )
                    if ($null -eq $oldestLogDate -or $candidate -lt $oldestLogDate) {
                        $oldestLogDate = $candidate
                    }
                }
                catch { }
            }
        }

        if ($null -ne $oldestLogDate) {
            $firstRun = [DateTime]::SpecifyKind($oldestLogDate, [DateTimeKind]::Local).ToUniversalTime()
        }
        else {
            $firstRun = [DateTime]::UtcNow
        }

        [PSCustomObject]@{
            FirstRunUtc = $firstRun.ToString("o")
        } | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
    }

    $age = [DateTime]::UtcNow - $firstRun.ToUniversalTime()

    return [PSCustomObject]@{
        FirstRunUtc    = $firstRun.ToUniversalTime()
        AgeDays        = [Math]::Floor($age.TotalDays)
        IsWarmingUp    = ($age.TotalDays -lt 7)
    }
}

function New-AccessState {
    return [PSCustomObject]@{
        BaselineUtc = [DateTime]::UtcNow.ToString("o")
        Users       = [PSCustomObject]@{}
    }
}

function Get-AccessState {
    if (Test-Path $AccessStatePath) {
        try {
            $state = Get-Content -Path $AccessStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -eq $state.PSObject.Properties["Users"]) {
                $state | Add-Member -NotePropertyName "Users" -NotePropertyValue ([PSCustomObject]@{})
            }
            return $state
        }
        catch {
            Write-Log "Could not read access-state.json; rebuilding access roster." "WARN"
        }
    }

    return New-AccessState
}

function Save-AccessState {
    param([object]$State)

    $State |
        ConvertTo-Json -Depth 10 |
        Set-Content -Path $AccessStatePath -Encoding UTF8
}

function Add-AccessStateUser {
    param(
        [object]$State,
        [object]$User,
        [bool]$IsBaseline
    )

    $id = [string]$User.user_id
    if ([string]::IsNullOrWhiteSpace($id)) { return }

    $entry = [PSCustomObject]@{
        UserId         = $id
        Username       = [string]$User.username
        Email          = [string]$User.email
        FirstSeenUtc   = [DateTime]::UtcNow.ToString("o")
        IsBaseline     = $IsBaseline
        WelcomeSentUtc = ""
    }

    Add-Member -InputObject $State.Users -MemberType NoteProperty -Name $id -Value $entry -Force
}

function Sync-AccessRoster {
    param([switch]$RequireFreshUsers)

    # Tautulli's API exposes current access, not the Plex invitation acceptance
    # timestamp. We therefore establish a baseline once, then treat a newly
    # appearing active user as newly accepted from that point forward.
    try {
        Invoke-TautulliApi -Command "refresh_users_list" | Out-Null
    }
    catch {
        if ($RequireFreshUsers) {
            $script:TautWeeklyResultErrorCategory = "user-roster-refresh-failed"
            Write-Log "Required user-list refresh could not be confirmed; production delivery stopped before SMTP." "ERROR"
            throw "Required Tautulli user-list refresh could not be confirmed."
        }
        Write-Log "User-list refresh failed; continuing with the current local user list." "WARN"
    }

    $stateExists = Test-Path $AccessStatePath
    $state = Get-AccessState
    $users = @(Get-TautulliUsers)
    $changed = $false

    foreach ($u in $users) {
        $id = [string]$u.user_id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        # Only baseline/track users that currently have active access.
        if ((Safe-Int $u.is_active) -eq 0) { continue }

        $prop = $state.Users.PSObject.Properties[$id]

        if ($null -eq $prop) {
            Add-AccessStateUser -State $state -User $u -IsBaseline:(-not $stateExists)
            $changed = $true
        }
        else {
            # Keep basic contact metadata fresh without altering first-seen time.
            $prop.Value.Username = [string]$u.username
            $prop.Value.Email = [string]$u.email
            $changed = $true
        }
    }

    if (-not $stateExists -or $changed) {
        Save-AccessState -State $state
    }

    return $state
}

function Test-UserNeedsWelcome {
    param(
        [object]$State,
        [string]$UserId
    )

    if ($null -eq $State -or $null -eq $State.Users) { return $false }

    $prop = $State.Users.PSObject.Properties[[string]$UserId]
    if ($null -eq $prop) { return $false }

    $entry = $prop.Value
    if ($entry.IsBaseline -eq $true) { return $false }

    if ($null -ne $entry.PSObject.Properties["WelcomeSentUtc"] -and
        -not [string]::IsNullOrWhiteSpace([string]$entry.WelcomeSentUtc)) {
        return $false
    }

    try {
        $firstSeen = [DateTime]::Parse(
            [string]$entry.FirstSeenUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
    }
    catch {
        return $false
    }

    $recentDays = 7
    if ($null -ne $Config.PSObject.Properties["RecentAccessDays"]) {
        $candidate = Safe-Int $Config.RecentAccessDays
        if ($candidate -gt 0) { $recentDays = $candidate }
    }

    return ($firstSeen -ge [DateTime]::UtcNow.AddDays(-$recentDays))
}

function Mark-UserWelcomed {
    param(
        [object]$State,
        [string]$UserId
    )

    if ($null -eq $State -or $null -eq $State.Users) { return }

    $prop = $State.Users.PSObject.Properties[[string]$UserId]
    if ($null -eq $prop) { return }

    $prop.Value.WelcomeSentUtc = [DateTime]::UtcNow.ToString("o")
    Save-AccessState -State $State
}

$script:TautWeeklyResultErrorCategory = "configuration-invalid"
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath`nRun ./tautweekly.sh setup from the NAS project folder first."
}

$Config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Test-TautWeeklyDeliveryEmailAddress {
    param([string]$Address)

    if ([string]::IsNullOrWhiteSpace($Address) -or $Address.Length -gt 254) { return $false }
    try {
        $parsed = New-Object System.Net.Mail.MailAddress($Address)
        return [string]$parsed.Address -ceq $Address
    }
    catch { return $false }
}

function Assert-TautWeeklyUserEmailOverrides {
    $property = $Config.PSObject.Properties['UserEmailOverrides']
    if ($null -eq $property -or $null -eq $property.Value) { return }
    $entries = @($property.Value.PSObject.Properties)
    if ($entries.Count -gt 2000) { throw 'UserEmailOverrides supports at most 2000 assignments.' }
    foreach ($entry in $entries) {
        $id = ([string]$entry.Name).Trim()
        [UInt64]$parsedUserId = 0
        if ($id -notmatch '^\d{1,20}$' -or -not [UInt64]::TryParse($id, [ref]$parsedUserId)) { throw 'UserEmailOverrides keys must be valid numeric Tautulli user IDs.' }
        if ($entry.Value -isnot [string]) { throw "UserEmailOverrides[$id] must be an email-address string." }
        $address = ([string]$entry.Value).Trim()
        if (-not [string]::IsNullOrWhiteSpace($address) -and -not (Test-TautWeeklyDeliveryEmailAddress -Address $address)) {
            throw "UserEmailOverrides[$id] is not a valid email address of 254 characters or fewer."
        }
    }
}

Assert-TautWeeklyUserEmailOverrides
. (Join-Path $ScriptRoot "DeletedItemCache.ps1")
Initialize-TautWeeklyDeletedItemCache `
    -CacheRoot (Join-Path (Join-Path $DataRoot "cache") "deleted-items") `
    -Configuration $Config

$script:IncludedLibraryIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if ($null -ne $Config.PSObject.Properties["IncludedLibraryIds"]) {
    foreach ($value in @($Config.IncludedLibraryIds)) {
        $libraryId = ([string]$value).Trim()
        if (-not [string]::IsNullOrWhiteSpace($libraryId)) {
            [void]$script:IncludedLibraryIdSet.Add($libraryId)
        }
    }
}
$script:LibraryFilterEnabled = ($script:IncludedLibraryIdSet.Count -gt 0)
if ($script:LibraryFilterEnabled) {
    Write-Log ("Global library scope enabled for section ID(s): " + (($script:IncludedLibraryIdSet | Sort-Object) -join ", "))
}

function Test-IncludedLibraryRow {
    param(
        [object]$Row,
        [string]$ExpectedSectionId = ""
    )

    $sectionId = (Get-OptionalStringProperty -InputObject $Row -Name "section_id").Trim()
    $expectedSectionId = ([string]$ExpectedSectionId).Trim()

    if (-not $script:LibraryFilterEnabled) {
        # Unfiltered Recent Releases now uses per-section queries. Trust rows
        # that omit redundant section metadata, but never accept an explicit
        # cross-section mismatch from a scoped response.
        if ([string]::IsNullOrWhiteSpace($expectedSectionId) -or [string]::IsNullOrWhiteSpace($sectionId)) { return $true }
        return ($sectionId -eq $expectedSectionId)
    }

    if (-not [string]::IsNullOrWhiteSpace($expectedSectionId)) {
        if (-not $script:IncludedLibraryIdSet.Contains($expectedSectionId)) { return $false }

        # Tautulli uses Plex's library-specific recentlyAdded endpoint when a
        # section_id is supplied. Plex can omit the redundant librarySectionID
        # attribute from those already-scoped rows. Trust the selected query
        # scope only when the row omits the field; explicit mismatches still
        # fail closed.
        if ([string]::IsNullOrWhiteSpace($sectionId)) { return $true }
        return ($sectionId -eq $expectedSectionId)
    }

    if ([string]::IsNullOrWhiteSpace($sectionId)) { return $false }
    return $script:IncludedLibraryIdSet.Contains($sectionId)
}

function Get-IncludedLibraryQueryScopes {
    if (-not $script:LibraryFilterEnabled) { return @('') }
    return @($script:IncludedLibraryIdSet | Sort-Object)
}

function Get-LatestReleaseQueryScopes {
    if ($script:LibraryFilterEnabled) {
        return @(Get-IncludedLibraryQueryScopes)
    }

    # Tautulli's unscoped get_recently_added call is backed by Plex's global
    # hubs. Those hubs may legitimately return no rows once every addition is
    # older than the hub window, which is exactly when the quiet-week fallback
    # still needs content. Query every active movie/TV section directly so the
    # bounded Recent Releases shelves use the library's actual newest items.
    try {
        $sectionIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($library in @(Invoke-TautulliApi -Command "get_libraries")) {
            $sectionType = (Get-OptionalStringProperty -InputObject $library -Name "section_type").ToLowerInvariant()
            if ($sectionType -notin @("movie", "show")) { continue }
            if ($null -ne $library.PSObject.Properties["is_active"] -and
                (Safe-Int (Get-OptionalStringProperty -InputObject $library -Name "is_active")) -eq 0) { continue }
            $sectionId = (Get-OptionalStringProperty -InputObject $library -Name "section_id").Trim()
            if (-not [string]::IsNullOrWhiteSpace($sectionId)) { [void]$sectionIds.Add($sectionId) }
        }
        if ($sectionIds.Count -gt 0) {
            Write-Log ("Recent Releases will query {0} active movie/TV library section(s)." -f $sectionIds.Count)
            return @($sectionIds | Sort-Object)
        }
    }
    catch {
        Write-Log "Could not enumerate movie/TV library sections for Recent Releases; falling back to the global recently-added hub." "WARN"
    }
    return @('')
}

function Require-ConfigValue {
    param([string]$Name)
    $prop = $Config.PSObject.Properties[$Name]
    if ($null -eq $prop -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
        throw "Missing required config value '$Name' in $ConfigPath"
    }
}

Require-ConfigValue "TautulliUrl"
Require-ConfigValue "ApiKey"

$TautulliBase = ([string]$Config.TautulliUrl).TrimEnd('/')

function Get-ConfiguredServerName {
    if ($null -ne $Config.PSObject.Properties["FooterServerName"] -and
        -not [string]::IsNullOrWhiteSpace([string]$Config.FooterServerName)) {
        return [string]$Config.FooterServerName
    }
    if ($null -ne $Config.PSObject.Properties["ServerLabel"] -and
        -not [string]::IsNullOrWhiteSpace([string]$Config.ServerLabel)) {
        return [string]$Config.ServerLabel
    }
    return "My Plex"
}

function Get-ConfiguredPlexWebUrl {
    if ($null -ne $Config.PSObject.Properties["PlexWebUrl"] -and
        -not [string]::IsNullOrWhiteSpace([string]$Config.PlexWebUrl)) {
        $value = ([string]$Config.PlexWebUrl).Trim()
        [Uri]$parsed = $null
        if ([Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$parsed) -and
            $parsed.Scheme -in @('http', 'https') -and
            -not [string]::IsNullOrWhiteSpace($parsed.Host)) {
            return $value
        }
    }
    return "https://app.plex.tv/desktop/"
}

function Get-ConfiguredPlexButtonLabel {
    $label = if ($null -ne $Config.PSObject.Properties["PlexButtonLabel"]) {
        [string]$Config.PlexButtonLabel
    } else {
        ""
    }
    $label = [regex]::Replace($label, '[\x00-\x1F\x7F]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($label)) {
        return "Open Plex"
    }
    $textElements = [Globalization.StringInfo]::ParseCombiningCharacters($label)
    if ($textElements.Count -gt 64) {
        return $label.Substring(0, $textElements[64])
    }
    return $label
}

function Get-ConfiguredDeliveryDay {
    if ($null -ne $Config.PSObject.Properties["ScheduleDay"] -and
        -not [string]::IsNullOrWhiteSpace([string]$Config.ScheduleDay)) {
        return ([string]$Config.ScheduleDay).Trim()
    }
    return "Friday"
}
function Get-BoundedCustomTextValue {
    param(
        [AllowNull()][object]$Value,
        [int]$MaximumLength,
        [bool]$AllowLineBreaks
    )

    $text = [string]$Value
    if ($AllowLineBreaks) {
        $text = [regex]::Replace($text, '\r\n?', [string][char]10)
        $text = [regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    }
    else {
        $text = [regex]::Replace($text, '[\x00-\x1F\x7F]', '')
    }
    $text = $text.Trim()
    $elements = [Globalization.StringInfo]::ParseCombiningCharacters($text)
    if ($elements.Count -gt $MaximumLength) {
        return $text.Substring(0, $elements[$MaximumLength])
    }
    return $text
}

function Get-CustomTextCardTitleGifAsset {
    param([AllowNull()][object]$Value)

    $id = ([string]$Value).Trim().ToLowerInvariant()
    $definition = switch ($id) {
        "celebrate"    { @{ Id = "celebrate"; File = "celebrate.gif"; Cid = "custom_title_celebrate" } }
        "construction" { @{ Id = "construction"; File = "construction.gif"; Cid = "custom_title_construction" } }
        "rocket"       { @{ Id = "rocket"; File = "rocket.gif"; Cid = "custom_title_rocket" } }
        "tickets"      { @{ Id = "tickets"; File = "tickets.gif"; Cid = "custom_title_tickets" } }
        "warning"      { @{ Id = "warning"; File = "warning.gif"; Cid = "custom_title_warning" } }
        "alert"        { @{ Id = "alert"; File = "alert.gif"; Cid = "custom_title_alert" } }
        default          { $null }
    }
    if ($null -eq $definition) {
        return $null
    }
    $path = Join-Path $AssetsDir $definition.File
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    return [PSCustomObject]@{
        Id   = $definition.Id
        File = $definition.File
        Cid  = $definition.Cid
        Path = $path
    }
}

function Get-ConfiguredCustomTextCard {
    $enabled = (
        $null -ne $Config.PSObject.Properties["CustomTextCardEnabled"] -and
        [bool]$Config.CustomTextCardEnabled
    )
    $bodyValue = if ($null -ne $Config.PSObject.Properties["CustomTextCardBody"]) { $Config.CustomTextCardBody } else { "" }
    $body = Get-BoundedCustomTextValue -Value $bodyValue -MaximumLength 2000 -AllowLineBreaks $true
    if (-not $enabled -or [string]::IsNullOrWhiteSpace($body)) {
        return [PSCustomObject]@{ Enabled = $false }
    }

    $borderColor = if ($null -ne $Config.PSObject.Properties["CustomTextCardBorderColor"]) {
        ([string]$Config.CustomTextCardBorderColor).Trim()
    }
    else {
        "#72aef7"
    }
    if ($borderColor -notmatch '^#[0-9a-fA-F]{6}$') {
        $borderColor = "#72aef7"
    }
    $opacity = if ($null -ne $Config.PSObject.Properties["CustomTextCardBorderOpacity"]) {
        [Math]::Max(0, [Math]::Min(100, (Safe-Int $Config.CustomTextCardBorderOpacity)))
    }
    else {
        34
    }
    $titleValue = if ($null -ne $Config.PSObject.Properties["CustomTextCardTitle"]) { $Config.CustomTextCardTitle } else { "" }
    $titleGifValue = if ($null -ne $Config.PSObject.Properties["CustomTextCardTitleGif"]) { $Config.CustomTextCardTitleGif } else { "none" }
    $subheadingValue = if ($null -ne $Config.PSObject.Properties["CustomTextCardSubheading"]) { $Config.CustomTextCardSubheading } else { "" }

    return [PSCustomObject]@{
        Enabled       = $true
        Title         = Get-BoundedCustomTextValue -Value $titleValue -MaximumLength 120 -AllowLineBreaks $false
        TitleGif      = Get-CustomTextCardTitleGifAsset -Value $titleGifValue
        Subheading    = Get-BoundedCustomTextValue -Value $subheadingValue -MaximumLength 200 -AllowLineBreaks $false
        Body          = $body
        BorderColor   = $borderColor.ToLowerInvariant()
        BorderOpacity = $opacity
    }
}

function Get-CustomTextCardTableHtml {
    param(
        [ValidateSet("Preview","Email")]
        [string]$ImageMode = "Preview"
    )

    $card = Get-ConfiguredCustomTextCard
    if (-not $card.Enabled) {
        return ""
    }

    $titleHtml = ""
    if (-not [string]::IsNullOrWhiteSpace($card.Title)) {
        $titleGifHtml = ""
        if ($null -ne $card.TitleGif) {
            $source = if ($ImageMode -eq "Email") { "cid:$($card.TitleGif.Cid)" } else { "../assets/$($card.TitleGif.File)" }
            $titleGifHtml = '<img src="' + (HtmlEncode $source) + '" alt="" width="18" height="18" style="display:inline-block;width:18px;height:18px;border:0;vertical-align:-4px;margin-left:6px;">'
        }
        $titleHtml = '<div style="font-size:11px;color:#e5a00d;font-weight:800;letter-spacing:1.4px;"><span>' + (HtmlEncode $card.Title.ToUpperInvariant()) + '</span>' + $titleGifHtml + '</div>'
    }
    $subheadingHtml = ""
    if (-not [string]::IsNullOrWhiteSpace($card.Subheading)) {
        $subheadingPadding = if ([string]::IsNullOrWhiteSpace($titleHtml)) { "0" } else { "7px" }
        $subheadingHtml = '<div style="padding-top:' + $subheadingPadding + ';font-size:22px;line-height:1.2;color:#ffffff;font-weight:800;">' + (HtmlEncode $card.Subheading) + '</div>'
    }
    $bodyPadding = if ([string]::IsNullOrWhiteSpace($titleHtml) -and [string]::IsNullOrWhiteSpace($subheadingHtml)) { "0" } else { "7px" }
    $bodyHtml = (HtmlEncode $card.Body) -replace '(\r\n|\r|\n)', '<br>'
    $hex = $card.BorderColor.TrimStart('#')
    $red = [Convert]::ToInt32($hex.Substring(0, 2), 16)
    $green = [Convert]::ToInt32($hex.Substring(2, 2), 16)
    $blue = [Convert]::ToInt32($hex.Substring(4, 2), 16)
    $alpha = [double]$card.BorderOpacity / 100
    $fallbackRed = [int][Math]::Round(($red * $alpha) + (24 * (1 - $alpha)))
    $fallbackGreen = [int][Math]::Round(($green * $alpha) + (24 * (1 - $alpha)))
    $fallbackBlue = [int][Math]::Round(($blue * $alpha) + (24 * (1 - $alpha)))
    $fallbackColor = "#{0:X2}{1:X2}{2:X2}" -f $fallbackRed, $fallbackGreen, $fallbackBlue
    $alphaText = $alpha.ToString("0.##", [Globalization.CultureInfo]::InvariantCulture)
    $borderStyle = if ($card.BorderOpacity -eq 0) {
        "border:0;"
    }
    else {
        "border:1px solid $fallbackColor;border-color:rgba($red,$green,$blue,$alphaText);"
    }

    return @"
<table class="email-card custom-text-card" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#181818" style="background-color:#181818;$($borderStyle)border-radius:10px;border-collapse:separate;">
  <tr>
    <td valign="middle" style="padding:20px 22px;">
      $titleHtml
      $subheadingHtml
      <div style="padding-top:$bodyPadding;font-size:13px;line-height:1.5;color:#9b9b9b;">$bodyHtml</div>
    </td>
  </tr>
</table>
"@
}

function Get-CustomTextCardPlainText {
    $card = Get-ConfiguredCustomTextCard
    if (-not $card.Enabled) {
        return ""
    }

    $lines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($card.Title)) {
        $lines.Add($card.Title.ToUpperInvariant())
    }
    if (-not [string]::IsNullOrWhiteSpace($card.Subheading)) {
        $lines.Add($card.Subheading)
    }
    $lines.Add($card.Body)
    $newline = [string][char]13 + [string][char]10
    return (($lines -join $newline) + $newline + $newline)
}


function Build-TautulliUri {
    param(
        [string]$Command,
        [hashtable]$Parameters = @{}
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("apikey=" + [Uri]::EscapeDataString([string]$Config.ApiKey))
    $parts.Add("cmd=" + [Uri]::EscapeDataString($Command))

    foreach ($key in ($Parameters.Keys | Sort-Object)) {
        $value = $Parameters[$key]
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            $parts.Add(
                ([Uri]::EscapeDataString([string]$key)) + "=" +
                ([Uri]::EscapeDataString([string]$value))
            )
        }
    }

    return "$TautulliBase/api/v2?" + ($parts -join "&")
}

function Invoke-TautulliApi {
    param(
        [string]$Command,
        [hashtable]$Parameters = @{}
    )

    $uri = Build-TautulliUri -Command $Command -Parameters $Parameters
    try {
        $raw = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 60
    }
    catch {
        throw "Tautulli API request failed for '$Command': $($_.Exception.Message)"
    }

    if ($null -eq $raw.response) {
        throw "Unexpected Tautulli response for '$Command'."
    }

    if ([string]$raw.response.result -ne "success") {
        throw "Tautulli '$Command' returned: $($raw.response.message)"
    }

    return $raw.response.data
}

function Get-TautulliUser {
    param([string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) {
        throw "A Tautulli user ID is required."
    }

    try {
        $directUser = Invoke-TautulliApi -Command "get_user" -Parameters @{ user_id = $Id }
        if ($null -ne $directUser) { return $directUser }
    }
    catch {
        # Some Tautulli installations return a valid bulk roster while
        # rejecting otherwise valid per-user lookups. Fall back to get_users.
    }

    $matches = @(
        Get-TautulliUsers | Where-Object {
            [string](Get-OptionalStringProperty -InputObject $_ -Name "user_id") -eq $Id
        }
    )
    if ($matches.Count -eq 1) { return $matches[0] }
    if ($matches.Count -gt 1) {
        throw "Tautulli returned more than one bulk user for ID '$Id'."
    }

    throw "Tautulli user ID '$Id' was unavailable through both get_user and get_users."
}

function Get-TautulliUserNames {
    return @(Invoke-TautulliApi -Command "get_user_names")
}

function Get-TautulliUsers {
    return @(Invoke-TautulliApi -Command "get_users")
}

function Resolve-TautulliUserId {
    param([string]$Identifier)

    if ([string]::IsNullOrWhiteSpace($Identifier)) {
        throw "A Tautulli user identifier is required."
    }

    $needle = $Identifier.Trim()
    $users = Get-TautulliUsers

    $matches = @(
        $users | Where-Object {
            ([string]$_.user_id -eq $needle) -or
            ([string]$_.username -ieq $needle) -or
            ([string]$_.friendly_name -ieq $needle) -or
            ([string]$_.email -ieq $needle)
        }
    )

    if ($matches.Count -eq 1) {
        return [string]$matches[0].user_id
    }

    if ($matches.Count -gt 1) {
        throw "More than one Tautulli user matched '$Identifier'. Please use the numeric UserId from ./tautweekly.sh list-users."
    }

    throw "No Tautulli user matched '$Identifier'. Run ./tautweekly.sh list-users and enter the numeric UserId, username, friendly name, or email."
}

function Get-History {
    param(
        [string]$AfterDate,
        [string]$BeforeDate,
        [string]$ForUserId = ""
    )

    $all = New-Object System.Collections.Generic.List[object]
    $pageSize = 1000

    foreach ($sectionId in @(Get-IncludedLibraryQueryScopes)) {
        $start = 0
        while ($true) {
            $params = @{ grouping = 1; include_activity = 0; after = $AfterDate; before = $BeforeDate; start = $start; length = $pageSize }
            if (-not [string]::IsNullOrWhiteSpace($ForUserId)) { $params.user_id = $ForUserId }
            if (-not [string]::IsNullOrWhiteSpace($sectionId)) { $params.section_id = $sectionId }
            $data = Invoke-TautulliApi -Command "get_history" -Parameters $params
            $rows = @($data.data)
            foreach ($row in $rows) {
                if (Test-IncludedLibraryRow -Row $row -ExpectedSectionId $sectionId) { $all.Add($row) }
            }
            if ($rows.Count -lt $pageSize) { break }
            $start += $rows.Count
            $total = Safe-Int $data.recordsFiltered
            if ($total -gt 0 -and $start -ge $total) { break }
        }
    }

    return $all.ToArray()
}

function Get-RecipientWatchedMovies {
    param([string]$ExpectedUserId)

    $ratingKeys = @{}
    $metadataGuids = @{}
    $state = [PSCustomObject]@{
        ExpectedUserId = $ExpectedUserId
        RatingKeys     = $ratingKeys
        MetadataGuids  = $metadataGuids
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedUserId)) { return $state }

    $watchedThreshold = if ($null -ne $Config.PSObject.Properties["WatchedPercent"]) {
        Safe-Int $Config.WatchedPercent
    } else { 85 }
    $pageSize = 1000

    try {
        foreach ($sectionId in @(Get-IncludedLibraryQueryScopes)) {
            $start = 0
            while ($true) {
                # This query intentionally omits the newsletter's after/before
                # window. A movie is marked from the recipient's historical
                # watched state, while user_id and the selected library scope
                # keep the lookup private and relevant.
                $params = @{
                    grouping         = 1
                    include_activity = 0
                    media_type       = "movie"
                    user_id          = $ExpectedUserId
                    start            = $start
                    length           = $pageSize
                }
                if (-not [string]::IsNullOrWhiteSpace($sectionId)) {
                    $params.section_id = $sectionId
                }

                $data = Invoke-TautulliApi -Command "get_history" -Parameters $params
                $rows = @($data.data)

                foreach ($row in $rows) {
                    if (-not (Test-IncludedLibraryRow -Row $row -ExpectedSectionId $sectionId)) { continue }

                    # Fail closed when a row does not prove that it belongs to
                    # the requested recipient, even if an upstream API ever
                    # ignores its user_id filter.
                    $rowUserId = (Get-OptionalStringProperty -InputObject $row -Name "user_id").Trim()
                    if ($rowUserId -ne $ExpectedUserId) { continue }
                    if ((Get-OptionalStringProperty -InputObject $row -Name "media_type").ToLowerInvariant() -ne "movie") { continue }

                    $qualified = (
                        # Tautulli v2.18.0 returns graded watched_status values
                        # (0, .25, .5, .75, 1). Only 1 is definitive; partial
                        # grades must not mark a movie unless our configured
                        # percentage threshold independently qualifies it.
                        (Safe-Int $row.watched_status) -eq 1 -or
                        (Safe-Int $row.percent_complete) -ge $watchedThreshold
                    )
                    if (-not $qualified) { continue }

                    $ratingKey = (Get-OptionalStringProperty -InputObject $row -Name "rating_key").Trim()
                    if (-not [string]::IsNullOrWhiteSpace($ratingKey)) {
                        $ratingKeys[$ratingKey] = $true
                    }

                    $metadataGuid = (Get-OptionalStringProperty -InputObject $row -Name "guid").Trim()
                    if (-not [string]::IsNullOrWhiteSpace($metadataGuid)) {
                        $metadataGuids[$metadataGuid] = $true
                    }
                }

                if ($rows.Count -lt $pageSize) { break }
                $start += $rows.Count
                $total = Safe-Int $data.recordsFiltered
                if ($total -gt 0 -and $start -ge $total) { break }
            }
        }
    }
    catch {
        # The marker is supplementary. If historical state cannot be loaded,
        # omit it without weakening the normal newsletter delivery.
        $ratingKeys.Clear()
        $metadataGuids.Clear()
        Write-Log "Historical recipient movie state was unavailable; watched markers were omitted." "WARN"
    }

    return $state
}

function Test-RecipientHasWatchedMovie {
    param(
        [AllowNull()][object]$Item,
        [AllowNull()][object]$RecipientWatchedMovies
    )

    if ($null -eq $Item -or $null -eq $RecipientWatchedMovies) { return $false }
    if ((Get-OptionalStringProperty -InputObject $Item -Name "Type").ToLowerInvariant() -ne "movie") { return $false }

    $ratingKey = (Get-OptionalStringProperty -InputObject $Item -Name "RatingKey").Trim()
    if (-not [string]::IsNullOrWhiteSpace($ratingKey) -and
        $RecipientWatchedMovies.RatingKeys.ContainsKey($ratingKey)) {
        return $true
    }

    $metadataGuid = (Get-OptionalStringProperty -InputObject $Item -Name "MetadataGuid").Trim()
    if (-not [string]::IsNullOrWhiteSpace($metadataGuid) -and
        $RecipientWatchedMovies.MetadataGuids.ContainsKey($metadataGuid)) {
        return $true
    }

    return $false
}
function Get-RecentItems {
    param(
        [int64]$StartEpoch,
        [int64]$EndEpochExclusive
    )

    $all = New-Object System.Collections.Generic.List[object]
    $pageSize = 100
    $maxPages = 20

    foreach ($sectionId in @(Get-IncludedLibraryQueryScopes)) {
        $start = 0
        for ($page = 0; $page -lt $maxPages; $page++) {
            $params = @{ count = $pageSize; start = $start }
            if (-not [string]::IsNullOrWhiteSpace($sectionId)) { $params.section_id = $sectionId }
            $data = Invoke-TautulliApi -Command "get_recently_added" -Parameters $params
            $rows = @($data.recently_added)
            if ($rows.Count -eq 0) { break }
            $oldest = [int64]::MaxValue
            foreach ($row in $rows) {
                $added = Safe-Int64 $row.added_at
                if ($added -lt $oldest) { $oldest = $added }
                if ($added -ge $StartEpoch -and $added -lt $EndEpochExclusive -and (Test-IncludedLibraryRow -Row $row -ExpectedSectionId $sectionId)) { $all.Add($row) }
            }
            if ($oldest -lt $StartEpoch) { break }
            if ($rows.Count -lt $pageSize) { break }
            $start += $rows.Count
        }
    }

    return $all.ToArray()
}

function New-ReleaseData {
    param([object[]]$RecentItems)

    $movieList = New-Object System.Collections.Generic.List[object]
    $tvMap = @{}

    foreach ($item in $RecentItems) {
        $type = (Get-OptionalStringProperty -InputObject $item -Name "media_type").ToLowerInvariant()

        if ($type -eq "movie") {
            $ratingKey = Get-OptionalStringProperty -InputObject $item -Name "rating_key"
            $rating = Get-OptionalStringProperty -InputObject $item -Name "rating"
            $movieList.Add([PSCustomObject]@{
                Type            = "movie"
                ReleaseKey      = "movie:" + $ratingKey
                RatingKey       = $ratingKey
                PosterRatingKey = $ratingKey
                MetadataGuid    = Get-OptionalStringProperty -InputObject $item -Name "guid"
                Title           = Get-OptionalStringProperty -InputObject $item -Name "title"
                Year            = Get-OptionalStringProperty -InputObject $item -Name "year"
                Rating          = $rating
                RatingImage     = Get-OptionalStringProperty -InputObject $item -Name "rating_image"
                AudienceRating  = Get-OptionalStringProperty -InputObject $item -Name "audience_rating"
                AudienceRatingImage = Get-OptionalStringProperty -InputObject $item -Name "audience_rating_image"
                Summary         = Get-OptionalStringProperty -InputObject $item -Name "summary"
                DesignGenres    = @(if ($null -ne $item.PSObject.Properties["genres"]) {
                    ConvertTo-DesignGenreList -Value $item.genres
                })
                AddedAt         = Safe-Int64 $item.added_at
                EpisodeCount    = 0
                SeasonCount     = 0
                IsNewSeries     = $false
                Episodes        = @()
            })
            continue
        }

        if ($type -in @("episode","season","show")) {
            $showRatingKey = ""
            $showTitle = ""
            $posterRatingKey = ""

            if ($type -eq "show") {
                $showRatingKey = Get-OptionalStringProperty -InputObject $item -Name "rating_key"
                $showTitle = Get-OptionalStringProperty -InputObject $item -Name "title"
                $posterRatingKey = $showRatingKey
            }
            else {
                $showRatingKey = Get-OptionalStringProperty -InputObject $item -Name "grandparent_rating_key"
                $showTitle = Get-OptionalStringProperty -InputObject $item -Name "grandparent_title"
                $posterRatingKey = $showRatingKey
                if ([string]::IsNullOrWhiteSpace($showTitle)) {
                    $showTitle = Get-OptionalStringProperty -InputObject $item -Name "title"
                }
                if ([string]::IsNullOrWhiteSpace($showRatingKey)) {
                    $showRatingKey = Get-OptionalStringProperty -InputObject $item -Name "rating_key"
                    $posterRatingKey = $showRatingKey
                }
            }

            if ([string]::IsNullOrWhiteSpace($showRatingKey)) {
                $showRatingKey = $showTitle
            }

            $showSummaryField = if ($type -eq "show") { "summary" } else { "grandparent_summary" }
            $showYearField = if ($type -eq "show") { "year" } else { "grandparent_year" }
            $showRatingField = if ($type -eq "show") { "rating" } else { "grandparent_rating" }
            $showRatingImageField = if ($type -eq "show") { "rating_image" } else { "grandparent_rating_image" }
            $showAudienceField = if ($type -eq "show") { "audience_rating" } else { "grandparent_audience_rating" }
            $showAudienceImageField = if ($type -eq "show") { "audience_rating_image" } else { "grandparent_audience_rating_image" }
            $showGenresField = if ($type -eq "show") { "genres" } else { "grandparent_genres" }

            $showSummary = Get-OptionalStringProperty -InputObject $item -Name $showSummaryField
            $showYear = Get-OptionalStringProperty -InputObject $item -Name $showYearField
            $showRating = Get-OptionalStringProperty -InputObject $item -Name $showRatingField
            $showRatingImage = Get-OptionalStringProperty -InputObject $item -Name $showRatingImageField
            $showAudienceRating = Get-OptionalStringProperty -InputObject $item -Name $showAudienceField
            $showAudienceRatingImage = Get-OptionalStringProperty -InputObject $item -Name $showAudienceImageField
            $showGenres = @()
            if ($null -ne $item.PSObject.Properties[$showGenresField]) {
                $showGenres = @(ConvertTo-DesignGenreList -Value $item.PSObject.Properties[$showGenresField].Value)
            }
            $showRatingPairAvailable = (
                -not [string]::IsNullOrWhiteSpace($showRating) -and
                -not [string]::IsNullOrWhiteSpace($showRatingImage)
            )
            $showAudiencePairAvailable = (
                -not [string]::IsNullOrWhiteSpace($showAudienceRating) -and
                -not [string]::IsNullOrWhiteSpace($showAudienceRatingImage)
            )

            $mapKey = "show:" + $showRatingKey

            if (-not $tvMap.ContainsKey($mapKey)) {
                $tvMap[$mapKey] = [PSCustomObject]@{
                    Type            = "show"
                    ReleaseKey      = $mapKey
                    RatingKey       = $showRatingKey
                    PosterRatingKey = $posterRatingKey
                    MetadataGuid    = Get-OptionalStringProperty -InputObject $item -Name "guid"
                    MetadataParentIndex = if ($type -eq "episode") { Safe-Int (Get-OptionalStringProperty -InputObject $item -Name "parent_media_index") } else { 0 }
                    MetadataIndex   = if ($type -in @("episode", "season")) { Safe-Int (Get-OptionalStringProperty -InputObject $item -Name "media_index") } else { 0 }
                    Title           = $showTitle
                    Year            = $showYear
                    Rating          = if ($showRatingPairAvailable) { $showRating } else { "" }
                    RatingImage     = if ($showRatingPairAvailable) { $showRatingImage } else { "" }
                    AudienceRating  = if ($showAudiencePairAvailable) { $showAudienceRating } else { "" }
                    AudienceRatingImage = if ($showAudiencePairAvailable) { $showAudienceRatingImage } else { "" }
                    Summary         = $showSummary
                    DesignGenres    = @($showGenres)
                    AddedAt         = Safe-Int64 $item.added_at
                    EpisodeCount    = 0
                    SeasonCount     = 0
                    IsNewSeries     = $false
                    Episodes        = New-Object System.Collections.Generic.List[object]
                }
            }

            $entry = $tvMap[$mapKey]
            if ([string]::IsNullOrWhiteSpace([string]$entry.MetadataGuid)) {
                $entry.MetadataGuid = Get-OptionalStringProperty -InputObject $item -Name "guid"
                if ($type -eq "episode") {
                    $entry.MetadataParentIndex = Safe-Int (Get-OptionalStringProperty -InputObject $item -Name "parent_media_index")
                    $entry.MetadataIndex = Safe-Int (Get-OptionalStringProperty -InputObject $item -Name "media_index")
                }
                elseif ($type -eq "season") {
                    $entry.MetadataIndex = Safe-Int (Get-OptionalStringProperty -InputObject $item -Name "media_index")
                }
            }
            if ([string]::IsNullOrWhiteSpace([string]$entry.Year) -and
                -not [string]::IsNullOrWhiteSpace($showYear)) {
                $entry.Year = $showYear
            }
            if ([string]::IsNullOrWhiteSpace([string]$entry.Summary) -and
                -not [string]::IsNullOrWhiteSpace($showSummary)) {
                $entry.Summary = $showSummary
            }
            if (@($entry.DesignGenres).Count -eq 0 -and $showGenres.Count -gt 0) {
                $entry.DesignGenres = @($showGenres)
            }
            $entryRatingPairAvailable = (
                -not [string]::IsNullOrWhiteSpace([string]$entry.Rating) -and
                -not [string]::IsNullOrWhiteSpace([string]$entry.RatingImage)
            )
            if (-not $entryRatingPairAvailable -and $showRatingPairAvailable) {
                $entry.Rating = $showRating
                $entry.RatingImage = $showRatingImage
            }
            $entryAudiencePairAvailable = (
                -not [string]::IsNullOrWhiteSpace([string]$entry.AudienceRating) -and
                -not [string]::IsNullOrWhiteSpace([string]$entry.AudienceRatingImage)
            )
            if (-not $entryAudiencePairAvailable -and $showAudiencePairAvailable) {
                $entry.AudienceRating = $showAudienceRating
                $entry.AudienceRatingImage = $showAudienceRatingImage
            }
            if ((Safe-Int64 $item.added_at) -gt $entry.AddedAt) {
                $entry.AddedAt = Safe-Int64 $item.added_at
            }

            if ($type -eq "episode") {
                $entry.EpisodeCount++

                $episodeTitle = [string]$item.title
                if (-not [string]::IsNullOrWhiteSpace($episodeTitle)) {
                    $ratingImage = Get-OptionalStringProperty -InputObject $item -Name "rating_image"
                    $ratingValue = Get-OptionalStringProperty -InputObject $item -Name "rating"
                    $audienceImage = Get-OptionalStringProperty -InputObject $item -Name "audience_rating_image"
                    $audienceValue = Get-OptionalStringProperty -InputObject $item -Name "audience_rating"
                    $selectedRating = Get-DesignProviderRating `
                        -RatingImage $ratingImage `
                        -RatingValue $ratingValue `
                        -AudienceImage $audienceImage `
                        -AudienceValue $audienceValue
                    $nativeImdbRating = ""
                    if ($selectedRating.Provider -eq "IMDb") {
                        $nativeImdbRating = $selectedRating.Value
                    }

                    $entry.Episodes.Add([PSCustomObject]@{
                        Title       = $episodeTitle
                        RatingKey   = [string]$item.rating_key
                        AddedAt     = Safe-Int64 $item.added_at
                        ImdbRating  = $nativeImdbRating
                        RatingImage = $ratingImage
                        DesignRatingProvider = $selectedRating.Provider
                        DesignRatingValue = $selectedRating.Value
                        Season      = Safe-Int $item.parent_media_index
                        Episode     = Safe-Int $item.media_index
                    })
                }
            }
            elseif ($type -eq "season") {
                $entry.SeasonCount++
            }
            elseif ($type -eq "show") {
                $entry.IsNewSeries = $true
            }
        }
    }

    $movies = @($movieList | Sort-Object AddedAt -Descending)
    $tv = @($tvMap.Values | Sort-Object AddedAt -Descending)

    foreach ($entry in $tv) {
        if ($null -ne $entry.PSObject.Properties["Episodes"]) {
            $entry.Episodes = @($entry.Episodes | Sort-Object AddedAt -Descending)
        }
    }

    return [PSCustomObject]@{
        Movies = $movies
        TV     = $tv
    }
}


function Get-TvEpisodeSnapshotFromTautulli {
    param(
        [object]$Show,
        [int]$Limit = 3,
        [int64]$StartEpoch = 0,
        [int64]$EndEpochExclusive = 0
    )

    $emptyResult = [PSCustomObject]@{
        Episodes             = @()
        TotalRecentlyAdded   = 0
        CountSource          = "none"
    }

    if ($null -eq $Show -or $Limit -lt 1) { return $emptyResult }

    $showRatingKey = [string]$Show.RatingKey
    if ([string]::IsNullOrWhiteSpace($showRatingKey)) { return $emptyResult }

    $useRecentWindow = (
        $StartEpoch -gt 0 -and
        $EndEpochExclusive -gt $StartEpoch
    )

    $episodeRows = New-Object System.Collections.Generic.List[object]
    $recentSeasonEpisodeFallback = 0

    try {
        $showChildren = Invoke-TautulliApi -Command "get_children_metadata" -Parameters @{
            rating_key = $showRatingKey
            media_type = "show"
        }

        $children = @()
        if ($null -ne $showChildren -and
            $null -ne $showChildren.PSObject.Properties["children_list"]) {
            $children = @($showChildren.children_list | Where-Object { $null -ne $_ })
        }

        $childrenType = ""
        if ($null -ne $showChildren -and
            $null -ne $showChildren.PSObject.Properties["children_type"]) {
            $childrenType = ([string]$showChildren.children_type).ToLowerInvariant()
        }

        if ($childrenType -eq "episode") {
            foreach ($row in $children) {
                $episodeRows.Add($row)
            }
        }
        else {
            # A show normally returns seasons first. For a normal backfill,
            # stop after enough candidates. For weekly-count validation, inspect
            # every season so Tautulli show/season aggregation cannot hide the
            # true number of recently-added episodes.
            $seasonRows = @(
                $children |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_.rating_key)
                } |
                Sort-Object `
                    @{ Expression = { Safe-Int64 $_.added_at }; Descending = $true },
                    @{ Expression = { Safe-Int $_.media_index }; Descending = $true }
            )

            foreach ($season in $seasonRows) {
                $seasonKey = [string]$season.rating_key
                if ([string]::IsNullOrWhiteSpace($seasonKey)) { continue }

                try {
                    $seasonChildren = Invoke-TautulliApi -Command "get_children_metadata" -Parameters @{
                        rating_key = $seasonKey
                        media_type = "season"
                    }

                    $seasonEpisodes = @()
                    if ($null -ne $seasonChildren -and
                        $null -ne $seasonChildren.PSObject.Properties["children_list"]) {
                        $seasonEpisodes = @(
                            $seasonChildren.children_list |
                            Where-Object { $null -ne $_ }
                        )
                    }

                    foreach ($episodeRow in $seasonEpisodes) {
                        $episodeRows.Add($episodeRow)
                    }

                    # Some Tautulli/Plex combinations expose a reliable recent
                    # timestamp on the season row while child episode timestamps
                    # are missing or flattened. Keep this as a count fallback.
                    if ($useRecentWindow) {
                        $seasonAddedAt = Safe-Int64 $season.added_at
                        if ($seasonAddedAt -ge $StartEpoch -and
                            $seasonAddedAt -lt $EndEpochExclusive) {
                            $recentSeasonEpisodeFallback += $seasonEpisodes.Count
                        }
                    }
                }
                catch {
                    Write-Log ("Could not resolve episodes for TV season rating key {0}: {1}" -f `
                        $seasonKey,
                        $_.Exception.Message
                    ) "WARN"
                }

                if (-not $useRecentWindow -and $episodeRows.Count -ge $Limit) {
                    break
                }
            }
        }
    }
    catch {
        Write-Log ("Could not resolve TV episode snapshot for '{0}' ({1}): {2}" -f `
            [string]$Show.Title,
            $showRatingKey,
            $_.Exception.Message
        ) "WARN"
        return $emptyResult
    }

    if ($episodeRows.Count -eq 0) { return $emptyResult }

    $ordered = @(
        $episodeRows |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.title)
        } |
        Sort-Object `
            @{ Expression = { Safe-Int64 $_.added_at }; Descending = $true },
            @{ Expression = { Safe-Int $_.parent_media_index }; Descending = $true },
            @{ Expression = { Safe-Int $_.media_index }; Descending = $true }
    )

    if ($ordered.Count -eq 0) { return $emptyResult }

    $recentRows = @()
    if ($useRecentWindow) {
        $recentRows = @(
            $ordered |
            Where-Object {
                $addedAt = Safe-Int64 $_.added_at
                $addedAt -ge $StartEpoch -and
                $addedAt -lt $EndEpochExclusive
            }
        )
    }

    # For weekly cards, show the newest episodes from the weekly window when
    # available. If timestamps are unavailable, retain the existing latest-
    # episode backfill behavior while leaving EpisodeCount as the fallback.
    $displayRows = if ($useRecentWindow -and $recentRows.Count -gt 0) {
        $recentRows
    }
    else {
        $ordered
    }

    $recentSeen = @{}
    $recentUniqueCount = 0
    foreach ($episode in $recentRows) {
        $ratingKey = [string]$episode.rating_key
        $dedupeKey = if (-not [string]::IsNullOrWhiteSpace($ratingKey)) {
            $ratingKey
        }
        else {
            "{0}:{1}:{2}" -f `
                (Safe-Int $episode.parent_media_index),
                (Safe-Int $episode.media_index),
                [string]$episode.title
        }

        if ($recentSeen.ContainsKey($dedupeKey)) { continue }
        $recentSeen[$dedupeKey] = $true
        $recentUniqueCount++
    }

    $totalRecentlyAdded = $recentUniqueCount
    $countSource = if ($recentUniqueCount -gt 0) { "episode-added-at" } else { "none" }

    if ($recentSeasonEpisodeFallback -gt $totalRecentlyAdded) {
        $totalRecentlyAdded = $recentSeasonEpisodeFallback
        $countSource = "recent-season-children"
    }

    # A brand-new show import can arrive as one show row. If child timestamps
    # are missing but the show itself is inside the window, all resolved child
    # episodes are a safer count than the three-card display limit.
    if ($useRecentWindow -and
        $totalRecentlyAdded -eq 0 -and
        $null -ne $Show.PSObject.Properties["IsNewSeries"] -and
        [bool]$Show.IsNewSeries) {

        $showAddedAt = Safe-Int64 $Show.AddedAt
        if ($showAddedAt -ge $StartEpoch -and
            $showAddedAt -lt $EndEpochExclusive) {
            $allSeen = @{}
            foreach ($episode in $ordered) {
                $ratingKey = [string]$episode.rating_key
                $dedupeKey = if (-not [string]::IsNullOrWhiteSpace($ratingKey)) {
                    $ratingKey
                }
                else {
                    "{0}:{1}:{2}" -f `
                        (Safe-Int $episode.parent_media_index),
                        (Safe-Int $episode.media_index),
                        [string]$episode.title
                }

                if ($allSeen.ContainsKey($dedupeKey)) { continue }
                $allSeen[$dedupeKey] = $true
            }

            $totalRecentlyAdded = $allSeen.Count
            if ($totalRecentlyAdded -gt 0) {
                $countSource = "new-show-child-count"
            }
        }
    }

    $shownSeen = @{}
    $result = New-Object System.Collections.Generic.List[object]

    foreach ($episode in $displayRows) {
        $ratingKey = [string]$episode.rating_key
        $seasonIndex = Safe-Int $episode.parent_media_index
        $episodeIndex = Safe-Int $episode.media_index
        $title = [string]$episode.title

        $dedupeKey = if (-not [string]::IsNullOrWhiteSpace($ratingKey)) {
            $ratingKey
        }
        else {
            "{0}:{1}:{2}" -f $seasonIndex, $episodeIndex, $title
        }

        if ($shownSeen.ContainsKey($dedupeKey)) { continue }
        $shownSeen[$dedupeKey] = $true

        $ratingImage = Get-OptionalStringProperty -InputObject $episode -Name "rating_image"
        $ratingValue = Get-OptionalStringProperty -InputObject $episode -Name "rating"
        $audienceImage = Get-OptionalStringProperty -InputObject $episode -Name "audience_rating_image"
        $audienceValue = Get-OptionalStringProperty -InputObject $episode -Name "audience_rating"
        $selectedRating = Get-DesignProviderRating `
            -RatingImage $ratingImage `
            -RatingValue $ratingValue `
            -AudienceImage $audienceImage `
            -AudienceValue $audienceValue
        $nativeImdbRating = ""
        if ($selectedRating.Provider -eq "IMDb") {
            $nativeImdbRating = $selectedRating.Value
        }

        $result.Add([PSCustomObject]@{
            Title       = $title
            RatingKey   = $ratingKey
            AddedAt     = Safe-Int64 $episode.added_at
            ImdbRating  = $nativeImdbRating
            RatingImage = $ratingImage
            DesignRatingProvider = $selectedRating.Provider
            DesignRatingValue = $selectedRating.Value
            Season      = $seasonIndex
            Episode     = $episodeIndex
        })

        if ($result.Count -ge $Limit) { break }
    }

    return [PSCustomObject]@{
        Episodes           = $result.ToArray()
        TotalRecentlyAdded = $totalRecentlyAdded
        CountSource        = $countSource
    }
}

function Merge-TvEpisodeSnapshots {
    param(
        [object[]]$ExistingEpisodes,
        [object[]]$SnapshotEpisodes,
        [int]$Limit = 3
    )

    $getFallbackIdentity = {
        param([object]$EpisodeItem)
        $season = Safe-Int (Get-OptionalStringProperty -InputObject $EpisodeItem -Name "Season")
        $episodeIndex = Safe-Int (Get-OptionalStringProperty -InputObject $EpisodeItem -Name "Episode")
        if ($season -gt 0 -and $episodeIndex -gt 0) {
            return "index:{0}:{1}" -f $season, $episodeIndex
        }
        $title = (Get-OptionalStringProperty -InputObject $EpisodeItem -Name "Title").Trim().ToLowerInvariant()
        $addedAt = Safe-Int64 (Get-OptionalStringProperty -InputObject $EpisodeItem -Name "AddedAt")
        if (-not [string]::IsNullOrWhiteSpace($title) -and $addedAt -gt 0) {
            return "title-time:{0}:{1}" -f $title, $addedAt
        }
        return ""
    }
    $getPreferredIdentity = {
        param([object]$EpisodeItem)
        $ratingKey = Get-OptionalStringProperty -InputObject $EpisodeItem -Name "RatingKey"
        if (-not [string]::IsNullOrWhiteSpace($ratingKey)) {
            return "key:" + $ratingKey
        }
        return (& $getFallbackIdentity $EpisodeItem)
    }

    $existingByRatingKey = @{}
    $existingByFallback = @{}
    foreach ($existingEpisode in @($ExistingEpisodes)) {
        $ratingKey = Get-OptionalStringProperty -InputObject $existingEpisode -Name "RatingKey"
        if (-not [string]::IsNullOrWhiteSpace($ratingKey) -and
            -not $existingByRatingKey.ContainsKey($ratingKey)) {
            $existingByRatingKey[$ratingKey] = $existingEpisode
        }
        $fallbackIdentity = & $getFallbackIdentity $existingEpisode
        if (-not [string]::IsNullOrWhiteSpace($fallbackIdentity) -and
            -not $existingByFallback.ContainsKey($fallbackIdentity)) {
            $existingByFallback[$fallbackIdentity] = $existingEpisode
        }
    }

    $merged = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($snapshotEpisode in @($SnapshotEpisodes)) {
        $ratingKey = Get-OptionalStringProperty -InputObject $snapshotEpisode -Name "RatingKey"
        $fallbackIdentity = & $getFallbackIdentity $snapshotEpisode
        $existingEpisode = $null
        $matchedExistingIdentity = ""
        if (-not [string]::IsNullOrWhiteSpace($ratingKey) -and
            $existingByRatingKey.ContainsKey($ratingKey)) {
            $existingEpisode = $existingByRatingKey[$ratingKey]
        }
        elseif (-not [string]::IsNullOrWhiteSpace($fallbackIdentity) -and
            $existingByFallback.ContainsKey($fallbackIdentity)) {
            $existingEpisode = $existingByFallback[$fallbackIdentity]
        }

        if ($null -ne $existingEpisode) {
            foreach ($fieldName in @("RatingKey", "Title")) {
                $snapshotValue = Get-OptionalStringProperty -InputObject $snapshotEpisode -Name $fieldName
                $existingValue = Get-OptionalStringProperty -InputObject $existingEpisode -Name $fieldName
                if ([string]::IsNullOrWhiteSpace($snapshotValue) -and
                    -not [string]::IsNullOrWhiteSpace($existingValue)) {
                    $snapshotEpisode | Add-Member -NotePropertyName $fieldName -NotePropertyValue $existingValue -Force
                }
            }
            foreach ($fieldName in @("Season", "Episode", "AddedAt")) {
                $snapshotValue = Safe-Int64 (Get-OptionalStringProperty -InputObject $snapshotEpisode -Name $fieldName)
                $existingValue = Safe-Int64 (Get-OptionalStringProperty -InputObject $existingEpisode -Name $fieldName)
                if ($snapshotValue -le 0 -and $existingValue -gt 0) {
                    $snapshotEpisode | Add-Member -NotePropertyName $fieldName -NotePropertyValue $existingValue -Force
                }
            }

            $snapshotImdb = Get-OptionalStringProperty -InputObject $snapshotEpisode -Name "ImdbRating"
            $existingImdb = Get-OptionalStringProperty -InputObject $existingEpisode -Name "ImdbRating"
            if ([string]::IsNullOrWhiteSpace($snapshotImdb) -and
                -not [string]::IsNullOrWhiteSpace($existingImdb)) {
                $snapshotEpisode | Add-Member -NotePropertyName "ImdbRating" -NotePropertyValue $existingImdb -Force
            }

            $snapshotProvider = Get-OptionalStringProperty -InputObject $snapshotEpisode -Name "DesignRatingProvider"
            $snapshotProviderValue = Get-OptionalStringProperty -InputObject $snapshotEpisode -Name "DesignRatingValue"
            $existingProvider = Get-OptionalStringProperty -InputObject $existingEpisode -Name "DesignRatingProvider"
            $existingProviderValue = Get-OptionalStringProperty -InputObject $existingEpisode -Name "DesignRatingValue"
            $snapshotPairAvailable = (-not [string]::IsNullOrWhiteSpace($snapshotProvider) -and -not [string]::IsNullOrWhiteSpace($snapshotProviderValue))
            $existingPairAvailable = (-not [string]::IsNullOrWhiteSpace($existingProvider) -and -not [string]::IsNullOrWhiteSpace($existingProviderValue))
            $snapshotRatingImage = Get-OptionalStringProperty -InputObject $snapshotEpisode -Name "RatingImage"
            $existingRatingImage = Get-OptionalStringProperty -InputObject $existingEpisode -Name "RatingImage"
            if (-not $snapshotPairAvailable -and $existingPairAvailable) {
                $snapshotEpisode | Add-Member -NotePropertyName "DesignRatingProvider" -NotePropertyValue $existingProvider -Force
                $snapshotEpisode | Add-Member -NotePropertyName "DesignRatingValue" -NotePropertyValue $existingProviderValue -Force
                $snapshotEpisode | Add-Member -NotePropertyName "RatingImage" -NotePropertyValue $existingRatingImage -Force
            }
            elseif ($snapshotPairAvailable -and [string]::IsNullOrWhiteSpace($snapshotRatingImage) -and
                $existingPairAvailable -and $snapshotProvider -eq $existingProvider -and
                -not [string]::IsNullOrWhiteSpace($existingRatingImage)) {
                $snapshotEpisode | Add-Member -NotePropertyName "RatingImage" -NotePropertyValue $existingRatingImage -Force
            }

            $matchedExistingIdentity = & $getPreferredIdentity $existingEpisode
        }

        $identity = & $getPreferredIdentity $snapshotEpisode
        if ([string]::IsNullOrWhiteSpace($identity) -or -not $seen.ContainsKey($identity)) {
            if (-not [string]::IsNullOrWhiteSpace($identity)) { $seen[$identity] = $true }
            $merged.Add($snapshotEpisode)
        }
        if (-not [string]::IsNullOrWhiteSpace($matchedExistingIdentity)) { $seen[$matchedExistingIdentity] = $true }
    }
    foreach ($existingEpisode in @($ExistingEpisodes)) {
        $identity = & $getPreferredIdentity $existingEpisode
        if ([string]::IsNullOrWhiteSpace($identity) -or -not $seen.ContainsKey($identity)) {
            if (-not [string]::IsNullOrWhiteSpace($identity)) { $seen[$identity] = $true }
            $merged.Add($existingEpisode)
        }
    }

    return @($merged | Sort-Object AddedAt -Descending | Select-Object -First $Limit)
}

function Enrich-TvEpisodeMetadata {
    param(
        [object]$ReleaseData,
        [string]$ContextLabel = "TV",
        [int64]$StartEpoch = 0,
        [int64]$EndEpochExclusive = 0,
        [bool]$CountRecentEpisodes = $false
    )

    if ($null -eq $ReleaseData -or $null -eq $ReleaseData.TV) { return }

    $cache = @{}
    $lookups = 0
    $imdbFound = 0
    $rtFound = 0

    foreach ($show in @($ReleaseData.TV)) {
        # Tautulli can represent a weekly TV import as episode rows, one
        # season row, or one show row. When weekly counting is enabled, inspect
        # child metadata so the three-row display limit does not become the
        # reported total.
        $existingEpisodes = @()
        if ($null -ne $show.PSObject.Properties["Episodes"]) {
            $existingEpisodes = @($show.Episodes)
        }

        $needsSnapshot = (
            $existingEpisodes.Count -eq 0 -or
            $CountRecentEpisodes
        )

        if ($needsSnapshot) {
            $snapshot = Get-TvEpisodeSnapshotFromTautulli `
                -Show $show `
                -Limit 3 `
                -StartEpoch $(if ($CountRecentEpisodes) { $StartEpoch } else { 0 }) `
                -EndEpochExclusive $(if ($CountRecentEpisodes) { $EndEpochExclusive } else { 0 })

            $snapshotEpisodes = @($snapshot.Episodes)
            if ($snapshotEpisodes.Count -gt 0) {
                $show.Episodes = @(Merge-TvEpisodeSnapshots -ExistingEpisodes $existingEpisodes -SnapshotEpisodes $snapshotEpisodes -Limit 3)
                Write-Log ("TV episode snapshot: {0} -> {1} displayed episode(s)." -f `
                    [string]$show.Title,
                    @($show.Episodes).Count
                )
            }

            if ($CountRecentEpisodes) {
                $existingCount = Safe-Int $show.EpisodeCount
                $snapshotCount = Safe-Int $snapshot.TotalRecentlyAdded
                $resolvedCount = [Math]::Max($existingCount, $snapshotCount)
                $show.EpisodeCount = $resolvedCount

                Write-Log ("TV recent count: {0} -> {1} episode(s), source={2}, original={3}." -f `
                    [string]$show.Title,
                    $resolvedCount,
                    [string]$snapshot.CountSource,
                    $existingCount
                )
            }
        }

        if ($null -eq $show.PSObject.Properties["Episodes"]) { continue }

        foreach ($episode in @($show.Episodes)) {
            $ratingKey = [string]$episode.RatingKey
            if ([string]::IsNullOrWhiteSpace($ratingKey)) { continue }

            $meta = $null
            if ($cache.ContainsKey($ratingKey)) {
                $meta = $cache[$ratingKey]
            }
            else {
                try {
                    $meta = Invoke-TautulliApi -Command "get_metadata" -Parameters @{
                        rating_key = $ratingKey
                    }
                    $cache[$ratingKey] = $meta
                    $lookups++
                }
                catch {
                    Write-Log ("Rating lookup failed for episode rating key {0}: {1}" -f $ratingKey, $_.Exception.Message) "WARN"
                    continue
                }
            }

            if ($null -eq $meta) { continue }

            # get_metadata is the authoritative item-level source for the
            # episode index and selected Plex rating provider.
            $episodeIndex = Safe-Int $meta.media_index
            $seasonIndex = Safe-Int $meta.parent_media_index

            if ($episodeIndex -gt 0) {
                $episode.Episode = $episodeIndex
            }
            if ($seasonIndex -gt 0) {
                $episode.Season = $seasonIndex
            }

            $ratingImage = Get-OptionalStringProperty -InputObject $meta -Name "rating_image"
            $ratingValue = Get-OptionalStringProperty -InputObject $meta -Name "rating"
            $audienceImage = Get-OptionalStringProperty -InputObject $meta -Name "audience_rating_image"
            $audienceValue = Get-OptionalStringProperty -InputObject $meta -Name "audience_rating"
            $selectedRating = Get-DesignProviderRating `
                -RatingImage $ratingImage `
                -RatingValue $ratingValue `
                -AudienceImage $audienceImage `
                -AudienceValue $audienceValue
            $selectedRatingAvailable = (
                -not [string]::IsNullOrWhiteSpace([string]$selectedRating.Provider) -and
                -not [string]::IsNullOrWhiteSpace([string]$selectedRating.Value)
            )
            if ($selectedRatingAvailable) {
                if (-not [string]::IsNullOrWhiteSpace($ratingImage)) {
                    $episode.RatingImage = $ratingImage
                }
                $episode | Add-Member -NotePropertyName "DesignRatingProvider" -NotePropertyValue $selectedRating.Provider -Force
                $episode | Add-Member -NotePropertyName "DesignRatingValue" -NotePropertyValue $selectedRating.Value -Force
            }

            # Fast path: Tautulli explicitly identifies IMDb as the selected
            # episode rating provider. Otherwise retain an exact IMDb value
            # already returned by recently-added or child metadata.
            if ($selectedRating.Provider -eq "IMDb" -and $selectedRatingAvailable) {
                $episode.ImdbRating = $selectedRating.Value
            }

            # Plex UI can show IMDb alongside other providers even when
            # Tautulli's flattened rating_image does not select IMDb.
            # Fall back to Plex's native Rating[] / legacy XML metadata.
            if ([string]::IsNullOrWhiteSpace([string]$episode.ImdbRating)) {
                $episode.ImdbRating = Get-DesignEpisodeImdbRating `
                    -RatingKey $ratingKey `
                    -TautulliMetadata $meta
            }

            # Exact-episode IMDb remains the first choice. If neither the
            # selected Tautulli fields nor Plex's provider array has IMDb, use
            # an exact-episode RT critic score (then audience) rather than a
            # show-level or unrelated provider value.
            $episodeRt = [PSCustomObject]@{ Value = ""; Image = ""; Kind = "" }
            if ([string]::IsNullOrWhiteSpace([string]$episode.ImdbRating)) {
                $episodeRt = Get-DesignEpisodeRtRating `
                    -RatingKey $ratingKey `
                    -TautulliMetadata $meta
            }
            $episode | Add-Member -NotePropertyName "RtRating" -NotePropertyValue ([string]$episodeRt.Value) -Force
            $episode | Add-Member -NotePropertyName "RtRatingImage" -NotePropertyValue ([string]$episodeRt.Image) -Force
            $episode | Add-Member -NotePropertyName "RtRatingKind" -NotePropertyValue ([string]$episodeRt.Kind) -Force

            if (-not [string]::IsNullOrWhiteSpace([string]$episode.ImdbRating)) {
                $imdbFound++
                Write-Log ("TV IMDb: {0} S{1}E{2} '{3}' -> {4}" -f `
                    $show.Title,
                    $episode.Season,
                    $episode.Episode,
                    $episode.Title,
                    $episode.ImdbRating
                )
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$episode.RtRating)) {
                $rtFound++
                Write-Log ("TV RT fallback: {0} S{1}E{2} '{3}' -> {4} {5}%" -f `
                    $show.Title,
                    $episode.Season,
                    $episode.Episode,
                    $episode.Title,
                    $episode.RtRatingKind,
                    $episode.RtRating
                )
            }
        }
    }

    Write-Log ("{0} episode metadata enrichment: {1} get_metadata lookup(s), {2} IMDb rating(s), {3} RT fallback(s) found." -f `
        $ContextLabel,
        $lookups,
        $imdbFound,
        $rtFound
    )
}

function Get-LatestReleaseData {
    param(
        [int]$MovieLimit = 4,
        [int]$TvLimit = 4,
        [int64]$TvAddedAfterEpoch = 0
    )

    $all = New-Object System.Collections.Generic.List[object]
    $pageSize = 100
    $maxPages = 10

    foreach ($sectionId in @(Get-LatestReleaseQueryScopes)) {
        $start = 0
        $scopeRows = New-Object System.Collections.Generic.List[object]
        for ($page = 0; $page -lt $maxPages; $page++) {
            $params = @{ count = $pageSize; start = $start }
            if (-not [string]::IsNullOrWhiteSpace($sectionId)) { $params.section_id = $sectionId }
            $data = Invoke-TautulliApi -Command "get_recently_added" -Parameters $params
            $rows = @($data.recently_added)
            if ($rows.Count -eq 0) { break }
            foreach ($row in $rows) {
                if (Test-IncludedLibraryRow -Row $row -ExpectedSectionId $sectionId) {
                    $all.Add($row)
                    $scopeRows.Add($row)
                }
            }
            $scopeSnapshot = New-ReleaseData -RecentItems $scopeRows.ToArray()
            $isSectionScope = -not [string]::IsNullOrWhiteSpace($sectionId)
            $enoughForScope = if ($script:LibraryFilterEnabled -or $isSectionScope) { ($scopeSnapshot.Movies.Count -ge $MovieLimit -or $scopeSnapshot.TV.Count -ge $TvLimit) } else { ($scopeSnapshot.Movies.Count -ge $MovieLimit -and $scopeSnapshot.TV.Count -ge $TvLimit) }
            if ($enoughForScope) { break }
            if ($rows.Count -lt $pageSize) { break }
            $start += $rows.Count
        }
    }

    $result = New-ReleaseData -RecentItems $all.ToArray()
    $recentTv = @(
        $result.TV |
        Where-Object {
            $TvAddedAfterEpoch -le 0 -or
            (Safe-Int64 $_.AddedAt) -gt $TvAddedAfterEpoch
        }
    )

    return [PSCustomObject]@{
        Movies = @($result.Movies | Select-Object -First $MovieLimit)
        TV     = @($recentTv | Select-Object -First $TvLimit)
    }
}

function Get-UserStats {
    param(
        [object[]]$History
    )

    $watchedThreshold = if ($null -ne $Config.PSObject.Properties["WatchedPercent"]) {
        Safe-Int $Config.WatchedPercent
    } else { 85 }

    $moviesWatched = 0
    $episodesStreamed = 0
    $qualifyingPlays = 0
    [int64]$totalSeconds = 0
    $titleTotals = @{}
    $movieItemTotals = @{}
    $tvShowTotals = @{}
    $episodeSeen = @{}
    $episodeItems = New-Object System.Collections.Generic.List[object]

    foreach ($row in $History) {
        $type = ([string]$row.media_type).ToLowerInvariant()
        $seconds = [int64](Safe-Int $row.play_duration)
        if ($seconds -lt 0) { $seconds = 0 }

        if ($type -in @("movie","episode")) {
            $totalSeconds += $seconds
        }

        if ($type -eq "movie") {
            $qualified = Test-HistoryRowQualifiedView -Row $row -WatchedThreshold $watchedThreshold

            if ($qualified) {
                $moviesWatched++
                $qualifyingPlays += (Get-HistoryRowPlayCount -Row $row)

                $ratingKey = [string]$row.rating_key
                $title = [string]$row.title
                $dedupeKey = if (-not [string]::IsNullOrWhiteSpace($ratingKey)) {
                    "movie:" + $ratingKey
                } else {
                    "movie:title:" + $title.ToLowerInvariant()
                }

                $rowMovieSummary = Get-OptionalStringProperty -InputObject $row -Name "summary"
                $rowMovieYear = Get-OptionalStringProperty -InputObject $row -Name "year"
                $rowMovieRating = Get-OptionalStringProperty -InputObject $row -Name "rating"
                $rowMovieRatingImage = Get-OptionalStringProperty -InputObject $row -Name "rating_image"
                $rowMovieAudience = Get-OptionalStringProperty -InputObject $row -Name "audience_rating"
                $rowMovieAudienceImage = Get-OptionalStringProperty -InputObject $row -Name "audience_rating_image"
                $rowMovieGenres = @(if ($null -ne $row.PSObject.Properties["genres"]) {
                    ConvertTo-DesignGenreList -Value $row.genres
                })
                $rowMovieRatingPairAvailable = (
                    -not [string]::IsNullOrWhiteSpace($rowMovieRating) -and
                    -not [string]::IsNullOrWhiteSpace($rowMovieRatingImage)
                )
                $rowMovieAudiencePairAvailable = (
                    -not [string]::IsNullOrWhiteSpace($rowMovieAudience) -and
                    -not [string]::IsNullOrWhiteSpace($rowMovieAudienceImage)
                )

                if (-not $movieItemTotals.ContainsKey($dedupeKey)) {
                    $movieItemTotals[$dedupeKey] = [PSCustomObject]@{
                        Type            = "movie"
                        RatingKey       = $ratingKey
                        PosterRatingKey = $ratingKey
                        MetadataGuid    = Get-OptionalStringProperty -InputObject $row -Name "guid"
                        Title           = $title
                        Summary         = $rowMovieSummary
                        Year            = $rowMovieYear
                        Rating          = if ($rowMovieRatingPairAvailable) { $rowMovieRating } else { "" }
                        RatingImage     = if ($rowMovieRatingPairAvailable) { $rowMovieRatingImage } else { "" }
                        AudienceRating  = if ($rowMovieAudiencePairAvailable) { $rowMovieAudience } else { "" }
                        AudienceRatingImage = if ($rowMovieAudiencePairAvailable) { $rowMovieAudienceImage } else { "" }
                        DesignGenres    = @($rowMovieGenres)
                        Plays           = 0
                        Seconds         = [int64]0
                    }
                }
                if ([string]::IsNullOrWhiteSpace([string]$movieItemTotals[$dedupeKey].MetadataGuid)) {
                    $movieItemTotals[$dedupeKey].MetadataGuid = Get-OptionalStringProperty -InputObject $row -Name "guid"
                }
                $movieEntry = $movieItemTotals[$dedupeKey]
                if ([string]::IsNullOrWhiteSpace([string]$movieEntry.Summary) -and
                    -not [string]::IsNullOrWhiteSpace($rowMovieSummary)) {
                    $movieEntry.Summary = $rowMovieSummary
                }
                if ([string]::IsNullOrWhiteSpace([string]$movieEntry.Year) -and
                    -not [string]::IsNullOrWhiteSpace($rowMovieYear)) {
                    $movieEntry.Year = $rowMovieYear
                }
                if (@($movieEntry.DesignGenres).Count -eq 0 -and $rowMovieGenres.Count -gt 0) {
                    $movieEntry.DesignGenres = @($rowMovieGenres)
                }
                $movieRatingPairAvailable = (
                    -not [string]::IsNullOrWhiteSpace([string]$movieEntry.Rating) -and
                    -not [string]::IsNullOrWhiteSpace([string]$movieEntry.RatingImage)
                )
                if (-not $movieRatingPairAvailable -and $rowMovieRatingPairAvailable) {
                    $movieEntry.Rating = $rowMovieRating
                    $movieEntry.RatingImage = $rowMovieRatingImage
                }
                $movieAudiencePairAvailable = (
                    -not [string]::IsNullOrWhiteSpace([string]$movieEntry.AudienceRating) -and
                    -not [string]::IsNullOrWhiteSpace([string]$movieEntry.AudienceRatingImage)
                )
                if (-not $movieAudiencePairAvailable -and $rowMovieAudiencePairAvailable) {
                    $movieEntry.AudienceRating = $rowMovieAudience
                    $movieEntry.AudienceRatingImage = $rowMovieAudienceImage
                }
                $movieItemTotals[$dedupeKey].Plays += (Get-HistoryRowPlayCount -Row $row)
                $movieItemTotals[$dedupeKey].Seconds += $seconds
            }

            $topTitle = [string]$row.title
            if ($qualified -and -not [string]::IsNullOrWhiteSpace($topTitle) -and $seconds -gt 0) {
                $key = "movie:" + $topTitle
                if (-not $titleTotals.ContainsKey($key)) {
                    $titleTotals[$key] = [PSCustomObject]@{
                        Title   = $topTitle
                        Seconds = [int64]0
                    }
                }
                $titleTotals[$key].Seconds += $seconds
            }
        }
        elseif ($type -eq "episode") {
            $qualified = Test-HistoryRowQualifiedView -Row $row -WatchedThreshold $watchedThreshold

            if ($qualified) {
                $episodesStreamed++
                $qualifyingPlays += (Get-HistoryRowPlayCount -Row $row)

                $ratingKey = [string]$row.rating_key
                $showRatingKey = [string]$row.grandparent_rating_key
                $showTitle = [string]$row.grandparent_title
                if ([string]::IsNullOrWhiteSpace($showTitle)) {
                    $showTitle = [string]$row.parent_title
                }
                $episodeTitle = [string]$row.title

                $showDedupeKey = if (-not [string]::IsNullOrWhiteSpace($showRatingKey)) {
                    "show:" + $showRatingKey
                } else {
                    "show:title:" + $showTitle.ToLowerInvariant()
                }
                $rowShowSummary = Get-OptionalStringProperty -InputObject $row -Name "grandparent_summary"
                $rowShowYear = Get-OptionalStringProperty -InputObject $row -Name "grandparent_year"
                $rowShowRating = Get-OptionalStringProperty -InputObject $row -Name "grandparent_rating"
                $rowShowRatingImage = Get-OptionalStringProperty -InputObject $row -Name "grandparent_rating_image"
                $rowShowAudience = Get-OptionalStringProperty -InputObject $row -Name "grandparent_audience_rating"
                $rowShowAudienceImage = Get-OptionalStringProperty -InputObject $row -Name "grandparent_audience_rating_image"
                $rowShowGenres = @(if ($null -ne $row.PSObject.Properties["grandparent_genres"]) {
                    ConvertTo-DesignGenreList -Value $row.grandparent_genres
                })
                $rowShowRatingPairAvailable = (
                    -not [string]::IsNullOrWhiteSpace($rowShowRating) -and
                    -not [string]::IsNullOrWhiteSpace($rowShowRatingImage)
                )
                $rowShowAudiencePairAvailable = (
                    -not [string]::IsNullOrWhiteSpace($rowShowAudience) -and
                    -not [string]::IsNullOrWhiteSpace($rowShowAudienceImage)
                )
                if (-not $tvShowTotals.ContainsKey($showDedupeKey)) {
                    $tvShowTotals[$showDedupeKey] = [PSCustomObject]@{
                        Type            = "show"
                        RatingKey       = $showRatingKey
                        PosterRatingKey = $showRatingKey
                        MetadataGuid    = Get-OptionalStringProperty -InputObject $row -Name "guid"
                        MetadataParentIndex = Safe-Int (Get-OptionalStringProperty -InputObject $row -Name "parent_media_index")
                        MetadataIndex   = Safe-Int (Get-OptionalStringProperty -InputObject $row -Name "media_index")
                        Title           = $showTitle
                        ShowTitle       = $showTitle
                        Summary         = $rowShowSummary
                        Year            = $rowShowYear
                        Rating          = if ($rowShowRatingPairAvailable) { $rowShowRating } else { "" }
                        RatingImage     = if ($rowShowRatingPairAvailable) { $rowShowRatingImage } else { "" }
                        AudienceRating  = if ($rowShowAudiencePairAvailable) { $rowShowAudience } else { "" }
                        AudienceRatingImage = if ($rowShowAudiencePairAvailable) { $rowShowAudienceImage } else { "" }
                        DesignGenres    = @($rowShowGenres)
                        Plays           = 0
                        Seconds         = [int64]0
                        EpisodeCount    = 0
                        TotalTimeText   = ""
                    }
                }
                if ([string]::IsNullOrWhiteSpace([string]$tvShowTotals[$showDedupeKey].MetadataGuid)) {
                    $tvShowTotals[$showDedupeKey].MetadataGuid = Get-OptionalStringProperty -InputObject $row -Name "guid"
                    $tvShowTotals[$showDedupeKey].MetadataParentIndex = Safe-Int (Get-OptionalStringProperty -InputObject $row -Name "parent_media_index")
                    $tvShowTotals[$showDedupeKey].MetadataIndex = Safe-Int (Get-OptionalStringProperty -InputObject $row -Name "media_index")
                }
                $showEntry = $tvShowTotals[$showDedupeKey]
                if ([string]::IsNullOrWhiteSpace([string]$showEntry.Summary) -and
                    -not [string]::IsNullOrWhiteSpace($rowShowSummary)) {
                    $showEntry.Summary = $rowShowSummary
                }
                if ([string]::IsNullOrWhiteSpace([string]$showEntry.Year) -and
                    -not [string]::IsNullOrWhiteSpace($rowShowYear)) {
                    $showEntry.Year = $rowShowYear
                }
                if (@($showEntry.DesignGenres).Count -eq 0 -and $rowShowGenres.Count -gt 0) {
                    $showEntry.DesignGenres = @($rowShowGenres)
                }
                $showRatingPairAvailable = (
                    -not [string]::IsNullOrWhiteSpace([string]$showEntry.Rating) -and
                    -not [string]::IsNullOrWhiteSpace([string]$showEntry.RatingImage)
                )
                if (-not $showRatingPairAvailable -and $rowShowRatingPairAvailable) {
                    $showEntry.Rating = $rowShowRating
                    $showEntry.RatingImage = $rowShowRatingImage
                }
                $showAudiencePairAvailable = (
                    -not [string]::IsNullOrWhiteSpace([string]$showEntry.AudienceRating) -and
                    -not [string]::IsNullOrWhiteSpace([string]$showEntry.AudienceRatingImage)
                )
                if (-not $showAudiencePairAvailable -and $rowShowAudiencePairAvailable) {
                    $showEntry.AudienceRating = $rowShowAudience
                    $showEntry.AudienceRatingImage = $rowShowAudienceImage
                }
                $tvShowTotals[$showDedupeKey].Plays += (Get-HistoryRowPlayCount -Row $row)
                $tvShowTotals[$showDedupeKey].Seconds += $seconds
                $dedupeKey = if (-not [string]::IsNullOrWhiteSpace($ratingKey)) {
                    "episode:" + $ratingKey
                } else {
                    "episode:{0}:{1}:{2}" -f `
                        (Safe-Int $row.parent_media_index),
                        (Safe-Int $row.media_index),
                        $episodeTitle.ToLowerInvariant()
                }

                if (-not $episodeSeen.ContainsKey($dedupeKey)) {
                    $episodeSeen[$dedupeKey] = $true
                    $tvShowTotals[$showDedupeKey].EpisodeCount++

                    $nativeImdb = ""
                    $ratingImage = Get-OptionalStringProperty -InputObject $row -Name "rating_image"
                    $ratingValue = Get-OptionalStringProperty -InputObject $row -Name "rating"
                    $audienceImage = Get-OptionalStringProperty -InputObject $row -Name "audience_rating_image"
                    $audienceValue = Get-OptionalStringProperty -InputObject $row -Name "audience_rating"
                    $selectedRating = Get-DesignProviderRating `
                        -RatingImage $ratingImage `
                        -RatingValue $ratingValue `
                        -AudienceImage $audienceImage `
                        -AudienceValue $audienceValue
                    if ($selectedRating.Provider -eq "IMDb") {
                        $nativeImdb = $selectedRating.Value
                    }

                    $episodeItems.Add([PSCustomObject]@{
                        Type            = "episode"
                        RatingKey       = $ratingKey
                        PosterRatingKey = $showRatingKey
                        MetadataGuid    = Get-OptionalStringProperty -InputObject $row -Name "guid"
                        ShowTitle       = $showTitle
                        EpisodeTitle    = $episodeTitle
                        Season          = Safe-Int $row.parent_media_index
                        Episode         = Safe-Int $row.media_index
                        ImdbRating      = $nativeImdb
                        DesignRatingProvider = $selectedRating.Provider
                        DesignRatingValue = $selectedRating.Value
                        Plays           = Get-HistoryRowPlayCount -Row $row
                    })
                }
            }

            $showTitleForTop = [string]$row.grandparent_title
            if ([string]::IsNullOrWhiteSpace($showTitleForTop)) {
                $showTitleForTop = [string]$row.title
            }

            if ($qualified -and -not [string]::IsNullOrWhiteSpace($showTitleForTop) -and $seconds -gt 0) {
                $key = "show:" + $showTitleForTop
                if (-not $titleTotals.ContainsKey($key)) {
                    $titleTotals[$key] = [PSCustomObject]@{
                        Title   = $showTitleForTop
                        Seconds = [int64]0
                    }
                }
                $titleTotals[$key].Seconds += $seconds
            }
        }
    }

    $rankedMovieItems = @($movieItemTotals.Values | Sort-Object Seconds, Plays -Descending)
    $rankedTvShowItems = @($tvShowTotals.Values | Sort-Object Seconds, Plays -Descending)
    foreach ($showItem in $rankedTvShowItems) {
        $showItem.TotalTimeText = Format-WatchTime ([int64]$showItem.Seconds)
    }

    $top = @($titleTotals.Values | Sort-Object Seconds -Descending | Select-Object -First 1)
    $topTitleValue = if ($top.Count -gt 0) { [string]$top[0].Title } else { "" }

    return [PSCustomObject]@{
        MoviesWatched        = $moviesWatched
        EpisodesStreamed     = $episodesStreamed
        QualifyingPlays      = $qualifyingPlays
        TotalSeconds         = $totalSeconds
        TotalTimeText        = Format-WatchTime $totalSeconds
        MostWatched          = $topTitleValue
        MovieItems           = $rankedMovieItems
        EpisodeItems         = $episodeItems.ToArray()
        TvShowItems          = $rankedTvShowItems
    }
}

function Add-UserStatsMediaMetadata {
    param([object]$Stats)

    if ($null -eq $Stats) { return }

    $movies = @()
    $tvShows = @()
    if ($null -ne $Stats.PSObject.Properties["MovieItems"]) {
        $movies = @($Stats.MovieItems)
    }
    if ($null -ne $Stats.PSObject.Properties["TvShowItems"]) {
        $tvShows = @($Stats.TvShowItems)
    }

    if ($movies.Count -gt 0 -or $tvShows.Count -gt 0) {
        Add-DesignRatingMetadata -ReleaseData ([PSCustomObject]@{
            Movies = $movies
            TV     = $tvShows
        })
    }
}

function Get-HotNewRelease {
    param(
        [object]$ReleaseData,
        [object[]]$GlobalHistory
    )

    $watchedThreshold = if ($null -ne $Config.PSObject.Properties["WatchedPercent"]) {
        Safe-Int $Config.WatchedPercent
    } else { 85 }

    $lookup = @{}

    foreach ($m in @($ReleaseData.Movies)) {
        $lookup[$m.ReleaseKey] = [PSCustomObject]@{
            Item       = $m
            Seconds    = [int64]0
            Plays      = 0
            ViewerKeys = @{}
        }
    }

    foreach ($row in $GlobalHistory) {
        $type = ([string]$row.media_type).ToLowerInvariant()
        if ($type -ne "movie") { continue }
        if (-not (Test-HistoryRowQualifiedView -Row $row -WatchedThreshold $watchedThreshold)) { continue }

        $ratingKey = ([string]$row.rating_key).Trim()
        if ([string]::IsNullOrWhiteSpace($ratingKey)) { continue }
        $key = "movie:" + $ratingKey
        if (-not $lookup.ContainsKey($key)) { continue }

        $seconds = [int64](Safe-Int $row.play_duration)
        if ($seconds -lt 0) { $seconds = 0 }
        $lookup[$key].Seconds += $seconds
        $lookup[$key].Plays += (Get-HistoryRowPlayCount -Row $row)

        $viewerKey = Get-HistoryRowViewerKey -Row $row
        if (-not [string]::IsNullOrWhiteSpace($viewerKey)) {
            $lookup[$key].ViewerKeys[$viewerKey] = $true
        }
    }

    $watched = @(
        $lookup.Values |
        Where-Object { $_.Plays -gt 0 } |
        Sort-Object `
            @{ Expression = { Safe-Int $_.Plays }; Descending = $true }, `
            @{ Expression = { $_.ViewerKeys.Count }; Descending = $true }, `
            @{ Expression = { [int64]$_.Seconds }; Descending = $true }, `
            @{ Expression = { [int64]$_.Item.AddedAt }; Descending = $true } |
        Select-Object -First 1
    )

    if ($watched.Count -gt 0) {
        $winner = $watched[0]
        return [PSCustomObject]@{
            Item      = $winner.Item
            Seconds   = $winner.Seconds
            Plays     = $winner.Plays
            IsPopular = $true
            IsTrending = $false
        }
    }

    # Fresh-install fallback: feature the newest addition until enough
    # Tautulli history exists to rank new releases by viewing activity.
    $newest = @($ReleaseData.Movies | Sort-Object AddedAt -Descending | Select-Object -First 1)
    if ($newest.Count -gt 0) {
        return [PSCustomObject]@{
            Item      = $newest[0]
            Seconds   = [int64]0
            Plays     = 0
            IsPopular = $false
            IsTrending = $false
        }
    }

    return $null
}

function Get-HistoryRowPlayCount {
    param([object]$Row)

    # With grouping enabled, each returned Tautulli reference represents one
    # play session. group_count describes grouped fragments and must not turn a
    # resumed session into multiple newsletter plays.
    return 1
}

function Test-HistoryRowQualifiedView {
    param(
        [AllowNull()][object]$Row,
        [int]$WatchedThreshold = 85
    )

    if ($null -eq $Row) { return $false }
    return (
        (Safe-Int $Row.watched_status) -eq 1 -or
        (Safe-Int $Row.percent_complete) -ge $WatchedThreshold
    )
}

function Get-HistoryRowViewerKey {
    param([AllowNull()][object]$Row)

    if ($null -eq $Row) { return "" }
    foreach ($propertyName in @("user_id", "userId")) {
        $value = (Get-OptionalStringProperty -InputObject $Row -Name $propertyName).Trim()
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return "id:" + $value
        }
    }
    foreach ($propertyName in @("user", "username", "friendly_name")) {
        $value = (Get-OptionalStringProperty -InputObject $Row -Name $propertyName).Trim()
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return "name:" + $value.ToLowerInvariant()
        }
    }

    return ""
}

function Get-NewsletterPlatformCatalog {
    # Keep aliases conservative and aligned with the platform families Tautulli
    # reports. Labels, filenames, and CIDs are fixed here so untrusted history
    # values never flow into HTML attributes or local paths.
    return @(
        [PSCustomObject]@{ Key = "android"; Label = "Android"; FileName = "platform-android.png"; Cid = "platform_android"; Aliases = @("android", "android tv", "google tv", "nexus") },
        [PSCustomObject]@{ Key = "apple-tv"; Label = "Apple TV"; FileName = "platform-apple-tv.png"; Cid = "platform_apple_tv"; Aliases = @("apple tv", "appletv", "atv", "tvos") },
        [PSCustomObject]@{ Key = "chrome"; Label = "Chrome"; FileName = "platform-chrome.png"; Cid = "platform_chrome"; Aliases = @("chrome", "chrome os", "chromium", "google chrome") },
        [PSCustomObject]@{ Key = "chromecast"; Label = "Chromecast"; FileName = "platform-chromecast.png"; Cid = "platform_chromecast"; Aliases = @("chromecast", "google cast", "googlecast") },
        [PSCustomObject]@{ Key = "dlna"; Label = "DLNA"; FileName = "platform-dlna.png"; Cid = "platform_dlna"; Aliases = @("dlna") },
        [PSCustomObject]@{ Key = "firefox"; Label = "Firefox"; FileName = "platform-firefox.png"; Cid = "platform_firefox"; Aliases = @("firefox", "mozilla firefox") },
        [PSCustomObject]@{ Key = "internet-explorer"; Label = "Internet Explorer"; FileName = "platform-internet-explorer.png"; Cid = "platform_internet_explorer"; Aliases = @("ie", "internet explorer") },
        [PSCustomObject]@{ Key = "ios"; Label = "iOS"; FileName = "platform-ios.png"; Cid = "platform_ios"; Aliases = @("ios", "ipad", "ipados", "iphone") },
        [PSCustomObject]@{ Key = "kodi"; Label = "Kodi"; FileName = "platform-kodi.png"; Cid = "platform_kodi"; Aliases = @("kodi", "xbmc") },
        [PSCustomObject]@{ Key = "lg"; Label = "LG"; FileName = "platform-lg.png"; Cid = "platform_lg"; Aliases = @("lg", "lg webos", "netcast", "web os", "webos") },
        [PSCustomObject]@{ Key = "linux"; Label = "Linux"; FileName = "platform-linux.png"; Cid = "platform_linux"; Aliases = @("linux") },
        [PSCustomObject]@{ Key = "macos"; Label = "macOS"; FileName = "platform-macos.png"; Cid = "platform_macos"; Aliases = @("mac os", "mac os x", "macos", "osx") },
        [PSCustomObject]@{ Key = "microsoft-edge"; Label = "Microsoft Edge"; FileName = "platform-microsoft-edge.png"; Cid = "platform_microsoft_edge"; Aliases = @("edge", "microsoft edge", "msedge") },
        [PSCustomObject]@{ Key = "opera"; Label = "Opera"; FileName = "platform-opera.png"; Cid = "platform_opera"; Aliases = @("opera", "smartcast", "vizio", "vizio smartcast") },
        [PSCustomObject]@{ Key = "playstation"; Label = "PlayStation"; FileName = "platform-playstation.png"; Cid = "platform_playstation"; Aliases = @("playstation", "playstation 3", "playstation 4", "playstation 5", "ps3", "ps4", "ps5") },
        [PSCustomObject]@{ Key = "plex"; Label = "Plex"; FileName = "platform-plex.png"; Cid = "platform_plex"; Aliases = @("plex", "plex desktop", "plex home theater", "plex htpc", "plex media player") },
        [PSCustomObject]@{ Key = "roku"; Label = "Roku"; FileName = "platform-roku.png"; Cid = "platform_roku"; Aliases = @("roku") },
        [PSCustomObject]@{ Key = "safari"; Label = "Safari"; FileName = "platform-safari.png"; Cid = "platform_safari"; Aliases = @("safari") },
        [PSCustomObject]@{ Key = "samsung"; Label = "Samsung"; FileName = "platform-samsung.png"; Cid = "platform_samsung"; Aliases = @("samsung", "tizen") },
        [PSCustomObject]@{ Key = "wii-u"; Label = "Wii U"; FileName = "platform-wii-u.png"; Cid = "platform_wii_u"; Aliases = @("wii u", "wiiu") },
        [PSCustomObject]@{ Key = "windows"; Label = "Windows"; FileName = "platform-windows.png"; Cid = "platform_windows"; Aliases = @("windows", "windows phone", "wp") },
        [PSCustomObject]@{ Key = "xbox"; Label = "Xbox"; FileName = "platform-xbox.png"; Cid = "platform_xbox"; Aliases = @("xbox", "xbox 360", "xbox one", "xbox series", "xbox series s", "xbox series x") }
    )
}

function ConvertTo-NewsletterPlatformAlias {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return "" }
    $normalized = ([string]$Value).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) { return "" }
    $normalized = $normalized -replace '[^a-z0-9]+', ' '
    return (($normalized -replace '\s+', ' ').Trim())
}

function Resolve-NewsletterPlatform {
    param([AllowNull()][object]$Row)

    if ($null -eq $Row) { return $null }
    $catalog = @(Get-NewsletterPlatformCatalog)
    foreach ($propertyName in @("platform_name", "platform")) {
        $candidate = ConvertTo-NewsletterPlatformAlias (
            Get-OptionalStringProperty -InputObject $Row -Name $propertyName
        )
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

        foreach ($platform in $catalog) {
            if ($candidate -in @($platform.Aliases)) {
                return $platform
            }
        }
    }

    return $null
}

function Get-NewsletterPlatformHistoryTimestamp {
    param([AllowNull()][object]$Row)

    if ($null -eq $Row) { return [int64]0 }
    [int64]$latest = 0
    foreach ($propertyName in @("started", "date", "stopped")) {
        $raw = (Get-OptionalStringProperty -InputObject $Row -Name $propertyName).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        [int64]$epoch = 0
        if ([int64]::TryParse(
            $raw,
            [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$epoch
        )) {
            if ($epoch -gt $latest) { $latest = $epoch }
            continue
        }

        [DateTimeOffset]$parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse(
            $raw,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$parsed
        )) {
            $epoch = $parsed.ToUnixTimeSeconds()
            if ($epoch -gt $latest) { $latest = $epoch }
        }
    }

    return $latest
}

function Get-NewsletterPlatform {
    param(
        [object[]]$History,
        [string]$ExpectedUserId = ""
    )

    $totals = @{}
    foreach ($row in @($History)) {
        if ($null -eq $row) { continue }

        $rowUserId = (Get-OptionalStringProperty -InputObject $row -Name "user_id").Trim()
        if (-not [string]::IsNullOrWhiteSpace($ExpectedUserId) -and
            $rowUserId -ne $ExpectedUserId) {
            continue
        }

        $platform = Resolve-NewsletterPlatform -Row $row
        if ($null -eq $platform) { continue }

        $key = [string]$platform.Key
        if (-not $totals.ContainsKey($key)) {
            $totals[$key] = [PSCustomObject]@{
                Platform = $platform
                Plays = 0
                Latest = [int64]0
            }
        }
        $totals[$key].Plays += (Get-HistoryRowPlayCount -Row $row)
        $timestamp = Get-NewsletterPlatformHistoryTimestamp -Row $row
        if ($timestamp -gt $totals[$key].Latest) {
            $totals[$key].Latest = $timestamp
        }
    }

    $ranked = @(
        $totals.Values |
            Sort-Object @{ Expression = { $_.Plays }; Descending = $true }, @{ Expression = { $_.Latest }; Descending = $true }, @{ Expression = { $_.Platform.Key }; Descending = $false } |
            Select-Object -First 1
    )
    if ($ranked.Count -eq 0) { return $null }
    return $ranked[0].Platform
}

function Get-NewsletterLastPlatform {
    param([string]$ExpectedUserId)

    if ([string]::IsNullOrWhiteSpace($ExpectedUserId)) { return $null }

    try {
        $table = Invoke-TautulliApi -Command "get_users_table" -Parameters @{
            user_id = $ExpectedUserId
            start   = 0
            length  = 1
        }
        $rows = @()
        if ($null -ne $table -and $null -ne $table.PSObject.Properties["data"]) {
            $rows = @($table.data)
        }
        $matches = @(
            $rows | Where-Object {
                (Get-OptionalStringProperty -InputObject $_ -Name "user_id").Trim() -eq $ExpectedUserId
            }
        )
    }
    catch {
        return $null
    }

    if ($matches.Count -ne 1) { return $null }
    return Resolve-NewsletterPlatform -Row $matches[0]
}

function Get-NewsletterPlatformHeadingHtml {
    param(
        [AllowNull()][object]$Platform,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode,
        [string]$PreviewAssetBase = ""
    )

    $heading = '<div style="font-size:12px;color:#e5a00d;font-weight:800;letter-spacing:1.4px;">YOUR WEEK ON PLEX</div>'
    if ($null -eq $Platform) { return $heading }

    $fileName = Get-OptionalStringProperty -InputObject $Platform -Name "FileName"
    $cid = Get-OptionalStringProperty -InputObject $Platform -Name "Cid"
    $label = Get-OptionalStringProperty -InputObject $Platform -Name "Label"
    if ([string]::IsNullOrWhiteSpace($fileName) -or
        [string]::IsNullOrWhiteSpace($cid) -or
        [string]::IsNullOrWhiteSpace($label) -or
        -not (Test-Path -LiteralPath (Join-Path $AssetsDir $fileName) -PathType Leaf)) {
        return $heading
    }

    $imageSource = if ($ImageMode -eq "Email") {
        "cid:" + $cid
    }
    elseif (-not [string]::IsNullOrWhiteSpace($PreviewAssetBase)) {
        $PreviewAssetBase.TrimEnd('/') + '/' + $fileName
    }
    else {
        ""
    }
    if ([string]::IsNullOrWhiteSpace($imageSource)) { return $heading }

    $alt = HtmlEncode ("Platform: " + $label)
    return @"
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="border-collapse:collapse;">
  <tr>
    <td valign="middle">$heading</td>
    <td valign="middle" style="padding-left:8px;line-height:0;"><img src="$(HtmlEncode $imageSource)" width="21" height="21" alt="$alt" style="display:block;width:21px;height:21px;max-height:21px;border:0;outline:none;text-decoration:none;"></td>
  </tr>
</table>
"@
}


function Get-GlobalTitleTotals {
    param([object[]]$GlobalHistory)

    $watchedThreshold = if ($null -ne $Config.PSObject.Properties["WatchedPercent"]) {
        Safe-Int $Config.WatchedPercent
    } else { 85 }

    $totals = @{}

    foreach ($row in $GlobalHistory) {
        $type = ([string]$row.media_type).ToLowerInvariant()
        $seconds = [int64](Safe-Int $row.play_duration)
        if ($seconds -lt 0) { $seconds = 0 }
        if (-not (Test-HistoryRowQualifiedView -Row $row -WatchedThreshold $watchedThreshold)) { continue }

        $title = ""
        $key = ""
        $ratingKey = ""
        $titleType = ""
        $metadataGuid = Get-OptionalStringProperty -InputObject $row -Name "guid"
        $metadataYear = Get-OptionalStringProperty -InputObject $row -Name "year"
        $metadataSummary = ""
        $metadataRating = ""
        $metadataRatingImage = ""
        $metadataAudienceRating = ""
        $metadataAudienceRatingImage = ""
        $metadataGenres = @()
        $metadataParentIndex = 0
        $metadataIndex = 0

        if ($type -eq "movie") {
            $title = [string]$row.title
            $ratingKey = [string]$row.rating_key
            $key = if ([string]::IsNullOrWhiteSpace($ratingKey)) { "movie:title:" + $title } else { "movie:" + $ratingKey }
            $titleType = "movie"
            $metadataSummary = Get-OptionalStringProperty -InputObject $row -Name "summary"
            $metadataRating = Get-OptionalStringProperty -InputObject $row -Name "rating"
            $metadataRatingImage = Get-OptionalStringProperty -InputObject $row -Name "rating_image"
            $metadataAudienceRating = Get-OptionalStringProperty -InputObject $row -Name "audience_rating"
            $metadataAudienceRatingImage = Get-OptionalStringProperty -InputObject $row -Name "audience_rating_image"
            if ($null -ne $row.PSObject.Properties["genres"]) { $metadataGenres = @(ConvertTo-DesignGenreList -Value $row.genres) }
        }
        elseif ($type -eq "episode") {
            $title = [string]$row.grandparent_title
            if ([string]::IsNullOrWhiteSpace($title)) {
                $title = [string]$row.title
            }
            $ratingKey = [string]$row.grandparent_rating_key
            $key = if ([string]::IsNullOrWhiteSpace($ratingKey)) { "show:title:" + $title } else { "show:" + $ratingKey }
            $titleType = "show"
            $metadataParentIndex = Safe-Int (Get-OptionalStringProperty -InputObject $row -Name "parent_media_index")
            $metadataIndex = Safe-Int (Get-OptionalStringProperty -InputObject $row -Name "media_index")
        }
        else {
            continue
        }

        $metadataRatingPairAvailable = (
            -not [string]::IsNullOrWhiteSpace($metadataRating) -and
            -not [string]::IsNullOrWhiteSpace($metadataRatingImage)
        )
        $metadataAudiencePairAvailable = (
            -not [string]::IsNullOrWhiteSpace($metadataAudienceRating) -and
            -not [string]::IsNullOrWhiteSpace($metadataAudienceRatingImage)
        )
        if ([string]::IsNullOrWhiteSpace($title)) { continue }

        if (-not $totals.ContainsKey($key)) {
            $totals[$key] = [PSCustomObject]@{
                Key       = $key
                Title     = $title
                Type      = $titleType
                RatingKey = $ratingKey
                MetadataGuid = $metadataGuid
                MetadataParentIndex = $metadataParentIndex
                MetadataIndex = $metadataIndex
                Year      = $metadataYear
                Summary   = $metadataSummary
                Rating    = if ($metadataRatingPairAvailable) { $metadataRating } else { "" }
                RatingImage = if ($metadataRatingPairAvailable) { $metadataRatingImage } else { "" }
                AudienceRating = if ($metadataAudiencePairAvailable) { $metadataAudienceRating } else { "" }
                AudienceRatingImage = if ($metadataAudiencePairAvailable) { $metadataAudienceRatingImage } else { "" }
                Genres    = @($metadataGenres)
                Seconds   = [int64]0
                Plays     = 0
                ViewerKeys = @{}
                Latest    = [int64]0
            }
        }

        if ([string]::IsNullOrWhiteSpace([string]$totals[$key].MetadataGuid) -and
            -not [string]::IsNullOrWhiteSpace($metadataGuid)) {
            $totals[$key].MetadataGuid = $metadataGuid
            $totals[$key].MetadataParentIndex = $metadataParentIndex
            $totals[$key].MetadataIndex = $metadataIndex
        }
        if ([string]::IsNullOrWhiteSpace([string]$totals[$key].Year) -and
            -not [string]::IsNullOrWhiteSpace($metadataYear)) {
            $totals[$key].Year = $metadataYear
        }
        if ($titleType -eq "movie") {
            if ([string]::IsNullOrWhiteSpace([string]$totals[$key].Summary) -and -not [string]::IsNullOrWhiteSpace($metadataSummary)) { $totals[$key].Summary = $metadataSummary }
            $currentRatingPairAvailable = (
                -not [string]::IsNullOrWhiteSpace([string]$totals[$key].Rating) -and
                -not [string]::IsNullOrWhiteSpace([string]$totals[$key].RatingImage)
            )
            if (-not $currentRatingPairAvailable -and $metadataRatingPairAvailable) {
                $totals[$key].Rating = $metadataRating
                $totals[$key].RatingImage = $metadataRatingImage
            }
            $currentAudiencePairAvailable = (
                -not [string]::IsNullOrWhiteSpace([string]$totals[$key].AudienceRating) -and
                -not [string]::IsNullOrWhiteSpace([string]$totals[$key].AudienceRatingImage)
            )
            if (-not $currentAudiencePairAvailable -and $metadataAudiencePairAvailable) {
                $totals[$key].AudienceRating = $metadataAudienceRating
                $totals[$key].AudienceRatingImage = $metadataAudienceRatingImage
            }
            if (@($totals[$key].Genres).Count -eq 0 -and $metadataGenres.Count -gt 0) { $totals[$key].Genres = @($metadataGenres) }
        }

        $totals[$key].Seconds += $seconds
        $totals[$key].Plays += (Get-HistoryRowPlayCount -Row $row)
        $viewerKey = Get-HistoryRowViewerKey -Row $row
        if (-not [string]::IsNullOrWhiteSpace($viewerKey)) {
            $totals[$key].ViewerKeys[$viewerKey] = $true
        }
        $timestamp = Get-NewsletterPlatformHistoryTimestamp -Row $row
        if ($timestamp -gt $totals[$key].Latest) { $totals[$key].Latest = $timestamp }
    }

    return @($totals.Values)
}

function Get-GlobalTrendingStat {
    param([object[]]$GlobalHistory)

    $top = @(
        Get-GlobalTitleTotals -GlobalHistory $GlobalHistory |
        Where-Object {
            [string]$_.Type -eq "movie" -and
            ($_.Seconds -gt 0 -or $_.Plays -gt 0)
        } |
        Sort-Object `
            @{ Expression = { Safe-Int $_.Plays }; Descending = $true }, `
            @{ Expression = { $_.ViewerKeys.Count }; Descending = $true }, `
            @{ Expression = { [int64]$_.Seconds }; Descending = $true }, `
            @{ Expression = { [int64]$_.Latest }; Descending = $true } |
        Select-Object -First 1
    )

    if ($top.Count -eq 0) { return $null }
    return $top[0]
}

function Get-GlobalTrendingTitle {
    param([object[]]$GlobalHistory)

    $stat = Get-GlobalTrendingStat -GlobalHistory $GlobalHistory
    if ($null -ne $stat) { return [string]$stat.Title }
    return ""
}

function ConvertTo-TopMovieGenreLabel {
    param([AllowNull()][object]$Value)

    $genres = @(ConvertTo-DesignGenreList -Value $Value)
    if ($genres.Count -eq 0) { return "" }

    $label = ([string]$genres[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($label)) { return "" }

    $aliasKey = (($label.ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim())
    if ($aliasKey -in @('science fiction', 'sci fi', 'scifi')) { return 'Science Fiction' }

    $knownLabels = @{
        'action' = 'Action'; 'comedy' = 'Comedy'; 'crime' = 'Crime'
        'drama' = 'Drama'; 'fantasy' = 'Fantasy'; 'horror' = 'Horror'
        'musical' = 'Musical'; 'mystery' = 'Mystery'; 'romance' = 'Romance'
        'thriller' = 'Thriller'; 'western' = 'Western'
    }
    if ($knownLabels.ContainsKey($aliasKey)) { return [string]$knownLabels[$aliasKey] }

    # Unknown Plex genres still aggregate case-insensitively. Normalize their
    # display casing and use the neutral local movie asset at render time.
    return [Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($aliasKey)
}

function Get-TopMovieGenreAsset {
    param([string]$Genre)

    $assetMap = @{
        'action' = [PSCustomObject]@{ FileName = 'genre-action.gif'; Cid = 'genre_action' }
        'comedy' = [PSCustomObject]@{ FileName = 'genre-comedy.gif'; Cid = 'genre_comedy' }
        'crime' = [PSCustomObject]@{ FileName = 'genre-crime.gif'; Cid = 'genre_crime' }
        'drama' = [PSCustomObject]@{ FileName = 'genre-drama.gif'; Cid = 'genre_drama' }
        'fantasy' = [PSCustomObject]@{ FileName = 'genre-fantasy.gif'; Cid = 'genre_fantasy' }
        'horror' = [PSCustomObject]@{ FileName = 'genre-horror.gif'; Cid = 'genre_horror' }
        'musical' = [PSCustomObject]@{ FileName = 'genre-musical.gif'; Cid = 'genre_musical' }
        'mystery' = [PSCustomObject]@{ FileName = 'genre-mystery.gif'; Cid = 'genre_mystery' }
        'romance' = [PSCustomObject]@{ FileName = 'genre-romance.gif'; Cid = 'genre_romance' }
        'science fiction' = [PSCustomObject]@{ FileName = 'genre-scifi.gif'; Cid = 'genre_scifi' }
        'thriller' = [PSCustomObject]@{ FileName = 'genre-thriller.gif'; Cid = 'genre_thriller' }
        'western' = [PSCustomObject]@{ FileName = 'genre-western.gif'; Cid = 'genre_western' }
    }

    $key = ([string]$Genre).Trim().ToLowerInvariant()
    if ($assetMap.ContainsKey($key)) {
        $candidate = $assetMap[$key]
        if (Test-Path -LiteralPath (Join-Path $AssetsDir ([string]$candidate.FileName)) -PathType Leaf) {
            return [PSCustomObject]@{ FileName = [string]$candidate.FileName; Cid = [string]$candidate.Cid; IsFallback = $false }
        }
    }

    return [PSCustomObject]@{ FileName = 'movies.gif'; Cid = 'icon_movies'; IsFallback = $true }
}

function Get-GlobalTopMovieGenre {
    param([object[]]$GlobalHistory)

    $watchedThreshold = if ($null -ne $Config.PSObject.Properties['WatchedPercent']) {
        Safe-Int $Config.WatchedPercent
    } else { 85 }

    $movieTotals = @{}
    foreach ($row in @($GlobalHistory)) {
        if ((Get-OptionalStringProperty -InputObject $row -Name 'media_type').ToLowerInvariant() -ne 'movie') { continue }

        $seconds = [int64](Safe-Int $row.play_duration)
        if ($seconds -lt 0) { $seconds = 0 }
        $qualified = Test-HistoryRowQualifiedView -Row $row -WatchedThreshold $watchedThreshold
        if (-not $qualified) { continue }

        $ratingKey = (Get-OptionalStringProperty -InputObject $row -Name 'rating_key').Trim()
        $title = (Get-OptionalStringProperty -InputObject $row -Name 'title').Trim()
        $movieKey = if (-not [string]::IsNullOrWhiteSpace($ratingKey)) {
            'movie:' + $ratingKey
        } elseif (-not [string]::IsNullOrWhiteSpace($title)) {
            'movie:title:' + $title.ToLowerInvariant()
        } else { '' }
        if ([string]::IsNullOrWhiteSpace($movieKey)) { continue }

        if (-not $movieTotals.ContainsKey($movieKey)) {
            $movieTotals[$movieKey] = [PSCustomObject]@{
                Key = $movieKey; RatingKey = $ratingKey; Title = $title
                Seconds = [int64]0; Plays = 0
            }
        }
        $movieTotals[$movieKey].Seconds += $seconds
        $movieTotals[$movieKey].Plays += (Get-HistoryRowPlayCount -Row $row)
    }

    $genreTotals = @{}
    foreach ($movie in @($movieTotals.Values | Sort-Object Key)) {
        $firstGenre = ''

        # Tautulli get_metadata is the normal Plex metadata bridge. Preserve
        # Plex's array order and use exactly its first nonblank genre.
        if (-not [string]::IsNullOrWhiteSpace([string]$movie.RatingKey)) {
            try {
                $metadata = Invoke-TautulliApi -Command 'get_metadata' -Parameters @{ rating_key = [string]$movie.RatingKey }
                foreach ($propertyName in @('genres', 'genre', 'Genre')) {
                    if ($null -ne $metadata -and $null -ne $metadata.PSObject.Properties[$propertyName]) {
                        $metadataGenres = @(ConvertTo-DesignGenreList -Value $metadata.PSObject.Properties[$propertyName].Value)
                        if ($metadataGenres.Count -gt 0) { $firstGenre = [string]$metadataGenres[0]; break }
                    }
                }
            } catch {
                Write-Log "Top Movie Genre metadata lookup failed for rating key $($movie.RatingKey); trying direct Plex metadata." 'WARN'
            }

            if ([string]::IsNullOrWhiteSpace($firstGenre)) {
                try {
                    $plexMetadata = Get-DesignPlexMetadata -RatingKey ([string]$movie.RatingKey)
                    foreach ($propertyName in @('Genre', 'genres', 'genre')) {
                        if ($null -ne $plexMetadata -and $null -ne $plexMetadata.PSObject.Properties[$propertyName]) {
                            $plexGenres = @(ConvertTo-DesignGenreList -Value $plexMetadata.PSObject.Properties[$propertyName].Value)
                            if ($plexGenres.Count -gt 0) { $firstGenre = [string]$plexGenres[0]; break }
                        }
                    }
                } catch {
                    Write-Log "Top Movie Genre direct Plex metadata fallback failed for rating key $($movie.RatingKey)." 'WARN'
                }
            }
        }

        $genre = ConvertTo-TopMovieGenreLabel -Value $firstGenre
        if ([string]::IsNullOrWhiteSpace($genre)) { continue }

        $genreKey = $genre.ToLowerInvariant()
        if (-not $genreTotals.ContainsKey($genreKey)) {
            $genreTotals[$genreKey] = [PSCustomObject]@{ Genre = $genre; Seconds = [int64]0; Plays = 0; MovieKeys = @{} }
        }
        $genreTotals[$genreKey].Seconds += [int64]$movie.Seconds
        $genreTotals[$genreKey].Plays += Safe-Int $movie.Plays
        $genreTotals[$genreKey].MovieKeys[[string]$movie.Key] = $true
    }

    # Rank by the displayed qualified watch time, then displayed unique-movie
    # count, grouped play count, and finally the normalized genre label.
    $winner = @(
        $genreTotals.Values |
            Sort-Object `
                @{ Expression = { [int64]$_.Seconds }; Descending = $true }, `
                @{ Expression = { $_.MovieKeys.Count }; Descending = $true }, `
                @{ Expression = { Safe-Int $_.Plays }; Descending = $true }, `
                @{ Expression = { ([string]$_.Genre).ToLowerInvariant() }; Descending = $false } |
            Select-Object -First 1
    )

    if ($winner.Count -eq 0) {
        $fallbackAsset = Get-TopMovieGenreAsset -Genre ''
        return [PSCustomObject]@{
            Available = $false; Genre = 'No qualifying genre yet'; Seconds = [int64]0
            Plays = 0; MovieCount = 0; TotalTimeText = '0m'
            SupportingText = 'No qualifying movie activity with genre metadata this week'
            AssetFileName = [string]$fallbackAsset.FileName; AssetCid = [string]$fallbackAsset.Cid
            AssetFallback = $true
        }
    }

    $top = $winner[0]
    $movieCount = $top.MovieKeys.Count
    $movieWord = if ($movieCount -eq 1) { 'movie' } else { 'movies' }
    $timeText = Format-WatchTime ([int64]$top.Seconds)
    $asset = Get-TopMovieGenreAsset -Genre ([string]$top.Genre)
    return [PSCustomObject]@{
        Available = $true; Genre = [string]$top.Genre; Seconds = [int64]$top.Seconds
        Plays = Safe-Int $top.Plays; MovieCount = $movieCount; TotalTimeText = $timeText
        SupportingText = "$timeText watched across $movieCount $movieWord"
        AssetFileName = [string]$asset.FileName; AssetCid = [string]$asset.Cid
        AssetFallback = [bool]$asset.IsFallback
    }
}
function New-HeroItemFromGlobalStat {
    param([object]$Stat)

    if ($null -eq $Stat) { return $null }

    $meta = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Stat.RatingKey)) {
        try {
            $meta = Invoke-TautulliApi -Command "get_metadata" -Parameters @{
                rating_key = [string]$Stat.RatingKey
            }
        }
        catch {
            Write-Log "Could not load metadata for server-wide hero '$($Stat.Title)': $($_.Exception.Message)" "WARN"
        }
    }

    $title = [string]$Stat.Title
    $year = Get-OptionalStringProperty -InputObject $Stat -Name "Year"
    $summary = Get-OptionalStringProperty -InputObject $Stat -Name "Summary"
    $rating = Get-OptionalStringProperty -InputObject $Stat -Name "Rating"
    $ratingImage = Get-OptionalStringProperty -InputObject $Stat -Name "RatingImage"
    $audienceRating = Get-OptionalStringProperty -InputObject $Stat -Name "AudienceRating"
    $audienceRatingImage = Get-OptionalStringProperty -InputObject $Stat -Name "AudienceRatingImage"
    $genres = @(if ($null -ne $Stat.PSObject.Properties["Genres"]) { ConvertTo-DesignGenreList -Value $Stat.Genres })
    $posterRatingKey = [string]$Stat.RatingKey
    $addedAt = [int64]0

    if ($null -ne $meta) {
        $metadataTitle = Get-OptionalStringProperty -InputObject $meta -Name "title"
        if (-not [string]::IsNullOrWhiteSpace($metadataTitle)) { $title = $metadataTitle }
        $metadataYear = Get-OptionalStringProperty -InputObject $meta -Name "year"
        if (-not [string]::IsNullOrWhiteSpace($metadataYear)) { $year = $metadataYear }
        $metadataSummary = Get-OptionalStringProperty -InputObject $meta -Name "summary"
        if (-not [string]::IsNullOrWhiteSpace($metadataSummary)) { $summary = $metadataSummary }
        $metadataRating = Get-OptionalStringProperty -InputObject $meta -Name "rating"
        $metadataRatingImage = Get-OptionalStringProperty -InputObject $meta -Name "rating_image"
        if (-not [string]::IsNullOrWhiteSpace($metadataRating) -and
            -not [string]::IsNullOrWhiteSpace($metadataRatingImage)) {
            $rating = $metadataRating
            $ratingImage = $metadataRatingImage
        }
        $metadataAudienceRating = Get-OptionalStringProperty -InputObject $meta -Name "audience_rating"
        $metadataAudienceRatingImage = Get-OptionalStringProperty -InputObject $meta -Name "audience_rating_image"
        if (-not [string]::IsNullOrWhiteSpace($metadataAudienceRating) -and
            -not [string]::IsNullOrWhiteSpace($metadataAudienceRatingImage)) {
            $audienceRating = $metadataAudienceRating
            $audienceRatingImage = $metadataAudienceRatingImage
        }
        if ($null -ne $meta.PSObject.Properties["genres"]) { $metadataGenres = @(ConvertTo-DesignGenreList -Value $meta.genres); if ($metadataGenres.Count -gt 0) { $genres = $metadataGenres } }
        $addedAt = Safe-Int64 (Get-OptionalStringProperty -InputObject $meta -Name "added_at")
        if ([string]::IsNullOrWhiteSpace($posterRatingKey)) {
            $posterRatingKey = Get-OptionalStringProperty -InputObject $meta -Name "rating_key"
        }
    }

    return [PSCustomObject]@{
        Type            = [string]$Stat.Type
        ReleaseKey      = [string]$Stat.Key
        RatingKey       = [string]$Stat.RatingKey
        PosterRatingKey = $posterRatingKey
        MetadataGuid    = Get-OptionalStringProperty -InputObject $Stat -Name "MetadataGuid"
        MetadataParentIndex = Safe-Int (Get-OptionalStringProperty -InputObject $Stat -Name "MetadataParentIndex")
        MetadataIndex   = Safe-Int (Get-OptionalStringProperty -InputObject $Stat -Name "MetadataIndex")
        Title           = $title
        Year            = $year
        Rating          = $rating
        RatingImage     = $ratingImage
        AudienceRating  = $audienceRating
        AudienceRatingImage = $audienceRatingImage
        Summary         = $summary
        DesignGenres    = @($genres)
        AddedAt         = $addedAt
        EpisodeCount    = 0
        SeasonCount     = 0
        IsNewSeries     = $false
        Episodes        = @()
    }
}

function Get-GlobalTrendingHero {
    param(
        [object[]]$GlobalHistory,
        [AllowNull()][object]$ReleaseData = $null,
        [AllowNull()][object]$TrendingStat = $null
    )

    $top = @()
    if ($null -ne $TrendingStat) {
        $top = @($TrendingStat)
    } else {
        $top = @(Get-GlobalTrendingStat -GlobalHistory $GlobalHistory)
    }

    if ($top.Count -eq 0 -or $null -eq $top[0]) { return $null }

    $historyItem = New-HeroItemFromGlobalStat -Stat $top[0]
    $item = $historyItem
    if ($null -ne $ReleaseData -and $null -ne $ReleaseData.PSObject.Properties["Movies"]) {
        $releaseItem = @(
            $ReleaseData.Movies |
            Where-Object {
                [string]$_.ReleaseKey -eq [string]$top[0].Key -or
                (
                    -not [string]::IsNullOrWhiteSpace([string]$top[0].RatingKey) -and
                    [string]$_.RatingKey -eq [string]$top[0].RatingKey
                )
            } |
            Select-Object -First 1
        ) | Select-Object -First 1

        if ($null -ne $releaseItem) {
            $merged = [ordered]@{}
            foreach ($property in $releaseItem.PSObject.Properties) {
                $merged[$property.Name] = $property.Value
            }

            if ($null -ne $historyItem) {
                foreach ($propertyName in @(
                    "Type", "ReleaseKey", "RatingKey", "PosterRatingKey",
                    "MetadataGuid", "Title", "Year", "Summary"
                )) {
                    $historyValue = Get-OptionalStringProperty -InputObject $historyItem -Name $propertyName
                    $releaseValue = if ($merged.Contains($propertyName)) { [string]$merged[$propertyName] } else { "" }
                    if ([string]::IsNullOrWhiteSpace($releaseValue) -and
                        -not [string]::IsNullOrWhiteSpace($historyValue)) {
                        $merged[$propertyName] = $historyValue
                    }
                }
                $releaseRating = if ($merged.Contains("Rating")) { [string]$merged["Rating"] } else { "" }
                $releaseRatingImage = if ($merged.Contains("RatingImage")) { [string]$merged["RatingImage"] } else { "" }
                $historyRating = Get-OptionalStringProperty -InputObject $historyItem -Name "Rating"
                $historyRatingImage = Get-OptionalStringProperty -InputObject $historyItem -Name "RatingImage"
                if (([string]::IsNullOrWhiteSpace($releaseRating) -or [string]::IsNullOrWhiteSpace($releaseRatingImage)) -and
                    -not [string]::IsNullOrWhiteSpace($historyRating) -and
                    -not [string]::IsNullOrWhiteSpace($historyRatingImage)) {
                    $merged["Rating"] = $historyRating
                    $merged["RatingImage"] = $historyRatingImage
                }
                $releaseAudience = if ($merged.Contains("AudienceRating")) { [string]$merged["AudienceRating"] } else { "" }
                $releaseAudienceImage = if ($merged.Contains("AudienceRatingImage")) { [string]$merged["AudienceRatingImage"] } else { "" }
                $historyAudience = Get-OptionalStringProperty -InputObject $historyItem -Name "AudienceRating"
                $historyAudienceImage = Get-OptionalStringProperty -InputObject $historyItem -Name "AudienceRatingImage"
                if (([string]::IsNullOrWhiteSpace($releaseAudience) -or [string]::IsNullOrWhiteSpace($releaseAudienceImage)) -and
                    -not [string]::IsNullOrWhiteSpace($historyAudience) -and
                    -not [string]::IsNullOrWhiteSpace($historyAudienceImage)) {
                    $merged["AudienceRating"] = $historyAudience
                    $merged["AudienceRatingImage"] = $historyAudienceImage
                }

                $historyGenres = @()
                if ($null -ne $historyItem.PSObject.Properties["DesignGenres"]) {
                    $historyGenres = @($historyItem.DesignGenres)
                }
                $releaseGenres = @()
                if ($merged.Contains("DesignGenres")) {
                    $releaseGenres = @($merged["DesignGenres"])
                }
                if ($releaseGenres.Count -eq 0 -and $historyGenres.Count -gt 0) {
                    $merged["DesignGenres"] = $historyGenres
                }
            }

            $item = [PSCustomObject]$merged
        }
    }
    if ($null -eq $item) { return $null }

    return [PSCustomObject]@{
        Item      = $item
        Seconds   = [int64]$top[0].Seconds
        Plays     = Safe-Int $top[0].Plays
        IsPopular = $true
        IsTrending = $true
    }
}

function Get-BingeChampion {
    param([object[]]$GlobalHistory)

    $watchedThreshold = if ($null -ne $Config.PSObject.Properties["WatchedPercent"]) {
        Safe-Int $Config.WatchedPercent
    } else { 85 }

    $totals = @{}

    foreach ($row in $GlobalHistory) {
        $type = ([string]$row.media_type).ToLowerInvariant()
        $seconds = [int64](Safe-Int $row.play_duration)
        if ($seconds -lt 0) { $seconds = 0 }

        if ($type -notin @("movie", "episode")) { continue }
        $qualified = Test-HistoryRowQualifiedView -Row $row -WatchedThreshold $watchedThreshold

        if (-not $qualified) { continue }

        $userId = ""
        foreach ($propertyName in @("user_id","userId")) {
            if ($null -ne $row.PSObject.Properties[$propertyName]) {
                $candidate = [string]$row.$propertyName
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    $userId = $candidate
                    break
                }
            }
        }

        $friendlyName = ""
        foreach ($propertyName in @("friendly_name","user","username")) {
            if ($null -ne $row.PSObject.Properties[$propertyName]) {
                $candidate = [string]$row.$propertyName
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    $friendlyName = $candidate
                    break
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($userId) -and
            [string]::IsNullOrWhiteSpace($friendlyName)) {
            continue
        }

        $key = if (-not [string]::IsNullOrWhiteSpace($userId)) {
            "id:" + $userId
        } else {
            "name:" + $friendlyName.ToLowerInvariant()
        }

        if (-not $totals.ContainsKey($key)) {
            $totals[$key] = [PSCustomObject]@{
                UserId       = $userId
                FriendlyName = $friendlyName
                Plays        = 0
                Seconds      = [int64]0
                MoviePlays   = 0
                TvPlays      = 0
                Latest       = [int64]0
                QualifyingTitleKeys = @{}
                QualifyingMovieKeys = @{}
                QualifyingTvShowKeys = @{}
            }
        }

        $rowPlays = Get-HistoryRowPlayCount -Row $row
        $totals[$key].Plays += $rowPlays
        $totals[$key].Seconds += $seconds
        $timestamp = Get-NewsletterPlatformHistoryTimestamp -Row $row
        if ($timestamp -gt $totals[$key].Latest) { $totals[$key].Latest = $timestamp }

        $titleKey = if ($type -eq "movie") {
            $movieRatingKey = [string]$row.rating_key
            if (-not [string]::IsNullOrWhiteSpace($movieRatingKey)) {
                "movie:" + $movieRatingKey
            } else {
                "movie:title:" + ([string]$row.title).ToLowerInvariant()
            }
        } else {
            $showRatingKey = [string]$row.grandparent_rating_key
            $showTitle = [string]$row.grandparent_title
            if ([string]::IsNullOrWhiteSpace($showTitle)) { $showTitle = [string]$row.title }
            if (-not [string]::IsNullOrWhiteSpace($showRatingKey)) {
                "show:" + $showRatingKey
            } else {
                "show:title:" + $showTitle.ToLowerInvariant()
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($titleKey)) {
            $totals[$key].QualifyingTitleKeys[$titleKey] = $true
            if ($type -eq "movie") {
                $totals[$key].QualifyingMovieKeys[$titleKey] = $true
            }
            elseif ($type -eq "episode") {
                $totals[$key].QualifyingTvShowKeys[$titleKey] = $true
            }
        }

        if ($type -eq "movie") {
            $totals[$key].MoviePlays += $rowPlays
        }
        elseif ($type -eq "episode") {
            $totals[$key].TvPlays += $rowPlays
        }
    }

    $top = @(
        $totals.Values |
        Where-Object { $_.Plays -gt 0 } |
        Sort-Object `
            @{ Expression = { [int64]$_.Seconds }; Descending = $true }, `
            @{ Expression = { Safe-Int $_.Plays }; Descending = $true }, `
            @{ Expression = { $_.QualifyingTitleKeys.Count }; Descending = $true }, `
            @{ Expression = { [int64]$_.Latest }; Descending = $true } |
        Select-Object -First 1
    )

    if ($top.Count -eq 0) { return $null }

    $winner = $top[0]
    if ([string]::IsNullOrWhiteSpace([string]$winner.FriendlyName) -and
        -not [string]::IsNullOrWhiteSpace([string]$winner.UserId)) {
        try {
            $resolved = Get-NewsletterUser -Id ([string]$winner.UserId)
            $winner.FriendlyName = [string]$resolved.FriendlyName
        }
        catch {
            Write-Log "Could not resolve Binge Champion user $($winner.UserId): $($_.Exception.Message)" "WARN"
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$winner.FriendlyName)) {
        $winner.FriendlyName = "A Plex user"
    }

    return [PSCustomObject]@{
        UserId        = [string]$winner.UserId
        FriendlyName  = [string]$winner.FriendlyName
        Plays         = Safe-Int $winner.Plays
        MoviePlays    = Safe-Int $winner.MoviePlays
        TvPlays       = Safe-Int $winner.TvPlays
        QualifyingTitles = $winner.QualifyingTitleKeys.Count
        QualifyingMovies = $winner.QualifyingMovieKeys.Count
        QualifyingTvShows = $winner.QualifyingTvShowKeys.Count
        Seconds       = [int64]$winner.Seconds
        TotalTimeText = Format-WatchTime ([int64]$winner.Seconds)
    }
}

function Get-BingeChampionDisplay {
    param(
        [object]$BingeChampion,
        [object]$User
    )

    if ($null -eq $BingeChampion) {
        return [PSCustomObject]@{
            Available     = $false
            IsWinner      = $false
            TotalTimeText = ""
            Plays         = 0
            MoviePlays    = 0
            TvPlays       = 0
            QualifyingTitles = 0
            QualifyingMovies = 0
            QualifyingTvShows = 0
        }
    }

    $isWinner = $false
    $winnerId = [string]$BingeChampion.UserId
    if (-not [string]::IsNullOrWhiteSpace($winnerId) -and
        [string]$User.UserId -eq $winnerId) {
        $isWinner = $true
    }
    elseif ([string]::IsNullOrWhiteSpace($winnerId) -and
        [string]$User.FriendlyName -ieq [string]$BingeChampion.FriendlyName) {
        $isWinner = $true
    }

    $totalTimeText = [string]$BingeChampion.TotalTimeText
    if ([string]::IsNullOrWhiteSpace($totalTimeText)) {
        $totalTimeText = Format-WatchTime ([int64]$BingeChampion.Seconds)
    }

    $plays = if ($null -ne $BingeChampion.PSObject.Properties["Plays"]) {
        Safe-Int $BingeChampion.Plays
    } else {
        0
    }

    $qualifyingTitles = if ($null -ne $BingeChampion.PSObject.Properties["QualifyingTitles"]) {
        Safe-Int $BingeChampion.QualifyingTitles
    } else {
        0
    }
    $qualifyingMovies = if ($null -ne $BingeChampion.PSObject.Properties["QualifyingMovies"]) {
        Safe-Int $BingeChampion.QualifyingMovies
    } else {
        0
    }
    $qualifyingTvShows = if ($null -ne $BingeChampion.PSObject.Properties["QualifyingTvShows"]) {
        Safe-Int $BingeChampion.QualifyingTvShows
    } else {
        0
    }

    return [PSCustomObject]@{
        Available     = $true
        IsWinner      = $isWinner
        TotalTimeText = $totalTimeText
        Plays         = $plays
        MoviePlays    = Safe-Int $BingeChampion.MoviePlays
        TvPlays       = Safe-Int $BingeChampion.TvPlays
        QualifyingTitles = $qualifyingTitles
        QualifyingMovies = $qualifyingMovies
        QualifyingTvShows = $qualifyingTvShows
    }
}

function Get-BingeChampionTitleBreakdown {
    param([object]$BingeDisplay)

    $parts = New-Object System.Collections.Generic.List[string]
    $playCount = Safe-Int $BingeDisplay.Plays
    $movieCount = Safe-Int $BingeDisplay.QualifyingMovies
    $tvShowCount = Safe-Int $BingeDisplay.QualifyingTvShows
    $episodeCount = if ($null -ne $BingeDisplay.PSObject.Properties["TvPlays"]) {
        Safe-Int $BingeDisplay.TvPlays
    } else {
        0
    }

    if ($playCount -gt 0) {
        $playWord = if ($playCount -eq 1) { "play" } else { "plays" }
        $parts.Add("$playCount $playWord")
    }
    if ($movieCount -gt 0) {
        $movieWord = if ($movieCount -eq 1) { "movie" } else { "movies" }
        $parts.Add("$movieCount $movieWord")
    }
    if ($tvShowCount -gt 0) {
        $tvShowWord = if ($tvShowCount -eq 1) { "TV show" } else { "TV shows" }
        $tvSummary = "$tvShowCount $tvShowWord"
        if ($episodeCount -gt 1) {
            $tvSummary += ": $episodeCount episodes"
        }
        $parts.Add($tvSummary)
    }

    return ($parts -join " • ")
}

function Get-DesignPlexContext {
    if ($null -ne $script:DesignPlexContext) {
        return $script:DesignPlexContext
    }

    $serverUrl = ""
    $token = ""

    if ($null -ne $Config.PSObject.Properties["PlexServerUrl"] -and
        -not [string]::IsNullOrWhiteSpace([string]$Config.PlexServerUrl)) {
        $serverUrl = ([string]$Config.PlexServerUrl).TrimEnd("/")
    }

    if ($null -ne $Config.PSObject.Properties["PlexToken"] -and
        -not [string]::IsNullOrWhiteSpace([string]$Config.PlexToken)) {
        $token = [string]$Config.PlexToken
    }

    if ([string]::IsNullOrWhiteSpace($serverUrl)) {
        try {
            $serverInfo = Invoke-TautulliApi -Command "get_server_info"
        if ($null -ne $serverInfo.PSObject.Properties["pms_url"]) {
            $serverUrl = ([string]$serverInfo.pms_url).TrimEnd("/")
        }
    }
        catch {
            Write-Log "TautWeekly for Plex: could not retrieve Plex server URL from Tautulli: $($_.Exception.Message)" "WARN"
        }
    }

    # Prefer an explicitly supplied environment token when present when no
    # PlexToken was supplied in config.json.
    if ([string]::IsNullOrWhiteSpace($token) -and
        -not [string]::IsNullOrWhiteSpace([string]$env:PLEX_TOKEN)) {
        $token = [string]$env:PLEX_TOKEN
    }

    # In the Mac Docker container there is no host registry to inspect. Prefer an
    # explicit PlexToken, PLEX_TOKEN, or an optional read-only Tautulli
    # config.ini mount. Direct Plex access is optional; Tautulli fallbacks
    # remain available when no token can be resolved.
    if ([string]::IsNullOrWhiteSpace($token)) {
        $configCandidates = New-Object System.Collections.Generic.List[string]

        foreach ($candidate in @(
            [string]$env:TAUTULLI_CONFIG_PATH,
            "/tautulli/config.ini",
            "/config/config.ini",
            (Join-Path $DataRoot "tautulli-config.ini")
        )) {
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and
                -not $configCandidates.Contains($candidate)) {
                $configCandidates.Add($candidate)
            }
        }

        foreach ($candidatePath in $configCandidates) {
            if (-not (Test-Path $candidatePath)) { continue }

            try {
                foreach ($line in (Get-Content -Path $candidatePath -Encoding UTF8 -ErrorAction Stop)) {
                    if ($line -match '^\s*pms_token\s*=\s*(.+?)\s*$') {
                        $candidateToken = [string]$Matches[1]
                        if (-not [string]::IsNullOrWhiteSpace($candidateToken) -and
                            $candidateToken -notmatch '^(none|null)$') {
                            $token = $candidateToken.Trim()
                            Write-Log ("TautWeekly for Plex: Plex token loaded from mounted Tautulli config: " + $candidatePath)
                            break
                        }
                    }
                }
            }
            catch { }

            if (-not [string]::IsNullOrWhiteSpace($token)) { break }
        }
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Log "TautWeekly for Plex: Plex token unavailable from config, environment, or optional mounted Tautulli config." "WARN"
    }

    $available = (
        -not [string]::IsNullOrWhiteSpace($serverUrl) -and
        -not [string]::IsNullOrWhiteSpace($token)
    )

    $script:DesignPlexContext = [PSCustomObject]@{
        Available = $available
        ServerUrl = $serverUrl
        Token     = $token
    }

    if ($available) {
        Write-Log "TautWeekly for Plex: direct Plex metadata access enabled."
    }
    else {
        Write-Log "TautWeekly for Plex: direct Plex metadata unavailable; Tautulli fallbacks will be used." "WARN"
    }

    return $script:DesignPlexContext
}

function Invoke-DesignPlexJson {
    param([string]$Path)

    $ctx = Get-DesignPlexContext
    if (-not $ctx.Available) { return $null }

    $url = $ctx.ServerUrl + $Path
    $headers = @{
        "Accept"                 = "application/json"
        "X-Plex-Token"           = [string]$ctx.Token
        "X-Plex-Pms-Api-Version" = "1.2.2"
    }

    try {
        return Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec 60
    }
    catch {
        # Some PMS builds may reject the explicit API-version header.
        try {
            $headers.Remove("X-Plex-Pms-Api-Version")
            return Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec 60
        }
        catch {
            Write-Log "TautWeekly for Plex direct Plex request failed for $Path`: $($_.Exception.Message)" "WARN"
            return $null
        }
    }
}

function Test-TautWeeklyDirectPlexConnection {
    $ctx = Get-DesignPlexContext
    if (-not $ctx.Available) {
        Write-Log "Direct Plex verification skipped because no URL/token pair could be resolved. Tautulli-only fallback remains available, but complete movie RT critic/audience ratings, exact-episode IMDb/RT ratings, backgrounds, and selected logos may be unavailable." "WARN"
        return 3
    }

    try {
        $serverUri = $null
        if (-not [Uri]::TryCreate([string]$ctx.ServerUrl, [UriKind]::Absolute, [ref]$serverUri) -or
            $serverUri.Scheme -notin @("http", "https")) {
            throw "PlexServerUrl must be an absolute HTTP or HTTPS URL."
        }
        if (-not [string]::IsNullOrWhiteSpace($serverUri.UserInfo) -or
            -not [string]::IsNullOrWhiteSpace($serverUri.Query) -or
            -not [string]::IsNullOrWhiteSpace($serverUri.Fragment)) {
            throw "PlexServerUrl must not contain credentials, a query string, or a fragment."
        }
        if ($serverUri.IsLoopback) {
            Write-Log "PlexServerUrl resolves to this container's loopback. Use host.docker.internal, a shared-network Plex service name, or another trusted LAN URL when Plex runs outside TautWeekly." "WARN"
        }

        $headers = @{
            "Accept"       = "application/json"
            "X-Plex-Token" = [string]$ctx.Token
        }
        $identity = Invoke-WebRequest `
            -Uri ($ctx.ServerUrl + "/identity") `
            -Headers $headers `
            -Method Get `
            -TimeoutSec 15 `
            -UseBasicParsing
        $libraries = Invoke-WebRequest `
            -Uri ($ctx.ServerUrl + "/library/sections") `
            -Headers $headers `
            -Method Get `
            -TimeoutSec 15 `
            -UseBasicParsing

        if ([int]$identity.StatusCode -ne 200 -or [int]$libraries.StatusCode -ne 200 -or
            [string]$identity.Content -notmatch '(?i)"MediaContainer"|<MediaContainer' -or
            [string]$libraries.Content -notmatch '(?i)"MediaContainer"|<MediaContainer') {
            throw "Direct Plex verification received an unexpected response."
        }

        Write-Log ("Direct Plex verification passed: identity HTTP {0}; authenticated library HTTP {1}." -f `
            [int]$identity.StatusCode, [int]$libraries.StatusCode)
        return 0
    }
    catch {
        $safeFailure = "request or response validation failed"
        try {
            if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
                $safeFailure = "HTTP " + [int]$_.Exception.Response.StatusCode
            }
        }
        catch { }
        Write-Log ("Direct Plex verification failed ({0}). Confirm the private PlexServerUrl and PlexToken are valid and reachable from inside this runtime." -f $safeFailure) "ERROR"
        return 2
    }
}

function Invoke-DesignPlexLegacyJson {
    param([string]$Path)

    $ctx = Get-DesignPlexContext
    if (-not $ctx.Available) { return $null }

    $url = $ctx.ServerUrl + $Path
    $headers = @{
        "Accept"       = "application/json"
        "X-Plex-Token" = [string]$ctx.Token
    }

    try {
        return Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec 60
    }
    catch {
        Write-Log "TautWeekly for Plex legacy Plex request failed for $Path`: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Get-DesignPlexMetadata {
    param([string]$RatingKey)

    if ([string]::IsNullOrWhiteSpace($RatingKey)) { return $null }

    if ($script:DesignPlexMetadataCache.ContainsKey($RatingKey)) {
        return $script:DesignPlexMetadataCache[$RatingKey]
    }

    # Rating[] is optional, and its name collides case-insensitively with the
    # scalar rating field in PowerShell's JSON object model. Request the array
    # and omit that redundant scalar; Tautulli already retains the selected
    # provider fallback separately.
    $raw = Invoke-DesignPlexJson -Path (
        "/library/metadata/" +
        [Uri]::EscapeDataString($RatingKey) +
        "?includeOptionalElements=Rating&excludeFields=rating"
    )
    $meta = $null

    if ($null -ne $raw -and $null -ne $raw.PSObject.Properties["MediaContainer"]) {
        $container = $raw.MediaContainer
        if ($null -ne $container.PSObject.Properties["Metadata"]) {
            $rows = @($container.Metadata)
            if ($rows.Count -gt 0) {
                $meta = $rows[0]
            }
        }
    }

    # PMS response customization is best-effort. Some builds ignore the JSON
    # field exclusion or omit optional child elements there, while the same
    # local item exposes its provider Rating elements through native XML. Use
    # that response only when JSON lacks movie RT or exact-episode/show IMDb.
    $jsonRatings = @()
    if ($null -ne $meta -and $null -ne $meta.PSObject.Properties["Rating"]) {
        $jsonRatings = @($meta.Rating)
    }
    $metaType = (Get-OptionalStringProperty -InputObject $meta -Name "type").Trim().ToLowerInvariant()
    $needsXmlRatings = ($jsonRatings.Count -eq 0)
    if ($metaType -eq "movie") {
        $hasRtCritic = @($jsonRatings | Where-Object {
            (Get-OptionalStringProperty -InputObject $_ -Name "image") -like "rottentomatoes://image.rating.*" -and
            (Get-OptionalStringProperty -InputObject $_ -Name "type") -eq "critic" -and
            -not [string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $_ -Name "value"))
        }).Count -gt 0
        $hasRtAudience = @($jsonRatings | Where-Object {
            (Get-OptionalStringProperty -InputObject $_ -Name "image") -like "rottentomatoes://image.rating.*" -and
            (Get-OptionalStringProperty -InputObject $_ -Name "type") -eq "audience" -and
            -not [string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $_ -Name "value"))
        }).Count -gt 0
        $needsXmlRatings = (-not $hasRtCritic -or -not $hasRtAudience)
    }
    elseif ($metaType -in @("show", "episode")) {
        $needsXmlRatings = @($jsonRatings | Where-Object {
            (Get-OptionalStringProperty -InputObject $_ -Name "image") -like "imdb://image.rating*" -and
            -not [string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $_ -Name "value"))
        }).Count -eq 0
    }
    if ($needsXmlRatings) {
        try {
            $xml = Invoke-DesignPlexLegacyXml -Path (
                "/library/metadata/" +
                [Uri]::EscapeDataString($RatingKey) +
                "?includeOptionalElements=Rating"
            )
            $xmlRatings = @()
            if ($null -ne $xml) {
                foreach ($node in @($xml.SelectNodes("//Rating"))) {
                    if ($null -eq $node) { continue }

                    $xmlRatings += [PSCustomObject]@{
                        image = if ($null -ne $node.Attributes["image"]) { [string]$node.Attributes["image"].Value } else { "" }
                        type  = if ($null -ne $node.Attributes["type"])  { [string]$node.Attributes["type"].Value }  else { "" }
                        value = if ($null -ne $node.Attributes["value"]) { [string]$node.Attributes["value"].Value } else { "" }
                    }
                }
            }

            if ($xmlRatings.Count -gt 0) {
                if ($null -eq $meta) { $meta = [PSCustomObject]@{} }
                $mergedRatings = @($jsonRatings)
                foreach ($xmlRating in $xmlRatings) {
                    $duplicate = @($mergedRatings | Where-Object {
                        (Get-OptionalStringProperty -InputObject $_ -Name "image") -eq $xmlRating.image -and
                        (Get-OptionalStringProperty -InputObject $_ -Name "type") -eq $xmlRating.type -and
                        (Get-OptionalStringProperty -InputObject $_ -Name "value") -eq $xmlRating.value
                    }).Count -gt 0
                    if (-not $duplicate) { $mergedRatings += $xmlRating }
                }
                $meta | Add-Member -NotePropertyName "Rating" -NotePropertyValue @($mergedRatings) -Force
            }
        }
        catch {
            Write-Log "TautWeekly for Plex native XML rating fallback failed: $($_.Exception.Message)" "WARN"
        }
    }

    $script:DesignPlexMetadataCache[$RatingKey] = $meta
    return $meta
}

function Get-DesignEpisodeImdbRating {
    param(
        [string]$RatingKey,
        [AllowNull()][object]$TautulliMetadata = $null
    )

    if ([string]::IsNullOrWhiteSpace($RatingKey)) { return "" }

    $jsonRatings = @()
    $xmlRatings = @()
    $result = ""

    # Published Plex metadata exposes a Rating[] array. Episodes may include:
    #   image = imdb://image.rating
    #   type  = audience
    #   value = 8.1
    try {
        $plexMeta = Get-DesignPlexMetadata -RatingKey $RatingKey

        if ($null -ne $plexMeta -and
            $null -ne $plexMeta.PSObject.Properties["Rating"]) {

            foreach ($ratingEntry in @($plexMeta.Rating)) {
                $image = if ($null -ne $ratingEntry.PSObject.Properties["image"]) {
                    [string]$ratingEntry.image
                } else { "" }

                $value = if ($null -ne $ratingEntry.PSObject.Properties["value"]) {
                    [string]$ratingEntry.value
                } else { "" }

                $type = if ($null -ne $ratingEntry.PSObject.Properties["type"]) {
                    [string]$ratingEntry.type
                } else { "" }

                $jsonRatings += [PSCustomObject]@{
                    image = $image
                    type  = $type
                    value = $value
                }

                if ([string]::IsNullOrWhiteSpace($result) -and
                    $image -match '(?i)^imdb://image\.rating' -and
                    -not [string]::IsNullOrWhiteSpace($value)) {
                    $result = $value
                }
            }
        }
    }
    catch {
        Write-Log ("TautWeekly for Plex direct Plex IMDb JSON lookup failed for episode {0}: {1}" -f `
            $RatingKey,
            $_.Exception.Message
        ) "WARN"
    }

    # Legacy/local PMS metadata can also expose <Rating> elements even when
    # JSON serialization omits them. Use XML as a second native Plex source.
    if ([string]::IsNullOrWhiteSpace($result)) {
        try {
            $xml = Invoke-DesignPlexLegacyXml -Path (
                "/library/metadata/" +
                [Uri]::EscapeDataString($RatingKey) +
                "?includeOptionalElements=Rating"
            )

            if ($null -ne $xml) {
                foreach ($node in @($xml.SelectNodes("//Rating"))) {
                    if ($null -eq $node) { continue }

                    $image = ""
                    $value = ""
                    $type = ""

                    if ($null -ne $node.Attributes["image"]) {
                        $image = [string]$node.Attributes["image"].Value
                    }
                    if ($null -ne $node.Attributes["value"]) {
                        $value = [string]$node.Attributes["value"].Value
                    }
                    if ($null -ne $node.Attributes["type"]) {
                        $type = [string]$node.Attributes["type"].Value
                    }

                    $xmlRatings += [PSCustomObject]@{
                        image = $image
                        type  = $type
                        value = $value
                    }

                    if ([string]::IsNullOrWhiteSpace($result) -and
                        $image -match '(?i)^imdb://image\.rating' -and
                        -not [string]::IsNullOrWhiteSpace($value)) {
                        $result = $value
                    }
                }
            }
        }
        catch {
            Write-Log ("TautWeekly for Plex direct Plex IMDb XML lookup failed for episode {0}: {1}" -f `
                $RatingKey,
                $_.Exception.Message
            ) "WARN"
        }
    }

    # When nothing is found, leave a sanitized diagnostic so another miss is
    # immediately actionable without exposing tokens or media file paths.
    if ([string]::IsNullOrWhiteSpace($result)) {
        try {
            $tautRating = ""
            $tautRatingImage = ""

            if ($null -ne $TautulliMetadata) {
                if ($null -ne $TautulliMetadata.PSObject.Properties["rating"]) {
                    $tautRating = [string]$TautulliMetadata.rating
                }
                if ($null -ne $TautulliMetadata.PSObject.Properties["rating_image"]) {
                    $tautRatingImage = [string]$TautulliMetadata.rating_image
                }
            }

            [PSCustomObject]@{
                RatingKey          = $RatingKey
                TautulliRating     = $tautRating
                TautulliRatingImage = $tautRatingImage
                PlexJsonRatings    = $jsonRatings
                PlexXmlRatings     = $xmlRatings
            } |
                ConvertTo-Json -Depth 8 |
                Set-Content `
                    -Path (Join-Path $DesignMediaDir ("episode_rating_probe_" + (Get-SafeFilePart $RatingKey) + ".json")) `
                    -Encoding UTF8
        }
        catch { }
    }

    return $result
}

function Get-DesignEpisodeRtRating {
    param(
        [string]$RatingKey,
        [AllowNull()][object]$TautulliMetadata = $null
    )

    $empty = [PSCustomObject]@{ Value = ""; Image = ""; Kind = "" }
    if ([string]::IsNullOrWhiteSpace($RatingKey)) { return $empty }

    $critic = $null
    $audience = $null

    # The supplied metadata belongs to this exact episode. Preserve Plex's
    # provider/state identifier so the tomato/popcorn icon remains accurate.
    if ($null -ne $TautulliMetadata) {
        foreach ($candidate in @(
            [PSCustomObject]@{
                Image = Get-OptionalStringProperty -InputObject $TautulliMetadata -Name "rating_image"
                Value = Get-OptionalStringProperty -InputObject $TautulliMetadata -Name "rating"
                Kind = "critic"
            },
            [PSCustomObject]@{
                Image = Get-OptionalStringProperty -InputObject $TautulliMetadata -Name "audience_rating_image"
                Value = Get-OptionalStringProperty -InputObject $TautulliMetadata -Name "audience_rating"
                Kind = "audience"
            }
        )) {
            if ($candidate.Image -notlike "rottentomatoes://image.rating.*") { continue }
            $percent = Convert-DesignRatingPercent $candidate.Value
            if ([string]::IsNullOrWhiteSpace($percent)) { continue }

            $kind = [string]$candidate.Kind
            if ($candidate.Image -match '(?i)\.(upright|spilled)$') { $kind = "audience" }
            elseif ($candidate.Image -match '(?i)\.(ripe|rotten)$') { $kind = "critic" }
            $resolved = [PSCustomObject]@{ Value = $percent; Image = [string]$candidate.Image; Kind = $kind }
            if ($kind -eq "critic") { $critic = $resolved } else { $audience = $resolved }
        }
    }

    # Direct Plex may expose an alternate exact-episode RT entry even when
    # Tautulli flattened another selected provider.
    try {
        $plexMeta = Get-DesignPlexMetadata -RatingKey $RatingKey
        if ($null -ne $plexMeta -and $null -ne $plexMeta.PSObject.Properties["Rating"]) {
            foreach ($ratingEntry in @($plexMeta.Rating)) {
                $image = Get-OptionalStringProperty -InputObject $ratingEntry -Name "image"
                if ($image -notlike "rottentomatoes://image.rating.*") { continue }
                $percent = Convert-DesignRatingPercent (Get-OptionalStringProperty -InputObject $ratingEntry -Name "value")
                if ([string]::IsNullOrWhiteSpace($percent)) { continue }

                $kind = (Get-OptionalStringProperty -InputObject $ratingEntry -Name "type").Trim().ToLowerInvariant()
                if ($kind -notin @("critic", "audience")) {
                    if ($image -match '(?i)\.(upright|spilled)$') { $kind = "audience" }
                    else { $kind = "critic" }
                }
                $resolved = [PSCustomObject]@{ Value = $percent; Image = $image; Kind = $kind }
                if ($kind -eq "critic" -and $null -eq $critic) { $critic = $resolved }
                elseif ($kind -eq "audience" -and $null -eq $audience) { $audience = $resolved }
            }
        }
    }
    catch {
        Write-Log ("TautWeekly for Plex direct Plex RT lookup failed for episode {0}: {1}" -f `
            $RatingKey,
            $_.Exception.Message
        ) "WARN"
    }

    if ($null -ne $critic) { return $critic }
    if ($null -ne $audience) { return $audience }
    return $empty
}


function Get-DesignPlexImages {
    param([string]$RatingKey)

    if ([string]::IsNullOrWhiteSpace($RatingKey)) { return @() }

    $meta = Get-DesignPlexMetadata -RatingKey $RatingKey
    if ($null -ne $meta -and $null -ne $meta.PSObject.Properties["Image"]) {
        $images = @($meta.Image)
        if ($images.Count -gt 0) {
            return $images
        }
    }

    # Current Plex metadata providers expose an /images endpoint as well.
    $raw = Invoke-DesignPlexJson -Path (
        "/library/metadata/" + [Uri]::EscapeDataString($RatingKey) + "/images"
    )

    if ($null -ne $raw -and $null -ne $raw.PSObject.Properties["MediaContainer"]) {
        $container = $raw.MediaContainer
        if ($null -ne $container.PSObject.Properties["Image"]) {
            return @($container.Image)
        }
    }

    return @()
}

function Invoke-DesignPlexLegacyXml {
    param([string]$Path)

    $ctx = Get-DesignPlexContext
    if (-not $ctx.Available) {
        throw "Direct Plex context is unavailable."
    }

    $url = $ctx.ServerUrl + $Path
    $headers = @{
        "Accept" = "application/xml"
        "X-Plex-Token" = [string]$ctx.Token
    }

    try {
        $response = Invoke-WebRequest `
            -Uri $url `
            -Headers $headers `
            -Method Get `
            -UseBasicParsing `
            -TimeoutSec 60

        if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
            throw "Plex returned an empty response body."
        }

        return [xml]$response.Content
    }
    catch {
        throw "Raw Plex XML request failed for $Path`: $($_.Exception.Message)"
    }
}

function Get-ImageMagickTool {
    param([ValidateSet("identify","convert")][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $isWindowsVolumeConverter = $false
        if ($Name -eq "convert" -and
            -not [string]::IsNullOrWhiteSpace([string]$env:SystemRoot)) {
            $windowsConverter = Join-Path $env:SystemRoot "System32\convert.exe"
            $isWindowsVolumeConverter = [string]::Equals(
                [IO.Path]::GetFullPath([string]$command.Source),
                [IO.Path]::GetFullPath($windowsConverter),
                [StringComparison]::OrdinalIgnoreCase
            )
        }
        if (-not $isWindowsVolumeConverter) { return [string]$command.Source }
    }

    $magick = Get-Command "magick" -ErrorAction SilentlyContinue
    if ($null -ne $magick) { return [string]$magick.Source }

    return ""
}

function Get-DesignLogoVisualScore {
    param([string]$Path)

    $result = [PSCustomObject]@{
        Valid          = $false
        AverageLuma    = 0.0
        BrightFraction = 0.0
        Score          = 0.0
        Width          = 0
        Height         = 0
        Error          = ""
    }

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $result
    }

    try {
        $identify = Get-ImageMagickTool -Name "identify"
        $convert = Get-ImageMagickTool -Name "convert"
        if ([string]::IsNullOrWhiteSpace($identify) -or
            [string]::IsNullOrWhiteSpace($convert)) {
            throw "ImageMagick identify/convert commands are unavailable."
        }

        if ([IO.Path]::GetFileName($identify) -match '^magick(?:\.exe)?$') {
            $dimensions = (& $identify "identify" "-format" "%w %h" $Path 2>$null | Out-String).Trim()
        }
        else {
            $dimensions = (& $identify "-format" "%w %h" $Path 2>$null | Out-String).Trim()
        }

        if ($LASTEXITCODE -ne 0 -or $dimensions -notmatch '^(\d+)\s+(\d+)$') {
            throw "ImageMagick could not read logo dimensions."
        }

        $result.Width = [int]$Matches[1]
        $result.Height = [int]$Matches[2]
        if ($result.Width -le 0 -or $result.Height -le 0) {
            throw "Logo image has invalid dimensions."
        }

        $convertArgs = @(
            $Path,
            "-alpha", "on",
            "-resize", "220x220>",
            "-depth", "8",
            "txt:-"
        )

        if ([IO.Path]::GetFileName($convert) -match '^magick(?:\.exe)?$') {
            $pixelLines = @(& $convert "convert" @convertArgs 2>$null)
        }
        else {
            $pixelLines = @(& $convert @convertArgs 2>$null)
        }

        if ($LASTEXITCODE -ne 0 -or $pixelLines.Count -eq 0) {
            throw "ImageMagick could not sample logo pixels."
        }

        [double]$weightedLuma = 0
        [double]$totalWeight = 0
        [double]$brightWeight = 0

        foreach ($line in $pixelLines) {
            # ImageMagick txt: output at 8-bit depth normally begins with:
            # 0,0: (R,G,B,A) ...
            if ([string]$line -notmatch '^\s*\d+,\d+:\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)') {
                continue
            }

            $red = [double]$Matches[1]
            $green = [double]$Matches[2]
            $blue = [double]$Matches[3]
            $alpha = [double]$Matches[4]
            if ($alpha -lt 32) { continue }

            $alphaWeight = $alpha / 255.0
            $luma = ((0.2126 * $red) + (0.7152 * $green) + (0.0722 * $blue)) / 255.0
            $weightedLuma += ($luma * $alphaWeight)
            $totalWeight += $alphaWeight
            if ($luma -ge 0.62) { $brightWeight += $alphaWeight }
        }

        if ($totalWeight -le 0) {
            throw "Logo contains no visible pixels."
        }

        $averageLuma = $weightedLuma / $totalWeight
        $brightFraction = $brightWeight / $totalWeight
        $score = ($averageLuma * 0.75) + ($brightFraction * 0.25)

        $result.Valid = $true
        $result.AverageLuma = [Math]::Round($averageLuma, 4)
        $result.BrightFraction = [Math]::Round($brightFraction, 4)
        $result.Score = [Math]::Round($score, 4)
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Get-DesignBestClearLogoAsset {
    param([string]$RatingKey)

    $result = [PSCustomObject]@{
        LogoSrc       = ""
        CandidateCount = 0
        ReadableCount = 0
        ChosenIndex   = -1
        ChosenScore   = 0.0
        ChosenWasPlexSelected = $false
    }

    if ([string]::IsNullOrWhiteSpace($RatingKey)) {
        return $result
    }

    $safeKey = Get-SafeFilePart $RatingKey
    $diagPath = Join-Path $DesignMediaDir ("clearlogos_probe_" + $safeKey + ".json")
    $rawPath = Join-Path $DesignMediaDir ("clearlogos_raw_" + $safeKey + ".xml")

    $diag = [ordered]@{
        RatingKey = $RatingKey
        RequestPath = "/library/metadata/$RatingKey/clearLogos"
        PhotoCount = 0
        Candidates = @()
        ChosenIndex = -1
        ChosenScore = 0
        ChosenWasPlexSelected = $false
        Decision = ""
        Error = ""
    }

    $candidateFiles = New-Object System.Collections.Generic.List[string]

    try {
        $xml = Invoke-DesignPlexLegacyXml -Path (
            "/library/metadata/" +
            [Uri]::EscapeDataString($RatingKey) +
            "/clearLogos"
        )

        try { $xml.Save($rawPath) } catch { }

        if ($null -eq $xml.MediaContainer) {
            throw "XML response did not contain MediaContainer."
        }

        $photos = @(
            @($xml.MediaContainer.Photo) |
            Where-Object { $null -ne $_ }
        )

        $result.CandidateCount = $photos.Count
        $diag.PhotoCount = $photos.Count

        if ($photos.Count -eq 0) {
            throw "Plex returned zero clearLogo candidates."
        }

        $scored = @()

        for ($i = 0; $i -lt $photos.Count; $i++) {
            $photo = $photos[$i]

            $logoPath = ""
            if (-not [string]::IsNullOrWhiteSpace([string]$photo.thumb)) {
                $logoPath = [string]$photo.thumb
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$photo.key)) {
                $logoPath = [string]$photo.key
            }

            $candidateName = "logo_candidate_{0}_{1}.img" -f $safeKey, $i
            $candidateRel = ""

            if (-not [string]::IsNullOrWhiteSpace($logoPath)) {
                $candidateRel = Get-DesignPlexAsset `
                    -Url $logoPath `
                    -OutputName $candidateName
            }

            $localPath = if ([string]::IsNullOrWhiteSpace($candidateRel)) {
                ""
            }
            else {
                Join-Path $DesignMediaDir $candidateName
            }

            if (-not [string]::IsNullOrWhiteSpace($localPath)) {
                $candidateFiles.Add($localPath)
            }

            $visual = Get-DesignLogoVisualScore -Path $localPath
            if (-not $visual.Valid -and -not [string]::IsNullOrWhiteSpace($localPath)) {
                # The container packages ship ImageMagick, but their shared
                # source is also validated on Windows hosts. If ImageMagick is
                # unavailable there, use the same managed decoder as the
                # native Windows package to confirm the candidate is usable.
                $fallbackBitmap = $null
                try {
                    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
                    $fallbackBitmap = New-Object System.Drawing.Bitmap([string]$localPath)
                    if ($fallbackBitmap.Width -gt 0 -and $fallbackBitmap.Height -gt 0) {
                        $visual.Width = $fallbackBitmap.Width
                        $visual.Height = $fallbackBitmap.Height

                        $largestDimension = [Math]::Max($fallbackBitmap.Width, $fallbackBitmap.Height)
                        $step = [Math]::Max(1, [int][Math]::Floor($largestDimension / 220.0))
                        [double]$weightedLuma = 0
                        [double]$totalWeight = 0
                        [double]$brightWeight = 0

                        for ($y = 0; $y -lt $fallbackBitmap.Height; $y += $step) {
                            for ($x = 0; $x -lt $fallbackBitmap.Width; $x += $step) {
                                $pixel = $fallbackBitmap.GetPixel($x, $y)
                                if ($pixel.A -lt 32) { continue }

                                $alphaWeight = $pixel.A / 255.0
                                $luma = (
                                    (0.2126 * $pixel.R) +
                                    (0.7152 * $pixel.G) +
                                    (0.0722 * $pixel.B)
                                ) / 255.0
                                $weightedLuma += ($luma * $alphaWeight)
                                $totalWeight += $alphaWeight
                                if ($luma -ge 0.62) {
                                    $brightWeight += $alphaWeight
                                }
                            }
                        }

                        if ($totalWeight -gt 0) {
                            $averageLuma = $weightedLuma / $totalWeight
                            $brightFraction = $brightWeight / $totalWeight
                            $visual.Valid = $true
                            $visual.AverageLuma = [Math]::Round($averageLuma, 4)
                            $visual.BrightFraction = [Math]::Round($brightFraction, 4)
                            $visual.Score = [Math]::Round((($averageLuma * 0.75) + ($brightFraction * 0.25)), 4)
                            $visual.Error = ""
                        }
                    }
                }
                catch { }
                finally {
                    if ($null -ne $fallbackBitmap) {
                        $fallbackBitmap.Dispose()
                    }
                }
            }
            $isSelected = ([string]$photo.selected -eq "1")

            $entry = [PSCustomObject]@{
                Index          = $i
                Selected       = $isSelected
                RatingKey      = [string]$photo.ratingKey
                Valid          = [bool]$visual.Valid
                AverageLuma    = [double]$visual.AverageLuma
                BrightFraction = [double]$visual.BrightFraction
                Score          = [double]$visual.Score
                Width          = [int]$visual.Width
                Height         = [int]$visual.Height
                LocalPath      = $localPath
                Error          = [string]$visual.Error
            }

            $scored += $entry

            $diag.Candidates += [PSCustomObject]@{
                Index          = $entry.Index
                Selected       = $entry.Selected
                RatingKey      = $entry.RatingKey
                Valid          = $entry.Valid
                AverageLuma    = $entry.AverageLuma
                BrightFraction = $entry.BrightFraction
                Score          = $entry.Score
                Width          = $entry.Width
                Height         = $entry.Height
                Error          = $entry.Error
            }
        }

        $readable = @(
            $scored |
            Where-Object {
                $_.Valid -and
                $_.Score -ge 0.36
            }
        )

        $result.ReadableCount = $readable.Count

        if ($readable.Count -eq 0) {
            $diag.Decision = "No sufficiently bright clearLogo candidate; continue alternate logo fallbacks."
            Write-Log "TautWeekly for Plex: clearLogo variants exist, but none meet the dark-hero readability threshold. Trying alternate logo sources." "WARN"
            return $result
        }

        $ranked = @(
            $readable |
            Sort-Object `
                @{ Expression = "Score"; Descending = $true },
                @{ Expression = "Selected"; Descending = $true }
        )

        $chosen = $ranked[0]

        # If Plex's selected variant is essentially tied with the brightest
        # option, preserve Plex's choice. Otherwise readability wins.
        $selectedReadable = @(
            $readable |
            Where-Object { $_.Selected } |
            Select-Object -First 1
        )

        if ($selectedReadable.Count -gt 0) {
            $scoreGap = [double]$chosen.Score - [double]$selectedReadable[0].Score
            if ($scoreGap -le 0.035) {
                $chosen = $selectedReadable[0]
            }
        }

        $result.ChosenIndex = [int]$chosen.Index
        $result.ChosenScore = [double]$chosen.Score
        $result.ChosenWasPlexSelected = [bool]$chosen.Selected

        $diag.ChosenIndex = $result.ChosenIndex
        $diag.ChosenScore = $result.ChosenScore
        $diag.ChosenWasPlexSelected = $result.ChosenWasPlexSelected

        $finalName = "logo_" + $safeKey + ".png"
        $finalPath = Join-Path $DesignMediaDir $finalName

        $converted = $false
        $convert = Get-ImageMagickTool -Name "convert"
        if (-not [string]::IsNullOrWhiteSpace($convert)) {
            if ([IO.Path]::GetFileName($convert) -match '^magick(?:\.exe)?$') {
                & $convert "convert" ([string]$chosen.LocalPath) "PNG32:$finalPath" 2>$null
            }
            else {
                & $convert ([string]$chosen.LocalPath) "PNG32:$finalPath" 2>$null
            }
            $converted = ($LASTEXITCODE -eq 0 -and (Test-Path $finalPath))
        }

        if (-not $converted) {
            $fallbackBitmap = $null
            try {
                Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
                $fallbackBitmap = New-Object System.Drawing.Bitmap([string]$chosen.LocalPath)
                $fallbackBitmap.Save($finalPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $converted = (Test-Path $finalPath)
            }
            catch { }
            finally {
                if ($null -ne $fallbackBitmap) {
                    $fallbackBitmap.Dispose()
                }
            }
        }

        if (-not $converted) {
            throw "ImageMagick could not convert the chosen clearLogo to PNG."
        }

        if ((Test-Path $finalPath) -and (Get-Item $finalPath).Length -gt 256) {
            $result.LogoSrc = "media/" + $finalName
            $diag.Decision = "Chose highest-contrast clearLogo for #181818 email hero."

            Write-Log (
                "TautWeekly for Plex: chose clearLogo candidate {0}/{1} for dark hero (score {2}; Plex selected={3})." -f `
                ($result.ChosenIndex + 1),
                $result.CandidateCount,
                $result.ChosenScore,
                $result.ChosenWasPlexSelected
            )
        }
    }
    catch {
        $diag.Error = $_.Exception.Message
        Write-Log ("TautWeekly for Plex clearLogo selection failed: " + $diag.Error) "WARN"
    }
    finally {
        foreach ($candidateFile in $candidateFiles) {
            Remove-Item $candidateFile -Force -ErrorAction SilentlyContinue
        }

        try {
            [PSCustomObject]$diag |
                ConvertTo-Json -Depth 10 |
                Set-Content -Path $diagPath -Encoding UTF8
        }
        catch { }
    }

    return $result
}

function Save-DesignPlexDiagnostic {
    param(
        [string]$RatingKey,
        [object]$Metadata,
        [object[]]$Images
    )

    if ([string]::IsNullOrWhiteSpace($RatingKey)) { return }

    $ratings = @()
    if ($null -ne $Metadata -and $null -ne $Metadata.PSObject.Properties["Rating"]) {
        foreach ($r in @($Metadata.Rating)) {
            $ratings += [PSCustomObject]@{
                image = if ($null -ne $r.PSObject.Properties["image"]) { [string]$r.image } else { "" }
                type  = if ($null -ne $r.PSObject.Properties["type"])  { [string]$r.type }  else { "" }
                value = if ($null -ne $r.PSObject.Properties["value"]) { $r.value } else { $null }
            }
        }
    }

    $imageSummary = @()
    foreach ($img in @($Images)) {
        $imageSummary += [PSCustomObject]@{
            type = if ($null -ne $img.PSObject.Properties["type"]) { [string]$img.type } else { "" }
            url  = if ($null -ne $img.PSObject.Properties["url"])  { [string]$img.url }  else { "" }
            alt  = if ($null -ne $img.PSObject.Properties["alt"])  { [string]$img.alt }  else { "" }
        }
    }

    $diag = [PSCustomObject]@{
        RatingKey = $RatingKey
        Title = if ($null -ne $Metadata -and $null -ne $Metadata.PSObject.Properties["title"]) {
            [string]$Metadata.title
        } else {
            ""
        }
        Ratings = $ratings
        Images  = $imageSummary
    }

    $diagName = "plex_design_diagnostic_" + (Get-SafeFilePart $RatingKey) + ".json"
    $diagPath = Join-Path $DesignMediaDir $diagName
    $diag | ConvertTo-Json -Depth 8 | Set-Content -Path $diagPath -Encoding UTF8

    Write-Log "TautWeekly for Plex: saved Plex rating/image diagnostic to preview-output\media\$diagName"
}

function Get-DesignPlexAsset {
    param(
        [string]$Url,
        [string]$OutputName
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return "" }

    $local = Join-Path $DesignMediaDir $OutputName
    $ctx = Get-DesignPlexContext

    try {
        if ($Url -match '^https?://') {
            Invoke-WebRequest -Uri $Url -OutFile $local -TimeoutSec 60 | Out-Null
        }
        elseif ($ctx.Available) {
            $assetUrl = $ctx.ServerUrl + $Url
            $headers = @{ "X-Plex-Token" = [string]$ctx.Token }
            Invoke-WebRequest -Uri $assetUrl -Headers $headers -OutFile $local -TimeoutSec 60 | Out-Null
        }
        else {
            return ""
        }

        if ((Test-Path $local) -and (Get-Item $local).Length -gt 256) {
            return "media/" + $OutputName
        }
    }
    catch {
        Write-Log "TautWeekly for Plex: Plex asset download failed ($OutputName): $($_.Exception.Message)" "WARN"
    }

    Remove-Item $local -Force -ErrorAction SilentlyContinue
    return ""
}


$script:DesignRichExportCache = @{}

function Find-DesignProviderRatingsRecursive {
    param(
        [AllowNull()][object]$Node,
        [ref]$Critic,
        [ref]$Audience,
        [ref]$Imdb,
        [ref]$Provider,
        [ref]$ProviderValue
    )

    if ($null -eq $Node) { return }

    if ($Node -is [string] -or
        $Node -is [ValueType]) {
        return
    }

    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($child in $Node) {
            Find-DesignProviderRatingsRecursive `
                -Node $child `
                -Critic $Critic `
                -Audience $Audience `
                -Imdb $Imdb `
                -Provider $Provider `
                -ProviderValue $ProviderValue
        }
        return
    }

    # Look for an object that itself represents a Plex Rating entry.
    try {
        $props = $Node.PSObject.Properties
        if ($null -ne $props) {
            # Tautulli's item exporter serializes the selected Plex ratings as
            # flat fields. Accept both its camelCase names and the snake_case
            # shape returned by get_metadata without treating an unlabeled
            # numeric rating as provider-labelled data.
            $ratingImage = Get-OptionalStringProperty -InputObject $Node -Name "ratingImage"
            if ([string]::IsNullOrWhiteSpace($ratingImage)) {
                $ratingImage = Get-OptionalStringProperty -InputObject $Node -Name "rating_image"
            }
            $ratingValue = Get-OptionalStringProperty -InputObject $Node -Name "rating"
            if ([string]::IsNullOrWhiteSpace($Imdb.Value) -and
                $ratingImage -like "imdb://image.rating*") {
                $Imdb.Value = $ratingValue
            }
            elseif ([string]::IsNullOrWhiteSpace($Critic.Value) -and
                $ratingImage -like "rottentomatoes://image.rating.*") {
                $Critic.Value = Convert-DesignRatingPercent $ratingValue
            }

            $audienceImage = Get-OptionalStringProperty -InputObject $Node -Name "audienceRatingImage"
            if ([string]::IsNullOrWhiteSpace($audienceImage)) {
                $audienceImage = Get-OptionalStringProperty -InputObject $Node -Name "audience_rating_image"
            }
            $audienceValue = Get-OptionalStringProperty -InputObject $Node -Name "audienceRating"
            if ([string]::IsNullOrWhiteSpace($audienceValue)) {
                $audienceValue = Get-OptionalStringProperty -InputObject $Node -Name "audience_rating"
            }
            if ([string]::IsNullOrWhiteSpace($Audience.Value) -and
                $audienceImage -like "rottentomatoes://image.rating.*") {
                $Audience.Value = Convert-DesignRatingPercent $audienceValue
            }

            if ([string]::IsNullOrWhiteSpace($Provider.Value)) {
                $selected = Get-DesignProviderRating `
                    -RatingImage $ratingImage `
                    -RatingValue $ratingValue `
                    -AudienceImage $audienceImage `
                    -AudienceValue $audienceValue
                $Provider.Value = $selected.Provider
                $ProviderValue.Value = $selected.Value
            }

            $imageProp = $props["image"]
            $valueProp = $props["value"]

            if ($null -ne $imageProp -and $null -ne $valueProp) {
                $image = [string]$imageProp.Value
                $value = $valueProp.Value
                $type = Get-OptionalStringProperty -InputObject $Node -Name "type"

                if ($image -like "imdb://image.rating*" -and
                    [string]::IsNullOrWhiteSpace($Imdb.Value)) {
                    $Imdb.Value = [string]$value
                }
                elseif ($image -like "rottentomatoes://image.rating.*") {
                    $percent = Convert-DesignRatingPercent $value
                    if ($type -eq "critic" -or $image -match '(?i)\.(ripe|rotten)$') {
                        if ([string]::IsNullOrWhiteSpace($Critic.Value)) {
                            $Critic.Value = $percent
                        }
                    }
                    elseif ($type -eq "audience" -or $image -match '(?i)\.(upright|spilled)$') {
                        if ([string]::IsNullOrWhiteSpace($Audience.Value)) {
                            $Audience.Value = $percent
                        }
                    }
                }
                elseif ([string]::IsNullOrWhiteSpace($Provider.Value)) {
                    $selected = Get-DesignProviderRating -RatingImage $image -RatingValue $value
                    $Provider.Value = $selected.Provider
                    $ProviderValue.Value = $selected.Value
                }
            }

            foreach ($p in $props) {
                Find-DesignProviderRatingsRecursive `
                    -Node $p.Value `
                    -Critic $Critic `
                    -Audience $Audience `
                    -Imdb $Imdb `
                    -Provider $Provider `
                    -ProviderValue $ProviderValue
            }
            return
        }
    }
    catch { }

}

function Get-DesignLogoExportSimple {
    param(
        [string]$RatingKey,
        [string]$MediaType = "movie"
    )

    $safeKey = Get-SafeFilePart $RatingKey
    $diagPath = Join-Path $DesignMediaDir ("logo_probe_" + $safeKey + ".json")
    $zipPath = Join-Path $DesignMediaDir ("logo_probe_" + $safeKey + ".zip")
    $extractPath = Join-Path $DesignMediaDir ("logo_probe_" + $safeKey)

    $diag = [ordered]@{
        RatingKey = $RatingKey
        MediaType = $MediaType
        TautulliVersion = ""
        LogoFields = @()
        RequestedLogoLevel = 9
        ExportId = 0
        Complete = $false
        Downloaded = $false
        IsZip = $false
        ExportedFiles = @()
        LogoFound = $false
        LogoSrc = ""
        Error = ""
    }

    $exportId = 0

    try {
        try {
            $info = Invoke-TautulliApi -Command "get_tautulli_info"
            if ($null -ne $info.PSObject.Properties["tautulli_version"]) {
                $diag.TautulliVersion = [string]$info.tautulli_version
            }
        }
        catch { }

        $logoFields = New-Object System.Collections.Generic.List[string]
        try {
            $fieldInfo = Invoke-TautulliApi -Command "get_export_fields" -Parameters @{
                media_type = $MediaType
                sub_media_type = $MediaType
            }

            foreach ($field in @($fieldInfo.metadata_fields)) {
                $fieldName = [string]$field.field
                if ($fieldName -match '(?i)logo') {
                    if (-not $logoFields.Contains($fieldName)) {
                        $logoFields.Add($fieldName)
                    }
                }
            }

            $diag.LogoFields = @($logoFields)
        }
        catch { }

        Write-Log "TautWeekly for Plex: requesting selected logo from Tautulli exporter (level 9)..."

        $exportParams = @{
            rating_key       = $RatingKey
            file_format      = "json"
            metadata_level   = 1
            media_info_level = 0
            thumb_level      = 0
            art_level        = 0
            logo_level       = 9
            squareArt_level  = 0
            theme_level      = 0
        }

        if ($logoFields.Count -gt 0) {
            $exportParams.custom_fields = ($logoFields -join ",")
        }

        $request = Invoke-TautulliApi -Command "export_metadata" -Parameters $exportParams

        # original inline parameter block removed below
                $exportId = Safe-Int $request.export_id
        $diag.ExportId = $exportId

        if ($exportId -le 0) {
            throw "Tautulli did not return an export_id."
        }

        $row = $null
        for ($i = 0; $i -lt 90; $i++) {
            Start-Sleep -Milliseconds 750

            $table = Invoke-TautulliApi -Command "get_exports_table" -Parameters @{
                length = 250
            }

            $matches = @(
                $table.data |
                Where-Object { (Safe-Int $_.export_id) -eq $exportId } |
                Select-Object -First 1
            )

            if ($matches.Count -gt 0) {
                $row = $matches[0]

                if ((Safe-Int $row.complete) -eq 1) {
                    $diag.Complete = $true
                    break
                }
            }
        }

        if (-not $diag.Complete) {
            throw "Logo export did not complete within the timeout."
        }

        $downloadUri = Build-TautulliUri -Command "download_export" -Parameters @{
            export_id = $exportId
        }

        Invoke-WebRequest `
            -Uri $downloadUri `
            -OutFile $zipPath `
            -TimeoutSec 120 | Out-Null

        if (-not (Test-Path $zipPath)) {
            throw "Tautulli download_export did not create a file."
        }

        $diag.Downloaded = $true

        $bytes = [IO.File]::ReadAllBytes($zipPath)
        $isZip = ($bytes.Length -ge 2 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B)
        $diag.IsZip = $isZip

        if (-not $isZip) {
            $rawBin = Join-Path $DesignMediaDir ("logo_probe_" + $safeKey + "_download.bin")
            Copy-Item -Path $zipPath -Destination $rawBin -Force

            try {
                $rawText = Get-Content -Path $zipPath -Raw -Encoding UTF8
                if (-not [string]::IsNullOrWhiteSpace($rawText)) {
                    Set-Content `
                        -Path (Join-Path $DesignMediaDir ("logo_probe_" + $safeKey + "_download.txt")) `
                        -Value $rawText `
                        -Encoding UTF8
                }
            }
            catch { }

            throw "Tautulli returned a single data file instead of a ZIP; no logo image was included."
        }

        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $extractPath | Out-Null
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

        $files = @(
            Get-ChildItem -Path $extractPath -Recurse -File -ErrorAction SilentlyContinue
        )

        $diag.ExportedFiles = @($files | ForEach-Object { $_.Name })

        $imageFiles = @(
            $files |
            Where-Object { $_.Extension -match '^\.(png|svg|webp|jpg|jpeg)$' }
        )

        # Prefer filenames explicitly containing logo; otherwise a logo-only
        # level-9 export with a single image is unambiguous.
        $candidate = @(
            $imageFiles |
            Where-Object { $_.Name -match '(?i)logo' } |
            Sort-Object Length -Descending |
            Select-Object -First 1
        )

        if ($candidate.Count -eq 0 -and $imageFiles.Count -eq 1) {
            $candidate = @($imageFiles[0])
        }

        if ($candidate.Count -gt 0) {
            $ext = $candidate[0].Extension.ToLowerInvariant()
            $finalName = "logo_" + $safeKey + $ext
            $finalPath = Join-Path $DesignMediaDir $finalName

            Copy-Item -Path $candidate[0].FullName -Destination $finalPath -Force

            if ((Test-Path $finalPath) -and (Get-Item $finalPath).Length -gt 64) {
                $diag.LogoFound = $true
                $diag.LogoSrc = "media/" + $finalName
            }
        }

        if (-not $diag.LogoFound) {
            throw "Export completed, but no logo image was found in the archive."
        }

        Write-Log "TautWeekly for Plex: selected logo acquired through Tautulli exporter."
    }
    catch {
        $diag.Error = $_.Exception.Message
        Write-Log ("TautWeekly for Plex logo probe failed: " + $diag.Error) "WARN"
    }
    finally {
        try {
            [PSCustomObject]$diag |
                ConvertTo-Json -Depth 8 |
                Set-Content -Path $diagPath -Encoding UTF8
        }
        catch { }

        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue

        if ($exportId -gt 0) {
            try {
                Invoke-TautulliApi -Command "delete_export" -Parameters @{
                    export_id = $exportId
                } | Out-Null
            }
            catch { }
        }
    }

    return [PSCustomObject]@{
        LogoSrc = [string]$diag.LogoSrc
        DiagnosticFile = "media/logo_probe_" + $safeKey + ".json"
    }
}

function Get-DesignRichExport {
    param(
        [string]$RatingKey,
        [string]$MediaType = "movie",
        [bool]$NeedLogo = $false
    )

    if ([string]::IsNullOrWhiteSpace($RatingKey)) {
        return [PSCustomObject]@{
            RtCritic = ""
            RtAudience = ""
            Imdb = ""
            Provider = ""
            ProviderValue = ""
            LogoSrc = ""
            DiagnosticFile = ""
        }
    }

    $cacheKey = $RatingKey + "|" + $NeedLogo
    if ($script:DesignRichExportCache.ContainsKey($cacheKey)) {
        return $script:DesignRichExportCache[$cacheKey]
    }

    $safeKey = Get-SafeFilePart $RatingKey
    $exportId = 0
    $tmpRoot = Join-Path $DesignMediaDir ("rich_export_" + $safeKey)
    $downloadPath = Join-Path $DesignMediaDir ("rich_export_" + $safeKey + ".zip")
    $diagPath = Join-Path $DesignMediaDir ("rich_export_" + $safeKey + ".json")

    $result = [PSCustomObject]@{
        RtCritic = ""
        RtAudience = ""
        Imdb = ""
        Provider = ""
        ProviderValue = ""
        LogoSrc = ""
        DiagnosticFile = ""
    }

    try {
        # Always request Plex's stable provider-labelled rating fields. Some
        # Tautulli versions place them outside metadata level 1, and current
        # get_export_fields implementations require a non-null subtype even
        # though their API documentation calls it optional.
        $customFields = New-Object System.Collections.Generic.List[string]
        $providerRatingFields = @("rating", "ratingImage", "audienceRating", "audienceRatingImage")
        foreach ($name in $providerRatingFields) {
            $customFields.Add($name)
        }
        try {
            $fieldInfo = Invoke-TautulliApi -Command "get_export_fields" -Parameters @{
                media_type = $MediaType
                sub_media_type = $MediaType
            }

            foreach ($field in @($fieldInfo.metadata_fields)) {
                $name = [string]$field.field
                if ($name -in $providerRatingFields -or ($NeedLogo -and $name -match '(?i)logo')) {
                    if (-not $customFields.Contains($name)) {
                        $customFields.Add($name)
                    }
                }
            }
        }
        catch {
            Write-Log "TautWeekly for Plex: could not enumerate additional exporter fields; requesting the standard provider-labelled rating fields." "WARN"
        }

        $params = @{
            rating_key       = $RatingKey
            file_format      = "json"
            # Availability differs by media type (show exports can omit
            # ratingImage), so the selected provider fields are also requested
            # explicitly. Higher levels can add private media paths that this
            # presentation fallback never needs.
            metadata_level   = 1
            media_info_level = 0
            thumb_level      = 0
            art_level        = 0
            logo_level       = $(if ($NeedLogo) { 9 } else { 0 })
            squareArt_level  = 0
            theme_level      = 0
            # Tautulli rejects individual_files for a rating_key item export.
            # Resource-bearing item exports are zipped automatically; a
            # rating-only item export is returned as a single JSON file.
            individual_files = "false"
        }

        if ($customFields.Count -gt 0) {
            $params.custom_fields = ($customFields -join ",")
        }

        Write-Log ("TautWeekly for Plex: Tautulli item export for {0} (provider-labelled rating fields{1})..." -f `
            $RatingKey,
            $(if ($NeedLogo) { " + selected logo level 9" } else { "" })
        )

        $request = Invoke-TautulliApi -Command "export_metadata" -Parameters $params
        $exportId = Safe-Int $request.export_id

        if ($exportId -le 0) {
            throw "Tautulli did not return an export id."
        }

        $complete = $false
        for ($i = 0; $i -lt 75; $i++) {
            Start-Sleep -Milliseconds 800

            $table = Invoke-TautulliApi -Command "get_exports_table" -Parameters @{
                rating_key = $RatingKey
                length = 100
            }

            $rows = @(
                $table.data |
                Where-Object { (Safe-Int $_.export_id) -eq $exportId } |
                Select-Object -First 1
            )

            if ($rows.Count -gt 0 -and (Safe-Int $rows[0].complete) -eq 1) {
                $complete = $true
                break
            }
        }

        if (-not $complete) {
            throw "Tautulli rich metadata export did not complete within 60 seconds."
        }

        $downloadUri = Build-TautulliUri -Command "download_export" -Parameters @{
            export_id = $exportId
        }

        Invoke-WebRequest `
            -Uri $downloadUri `
            -OutFile $downloadPath `
            -TimeoutSec 120 | Out-Null

        if (-not (Test-Path $downloadPath) -or (Get-Item $downloadPath).Length -eq 0) {
            throw "Downloaded export was empty."
        }

        $critic = ""
        $audience = ""
        $imdb = ""
        $provider = ""
        $providerValue = ""
        $jsonFiles = @()
        $exportedFiles = @()
        $bytes = [IO.File]::ReadAllBytes($downloadPath)
        $isZip = ($bytes.Length -ge 2 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B)

        if ($isZip) {
            Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
            Expand-Archive -Path $downloadPath -DestinationPath $tmpRoot -Force

            $exportedFiles = @(
                Get-ChildItem -Path $tmpRoot -Recurse -File -ErrorAction SilentlyContinue
            )
            $jsonFiles = @($exportedFiles | Where-Object { $_.Extension -ieq ".json" })

            foreach ($jsonFile in $jsonFiles) {
                try {
                    $parsed = Get-Content -Path $jsonFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    Find-DesignProviderRatingsRecursive `
                        -Node $parsed `
                        -Critic ([ref]$critic) `
                        -Audience ([ref]$audience) `
                        -Imdb ([ref]$imdb) `
                        -Provider ([ref]$provider) `
                        -ProviderValue ([ref]$providerValue)

                    if (-not [string]::IsNullOrWhiteSpace($critic) -and
                        -not [string]::IsNullOrWhiteSpace($audience)) {
                        break
                    }
                }
                catch { }
            }
        }
        else {
            try {
                $parsed = Get-Content -Path $downloadPath -Raw -Encoding UTF8 | ConvertFrom-Json
                Find-DesignProviderRatingsRecursive `
                    -Node $parsed `
                    -Critic ([ref]$critic) `
                    -Audience ([ref]$audience) `
                    -Imdb ([ref]$imdb) `
                    -Provider ([ref]$provider) `
                    -ProviderValue ([ref]$providerValue)
            }
            catch {
                throw "Downloaded item export was neither a ZIP archive nor valid JSON."
            }
        }

        $result.RtCritic = $critic
        $result.RtAudience = $audience
        $result.Imdb = $imdb
        $result.Provider = $provider
        $result.ProviderValue = $providerValue

        if ($NeedLogo) {
            if (-not $isZip) {
                throw "Tautulli returned rating JSON without the requested logo resource."
            }
            $imageFiles = @(
                $exportedFiles |
                Where-Object {
                    $_.Extension -match '^\.(png|jpg|jpeg|webp|svg)$'
                }
            )

            $logoCandidate = @(
                $imageFiles |
                Where-Object { $_.Name -match '(?i)clear.?logo|logo' } |
                Sort-Object Length -Descending |
                Select-Object -First 1
            )

            # A logo-only export normally contains only the selected logo image.
            if ($logoCandidate.Count -eq 0 -and $imageFiles.Count -eq 1) {
                $logoCandidate = @($imageFiles[0])
            }

            if ($logoCandidate.Count -gt 0) {
                $ext = $logoCandidate[0].Extension.ToLowerInvariant()
                $logoName = "logo_" + $safeKey + $ext
                $logoPath = Join-Path $DesignMediaDir $logoName

                Copy-Item `
                    -Path $logoCandidate[0].FullName `
                    -Destination $logoPath `
                    -Force

                if ((Test-Path $logoPath) -and (Get-Item $logoPath).Length -gt 512) {
                    $result.LogoSrc = "media/" + $logoName
                }
            }
        }

        $diag = [PSCustomObject]@{
            RatingKey = $RatingKey
            MediaType = $MediaType
            CustomFieldsRequested = @($customFields)
            RtCritic = $result.RtCritic
            RtAudience = $result.RtAudience
            Imdb = $result.Imdb
            Provider = $result.Provider
            ProviderValue = $result.ProviderValue
            LogoExportLevel = $(if ($NeedLogo) { 9 } else { 0 })
            LogoFound = -not [string]::IsNullOrWhiteSpace($result.LogoSrc)
            JsonFiles = @($jsonFiles | ForEach-Object { $_.Name })
            DownloadFormat = $(if ($isZip) { "zip" } else { "json" })
            ExportedFiles = @($exportedFiles | ForEach-Object { $_.Name })
        }

        $diag | ConvertTo-Json -Depth 8 | Set-Content -Path $diagPath -Encoding UTF8
        $result.DiagnosticFile = "media/" + $diagPath.Split([IO.Path]::DirectorySeparatorChar)[-1]

        Write-Log ("Design rich export result: RT critic={0}, audience={1}, IMDb={2}, selected={3}, logo={4}" -f `
            $(if ($result.RtCritic) { $result.RtCritic + "%" } else { "n/a" }),
            $(if ($result.RtAudience) { $result.RtAudience } else { "n/a" }),
            $(if ($result.Imdb) { $result.Imdb } else { "n/a" }),
            $(if ($result.Provider) { $result.Provider + " " + $result.ProviderValue } else { "n/a" }),
            $(if ($result.LogoSrc) { "yes" } else { "no" })
        )
    }
    catch {
        Write-Log "Design rich export failed for rating key ${RatingKey}: $($_.Exception.Message)" "WARN"
    }
    finally {
        Remove-Item $downloadPath -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue

        if ($exportId -gt 0) {
            try {
                Invoke-TautulliApi -Command "delete_export" -Parameters @{
                    export_id = $exportId
                } | Out-Null
            }
            catch { }
        }
    }

    $script:DesignRichExportCache[$cacheKey] = $result
    return $result
}

function Convert-DesignRatingPercent {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return "" }

    [double]$n = 0
    $ok = [double]::TryParse(
        [string]$Value,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$n
    )
    if (-not $ok) { return "" }

    if ($n -le 10) { $n = $n * 10 }
    return [string][Math]::Round($n)
}

function ConvertTo-DesignGenreList {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return @() }

    $source = @()
    if ($Value -is [string]) {
        $rawText = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($rawText)) { return @() }

        if ($rawText -match '[,|]') {
            $source = @($rawText -split '\s*[,|]\s*')
        }
        else {
            $source = @($rawText)
        }
    }
    elseif ($Value -is [System.Collections.IEnumerable]) {
        $source = @($Value)
    }
    else {
        $source = @($Value)
    }

    $result = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    foreach ($entry in $source) {
        if ($null -eq $entry) { continue }

        $text = ""
        if ($entry -is [string]) {
            $text = ([string]$entry).Trim()
        }
        else {
            foreach ($propertyName in @("tag", "name", "title")) {
                if ($null -ne $entry.PSObject.Properties[$propertyName]) {
                    $candidate = ([string]$entry.$propertyName).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                        $text = $candidate
                        break
                    }
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $key = $text.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }

        $seen[$key] = $true
        $result.Add($text)
    }

    return $result.ToArray()
}

function Get-DesignGenreLine {
    param([object]$Item)

    if ($null -eq $Item) { return "" }

    $rawGenres = @()
    if ($null -ne $Item.PSObject.Properties["DesignGenres"]) {
        $rawGenres = @($Item.DesignGenres)
    }

    $genres = @(ConvertTo-DesignGenreList -Value $rawGenres)
    if ($genres.Count -eq 0) { return "" }

    if ($genres.Count -eq 1) {
        return [string]$genres[0]
    }

    if ($genres.Count -eq 2) {
        return ([string]$genres[0]) + ", " + ([string]$genres[1])
    }

    return ([string]$genres[0]) + ", " + ([string]$genres[1]) + ", and more"
}

function Add-DesignRatingMetadata {
    param([object]$ReleaseData)

    $all = @()
    $all += @($ReleaseData.Movies)
    $all += @($ReleaseData.TV)

    foreach ($item in $all) {
        $critic = Get-OptionalStringProperty -InputObject $item -Name "DesignRtCritic"
        $audience = Get-OptionalStringProperty -InputObject $item -Name "DesignRtAudience"
        $imdb = Get-OptionalStringProperty -InputObject $item -Name "DesignImdbRating"
        $provider = Get-OptionalStringProperty -InputObject $item -Name "DesignRatingProvider"
        $providerValue = Get-OptionalStringProperty -InputObject $item -Name "DesignRatingValue"
        $criticImage = Get-OptionalStringProperty -InputObject $item -Name "DesignRtCriticImage"
        $audienceImageState = Get-OptionalStringProperty -InputObject $item -Name "DesignRtAudienceImage"
        $genres = @()
        $watchSlug = ""
        $liveMetadataAvailable = $false
        $ratingKey = [string]$item.RatingKey
        $mediaType = if ([string]$item.Type -eq "show") { "show" } else { "movie" }

        # Preserve rich fields already returned by get_recently_added or
        # get_history. A later metadata lookup may improve them, but a sparse
        # lookup must never erase usable source-row content.
        if ($null -ne $item.PSObject.Properties["DesignGenres"]) {
            $genres = @(ConvertTo-DesignGenreList -Value $item.DesignGenres)
        }
        elseif ($null -ne $item.PSObject.Properties["Genres"]) {
            $genres = @(ConvertTo-DesignGenreList -Value $item.Genres)
        }
        $sourceRatingImage = Get-OptionalStringProperty -InputObject $item -Name "RatingImage"
        $sourceRatingValue = Get-OptionalStringProperty -InputObject $item -Name "Rating"
        $sourceAudienceImage = Get-OptionalStringProperty -InputObject $item -Name "AudienceRatingImage"
        $sourceAudienceValue = Get-OptionalStringProperty -InputObject $item -Name "AudienceRating"
        $sourceSelectedRating = Get-DesignProviderRating -RatingImage $sourceRatingImage -RatingValue $sourceRatingValue -AudienceImage $sourceAudienceImage -AudienceValue $sourceAudienceValue
        if (-not [string]::IsNullOrWhiteSpace($sourceSelectedRating.Provider)) {
            $provider = $sourceSelectedRating.Provider
            $providerValue = $sourceSelectedRating.Value
        }
        if ($sourceRatingImage -like 'rottentomatoes://image.rating.*') {
            $sourceCritic = Convert-DesignRatingPercent $sourceRatingValue
            if (-not [string]::IsNullOrWhiteSpace($sourceCritic)) {
                $critic = $sourceCritic
                $criticImage = $sourceRatingImage
            }
        }
        if ($sourceAudienceImage -like 'rottentomatoes://image.rating.*') {
            $sourceAudience = Convert-DesignRatingPercent $sourceAudienceValue
            if (-not [string]::IsNullOrWhiteSpace($sourceAudience)) {
                $audience = $sourceAudience
                $audienceImageState = $sourceAudienceImage
            }
        }
        if ($mediaType -eq "show" -and
            $sourceRatingImage -like 'imdb://image.rating*' -and
            $sourceSelectedRating.Provider -eq "IMDb" -and
            -not [string]::IsNullOrWhiteSpace([string]$sourceSelectedRating.Value)) {
            $imdb = $sourceSelectedRating.Value
        }

        # Primary source for the newsletter: Tautulli exposes Plex's selected,
        # provider-labelled rating fields. Keep the dedicated RT/IMDb display
        # paths, then retain another recognized provider as a text badge.
        try {
            $meta = Invoke-TautulliApi -Command "get_metadata" -Parameters @{
                rating_key = $ratingKey
            }
            $metadataIdentity = Get-OptionalStringProperty -InputObject $meta -Name "rating_key"
            $metadataTitle = Get-OptionalStringProperty -InputObject $meta -Name "title"
            $liveMetadataAvailable = (
                $null -ne $meta -and
                -not [string]::IsNullOrWhiteSpace($metadataIdentity) -and
                -not [string]::IsNullOrWhiteSpace($metadataTitle)
            )

            $ratingImage = Get-OptionalStringProperty -InputObject $meta -Name "rating_image"
            $audienceImage = Get-OptionalStringProperty -InputObject $meta -Name "audience_rating_image"
            $ratingValue = Get-OptionalStringProperty -InputObject $meta -Name "rating"
            $audienceRatingValue = Get-OptionalStringProperty -InputObject $meta -Name "audience_rating"
            $selectedRating = Get-DesignProviderRating `
                -RatingImage $ratingImage `
                -RatingValue $ratingValue `
                -AudienceImage $audienceImage `
                -AudienceValue $audienceRatingValue
            if (-not [string]::IsNullOrWhiteSpace($selectedRating.Provider)) {
                $provider = $selectedRating.Provider
                $providerValue = $selectedRating.Value
            }

            if ([string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $item -Name "Summary"))) {
                $summary = Get-OptionalStringProperty -InputObject $meta -Name "summary"
                if (-not [string]::IsNullOrWhiteSpace($summary)) {
                    $item | Add-Member -NotePropertyName "Summary" -NotePropertyValue $summary -Force
                }
            }
            if ([string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $item -Name "Year"))) {
                $year = Get-OptionalStringProperty -InputObject $meta -Name "year"
                if (-not [string]::IsNullOrWhiteSpace($year)) {
                    $item | Add-Member -NotePropertyName "Year" -NotePropertyValue $year -Force
                }
            }

            if ($null -ne $meta.PSObject.Properties["genres"]) {
                $metadataGenres = @(ConvertTo-DesignGenreList -Value $meta.genres)
                if ($metadataGenres.Count -gt 0) { $genres = $metadataGenres }
            }
            elseif ($null -ne $meta.PSObject.Properties["genre"]) {
                $metadataGenres = @(ConvertTo-DesignGenreList -Value $meta.genre)
                if ($metadataGenres.Count -gt 0) { $genres = $metadataGenres }
            }

            if ($ratingImage -like 'rottentomatoes://image.rating.*') {
                $metadataCritic = Convert-DesignRatingPercent $ratingValue
                if (-not [string]::IsNullOrWhiteSpace($metadataCritic)) {
                    $critic = $metadataCritic
                    $criticImage = $ratingImage
                }
            }
            if ($audienceImage -like 'rottentomatoes://image.rating.*') {
                $metadataAudience = Convert-DesignRatingPercent $audienceRatingValue
                if (-not [string]::IsNullOrWhiteSpace($metadataAudience)) {
                    $audience = $metadataAudience
                    $audienceImageState = $audienceImage
                }
            }
            if ($mediaType -eq "show" -and
                $ratingImage -like 'imdb://image.rating*' -and
                $selectedRating.Provider -eq "IMDb" -and
                -not [string]::IsNullOrWhiteSpace([string]$selectedRating.Value)) {
                $imdb = $selectedRating.Value
            }
        }
        catch {
            Write-Log "TautWeekly for Plex Tautulli rating/metadata lookup failed for $($item.Title): $($_.Exception.Message)" "WARN"
        }

        # Optional secondary source: Plex's full Rating[] if direct access
        # happens to be available on this install.
        $needsDirectRatings = if ($mediaType -eq "movie") {
            [string]::IsNullOrWhiteSpace($critic) -or [string]::IsNullOrWhiteSpace($audience)
        }
        else {
            [string]::IsNullOrWhiteSpace($imdb)
        }
        if ($needsDirectRatings) {
            try {
                $plexMeta = Get-DesignPlexMetadata -RatingKey $ratingKey

                if ($null -ne $plexMeta -and
                    $genres.Count -eq 0 -and
                    $null -ne $plexMeta.PSObject.Properties["Genre"]) {
                    $genres = @(ConvertTo-DesignGenreList -Value $plexMeta.Genre)
                }

                if ($null -ne $plexMeta -and
                    $null -ne $plexMeta.PSObject.Properties["Rating"]) {

                    foreach ($ratingEntry in @($plexMeta.Rating)) {
                        $image = ""
                        $type = ""
                        $value = $null

                        if ($null -ne $ratingEntry.PSObject.Properties["image"]) {
                            $image = [string]$ratingEntry.image
                        }
                        if ($null -ne $ratingEntry.PSObject.Properties["type"]) {
                            $type = [string]$ratingEntry.type
                        }
                        if ($null -ne $ratingEntry.PSObject.Properties["value"]) {
                            $value = $ratingEntry.value
                        }

                        $entrySelectedRating = Get-DesignProviderRating -RatingImage $image -RatingValue $value
                        if ($mediaType -eq "show" -and
                            [string]::IsNullOrWhiteSpace($imdb) -and
                            $image -like "imdb://image.rating*" -and
                            $entrySelectedRating.Provider -eq "IMDb") {
                            $imdb = $entrySelectedRating.Value
                        }

                        if ([string]::IsNullOrWhiteSpace($provider) -and
                            -not [string]::IsNullOrWhiteSpace([string]$entrySelectedRating.Provider)) {
                            $provider = $entrySelectedRating.Provider
                            $providerValue = $entrySelectedRating.Value
                        }

                        if ([string]::IsNullOrWhiteSpace($critic) -and
                            $image -like "rottentomatoes://image.rating.*" -and
                            $type -eq "critic") {
                            $entryCritic = Convert-DesignRatingPercent $value
                            if (-not [string]::IsNullOrWhiteSpace($entryCritic)) {
                                $critic = $entryCritic
                                $criticImage = $image
                            }
                        }

                        if ([string]::IsNullOrWhiteSpace($audience) -and
                            $image -like "rottentomatoes://image.rating.*" -and
                            $type -eq "audience") {
                            $entryAudience = Convert-DesignRatingPercent $value
                            if (-not [string]::IsNullOrWhiteSpace($entryAudience)) {
                                $audience = $entryAudience
                                $audienceImageState = $image
                            }
                        }
                    }
                }
            }
            catch {
                Write-Log "TautWeekly for Plex optional direct Plex rating lookup failed for $($item.Title): $($_.Exception.Message)" "WARN"
            }
        }

        # A deleted library item can no longer be expanded by the local PMS,
        # but Tautulli history retains its Plex metadata GUID and limited match
        # context. Plex requires that context for its provider POST contract;
        # accept the result only when it agrees with that retained context.
        $metadataGuid = Get-OptionalStringProperty -InputObject $item -Name "MetadataGuid"
        $matchTitle = Get-OptionalStringProperty -InputObject $item -Name "Title"
        $matchYear = Get-OptionalStringProperty -InputObject $item -Name "Year"
        $matchParentIndex = Safe-Int (Get-OptionalStringProperty -InputObject $item -Name "MetadataParentIndex")
        $matchIndex = Safe-Int (Get-OptionalStringProperty -InputObject $item -Name "MetadataIndex")
        $cachedEntry = Get-TautWeeklyDeletedItemCacheEntry `
            -MediaType $mediaType `
            -MetadataGuid $metadataGuid `
            -LogHit
        if ($null -ne $cachedEntry) {
            if ([string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $item -Name "Summary"))) {
                $cachedSummary = Get-OptionalStringProperty -InputObject $cachedEntry -Name "Summary"
                if (-not [string]::IsNullOrWhiteSpace($cachedSummary)) {
                    $item | Add-Member -NotePropertyName "Summary" -NotePropertyValue $cachedSummary -Force
                }
            }
            if ([string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $item -Name "Year"))) {
                $cachedYear = Get-OptionalStringProperty -InputObject $cachedEntry -Name "Year"
                if (-not [string]::IsNullOrWhiteSpace($cachedYear)) {
                    $item | Add-Member -NotePropertyName "Year" -NotePropertyValue $cachedYear -Force
                }
            }
            if ($genres.Count -eq 0 -and $null -ne $cachedEntry.PSObject.Properties["Genres"]) {
                $genres = @(ConvertTo-DesignGenreList -Value $cachedEntry.Genres)
            }
            if ($null -ne $cachedEntry.PSObject.Properties["Ratings"]) {
                $cachedCritic = Get-OptionalStringProperty $cachedEntry.Ratings "RtCritic"
                $cachedCriticImage = Get-OptionalStringProperty $cachedEntry.Ratings "RtCriticImage"
                $criticPairAvailable = (
                    -not [string]::IsNullOrWhiteSpace($critic) -and
                    -not [string]::IsNullOrWhiteSpace($criticImage)
                )
                if (-not $criticPairAvailable -and
                    -not [string]::IsNullOrWhiteSpace($cachedCritic) -and
                    -not [string]::IsNullOrWhiteSpace($cachedCriticImage)) {
                    $critic = $cachedCritic
                    $criticImage = $cachedCriticImage
                }
                $cachedAudience = Get-OptionalStringProperty $cachedEntry.Ratings "RtAudience"
                $cachedAudienceImage = Get-OptionalStringProperty $cachedEntry.Ratings "RtAudienceImage"
                $audiencePairAvailable = (
                    -not [string]::IsNullOrWhiteSpace($audience) -and
                    -not [string]::IsNullOrWhiteSpace($audienceImageState)
                )
                if (-not $audiencePairAvailable -and
                    -not [string]::IsNullOrWhiteSpace($cachedAudience) -and
                    -not [string]::IsNullOrWhiteSpace($cachedAudienceImage)) {
                    $audience = $cachedAudience
                    $audienceImageState = $cachedAudienceImage
                }
                $cachedImdb = Get-OptionalStringProperty $cachedEntry.Ratings "Imdb"
                if ([string]::IsNullOrWhiteSpace($imdb) -and -not [string]::IsNullOrWhiteSpace($cachedImdb)) { $imdb = $cachedImdb }
                $cachedProvider = Get-OptionalStringProperty $cachedEntry.Ratings "Provider"
                $cachedProviderValue = Get-OptionalStringProperty $cachedEntry.Ratings "ProviderValue"
                if (([string]::IsNullOrWhiteSpace($provider) -or [string]::IsNullOrWhiteSpace($providerValue)) -and
                    -not [string]::IsNullOrWhiteSpace($cachedProvider) -and
                    -not [string]::IsNullOrWhiteSpace($cachedProviderValue)) {
                    $provider = $cachedProvider
                    $providerValue = $cachedProviderValue
                }
            }
        }
        $needsHostedRating = if ($mediaType -eq "movie") {
            [string]::IsNullOrWhiteSpace($critic) -or [string]::IsNullOrWhiteSpace($audience)
        }
        else {
            [string]::IsNullOrWhiteSpace($imdb)
        }
        $needsHostedMetadata = (
            -not [string]::IsNullOrWhiteSpace($metadataGuid) -and
            ($genres.Count -eq 0 -or
             $needsHostedRating -or
             [string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $item -Name "Summary")) -or
             [string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $item -Name "Year")))
        )

        if ($needsHostedMetadata) {
            try {
                $hostedMeta = Get-PlexHostedMetadata `
                    -MetadataGuid $metadataGuid `
                    -MediaType $mediaType `
                    -MatchTitle $matchTitle `
                    -MatchYear $matchYear `
                    -ParentIndex $matchParentIndex `
                    -Index $matchIndex
                if ($null -ne $hostedMeta) {
                    $watchSlug = Get-OptionalStringProperty -InputObject $hostedMeta -Name "slug"
                    if ($genres.Count -eq 0) {
                        if ($null -ne $hostedMeta.PSObject.Properties["Genre"]) {
                            $genres = @(ConvertTo-DesignGenreList -Value $hostedMeta.Genre)
                        }
                        elseif ($null -ne $hostedMeta.PSObject.Properties["genres"]) {
                            $genres = @(ConvertTo-DesignGenreList -Value $hostedMeta.genres)
                        }
                    }

                    if ([string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $item -Name "Summary"))) {
                        $summary = Get-OptionalStringProperty -InputObject $hostedMeta -Name "summary"
                        if (-not [string]::IsNullOrWhiteSpace($summary)) {
                            $item | Add-Member -NotePropertyName "Summary" -NotePropertyValue $summary -Force
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $item -Name "Year"))) {
                        $year = Get-OptionalStringProperty -InputObject $hostedMeta -Name "year"
                        if (-not [string]::IsNullOrWhiteSpace($year)) {
                            $item | Add-Member -NotePropertyName "Year" -NotePropertyValue $year -Force
                        }
                    }

                    $hostedRatingImage = Get-OptionalStringProperty -InputObject $hostedMeta -Name "ratingImage"
                    if ([string]::IsNullOrWhiteSpace($hostedRatingImage)) {
                        $hostedRatingImage = Get-OptionalStringProperty -InputObject $hostedMeta -Name "rating_image"
                    }
                    $hostedAudienceImage = Get-OptionalStringProperty -InputObject $hostedMeta -Name "audienceRatingImage"
                    if ([string]::IsNullOrWhiteSpace($hostedAudienceImage)) {
                        $hostedAudienceImage = Get-OptionalStringProperty -InputObject $hostedMeta -Name "audience_rating_image"
                    }
                    $hostedRating = Get-OptionalStringProperty -InputObject $hostedMeta -Name "rating"
                    $hostedAudience = Get-OptionalStringProperty -InputObject $hostedMeta -Name "audienceRating"
                    if ([string]::IsNullOrWhiteSpace($hostedAudience)) {
                        $hostedAudience = Get-OptionalStringProperty -InputObject $hostedMeta -Name "audience_rating"
                    }

                    $hostedSelectedRating = Get-DesignProviderRating `
                        -RatingImage $hostedRatingImage `
                        -RatingValue $hostedRating `
                        -AudienceImage $hostedAudienceImage `
                        -AudienceValue $hostedAudience
                    if ([string]::IsNullOrWhiteSpace($critic) -and
                        $hostedRatingImage -like 'rottentomatoes://image.rating.*') {
                        $hostedCritic = Convert-DesignRatingPercent $hostedRating
                        if (-not [string]::IsNullOrWhiteSpace($hostedCritic)) {
                            $critic = $hostedCritic
                            $criticImage = $hostedRatingImage
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($audience) -and
                        $hostedAudienceImage -like 'rottentomatoes://image.rating.*') {
                        $hostedAudienceValue = Convert-DesignRatingPercent $hostedAudience
                        if (-not [string]::IsNullOrWhiteSpace($hostedAudienceValue)) {
                            $audience = $hostedAudienceValue
                            $audienceImageState = $hostedAudienceImage
                        }
                    }
                    if ($mediaType -eq "show" -and
                        [string]::IsNullOrWhiteSpace($imdb) -and
                        $hostedRatingImage -like 'imdb://image.rating*' -and
                        $hostedSelectedRating.Provider -eq "IMDb") {
                        $imdb = $hostedSelectedRating.Value
                    }
                    if ([string]::IsNullOrWhiteSpace($provider) -and
                        -not [string]::IsNullOrWhiteSpace([string]$hostedSelectedRating.Provider)) {
                        $provider = $hostedSelectedRating.Provider
                        $providerValue = $hostedSelectedRating.Value
                    }

                    if ($null -ne $hostedMeta.PSObject.Properties["Rating"]) {
                        foreach ($ratingEntry in @($hostedMeta.Rating)) {
                            $image = Get-OptionalStringProperty -InputObject $ratingEntry -Name "image"
                            $type = Get-OptionalStringProperty -InputObject $ratingEntry -Name "type"
                            $value = Get-OptionalStringProperty -InputObject $ratingEntry -Name "value"

                            $hostedEntryRating = Get-DesignProviderRating -RatingImage $image -RatingValue $value
                            if ($mediaType -eq "show" -and
                                [string]::IsNullOrWhiteSpace($imdb) -and
                                $image -like 'imdb://image.rating*' -and
                                $hostedEntryRating.Provider -eq "IMDb") {
                                $imdb = $hostedEntryRating.Value
                            }
                            if ([string]::IsNullOrWhiteSpace($provider) -and
                                -not [string]::IsNullOrWhiteSpace([string]$hostedEntryRating.Provider)) {
                                $provider = $hostedEntryRating.Provider
                                $providerValue = $hostedEntryRating.Value
                            }
                            if ([string]::IsNullOrWhiteSpace($critic) -and
                                $image -like 'rottentomatoes://image.rating.*' -and
                                $type -eq "critic") {
                                $hostedEntryCritic = Convert-DesignRatingPercent $value
                                if (-not [string]::IsNullOrWhiteSpace($hostedEntryCritic)) {
                                    $critic = $hostedEntryCritic
                                    $criticImage = $image
                                }
                            }
                            if ([string]::IsNullOrWhiteSpace($audience) -and
                                $image -like 'rottentomatoes://image.rating.*' -and
                                $type -eq "audience") {
                                $hostedEntryAudience = Convert-DesignRatingPercent $value
                                if (-not [string]::IsNullOrWhiteSpace($hostedEntryAudience)) {
                                    $audience = $hostedEntryAudience
                                    $audienceImageState = $image
                                }
                            }
                        }
                    }
                }
            }
            catch {
                Write-Log "Plex hosted enrichment failed for deleted $mediaType history metadata: $($_.Exception.Message)" "WARN"
            }
        }

        # Plex's exact-GUID metadata response can retain artwork and genres but
        # omit provider ratings. Its public watch page exposes semantic,
        # provider-labelled scores for the exact slug. Request only that slug,
        # without a Plex token or title search, and fail closed when a provider
        # does not publish the expected movie RT or TV IMDb value.
        $needsWatchRating = if ($mediaType -eq "movie") {
            [string]::IsNullOrWhiteSpace($critic) -or [string]::IsNullOrWhiteSpace($audience)
        }
        else {
            [string]::IsNullOrWhiteSpace($imdb)
        }
        if ($needsWatchRating -and -not [string]::IsNullOrWhiteSpace($watchSlug)) {
            $watchRatings = Get-PlexWatchRatings -Slug $watchSlug -MediaType $mediaType
            if ($mediaType -eq "movie") {
                if ([string]::IsNullOrWhiteSpace($critic)) {
                    $critic = Get-OptionalStringProperty -InputObject $watchRatings -Name "RtCritic"
                }
                if ([string]::IsNullOrWhiteSpace($audience)) {
                    $audience = Get-OptionalStringProperty -InputObject $watchRatings -Name "RtAudience"
                }
            }
            else {
                if ([string]::IsNullOrWhiteSpace($imdb)) {
                    $imdb = Get-OptionalStringProperty -InputObject $watchRatings -Name "Imdb"
                }
                if ([string]::IsNullOrWhiteSpace($critic)) {
                    $critic = Get-OptionalStringProperty -InputObject $watchRatings -Name "RtCritic"
                }
                if ([string]::IsNullOrWhiteSpace($audience)) {
                    $audience = Get-OptionalStringProperty -InputObject $watchRatings -Name "RtAudience"
                }
            }
        }

        # Last resort: Tautulli's provider-labelled item export can still reach
        # Plex through Tautulli when this runtime cannot connect directly.
        $needsRichExport = if ([string]$item.Type -eq "movie") {
            ([string]::IsNullOrWhiteSpace($critic) -or
                [string]::IsNullOrWhiteSpace($audience))
        }
        else {
            [string]::IsNullOrWhiteSpace($imdb)
        }
        if ($needsRichExport) {

            $rich = Get-DesignRichExport `
                -RatingKey $ratingKey `
                -MediaType $mediaType `
                -NeedLogo:$false

            if ([string]$item.Type -eq "movie") {
                if ([string]::IsNullOrWhiteSpace($critic)) {
                    $critic = [string]$rich.RtCritic
                }
                if ([string]::IsNullOrWhiteSpace($audience)) {
                    $audience = [string]$rich.RtAudience
                }
            }
            else {
                if ([string]::IsNullOrWhiteSpace($imdb)) {
                    $imdb = [string]$rich.Imdb
                }
                if ([string]::IsNullOrWhiteSpace($critic)) {
                    $critic = [string]$rich.RtCritic
                }
                if ([string]::IsNullOrWhiteSpace($audience)) {
                    $audience = [string]$rich.RtAudience
                }
            }
            if ([string]::IsNullOrWhiteSpace($provider)) {
                $provider = [string]$rich.Provider
                $providerValue = [string]$rich.ProviderValue
            }
        }

        if ([string]::IsNullOrWhiteSpace($imdb) -and $provider -eq "IMDb") {
            $imdb = $providerValue
        }

        if ($mediaType -eq "show") {
            Write-Log ("Design ratings: {0} -> IMDb {1}, RT critic {2}, audience {3}, selected {4}" -f `
                $item.Title,
                $(if ($imdb) { $imdb } else { "n/a" }),
                $(if ($critic) { $critic + "%" } else { "n/a" }),
                $(if ($audience) { $audience + "%" } else { "n/a" }),
                $(if ($provider) { $provider + " " + $providerValue } else { "n/a" })
            )
        }
        else {
            Write-Log ("Design ratings: {0} -> RT critic {1}, audience {2}, selected {3}" -f `
                $item.Title,
                $(if ($critic) { $critic + "%" } else { "n/a" }),
                $(if ($audience) { $audience } else { "n/a" }),
                $(if ($provider) { $provider + " " + $providerValue } else { "n/a" })
            )
        }

        $item | Add-Member -NotePropertyName "DesignRtCritic" -NotePropertyValue $critic -Force
        $item | Add-Member -NotePropertyName "DesignRtAudience" -NotePropertyValue $audience -Force
        $item | Add-Member -NotePropertyName "DesignImdbRating" -NotePropertyValue $imdb -Force
        $item | Add-Member -NotePropertyName "DesignRatingProvider" -NotePropertyValue $provider -Force
        $item | Add-Member -NotePropertyName "DesignRatingValue" -NotePropertyValue $providerValue -Force
        $item | Add-Member -NotePropertyName "DesignRtCriticImage" -NotePropertyValue $criticImage -Force
        $item | Add-Member -NotePropertyName "DesignRtAudienceImage" -NotePropertyValue $audienceImageState -Force
        $item | Add-Member -NotePropertyName "DesignGenres" -NotePropertyValue @($genres) -Force
        $item | Add-Member -NotePropertyName "CacheCaptureEligible" -NotePropertyValue $liveMetadataAvailable -Force
    }
}

function Get-DesignRtIconUrl {
    param(
        [string]$ImageState,
        [ValidateSet("critic","audience")]
        [string]$Kind,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode = "Preview"
    )

    $state = ([string]$ImageState).Trim().ToLowerInvariant()
    $token = ""

    if ($state -match '\.([a-z]+)$') {
        $token = [string]$Matches[1]
    }

    $assetName = ""
    $cid = ""

    if ($Kind -eq "critic") {
        if ($token -eq "rotten") {
            $assetName = "rt_rotten.png"
            $cid = "rt_rotten"
        }
        else {
            $assetName = "rt_ripe.png"
            $cid = "rt_ripe"
        }
    }
    else {
        if ($token -eq "spilled") {
            $assetName = "rt_spilled.png"
            $cid = "rt_spilled"
        }
        else {
            $assetName = "rt_upright.png"
            $cid = "rt_upright"
        }
    }

    if ($ImageMode -eq "Email") {
        return "cid:" + $cid
    }

    return "assets/" + $assetName
}

function Get-DesignProviderRatingHtml {
    param(
        [string]$Provider,
        [string]$Value,
        [int]$MarginLeft = 0
    )

    if ($Provider -notin @("IMDb", "TMDB", "TVDB") -or
        $Value -notmatch '^(?:10(?:\.0+)?|[0-9](?:\.[0-9]+)?)$') {
        return ""
    }

    $margin = if ($MarginLeft -gt 0) { "margin-left:${MarginLeft}px;" } else { "" }
    return '<span style="display:inline-block;' + $margin + 'white-space:nowrap;">' +
        '<span style="display:inline-block;padding:1px 4px;border:1px solid #a87500;border-radius:3px;margin-right:4px;font-size:9px;line-height:1.1;font-weight:800;letter-spacing:.2px;vertical-align:1px;">' +
        (HtmlEncode $Provider) +
        '</span>' +
        (HtmlEncode $Value) +
        '</span>'
}

function Get-DesignRatingLine {
    param(
        [object]$Item,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode = "Preview"
    )

    $pieces = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace([string]$Item.Year)) {
        $pieces.Add(
            '<span class="design-rating-year">' +
            (HtmlEncode ([string]$Item.Year)) +
            '</span>'
        )
    }

    $critic = ""
    $audience = ""
    $criticImage = ""
    $audienceImage = ""

    if ($null -ne $Item.PSObject.Properties["DesignRtCritic"]) {
        $critic = [string]$Item.DesignRtCritic
    }
    if ($null -ne $Item.PSObject.Properties["DesignRtAudience"]) {
        $audience = [string]$Item.DesignRtAudience
    }
    if ($null -ne $Item.PSObject.Properties["DesignRtCriticImage"]) {
        $criticImage = [string]$Item.DesignRtCriticImage
    }
    if ($null -ne $Item.PSObject.Properties["DesignRtAudienceImage"]) {
        $audienceImage = [string]$Item.DesignRtAudienceImage
    }

    # Only if the original provider-state identifier is unavailable, infer the
    # visual state from RT's 60% cutoff. Tautulli state always wins when present.
    if (-not [string]::IsNullOrWhiteSpace($critic)) {
        if ([string]::IsNullOrWhiteSpace($criticImage)) {
            $criticImage = if ((Safe-Int $critic) -ge 60) {
                "rottentomatoes://image.rating.ripe"
            } else {
                "rottentomatoes://image.rating.rotten"
            }
        }

        $criticIcon = Get-DesignRtIconUrl -ImageState $criticImage -Kind "critic" -ImageMode $ImageMode
        $pieces.Add(
            '<span class="design-rating-item">' +
            '<img src="' + (HtmlEncode $criticIcon) + '" alt="Rotten Tomatoes critic" ' +
            'width="18" height="18" style="display:inline-block;width:18px;height:18px;object-fit:contain;border:0;vertical-align:-4px;margin-right:4px;">' +
            (HtmlEncode ($critic + "%")) +
            '</span>'
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($audience)) {
        if ([string]::IsNullOrWhiteSpace($audienceImage)) {
            $audienceImage = if ((Safe-Int $audience) -ge 60) {
                "rottentomatoes://image.rating.upright"
            } else {
                "rottentomatoes://image.rating.spilled"
            }
        }

        $audienceIcon = Get-DesignRtIconUrl -ImageState $audienceImage -Kind "audience" -ImageMode $ImageMode
        $pieces.Add(
            '<span class="design-rating-item">' +
            '<img src="' + (HtmlEncode $audienceIcon) + '" alt="Rotten Tomatoes audience" ' +
            'width="18" height="18" style="display:inline-block;width:18px;height:18px;object-fit:contain;border:0;vertical-align:-4px;margin-right:4px;">' +
            (HtmlEncode ($audience + "%")) +
            '</span>'
        )
    }

    # Movies show RT whenever either RT score exists. A provider-labelled IMDb
    # value is retained only as the final fallback when RT is wholly absent.
    # Shows keep their dedicated IMDb treatment; generic provider scores are
    # never substituted for either media-specific presentation.
    $hasRt = (
        -not [string]::IsNullOrWhiteSpace($critic) -or
        -not [string]::IsNullOrWhiteSpace($audience)
    )
    $imdb = Get-OptionalStringProperty -InputObject $Item -Name "DesignImdbRating"
    if (([string]$Item.Type -eq "show" -or -not $hasRt) -and
        -not [string]::IsNullOrWhiteSpace($imdb)) {
        $imdbIcon = if ($ImageMode -eq "Email") { "cid:icon_imdb" } else { "../assets/imdb.png" }
        $pieces.Add(
            '<span class="design-rating-item">' +
            '<img src="' + (HtmlEncode $imdbIcon) + '" alt="IMDb" ' +
            'width="28" height="14" style="display:inline-block;width:28px;height:14px;object-fit:contain;border:0;vertical-align:-3px;margin-right:5px;">' +
            (HtmlEncode $imdb) +
            '</span>'
        )
    }

    return ($pieces -join '<span style="display:inline-block;width:7px;"></span>')
}


function Get-DesignPmsImage {
    param(
        [string]$ImagePath,
        [string]$RatingKey,
        [string]$OutputName,
        [string]$Fallback = "art",
        [int]$Width = 1200,
        [int]$Height = 450,
        [string]$Format = "jpg"
    )

    $local = Join-Path $DesignMediaDir $OutputName
    try {
        $params = @{
            width      = $Width
            height     = $Height
            img_format = $Format
            fallback   = $Fallback
            refresh    = "false"
        }
        if (-not [string]::IsNullOrWhiteSpace($ImagePath)) {
            $params.img = $ImagePath
        }
        elseif (-not [string]::IsNullOrWhiteSpace($RatingKey)) {
            $params.rating_key = $RatingKey
        }
        else {
            return ""
        }

        $uri = Build-TautulliUri -Command "pms_image_proxy" -Parameters $params
        Invoke-WebRequest -Uri $uri -OutFile $local -TimeoutSec 60 | Out-Null
        if ((Test-Path $local) -and (Get-Item $local).Length -gt 512) {
            return "media/" + $OutputName
        }
    }
    catch {
        Write-Log "Design image fetch failed ($OutputName): $($_.Exception.Message)" "WARN"
    }

    Remove-Item $local -Force -ErrorAction SilentlyContinue
    return ""
}

function Get-DesignLogoFromExporter {
    param([string]$RatingKey)

    if ([string]::IsNullOrWhiteSpace($RatingKey)) { return "" }

    $safeKey = Get-SafeFilePart $RatingKey
    $logoName = "logo_${safeKey}.png"
    $logoPath = Join-Path $DesignMediaDir $logoName
    if ((Test-Path $logoPath) -and (Get-Item $logoPath).Length -gt 512) {
        return "media/" + $logoName
    }

    $exportId = 0
    $tmpRoot = Join-Path $DesignMediaDir ("export_" + $safeKey)
    $downloadPath = Join-Path $DesignMediaDir ("export_" + $safeKey + ".zip")

    try {
        Write-Log "TautWeekly for Plex: requesting Plex logo export for rating key $RatingKey..."
        $request = Invoke-TautulliApi -Command "export_metadata" -Parameters @{
            rating_key       = $RatingKey
            file_format      = "json"
            metadata_level   = 1
            media_info_level = 0
            thumb_level      = 0
            art_level        = 0
            logo_level       = 9
            squareArt_level  = 0
            theme_level      = 0
            individual_files = "false"
        }

        $exportId = Safe-Int $request.export_id
        if ($exportId -le 0) {
            Write-Log "TautWeekly for Plex: Tautulli did not return an export id for the logo." "WARN"
            return ""
        }

        $complete = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 750
            $table = Invoke-TautulliApi -Command "get_exports_table" -Parameters @{
                rating_key = $RatingKey
                length     = 50
            }
            $row = @($table.data | Where-Object { (Safe-Int $_.export_id) -eq $exportId } | Select-Object -First 1)
            if ($row.Count -gt 0 -and (Safe-Int $row[0].complete) -eq 1) {
                $complete = $true
                break
            }
        }

        if (-not $complete) {
            Write-Log "TautWeekly for Plex: logo export did not finish in time; continuing without a logo." "WARN"
            return ""
        }

        $downloadUri = Build-TautulliUri -Command "download_export" -Parameters @{ export_id = $exportId }
        Invoke-WebRequest -Uri $downloadUri -OutFile $downloadPath -TimeoutSec 90 | Out-Null

        if (-not (Test-Path $downloadPath) -or (Get-Item $downloadPath).Length -lt 64) {
            return ""
        }

        $bytes = [IO.File]::ReadAllBytes($downloadPath)
        if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x50 -or $bytes[1] -ne 0x4B) {
            Write-Log "TautWeekly for Plex: logo export download was not a zip archive." "WARN"
            return ""
        }

        Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
        Expand-Archive -Path $downloadPath -DestinationPath $tmpRoot -Force

        $pngs = @(Get-ChildItem -Path $tmpRoot -Recurse -File -Filter "*.png" -ErrorAction SilentlyContinue)
        $candidate = @($pngs | Where-Object { $_.Name -match 'logo' } | Select-Object -First 1)
        if ($candidate.Count -eq 0) {
            $candidate = @($pngs | Select-Object -First 1)
        }

        if ($candidate.Count -gt 0) {
            Copy-Item -Path $candidate[0].FullName -Destination $logoPath -Force
            if ((Test-Path $logoPath) -and (Get-Item $logoPath).Length -gt 512) {
                Write-Log "TautWeekly for Plex: real Plex logo acquired."
                return "media/" + $logoName
            }
        }

        Write-Log "TautWeekly for Plex: no logo PNG was present in the Tautulli export." "WARN"
    }
    catch {
        Write-Log "TautWeekly for Plex logo export failed: $($_.Exception.Message)" "WARN"
    }
    finally {
        Remove-Item $downloadPath -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        if ($exportId -gt 0) {
            try {
                Invoke-TautulliApi -Command "delete_export" -Parameters @{ export_id = $exportId } | Out-Null
            }
            catch { }
        }
    }

    return ""
}

function Get-DesignHeroAssets {
    param([object]$HotRelease)

    $result = [PSCustomObject]@{
        BannerSrc    = ""
        ArtSrc       = ""
        LogoSrc      = ""
        SuppressLogoFallback = $false
        MetadataFile = ""
        DiagnosticFile = ""
    }

    if ($null -eq $HotRelease -or $null -eq $HotRelease.Item) { return $result }

    $ratingKey = [string]$HotRelease.Item.RatingKey
    if ([string]::IsNullOrWhiteSpace($ratingKey)) {
        $ratingKey = [string]$HotRelease.Item.PosterRatingKey
    }
    if ([string]::IsNullOrWhiteSpace($ratingKey)) { return $result }

    $tautMeta = $null

    try {
        $tautMeta = Invoke-TautulliApi -Command "get_metadata" -Parameters @{ rating_key = $ratingKey }
        $metaName = "metadata_" + (Get-SafeFilePart $ratingKey) + ".json"
        $metaPath = Join-Path $DesignMediaDir $metaName
        $tautMeta | ConvertTo-Json -Depth 15 | Set-Content -Path $metaPath -Encoding UTF8
        $result.MetadataFile = "media/" + $metaName

        $banner = [string]$tautMeta.banner
        $art = [string]$tautMeta.art

        if (-not [string]::IsNullOrWhiteSpace($banner)) {
            $result.BannerSrc = Get-DesignPmsImage `
                -ImagePath $banner `
                -RatingKey $ratingKey `
                -OutputName ("banner_" + (Get-SafeFilePart $ratingKey) + ".jpg") `
                -Fallback "art" `
                -Width 1200 `
                -Height 420 `
                -Format "jpg"
        }

        if (-not [string]::IsNullOrWhiteSpace($art)) {
            $result.ArtSrc = Get-DesignPmsImage `
                -ImagePath $art `
                -RatingKey $ratingKey `
                -OutputName ("art_" + (Get-SafeFilePart $ratingKey) + ".jpg") `
                -Fallback "art" `
                -Width 1200 `
                -Height 600 `
                -Format "jpg"
        }

        if ([string]::IsNullOrWhiteSpace($result.BannerSrc)) {
            $result.BannerSrc = $result.ArtSrc
        }
    }
    catch {
        Write-Log "TautWeekly for Plex metadata/art lookup failed: $($_.Exception.Message)" "WARN"
    }

    # Plex may select a clearLogo that works on its own artwork but becomes
    # unreadable on TautWeekly for Plex's #181818 hero card. Evaluate every available
    # clearLogo and choose the brightest/highest-contrast variant for email.
    try {
        $logoSelection = Get-DesignBestClearLogoAsset -RatingKey $ratingKey
        $result.LogoSrc = [string]$logoSelection.LogoSrc
        $result.SuppressLogoFallback = $false

        if (-not [string]::IsNullOrWhiteSpace($result.LogoSrc)) {
            Write-Log "TautWeekly for Plex: email-optimized clearLogo acquired from Plex /clearLogos."
        }
    }
    catch {
        Write-Log "TautWeekly for Plex email-aware /clearLogos lookup failed: $($_.Exception.Message)" "WARN"
    }

    # Secondary direct Plex metadata/image-array fallback.
    $plexMeta = $null
    $plexImages = @()

    try {
        $plexMeta = Get-DesignPlexMetadata -RatingKey $ratingKey
        $plexImages = @(Get-DesignPlexImages -RatingKey $ratingKey)

        Save-DesignPlexDiagnostic `
            -RatingKey $ratingKey `
            -Metadata $plexMeta `
            -Images $plexImages

        $result.DiagnosticFile = "media/plex_design_diagnostic_" +
            (Get-SafeFilePart $ratingKey) + ".json"

        if ([string]::IsNullOrWhiteSpace($result.LogoSrc) -and -not $result.SuppressLogoFallback) {
            $clearLogo = @(
                $plexImages |
                Where-Object {
                    $null -ne $_.PSObject.Properties["type"] -and
                    [string]$_.type -eq "clearLogo"
                } |
                Select-Object -First 1
            )

            if ($clearLogo.Count -gt 0 -and
                $null -ne $clearLogo[0].PSObject.Properties["url"]) {

                $logoUrl = [string]$clearLogo[0].url
                $logoName = "logo_" + (Get-SafeFilePart $ratingKey) + ".png"

                $result.LogoSrc = Get-DesignPlexAsset `
                    -Url $logoUrl `
                    -OutputName $logoName

                if (-not [string]::IsNullOrWhiteSpace($result.LogoSrc)) {
                    Write-Log "TautWeekly for Plex: clearLogo acquired from Plex Image[] metadata."
                }
            }
        }
    }
    catch {
        Write-Log "TautWeekly for Plex direct Plex logo lookup failed: $($_.Exception.Message)" "WARN"
    }

    # Primary fallback: let Tautulli export the selected logo using the
    # authenticated Plex connection it already owns.
    if ([string]::IsNullOrWhiteSpace($result.LogoSrc) -and -not $result.SuppressLogoFallback) {
        $mediaType = if ($null -ne $HotRelease.Item.PSObject.Properties["Type"]) {
            [string]$HotRelease.Item.Type
        } else {
            "movie"
        }

        $logoProbe = Get-DesignLogoExportSimple `
            -RatingKey $ratingKey `
            -MediaType $mediaType

        $result.LogoSrc = [string]$logoProbe.LogoSrc
        $result.DiagnosticFile = [string]$logoProbe.DiagnosticFile
    }

    return $result
}

function Get-PlexMetadataProviderBaseUrl {
    $defaultUrl = "https://metadata.provider.plex.tv"
    $testUrl = [string]$env:TAUTWEEKLY_TEST_PLEX_METADATA_PROVIDER_URL
    if ([string]::IsNullOrWhiteSpace($testUrl)) { return $defaultUrl }

    try {
        $uri = [Uri]$testUrl
        if ($uri.IsLoopback -and $uri.Scheme -in @("http", "https")) {
            return $testUrl.TrimEnd("/")
        }
    }
    catch { }

    return $defaultUrl
}

function Get-PlexWatchBaseUrl {
    $defaultUrl = "https://watch.plex.tv"
    $testUrl = [string]$env:TAUTWEEKLY_TEST_PLEX_WATCH_URL
    if ([string]::IsNullOrWhiteSpace($testUrl)) { return $defaultUrl }

    try {
        $uri = [Uri]$testUrl
        if ($uri.IsLoopback -and $uri.Scheme -in @("http", "https")) {
            return $testUrl.TrimEnd("/")
        }
    }
    catch { }

    return $defaultUrl
}

function Get-PlexWatchRatings {
    param(
        [string]$Slug,
        [ValidateSet("movie", "show")]
        [string]$MediaType
    )

    $result = [PSCustomObject]@{ RtCritic = ""; RtAudience = ""; Imdb = "" }
    if ([string]::IsNullOrWhiteSpace($Slug)) { return $result }

    $slugValue = $Slug.Trim().ToLowerInvariant()
    if ($slugValue -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { return $result }

    $cacheKey = $MediaType + ":" + $slugValue
    if ($script:PlexWatchRatingCache.ContainsKey($cacheKey)) {
        return $script:PlexWatchRatingCache[$cacheKey]
    }

    try {
        $response = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri ((Get-PlexWatchBaseUrl) + "/" + $MediaType + "/" + $slugValue) `
            -Headers @{
                "Accept-Language" = "en-US,en;q=0.9"
                "User-Agent"      = "TautWeekly-for-Plex/0.11.1"
            } `
            -TimeoutSec 60
        $content = [string]$response.Content
        $ratingsStart = $content.IndexOf('data-testid="metadata-ratings"', [StringComparison]::OrdinalIgnoreCase)
        if ($ratingsStart -ge 0) {
            $ratingsHtml = $content.Substring(
                $ratingsStart,
                [Math]::Min(12000, $content.Length - $ratingsStart)
            )

            $criticMatch = [regex]::Match(
                $ratingsHtml,
                'title=["''](?<value>[0-9]+(?:\.[0-9]+)?)% critic rating on Rotten Tomatoes["'']',
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            $audienceMatch = [regex]::Match(
                $ratingsHtml,
                'title=["''](?<value>[0-9]+(?:\.[0-9]+)?)% audience rating on Rotten Tomatoes["'']',
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            $imdbMatch = [regex]::Match(
                $ratingsHtml,
                'title=["''](?<value>[0-9]+(?:\.[0-9]+)?) audience rating on IMDb["'']',
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if ($criticMatch.Success) { $result.RtCritic = [string]$criticMatch.Groups["value"].Value }
            if ($audienceMatch.Success) { $result.RtAudience = [string]$audienceMatch.Groups["value"].Value }
            if ($imdbMatch.Success) { $result.Imdb = [string]$imdbMatch.Groups["value"].Value }
        }
    }
    catch {
        Write-Log "Plex public rating fallback failed for exact $MediaType metadata: $($_.Exception.Message)" "WARN"
    }

    $script:PlexWatchRatingCache[$cacheKey] = $result
    return $result
}

function Get-PlexHostedMetadataLookupPath {
    param(
        [string]$MetadataGuid,
        [ValidateSet("movie", "show")]
        [string]$MediaType
    )

    if ([string]::IsNullOrWhiteSpace($MetadataGuid)) { return "" }

    $guid = $MetadataGuid.Trim()
    if ($guid -match '(?i)^plex://(?:movie|show|season|episode)/(?<id>[a-z0-9][a-z0-9_-]*)(?:\?.*)?$') {
        return "/library/metadata/" + [Uri]::EscapeDataString([string]$Matches.id)
    }

    $externalGuid = ""
    if ($guid -match '(?i)^tmdb://(?<id>[0-9]+)(?:/[^?]*)?(?:\?.*)?$') {
        $externalGuid = "tmdb://" + [string]$Matches.id
    }
    elseif ($guid -match '(?i)^imdb://(?<id>tt[0-9]+)(?:\?.*)?$') {
        $externalGuid = "imdb://" + [string]$Matches.id
    }
    elseif ($guid -match '(?i)^com\.plexapp\.agents\.(?:themoviedb|tmdb)://(?<id>[0-9]+)(?:/[^?]*)?(?:\?.*)?$') {
        $externalGuid = "tmdb://" + [string]$Matches.id
    }
    elseif ($guid -match '(?i)^com\.plexapp\.agents\.imdb://(?<id>tt[0-9]+)(?:\?.*)?$') {
        $externalGuid = "imdb://" + [string]$Matches.id
    }
    elseif ($MediaType -eq "show" -and
        $guid -match '(?i)^(?:tvdb|com\.plexapp\.agents\.thetvdb)://(?<id>[0-9]+)(?:/[^?]*)?(?:\?.*)?$') {
        $externalGuid = "tvdb://" + [string]$Matches.id
    }

    if ([string]::IsNullOrWhiteSpace($externalGuid)) { return "" }

    $providerType = if ($MediaType -eq "movie") { 1 } else { 2 }
    return "/library/metadata/matches?guid=" +
        [Uri]::EscapeDataString($externalGuid) +
        "&type=" + $providerType
}

function Get-PlexHostedMetadataMatchPayload {
    param(
        [string]$MetadataGuid,
        [ValidateSet("movie", "show")]
        [string]$MediaType,
        [string]$LookupPath,
        [string]$MatchTitle = "",
        [string]$MatchYear = "",
        [int]$ParentIndex = 0,
        [int]$Index = 0
    )

    if ([string]::IsNullOrWhiteSpace($MetadataGuid) -or [string]::IsNullOrWhiteSpace($LookupPath)) { return $null }

    $exactGuid = ""
    $providerType = 0
    if ($LookupPath -match '^/library/metadata/matches\?guid=(?<guid>[^&]+)&type=(?<type>[12])$') {
        $exactGuid = [Uri]::UnescapeDataString([string]$Matches.guid)
        $providerType = [int]$Matches.type
    }
    elseif ($MetadataGuid.Trim() -match '(?i)^plex://(?<kind>movie|show|season|episode)/(?<id>[a-z0-9][a-z0-9_-]*)(?:\?.*)?$') {
        $kind = ([string]$Matches.kind).ToLowerInvariant()
        $exactGuid = "plex://" + $kind + "/" + [string]$Matches.id
        $providerType = switch ($kind) {
            "movie" { 1 }
            "show" { 2 }
            "season" { 3 }
            "episode" { 4 }
        }
    }

    if ([string]::IsNullOrWhiteSpace($exactGuid) -or $providerType -eq 0) { return $null }

    $payload = [ordered]@{ guid = $exactGuid; type = $providerType }
    $title = $MatchTitle.Trim()
    if ($providerType -in @(1, 2)) {
        if ([string]::IsNullOrWhiteSpace($title)) { return $null }
        $payload.title = $title
        if ($providerType -eq 1) {
            $year = Safe-Int $MatchYear
            if ($year -gt 0) { $payload.year = $year }
        }
    }
    elseif ($providerType -eq 3) {
        if ([string]::IsNullOrWhiteSpace($title) -or $Index -le 0) { return $null }
        $payload.parentTitle = $title
        $payload.index = $Index
    }
    elseif ($providerType -eq 4) {
        if ([string]::IsNullOrWhiteSpace($title) -or $ParentIndex -le 0 -or $Index -le 0) { return $null }
        $payload.grandparentTitle = $title
        $payload.parentIndex = $ParentIndex
        $payload.index = $Index
    }

    return $payload
}

function Get-PlexHostedMetadataItemFromResponse {
    param([object]$Response)

    if ($null -eq $Response) { return $null }

    $containerProperty = $Response.PSObject.Properties["MediaContainer"]
    if ($null -eq $containerProperty -or $null -eq $containerProperty.Value) { return $null }

    $metadataProperty = $containerProperty.Value.PSObject.Properties["Metadata"]
    if ($null -eq $metadataProperty) { return $null }

    $rows = @($metadataProperty.Value)
    if ($rows.Count -eq 0) { return $null }
    return $rows[0]
}

function Test-PlexHostedMetadataExactMatch {
    param(
        [object]$Metadata,
        [object]$MatchPayload
    )

    if ($null -eq $Metadata -or $null -eq $MatchPayload) { return $false }
    $expectedGuid = if ($MatchPayload -is [System.Collections.IDictionary] -and $MatchPayload.Contains("guid")) {
        [string]$MatchPayload["guid"]
    }
    else {
        Get-OptionalStringProperty -InputObject $MatchPayload -Name "guid"
    }
    if ([string]::IsNullOrWhiteSpace($expectedGuid)) { return $false }

    if ($expectedGuid -match '(?i)^plex://') {
        $resolvedGuid = Get-OptionalStringProperty -InputObject $Metadata -Name "guid"
        return (-not [string]::IsNullOrWhiteSpace($resolvedGuid) -and $resolvedGuid -ieq $expectedGuid)
    }

    $externalGuidProperty = @(
        $Metadata.PSObject.Properties |
            Where-Object { $_.Name -ceq "Guid" } |
            Select-Object -First 1
    )
    if ($externalGuidProperty.Count -gt 0) {
        foreach ($guidEntry in @($externalGuidProperty[0].Value)) {
            $candidate = Get-OptionalStringProperty -InputObject $guidEntry -Name "id"
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and $candidate -ieq $expectedGuid) {
                return $true
            }
        }
        return $false
    }

    # Some Plex JSON responses omit the external Guid[] array. The request is
    # still anchored to a validated TMDB/TVDB/IMDb identifier; require its
    # retained title and media type to agree before accepting that response.
    $expectedTitle = if ($MatchPayload -is [System.Collections.IDictionary] -and $MatchPayload.Contains("title")) {
        [string]$MatchPayload["title"]
    }
    else { "" }
    $expectedType = if ($MatchPayload -is [System.Collections.IDictionary] -and $MatchPayload.Contains("type")) {
        switch ([int]$MatchPayload["type"]) { 1 { "movie" }; 2 { "show" }; default { "" } }
    }
    else { "" }
    $resolvedTitle = Get-OptionalStringProperty -InputObject $Metadata -Name "title"
    $resolvedType = Get-OptionalStringProperty -InputObject $Metadata -Name "type"
    return (
        -not [string]::IsNullOrWhiteSpace($expectedTitle) -and
        $resolvedTitle.Trim() -ieq $expectedTitle.Trim() -and
        $resolvedType -ieq $expectedType
    )
}

function Get-PlexHostedMetadata {
    param(
        [string]$MetadataGuid,
        [ValidateSet("movie", "show")]
        [string]$MediaType,
        [string]$MatchTitle = "",
        [string]$MatchYear = "",
        [int]$ParentIndex = 0,
        [int]$Index = 0
    )

    if ([string]::IsNullOrWhiteSpace($MetadataGuid)) { return $null }

    $cacheKey = @($MediaType, $MetadataGuid.Trim(), $MatchTitle.Trim(), $MatchYear.Trim(), $ParentIndex, $Index) -join "|"
    if ($script:PlexHostedMetadataCache.ContainsKey($cacheKey)) {
        return $script:PlexHostedMetadataCache[$cacheKey]
    }

    $lookupPath = Get-PlexHostedMetadataLookupPath -MetadataGuid $MetadataGuid -MediaType $MediaType
    if ([string]::IsNullOrWhiteSpace($lookupPath)) {
        Write-Log "Plex hosted metadata recovery skipped a retained $MediaType GUID because its exact provider format is unsupported." "WARN"
        $script:PlexHostedMetadataCache[$cacheKey] = $null
        return $null
    }
    $matchPayload = Get-PlexHostedMetadataMatchPayload `
        -MetadataGuid $MetadataGuid `
        -MediaType $MediaType `
        -LookupPath $lookupPath `
        -MatchTitle $MatchTitle `
        -MatchYear $MatchYear `
        -ParentIndex $ParentIndex `
        -Index $Index

    $ctx = Get-DesignPlexContext
    $token = Get-OptionalStringProperty -InputObject $ctx -Name "Token"
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Log "Plex hosted metadata recovery requires the configured administrator Plex token." "WARN"
        $script:PlexHostedMetadataCache[$cacheKey] = $null
        return $null
    }

    $headers = @{
        "Accept"                   = "application/json"
        "X-Plex-Token"             = $token
        "X-Plex-Product"           = "TautWeekly for Plex"
        "X-Plex-Version"           = "0.11.1"
        "X-Plex-Client-Identifier" = "tautweekly-history-artwork"
    }

    $metadata = $null
    $requestCompleted = $false
    $postRetryAttempted = $false
    try {
        $providerBaseUrl = Get-PlexMetadataProviderBaseUrl
        $raw = Invoke-RestMethod `
            -Uri ($providerBaseUrl + $lookupPath) `
            -Headers $headers `
            -Method Get `
            -TimeoutSec 60
        $requestCompleted = $true
        $metadata = Get-PlexHostedMetadataItemFromResponse -Response $raw
        if ($null -ne $metadata) {
            $isExactResponse = if ($null -ne $matchPayload) {
                Test-PlexHostedMetadataExactMatch -Metadata $metadata -MatchPayload $matchPayload
            }
            elseif ($MetadataGuid.Trim() -match '(?i)^plex://(?<kind>movie|show|season|episode)/(?<id>[a-z0-9][a-z0-9_-]*)(?:\?.*)?$') {
                (Get-OptionalStringProperty -InputObject $metadata -Name "guid") -ieq
                    ("plex://" + ([string]$Matches.kind).ToLowerInvariant() + "/" + [string]$Matches.id)
            }
            else {
                (Get-OptionalStringProperty -InputObject $metadata -Name "type") -ieq $MediaType
            }
            if (-not $isExactResponse) {
                Write-Log "Plex hosted metadata rejected a non-exact $MediaType response for the retained identifier." "WARN"
                $metadata = $null
            }
        }
    }
    catch {
        Write-Log "Plex hosted direct identifier lookup failed for deleted $MediaType history metadata: $($_.Exception.Message)" "WARN"
    }

    # Plex's current provider contract requires retained title context for
    # movies/shows and show-title plus season/episode indexes for episodes.
    # These are matching hints only: require an exact modern GUID, or require
    # external-ID responses to agree with returned IDs or retained type/title.
    if ($null -eq $metadata -and $null -ne $matchPayload) {
        try {
            $matchBody = $matchPayload | ConvertTo-Json -Compress
            $postRetryAttempted = $true
            $requestCompleted = $false
            $raw = Invoke-RestMethod `
                -Uri ($providerBaseUrl + "/library/metadata/matches") `
                -Headers $headers `
                -Method Post `
                -Body $matchBody `
                -ContentType "application/json" `
                -TimeoutSec 60
            $requestCompleted = $true
            $metadata = Get-PlexHostedMetadataItemFromResponse -Response $raw
            if ($null -ne $metadata -and -not (Test-PlexHostedMetadataExactMatch -Metadata $metadata -MatchPayload $matchPayload)) {
                Write-Log "Plex hosted metadata rejected a non-exact $MediaType response for the retained identifier." "WARN"
                $metadata = $null
            }
            elseif ($null -ne $metadata) {
                Write-Log "Plex hosted metadata recovered an exact $MediaType match through the provider POST contract."
            }
        }
        catch {
            Write-Log "Plex hosted metadata fallback failed for deleted $MediaType history metadata: $($_.Exception.Message)" "WARN"
        }
    }

    if ($requestCompleted -and $null -eq $metadata) {
        $attemptDescription = if ($postRetryAttempted) { "query and provider POST attempts" } else { "the supported request" }
        Write-Log "Optional Plex hosted metadata recovery found no exact match for the retained $MediaType GUID after $attemptDescription; continuing with available local/Tautulli metadata."
    }

    if ($null -ne $metadata -and $MediaType -eq "show") {
        $resolvedType = Get-OptionalStringProperty -InputObject $metadata -Name "type"
        if ($resolvedType -ne "show") {
            $showGuid = if ($resolvedType -eq "season") {
                Get-OptionalStringProperty -InputObject $metadata -Name "parentGuid"
            }
            else {
                Get-OptionalStringProperty -InputObject $metadata -Name "grandparentGuid"
            }
            if ([string]::IsNullOrWhiteSpace($showGuid)) {
                $showGuid = if ($resolvedType -eq "season") {
                    Get-OptionalStringProperty -InputObject $metadata -Name "parent_guid"
                }
                else {
                    Get-OptionalStringProperty -InputObject $metadata -Name "grandparent_guid"
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($showGuid) -and $showGuid -ne $MetadataGuid) {
                $showMetadata = Get-PlexHostedMetadata `
                    -MetadataGuid $showGuid `
                    -MediaType "show" `
                    -MatchTitle $MatchTitle
                if ($null -ne $showMetadata) { $metadata = $showMetadata }
            }
        }
    }

    $script:PlexHostedMetadataCache[$cacheKey] = $metadata
    return $metadata
}

function Get-PlexHostedPosterPath {
    param(
        [string]$MetadataGuid,
        [ValidateSet("movie", "show")]
        [string]$MediaType,
        [string]$DestinationPath,
        [string]$MatchTitle = "",
        [string]$MatchYear = "",
        [int]$ParentIndex = 0,
        [int]$Index = 0
    )

    if ([string]::IsNullOrWhiteSpace($MetadataGuid) -or
        [string]::IsNullOrWhiteSpace($DestinationPath)) {
        return ""
    }

    $metadata = Get-PlexHostedMetadata `
        -MetadataGuid $MetadataGuid `
        -MediaType $MediaType `
        -MatchTitle $MatchTitle `
        -MatchYear $MatchYear `
        -ParentIndex $ParentIndex `
        -Index $Index
    if ($null -eq $metadata) { return "" }

    $fieldNames = if ($MediaType -eq "show") {
        @("thumb", "grandparentThumb", "grandparent_thumb", "parentThumb", "parent_thumb")
    }
    else {
        @("thumb")
    }

    $posterUrl = ""
    foreach ($fieldName in $fieldNames) {
        $posterUrl = Get-OptionalStringProperty -InputObject $metadata -Name $fieldName
        if (-not [string]::IsNullOrWhiteSpace($posterUrl)) { break }
    }
    if ([string]::IsNullOrWhiteSpace($posterUrl)) { return "" }

    $providerBaseUrl = Get-PlexMetadataProviderBaseUrl
    $assetUrl = $posterUrl
    $headers = @{}

    try {
        if ($posterUrl.StartsWith("/")) {
            $assetUrl = $providerBaseUrl + $posterUrl
            $headers["X-Plex-Token"] = [string](Get-DesignPlexContext).Token
        }
        else {
            $assetUri = [Uri]$posterUrl
            if ($assetUri.Scheme -notin @("http", "https")) { return "" }

            $providerUri = [Uri]$providerBaseUrl
            if ($assetUri.Scheme -ieq $providerUri.Scheme -and
                $assetUri.Host -ieq $providerUri.Host -and
                $assetUri.Port -eq $providerUri.Port) {
                $headers["X-Plex-Token"] = [string](Get-DesignPlexContext).Token
            }
        }

        if ($headers.Count -gt 0) {
            Invoke-WebRequest -Uri $assetUrl -Headers $headers -OutFile $DestinationPath -TimeoutSec 60 | Out-Null
        }
        else {
            Invoke-WebRequest -Uri $assetUrl -OutFile $DestinationPath -TimeoutSec 60 | Out-Null
        }

        if ((Test-Path $DestinationPath) -and (Get-Item $DestinationPath).Length -gt 512) {
            Write-Log "Recovered deleted Plex $MediaType history artwork from its retained metadata GUID."
            return $DestinationPath
        }
    }
    catch {
        Write-Log "Plex hosted poster download failed for deleted $MediaType history artwork: $($_.Exception.Message)" "WARN"
    }

    Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
    return ""
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    $algorithm = $null
    try {
        $stream = [IO.File]::OpenRead((Get-Item -LiteralPath $Path).FullName)
        $algorithm = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '')
    }
    finally {
        if ($null -ne $algorithm) { $algorithm.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-TautulliDefaultPosterHash {
    if (-not [string]::IsNullOrWhiteSpace($script:TautulliDefaultPosterHash)) {
        return $script:TautulliDefaultPosterHash
    }

    $probePath = Join-Path $PosterDir ("tautulli-default-poster-" + [Guid]::NewGuid().ToString("N") + ".png")
    try {
        $uri = Build-TautulliUri -Command "pms_image_proxy" -Parameters @{
            fallback = "poster"
        }
        Invoke-WebRequest -Uri $uri -OutFile $probePath -TimeoutSec 60 | Out-Null
        if ((Test-Path -LiteralPath $probePath) -and (Get-Item -LiteralPath $probePath).Length -gt 0) {
            $script:TautulliDefaultPosterHash = Get-FileSha256 -Path $probePath
        }
    }
    catch {
        Write-Log "Could not fingerprint Tautulli's generic poster fallback: $($_.Exception.Message)" "WARN"
    }
    finally {
        Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
    }

    return $script:TautulliDefaultPosterHash
}

function Test-IsTautulliDefaultPoster {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return $false }

    $defaultHash = Get-TautulliDefaultPosterHash
    if ([string]::IsNullOrWhiteSpace($defaultHash)) { return $false }

    return ((Get-FileSha256 -Path $Path) -eq $defaultHash)
}

function Get-PosterPath {
    param(
        [string]$RatingKey,
        [string]$MetadataGuid = "",
        [ValidateSet("movie", "show")]
        [string]$MediaType = "movie",
        [string]$MatchTitle = "",
        [string]$MatchYear = "",
        [int]$ParentIndex = 0,
        [int]$Index = 0,
        [ref]$LivePlexPoster = $null
    )

    if ([string]::IsNullOrWhiteSpace($RatingKey)) { return "" }
    if ($null -ne $LivePlexPoster) { $LivePlexPoster.Value = $false }

    $cid = "poster_" + (Get-SafeFilePart $RatingKey)
    $path = Join-Path $PosterDir ($cid + ".jpg")

    # Never promote a prior generated-output file into persistent state. A
    # cache capture must be backed by a fresh local Plex/Tautulli response.
    Remove-Item $path -Force -ErrorAction SilentlyContinue

    $uri = Build-TautulliUri -Command "pms_image_proxy" -Parameters @{
        rating_key = $RatingKey
        width      = 300
        height     = 450
        img_format = "jpg"
        fallback   = "poster"
    }

    try {
        Invoke-WebRequest -Uri $uri -OutFile $path -TimeoutSec 60 | Out-Null
        if ((Test-Path $path) -and (Get-Item $path).Length -gt 512) {
            $isGenericFallback = Test-IsTautulliDefaultPoster -Path $path
            if (-not $isGenericFallback) {
                if ($null -ne $LivePlexPoster) { $LivePlexPoster.Value = $true }
                return $path
            }

            if (-not [string]::IsNullOrWhiteSpace($MetadataGuid)) {
                Write-Log "Tautulli returned its generic poster for deleted Plex $MediaType history; trying the exact pre-deletion cache and retained metadata GUID."
            }
            else {
                Write-Log "Deleted Plex $MediaType history has no retained stable GUID; the persistent cache will not title-match it." "WARN"
            }
        }
    }
    catch {
        Write-Log "Poster fetch failed for rating key ${RatingKey}: $($_.Exception.Message)" "WARN"
    }

    Remove-Item $path -Force -ErrorAction SilentlyContinue
    $cachedPath = Restore-TautWeeklyDeletedItemCachePoster `
        -MediaType $MediaType `
        -MetadataGuid $MetadataGuid `
        -DestinationPath $path
    if (-not [string]::IsNullOrWhiteSpace($cachedPath)) { return $cachedPath }

    $hostedPath = Get-PlexHostedPosterPath `
        -MetadataGuid $MetadataGuid `
        -MediaType $MediaType `
        -DestinationPath $path `
        -MatchTitle $MatchTitle `
        -MatchYear $MatchYear `
        -ParentIndex $ParentIndex `
        -Index $Index
    if (-not [string]::IsNullOrWhiteSpace($hostedPath)) { return $hostedPath }

    if (-not [string]::IsNullOrWhiteSpace($MetadataGuid)) {
        Write-Log "No stored pre-deletion $MediaType artwork matched the exact retained GUID; Plex hosted recovery also had no usable asset." "WARN"
    }

    return ""
}

function Prepare-PosterAssets {
    param(
        [object]$ReleaseData,
        [string]$FeaturedRatingKey = "",
        [AllowNull()][object]$HotRelease = $null,
        [bool]$QuietReleaseMode = $false,
        [object[]]$AdditionalItems = @()
    )

    $releaseDisplay = Get-NewsletterReleaseDisplayData `
        -ReleaseData $ReleaseData `
        -HotRelease $HotRelease `
        -QuietReleaseMode $QuietReleaseMode

    $selected = New-Object System.Collections.Generic.List[object]

    if (-not [string]::IsNullOrWhiteSpace($FeaturedRatingKey)) {
        $featured = @(
            @($ReleaseData.Movies) + @($ReleaseData.TV) + @($AdditionalItems) |
            Where-Object { [string]$_.PosterRatingKey -eq $FeaturedRatingKey } |
            Select-Object -First 1
        )
        if ($featured.Count -gt 0) {
            $selected.Add($featured[0])
        }
        else {
            # A quiet-release Trending hero may not be one of the latest cards.
            # Fetch its poster independently so the featured hero is never blank.
            $selected.Add([PSCustomObject]@{
                PosterRatingKey = $FeaturedRatingKey
            })
        }
    }

    foreach ($m in @($releaseDisplay.Movies)) {
        $selected.Add($m)
    }
    foreach ($t in @($releaseDisplay.TV)) {
        $selected.Add($t)
    }

    foreach ($extra in @($AdditionalItems)) {
        if ($null -ne $extra) {
            $selected.Add($extra)
        }
    }

    $assets = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($item in $selected) {
        $rk = [string]$item.PosterRatingKey
        if ([string]::IsNullOrWhiteSpace($rk) -or $seen.ContainsKey($rk)) { continue }

        $seen[$rk] = $true
        $metadataGuid = Get-OptionalStringProperty -InputObject $item -Name "MetadataGuid"
        $mediaType = Get-OptionalStringProperty -InputObject $item -Name "Type"
        if ($mediaType -ne "show") { $mediaType = "movie" }
        $matchTitle = Get-OptionalStringProperty -InputObject $item -Name "Title"
        $matchYear = Get-OptionalStringProperty -InputObject $item -Name "Year"
        $matchParentIndex = Safe-Int (Get-OptionalStringProperty -InputObject $item -Name "MetadataParentIndex")
        $matchIndex = Safe-Int (Get-OptionalStringProperty -InputObject $item -Name "MetadataIndex")
        $cacheCaptureEligible = (
            $null -ne $item.PSObject.Properties["CacheCaptureEligible"] -and
            [bool]$item.CacheCaptureEligible
        )

        $livePlexPoster = $false
        $path = Get-PosterPath `
            -RatingKey $rk `
            -MetadataGuid $metadataGuid `
            -MediaType $mediaType `
            -MatchTitle $matchTitle `
            -MatchYear $matchYear `
            -ParentIndex $matchParentIndex `
            -Index $matchIndex `
            -LivePlexPoster ([ref]$livePlexPoster)
        if ($cacheCaptureEligible -and $livePlexPoster -and -not [string]::IsNullOrWhiteSpace($path)) {
            [void](Update-TautWeeklyDeletedItemCache -Item $item -PosterPath $path)
        }
        elseif (-not $cacheCaptureEligible) {
            Register-TautWeeklyDeletedItemCacheCaptureSkip -Reason metadata
        }
        else {
            Register-TautWeeklyDeletedItemCacheCaptureSkip -Reason poster
        }
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $assets.Add([PSCustomObject]@{
                RatingKey = $rk
                Cid       = "poster_" + (Get-SafeFilePart $rk)
                Path      = $path
                FileName  = [IO.Path]::GetFileName($path)
            })
        }
    }

    return $assets.ToArray()
}

function Get-ImageSource {
    param(
        [string]$RatingKey,
        [object[]]$PosterAssets,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode
    )

    if ([string]::IsNullOrWhiteSpace($RatingKey)) { return "" }

    $asset = @(
        $PosterAssets |
            Where-Object { (Get-OptionalStringProperty -InputObject $_ -Name "RatingKey") -eq $RatingKey } |
            Select-Object -First 1
    )
    if ($asset.Count -eq 0) { return "" }

    if ($ImageMode -eq "Email") {
        return "cid:" + [string]$asset[0].Cid
    }

    return "posters/" + [string]$asset[0].FileName
}

function Get-RecipientWatchedAssetSource {
    param(
        [string]$FileName,
        [string]$Cid,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode,
        [string]$PreviewAssetBase
    )

    if ($ImageMode -eq "Email") { return "cid:" + $Cid }
    return $PreviewAssetBase.TrimEnd('/') + "/" + $FileName
}

function Get-RecipientWatchedTitleIconHtml {
    param(
        [AllowNull()][object]$Item,
        [AllowNull()][object]$RecipientWatchedMovies,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode,
        [string]$PreviewAssetBase
    )

    if (-not (Test-RecipientHasWatchedMovie -Item $Item -RecipientWatchedMovies $RecipientWatchedMovies)) {
        return ""
    }

    $source = Get-RecipientWatchedAssetSource -FileName "watched.png" -Cid "recipient_watched" -ImageMode $ImageMode -PreviewAssetBase $PreviewAssetBase
    return '<img class="recipient-watched-title-icon" src="' + (HtmlEncode $source) + '" width="16" height="16" alt="Watched" title="Watched" style="display:inline-block;width:16px;height:16px;border:0;vertical-align:middle;margin-left:8px;">'
}

function Get-RecipientWatchedTitleHtml {
    param(
        [string]$EncodedTitle,
        [AllowNull()][object]$Item,
        [AllowNull()][object]$RecipientWatchedMovies,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode,
        [string]$PreviewAssetBase
    )

    $icon = Get-RecipientWatchedTitleIconHtml -Item $Item -RecipientWatchedMovies $RecipientWatchedMovies -ImageMode $ImageMode -PreviewAssetBase $PreviewAssetBase
    if ([string]::IsNullOrWhiteSpace($icon)) { return $EncodedTitle }

    # Align both text and icon to the same middle, rather than aligning an
    # image to the font's x-height alone. Keep only the final word with the
    # icon; the preceding title remains free to wrap at every normal space.
    $lastSpace = $EncodedTitle.LastIndexOf(' ')
    $prefix = if ($lastSpace -ge 0) { $EncodedTitle.Substring(0, $lastSpace + 1) } else { '' }
    $tail = if ($lastSpace -ge 0) { $EncodedTitle.Substring($lastSpace + 1) } else { $EncodedTitle }
    $prefixHtml = if ($prefix.Length -gt 0) { '<span style="vertical-align:middle;">' + $prefix + '</span>' } else { '' }
    return $prefixHtml + '<span class="recipient-watched-title-tail" style="white-space:nowrap;"><span style="vertical-align:middle;">' + $tail + '</span>' + $icon + '</span>'
}

function Get-RecipientWatchedDesktopHeroPosterHtml {
    param(
        [AllowNull()][object]$Item,
        [AllowNull()][object]$RecipientWatchedMovies,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode,
        [string]$PreviewAssetBase,
        [string]$PosterSource,
        [string]$PosterAlt
    )

    if ([string]::IsNullOrWhiteSpace($PosterSource)) { return "" }
    $encodedPoster = HtmlEncode $PosterSource
    $encodedAlt = HtmlEncode $PosterAlt
    $posterHtml = '<img src="' + $encodedPoster + '" width="180" alt="' + $encodedAlt + '" style="display:block;width:180px;max-width:180px;height:auto;border:0;border-radius:8px;">'
    if (-not (Test-RecipientHasWatchedMovie -Item $Item -RecipientWatchedMovies $RecipientWatchedMovies)) {
        return $posterHtml
    }

    $source = Get-RecipientWatchedAssetSource -FileName "watched-desktop.png" -Cid "recipient_watched_desktop" -ImageMode $ImageMode -PreviewAssetBase $PreviewAssetBase
    $encodedSource = HtmlEncode $source
    # A zero-height poster layer followed by a transparent table avoids CSS
    # positioning in webmail. The table grid fixes the badge at x=147, y=0
    # while the poster starts at y=5: 7px inset, 5px above its top edge.
    # Classic Outlook receives one fixed VML coordinate system, never a
    # floating shape anchored relative to a character or line.
    return @"
<!--[if mso]>
<v:group xmlns:v="urn:schemas-microsoft-com:vml" coordorigin="0,0" coordsize="180,275" style="width:135pt;height:206.25pt;">
  <v:image src="$encodedPoster" alt="$encodedAlt" style="position:absolute;left:0;top:5;width:180;height:270;" />
  <v:image src="$encodedSource" alt="Watched" title="Watched" style="position:absolute;left:147;top:0;width:26;height:26;" />
</v:group>
<![endif]-->
<!--[if !mso]><!-- -->
<div class="recipient-watched-desktop-poster" style="width:180px;max-width:180px;line-height:0;">
  <div style="height:0;max-height:0;overflow:visible;line-height:0;">
    <table role="presentation" width="180" cellspacing="0" cellpadding="0" border="0" style="width:180px;border-collapse:collapse;"><tr><td style="padding:5px 0 0;">$posterHtml</td></tr></table>
  </div>
  <table role="presentation" width="180" height="275" cellspacing="0" cellpadding="0" border="0" style="width:180px;height:275px;border-collapse:collapse;">
    <tr>
      <td width="147" height="26" style="width:147px;height:26px;padding:0;font-size:0;line-height:0;"></td>
      <td width="26" height="26" valign="top" style="width:26px;height:26px;padding:0;"><img class="recipient-watched-desktop-badge" src="$encodedSource" width="26" height="26" alt="Watched" title="Watched" style="display:block;width:26px;height:26px;border:0;"></td>
      <td width="7" height="26" style="width:7px;height:26px;padding:0;font-size:0;line-height:0;"></td>
    </tr>
    <tr><td colspan="3" height="249" style="height:249px;padding:0;font-size:0;line-height:0;"></td></tr>
  </table>
</div>
<!--<![endif]-->
"@
}

function Get-RecipientWatchedPlainTextSuffix {
    param(
        [AllowNull()][object]$Item,
        [AllowNull()][object]$RecipientWatchedMovies
    )

    if (Test-RecipientHasWatchedMovie -Item $Item -RecipientWatchedMovies $RecipientWatchedMovies) {
        return " - Watched"
    }
    return ""
}
function Get-StatsMovieRatingHtml {
    param(
        [object]$Item,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode
    )

    $pieces = New-Object System.Collections.Generic.List[string]

    $critic = if ($null -ne $Item.PSObject.Properties["DesignRtCritic"]) {
        [string]$Item.DesignRtCritic
    } else { "" }
    $audience = if ($null -ne $Item.PSObject.Properties["DesignRtAudience"]) {
        [string]$Item.DesignRtAudience
    } else { "" }
    $criticImage = if ($null -ne $Item.PSObject.Properties["DesignRtCriticImage"]) {
        [string]$Item.DesignRtCriticImage
    } else { "" }
    $audienceImage = if ($null -ne $Item.PSObject.Properties["DesignRtAudienceImage"]) {
        [string]$Item.DesignRtAudienceImage
    } else { "" }

    if (-not [string]::IsNullOrWhiteSpace($critic)) {
        if ([string]::IsNullOrWhiteSpace($criticImage)) {
            $criticImage = if ((Safe-Int $critic) -ge 60) {
                "rottentomatoes://image.rating.ripe"
            } else {
                "rottentomatoes://image.rating.rotten"
            }
        }
        $icon = Get-DesignRtIconUrl -ImageState $criticImage -Kind "critic" -ImageMode $ImageMode
        $pieces.Add(
            '<span style="display:inline-block;white-space:nowrap;">' +
            '<img src="' + (HtmlEncode $icon) + '" alt="Rotten Tomatoes critic" width="16" height="16" style="display:inline-block;width:16px;height:16px;border:0;vertical-align:-3px;margin-right:3px;">' +
            (HtmlEncode ($critic + "%")) +
            '</span>'
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($audience)) {
        if ([string]::IsNullOrWhiteSpace($audienceImage)) {
            $audienceImage = if ((Safe-Int $audience) -ge 60) {
                "rottentomatoes://image.rating.upright"
            } else {
                "rottentomatoes://image.rating.spilled"
            }
        }
        $icon = Get-DesignRtIconUrl -ImageState $audienceImage -Kind "audience" -ImageMode $ImageMode
        $pieces.Add(
            '<span style="display:inline-block;white-space:nowrap;">' +
            '<img src="' + (HtmlEncode $icon) + '" alt="Rotten Tomatoes audience" width="16" height="16" style="display:inline-block;width:16px;height:16px;border:0;vertical-align:-3px;margin-right:3px;">' +
            (HtmlEncode ($audience + "%")) +
            '</span>'
        )
    }

    $hasRt = (
        -not [string]::IsNullOrWhiteSpace($critic) -or
        -not [string]::IsNullOrWhiteSpace($audience)
    )
    $imdb = Get-OptionalStringProperty -InputObject $Item -Name "DesignImdbRating"
    if (-not $hasRt -and -not [string]::IsNullOrWhiteSpace($imdb)) {
        $imdbIcon = if ($ImageMode -eq "Email") { "cid:icon_imdb" } else { "../assets/imdb.png" }
        $pieces.Add(
            '<span style="display:inline-block;white-space:nowrap;">' +
            '<img src="' + (HtmlEncode $imdbIcon) + '" alt="IMDb" width="28" height="14" style="display:inline-block;width:28px;height:14px;object-fit:contain;border:0;vertical-align:-3px;margin-right:5px;">' +
            (HtmlEncode $imdb) +
            '</span>'
        )
    }

    if ($pieces.Count -eq 0) {
        return ""
    }

    return ($pieces -join '<span style="display:inline-block;width:6px;"></span>')
}

function Get-StatsMovieRowsHtml {
    param(
        [object[]]$Items,
        [object[]]$PosterAssets,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode
    )

    $rows = New-Object System.Text.StringBuilder
    $cells = New-Object System.Text.StringBuilder
    $columnIndex = 0

    foreach ($item in @($Items)) {
        $title = HtmlEncode (Truncate-Text ([string]$item.Title) 42)
        $posterSrc = Get-ImageSource `
            -RatingKey ([string]$item.PosterRatingKey) `
            -PosterAssets $PosterAssets `
            -ImageMode $ImageMode

        $posterHtml = if ([string]::IsNullOrWhiteSpace($posterSrc)) {
            '<div style="width:42px;height:62px;border-radius:5px;background-color:#262626;border:1px solid #363636;"></div>'
        } else {
            '<img src="' + (HtmlEncode $posterSrc) + '" width="42" height="62" alt="' + $title + ' poster" style="display:block;width:42px;height:62px;object-fit:cover;border:1px solid #363636;border-radius:5px;">'
        }

        # Reuse the global movie genre formatter so watched-movie stats match
        # regular movie cards and movie heroes:
        # first two genres, then ", and more" when additional genres exist.
        $genreText = Get-DesignGenreLine -Item $item
        $genreHtml = ""
        if (-not [string]::IsNullOrWhiteSpace($genreText)) {
            $genreHtml = '<div style="padding-top:3px;font-size:12px;line-height:1.3;color:#9b9b9b;font-weight:500;">' +
                (HtmlEncode $genreText) +
                '</div>'
        }

        $ratingHtml = Get-StatsMovieRatingHtml -Item $item -ImageMode $ImageMode
        $ratingPadding = if ([string]::IsNullOrWhiteSpace($genreHtml)) { "5px" } else { "4px" }
        $ratingLineHtml = ""
        if (-not [string]::IsNullOrWhiteSpace($ratingHtml)) {
            $ratingLineHtml = '<div style="padding-top:' + $ratingPadding + ';font-size:12px;line-height:1.35;color:#e5a00d;font-weight:700;">' +
                $ratingHtml +
                '</div>'
        }

        $cellPadding = if ($columnIndex -eq 0) { "7px 12px 7px 0" } else { "7px 0 7px 12px" }
        [void]$cells.Append(@"
<td class="stats-title-cell" width="50%" valign="top" style="width:50%;padding:$cellPadding;border-bottom:1px solid #292929;">
  <table width="100%" cellspacing="0" cellpadding="0" border="0">
    <tr>
      <td width="50" valign="middle" style="width:50px;padding:0 8px 0 0;">$posterHtml</td>
      <td valign="middle" style="padding:0;">
        <div style="font-size:12px;line-height:1.3;color:#ffffff;font-weight:800;">$title</div>
        $genreHtml
        $ratingLineHtml
      </td>
    </tr>
  </table>
</td>
"@)
        $columnIndex++
        if ($columnIndex -eq 2) {
            [void]$rows.Append("<tr>$($cells.ToString())</tr>")
            [void]$cells.Clear()
            $columnIndex = 0
        }
    }

    if ($columnIndex -gt 0) {
        [void]$cells.Append('<td class="stats-title-spacer" width="50%" style="width:50%;border-bottom:1px solid #292929;"></td>')
        [void]$rows.Append("<tr>$($cells.ToString())</tr>")
    }

    return $rows.ToString()
}

function Get-StatsTvShowRatingHtml {
    param(
        [object]$Item,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode
    )

    $imdb = Get-OptionalStringProperty -InputObject $Item -Name "DesignImdbRating"
    if (-not [string]::IsNullOrWhiteSpace($imdb)) {
        $imdbIcon = if ($ImageMode -eq "Email") { "cid:icon_imdb" } else { "../assets/imdb.png" }
        return '<span style="display:inline-block;white-space:nowrap;">' +
            '<img src="' + (HtmlEncode $imdbIcon) + '" alt="IMDb" width="28" height="14" style="display:inline-block;width:28px;height:14px;object-fit:contain;border:0;vertical-align:-3px;margin-right:5px;">' +
            (HtmlEncode $imdb) +
            '</span>'
    }

    $rtValue = Get-OptionalStringProperty -InputObject $Item -Name "DesignRtCritic"
    $rtKind = "critic"
    $rtImage = Get-OptionalStringProperty -InputObject $Item -Name "DesignRtCriticImage"
    if ([string]::IsNullOrWhiteSpace($rtValue)) {
        $rtValue = Get-OptionalStringProperty -InputObject $Item -Name "DesignRtAudience"
        $rtKind = "audience"
        $rtImage = Get-OptionalStringProperty -InputObject $Item -Name "DesignRtAudienceImage"
    }

    if ([string]::IsNullOrWhiteSpace($rtValue)) { return "" }

    if ([string]::IsNullOrWhiteSpace($rtImage)) {
        $rtImage = if ($rtKind -eq "audience") {
            if ((Safe-Int $rtValue) -ge 60) { "rottentomatoes://image.rating.upright" } else { "rottentomatoes://image.rating.spilled" }
        }
        else {
            if ((Safe-Int $rtValue) -ge 60) { "rottentomatoes://image.rating.ripe" } else { "rottentomatoes://image.rating.rotten" }
        }
    }

    $rtIcon = Get-DesignRtIconUrl -ImageState $rtImage -Kind $rtKind -ImageMode $ImageMode
    $rtAlt = if ($rtKind -eq "audience") { "Rotten Tomatoes audience" } else { "Rotten Tomatoes critic" }
    return '<span style="display:inline-block;white-space:nowrap;">' +
        '<img src="' + (HtmlEncode $rtIcon) + '" alt="' + $rtAlt + '" width="16" height="16" style="display:inline-block;width:16px;height:16px;object-fit:contain;border:0;vertical-align:-3px;margin-right:4px;">' +
        (HtmlEncode ($rtValue + "%")) +
        '</span>'
}

function Get-StatsEpisodeRowsHtml {
    param(
        [object[]]$Items,
        [object[]]$PosterAssets,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode,
        [string]$ImdbIconSrc
    )

    $rows = New-Object System.Text.StringBuilder

    foreach ($item in @($Items | Select-Object -First 3)) {
        $showTitle = HtmlEncode (Truncate-Text ([string]$item.ShowTitle) 42)
        $episodeTitle = HtmlEncode (Truncate-Text ([string]$item.EpisodeTitle) 38)
        $season = Safe-Int $item.Season
        $episodeNumber = Safe-Int $item.Episode

        $prefix = ""
        if ($episodeNumber -gt 0) {
            $prefix = "S" + $season.ToString("00") + " EP" + $episodeNumber.ToString("00") + ": "
        }

        $posterSrc = Get-ImageSource `
            -RatingKey ([string]$item.PosterRatingKey) `
            -PosterAssets $PosterAssets `
            -ImageMode $ImageMode

        $posterHtml = if ([string]::IsNullOrWhiteSpace($posterSrc)) {
            '<div style="width:42px;height:62px;border-radius:5px;background-color:#262626;border:1px solid #363636;"></div>'
        } else {
            '<img src="' + (HtmlEncode $posterSrc) + '" width="42" height="62" alt="' + $showTitle + ' poster" style="display:block;width:42px;height:62px;object-fit:cover;border:1px solid #363636;border-radius:5px;">'
        }

        $imdb = [string]$item.ImdbRating
        $imdbLineHtml = if ([string]::IsNullOrWhiteSpace($imdb)) {
            ""
        } else {
            '<div style="padding-top:4px;font-size:12px;line-height:1.3;color:#e5a00d;font-weight:700;">' +
            '<span style="display:inline-block;white-space:nowrap;">' +
            '<img src="' + (HtmlEncode $ImdbIconSrc) + '" alt="IMDb" width="28" height="14" style="display:inline-block;width:28px;height:14px;object-fit:contain;border:0;vertical-align:-3px;margin-right:5px;">' +
            (HtmlEncode $imdb) +
            '</span></div>'
        }

        [void]$rows.Append(@"
<tr>
  <td width="50" valign="middle" style="width:50px;padding:7px 8px 7px 0;border-bottom:1px solid #292929;">$posterHtml</td>
  <td valign="middle" style="padding:7px 0;border-bottom:1px solid #292929;">
    <div style="font-size:12px;line-height:1.25;color:#ffffff;font-weight:800;">$showTitle</div>
    <div style="padding-top:3px;font-size:12px;line-height:1.3;color:#9b9b9b;">$(HtmlEncode $prefix)$episodeTitle</div>
    $imdbLineHtml
  </td>
</tr>
"@)
    }

    return $rows.ToString()
}

function Get-StatsTvShowRowsHtml {
    param(
        [object[]]$Items,
        [object[]]$PosterAssets,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode
    )

    $rows = New-Object System.Text.StringBuilder
    $cells = New-Object System.Text.StringBuilder
    $columnIndex = 0

    foreach ($item in @($Items)) {
        $showTitle = HtmlEncode (Truncate-Text ([string]$item.ShowTitle) 42)
        $posterSrc = Get-ImageSource `
            -RatingKey ([string]$item.PosterRatingKey) `
            -PosterAssets $PosterAssets `
            -ImageMode $ImageMode

        $posterHtml = if ([string]::IsNullOrWhiteSpace($posterSrc)) {
            '<div style="width:42px;height:62px;border-radius:5px;background-color:#262626;border:1px solid #363636;"></div>'
        } else {
            '<img src="' + (HtmlEncode $posterSrc) + '" width="42" height="62" alt="' + $showTitle + ' poster" style="display:block;width:42px;height:62px;object-fit:cover;border:1px solid #363636;border-radius:5px;">'
        }

        $episodeCount = Safe-Int (Get-OptionalStringProperty -InputObject $item -Name "EpisodeCount")
        $episodeWord = if ($episodeCount -eq 1) { "episode" } else { "episodes" }
        $episodeSummary = "$episodeCount $episodeWord"

        $ratingHtml = Get-StatsTvShowRatingHtml -Item $item -ImageMode $ImageMode
        $ratingLineHtml = if ([string]::IsNullOrWhiteSpace($ratingHtml)) {
            ""
        } else {
            '<div style="padding-top:4px;font-size:12px;line-height:1.35;color:#e5a00d;font-weight:700;">' +
            $ratingHtml +
            '</div>'
        }

        $cellPadding = if ($columnIndex -eq 0) { "7px 12px 7px 0" } else { "7px 0 7px 12px" }
        $cellClass = if ($columnIndex -eq 0) {
            "stats-title-cell stats-tv-title-cell stats-tv-title-left"
        } else {
            "stats-title-cell stats-tv-title-cell stats-tv-title-right"
        }
        [void]$cells.Append(@"
<td class="$cellClass" width="50%" valign="top" style="width:50%;padding:$cellPadding;border-bottom:1px solid #292929;">
  <table width="100%" cellspacing="0" cellpadding="0" border="0">
    <tr>
      <td width="50" valign="middle" style="width:50px;padding:0 8px 0 0;">$posterHtml</td>
      <td valign="middle" style="padding:0;">
        <div style="font-size:12px;line-height:1.3;color:#ffffff;font-weight:800;">$showTitle</div>
        $ratingLineHtml
        <div style="padding-top:3px;font-size:12px;line-height:1.35;color:#9b9b9b;font-weight:600;">$(HtmlEncode $episodeSummary)</div>
      </td>
    </tr>
  </table>
</td>
"@)
        $columnIndex++
        if ($columnIndex -eq 2) {
            [void]$rows.Append("<tr>$($cells.ToString())</tr>")
            [void]$cells.Clear()
            $columnIndex = 0
        }
    }

    if ($columnIndex -gt 0) {
        [void]$cells.Append('<td class="stats-title-spacer stats-tv-title-spacer" width="50%" style="width:50%;border-bottom:1px solid #292929;"></td>')
        [void]$rows.Append("<tr>$($cells.ToString())</tr>")
    }

    return $rows.ToString()
}

function Get-TvEpisodeLinesHtml {
    param(
        [object]$Item,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode = "Preview"
    )

    $episodes = @()
    if ($null -ne $Item.PSObject.Properties["Episodes"]) {
        $episodes = @($Item.Episodes)
    }

    if ($episodes.Count -eq 0) { return "" }

    $lines = New-Object System.Text.StringBuilder
    $shown = @($episodes | Select-Object -First 3)

    foreach ($episode in $shown) {
        $episodeTitle = HtmlEncode (Truncate-Text ([string]$episode.Title) 40)
        $seasonNumber = Safe-Int $episode.Season
        $episodeNumber = Safe-Int $episode.Episode

        $episodePrefix = ""
        if ($seasonNumber -ge 0 -and $episodeNumber -gt 0) {
            # Compact global TV-card format:
            # S01 EP02: Episode Title
            $seasonLabel = "S" + $seasonNumber.ToString("00")
            $episodeLabel = "EP" + $episodeNumber.ToString("00")
            $episodePrefix = "$seasonLabel $episodeLabel`: "
        }
        elseif ($episodeNumber -gt 0) {
            $episodePrefix = "EP" + $episodeNumber.ToString("00") + "`: "
        }

        $subtitleText = (HtmlEncode $episodePrefix) + $episodeTitle

        $imdb = ""
        if ($null -ne $episode.PSObject.Properties["ImdbRating"]) {
            $imdb = [string]$episode.ImdbRating
        }

        $ratingHtml = ""
        if (-not [string]::IsNullOrWhiteSpace($imdb)) {
            $imdbSrc = if ($ImageMode -eq "Email") { "cid:icon_imdb" } else { "assets/imdb.png" }
            $ratingHtml = '<span style="display:inline-block;margin-left:8px;color:#e5a00d;font-size:12px;font-weight:700;white-space:nowrap;">' +
            '<img src="' + $imdbSrc + '" alt="IMDb" width="28" height="14" style="display:inline-block;width:28px;height:14px;object-fit:contain;border:0;vertical-align:-3px;margin-right:5px;">' +
            (HtmlEncode $imdb) +
            '</span>'
        }
        else {
            $rtValue = Get-OptionalStringProperty -InputObject $episode -Name "RtRating"
            if (-not [string]::IsNullOrWhiteSpace($rtValue)) {
                $rtKind = (Get-OptionalStringProperty -InputObject $episode -Name "RtRatingKind").Trim().ToLowerInvariant()
                if ($rtKind -ne "audience") { $rtKind = "critic" }
                $rtImage = Get-OptionalStringProperty -InputObject $episode -Name "RtRatingImage"
                if ([string]::IsNullOrWhiteSpace($rtImage)) {
                    $rtImage = if ($rtKind -eq "audience") {
                        if ((Safe-Int $rtValue) -ge 60) { "rottentomatoes://image.rating.upright" } else { "rottentomatoes://image.rating.spilled" }
                    }
                    else {
                        if ((Safe-Int $rtValue) -ge 60) { "rottentomatoes://image.rating.ripe" } else { "rottentomatoes://image.rating.rotten" }
                    }
                }
                $rtSrc = Get-DesignRtIconUrl -ImageState $rtImage -Kind $rtKind -ImageMode $ImageMode
                $rtAlt = if ($rtKind -eq "audience") { "Rotten Tomatoes audience" } else { "Rotten Tomatoes critic" }
                $ratingHtml = '<span style="display:inline-block;margin-left:8px;color:#e5a00d;font-size:11px;font-weight:700;white-space:nowrap;">' +
                    '<img src="' + (HtmlEncode $rtSrc) + '" alt="' + $rtAlt + '" width="14" height="14" style="display:inline-block;width:14px;height:14px;object-fit:contain;border:0;vertical-align:-3px;margin-right:4px;">' +
                    (HtmlEncode ($rtValue + "%")) +
                    '</span>'
            }
        }

        [void]$lines.Append(
            '<div style="padding-top:2px;color:#b0b0b0;font-size:13px;font-weight:600;line-height:1.35;">' +
            $subtitleText + $ratingHtml +
            '</div>'
        )
    }

    # EpisodeCount is the authoritative weekly recently-added count when
    # Tautulli supplied episode rows. Episodes.Count remains the fallback for
    # release data assembled from direct episode metadata.
    $totalRecentlyAdded = $episodes.Count
    if ($null -ne $Item.PSObject.Properties["EpisodeCount"]) {
        $reportedCount = Safe-Int $Item.EpisodeCount
        if ($reportedCount -gt $totalRecentlyAdded) {
            $totalRecentlyAdded = $reportedCount
        }
    }

    $additionalRow = ""
    if ($totalRecentlyAdded -gt 3) {
        $remaining = $totalRecentlyAdded - 3
        $episodeWord = if ($remaining -eq 1) { "episode" } else { "episodes" }
        $additionalText = "$remaining additional $episodeWord recently added"

        $additionalRow = (
            '<tr><td height="24" valign="bottom" style="height:24px;padding-top:10px;color:#e5a00d;font-size:12px;font-weight:700;line-height:1.35;">' +
            (HtmlEncode $additionalText) +
            '</td></tr>'
        )
    }

    return (
        '<table width="100%" height="132" cellspacing="0" cellpadding="0" border="0" style="width:100%;height:132px;border-collapse:collapse;">' +
        '<tr><td valign="top" style="padding:0;">' + $lines.ToString() + '</td></tr>' +
        $additionalRow +
        '</table>'
    )
}

function Get-ReleaseCardsHtml {
    param(
        [object[]]$Items,
        [object[]]$PosterAssets,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode,
        [AllowNull()][object]$RecipientWatchedMovies,
        [string]$PreviewAssetBase,
        [ValidateSet("Movie","TV")]
        [string]$Kind
    )

    if ($Items.Count -eq 0) {
        return ''
    }

    $html = New-Object System.Text.StringBuilder
    $index = 0

    while ($index -lt $Items.Count) {
        [void]$html.Append('<tr>')

        for ($col = 0; $col -lt 2; $col++) {
            if ($index -ge $Items.Count) {
                [void]$html.Append('<td width="50%" style="padding:0 6px 18px;"></td>')
                continue
            }

            $item = $Items[$index]
            $title = HtmlEncode $item.Title
            $titleWithStatus = if ($Kind -eq "Movie") { Get-RecipientWatchedTitleHtml -EncodedTitle $title -Item $item -RecipientWatchedMovies $RecipientWatchedMovies -ImageMode $ImageMode -PreviewAssetBase $PreviewAssetBase } else { $title }
            $posterSrc = Get-ImageSource -RatingKey ([string]$item.PosterRatingKey) -PosterAssets $PosterAssets -ImageMode $ImageMode
            $posterHtml = ""

            if (-not [string]::IsNullOrWhiteSpace($posterSrc)) {
                $posterHtml = '<img src="' + (HtmlEncode $posterSrc) + '" width="100%" alt="' + $title + ' poster" style="display:block;width:100%;height:auto;border:0;border-radius:8px 8px 0 0;">'
            }
            else {
                $posterHtml = '<div style="height:260px;background-color:#222;border-radius:8px 8px 0 0;text-align:center;color:#777;font-size:12px;line-height:260px;">Poster unavailable</div>'
            }

            $contentHeight = if ($Kind -eq "Movie") { 170 } else { 184 }
            $contentHtml = ""

            if ($Kind -eq "Movie") {
                $genreText = Get-DesignGenreLine -Item $item
                $genreHtml = ""
                $metaTop = 10

                if (-not [string]::IsNullOrWhiteSpace($genreText)) {
                    $genreHtml = '<div style="padding-top:3px;color:#9b9b9b;font-size:13px;font-weight:500;line-height:1.35;">' +
                        (HtmlEncode $genreText) +
                        '</div>'
                    $metaTop = 13
                }

                $meta = Get-DesignRatingLine -Item $item -ImageMode $ImageMode
                $summary = Truncate-Text $item.Summary 150
                $summaryText = if ([string]::IsNullOrWhiteSpace($summary)) {
                    "&nbsp;"
                }
                else {
                    HtmlEncode $summary
                }

                # Movie content intentionally uses normal-flow DIV blocks rather
                # than a fixed-height inner table. This keeps the genre directly
                # beneath the title instead of distributing spare table height
                # between the genre and rating rows.
                $contentHtml = @"
<div style="color:#ffffff;font-size:16px;font-weight:700;line-height:1.25;">$titleWithStatus</div>
$genreHtml
<div style="padding-top:${metaTop}px;color:#e5a00d;font-size:12px;font-weight:600;line-height:1.25;">$meta</div>
<div style="padding-top:9px;color:#9b9b9b;font-size:12px;line-height:1.45;overflow:hidden;">$summaryText</div>
"@
            }
            else {
                $episodeLines = Get-TvEpisodeLinesHtml -Item $item -ImageMode $ImageMode
                $showRatingHtml = ""
                if ([string]::IsNullOrWhiteSpace($episodeLines)) {
                    $showImdb = Get-OptionalStringProperty -InputObject $item -Name "DesignImdbRating"
                    if (-not [string]::IsNullOrWhiteSpace($showImdb)) {
                        $imdbSrc = if ($ImageMode -eq "Email") { "cid:icon_imdb" } else { "../assets/imdb.png" }
                        $showRatingHtml = '<span style="display:inline-block;margin-left:8px;color:#e5a00d;font-size:12px;font-weight:700;white-space:nowrap;">' +
                            '<img src="' + $imdbSrc + '" alt="IMDb" width="28" height="14" style="display:inline-block;width:28px;height:14px;object-fit:contain;border:0;vertical-align:-3px;margin-right:5px;">' +
                            (HtmlEncode $showImdb) +
                            '</span>'
                    }
                }
                $tvDetails = ""

                if (-not [string]::IsNullOrWhiteSpace($episodeLines)) {
                    $tvDetails = @"
<tr>
  <td height="132" valign="top" style="height:132px;padding-top:2px;overflow:hidden;">
    $episodeLines
  </td>
</tr>
"@
                }
                else {
                    $meta = if ($item.SeasonCount -gt 0) {
                        if ($item.SeasonCount -eq 1) { "1 new season" } else { "$($item.SeasonCount) new seasons" }
                    }
                    elseif ($item.IsNewSeries) {
                        "New on Plex"
                    }
                    elseif ($item.EpisodeCount -gt 0) {
                        if ($item.EpisodeCount -eq 1) { "1 new episode" } else { "$($item.EpisodeCount) new episodes" }
                    }
                    else {
                        "New on Plex"
                    }

                    $tvDetails = @"
<tr>
  <td height="132" valign="top" style="height:132px;padding-top:4px;color:#e5a00d;font-size:12px;font-weight:600;line-height:1.35;">
    $(HtmlEncode $meta)
  </td>
</tr>
"@
                }

                $contentHtml = @"
<table width="100%" height="166" cellspacing="0" cellpadding="0" border="0" style="width:100%;height:166px;">
  <tr>
    <td height="34" valign="top" style="height:34px;color:#ffffff;font-size:16px;font-weight:700;line-height:1.25;">
      $title$showRatingHtml
    </td>
  </tr>
  $tvDetails
</table>
"@
            }

            [void]$html.Append(@"
<td width="50%" valign="top" style="padding:0 6px 18px;">
  <table class="email-card" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#181818" style="width:100%;background-color:#181818;border:1px solid #2b2b2b;border-radius:10px;border-collapse:separate;overflow:hidden;">
    <tr>
      <td valign="top" style="padding:0;">
        $posterHtml
      </td>
    </tr>
    <tr>
      <td height="$contentHeight" valign="top" style="height:${contentHeight}px;padding:12px 12px 14px;">
        $contentHtml
      </td>
    </tr>
  </table>
</td>
"@)
            $index++
        }

        [void]$html.Append('</tr>')
    }

    return $html.ToString()
}

function Get-NewsletterReleaseDisplayData {
    param(
        [object]$ReleaseData,
        [AllowNull()][object]$HotRelease,
        [bool]$QuietReleaseMode
    )

    $configuredMaxMovies = if ($null -ne $Config.PSObject.Properties["MaxMovies"]) { [Math]::Max(0, (Safe-Int $Config.MaxMovies)) } else { 8 }
    $configuredMaxTv = if ($null -ne $Config.PSObject.Properties["MaxTv"]) { [Math]::Max(0, (Safe-Int $Config.MaxTv)) } else { 8 }
    $maxMovies = if ($QuietReleaseMode) { [Math]::Min($configuredMaxMovies, 4) } else { $configuredMaxMovies }
    $maxTv = if ($QuietReleaseMode) { [Math]::Min($configuredMaxTv, 4) } else { $configuredMaxTv }
    $trendingHeroMode = (
        $null -ne $HotRelease -and
        $null -ne $HotRelease.PSObject.Properties["IsTrending"] -and
        [bool]$HotRelease.IsTrending
    )

    $movieSectionLabel = if ($null -ne $ReleaseData.PSObject.Properties["MovieSectionLabel"] -and
        -not [string]::IsNullOrWhiteSpace([string]$ReleaseData.MovieSectionLabel)) {
        [string]$ReleaseData.MovieSectionLabel
    }
    elseif ($QuietReleaseMode) { "RECENT RELEASES" } else { "NEW RELEASES" }
    $tvSectionLabel = if ($null -ne $ReleaseData.PSObject.Properties["TvSectionLabel"] -and
        -not [string]::IsNullOrWhiteSpace([string]$ReleaseData.TvSectionLabel)) {
        [string]$ReleaseData.TvSectionLabel
    }
    elseif ($QuietReleaseMode) { "RECENT RELEASES" } else { "NEW RELEASES" }

    $featuredReleaseKey = ""
    if ($null -ne $HotRelease -and $null -ne $HotRelease.Item) {
        $featuredReleaseKey = [string]$HotRelease.Item.ReleaseKey
    }

    $movies = @(
        $ReleaseData.Movies |
        Where-Object {
            [string]::IsNullOrWhiteSpace($featuredReleaseKey) -or
            [string]$_.ReleaseKey -ne $featuredReleaseKey
        } |
        Select-Object -First $maxMovies
    )
    $tv = @(
        $ReleaseData.TV |
        Where-Object {
            [string]::IsNullOrWhiteSpace($featuredReleaseKey) -or
            [string]$_.ReleaseKey -ne $featuredReleaseKey
        } |
        Select-Object -First $maxTv
    )

    if ($QuietReleaseMode) {
        if ($tvSectionLabel -eq "NEW RELEASES") {
            $weeklyTvCount = @($ReleaseData.TV).Count
            $weeklyTvWord = if ($weeklyTvCount -eq 1) { "TV TITLE" } else { "TV TITLES" }
            $countLine = "0 NEW MOVIES • $weeklyTvCount $weeklyTvWord"
        }
        else {
            $countParts = New-Object System.Collections.Generic.List[string]
            if ($trendingHeroMode -and
                $null -ne $HotRelease.Item -and
                [string]$HotRelease.Item.Type -eq "movie") {
                $countParts.Add("1 TRENDING MOVIE")
            }
            $movieReleaseWord = if ($movies.Count -eq 1) { "RECENT MOVIE RELEASE" } else { "RECENT MOVIE RELEASES" }
            $countParts.Add("$($movies.Count) $movieReleaseWord")
            $countLine = $countParts -join " • "
        }
    }
    else {
        $movieCount = @($ReleaseData.Movies).Count
        $tvCount = @($ReleaseData.TV).Count
        $movieWord = if ($movieCount -eq 1) { "NEW MOVIE" } else { "NEW MOVIES" }
        $tvWord = if ($tvCount -eq 1) { "TV TITLE" } else { "TV TITLES" }
        $countLine = "$movieCount $movieWord • $tvCount $tvWord"
    }

    return [PSCustomObject]@{
        Movies            = $movies
        TV                = $tv
        CountLine         = $countLine
        SectionLabel      = $movieSectionLabel
        MovieSectionLabel = $movieSectionLabel
        TvSectionLabel    = $tvSectionLabel
        TrendingHeroMode  = $trendingHeroMode
    }
}

function Build-NewsletterHtml {
    param(
        [object]$User,
        [object]$Stats,
        [object]$ReleaseData,
        [object]$HotRelease,
        [string]$TrendingTitle,
        [AllowNull()][object]$TopMovieGenre = $null,
        [bool]$SystemWarmingUp,
        [bool]$RecentAccess,
        [AllowNull()][object]$RecipientWatchedMovies = $null,
        [bool]$WelcomeOnly = $false,
        [bool]$QuietReleaseMode = $false,
        [object]$BingeChampion = $null,
        [AllowNull()][object]$RecipientPlatform = $null,
        [object[]]$PosterAssets,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode,
        [string]$StartLabel,
        [string]$EndLabel
    )

    $releaseDisplay = Get-NewsletterReleaseDisplayData -ReleaseData $ReleaseData -HotRelease $HotRelease -QuietReleaseMode $QuietReleaseMode
    $movies = @($releaseDisplay.Movies)
    $tv = @($releaseDisplay.TV)
    $movieReleaseSectionLabel = HtmlEncode ([string]$releaseDisplay.MovieSectionLabel)
    $tvReleaseSectionLabel = HtmlEncode ([string]$releaseDisplay.TvSectionLabel)
    $previewAssetBase = "assets"
    $trendingHeroMode = [bool]$releaseDisplay.TrendingHeroMode
    $footerServerName = Get-ConfiguredServerName
    $deliveryDay = Get-ConfiguredDeliveryDay

    $movieCards = Get-ReleaseCardsHtml -Items $movies -PosterAssets $PosterAssets -ImageMode $ImageMode -RecipientWatchedMovies $RecipientWatchedMovies -PreviewAssetBase $previewAssetBase -Kind "Movie"
    $tvCards = Get-ReleaseCardsHtml -Items $tv -PosterAssets $PosterAssets -ImageMode $ImageMode -RecipientWatchedMovies $RecipientWatchedMovies -PreviewAssetBase $previewAssetBase -Kind "TV"

    $friendly = HtmlEncode $User.FriendlyName
    $moviesWatched = HtmlEncode $Stats.MoviesWatched
    $episodesStreamed = HtmlEncode $Stats.EpisodesStreamed
    $timeText = HtmlEncode $Stats.TotalTimeText

    $releaseCountLine = [string]$releaseDisplay.CountLine

    $headerIntro = if ($WelcomeOnly) {
        "Welcome to $(HtmlEncode $footerServerName) — you're all set. Here's what's new and what to expect from your $deliveryDay drops."
    }
    elseif ($QuietReleaseMode) {
        "Your $deliveryDay Plex drop is here — this week’s server favorites, latest library additions, and your private weekly recap."
    }
    else {
        "Your $deliveryDay Plex drop is here — fresh releases plus your private weekly recap."
    }

    $preheader = if ($QuietReleaseMode) {
        $releaseCountLine
    }
    else {
        Get-DynamicPreheader -ReleaseData $ReleaseData
    }

    $preheaderPadding = if ([string]::IsNullOrWhiteSpace($preheader)) {
        ""
    }
    else {
        ("&zwnj;&nbsp;" * 28)
    }

    $customTextCardTable = Get-CustomTextCardTableHtml -ImageMode $ImageMode
    $headerCustomTextCardBlock = ""
    $welcomeCustomTextCardBlock = ""
    if (-not [string]::IsNullOrWhiteSpace($customTextCardTable)) {
        if ($WelcomeOnly -or $RecentAccess) {
            $welcomeCustomTextCardBlock = @"
<tr>
<td class="pad" style="padding:0 20px 18px;">
  $customTextCardTable
</td>
</tr>
"@
        }
        else {
            $headerCustomTextCardBlock = @"
  <div style="padding-top:18px;">
    $customTextCardTable
  </div>
"@
        }
    }
    $headerReleaseMetaTopPadding = if ([string]::IsNullOrWhiteSpace($headerCustomTextCardBlock)) { "10px" } else { "18px" }


    $headerReleaseMetaBlock = if ($WelcomeOnly -or $RecentAccess) {
        ""
    }
    else {
        @"
  <div style="padding-top:$headerReleaseMetaTopPadding;font-size:12px;color:#e5a00d;font-weight:800;letter-spacing:0.8px;">$(HtmlEncode $releaseCountLine)</div>
  <div style="padding-top:6px;font-size:12px;color:#666666;">$(HtmlEncode $StartLabel) – $(HtmlEncode $EndLabel)</div>
"@
    }

    $welcomeReleaseMetaBlock = if ($WelcomeOnly -or $RecentAccess) {
        @"
<tr>
<td class="pad" style="padding:0 20px 18px;">
  <div style="font-size:12px;color:#e5a00d;font-weight:800;letter-spacing:0.8px;">$(HtmlEncode $releaseCountLine)</div>
  <div style="padding-top:6px;font-size:12px;color:#666666;">$(HtmlEncode $StartLabel) – $(HtmlEncode $EndLabel)</div>
</td>
</tr>
"@
    }
    else {
        ""
    }

    $movieReleaseSection = ""
    if ($movies.Count -gt 0) {
        $movieReleaseSection = @"
<tr>
<td class="pad" style="padding:0 20px 10px;">
  <div style="font-size:12px;color:#e5a00d;font-weight:800;letter-spacing:1.4px;">$movieReleaseSectionLabel</div>
  <div style="padding-top:3px;font-size:24px;color:#ffffff;font-weight:800;">Movies</div>
</td>
</tr>
<tr>
<td class="pad" style="padding:0 14px 8px;">
<table width="100%" cellspacing="0" cellpadding="0" border="0">
$movieCards
</table>
</td>
</tr>
"@
    }

    $tvReleaseSection = ""
    if ($tv.Count -gt 0) {
        $tvTopPadding = if ($movies.Count -gt 0) { "8px" } else { "0" }
        $tvHeadingPrefix = if ($trendingHeroMode -or $movies.Count -eq 0) {
            '<div style="font-size:12px;color:#e5a00d;font-weight:800;letter-spacing:1.4px;">' + $tvReleaseSectionLabel + '</div>'
        }
        else { "" }

        $tvReleaseSection = @"
<tr>
<td class="pad" style="padding:$tvTopPadding 20px 10px;">
  $tvHeadingPrefix
  <div style="padding-top:3px;font-size:24px;color:#ffffff;font-weight:800;">TV</div>
</td>
</tr>
<tr>
<td class="pad" style="padding:0 14px 14px;">
<table width="100%" cellspacing="0" cellpadding="0" border="0">
$tvCards
</table>
</td>
</tr>
"@
    }

    $newReleasesBlock = $movieReleaseSection + $tvReleaseSection

    $mostWatched = if ([string]::IsNullOrWhiteSpace([string]$Stats.MostWatched)) {
        "Nothing yet"
    } else {
        HtmlEncode (Truncate-Text $Stats.MostWatched 48)
    }

    $plexUrl = Get-ConfiguredPlexWebUrl
    $plexButtonLabel = Get-ConfiguredPlexButtonLabel

    $serverLabel = if ($null -ne $Config.PSObject.Properties["ServerLabel"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.ServerLabel)) {
        [string]$Config.ServerLabel
    } else {
        "PLEX"
    }

    $moviesIconSrc = if ($ImageMode -eq "Email") { "cid:icon_movies" } else { "assets/movies.gif" }
    $tvIconSrc = if ($ImageMode -eq "Email") { "cid:icon_tv" } else { "assets/tv.gif" }
    $clockIconSrc = if ($ImageMode -eq "Email") { "cid:icon_clock" } else { "assets/clock.gif" }
    $trophyIconSrc = if ($ImageMode -eq "Email") { "cid:icon_trophy" } else { "assets/trophy.gif" }
    $hotIconSrc = if ($ImageMode -eq "Email") { "cid:icon_hot" } else { "assets/hot.gif" }
    $trendingIconSrc = if ($ImageMode -eq "Email") { "cid:icon_trending" } else { "assets/trending.gif" }
    $pendingIconSrc = if ($ImageMode -eq "Email") { "cid:icon_pending" } else { "assets/pending.gif" }
    $quietIconSrc = if ($ImageMode -eq "Email") { "cid:icon_quiet" } else { "assets/quiet.gif" }
    $welcomeIconSrc = if ($ImageMode -eq "Email") { "cid:icon_welcome" } else { "assets/welcome.gif" }
    $actionIconSrc = if ($ImageMode -eq "Email") { "cid:icon_action" } else { "assets/action.gif" }
    $watchedIconSrc = if ($ImageMode -eq "Email") { "cid:icon_watched" } else { "assets/watched.gif" }
    $lockInfoIconSrc = if ($ImageMode -eq "Email") { "cid:icon_lockinfo" } else { "assets/lockinfo.gif" }
    $bingeIconSrc = if ($ImageMode -eq "Email") { "cid:icon_binge" } else { "assets/watchlist.gif" }
    $popcornIconSrc = if ($ImageMode -eq "Email") { "cid:icon_popcorn" } else { "assets/popcorn.gif" }
    $imdbIconSrc = if ($ImageMode -eq "Email") { "cid:icon_imdb" } else { "assets/imdb.png" }
    $summarySupportingStyle = 'padding-top:3px;font-size:12px;line-height:1.35;font-weight:400;color:#8e8e8e;'

    # Recently accepted access: special welcome banner.
    $welcomeBlock = ""
    if ($RecentAccess) {
        $welcomeDescription = if ($WelcomeOnly) {
            "Your access to $(HtmlEncode $footerServerName) is live. Grab the remote — you’re cleared for departure."
        }
        elseif ($QuietReleaseMode) {
            "Your access to $(HtmlEncode $footerServerName) is live. This is your first $deliveryDay drop — what’s trending and the latest library additions are below, and your private watch readout will come online as you stream."
        }
        else {
            "Your access to $(HtmlEncode $footerServerName) is live. This is your first $deliveryDay drop — new releases are below, and your private watch readout will come online as you stream."
        }

        $welcomeBlock = @"
<tr>
<td class="pad" style="padding:4px 20px 26px;">
  <table class="email-card" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#181818" style="background-color:#181818;border:1px solid #e5a00d;border-radius:10px;border-collapse:separate;">
    <tr>
      <td valign="middle" style="padding:20px 22px;">
        <div style="font-size:11px;color:#e5a00d;font-weight:800;letter-spacing:1.4px;">
          <span style="display:inline-block;vertical-align:middle;">WELCOME ABOARD</span>
          <img src="$welcomeIconSrc" width="18" height="18" alt="Welcome aboard" style="display:inline-block;width:18px;height:18px;border:0;vertical-align:-4px;margin-left:6px;">
        </div>
        <div style="padding-top:7px;font-size:22px;line-height:1.2;color:#ffffff;font-weight:800;">Access granted, $friendly.</div>
        <div style="padding-top:7px;font-size:13px;line-height:1.5;color:#9b9b9b;">$welcomeDescription</div>
      </td>
    </tr>
  </table>
</td>
</tr>
"@
    }

    # HOT NEW RELEASE hero.
    # Regular Friday newsletters use the same gold accent border as the
    # Welcome Aboard panel. Welcome-related emails keep the original gray border.
    $hotBorderColor = if (-not $WelcomeOnly -and -not $RecentAccess) {
        "#e5a00d"
    }
    else {
        "#2b2b2b"
    }

    $heroLabel = if ($trendingHeroMode) { "TRENDING THIS WEEK" } else { "HOT NEW RELEASE" }
    $heroIconSrc = if ($trendingHeroMode) { $popcornIconSrc } else { $hotIconSrc }
    $heroIconAlt = if ($trendingHeroMode) { "Trending this week" } else { "Hot new release" }

    $hotBlock = ""
    if ($null -ne $HotRelease -and $null -ne $HotRelease.Item) {
        $hotItem = $HotRelease.Item
        $hotTitle = HtmlEncode $hotItem.Title
        $hotTitleWithStatus = Get-RecipientWatchedTitleHtml -EncodedTitle $hotTitle -Item $hotItem -RecipientWatchedMovies $RecipientWatchedMovies -ImageMode $ImageMode -PreviewAssetBase $previewAssetBase
        $hotPosterSrc = Get-ImageSource -RatingKey ([string]$hotItem.PosterRatingKey) -PosterAssets $PosterAssets -ImageMode $ImageMode

        $hotPosterHtml = Get-RecipientWatchedDesktopHeroPosterHtml -Item $hotItem -RecipientWatchedMovies $RecipientWatchedMovies -ImageMode $ImageMode -PreviewAssetBase $previewAssetBase -PosterSource $hotPosterSrc -PosterAlt ($hotItem.Title + ' poster')
        $hotPosterTopPadding = if (-not [string]::IsNullOrWhiteSpace($hotPosterSrc) -and (Test-RecipientHasWatchedMovie -Item $hotItem -RecipientWatchedMovies $RecipientWatchedMovies)) { 11 } else { 16 }

        $hotMeta = Get-DesignRatingLine -Item $hotItem -ImageMode $ImageMode
        if ([string]$hotItem.Type -eq "show" -and $hotItem.EpisodeCount -gt 0) {
            $epText = if ($hotItem.EpisodeCount -eq 1) { "1 new episode" } else { "$($hotItem.EpisodeCount) new episodes" }
            if ([string]::IsNullOrWhiteSpace($hotMeta)) {
                $hotMeta = $epText
            }
            else {
                $hotMeta = $hotMeta + "  " + $epText
            }
        }
        # Genre is displayed globally for movie heroes: desktop clearLogo,
        # desktop text-title fallback, and mobile text-title layout.
        $hotGenreText = ""
        $hotGenreDesktopHtml = ""
        $hotGenreMobileHtml = ""
        $hotMetaDesktopTop = 8
        $hotMetaMobileTop = 7

        if ([string]$hotItem.Type -eq "movie") {
            $hotGenreText = Get-DesignGenreLine -Item $hotItem

            if (-not [string]::IsNullOrWhiteSpace($hotGenreText)) {
                $encodedHotGenre = HtmlEncode $hotGenreText

                $hotGenreDesktopHtml = '<div style="padding-top:4px;color:#969696;font-size:13px;font-weight:500;line-height:1.35;">' +
                    $encodedHotGenre +
                    '</div>'

                $hotGenreMobileHtml = '<div style="padding-top:4px;color:#969696;font-size:13px;font-weight:500;line-height:1.35;text-align:left;">' +
                    $encodedHotGenre +
                    '</div>'

                $hotMetaDesktopTop = 11
                $hotMetaMobileTop = 11
            }
        }

        # For movies, Get-DesignRatingLine returns safe HTML. Do not encode it.
        # TV episode text is constructed internally and contains no user HTML.

        # Match the New Releases movie-card summary treatment.
        $hotSummary = Truncate-Text ([string]$hotItem.Summary) 150
        $hotSummaryText = if ([string]::IsNullOrWhiteSpace($hotSummary)) {
            "&nbsp;"
        }
        else {
            HtmlEncode $hotSummary
        }

        $playCount = Safe-Int $HotRelease.Plays
        $playWord = if ($playCount -eq 1) { "play" } else { "plays" }

        $hotStatus = if ($trendingHeroMode) {
            "Most watched across $footerServerName this week • $playCount $playWord"
        }
        elseif ($HotRelease.IsPopular) {
            "Most-watched new release across $footerServerName this week • $playCount $playWord"
        }
        else {
            "Freshly added!"
        }

        $designBannerHtml = ""
        $designBannerSrc = ""
        if ($null -ne $designHero -and -not [string]::IsNullOrWhiteSpace([string]$designHero.BannerSrc)) {
            $designBannerSrc = if ($ImageMode -eq "Email") { "cid:hero_banner" } else { [string]$designHero.BannerSrc }
            $designBannerHtml = '<img class="design-mobile-banner" src="' + (HtmlEncode $designBannerSrc) + '" alt="' + $hotTitle + ' banner" style="display:block;width:100%;height:160px;object-fit:cover;border:0;">'
        }

        $designHasLogo = (
            $null -ne $designHero -and
            -not [string]::IsNullOrWhiteSpace([string]$designHero.LogoSrc)
        )

        # Production email intentionally embeds only PNG clearLogos. SVG and
        # WebP support is inconsistent across email clients, so any other logo
        # format falls back to the normal text title. Browser previews may still
        # display formats the browser supports.
        if ($designHasLogo -and $ImageMode -eq "Email" -and
            [IO.Path]::GetExtension([string]$designHero.LogoSrc).ToLowerInvariant() -ne ".png") {
            $designHasLogo = $false
        }

        if ($designHasLogo) {
            $designLogoSrc = if ($ImageMode -eq "Email") { "cid:hero_logo" } else { [string]$designHero.LogoSrc }
            $designDesktopIdentityHtml = @"
<div class="design-desktop-logo-wrap" style="padding-top:8px;">
  <img class="design-desktop-logo" src="$(HtmlEncode $designLogoSrc)" alt="$hotTitle logo" style="display:block;max-width:280px;max-height:96px;width:auto;height:auto;border:0;">
</div>
"@

            # Mobile banner no longer renders the clearlogo overlay.
            $designMobileLogoOverlayHtml = ""
        }
        else {
            $designDesktopIdentityHtml = '<div style="padding-top:5px;font-size:23px;line-height:1.2;color:#ffffff;font-weight:800;">' + $hotTitle + '</div>'
            $designMobileLogoOverlayHtml = ""
        }

        $hotBlock = @"
<tr class="design-hot-desktop">
<td class="pad" style="padding:4px 20px 26px;">
  <table class="email-card" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#181818" style="background-color:#181818;border:1px solid $hotBorderColor;border-radius:10px;border-collapse:separate;">
    <tr>
      <td width="205" valign="top" style="padding:${hotPosterTopPadding}px 0 16px 16px;">
        $hotPosterHtml
      </td>
      <td valign="top" style="padding:16px 20px;">
        <table width="100%" height="270" cellspacing="0" cellpadding="0" border="0" style="width:100%;height:270px;">
          <tr>
            <td valign="top">
              <img src="$heroIconSrc" width="42" height="42" alt="$(HtmlEncode $heroIconAlt)" style="display:block;width:42px;height:42px;border:0;">
              <div style="padding-top:8px;font-size:11px;color:#e5a00d;font-weight:800;letter-spacing:1.3px;">$heroLabel</div>
              $designDesktopIdentityHtml
              $hotGenreDesktopHtml
              <div style="padding-top:${hotMetaDesktopTop}px;font-size:12px;color:#e5a00d;font-weight:700;">$hotMeta</div>
              <div style="padding-top:10px;font-size:13px;line-height:1.45;color:#969696;">$hotSummaryText</div>
            </td>
          </tr>
          <tr>
            <td valign="bottom" style="padding-top:12px;font-size:12px;line-height:1.4;color:#e5a00d;">
              $(HtmlEncode $hotStatus)
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</td>
</tr>
<tr class="design-hot-mobile" style="display:none;">
<td class="pad" style="padding:4px 12px 15px;">
  <table cellspacing="0" cellpadding="0" border="0">
    <tr>
      <td valign="middle" style="padding-right:9px;">
        <img src="$heroIconSrc" width="34" height="34" alt="$(HtmlEncode $heroIconAlt)" style="display:block;width:34px;height:34px;border:0;">
      </td>
      <td valign="middle" style="font-size:11px;line-height:34px;color:#e5a00d;font-weight:800;letter-spacing:1.3px;white-space:nowrap;">
        $heroLabel
      </td>
    </tr>
  </table>
</td>
</tr>

<tr class="design-hot-mobile" style="display:none;">
<td class="pad" style="padding:0 12px 26px;">
  <table class="email-card" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#181818" style="background-color:#181818;border:1px solid $hotBorderColor;border-radius:10px;border-collapse:separate;overflow:hidden;">
    <tr>
      <td style="padding:0;">
        <div class="design-mobile-banner-wrap" style="position:relative;overflow:hidden;">
          $designBannerHtml
          $designMobileLogoOverlayHtml
        </div>
      </td>
    </tr>
    <tr>
      <td style="padding:16px 18px 20px;">
        <div style="font-size:23px;line-height:1.2;color:#ffffff;font-weight:800;text-align:left;">$hotTitleWithStatus</div>
        $hotGenreMobileHtml
        <div style="padding-top:${hotMetaMobileTop}px;font-size:12px;color:#e5a00d;font-weight:700;">$hotMeta</div>
        <div style="padding-top:14px;font-size:13px;line-height:1.5;color:#969696;">$hotSummaryText</div>
        <div style="padding-top:22px;font-size:12px;line-height:1.4;color:#e5a00d;">$(HtmlEncode $hotStatus)</div>
      </td>
    </tr>
  </table>
</td>
</tr>
"@
    }

    # Server-wide Trending appears once:
    # - normal release weeks: compact poster card below the weekly content
    # - quiet release weeks: Trending is already the featured hero
    $trendingBlock = ""

    if (-not $trendingHeroMode -and
        -not [string]::IsNullOrWhiteSpace($TrendingTitle) -and
        $null -ne $script:GlobalTrendingStat) {
        $trendingDisplay = ""
        $trendingDescription = ""
        $trendingPosterHtml = ""

        $trendingDisplay = HtmlEncode (Truncate-Text $TrendingTitle 70)
        $trendingPlays = Safe-Int $script:GlobalTrendingStat.Plays
        $trendingRatingKey = [string]$script:GlobalTrendingStat.RatingKey
        $trendingPosterSrc = Get-ImageSource `
            -RatingKey $trendingRatingKey `
            -PosterAssets $PosterAssets `
            -ImageMode $ImageMode

        if (-not [string]::IsNullOrWhiteSpace($trendingPosterSrc)) {
            $trendingPosterHtml = '<img src="' + (HtmlEncode $trendingPosterSrc) + '" width="58" height="86" alt="' + $trendingDisplay + ' poster" style="display:block;width:58px;height:86px;object-fit:cover;border:1px solid #383838;border-radius:6px;">'
        }

        $playWord = if ($trendingPlays -eq 1) { "play" } else { "plays" }
        $trendingDescription = if ($trendingPlays -gt 0) {
            "Most watched across $footerServerName this week • $trendingPlays $playWord"
        } else {
            "Most watched across $footerServerName this week"
        }

        $posterCell = if ([string]::IsNullOrWhiteSpace($trendingPosterHtml)) {
            ""
        } else {
            '<td width="70" valign="middle" style="padding:12px 0 12px 12px;">' + $trendingPosterHtml + '</td>'
        }

        $trendingBlock = @"
<tr>
<td class="pad" style="padding:0 20px 26px;">
  <table class="email-card" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#181818" style="background-color:#181818;border:1px solid #2b2b2b;border-radius:10px;border-collapse:separate;">
    <tr>
      $posterCell
      <td width="56" valign="middle" style="padding:16px 0 16px 14px;">
        <img src="$trendingIconSrc" width="42" height="42" alt="Trending this week" style="display:block;width:42px;height:42px;border:0;">
      </td>
      <td valign="middle" style="padding:16px 18px 16px 10px;">
        <div style="font-size:12px;color:#e5a00d;font-weight:900;letter-spacing:1.1px;">TRENDING THIS WEEK</div>
        <div style="padding-top:5px;font-size:27px;line-height:1.1;color:#ffffff;font-weight:800;overflow-wrap:anywhere;word-break:break-word;">$trendingDisplay</div>
        <div style="padding-top:4px;font-size:12px;line-height:1.35;font-weight:400;color:#8e8e8e;">$(HtmlEncode $trendingDescription)</div>
      </td>
    </tr>
  </table>
</td>
</tr>
"@
    }

    # A Trending hero already occupies the primary server-wide title slot, so
    # its complementary footer reports the server-wide qualified movie genre.
    $topGenreBlock = ""
    if ($trendingHeroMode) {
        $topGenreName = 'No qualifying genre yet'
        $topGenreDescription = 'No qualifying movie activity with genre metadata this week'
        $topGenreFileName = 'movies.gif'
        $topGenreCid = 'icon_movies'
        if ($null -ne $TopMovieGenre) {
            $candidateName = Get-OptionalStringProperty -InputObject $TopMovieGenre -Name 'Genre'
            $candidateDescription = Get-OptionalStringProperty -InputObject $TopMovieGenre -Name 'SupportingText'
            $candidateFileName = Get-OptionalStringProperty -InputObject $TopMovieGenre -Name 'AssetFileName'
            $candidateCid = Get-OptionalStringProperty -InputObject $TopMovieGenre -Name 'AssetCid'
            if (-not [string]::IsNullOrWhiteSpace($candidateName)) { $topGenreName = $candidateName }
            if (-not [string]::IsNullOrWhiteSpace($candidateDescription)) { $topGenreDescription = $candidateDescription }
            if (-not [string]::IsNullOrWhiteSpace($candidateFileName) -and
                -not [string]::IsNullOrWhiteSpace($candidateCid) -and
                (Test-Path -LiteralPath (Join-Path $AssetsDir $candidateFileName) -PathType Leaf)) {
                $topGenreFileName = $candidateFileName
                $topGenreCid = $candidateCid
            }
        }
        $topGenrePreviewBase = if ($moviesIconSrc -like '../assets/*') { '../assets' } else { 'assets' }
        $topGenreIconSrc = if ($ImageMode -eq 'Email') { 'cid:' + $topGenreCid } else { $topGenrePreviewBase + '/' + $topGenreFileName }

        $topGenreBlock = @"
<tr>
<td class="pad" style="padding:0 20px 26px;">
  <table class="email-card" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#181818" style="background-color:#181818;border:1px solid #2b2b2b;border-radius:10px;border-collapse:separate;">
    <tr>
      <td width="70" valign="middle" style="padding:16px 0 16px 20px;">
        <img src="$(HtmlEncode $topGenreIconSrc)" width="42" height="42" alt="Top genre this week" style="display:block;width:42px;height:42px;border:0;">
      </td>
      <td valign="middle" style="padding:16px 18px 16px 10px;">
        <div style="font-size:12px;color:#e5a00d;font-weight:900;letter-spacing:1.1px;">TOP GENRE THIS WEEK</div>
        <div style="padding-top:5px;font-size:27px;line-height:1.1;color:#ffffff;font-weight:800;">$(HtmlEncode $topGenreName)</div>
        <div style="$summarySupportingStyle">$(HtmlEncode $topGenreDescription)</div>
      </td>
    </tr>
  </table>
</td>
</tr>
"@
    }
    $footerFeatureBlock = if ($trendingHeroMode) { $topGenreBlock } else { $trendingBlock }
    # Binge Champion ranks users by qualifying watch time. Every recipient sees
    # the same anonymous watch time, play/title counts, and cumulative episode
    # count. Only the winner receives the gold YOU WON treatment.
    $bingeDisplay = Get-BingeChampionDisplay -BingeChampion $BingeChampion -User $User
    $bingeTimeLine = "Awaiting the first qualifying stream"
    $bingeTitleBreakdown = ""
    $isBingeWinner = [bool]$bingeDisplay.IsWinner

    if ($bingeDisplay.Available) {
        $bingeTimeLine = "$([string]$bingeDisplay.TotalTimeText) watched"
        $bingeTitleBreakdown = Get-BingeChampionTitleBreakdown -BingeDisplay $bingeDisplay
    }

    $bingeBreakdownHtml = ""
    if (-not [string]::IsNullOrWhiteSpace($bingeTitleBreakdown)) {
        $encodedBingeBreakdown = HtmlEncode $bingeTitleBreakdown
        $bingeBreakdownHtml = "<div style=`"$summarySupportingStyle`">$encodedBingeBreakdown</div>"
    }

    $bingeBorder = if ($isBingeWinner) { "#e5a00d" } else { "#2b2b2b" }
    $bingeBackground = if ($isBingeWinner) { "#211a0d" } else { "#181818" }
    $bingeEyebrow = if ($isBingeWinner) { "YOU WON • BINGE CHAMPION" } else { "THIS WEEK'S BINGE CHAMPION" }

    # Do not assign these collections through an `if` expression.
    # Windows PowerShell 5.1 can unwrap a one-item result into a scalar, and
    # strict mode then rejects `.Count`. Initialize and assign the arrays
    # explicitly so zero, one, and many items all retain collection semantics.
    $movieItems = @()
    $movieTitleCount = 0
    if ($null -ne $Stats.PSObject.Properties["MovieItems"]) {
        $movieTitleCount = @($Stats.MovieItems).Count
        $movieItems = @($Stats.MovieItems)
    }

    $tvShowItems = @()
    $tvShowTitleCount = 0
    if ($null -ne $Stats.PSObject.Properties["TvShowItems"]) {
        $tvShowTitleCount = @($Stats.TvShowItems).Count
        $tvShowItems = @($Stats.TvShowItems)
    }
    $movieDetailMode = ($movieItems.Count -gt 0)
    $tvShowDetailMode = ($tvShowItems.Count -gt 0)

    $movieRows = if ($movieDetailMode) {
        Get-StatsMovieRowsHtml `
            -Items $movieItems `
            -PosterAssets $PosterAssets `
            -ImageMode $ImageMode
    } else { "" }

    $tvShowRows = if ($tvShowDetailMode) {
        Get-StatsTvShowRowsHtml `
            -Items $tvShowItems `
            -PosterAssets $PosterAssets `
            -ImageMode $ImageMode
    } else { "" }

    $summaryCardHeight = 178

    $movieCardContent = if ($movieDetailMode) {
        @"
<table width="100%" cellspacing="0" cellpadding="0" border="0">
  <tr>
    <td style="padding-bottom:7px;border-bottom:1px solid #292929;">
      <table cellspacing="0" cellpadding="0" border="0">
        <tr>
          <td valign="middle" style="padding-right:8px;"><img src="$moviesIconSrc" width="42" height="42" alt="Movies watched" style="display:block;width:42px;height:42px;border:0;"></td>
          <td valign="middle"><div style="font-size:18px;font-weight:800;color:#ffffff;line-height:1;">$movieTitleCount</div><div style="padding-top:3px;font-size:12px;color:#8e8e8e;letter-spacing:.6px;">MOVIES WATCHED</div></td>
        </tr>
      </table>
    </td>
  </tr>
  $movieRows
</table>
"@
    } else { "" }

    $tvShowCardContent = if ($tvShowDetailMode) {
        @"
<table width="100%" cellspacing="0" cellpadding="0" border="0">
  <tr>
    <td style="padding-bottom:7px;border-bottom:1px solid #292929;">
      <table cellspacing="0" cellpadding="0" border="0">
        <tr>
          <td valign="middle" style="padding-right:8px;"><img src="$tvIconSrc" width="42" height="42" alt="TV shows watched" style="display:block;width:42px;height:42px;border:0;"></td>
          <td valign="middle"><div style="font-size:18px;font-weight:800;color:#ffffff;line-height:1;">$tvShowTitleCount</div><div style="padding-top:3px;font-size:12px;color:#8e8e8e;letter-spacing:.6px;margin-bottom:-7px;">TV SHOWS WATCHED</div></td>
        </tr>
      </table>
    </td>
  </tr>
  $tvShowRows
</table>
"@
    } else { "" }

    $mediaStatsRows = ""
    if ($movieDetailMode) {
        $mediaStatsRows += @"
<tr><td colspan="2" width="100%" valign="top" style="padding:0 0 10px;"><table class="email-card" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#181818" style="width:100%;background-color:#181818;border:1px solid #2b2b2b;border-radius:10px;border-collapse:separate;"><tr><td valign="top" style="padding:14px 16px;">$movieCardContent</td></tr></table></td></tr>
"@
    }
    if ($tvShowDetailMode) {
        $mediaStatsRows += @"
<tr><td colspan="2" width="100%" valign="top" style="padding:0 0 10px;"><table class="email-card" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#181818" style="width:100%;background-color:#181818;border:1px solid #2b2b2b;border-radius:10px;border-collapse:separate;"><tr><td valign="top" style="padding:14px 16px;">$tvShowCardContent</td></tr></table></td></tr>
"@
    }

    $statsBlock = ""
    $bingeStandaloneBlock = ""

    if ([int64]$Stats.TotalSeconds -le 0) {
        if ($SystemWarmingUp) {
            $zeroEyebrow = "STATS ARE WARMING UP"
            $zeroHeadline = "The sensors are online."
            $zeroDescription = "Your weekly watch recap will begin filling in as you stream. Check back next Friday for the full readout."
            $zeroAlt = "Stats warming up"
            $zeroIconSrc = $pendingIconSrc
        }
        else {
            $zeroEyebrow = "QUIET IN THIS SECTOR"
            $zeroHeadline = "No watch activity this week."
            $zeroDescription = "Warp Core still engaging. Your recap will be ready when you beam back aboard."
            $zeroAlt = "No watch activity this week"
            $zeroIconSrc = $quietIconSrc
        }

        $statsBlock = @"
<tr>
<td class="pad" style="padding:0 20px 16px;">
  <table class="email-card" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#181818" style="background-color:#181818;border:1px solid #2b2b2b;border-radius:10px;border-collapse:separate;">
    <tr>
      <td width="72" valign="middle" style="padding:20px 0 20px 20px;">
        <img src="$zeroIconSrc" width="48" height="48" alt="$(HtmlEncode $zeroAlt)" style="display:block;width:48px;height:48px;border:0;">
      </td>
      <td valign="middle" style="padding:20px 22px 20px 12px;">
        <div style="font-size:11px;color:#e5a00d;font-weight:800;letter-spacing:1.3px;">$(HtmlEncode $zeroEyebrow)</div>
        <div style="padding-top:6px;font-size:20px;line-height:1.25;color:#ffffff;font-weight:800;">$(HtmlEncode $zeroHeadline)</div>
        <div style="padding-top:6px;font-size:13px;line-height:1.5;color:#969696;">$(HtmlEncode $zeroDescription)</div>
      </td>
    </tr>
  </table>
</td>
</tr>
"@
    }
    else {
        $statsBlock = @"
<tr>
<td class="pad" style="padding:0px 20px 0px;">
<table width="100%" cellspacing="0" cellpadding="0" border="0">
$mediaStatsRows
<tr>
  <td class="stats-summary-cell" width="50%" valign="top" style="width:50%;padding:0 5px 10px 0;">
    <table class="email-card" width="100%" height="$summaryCardHeight" cellspacing="0" cellpadding="0" border="0" bgcolor="#181818" style="width:100%;height:${summaryCardHeight}px;background-color:#181818;border:1px solid #2b2b2b;border-radius:10px;border-collapse:separate;">
      <tr>
        <td height="$summaryCardHeight" valign="middle" style="height:${summaryCardHeight}px;padding:17px;">
          <div style="font-size:12px;color:#e5a00d;font-weight:900;letter-spacing:1.1px;">YOU CLOCKED</div>
          <img src="$clockIconSrc" width="42" height="42" alt="Personal total watch time" style="display:block;width:42px;height:42px;border:0;margin-top:9px;">
          <div style="padding-top:8px;font-size:27px;font-weight:800;color:#ffffff;line-height:1.1;">$timeText</div>
          <div style="$summarySupportingStyle">total watch time</div>
        </td>
      </tr>
    </table>
  </td>
  <td class="stats-summary-cell" width="50%" valign="top" style="width:50%;padding:0 0 10px 5px;">
    <table width="100%" height="$summaryCardHeight" cellspacing="0" cellpadding="0" border="0" bgcolor="$bingeBackground" style="width:100%;height:${summaryCardHeight}px;background-color:$bingeBackground;border:1px solid $bingeBorder;border-radius:10px;border-collapse:separate;">
      <tr>
        <td height="$summaryCardHeight" valign="middle" style="height:${summaryCardHeight}px;padding:17px;">
          <div style="font-size:12px;color:#e5a00d;font-weight:900;letter-spacing:1.1px;">$(HtmlEncode $bingeEyebrow)</div>
          <img src="$trophyIconSrc" width="$(if ($isBingeWinner) { 54 } else { 42 })" height="$(if ($isBingeWinner) { 54 } else { 42 })" alt="Binge Champion award" style="display:block;width:$(if ($isBingeWinner) { 54 } else { 42 })px;height:$(if ($isBingeWinner) { 54 } else { 42 })px;border:0;margin-top:9px;">
          <div style="padding-top:8px;font-size:27px;line-height:1.1;font-weight:800;color:#ffffff;">$(HtmlEncode $bingeTimeLine)</div>
          $bingeBreakdownHtml
        </td>
      </tr>
    </table>
  </td>
</tr>
</table>
</td>
</tr>
"@
    }

    # Award is still globally revealed when the recipient has no personal stats
    # or a first-Friday onboarding state suppresses the personal recap grid.
    if (-not $WelcomeOnly -and [int64]$Stats.TotalSeconds -le 0) {
        $bingeStandaloneBlock = @"
<tr>
<td class="pad" style="padding:0 20px 24px;">
  <table width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="$bingeBackground" style="background-color:$bingeBackground;border:1px solid $bingeBorder;border-radius:10px;border-collapse:separate;">
    <tr>
      <td width="84" valign="middle" style="padding:18px 0 18px 20px;">
        <img src="$trophyIconSrc" width="$(if ($isBingeWinner) { 54 } else { 42 })" height="$(if ($isBingeWinner) { 54 } else { 42 })" alt="Binge Champion award" style="display:block;width:$(if ($isBingeWinner) { 54 } else { 42 })px;height:$(if ($isBingeWinner) { 54 } else { 42 })px;border:0;">
      </td>
      <td valign="middle" style="padding:18px 20px 18px 12px;">
        <div style="font-size:12px;color:#e5a00d;font-weight:900;letter-spacing:1.1px;">$(HtmlEncode $bingeEyebrow)</div>
        <div style="padding-top:5px;font-size:27px;line-height:1.1;color:#ffffff;font-weight:800;">$(HtmlEncode $bingeTimeLine)</div>
        $bingeBreakdownHtml
      </td>
    </tr>
  </table>
</td>
</tr>
"@
    }

    # Suppress empty weekly recap only after statsBlock has been built.
    # One-off welcome: always suppress it.
    # New user's first Friday: suppress it only when they have zero activity.
    # Established users: retain normal quiet/warm-up behavior.
    if ($WelcomeOnly -or ($RecentAccess -and [int64]$Stats.TotalSeconds -le 0)) {
        $statsBlock = ""
    }

    $platformPreviewAssetBase = if ($moviesIconSrc -like "../assets/*") { "../assets" } else { "assets" }
    $platformHeadingHtml = Get-NewsletterPlatformHeadingHtml `
        -Platform $RecipientPlatform `
        -ImageMode $ImageMode `
        -PreviewAssetBase $platformPreviewAssetBase

    $weeklyHeadingBlock = if ($WelcomeOnly -or ($RecentAccess -and [int64]$Stats.TotalSeconds -le 0)) {
        ""
    }
    else {
        @"
<tr>
<td class="pad" style="padding:8px 20px 12px;">
  $platformHeadingHtml
</td>
</tr>
"@
    }

    $welcomeInfoPanelBlock = if ($WelcomeOnly -or $RecentAccess) {
        @"
<tr>
<td class="pad" style="padding:10px 20px 22px;">
  <table class="email-card" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#181818" style="background-color:#181818;border:1px solid #2b2b2b;border-radius:10px;border-collapse:separate;">
    <tr>
      <td style="padding:20px 22px;">
        <div style="font-size:13px;color:#e5a00d;font-weight:800;">
          <img src="$actionIconSrc" width="18" height="18" alt="Weekly Drops" style="display:inline-block;width:18px;height:18px;border:0;vertical-align:-4px;margin-right:6px;">
          <span style="display:inline-block;vertical-align:middle;">$($deliveryDay.ToUpperInvariant()) DROPS</span>
        </div>
        <div style="padding-top:5px;font-size:14px;line-height:1.5;color:#a0a0a0;">Every $deliveryDay morning you’ll get the newest movies and TV additions.</div>

        <div style="padding-top:18px;font-size:13px;color:#e5a00d;font-weight:800;">
          <img src="$watchedIconSrc" width="18" height="18" alt="Your Private Readout" style="display:inline-block;width:18px;height:18px;border:0;vertical-align:-4px;margin-right:6px;">
          <span style="display:inline-block;vertical-align:middle;">YOUR PRIVATE READOUT</span>
        </div>
        <div style="padding-top:5px;font-size:14px;line-height:1.5;color:#a0a0a0;">As you stream, your weekly email builds a private recap with watch time, movies, TV shows, posters, and ratings.</div>

        <div style="padding-top:18px;font-size:13px;color:#e5a00d;font-weight:800;">
          <img src="$lockInfoIconSrc" width="18" height="18" alt="Just Your Stats" style="display:inline-block;width:18px;height:18px;border:0;vertical-align:-4px;margin-right:6px;">
          <span style="display:inline-block;vertical-align:middle;">JUST YOUR STATS</span>
        </div>
        <div style="padding-top:5px;font-size:14px;line-height:1.5;color:#a0a0a0;">Your detailed viewing recap stays in your email. The Binge Champion watch duration, total plays, and nonzero unique movie/TV-show counts are shared server-wide; when more than one episode qualifies, their cumulative count is included. The champion’s identity stays private.</div>
      </td>
    </tr>
  </table>
</td>
</tr>
"@
    }
    else {
        ""
    }

    $footerBlock = if ($WelcomeOnly -or $RecentAccess) {
        ""
    }
    else {
        @"
<tr>
<td class="pad" align="center" style="padding:12px 20px 26px;color:#5f5f5f;font-size:11px;line-height:1.5;">
  Your watch recap is generated privately from $(HtmlEncode $footerServerName) server’s history.<br>
  Other users do not receive your detailed individual viewing stats.<br>
  The Binge Champion watch duration, total plays, and nonzero unique movie/TV-show counts are shared server-wide. A cumulative qualifying episode count is included when greater than one; the champion's identity stays private.
</td>
</tr>
"@
    }

    return @"
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>TautWeekly for Plex</title>
<style>
/* Email-safe table-first layout; only the featured hero swaps at the mobile breakpoint. */
:root { color-scheme:light dark; supported-color-schemes:light dark; }
.email-background { background-color:#0f0f0f !important; color:#ffffff !important; }
.email-card { background-color:#181818 !important; }
.design-hot-mobile { display:none; }
@media (prefers-color-scheme: dark) {
  .email-background { background-color:#0f0f0f !important; color:#ffffff !important; }
  .email-card { background-color:#181818 !important; }
}
@media only screen and (max-width: 620px) {
  .container { width: 100% !important; }
  .pad { padding-left: 12px !important; padding-right: 12px !important; }
  .design-hot-desktop { display:none !important; }
  .design-hot-mobile { display:table-row !important; }
  .design-mobile-banner { width:100% !important; height:150px !important; object-fit:cover !important; }
  .design-mobile-logo { max-width:250px !important; max-height:100px !important; width:auto !important; height:auto !important; }
  .design-mobile-logo-overlay { bottom:10px !important; }
  .stats-title-cell { display:block !important; width:100% !important; padding:7px 0 !important; }
  .stats-title-spacer { display:none !important; }
  .stats-title-cell.stats-tv-title-cell { display:table-cell !important; width:50% !important; }
  .stats-title-cell.stats-tv-title-left { padding:7px 6px 7px 0 !important; }
  .stats-title-cell.stats-tv-title-right { padding:7px 0 7px 6px !important; }
  .stats-title-spacer.stats-tv-title-spacer { display:table-cell !important; width:50% !important; }
  .stats-summary-cell { display:block !important; width:100% !important; padding:0 0 10px !important; }
}
</style>
</head>
<body class="email-background" bgcolor="#0f0f0f" style="margin:0;padding:0;background-color:#0f0f0f;color:#ffffff;font-family:Arial,Helvetica,sans-serif;">
<div style="display:none!important;font-size:1px;line-height:1px;max-height:0;max-width:0;overflow:hidden;opacity:0;color:transparent;mso-hide:all;">$(HtmlEncode $preheader)$preheaderPadding</div>
<table class="email-background" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#0f0f0f" style="background-color:#0f0f0f;">
<tr>
<td class="email-background" align="center" bgcolor="#0f0f0f" style="padding:28px 10px;background-color:#0f0f0f;">
<table class="container email-background" width="640" cellspacing="0" cellpadding="0" border="0" bgcolor="#0f0f0f" style="width:640px;max-width:640px;background-color:#0f0f0f;">
<tr>
<td class="pad" style="padding:0 20px 18px;">
  <div style="font-size:13px;font-weight:800;letter-spacing:2px;color:#e5a00d;">$(HtmlEncode $serverLabel)</div>
  <div style="padding-top:8px;font-size:30px;line-height:1.15;font-weight:800;color:#ffffff;">Hey $friendly,</div>
  <div style="padding-top:8px;font-size:15px;line-height:1.55;color:#a9a9a9;">$headerIntro</div>
$headerCustomTextCardBlock
$headerReleaseMetaBlock
</td>
</tr>

$welcomeBlock

$welcomeCustomTextCardBlock

$welcomeReleaseMetaBlock

$hotBlock

$newReleasesBlock

$weeklyHeadingBlock

$statsBlock

$welcomeInfoPanelBlock

$bingeStandaloneBlock

$footerFeatureBlock

<tr>
<td class="pad" align="center" style="padding:8px 20px 18px;">
  <a href="$(HtmlEncode $plexUrl)" style="display:inline-block;background-color:#e5a00d;color:#111111;text-decoration:none;font-size:14px;font-weight:800;padding:13px 24px;border-radius:7px;">$(HtmlEncode $plexButtonLabel)</a>
</td>
</tr>

$footerBlock
</table>
</td>
</tr>
</table>
</body>
</html>
"@
}

function Build-PlainText {
    param(
        [object]$User,
        [object]$Stats,
        [object]$ReleaseData,
        [object]$HotRelease,
        [string]$TrendingTitle,
        [AllowNull()][object]$TopMovieGenre = $null,
        [bool]$SystemWarmingUp,
        [bool]$RecentAccess,
        [bool]$QuietReleaseMode = $false,
        [AllowNull()][object]$RecipientWatchedMovies = $null,
        [object]$BingeChampion = $null,
        [bool]$WelcomeOnly = $false,
        [string]$StartLabel,
        [string]$EndLabel
    )

    $serverName = Get-ConfiguredServerName
    $deliveryDay = Get-ConfiguredDeliveryDay
    $plexWebUrl = Get-ConfiguredPlexWebUrl
    $plexButtonLabel = Get-ConfiguredPlexButtonLabel
    $customTextCardBlock = Get-CustomTextCardPlainText

    $releaseDisplay = Get-NewsletterReleaseDisplayData -ReleaseData $ReleaseData -HotRelease $HotRelease -QuietReleaseMode $QuietReleaseMode

    $plainPreheader = if ($QuietReleaseMode) {
        [string]$releaseDisplay.CountLine
    }
    else {
        Get-DynamicPreheader -ReleaseData $ReleaseData
    }

    $plainPreheaderBlock = if ([string]::IsNullOrWhiteSpace($plainPreheader)) {
        ""
    }
    else {
        $plainPreheader + "`r`n`r`n"
    }

    $releaseMetaText = [string]$releaseDisplay.CountLine + [Environment]::NewLine + "$StartLabel – $EndLabel"

    $heroLine = ""
    $plainTrendingHero = $false
    if ($null -ne $HotRelease -and $null -ne $HotRelease.Item) {
        $plainTrendingHero = (
            $null -ne $HotRelease.PSObject.Properties["IsTrending"] -and
            [bool]$HotRelease.IsTrending
        )
        $heroLabel = if ($plainTrendingHero) { "TRENDING THIS WEEK" } else { "HOT NEW RELEASE" }
        $heroWatchedSuffix = Get-RecipientWatchedPlainTextSuffix -Item $HotRelease.Item -RecipientWatchedMovies $RecipientWatchedMovies
        $heroLine = "`r`n${heroLabel}: $($HotRelease.Item.Title)$heroWatchedSuffix"
    }

    $footerFeature = ""

    if (-not $plainTrendingHero -and
        -not [string]::IsNullOrWhiteSpace($TrendingTitle) -and
        $null -ne $script:GlobalTrendingStat) {
        $trendPlays = Safe-Int $script:GlobalTrendingStat.Plays
        $trendPlayWord = if ($trendPlays -eq 1) { "play" } else { "plays" }
        $footerFeature += if ($trendPlays -gt 0) {
            "`r`nTRENDING THIS WEEK: $TrendingTitle — $trendPlays $trendPlayWord across the server"
        } else {
            "`r`nTRENDING THIS WEEK: $TrendingTitle"
        }
    }

    if ($plainTrendingHero) {
        $topGenreName = if ($null -ne $TopMovieGenre) {
            Get-OptionalStringProperty -InputObject $TopMovieGenre -Name 'Genre'
        } else { '' }
        $topGenreDescription = if ($null -ne $TopMovieGenre) {
            Get-OptionalStringProperty -InputObject $TopMovieGenre -Name 'SupportingText'
        } else { '' }
        if ([string]::IsNullOrWhiteSpace($topGenreName)) { $topGenreName = 'No qualifying genre yet' }
        if ([string]::IsNullOrWhiteSpace($topGenreDescription)) {
            $topGenreDescription = 'No qualifying movie activity with genre metadata this week'
        }
        $footerFeature += "`r`nTOP GENRE THIS WEEK: $topGenreName — $topGenreDescription"
    }
    if ($null -ne $BingeChampion) {
        $bingeDisplay = Get-BingeChampionDisplay -BingeChampion $BingeChampion -User $User
        $winnerLine = if ($bingeDisplay.IsWinner) {
            "YOU WON • BINGE CHAMPION"
        } else {
            "THIS WEEK'S BINGE CHAMPION"
        }
        $footerFeature += "`r`n${winnerLine}`r`n$($bingeDisplay.TotalTimeText) watched"
        $titleBreakdown = Get-BingeChampionTitleBreakdown -BingeDisplay $bingeDisplay
        if (-not [string]::IsNullOrWhiteSpace($titleBreakdown)) {
            $footerFeature += "`r`n$titleBreakdown"
        }
    }
    elseif (-not $WelcomeOnly) {
        $footerFeature += "`r`nTHIS WEEK'S BINGE CHAMPION: Awaiting the first qualifying stream."
    }

    $plainMovieItems = @()
    $plainMovieTitleCount = 0
    if ($null -ne $Stats.PSObject.Properties["MovieItems"]) {
        $plainMovieTitleCount = @($Stats.MovieItems).Count
        $plainMovieItems = @($Stats.MovieItems)
    }
    $plainTvShowItems = @()
    $plainTvShowTitleCount = 0
    if ($null -ne $Stats.PSObject.Properties["TvShowItems"]) {
        $plainTvShowTitleCount = @($Stats.TvShowItems).Count
        $plainTvShowItems = @($Stats.TvShowItems)
    }

    $movieStatsText = ""
    if ($plainMovieItems.Count -gt 0) {
        $movieWord = if ($plainMovieTitleCount -eq 1) { "movie" } else { "movies" }
        $movieLines = @($plainMovieItems | ForEach-Object {
            $watchedSuffix = Get-RecipientWatchedPlainTextSuffix -Item $_ -RecipientWatchedMovies $RecipientWatchedMovies
            "- {0}{1} — {2}" -f ([string]$_.Title), $watchedSuffix, (Format-WatchTime ([int64]$_.Seconds))
        })
        $movieStatsText = "{0} {1} watched`r`n{2}" -f $plainMovieTitleCount, $movieWord, ($movieLines -join "`r`n")
    }

    $tvStatsText = ""
    if ($plainTvShowItems.Count -gt 0) {
        $showWord = if ($plainTvShowTitleCount -eq 1) { "TV show" } else { "TV shows" }
        $showLines = @($plainTvShowItems | ForEach-Object {
            $episodeCount = Safe-Int (Get-OptionalStringProperty -InputObject $_ -Name "EpisodeCount")
            $episodeWord = if ($episodeCount -eq 1) { "episode" } else { "episodes" }
            "- {0} — {1} {2}" -f ([string]$_.ShowTitle), $episodeCount, $episodeWord
        })
        $tvStatsText = "{0} {1} watched`r`n{2}" -f $plainTvShowTitleCount, $showWord, ($showLines -join "`r`n")
    }

    $statsText = ""
    if ([int64]$Stats.TotalSeconds -le 0) {
        if ($RecentAccess) {
            $statsText = ""
        }
        elseif ($SystemWarmingUp) {
            $statsText = @"
YOUR WEEK ON PLEX

STATS ARE WARMING UP
The sensors are online.
Your weekly watch recap will begin filling in as you stream.
Check back next $deliveryDay for the full readout.
"@
        }
        else {
            $statsText = @"
YOUR WEEK ON PLEX

QUIET IN THIS SECTOR
No watch activity this week.
Warp Core still engaging. Your recap will be ready when you beam back aboard.
"@
        }
    }
    else {
        $statsText = @"
YOUR WEEK ON PLEX

$movieStatsText
$tvStatsText
$($Stats.TotalTimeText) total watch time
"@
    }

    $welcomeText = ""
    $welcomeInfoText = ""
    if ($RecentAccess) {
        $welcomeText = @"

WELCOME ABOARD
Access granted, $($User.FriendlyName).
Your access to $serverName is live. This is your first $deliveryDay drop.
"@
        $welcomeInfoText = @"

$($deliveryDay.ToUpperInvariant()) DROPS
Every $deliveryDay morning you'll get the newest movies and TV additions.

YOUR PRIVATE READOUT
As you stream, your weekly email builds a private recap with watch time, movies,
episodes, and your most-watched title.

JUST YOUR STATS
Your individual viewing recap stays in your email. Other users don't receive it.
"@
    }

    if ($RecentAccess) {
        return @"
${plainPreheaderBlock}Hey $($User.FriendlyName),
$welcomeText
$customTextCardBlock
$releaseMetaText
$heroLine

$statsText
$welcomeInfoText
$footerFeature

${plexButtonLabel}: $plexWebUrl
"@
    }

    return @"
${plainPreheaderBlock}Hey $($User.FriendlyName),

Your $deliveryDay Plex drop is here.
$customTextCardBlock
$releaseMetaText
$heroLine

$statsText
$footerFeature

${plexButtonLabel}: $plexWebUrl
"@
}

function Build-WelcomeHtml {
    param([object]$User)

    $friendly = HtmlEncode $User.FriendlyName

    $plexUrl = Get-ConfiguredPlexWebUrl
    $plexButtonLabel = Get-ConfiguredPlexButtonLabel
    $footerServerName = Get-ConfiguredServerName
    $deliveryDay = Get-ConfiguredDeliveryDay

    return @"
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>Welcome aboard</title>
<style>
:root { color-scheme:light dark; supported-color-schemes:light dark; }
.email-background { background-color:#0f0f0f !important; color:#ffffff !important; }
.email-card { background-color:#181818 !important; }
@media (prefers-color-scheme: dark) {
  .email-background { background-color:#0f0f0f !important; color:#ffffff !important; }
  .email-card { background-color:#181818 !important; }
}
</style>
</head>
<body class="email-background" bgcolor="#0f0f0f" style="margin:0;padding:0;background-color:#0f0f0f;color:#ffffff;font-family:Arial,Helvetica,sans-serif;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;mso-hide:all;">Your access to $(HtmlEncode $footerServerName) is live.</div>
<table class="email-background" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#0f0f0f" style="background-color:#0f0f0f;">
<tr>
<td class="email-background" align="center" bgcolor="#0f0f0f" style="padding:34px 12px;background-color:#0f0f0f;">
<table class="email-background" width="600" cellspacing="0" cellpadding="0" border="0" bgcolor="#0f0f0f" style="width:600px;max-width:600px;background-color:#0f0f0f;">
<tr>
<td style="padding:0 20px 20px;">
  <div style="font-size:12px;color:#e5a00d;font-weight:800;letter-spacing:1.8px;">
    <span style="display:inline-block;vertical-align:middle;">WELCOME ABOARD</span>
    <img src="cid:icon_welcome" width="18" height="18" alt="Welcome aboard" style="display:inline-block;width:18px;height:18px;border:0;vertical-align:-4px;margin-left:6px;">
  </div>
  <div style="padding-top:9px;font-size:34px;line-height:1.1;font-weight:800;color:#ffffff;">Access granted, $friendly.</div>
  <div style="padding-top:12px;font-size:16px;line-height:1.55;color:#a9a9a9;">Your access to $(HtmlEncode $footerServerName) is live. Grab the remote — you’re cleared for departure.</div>
</td>
</tr>
<tr>
<td style="padding:0 20px 22px;">
  <table class="email-card" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#181818" style="background-color:#181818;border:1px solid #2b2b2b;border-radius:10px;border-collapse:separate;">
    <tr>
      <td style="padding:20px 22px;">
        <div style="font-size:13px;color:#e5a00d;font-weight:800;">🍿 $($deliveryDay.ToUpperInvariant()) DROPS</div>
        <div style="padding-top:5px;font-size:14px;line-height:1.5;color:#a0a0a0;">Every $deliveryDay morning you’ll get the newest movies and TV additions.</div>

        <div style="padding-top:18px;font-size:13px;color:#e5a00d;font-weight:800;">📡 YOUR PRIVATE READOUT</div>
        <div style="padding-top:5px;font-size:14px;line-height:1.5;color:#a0a0a0;">As you stream, your weekly email builds a private recap with watch time, movies, TV shows, posters, and ratings.</div>

        <div style="padding-top:18px;font-size:13px;color:#e5a00d;font-weight:800;">🔒 JUST YOUR STATS</div>
        <div style="padding-top:5px;font-size:14px;line-height:1.5;color:#a0a0a0;">Your detailed viewing recap stays in your email. The Binge Champion watch duration, total plays, and nonzero unique movie/TV-show counts are shared server-wide; when more than one episode qualifies, their cumulative count is included. The champion’s identity stays private.</div>
      </td>
    </tr>
  </table>
</td>
</tr>
<tr>
<td align="center" style="padding:4px 20px 24px;">
  <a href="$(HtmlEncode $plexUrl)" style="display:inline-block;background-color:#e5a00d;color:#111111;text-decoration:none;font-size:14px;font-weight:800;padding:14px 28px;border-radius:7px;">$(HtmlEncode $plexButtonLabel)</a>
</td>
</tr>
<tr>
<td align="center" style="padding:5px 20px 24px;color:#5f5f5f;font-size:11px;line-height:1.5;">
  Welcome to $(HtmlEncode $footerServerName).<br>
  Reply to this email if anything looks broken.
</td>
</tr>
</table>
</td>
</tr>
</table>
</body>
</html>
"@
}

function Build-WelcomePlainText {
    param(
        [object]$User,
        [object]$ReleaseData
    )

    $serverName = Get-ConfiguredServerName
    $deliveryDay = Get-ConfiguredDeliveryDay
    $plexWebUrl = Get-ConfiguredPlexWebUrl
    $plexButtonLabel = Get-ConfiguredPlexButtonLabel
    $customTextCardBlock = Get-CustomTextCardPlainText

    $plainPreheader = Get-DynamicPreheader -ReleaseData $ReleaseData
    $plainPreheaderBlock = if ([string]::IsNullOrWhiteSpace($plainPreheader)) {
        ""
    }
    else {
        $plainPreheader + "`r`n`r`n"
    }

    return @"
${plainPreheaderBlock}Welcome aboard, $($User.FriendlyName).

Your access to $serverName is live. Grab the remote — you're cleared for departure.

$customTextCardBlock
Your welcome email also includes the current New Releases from the server.

$($deliveryDay.ToUpperInvariant()) DROPS
Every $deliveryDay morning you'll get the newest movies and TV additions.

YOUR PRIVATE READOUT
As you stream, your weekly email builds a private recap with watch time, movies,
episodes, and your most-watched title.

Your individual viewing stats are not shared with other users.

${plexButtonLabel}: $plexWebUrl
"@
}

function Send-NewsletterMail {
    param(
        [string]$To,
        [string]$Subject,
        [string]$Html,
        [string]$PlainText,
        [object[]]$PosterAssets,
        [AllowNull()][object]$HeroAssets = $null
    )

    foreach ($name in @("SmtpHost","SmtpPort","FromEmail","FromName")) {
        Require-ConfigValue $name
    }

    $smtpUseAuthentication = $true
    if ($null -ne $Config.PSObject.Properties["SmtpUseAuthentication"]) {
        $smtpUseAuthentication = [bool]$Config.SmtpUseAuthentication
    }

    $smtpPassword = ""
    if ($null -ne $Config.PSObject.Properties["SmtpPassword"]) {
        $smtpPassword = [string]$Config.SmtpPassword
    }
    elseif ($null -ne $Config.PSObject.Properties["SmtpAppPassword"]) {
        # Backward compatibility with pre-portable TautWeekly for Plex configs.
        $smtpPassword = [string]$Config.SmtpAppPassword
    }

    if ($smtpUseAuthentication) {
        Require-ConfigValue "SmtpUsername"
        if ([string]::IsNullOrWhiteSpace($smtpPassword)) {
            throw "SMTP authentication is enabled but SmtpPassword is blank."
        }
    }

    if ([string]::IsNullOrWhiteSpace($To)) {
        throw "Recipient email is blank."
    }

    $mail = New-Object System.Net.Mail.MailMessage
    $htmlView = $null
    $plainView = $null

    try {
        $mail.From = New-Object System.Net.Mail.MailAddress([string]$Config.FromEmail, [string]$Config.FromName)
        $mail.To.Add($To)

        if ($null -ne $Config.PSObject.Properties["ReplyToEmail"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.ReplyToEmail)) {
            $mail.ReplyToList.Add([string]$Config.ReplyToEmail)
        }

        $mail.Subject = $Subject
        $mail.SubjectEncoding = [Text.Encoding]::UTF8
        $mail.BodyEncoding = [Text.Encoding]::UTF8

        $plainView = [System.Net.Mail.AlternateView]::CreateAlternateViewFromString($PlainText, $null, "text/plain")
        $htmlView = [System.Net.Mail.AlternateView]::CreateAlternateViewFromString($Html, $null, "text/html")

        foreach ($asset in $PosterAssets) {
            if (-not (Test-Path $asset.Path)) { continue }

            $cid = [string]$asset.Cid
            if ([string]::IsNullOrWhiteSpace($cid)) { continue }

            # Do not package unused resources into the message.
            if ($Html.IndexOf(("cid:" + $cid), [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                continue
            }

            # Use a stream instead of a filename-based constructor so the MIME
            # image part does not inherit a downloadable filename/name parameter.
            $stream = [System.IO.File]::OpenRead([string]$asset.Path)
            try {
                $linked = New-Object System.Net.Mail.LinkedResource($stream, "image/jpeg")
                $linked.ContentId = $cid
                $linked.ContentLink = New-Object System.Uri(("cid:" + $cid))
                $linked.TransferEncoding = [System.Net.Mime.TransferEncoding]::Base64
                $htmlView.LinkedResources.Add($linked)

                # Ownership of the stream transfers to LinkedResource.
                $stream = $null
            }
            finally {
                if ($null -ne $stream) {
                    $stream.Dispose()
                }
            }
        }

        $uiAssets = @(
            @{ Path = (Join-Path $AssetsDir "movies.gif"); Cid = "icon_movies"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "tv.gif"); Cid = "icon_tv"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "clock.gif"); Cid = "icon_clock"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "trophy.gif"); Cid = "icon_trophy"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "hot.gif"); Cid = "icon_hot"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "trending.gif"); Cid = "icon_trending"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "pending.gif"); Cid = "icon_pending"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "quiet.gif"); Cid = "icon_quiet"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "welcome.gif"); Cid = "icon_welcome"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "watched.png"); Cid = "recipient_watched"; MediaType = "image/png" },
            @{ Path = (Join-Path $AssetsDir "watched-desktop.png"); Cid = "recipient_watched_desktop"; MediaType = "image/png" },
            @{ Path = (Join-Path $AssetsDir "action.gif"); Cid = "icon_action"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "watched.gif"); Cid = "icon_watched"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "lockinfo.gif"); Cid = "icon_lockinfo"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "watchlist.gif"); Cid = "icon_binge"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "popcorn.gif"); Cid = "icon_popcorn"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "genre-action.gif"); Cid = "genre_action"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "genre-comedy.gif"); Cid = "genre_comedy"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "genre-crime.gif"); Cid = "genre_crime"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "genre-drama.gif"); Cid = "genre_drama"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "genre-fantasy.gif"); Cid = "genre_fantasy"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "genre-horror.gif"); Cid = "genre_horror"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "genre-musical.gif"); Cid = "genre_musical"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "genre-mystery.gif"); Cid = "genre_mystery"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "genre-romance.gif"); Cid = "genre_romance"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "genre-scifi.gif"); Cid = "genre_scifi"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "genre-thriller.gif"); Cid = "genre_thriller"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "genre-western.gif"); Cid = "genre_western"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "celebrate.gif"); Cid = "custom_title_celebrate"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "construction.gif"); Cid = "custom_title_construction"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "rocket.gif"); Cid = "custom_title_rocket"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "tickets.gif"); Cid = "custom_title_tickets"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "warning.gif"); Cid = "custom_title_warning"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "alert.gif"); Cid = "custom_title_alert"; MediaType = "image/gif" },
            @{ Path = (Join-Path $AssetsDir "rt_ripe.png"); Cid = "rt_ripe"; MediaType = "image/png" },
            @{ Path = (Join-Path $AssetsDir "rt_rotten.png"); Cid = "rt_rotten"; MediaType = "image/png" },
            @{ Path = (Join-Path $AssetsDir "rt_upright.png"); Cid = "rt_upright"; MediaType = "image/png" },
            @{ Path = (Join-Path $AssetsDir "rt_spilled.png"); Cid = "rt_spilled"; MediaType = "image/png" },
            @{ Path = (Join-Path $AssetsDir "imdb.png"); Cid = "icon_imdb"; MediaType = "image/png" }
        )
        foreach ($platformAsset in @(Get-NewsletterPlatformCatalog)) {
            $uiAssets += @{
                Path = (Join-Path $AssetsDir ([string]$platformAsset.FileName))
                Cid = [string]$platformAsset.Cid
                MediaType = "image/png"
            }
        }

        foreach ($uiAsset in $uiAssets) {
            if (-not (Test-Path $uiAsset.Path)) { continue }

            $cid = [string]$uiAsset.Cid
            if ([string]::IsNullOrWhiteSpace($cid)) { continue }

            # Only embed UI art that this specific email actually references.
            if ($Html.IndexOf(("cid:" + $cid), [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                continue
            }

            $stream = [System.IO.File]::OpenRead([string]$uiAsset.Path)
            try {
                $linked = New-Object System.Net.Mail.LinkedResource(
                    $stream,
                    [string]$uiAsset.MediaType
                )
                $linked.ContentId = $cid
                $linked.ContentLink = New-Object System.Uri(("cid:" + $cid))
                $linked.TransferEncoding = [System.Net.Mime.TransferEncoding]::Base64
                $htmlView.LinkedResources.Add($linked)

                # LinkedResource will dispose the stream with the message.
                $stream = $null
            }
            finally {
                if ($null -ne $stream) {
                    $stream.Dispose()
                }
            }
        }


        # Featured hero art is generated locally from Plex/Tautulli metadata.
        # Attach only the resources the current HTML references.
        if ($null -ne $HeroAssets) {
            $heroLinkedAssets = New-Object System.Collections.Generic.List[object]

            if (-not [string]::IsNullOrWhiteSpace([string]$HeroAssets.BannerSrc)) {
                $heroLinkedAssets.Add([PSCustomObject]@{
                    RelativePath = [string]$HeroAssets.BannerSrc
                    Cid = "hero_banner"
                    MediaType = "image/jpeg"
                })
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$HeroAssets.LogoSrc)) {
                $logoExt = [IO.Path]::GetExtension([string]$HeroAssets.LogoSrc).ToLowerInvariant()
                if ($logoExt -eq ".png") {
                    $heroLinkedAssets.Add([PSCustomObject]@{
                        RelativePath = [string]$HeroAssets.LogoSrc
                        Cid = "hero_logo"
                        MediaType = "image/png"
                    })
                }
            }

            foreach ($heroAsset in $heroLinkedAssets) {
                if ($Html.IndexOf(("cid:" + $heroAsset.Cid), [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    continue
                }

                $heroPath = Join-Path $OutputDir ([string]$heroAsset.RelativePath)
                if (-not (Test-Path $heroPath)) {
                    Write-Log "Hero asset missing: $heroPath" "WARN"
                    continue
                }

                $stream = [System.IO.File]::OpenRead($heroPath)
                try {
                    $linked = New-Object System.Net.Mail.LinkedResource($stream, [string]$heroAsset.MediaType)
                    $linked.ContentId = [string]$heroAsset.Cid
                    $linked.ContentLink = New-Object System.Uri(("cid:" + [string]$heroAsset.Cid))
                    $linked.TransferEncoding = [System.Net.Mime.TransferEncoding]::Base64
                    $htmlView.LinkedResources.Add($linked)
                    $stream = $null
                }
                finally {
                    if ($null -ne $stream) { $stream.Dispose() }
                }
            }
        }

        $mail.AlternateViews.Add($plainView)
        $mail.AlternateViews.Add($htmlView)

        Send-TautWeeklySmtpMessage -MailMessage $mail -Config $Config
    }
    finally {
        if ($null -ne $mail) { $mail.Dispose() }
    }
}

function Get-NewsletterUser {
    param([string]$Id)

    $u = Get-TautulliUser -Id $Id

    $friendly = Get-OptionalStringProperty -InputObject $u -Name "friendly_name"
    if ([string]::IsNullOrWhiteSpace($friendly)) {
        $friendly = Get-OptionalStringProperty -InputObject $u -Name "username"
    }
    if ([string]::IsNullOrWhiteSpace($friendly)) {
        $friendly = "there"
    }

    $nativeEmail = Get-OptionalStringProperty -InputObject $u -Name "email"
    $deliveryEmail = $nativeEmail
    if ([string]::IsNullOrWhiteSpace($deliveryEmail) -and $null -ne $Config.PSObject.Properties['UserEmailOverrides']) {
        $override = $Config.UserEmailOverrides.PSObject.Properties[(Get-OptionalStringProperty -InputObject $u -Name "user_id")]
        if ($null -ne $override) { $deliveryEmail = ([string]$override.Value).Trim() }
    }

    return [PSCustomObject]@{
        UserId       = Get-OptionalStringProperty -InputObject $u -Name "user_id"
        Username     = Get-OptionalStringProperty -InputObject $u -Name "username"
        FriendlyName = $friendly
        Email        = $nativeEmail
        DeliveryEmail = $deliveryEmail
        IsActive     = Safe-Int (Get-OptionalStringProperty -InputObject $u -Name "is_active")
        DeletedUser  = Safe-Int (Get-OptionalStringProperty -InputObject $u -Name "deleted_user")
        DoNotify     = Safe-Int (Get-OptionalStringProperty -InputObject $u -Name "do_notify")
    }
}

function Get-UserSkipReason {
    param([object]$User)

    if ($User.DeletedUser -gt 0 -or $User.IsActive -eq 0) { return "inactiveOrDeleted" }

    if ($null -ne $Config.PSObject.Properties["ExcludedUserIds"]) {
        foreach ($id in @($Config.ExcludedUserIds)) {
            if ([string]$id -eq [string]$User.UserId) { return "excludedUserId" }
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$User.DeliveryEmail)) { return "missingEmail" }

    if ($null -ne $Config.PSObject.Properties["ExcludedEmails"]) {
        foreach ($email in @($Config.ExcludedEmails)) {
            if ([string]$email -ieq [string]$User.DeliveryEmail) { return "excludedEmail" }
        }
    }

    return ""
}

# ---------------------------------------------------------------------------
# SUBJECT / PREHEADER HELPERS
# ---------------------------------------------------------------------------
function Get-DynamicPreheader {
    param([object]$ReleaseData)

    $movieCount = @($ReleaseData.Movies).Count
    $tvCount = @($ReleaseData.TV).Count
    $parts = New-Object System.Collections.Generic.List[string]

    if ($movieCount -gt 0) {
        $movieWord = if ($movieCount -eq 1) { "new movie" } else { "new movies" }
        $parts.Add("$movieCount $movieWord")
    }
    if ($tvCount -gt 0) {
        $tvWord = if ($tvCount -eq 1) { "new TV title" } else { "new TV titles" }
        $parts.Add("$tvCount $tvWord")
    }

    if ($parts.Count -eq 0) { return "" }
    return ($parts -join " • ") + "!"
}

function Get-OneOffWelcomeSubject {
    param([object]$User)
    $serverName = Get-ConfiguredServerName
    return "$($User.FriendlyName), welcome aboard 🖖 | $serverName is ready 🍿"
}

function Get-NewsletterSubject {
    param(
        [object]$User,
        [bool]$RecentAccess = $false
    )

    $serverName = Get-ConfiguredServerName
    $deliveryDay = Get-ConfiguredDeliveryDay

    if ($RecentAccess) {
        return "$($User.FriendlyName), welcome aboard 🖖 | $serverName is ready 🍿"
    }

    return "$($User.FriendlyName), your $deliveryDay Plex drop is here 🍿"
}

# ---------------------------------------------------------------------------
# MODE: VERIFY DIRECT PLEX
# ---------------------------------------------------------------------------
if ($Mode -eq "VerifyPlex") {
    exit (Test-TautWeeklyDirectPlexConnection)
}

# ---------------------------------------------------------------------------
# MODE: LIST USERS
# ---------------------------------------------------------------------------
if ($Mode -eq "ListUsers") {
    $script:TautWeeklyResultErrorCategory = "tautulli-unavailable"
    Write-Log "Loading Tautulli users..."
    $names = Get-TautulliUserNames
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($n in $names) {
        try {
            $u = Get-NewsletterUser -Id ([string]$n.user_id)
            $rows.Add([PSCustomObject]@{
                UserId       = $u.UserId
                Username     = $u.Username
                FriendlyName = $u.FriendlyName
                Email        = $u.Email
                Active       = $u.IsActive
                TautulliNotify = $u.DoNotify
            })
        }
        catch {
            Write-Log "Could not load user $($n.user_id): $($_.Exception.Message)" "WARN"
        }
    }

    $rows | Sort-Object FriendlyName | Format-Table -AutoSize
    Write-Host ""
    Write-Host "TautulliNotify is legacy notification-agent state and does not control TautWeekly delivery." -ForegroundColor DarkGray
    Write-Host "ListUsers only displays the roster; it does not select or save a default user." -ForegroundColor Yellow
    Write-Host "Pass a numeric UserId from this table to Preview, PreviewAll, SendTest, SendTestAll, or SendWelcome."
    exit 0
}

# ---------------------------------------------------------------------------
# MODE: SEND ONE-OFF WELCOME
# This mode uses the same real release-state payload as scheduled and test delivery.
# ---------------------------------------------------------------------------
if ($Mode -eq "SendWelcome") {
    if ([string]::IsNullOrWhiteSpace($UserId)) {
        throw "SendWelcome mode requires a user identifier. ListUsers only displays the roster; pass a numeric UserId from that table."
    }
    if (-not $ConfirmWelcome) {
        throw "SendWelcome is intentionally locked. Re-run with -ConfirmWelcome."
    }

    $script:TautWeeklyResultErrorCategory = "tautulli-unavailable"
    $resolvedUserId = Resolve-TautulliUserId -Identifier $UserId
    $user = Get-NewsletterUser -Id $resolvedUserId
    $welcomeSkipReason = Get-UserSkipReason -User $user
    if (-not [string]::IsNullOrWhiteSpace($welcomeSkipReason)) {
        throw "This user is not eligible for welcome delivery: $welcomeSkipReason."
    }
    $recipientPlatform = Get-NewsletterLastPlatform -ExpectedUserId $user.UserId
    $recipientWatchedMovies = Get-RecipientWatchedMovies -ExpectedUserId $user.UserId

    $accessState = Sync-AccessRoster

    $daysBack = if ($null -ne $Config.PSObject.Properties["DaysBack"]) { Safe-Int $Config.DaysBack } else { 7 }
    if ($daysBack -lt 1) { $daysBack = 7 }

    $windowEnd = (Get-TautWeeklyRunNow).Date
    $windowStart = $windowEnd.AddDays(-($daysBack - 1))
    $windowEndExclusive = $windowEnd.AddDays(1)
    $afterDate = $windowStart.ToString("yyyy-MM-dd")
    $beforeDate = $windowEnd.ToString("yyyy-MM-dd")
    $startLabel = $windowStart.ToString("MMM d")
    $endLabel = $windowEnd.ToString("MMM d, yyyy")
    $startEpoch = [int64](ConvertTo-TautWeeklyRunUnixTime -LocalTime $windowStart)
    $endEpochExclusive = [int64](ConvertTo-TautWeeklyRunUnixTime -LocalTime $windowEndExclusive)

    Write-Log "Loading current New Releases for the one-off welcome..."
    $recentItems = Get-RecentItems -StartEpoch $startEpoch -EndEpochExclusive $endEpochExclusive
    $releaseData = New-ReleaseData -RecentItems $recentItems
    Add-DesignRatingMetadata -ReleaseData $releaseData
    Enrich-TvEpisodeMetadata -ReleaseData $releaseData -ContextLabel "One-off TV" -StartEpoch $startEpoch -EndEpochExclusive $endEpochExclusive -CountRecentEpisodes $true

    $isQuietReleaseWeek = (@($releaseData.Movies).Count -eq 0)
    Write-Log ("Found {0} new movies and {1} TV titles; Trending-release mode: {2}." -f $releaseData.Movies.Count, $releaseData.TV.Count, $isQuietReleaseWeek)

    $latestReleaseData = $null
    if ($isQuietReleaseWeek) {
        $latestTvCutoffEpoch = [int64]([DateTimeOffset]::UtcNow.AddMonths(-1).ToUnixTimeSeconds())
        Write-Log "No new movies. Loading shared Recent Releases movie candidates and TV fallback..."
        $latestReleaseData = Get-LatestReleaseData -MovieLimit 5 -TvLimit 4 -TvAddedAfterEpoch $latestTvCutoffEpoch
        Add-DesignRatingMetadata -ReleaseData $latestReleaseData
        if (@($releaseData.TV).Count -eq 0) {
            Enrich-TvEpisodeMetadata -ReleaseData $latestReleaseData -ContextLabel "Recent TV"
        }
        Write-Log ("Recent Releases candidates: {0} movies and {1} TV titles." -f $latestReleaseData.Movies.Count, $latestReleaseData.TV.Count)
    }

    $globalHistory = Get-History -AfterDate $afterDate -BeforeDate $beforeDate
    $topMovieGenre = Get-GlobalTopMovieGenre -GlobalHistory $globalHistory
    $movieHotRelease = Get-HotNewRelease -ReleaseData $releaseData -GlobalHistory $globalHistory
    $script:GlobalTrendingStat = Get-GlobalTrendingStat -GlobalHistory $globalHistory
    $trendingTitle = if ($null -ne $script:GlobalTrendingStat) { [string]$script:GlobalTrendingStat.Title } else { "" }
    $trendingReleaseData = if ($isQuietReleaseWeek -and @($releaseData.TV).Count -eq 0) { $latestReleaseData } else { $releaseData }
    $trendingHero = Get-GlobalTrendingHero -GlobalHistory $globalHistory -ReleaseData $trendingReleaseData -TrendingStat $script:GlobalTrendingStat
    $hotRelease = if (@($releaseData.Movies).Count -gt 0) { $movieHotRelease } else { $trendingHero }

    if (($isQuietReleaseWeek -or @($releaseData.Movies).Count -eq 0) -and $null -ne $trendingHero -and $null -ne $trendingHero.Item) {
        Add-DesignRatingMetadata -ReleaseData ([PSCustomObject]@{ Movies = @($trendingHero.Item); TV = @() })
    }

    $activeReleaseData = if ($isQuietReleaseWeek) {
        $trendingTvItems = if (@($releaseData.TV).Count -gt 0) { @($releaseData.TV) } else { @($latestReleaseData.TV) }
        [PSCustomObject]@{
            Movies            = @($latestReleaseData.Movies)
            TV                = $trendingTvItems
            MovieSectionLabel = "RECENT RELEASES"
            TvSectionLabel    = if (@($releaseData.TV).Count -gt 0) { "NEW RELEASES" } else { "RECENT RELEASES" }
        }
    }
    else { $releaseData }
    $activeHero = if ($isQuietReleaseWeek) { $trendingHero } else { $hotRelease }

    $trendingPosterItem = $null
    if ($null -ne $script:GlobalTrendingStat -and
        -not [string]::IsNullOrWhiteSpace([string]$script:GlobalTrendingStat.RatingKey)) {
        $trendingPosterItem = [PSCustomObject]@{
            PosterRatingKey = [string]$script:GlobalTrendingStat.RatingKey
            MetadataGuid    = Get-OptionalStringProperty -InputObject $script:GlobalTrendingStat -Name "MetadataGuid"
            MetadataParentIndex = Safe-Int (Get-OptionalStringProperty -InputObject $script:GlobalTrendingStat -Name "MetadataParentIndex")
            MetadataIndex   = Safe-Int (Get-OptionalStringProperty -InputObject $script:GlobalTrendingStat -Name "MetadataIndex")
            Type            = [string]$script:GlobalTrendingStat.Type
            Title           = [string]$script:GlobalTrendingStat.Title
            Year            = Get-OptionalStringProperty -InputObject $script:GlobalTrendingStat -Name "Year"
        }
    }
    $featuredRatingKey = if ($null -ne $activeHero -and $null -ne $activeHero.Item) {
        [string]$activeHero.Item.PosterRatingKey
    } else { "" }

    $script:TautWeeklyResultErrorCategory = "asset-unavailable"
    Write-Log "Preparing shared release posters and hero assets for welcome email..."
    $posterAssets = Prepare-PosterAssets `
        -ReleaseData $activeReleaseData `
        -FeaturedRatingKey $featuredRatingKey `
        -HotRelease $activeHero `
        -QuietReleaseMode $isQuietReleaseWeek `
        -AdditionalItems @($trendingPosterItem)
    $designHero = Get-DesignHeroAssets -HotRelease $activeHero

    $welcomeStats = [PSCustomObject]@{
        MoviesWatched    = 0
        EpisodesStreamed = 0
        TotalSeconds     = 0
        TotalTimeText    = "0 min"
        MostWatched      = ""
        QualifyingPlays  = 0
        MovieItems       = @()
        EpisodeItems     = @()
        TvShowItems      = @()
    }

    $script:TautWeeklyResultErrorCategory = "render-failed"
    $html = Build-NewsletterHtml `
        -User $user `
        -Stats $welcomeStats `
        -ReleaseData $activeReleaseData `
        -HotRelease $activeHero `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -SystemWarmingUp $false `
        -RecentAccess $true `
        -WelcomeOnly $true `
        -QuietReleaseMode $isQuietReleaseWeek `
        -BingeChampion $null `
        -RecipientPlatform $recipientPlatform `
        -PosterAssets $posterAssets `
        -ImageMode "Email" `
        -StartLabel $startLabel `
        -EndLabel $endLabel

    $plain = Build-PlainText `
        -User $user `
        -Stats $welcomeStats `
        -ReleaseData $activeReleaseData `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -HotRelease $activeHero `
        -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -SystemWarmingUp $false `
        -RecentAccess $true `
        -QuietReleaseMode $isQuietReleaseWeek `
        -BingeChampion $null `
        -WelcomeOnly $true `
        -StartLabel $startLabel `
        -EndLabel $endLabel
    $subject = Get-OneOffWelcomeSubject -User $user

    $script:TautWeeklyResultErrorCategory = "smtp-failed"
    Write-Log "Sending ONE-OFF welcome to $($user.FriendlyName) <$($user.DeliveryEmail)>..."
    Send-NewsletterMail `
        -To $user.DeliveryEmail `
        -Subject $subject `
        -Html $html `
        -PlainText $plain `
        -PosterAssets $posterAssets `
        -HeroAssets $designHero

    $script:TautWeeklyResultSmtpAcceptedCount = 1
    Mark-UserWelcomed -State $accessState -UserId $user.UserId
    Write-Log "Welcome email sent successfully to $($user.FriendlyName)."
    Write-TautWeeklyStructuredResult -Outcome "succeeded"
    exit 0
}

# ---------------------------------------------------------------------------
# COMMON DATA FOR FRIDAY PREVIEW / TEST / SEND
# ---------------------------------------------------------------------------
if ($Mode -eq "SendAll" -and -not $ConfirmSendAll) {
    throw "SendAll is intentionally locked. Re-run with -ConfirmSendAll after reviewing a test email."
}

$script:TautWeeklyResultErrorCategory = "configuration-invalid"
$tautWeeklyState = Get-TautWeeklyState
Write-Log ("TautWeekly for Plex age: {0} day(s); warm-up mode: {1}" -f $tautWeeklyState.AgeDays, $tautWeeklyState.IsWarmingUp)

$script:TautWeeklyResultErrorCategory = "configuration-invalid"
$accessState = if ($Mode -in @("PreviewAll","CacheWarm","SendTestAll")) {
    # The all-variant test harness must not change first-seen/welcome tracking.
    Get-AccessState
}
else {
    $script:TautWeeklyResultErrorCategory = "tautulli-unavailable"
    Sync-AccessRoster -RequireFreshUsers:($Mode -eq "SendAll")
}
$script:TautWeeklyResultErrorCategory = "tautulli-unavailable"
$daysBack = if ($null -ne $Config.PSObject.Properties["DaysBack"]) { Safe-Int $Config.DaysBack } else { 7 }
if ($daysBack -lt 1) { $daysBack = 7 }

$windowEnd = (Get-TautWeeklyRunNow).Date
$windowStart = $windowEnd.AddDays(-($daysBack - 1))
$windowEndExclusive = $windowEnd.AddDays(1)
$afterDate = $windowStart.ToString("yyyy-MM-dd")
$beforeDate = $windowEnd.ToString("yyyy-MM-dd")
$startLabel = $windowStart.ToString("MMM d")
$endLabel = $windowEnd.ToString("MMM d, yyyy")
$startEpoch = [int64](ConvertTo-TautWeeklyRunUnixTime -LocalTime $windowStart)
$endEpochExclusive = [int64](ConvertTo-TautWeeklyRunUnixTime -LocalTime $windowEndExclusive)

Write-Log "Newsletter window: $afterDate through $beforeDate"
Write-Log "Loading global recently-added media..."
$releaseData = New-ReleaseData -RecentItems (Get-RecentItems -StartEpoch $startEpoch -EndEpochExclusive $endEpochExclusive)
Add-DesignRatingMetadata -ReleaseData $releaseData
Enrich-TvEpisodeMetadata -ReleaseData $releaseData -ContextLabel "Weekly TV" -StartEpoch $startEpoch -EndEpochExclusive $endEpochExclusive -CountRecentEpisodes $true

$isQuietReleaseWeek = (@($releaseData.Movies).Count -eq 0)
Write-Log ("Found {0} new movies and {1} TV titles; Trending-release mode: {2}." -f $releaseData.Movies.Count, $releaseData.TV.Count, $isQuietReleaseWeek)

$latestReleaseData = $null
if ($isQuietReleaseWeek) {
    $latestTvCutoffEpoch = [int64]([DateTimeOffset]::UtcNow.AddMonths(-1).ToUnixTimeSeconds())
    Write-Log "No new movies. Loading shared Recent Releases movie candidates and TV fallback..."
    $latestReleaseData = Get-LatestReleaseData -MovieLimit 5 -TvLimit 4 -TvAddedAfterEpoch $latestTvCutoffEpoch
    Add-DesignRatingMetadata -ReleaseData $latestReleaseData
    if (@($releaseData.TV).Count -eq 0) {
        Enrich-TvEpisodeMetadata -ReleaseData $latestReleaseData -ContextLabel "Recent TV"
    }
    Write-Log ("Recent Releases candidates: {0} movies and {1} TV titles." -f $latestReleaseData.Movies.Count, $latestReleaseData.TV.Count)
}

Write-Log "Loading global history for hero, Trending, Top Movie Genre, and Binge Champion..."
$globalHistory = Get-History -AfterDate $afterDate -BeforeDate $beforeDate
$topMovieGenre = Get-GlobalTopMovieGenre -GlobalHistory $globalHistory
$movieHotRelease = Get-HotNewRelease -ReleaseData $releaseData -GlobalHistory $globalHistory
$script:GlobalTrendingStat = Get-GlobalTrendingStat -GlobalHistory $globalHistory
$trendingTitle = if ($null -ne $script:GlobalTrendingStat) { [string]$script:GlobalTrendingStat.Title } else { "" }
$trendingReleaseData = if ($isQuietReleaseWeek -and @($releaseData.TV).Count -eq 0) { $latestReleaseData } else { $releaseData }
$quietHero = Get-GlobalTrendingHero -GlobalHistory $globalHistory -ReleaseData $trendingReleaseData -TrendingStat $script:GlobalTrendingStat
$hotRelease = if (@($releaseData.Movies).Count -gt 0) { $movieHotRelease } else { $quietHero }
$bingeChampion = Get-BingeChampion -GlobalHistory $globalHistory

if (($isQuietReleaseWeek -or @($releaseData.Movies).Count -eq 0) -and $null -ne $quietHero -and $null -ne $quietHero.Item) {
    Add-DesignRatingMetadata -ReleaseData ([PSCustomObject]@{ Movies = @($quietHero.Item); TV = @() })
}

$activeReleaseData = if ($isQuietReleaseWeek) {
    $trendingTvItems = if (@($releaseData.TV).Count -gt 0) { @($releaseData.TV) } else { @($latestReleaseData.TV) }
    [PSCustomObject]@{
        Movies            = @($latestReleaseData.Movies)
        TV                = $trendingTvItems
        MovieSectionLabel = "RECENT RELEASES"
        TvSectionLabel    = if (@($releaseData.TV).Count -gt 0) { "NEW RELEASES" } else { "RECENT RELEASES" }
    }
}
else { $releaseData }
$activeHero = if ($isQuietReleaseWeek) { $quietHero } else { $hotRelease }

$featuredRatingKey = if ($null -ne $activeHero -and $null -ne $activeHero.Item) {
    [string]$activeHero.Item.PosterRatingKey
} else { "" }

$trendingPosterItem = $null
if ($null -ne $script:GlobalTrendingStat -and
    -not [string]::IsNullOrWhiteSpace([string]$script:GlobalTrendingStat.RatingKey)) {
    $trendingPosterItem = [PSCustomObject]@{
        PosterRatingKey = [string]$script:GlobalTrendingStat.RatingKey
        MetadataGuid    = Get-OptionalStringProperty -InputObject $script:GlobalTrendingStat -Name "MetadataGuid"
        MetadataParentIndex = Safe-Int (Get-OptionalStringProperty -InputObject $script:GlobalTrendingStat -Name "MetadataParentIndex")
        MetadataIndex   = Safe-Int (Get-OptionalStringProperty -InputObject $script:GlobalTrendingStat -Name "MetadataIndex")
        Type            = [string]$script:GlobalTrendingStat.Type
        Title           = [string]$script:GlobalTrendingStat.Title
        Year            = Get-OptionalStringProperty -InputObject $script:GlobalTrendingStat -Name "Year"
    }
}

$script:TautWeeklyResultErrorCategory = "asset-unavailable"
Write-Log "Preparing release posters..."
$activePosterAssets = Prepare-PosterAssets `
    -ReleaseData $activeReleaseData `
    -FeaturedRatingKey $featuredRatingKey `
    -HotRelease $activeHero `
    -QuietReleaseMode $isQuietReleaseWeek `
    -AdditionalItems @($trendingPosterItem)
Write-Log "Preparing featured hero artwork..."
$activeDesignHero = Get-DesignHeroAssets -HotRelease $activeHero
$designHero = $activeDesignHero

function Build-ForUser {
    param(
        [string]$Id,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode
    )

    $script:TautWeeklyResultErrorCategory = "tautulli-unavailable"
    $resolvedUserId = Resolve-TautulliUserId -Identifier $Id
    $user = Get-NewsletterUser -Id $resolvedUserId
    $recentAccess = Test-UserNeedsWelcome -State $accessState -UserId $user.UserId

    Write-Log "Loading history for $($user.FriendlyName) ($($user.UserId)); recent access: $recentAccess..."
    $history = Get-History -AfterDate $afterDate -BeforeDate $beforeDate -ForUserId $user.UserId
    $stats = Get-UserStats -History $history
    $recipientPlatform = Get-NewsletterPlatform -History $history -ExpectedUserId $user.UserId
    $recipientWatchedMovies = Get-RecipientWatchedMovies -ExpectedUserId $user.UserId
    if ($null -eq $recipientPlatform) {
        $recipientPlatform = Get-NewsletterLastPlatform -ExpectedUserId $user.UserId
    }
    Add-UserStatsMediaMetadata -Stats $stats

    $statsPosterItems = @()
    if ($null -ne $stats.PSObject.Properties["MovieItems"]) {
        $statsPosterItems += @($stats.MovieItems)
    }
    if ($null -ne $stats.PSObject.Properties["TvShowItems"]) {
        $statsPosterItems += @($stats.TvShowItems)
    }
    $statsPosterItems += @($trendingPosterItem)

    $script:TautWeeklyResultErrorCategory = "asset-unavailable"
    $userPosterAssets = Prepare-PosterAssets `
        -ReleaseData $activeReleaseData `
        -FeaturedRatingKey $featuredRatingKey `
        -HotRelease $activeHero `
        -QuietReleaseMode $isQuietReleaseWeek `
        -AdditionalItems $statsPosterItems

    $script:TautWeeklyResultErrorCategory = "render-failed"
    $html = Build-NewsletterHtml `
        -User $user `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -Stats $stats `
        -ReleaseData $activeReleaseData `
        -HotRelease $activeHero `
        -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -SystemWarmingUp $tautWeeklyState.IsWarmingUp `
        -RecentAccess $recentAccess `
        -WelcomeOnly $false `
        -QuietReleaseMode $isQuietReleaseWeek `
        -BingeChampion $bingeChampion `
        -RecipientPlatform $recipientPlatform `
        -PosterAssets $userPosterAssets `
        -ImageMode $ImageMode `
        -StartLabel $startLabel `
        -EndLabel $endLabel

    $plain = Build-PlainText `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -User $user `
        -Stats $stats `
        -ReleaseData $activeReleaseData `
        -HotRelease $activeHero `
        -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -SystemWarmingUp $tautWeeklyState.IsWarmingUp `
        -RecentAccess $recentAccess `
        -QuietReleaseMode $isQuietReleaseWeek `
        -BingeChampion $bingeChampion `
        -StartLabel $startLabel `
        -EndLabel $endLabel

    return [PSCustomObject]@{
        User         = $user
        Stats        = $stats
        RecentAccess = $recentAccess
        Html         = $html
        Plain        = $plain
        PosterAssets = $userPosterAssets
    }
}


function New-ZeroPreviewStats {
    return [PSCustomObject]@{
        MoviesWatched    = 0
        EpisodesStreamed = 0
        TotalSeconds     = [int64]0
        TotalTimeText    = "0m"
        MostWatched      = ""
        QualifyingPlays  = 0
        MovieItems       = @()
        EpisodeItems     = @()
        TvShowItems      = @()
    }
}

function Get-PopulatedPreviewStats {
    param([AllowNull()][object]$RealStats)

    $stats = if ($null -eq $RealStats) {
        New-ZeroPreviewStats
    } else {
        $RealStats
    }
    Add-UserStatsMediaMetadata -Stats $stats
    return [PSCustomObject]@{
        Stats    = $stats
        IsSample = $false
    }
}
function Build-AllEmailVariants {
    param(
        [string]$Id,
        [ValidateSet("Preview","Email")]
        [string]$ImageMode
    )

    $script:TautWeeklyResultErrorCategory = "tautulli-unavailable"
    $resolvedUserId = Resolve-TautulliUserId -Identifier $Id
    $user = Get-NewsletterUser -Id $resolvedUserId

    Write-Log "Loading real history for six-state email regression: $($user.FriendlyName)..."
    $recipientWatchedMovies = Get-RecipientWatchedMovies -ExpectedUserId $user.UserId
    $history = Get-History -AfterDate $afterDate -BeforeDate $beforeDate -ForUserId $user.UserId
    $realStats = Get-UserStats -History $history
    $recipientPlatform = Get-NewsletterPlatform -History $history -ExpectedUserId $user.UserId
    if ($null -eq $recipientPlatform) {
        $recipientPlatform = Get-NewsletterLastPlatform -ExpectedUserId $user.UserId
    }
    Add-UserStatsMediaMetadata -Stats $realStats
    $zeroStats = New-ZeroPreviewStats
    $populatedVariant = Get-PopulatedPreviewStats -RealStats $realStats
    Add-UserStatsMediaMetadata -Stats $populatedVariant.Stats

    $populatedPosterItems = @($trendingPosterItem)
    if ($null -ne $populatedVariant.Stats.PSObject.Properties["MovieItems"]) {
        $populatedPosterItems += @($populatedVariant.Stats.MovieItems)
    }
    if ($null -ne $populatedVariant.Stats.PSObject.Properties["TvShowItems"]) {
        $populatedPosterItems += @($populatedVariant.Stats.TvShowItems)
    }

    $script:TautWeeklyResultErrorCategory = "asset-unavailable"
    $populatedPosterAssets = Prepare-PosterAssets `
        -ReleaseData $activeReleaseData `
        -FeaturedRatingKey $featuredRatingKey `
        -HotRelease $activeHero `
        -QuietReleaseMode $isQuietReleaseWeek `
        -AdditionalItems $populatedPosterItems

    # Lifecycle variants share real release-state content; only their intro and
    # stats-state presentation differ.
    $oneOffPosterAssets = $activePosterAssets
    $oneOffDesignHero = $activeDesignHero
    $script:designHero = $oneOffDesignHero

    $script:TautWeeklyResultErrorCategory = "render-failed"
    $oneOffHtml = Build-NewsletterHtml `
        -User $user `
        -Stats $zeroStats `
        -ReleaseData $activeReleaseData `
        -HotRelease $activeHero `
        -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -SystemWarmingUp $false `
        -RecentAccess $true `
        -WelcomeOnly $true `
        -QuietReleaseMode $isQuietReleaseWeek `
        -BingeChampion $null `
        -RecipientPlatform $recipientPlatform `
        -PosterAssets $oneOffPosterAssets `
        -ImageMode $ImageMode `
        -StartLabel $startLabel `
        -EndLabel $endLabel

    $script:designHero = $activeDesignHero

    # 1) New user, first scheduled Friday, no viewing history:
    # onboarding replaces empty stats and no quiet/warm-up block appears.
    $newNoHistoryHtml = Build-NewsletterHtml `
        -User $user `
        -Stats $zeroStats `
        -ReleaseData $activeReleaseData `
        -HotRelease $activeHero `
        -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -SystemWarmingUp $false `
        -RecentAccess $true `
        -WelcomeOnly $false `
        -QuietReleaseMode $isQuietReleaseWeek `
        -BingeChampion $bingeChampion `
        -RecipientPlatform $recipientPlatform `
        -PosterAssets $activePosterAssets `
        -ImageMode $ImageMode `
        -StartLabel $startLabel `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -EndLabel $endLabel

    # 2) New user with activity: personalized stats are visible.
    $newWithHistoryHtml = Build-NewsletterHtml `
        -User $user `
        -Stats $populatedVariant.Stats `
        -ReleaseData $activeReleaseData `
        -HotRelease $activeHero `
        -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -SystemWarmingUp $false `
        -RecentAccess $true `
        -WelcomeOnly $false `
        -QuietReleaseMode $isQuietReleaseWeek `
        -BingeChampion $bingeChampion `
        -RecipientPlatform $recipientPlatform `
        -PosterAssets $populatedPosterAssets `
        -ImageMode $ImageMode `
        -StartLabel $startLabel `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -EndLabel $endLabel

    # 3) Established active user: always force a populated, non-warm-up state.
    # Empty selected-user history remains an authentic zero-activity state.
    $normalHtml = Build-NewsletterHtml `
        -User $user `
        -Stats $populatedVariant.Stats `
        -ReleaseData $activeReleaseData `
        -HotRelease $activeHero `
        -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -SystemWarmingUp $false `
        -RecentAccess $false `
        -WelcomeOnly $false `
        -QuietReleaseMode $isQuietReleaseWeek `
        -BingeChampion $bingeChampion `
        -RecipientPlatform $recipientPlatform `
        -PosterAssets $populatedPosterAssets `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -ImageMode $ImageMode `
        -StartLabel $startLabel `
        -EndLabel $endLabel

    # 4) Established user with zero activity after the initial warm-up period.
    $quietHtml = Build-NewsletterHtml `
        -User $user `
        -Stats $zeroStats `
        -ReleaseData $activeReleaseData `
        -HotRelease $activeHero `
        -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -SystemWarmingUp $false `
        -RecentAccess $false `
        -WelcomeOnly $false `
        -QuietReleaseMode $isQuietReleaseWeek `
        -BingeChampion $bingeChampion `
        -RecipientPlatform $recipientPlatform `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -PosterAssets $activePosterAssets `
        -ImageMode $ImageMode `
        -StartLabel $startLabel `
        -EndLabel $endLabel

    # 5) Established user with zero activity during TautWeekly for Plex's first 7 days.
    $warmupHtml = Build-NewsletterHtml `
        -User $user `
        -Stats $zeroStats `
        -ReleaseData $activeReleaseData `
        -HotRelease $activeHero `
        -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -SystemWarmingUp $true `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -RecentAccess $false `
        -WelcomeOnly $false `
        -QuietReleaseMode $isQuietReleaseWeek `
        -BingeChampion $bingeChampion `
        -RecipientPlatform $recipientPlatform `
        -PosterAssets $activePosterAssets `
        -ImageMode $ImageMode `
        -StartLabel $startLabel `
        -EndLabel $endLabel

    $oneOffPlain = Build-PlainText `
        -User $user -Stats $zeroStats -ReleaseData $activeReleaseData `
        -HotRelease $activeHero -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -SystemWarmingUp $false -RecentAccess $true `
        -QuietReleaseMode $isQuietReleaseWeek -BingeChampion $null `
        -WelcomeOnly $true `
        -StartLabel $startLabel -EndLabel $endLabel

    $newNoHistoryPlain = Build-PlainText `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -User $user -Stats $zeroStats -ReleaseData $activeReleaseData `
        -HotRelease $activeHero -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -SystemWarmingUp $false -RecentAccess $true `
        -QuietReleaseMode $isQuietReleaseWeek -BingeChampion $bingeChampion `
        -StartLabel $startLabel -EndLabel $endLabel

    $newWithHistoryPlain = Build-PlainText `
        -User $user -Stats $populatedVariant.Stats -ReleaseData $activeReleaseData `
        -HotRelease $activeHero -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -SystemWarmingUp $false -RecentAccess $true `
        -QuietReleaseMode $isQuietReleaseWeek -BingeChampion $bingeChampion `
        -StartLabel $startLabel -EndLabel $endLabel

    $normalPlain = Build-PlainText `
        -User $user -Stats $populatedVariant.Stats -ReleaseData $activeReleaseData `
        -HotRelease $activeHero -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -SystemWarmingUp $false -RecentAccess $false `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -QuietReleaseMode $isQuietReleaseWeek -BingeChampion $bingeChampion `
        -StartLabel $startLabel -EndLabel $endLabel

    $quietPlain = Build-PlainText `
        -User $user -Stats $zeroStats -ReleaseData $activeReleaseData `
        -HotRelease $activeHero -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -SystemWarmingUp $false -RecentAccess $false `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -QuietReleaseMode $isQuietReleaseWeek -BingeChampion $bingeChampion `
        -StartLabel $startLabel -EndLabel $endLabel

    $warmupPlain = Build-PlainText `
        -User $user -Stats $zeroStats -ReleaseData $activeReleaseData `
        -HotRelease $activeHero -TrendingTitle $trendingTitle -TopMovieGenre $topMovieGenre `
        -SystemWarmingUp $true -RecentAccess $false `
        -RecipientWatchedMovies $recipientWatchedMovies `
        -QuietReleaseMode $isQuietReleaseWeek -BingeChampion $bingeChampion `
        -StartLabel $startLabel -EndLabel $endLabel

    $oneOffSubject = Get-OneOffWelcomeSubject -User $user
    $newSubject = Get-NewsletterSubject -User $user -RecentAccess $true
    $normalSubject = Get-NewsletterSubject -User $user -RecentAccess $false
    $hasRealActivity = (Safe-Int64 $realStats.TotalSeconds) -gt 0
    $newWithHistoryLabel = if ($hasRealActivity) {
        "New user first scheduled newsletter — with history"
    } else {
        "New user first scheduled newsletter — no selected-user activity"
    }
    $normalLabel = if ($hasRealActivity) {
        "Established user — normal newsletter with activity"
    } else {
        "Established user — no selected-user activity"
    }

    return [PSCustomObject]@{
        User = $user
        RealStats = $realStats
        HasRealActivity = $hasRealActivity
        Variants = @(
            [PSCustomObject]@{
                Key="manual-welcome"
                Label="Manual one-off welcome"
                Subject=$oneOffSubject
                Html=$oneOffHtml
                Plain=$oneOffPlain
                PosterAssets=$oneOffPosterAssets
                HeroAssets=$oneOffDesignHero
            },
            [PSCustomObject]@{
                Key="new-scheduled-no-history"
                Label="New user first scheduled newsletter — no history"
                Subject=$newSubject
                Html=$newNoHistoryHtml
                Plain=$newNoHistoryPlain
                PosterAssets=$activePosterAssets
                HeroAssets=$activeDesignHero
            },
            [PSCustomObject]@{
                Key="new-scheduled-with-history"
                Label=$newWithHistoryLabel
                Subject=$newSubject
                Html=$newWithHistoryHtml
                Plain=$newWithHistoryPlain
                PosterAssets=$populatedPosterAssets
                HeroAssets=$activeDesignHero
            },
            [PSCustomObject]@{
                Key="normal-newsletter"
                Label=$normalLabel
                Subject=$normalSubject
                Html=$normalHtml
                Plain=$normalPlain
                PosterAssets=$populatedPosterAssets
                HeroAssets=$activeDesignHero
            },
            [PSCustomObject]@{
                Key="established-quiet"
                Label="Established user — quiet / no watch activity"
                Subject=$normalSubject
                Html=$quietHtml
                Plain=$quietPlain
                PosterAssets=$activePosterAssets
                HeroAssets=$activeDesignHero
            },
            [PSCustomObject]@{
                Key="established-warmup"
                Label="Established user — stats warming up"
                Subject=$normalSubject
                Html=$warmupHtml
                Plain=$warmupPlain
                PosterAssets=$activePosterAssets
                HeroAssets=$activeDesignHero
            }
        )
    }
}


# ---------------------------------------------------------------------------
# MODE: WARM DELETED-ITEM CACHE FOR EVERY ELIGIBLE RECIPIENT
# ---------------------------------------------------------------------------
if ($Mode -eq "CacheWarm") {
    $cacheStatus = Get-TautWeeklyDeletedItemCacheStatus
    if (-not $cacheStatus.Enabled) {
        throw "Deleted-item cache warm-up requires DeletedItemCacheEnabled=true."
    }
    if (-not $cacheStatus.Available) {
        throw "Deleted-item cache storage is unavailable for warm-up."
    }

    $script:TautWeeklyResultErrorCategory = "tautulli-unavailable"
    $names = @(Get-TautulliUserNames)
    $eligibleUsers = 0
    $failedUsers = 0
    $selectedItems = New-Object System.Collections.Generic.List[object]
    $seenItems = @{}

    foreach ($name in $names) {
        try {
            $user = Get-NewsletterUser -Id ([string]$name.user_id)
            if (-not [string]::IsNullOrWhiteSpace((Get-UserSkipReason -User $user))) {
                continue
            }

            $eligibleUsers++
            $history = Get-History -AfterDate $afterDate -BeforeDate $beforeDate -ForUserId $user.UserId
            $stats = Get-UserStats -History $history
            Add-UserStatsMediaMetadata -Stats $stats

            foreach ($item in @(@($stats.MovieItems) + @($stats.TvShowItems))) {
                if ($null -eq $item) { continue }
                $mediaType = if ((Get-OptionalStringProperty -InputObject $item -Name "Type") -eq "show") { "show" } else { "movie" }
                $metadataGuid = (Get-OptionalStringProperty -InputObject $item -Name "MetadataGuid").Trim().ToLowerInvariant()
                $ratingKey = (Get-OptionalStringProperty -InputObject $item -Name "PosterRatingKey").Trim()
                $identity = if (-not [string]::IsNullOrWhiteSpace($metadataGuid)) {
                    $mediaType + "|guid|" + $metadataGuid
                }
                elseif (-not [string]::IsNullOrWhiteSpace($ratingKey)) {
                    $mediaType + "|rating-key|" + $ratingKey
                }
                else { "" }
                if (-not [string]::IsNullOrWhiteSpace($identity) -and -not $seenItems.ContainsKey($identity)) {
                    $seenItems[$identity] = $true
                    $selectedItems.Add($item)
                }
            }
        }
        catch {
            $failedUsers++
            Write-Log "One included recipient could not be inspected during deleted-item cache warm-up." "WARN"
        }
    }

    $script:TautWeeklyResultErrorCategory = "asset-unavailable"
    if ($selectedItems.Count -gt 0) {
        [void](Prepare-PosterAssets `
            -ReleaseData ([PSCustomObject]@{ Movies = @(); TV = @() }) `
            -AdditionalItems $selectedItems.ToArray())
    }

    $cacheStatus = Get-TautWeeklyDeletedItemCacheStatus
    Write-Host ""
    Write-Host "TAUTWEEKLY DELETED-ITEM CACHE WARM-UP"
    Write-Host "------------------------------------"
    Write-Host ("Eligible users checked: {0}" -f $eligibleUsers)
    Write-Host ("Unique personal items:  {0}" -f $selectedItems.Count)
    Write-Host ("Retained cache entries: {0}" -f $cacheStatus.ItemCount)
    Write-Host "No email was sent and no recipient state was changed."

    if ($failedUsers -gt 0) {
        throw "Deleted-item cache warm-up could not inspect every included recipient."
    }
    Write-TautWeeklyStructuredResult -Outcome "succeeded"
    exit 0
}

# ---------------------------------------------------------------------------
# MODE: PREVIEW ALL EMAIL TYPES
# ---------------------------------------------------------------------------
if ($Mode -eq "PreviewAll") {
    if ([string]::IsNullOrWhiteSpace($UserId)) {
        throw "PreviewAll mode requires a user identifier. ListUsers only displays the roster; pass a numeric UserId from that table."
    }

    $bundle = Build-AllEmailVariants -Id $UserId -ImageMode "Preview"
    $script:TautWeeklyResultErrorCategory = "output-failed"
    $previewDir = $OutputDir

    $files = @(
        "preview-all-01-manual-welcome.html",
        "preview-all-02-new-user-no-history.html",
        "preview-all-03-new-user-with-history.html",
        "preview-all-04-normal-newsletter.html",
        "preview-all-05-established-quiet.html",
        "preview-all-06-established-warmup.html"
    )

    for ($i = 0; $i -lt $bundle.Variants.Count; $i++) {
        Set-Content -Path (Join-Path $previewDir $files[$i]) -Value $bundle.Variants[$i].Html -Encoding UTF8
        $script:TautWeeklyResultGeneratedPreviewFiles.Add($files[$i])
    }

    $serverName = HtmlEncode (Get-ConfiguredServerName)
    $userName = HtmlEncode $bundle.User.FriendlyName
    $historyNote = if ($bundle.HasRealActivity) {
        "Previews 03 and 04 use the selected user's real current-window watch statistics. Previews 05 and 06 intentionally force zero activity."
    } else {
        "The selected user has no activity in this window, so previews 03 and 04 render authentic no-history output without fictional viewing data. Previews 05 and 06 intentionally remain at zero activity."
    }

    $cards = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $bundle.Variants.Count; $i++) {
        $variant = $bundle.Variants[$i]
        [void]$cards.AppendLine('<div class="card">')
        [void]$cards.AppendLine('<div class="title">' + (HtmlEncode $variant.Label) + '</div>')
        [void]$cards.AppendLine('<div class="subject">Subject: ' + (HtmlEncode $variant.Subject) + '</div>')
        [void]$cards.AppendLine('<a class="btn" href="' + $files[$i] + '">Open preview</a>')
        [void]$cards.AppendLine('</div>')
    }

    $indexHtml = @"
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>TautWeekly for Plex — All Email Types</title>
<style>
body{margin:0;background-color:#0f0f0f;color:#fff;font-family:Arial,Helvetica,sans-serif;padding:32px 18px}.wrap{max-width:900px;margin:auto}.eyebrow{color:#e5a00d;font-size:12px;font-weight:800;letter-spacing:1.5px}.card{margin-top:14px;padding:18px 20px;background-color:#181818;border:1px solid #2b2b2b;border-radius:10px}.title{font-size:18px;font-weight:800}.subject{color:#aaa;margin-top:7px;font-size:13px;line-height:1.45}.btn{display:inline-block;margin-top:13px;background-color:#e5a00d;color:#111;text-decoration:none;font-weight:800;padding:10px 15px;border-radius:7px}.note{margin-top:20px;color:#999;font-size:12px;line-height:1.55;border-left:3px solid #e5a00d;padding-left:12px}.meta{color:#888;font-size:13px;line-height:1.55;margin-top:8px}
</style></head><body><div class="wrap">
<div class="eyebrow">TAUTWEEKLY FOR PLEX — ALL EMAIL TYPES</div>
<h1 style="margin:8px 0 0;font-size:30px;">The real email layout, across every state.</h1>
<div class="meta">Go ahead, shrink my window.<br>Server / selected recipient: $serverName · $userName<br>Window: $(HtmlEncode $startLabel) – $(HtmlEncode $endLabel)<br>Release mode: $(if ($isQuietReleaseWeek) { 'TRENDING / RECENT MOVIES' } else { 'NORMAL / NEW RELEASES' })</div>
$($cards.ToString())
<div class="note">$(HtmlEncode $historyNote)</div>
<div class="note">Local HTML only. No email was sent. No welcome timestamp was written. Resize a preview below 620px to inspect the mobile hero.</div>
</div></body></html>
"@

    $indexPath = Join-Path $previewDir "preview-all-00-INDEX.html"
    Set-Content -Path $indexPath -Value $indexHtml -Encoding UTF8
    $script:TautWeeklyResultGeneratedPreviewFiles.Add("preview-all-00-INDEX.html")

    Write-Host ""
    Write-Host "Created all-email-type preview: $indexPath" -ForegroundColor Green
    Write-Host "No email was sent and access-state.json was not modified by this mode."
    $publicUrl = Get-PreviewPublicUrl -Path $indexPath
    if (-not [string]::IsNullOrWhiteSpace($publicUrl)) {
        Write-Host "Browser URL: $publicUrl" -ForegroundColor Cyan
    }
    Write-TautWeeklyStructuredResult -Outcome "succeeded"
    exit 0
}

# ---------------------------------------------------------------------------
# MODE: SEND ALL EMAIL TYPES TO TESTEMAIL ONLY
# ---------------------------------------------------------------------------
if ($Mode -eq "SendTestAll") {
    if ([string]::IsNullOrWhiteSpace($UserId)) {
        throw "SendTestAll mode requires a user identifier. ListUsers only displays the roster; pass a numeric UserId from that table."
    }
    Require-ConfigValue "TestEmail"

    $bundle = Build-AllEmailVariants -Id $UserId -ImageMode "Email"
    $script:TautWeeklyResultErrorCategory = "smtp-failed"
    $delaySeconds = 10
    if ($null -ne $Config.PSObject.Properties["TestSendDelaySeconds"]) {
        $delaySeconds = [Math]::Max(0, (Safe-Int $Config.TestSendDelaySeconds))
    }

    for ($i = 0; $i -lt $bundle.Variants.Count; $i++) {
        $variant = $bundle.Variants[$i]
        $testSubject = "[TautWeekly for Plex TEST $($i + 1)/$($bundle.Variants.Count)] $($variant.Subject)"
        Write-Log "Sending $($variant.Label) test to $($Config.TestEmail)..."
        Send-NewsletterMail `
            -To ([string]$Config.TestEmail) `
            -Subject $testSubject `
            -Html $variant.Html `
            -PlainText $variant.Plain `
            -PosterAssets $variant.PosterAssets `
            -HeroAssets $variant.HeroAssets

        $script:TautWeeklyResultSmtpAcceptedCount++

        if ($delaySeconds -gt 0 -and $i -lt ($bundle.Variants.Count - 1)) {
            Start-Sleep -Seconds $delaySeconds
        }
    }

    Write-Log "All six email-state tests were sent to TestEmail only."
    Write-TautWeeklyStructuredResult -Outcome "succeeded"
    exit 0
}

# ---------------------------------------------------------------------------
# MODE: PREVIEW
# ---------------------------------------------------------------------------
if ($Mode -eq "Preview") {
    if ([string]::IsNullOrWhiteSpace($UserId)) {
        throw "Preview mode requires a user identifier. ListUsers only displays the roster; pass a numeric UserId from that table."
    }

    $result = Build-ForUser -Id $UserId -ImageMode "Preview"
    $script:TautWeeklyResultErrorCategory = "output-failed"
    $safeName = Get-SafeFilePart $result.User.FriendlyName
    $previewPath = Join-Path $OutputDir ("preview_{0}.html" -f $safeName)
    Set-Content -Path $previewPath -Value $result.Html -Encoding UTF8
    $script:TautWeeklyResultGeneratedPreviewFiles.Add([IO.Path]::GetFileName($previewPath))

    Write-Host ""
    Write-Host "TAUTWEEKLY FOR PLEX PREVIEW"
    Write-Host "------------------"
    Write-Host ("User:              {0}" -f $result.User.FriendlyName)
    Write-Host ("Release mode:      {0}" -f $(if ($isQuietReleaseWeek) { "QUIET" } else { "NORMAL" }))
    Write-Host ("Movies watched:    {0}" -f $result.Stats.MoviesWatched)
    Write-Host ("Episodes streamed: {0}" -f $result.Stats.EpisodesStreamed)
    Write-Host ("Watch time:        {0}" -f $result.Stats.TotalTimeText)
    Write-Host ("Recent access:     {0}" -f $result.RecentAccess)
    Write-Host ""
    Write-Host "Preview created: $previewPath"
    $publicUrl = Get-PreviewPublicUrl -Path $previewPath
    if (-not [string]::IsNullOrWhiteSpace($publicUrl)) {
        Write-Host "Browser URL: $publicUrl" -ForegroundColor Cyan
    }
    Write-TautWeeklyStructuredResult -Outcome "succeeded"
    exit 0
}

# ---------------------------------------------------------------------------
# MODE: SEND TEST
# ---------------------------------------------------------------------------
if ($Mode -eq "SendTest") {
    if ([string]::IsNullOrWhiteSpace($UserId)) {
        throw "SendTest mode requires a user identifier. ListUsers only displays the roster; pass a numeric UserId from that table."
    }
    Require-ConfigValue "TestEmail"

    $result = Build-ForUser -Id $UserId -ImageMode "Email"
    $script:TautWeeklyResultErrorCategory = "smtp-failed"
    $subject = Get-NewsletterSubject -User $result.User -RecentAccess $result.RecentAccess

    Write-Log "Sending TEST version for $($result.User.FriendlyName) to $($Config.TestEmail)..."
    Send-NewsletterMail `
        -To ([string]$Config.TestEmail) `
        -Subject $subject `
        -Html $result.Html `
        -PlainText $result.Plain `
        -PosterAssets $result.PosterAssets `
        -HeroAssets $activeDesignHero

    $script:TautWeeklyResultSmtpAcceptedCount = 1
    Write-Log "Test email sent successfully."
    Write-TautWeeklyStructuredResult -Outcome "succeeded"
    exit 0
}

# ---------------------------------------------------------------------------
# MODE: SEND ALL
# ---------------------------------------------------------------------------
if ($Mode -eq "SendAll") {
    $script:TautWeeklyResultErrorCategory = "tautulli-unavailable"
    $names = @(Get-TautulliUserNames)
    $sent = 0
    $skipped = 0
    $failed = 0
    $deliveryFailureCategory = ""
    $sendDelay = 30
    if ($null -ne $Config.PSObject.Properties["SendDelaySeconds"]) {
        $sendDelay = [Math]::Max(0, (Safe-Int $Config.SendDelaySeconds))
    }

    for ($recipientIndex = 0; $recipientIndex -lt $names.Count; $recipientIndex++) {
        $n = $names[$recipientIndex]
        $attemptedSmtp = $false
        try {
            $user = Get-NewsletterUser -Id ([string]$n.user_id)

            $skipReason = Get-UserSkipReason -User $user
            if (-not [string]::IsNullOrWhiteSpace($skipReason)) {
                Write-Log "Skipping one production recipient: $skipReason."
                $skipped++
                $script:TautWeeklyResultSkippedCount = $skipped
                $script:TautWeeklyResultSkipReasons[$skipReason]++
                continue
            }

            $script:TautWeeklyResultErrorCategory = "render-failed"
            $result = Build-ForUser -Id $user.UserId -ImageMode "Email"
            $subject = Get-NewsletterSubject -User $result.User -RecentAccess $result.RecentAccess

            $script:TautWeeklyResultErrorCategory = "smtp-failed"
            Write-Log "Sending to $($result.User.FriendlyName) <$($result.User.DeliveryEmail)>..."
            $attemptedSmtp = $true
            Send-NewsletterMail `
                -To $result.User.DeliveryEmail `
                -Subject $subject `
                -Html $result.Html `
                -PlainText $result.Plain `
                -PosterAssets $result.PosterAssets `
                -HeroAssets $activeDesignHero

            if ($result.RecentAccess) {
                Mark-UserWelcomed -State $accessState -UserId $result.User.UserId
            }

            $sent++
            $script:TautWeeklyResultSmtpAcceptedCount = $sent
        }
        catch {
            $failed++
            $script:TautWeeklyResultFailedCount = $failed
            $smtpFailure = Get-TautWeeklySmtpFailureEvidence -Exception $_.Exception
            if ($null -ne $smtpFailure) {
                $script:TautWeeklyResultSmtpFailure = $smtpFailure
                $script:TautWeeklyResultErrorCategory = [string]$smtpFailure.category
                $deliveryFailureCategory = [string]$smtpFailure.category
                Write-Log ("SMTP recipient attempt stopped safely ({0}, stage {1}, response {2})." -f $smtpFailure.category, $smtpFailure.stage, $smtpFailure.responseCode) "ERROR"
                if ([bool]$smtpFailure.batchFatal) {
                    Write-Log "Stopping the production batch before another SMTP connection or recipient attempt." "ERROR"
                    break
                }
            }
            else {
                if ([string]::IsNullOrWhiteSpace($deliveryFailureCategory)) {
                    $deliveryFailureCategory = [string]$script:TautWeeklyResultErrorCategory
                }
                Write-Log "One production recipient failed before SMTP acceptance." "ERROR"
            }
        }

        if ($attemptedSmtp -and $sendDelay -gt 0 -and $recipientIndex -lt ($names.Count - 1)) {
            Write-Log "Pausing $sendDelay seconds before the next recipient attempt..."
            Start-Sleep -Seconds $sendDelay
        }
    }

    Write-Host ""
    Write-Host "Finished."
    Write-Host ("Sent:    {0}" -f $sent)
    Write-Host ("Skipped: {0}" -f $skipped)
    Write-Host ("Failed:  {0}" -f $failed)

    if ($failed -gt 0) {
        if (-not [string]::IsNullOrWhiteSpace($deliveryFailureCategory)) {
            $script:TautWeeklyResultErrorCategory = $deliveryFailureCategory
        }
        Write-TautWeeklyStructuredResult -Outcome $(if ($sent -gt 0) { "partial" } else { "failed" })
        exit 2
    }
    if ($sent -eq 0) {
        $script:TautWeeklyResultErrorCategory = "no-eligible-recipients"
        Write-TautWeeklyStructuredResult -Outcome "failed"
        exit 3
    }
    Write-TautWeeklyStructuredResult -Outcome "succeeded"
    exit 0
}

throw "Unsupported mode: $Mode"
