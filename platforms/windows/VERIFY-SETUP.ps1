Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$configPath = Join-Path $root "config.json"
$assetsDir = Join-Path $root "assets"
. (Join-Path $root "Library-Selection.ps1")

function OK([string]$Text) { Write-Host "[OK]   $Text" -ForegroundColor Green }
function WARN([string]$Text) { Write-Host "[WARN] $Text" -ForegroundColor Yellow }
function FAIL([string]$Text) { Write-Host "[FAIL] $Text" -ForegroundColor Red }

Write-Host ""
Write-Host "TAUTWEEKLY FOR PLEX SETUP VERIFICATION" -ForegroundColor Cyan
Write-Host "=============================="

if ($PSVersionTable.PSVersion -lt [Version]"5.1") {
    FAIL "Windows PowerShell 5.1 or newer is required. Found $($PSVersionTable.PSVersion)."
    exit 1
}
OK "PowerShell $($PSVersionTable.PSVersion)"

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    FAIL "This distribution is designed for Windows. The BAT files and Task Scheduler integration are Windows-only."
    exit 1
}
OK "Windows operating system detected"

$scheduledTaskCommands = @(
    "New-ScheduledTaskAction", "New-ScheduledTaskTrigger",
    "New-ScheduledTaskSettingsSet", "New-ScheduledTaskPrincipal",
    "Register-ScheduledTask", "Get-ScheduledTask"
)
$missingTaskCommands = @($scheduledTaskCommands | Where-Object { $null -eq (Get-Command $_ -ErrorAction SilentlyContinue) })
if ($missingTaskCommands.Count -gt 0) {
    WARN ("Windows ScheduledTasks cmdlets are unavailable: " + ($missingTaskCommands -join ", "))
    WARN "Manual preview/test/send modes can still work, but Manager Schedule and 08-INSTALL-SCHEDULE.bat will not."
}
else {
    OK "Windows ScheduledTasks cmdlets are available"
}

if (-not (Test-Path $configPath)) {
    FAIL "config.json is missing. Open Manager Config and save a valid configuration, or use 00-SETUP-FIRST.bat as the portable fallback."
    exit 1
}
OK "config.json exists"

try {
    $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    FAIL "config.json is not valid JSON: $($_.Exception.Message)"
    exit 1
}
OK "config.json parses correctly"

try {
    $configAcl = Get-Acl -Path $configPath
    if ($configAcl.AreAccessRulesProtected) {
        OK "config.json is not inheriting broad folder permissions"
    }
    else {
        WARN "config.json still inherits folder permissions. Because it contains credentials, consider restricting the file ACL."
    }
}
catch {
    WARN "Could not inspect config.json permissions: $($_.Exception.Message)"
}

function Get-Prop([string]$Name) {
    $p = $config.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

foreach ($prop in @("TautulliUrl","ApiKey","FromName","FromEmail","SmtpHost","SmtpPort","TestEmail")) {
    $value = Get-Prop $prop
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value) -or [string]$value -match '^PASTE_') {
        FAIL "$prop is missing or still contains a placeholder."
        exit 1
    }
}
OK "Required configuration values are populated"

if ([string]$config.SmtpHost -ieq "smtp.example.com" -or
    [string]$config.FromEmail -match '@example\.com$' -or
    [string]$config.TestEmail -match '@example\.com$') {
    FAIL "config.json still contains example.com placeholder mail settings. Open Manager Config and save real settings, or use 00-SETUP-FIRST.bat as the portable fallback."
    exit 1
}
OK "Example mail placeholders have been replaced"

# Validate email addresses syntactically.
foreach ($emailProp in @("FromEmail","TestEmail","ReplyToEmail")) {
    $value = [string](Get-Prop $emailProp)
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    try { [void](New-Object System.Net.Mail.MailAddress($value)) }
    catch {
        FAIL "$emailProp is not a valid email address: $value"
        exit 1
    }
}
OK "Configured email addresses are syntactically valid"

$userEmailOverrides = Get-Prop "UserEmailOverrides"
if ($null -ne $userEmailOverrides) {
    $overrideEntries = @($userEmailOverrides.PSObject.Properties)
    if ($overrideEntries.Count -gt 2000) { FAIL "UserEmailOverrides contains more than 2000 assignments."; exit 1 }
    foreach ($entry in $overrideEntries) {
        $id = ([string]$entry.Name).Trim()
        $address = if ($entry.Value -is [string]) { ([string]$entry.Value).Trim() } else { "" }
        [UInt64]$parsedUserId = 0
        if ($id -notmatch '^\d{1,20}$' -or -not [UInt64]::TryParse($id, [ref]$parsedUserId) -or $entry.Value -isnot [string] -or $address.Length -gt 254) {
            FAIL "UserEmailOverrides contains an invalid user ID or address value."
            exit 1
        }
        if ([string]::IsNullOrWhiteSpace($address)) { continue }
        try {
            $parsed = New-Object System.Net.Mail.MailAddress($address)
            if ([string]$parsed.Address -cne $address) { throw "address normalization mismatch" }
        }
        catch { FAIL "UserEmailOverrides contains an invalid delivery address."; exit 1 }
    }
}
OK "Managed-user delivery addresses are valid"

$smtpAuth = $true
if ($null -ne $config.PSObject.Properties["SmtpUseAuthentication"]) {
    $smtpAuth = [bool]$config.SmtpUseAuthentication
}
if ($smtpAuth) {
    if ([string]::IsNullOrWhiteSpace([string](Get-Prop "SmtpUsername"))) {
        FAIL "SmtpUseAuthentication=true but SmtpUsername is blank."
        exit 1
    }
    $password = [string](Get-Prop "SmtpPassword")
    if ([string]::IsNullOrWhiteSpace($password)) {
        # Backward compatibility with older private TautWeekly for Plex configs.
        $password = [string](Get-Prop "SmtpAppPassword")
    }
    if ([string]::IsNullOrWhiteSpace($password) -or $password -match '^PASTE_') {
        FAIL "SMTP authentication is enabled but no SMTP password is configured."
        exit 1
    }
    OK "SMTP authentication credentials are configured"
}
else {
    OK "SMTP authentication is disabled by configuration"
}

# Tautulli API verification.
try {
    $base = ([string]$config.TautulliUrl).TrimEnd('/')
    $key = [Uri]::EscapeDataString([string]$config.ApiKey)
    $infoUri = "$base/api/v2?apikey=$key&cmd=get_tautulli_info"
    $infoResponse = Invoke-RestMethod -Uri $infoUri -Method Get -TimeoutSec 20
    if ([string]$infoResponse.response.result -ne "success") { throw $infoResponse.response.message }
    $version = [string]$infoResponse.response.data.tautulli_version
    if ([string]::IsNullOrWhiteSpace($version)) { $version = "version not reported" }
    OK "Tautulli API works ($version)"

    $usersUri = "$base/api/v2?apikey=$key&cmd=get_user_names"
    $usersResponse = Invoke-RestMethod -Uri $usersUri -Method Get -TimeoutSec 20
    if ([string]$usersResponse.response.result -ne "success") { throw $usersResponse.response.message }
    $userCount = @($usersResponse.response.data).Count
    OK "Tautulli user lookup works ($userCount users found)"

    $libraries = @(Get-TautWeeklySelectableLibraries -TautulliUrl $base -ApiKey ([string]$config.ApiKey))
    $selectableLibraries = @($libraries | Where-Object { $_.Selectable })
    if ($selectableLibraries.Count -eq 0) {
        FAIL "Tautulli did not report any active movie or TV libraries."
        exit 1
    }
    $configuredLibraryIds = @()
    if ($null -ne $config.PSObject.Properties["IncludedLibraryIds"]) {
        $configuredLibraryIds = @(Get-TautWeeklyUniqueLibraryIds -Values @($config.IncludedLibraryIds))
    }
    if ($configuredLibraryIds.Count -eq 0) {
        WARN "IncludedLibraryIds is empty or absent; legacy all-library scope is active ($($selectableLibraries.Count) libraries)."
    }
    else {
        $availableIds = @($selectableLibraries | ForEach-Object { $_.SectionId })
        $matchedIds = @($configuredLibraryIds | Where-Object { $availableIds -contains $_ })
        $staleIds = @($configuredLibraryIds | Where-Object { $availableIds -notcontains $_ })
        if ($matchedIds.Count -eq 0) {
            FAIL "None of the configured IncludedLibraryIds match an active movie or TV library. Run 15-MANAGE-LIBRARIES.bat."
            exit 1
        }
        OK "Global library scope matches $($matchedIds.Count) active movie/TV libraries"
        if ($staleIds.Count -gt 0) { WARN ("Configured library IDs no longer available: " + ($staleIds -join ", ")) }
    }

    # Verify the Tautulli build advertises the core API commands this newsletter
    # relies on. Older/unusual builds can otherwise pass a basic connectivity
    # test and fail only when previewing. The docs endpoint is itself optional,
    # so inability to query it is a warning rather than a hard failure.
    try {
        $docsUri = "$base/api/v2?apikey=$key&cmd=docs"
        $docsResponse = Invoke-RestMethod -Uri $docsUri -Method Get -TimeoutSec 20
        if ([string]$docsResponse.response.result -eq "success" -and $null -ne $docsResponse.response.data) {
            $requiredCommands = @(
                "get_users", "get_user", "get_history", "get_recently_added", "get_libraries",
                "get_metadata", "get_children_metadata", "get_user_names", "pms_image_proxy"
            )
            $availableCommands = @($docsResponse.response.data.PSObject.Properties.Name)
            $missingCommands = @($requiredCommands | Where-Object { $availableCommands -notcontains $_ })
            if ($missingCommands.Count -gt 0) {
                FAIL ("Tautulli API is missing required command(s): " + ($missingCommands -join ", "))
                exit 1
            }
            OK "Tautulli exposes the core API commands TautWeekly for Plex requires"
        }
        else {
            WARN "Tautulli API docs command did not return a command list; functional preview will be the final compatibility test."
        }
    }
    catch {
        WARN "Could not query Tautulli's API command list; functional preview will be the final compatibility test."
    }

    try {
        $serverUri = "$base/api/v2?apikey=$key&cmd=get_server_info"
        $serverResponse = Invoke-RestMethod -Uri $serverUri -Method Get -TimeoutSec 20
        if ([string]$serverResponse.response.result -eq "success") {
            $pmsUrl = [string]$serverResponse.response.data.pms_url
            if (-not [string]::IsNullOrWhiteSpace($pmsUrl)) {
                OK "Tautulli reports Plex server URL: $pmsUrl"
            }
        }
    }
    catch { WARN "Could not read Plex server information from Tautulli. Core newsletter features can still work." }
}
catch {
    FAIL "Tautulli API verification failed: $($_.Exception.Message)"
    exit 1
}

# Exercise the same direct-Plex discovery and request path used by preview and
# delivery. The child process receives only the private config path; the token
# stays in config/headers and is never placed on the command line or printed.
$plexVerifier = Join-Path $root "TautWeekly.ps1"
$plexHost = Join-Path $PSHOME "powershell.exe"
& $plexHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File $plexVerifier -Mode VerifyPlex -ConfigPath $configPath
$directPlexExit = $LASTEXITCODE
if ($directPlexExit -eq 3) {
    WARN "Direct Plex is not configured or discoverable. Core Tautulli operation remains available, but complete movie RT critic/audience ratings, exact-episode IMDb/RT ratings, backgrounds, and selected logos may be unavailable."
}
elseif ($directPlexExit -ne 0) {
    FAIL "Direct Plex verification failed. Correct the private Plex URL/token or its runtime connectivity before Preview or SendTest."
    exit 1
}
else {
    OK "Direct Plex identity and authenticated library requests succeeded"
    Write-Host "[INFO] Reachability does not select a movie rating provider or prove metadata freshness."
    Write-Host "[INFO] Before ratings/artwork acceptance, confirm each included Plex Movie library's Advanced > Ratings Source (use Ratings Source > Rotten Tomatoes when RT output is intended), run Plex Refresh All Metadata for every included movie/TV library, then use Tautulli Library > Media Info > Refresh media info for each same library."
}

# SMTP network reachability only. Authentication is tested by 04-SEND-TEST.bat.
try {
    $smtpPort = [int]$config.SmtpPort
    if ($smtpPort -lt 1 -or $smtpPort -gt 65535) { throw "Port is outside 1-65535." }
    if ($smtpPort -eq 465) {
        throw "Port 465 uses implicit SMTPS, which this System.Net.Mail.SmtpClient engine does not support. Use a STARTTLS port such as 587 when your provider offers it."
    }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect([string]$config.SmtpHost, $smtpPort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(5000, $false)) {
            throw "Connection timed out after 5 seconds."
        }
        $client.EndConnect($async)
    }
    finally { $client.Dispose() }
    OK "SMTP host is reachable at $($config.SmtpHost):$smtpPort"
    WARN "SMTP authentication and sender authorization are not tested by verify. Run SendTest with a numeric UserId before enabling the schedule."
}
catch {
    FAIL "Cannot reach SMTP server $($config.SmtpHost):$($config.SmtpPort): $($_.Exception.Message)"
    exit 1
}

# Validate schedule settings.
$validDays = @("Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday")
$day = [string](Get-Prop "ScheduleDay")
if ([string]::IsNullOrWhiteSpace($day)) { $day = "Friday" }
if (-not ($validDays | Where-Object { $_ -ieq $day })) {
    FAIL "ScheduleDay '$day' is invalid."
    exit 1
}
$time = [string](Get-Prop "ScheduleTime")
if ([string]::IsNullOrWhiteSpace($time)) { $time = "09:30" }
$parsedTime = [DateTime]::MinValue
if (-not [DateTime]::TryParseExact($time, "HH:mm", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedTime)) {
    FAIL "ScheduleTime '$time' must use HH:mm (24-hour) format."
    exit 1
}
OK "Schedule setting is $day at $time local Windows time"

# Validate image assets.
try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop }
catch {
    FAIL "System.Drawing is unavailable. This Windows build needs it for GIF/logo inspection."
    exit 1
}

function Get-Frames([string]$Path) {
    if (-not (Test-Path $Path)) { return 0 }
    $img = $null
    try {
        $img = [System.Drawing.Image]::FromFile($Path)
        if ($img.FrameDimensionsList.Count -eq 0) { return 1 }
        $dim = New-Object System.Drawing.Imaging.FrameDimension($img.FrameDimensionsList[0])
        return $img.GetFrameCount($dim)
    }
    catch { return 0 }
    finally { if ($null -ne $img) { $img.Dispose() } }
}

$animated = @(
    "movies.gif","tv.gif","clock.gif","trophy.gif","hot.gif","trending.gif",
    "pending.gif","quiet.gif","welcome.gif","action.gif","watched.gif",
    "lockinfo.gif","watchlist.gif","popcorn.gif",
    "genre-action.gif","genre-comedy.gif","genre-crime.gif","genre-drama.gif","genre-fantasy.gif","genre-horror.gif","genre-musical.gif","genre-mystery.gif","genre-romance.gif","genre-scifi.gif","genre-thriller.gif","genre-western.gif"
)
$assetFailure = $false
foreach ($name in $animated) {
    $path = Join-Path $assetsDir $name
    $frames = Get-Frames $path
    if ($frames -gt 1) { OK "$name is animated ($frames frames)" }
    elseif ($frames -eq 1) { FAIL "$name is static; expected an animated GIF"; $assetFailure = $true }
    else { FAIL "$name is missing or unreadable"; $assetFailure = $true }
}

$staticAssets = @("rt_ripe.png","rt_rotten.png","rt_upright.png","rt_spilled.png","imdb.png")
foreach ($name in $staticAssets) {
    $path = Join-Path $assetsDir $name
    if (-not (Test-Path $path) -or (Get-Item $path).Length -lt 100) {
        FAIL "$name is missing or invalid"
        $assetFailure = $true
    }
    else { OK "$name is present" }
}

if ($assetFailure) {
    Write-Host ""
    WARN "Run REPAIR-MOVIE-TV-ASSETS.bat to restore canonical animations, or re-extract this ZIP for other missing assets."
    exit 1
}

Write-Host ""
OK "TautWeekly for Plex Portable is ready for browser preview and test email."
Write-Host ""
Write-Host "NEXT SAFE STEPS:" -ForegroundColor Cyan
Write-Host "  02-LIST-USERS.bat"
Write-Host "  03-PREVIEW-NEWSLETTER.bat"
Write-Host "  05-PREVIEW-ALL-EMAIL-TYPES.bat"
Write-Host "  04-SEND-TEST.bat"
Write-Host "  06-SEND-TEST-ALL-EMAIL-TYPES.bat"
