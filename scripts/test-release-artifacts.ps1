[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$DistPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
if ([string]::IsNullOrWhiteSpace($DistPath)) { $DistPath = Join-Path $Root 'dist' }
$DistPath = [IO.Path]::GetFullPath($DistPath)

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Test-UnixTextReleasePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $normalized = $RelativePath.Replace('\','/')
    $name = [IO.Path]::GetFileName($normalized)
    $extension = [IO.Path]::GetExtension($name).ToLowerInvariant()
    return $extension -in @('.sh','.command','.ps1','.psm1','.yml','.yaml','.json','.md','.html','.css','.js','.py','.txt','.xml','.service','.example') -or
        $name -in @('Dockerfile','.dockerignore','LICENSE','tautweekly')
}

function Get-ZipEntrySha256([IO.Compression.ZipArchiveEntry]$Entry) {
    $stream = $Entry.Open()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Get-ZipEntryBytes([IO.Compression.ZipArchiveEntry]$Entry) {
    $stream = $Entry.Open()
    $memory = New-Object IO.MemoryStream
    try {
        $stream.CopyTo($memory)
        return $memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $stream.Dispose()
    }
}
function Assert-WatchedPngBytes([string]$PackageName, [string]$AssetName, [byte[]]$Bytes, [hashtable]$Expected) {
    Assert-True ($Bytes.Length -gt 25 -and
        [BitConverter]::ToString($Bytes, 0, 8) -eq '89-50-4E-47-0D-0A-1A-0A') "$PackageName $AssetName is not a PNG."
    $width = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($Bytes, 16))
    $height = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($Bytes, 20))
    Assert-True ($width -eq $Expected.Width -and $height -eq $Expected.Height) "$PackageName $AssetName has wrong dimensions."
    Assert-True ($Bytes[24] -eq 8 -and $Bytes[25] -eq 6) "$PackageName $AssetName is not 8-bit RGBA with transparency."
}

function Assert-WindowsManagerSocialJpeg([string]$PackageName, [byte[]]$Bytes) {
    Assert-True ($Bytes.Length -gt 4 -and $Bytes[0] -eq 0xff -and $Bytes[1] -eq 0xd8 -and
        $Bytes[$Bytes.Length - 2] -eq 0xff -and $Bytes[$Bytes.Length - 1] -eq 0xd9) "$PackageName Manager social preview is not a complete JPEG."
    $width = 0
    $height = 0
    $offset = 2
    $frameMarkers = @(0xc0,0xc1,0xc2,0xc3,0xc5,0xc6,0xc7,0xc9,0xca,0xcb,0xcd,0xce,0xcf)
    while ($offset -lt $Bytes.Length) {
        Assert-True ($Bytes[$offset] -eq 0xff) "$PackageName Manager social preview has an invalid JPEG marker."
        while ($offset -lt $Bytes.Length -and $Bytes[$offset] -eq 0xff) { $offset++ }
        Assert-True ($offset -lt $Bytes.Length) "$PackageName Manager social preview has a truncated JPEG marker."
        $marker = [int]$Bytes[$offset]
        $offset++
        if ($marker -eq 0xd9 -or $marker -eq 0xda) { break }
        if ($marker -eq 0x01 -or ($marker -ge 0xd0 -and $marker -le 0xd7)) { continue }
        Assert-True ($offset + 1 -lt $Bytes.Length) "$PackageName Manager social preview has a truncated JPEG segment."
        $length = ([int]$Bytes[$offset] * 256) + [int]$Bytes[$offset + 1]
        Assert-True ($length -ge 2 -and $offset + $length -le $Bytes.Length) "$PackageName Manager social preview has an invalid JPEG segment length."
        if ($frameMarkers -contains $marker) {
            Assert-True ($length -ge 7) "$PackageName Manager social preview has a truncated frame header."
            $height = ([int]$Bytes[$offset + 3] * 256) + [int]$Bytes[$offset + 4]
            $width = ([int]$Bytes[$offset + 5] * 256) + [int]$Bytes[$offset + 6]
        }
        $offset += $length
    }
    Assert-True ($width -eq 1280 -and $height -eq 640) "$PackageName Manager social preview has wrong dimensions: ${width}x${height}."
    $ascii = [Text.Encoding]::ASCII.GetString($Bytes)
    Assert-True ($ascii -notmatch 'Exif|Photoshop 3[.]0|ns[.]adobe[.]com/xap') "$PackageName Manager social preview retains editor or EXIF/XMP metadata."
}


function Assert-RendererContract([string]$PackageName, [string]$Renderer) {
    Assert-True ($Renderer.Contains('[string]$ResultPath = ""')) "$PackageName lacks the Manager structured-result path."
    Assert-True ($Renderer.Contains('function Write-TautWeeklyStructuredResult')) "$PackageName lacks the Manager structured-result writer."
    Assert-True ($Renderer.Contains('generatedPreviewFiles = $safePreviewFiles')) "$PackageName lacks sanitized Manager preview results."
    Assert-True ($Renderer.Contains('errorCategory')) "$PackageName lacks a sanitized renderer failure category."
    Assert-True ($Renderer.Contains('$script:TautWeeklyResultErrorCategory = "tautulli-unavailable"')) "$PackageName lacks the fixed Tautulli failure stage."
    Assert-True ($Renderer.Contains('$script:TautWeeklyResultErrorCategory = "output-failed"')) "$PackageName lacks the fixed preview-output failure stage."
    Assert-True ($Renderer.Contains('Get-OptionalStringProperty -InputObject $Row -Name "section_id"')) "$PackageName lacks the executable library predicate fix."
    Assert-True ($Renderer.Contains('function Get-NewsletterPlatformCatalog')) "$PackageName lacks the conservative newsletter platform catalog."
    Assert-True ($Renderer.Contains('function Get-NewsletterPlatform')) "$PackageName lacks grouped-play platform ranking."
    Assert-True ($Renderer.Contains('-ExpectedUserId $user.UserId')) "$PackageName does not constrain platform selection to the intended recipient."
    Assert-True ($Renderer.Contains('@{ Expression = { $_.Latest }; Descending = $true }')) "$PackageName lacks the most-recent platform tie-break."
    Assert-True ($Renderer.Contains('function Get-NewsletterPlatformHeadingHtml')) "$PackageName lacks the accessible weekly-heading platform renderer."
    Assert-True ($Renderer.Contains('width="21" height="21"') -and $Renderer.Contains('max-height:21px')) "$PackageName does not enforce the 21px platform icon maximum."
    Assert-True ($Renderer.Contains('MediaType = "image/png"') -and $Renderer.Contains('Get-NewsletterPlatformCatalog')) "$PackageName does not embed local PNG platform resources."
    Assert-True ($Renderer.Contains('$params.section_id = $sectionId')) "$PackageName lacks server-side selected-library scoping."
    Assert-True ($Renderer.Contains('$expectedSectionId = ([string]$ExpectedSectionId).Trim()')) "$PackageName lacks scoped recently-added row handling."
    Assert-True ($Renderer.Contains('if ([string]::IsNullOrWhiteSpace($sectionId)) { return $true }')) "$PackageName rejects selected-library rows that omit redundant section metadata."
    Assert-True ($Renderer.Contains('Get-OptionalStringProperty -InputObject $meta -Name "title"')) "$PackageName does not treat sparse hero metadata as optional."
    Assert-True (-not $Renderer.Contains('[string]$meta.title')) "$PackageName retains strict direct access to optional hero title metadata."
    Assert-True ($Renderer.Contains('Smtp-Transport.ps1')) "$PackageName does not load the explicit SMTP authentication transport."
    Assert-True ($Renderer.Contains('Send-TautWeeklySmtpMessage')) "$PackageName does not route mail through the explicit SMTP transport."
    Assert-True ($Renderer.Contains('function Assert-TautWeeklyUserEmailOverrides')) "$PackageName does not validate managed-user fallback addresses."
    Assert-True ($Renderer.Contains('UserEmailOverrides supports at most 2000 assignments.')) "$PackageName lacks the bounded managed-user fallback map."
    Assert-True ($Renderer.Contains('DeliveryEmail = $deliveryEmail')) "$PackageName does not resolve an effective recipient address."
    Assert-True ($Renderer.Contains('if ([string]::IsNullOrWhiteSpace([string]$User.DeliveryEmail)) { return "missingEmail" }')) "$PackageName does not apply missing-email policy to the effective address."
    Assert-True ($Renderer.Contains('-To $result.User.DeliveryEmail')) "$PackageName SendAll does not use the effective recipient address."
    Assert-True ($Renderer.Contains('function Get-StatsTvShowRowsHtml')) "$PackageName lacks grouped TV-show personal statistics."
    Assert-True ($Renderer.Contains('$tvShows = @($Stats.TvShowItems)')) "$PackageName does not enrich every watched TV show for IMDb ratings."
    Assert-True ($Renderer.Contains('$movies = @($Stats.MovieItems)')) "$PackageName does not enrich every watched movie for ratings."
    Assert-True ($Renderer.Contains('$summaryCardHeight = 178')) "$PackageName does not keep personal-time and Binge Champion cards compact."
    Assert-True ($Renderer.Contains('class="stats-summary-cell"')) "$PackageName lacks responsive compact personal summary cards."
    Assert-True ($Renderer.Contains('class="stats-title-cell" width="50%"') -and $Renderer.Contains('.stats-title-cell { display:block !important; width:100% !important;')) "$PackageName lacks the responsive movie-title grid."
    Assert-True ($Renderer.Contains('stats-title-cell stats-tv-title-cell stats-tv-title-left') -and $Renderer.Contains('.stats-title-cell.stats-tv-title-cell { display:table-cell !important; width:50% !important;')) "$PackageName does not preserve two TV titles per mobile row."
    Assert-True ($Renderer.Contains('YOU CLOCKED') -and $Renderer.Contains('total watch time')) "$PackageName has stale personal total-watch-time copy."
    Assert-True ($Renderer.Contains('Get-OptionalStringProperty -InputObject $item -Name "DesignImdbRating"')) "$PackageName does not render IMDb ratings in watched-TV statistics."
    Assert-True ($Renderer.Contains('function Get-PlexWatchRatings')) "$PackageName lacks the exact-slug public Plex rating fallback."
    Assert-True ($Renderer.Contains('function Get-PlexHostedMetadataMatchPayload')) "$PackageName lacks exact modern/legacy provider payload construction."
    Assert-True ($Renderer.Contains('function Get-PlexHostedMetadataItemFromResponse')) "$PackageName lacks shared hosted metadata response parsing."
    Assert-True ($Renderer.Contains('function Test-PlexHostedMetadataExactMatch')) "$PackageName lacks fail-closed hosted match validation."
    Assert-True ($Renderer.Contains('-Method Post')) "$PackageName lacks the provider-contract POST retry for empty exact-ID matches."
    Assert-True ($Renderer.Contains('matching hints only: require an exact modern GUID')) "$PackageName does not document the exact-identifier hosted POST boundary."
    Assert-True ($Renderer.Contains('"User-Agent"      = "TautWeekly-for-Plex/0.11.1"')) "$PackageName does not identify the tokenless public Plex rating fallback."
    Assert-True ($Renderer.Contains('"X-Plex-Version"           = "0.11.1"')) "$PackageName does not identify the authenticated hosted metadata fallback."
    Assert-True ($Renderer.Contains('native XML rating fallback failed')) "$PackageName lacks the native Plex XML rating fallback."
    Assert-True ($Renderer.Contains('function Get-DesignEpisodeRtRating')) "$PackageName lacks exact-episode Rotten Tomatoes fallback resolution."
    Assert-True ($Renderer.Contains('TV RT fallback:')) "$PackageName lacks sanitized exact-episode Rotten Tomatoes diagnostics."
    Assert-True ($Renderer.Contains('Get-DesignRtIconUrl -ImageState $rtImage -Kind $rtKind -ImageMode $ImageMode')) "$PackageName lacks score-dependent exact-episode Rotten Tomatoes icons."
    Assert-True ($Renderer.Contains('Optional Plex hosted metadata recovery found no exact match')) "$PackageName does not distinguish an optional hosted metadata miss from a local rating failure."
    Assert-True ($Renderer.Contains('<meta name="color-scheme" content="light dark">')) "$PackageName does not advertise Apple-compatible email color schemes."
    Assert-True ($Renderer.Contains(':root { color-scheme:light dark; supported-color-schemes:light dark; }')) "$PackageName lacks the Apple-compatible email scheme declaration."
    Assert-True (-not $Renderer.Contains('color-scheme:dark only')) "$PackageName retains the incompatible dark-only email declaration."
    Assert-True ($Renderer.Contains('individual_files = "false"')) "$PackageName still requests invalid individual files for a rating-key export."
    Assert-True ($Renderer.Contains('metadata_level   = 1')) "$PackageName requests more Tautulli metadata than the rating fallback requires."
    Assert-True ($Renderer.Contains('sub_media_type = $MediaType')) "$PackageName omits Tautulli's compatible exporter-field subtype."
    Assert-True ($Renderer.Contains('@("rating", "ratingImage", "audienceRating", "audienceRatingImage")')) "$PackageName does not request provider-labelled rating fields explicitly."
    Assert-True ($Renderer.Contains('function Get-DesignProviderRating')) "$PackageName cannot recognize selected Tautulli rating providers."
    Assert-True ($Renderer.Contains('DesignRatingProvider')) "$PackageName does not retain selected provider-labelled ratings."
    Assert-True ($Renderer.Contains('"Accept-Language" = "en-US,en;q=0.9"')) "$PackageName does not request stable provider-labelled rating text."
    Assert-True ($Renderer.Contains('function Get-BingeChampionTitleBreakdown')) "$PackageName lacks the media-specific Binge Champion title breakdown."
    Assert-True ($Renderer.Contains('$bingeTimeLine = "$([string]$bingeDisplay.TotalTimeText) watched"')) "$PackageName has stale Binge Champion duration copy."
    Assert-True (-not $Renderer.Contains('$bingeHeadline')) "$PackageName retains the retired one-line Binge Champion metric."
    Assert-True ($Renderer.Contains('$heroLabel = if ($trendingHeroMode) { "TRENDING THIS WEEK" } else { "HOT NEW RELEASE" }')) "$PackageName lacks the movie-empty Trending hero fallback."
    Assert-True ($Renderer.Contains('"tautulli-default-poster-" + [Guid]::NewGuid().ToString("N") + ".png"')) "$PackageName lacks the portable generic-poster probe."
    Assert-True ($Renderer.Contains('Get-FileSha256 -Path $probePath')) "$PackageName lacks portable poster fingerprinting."
    Assert-True ($Renderer.Contains('DeletedItemCache.ps1')) "$PackageName does not load the persistent deleted-item cache."
    Assert-True ($Renderer.Contains('Restore-TautWeeklyDeletedItemCachePoster')) "$PackageName does not reuse exact cached artwork."
    Assert-True ($Renderer.Contains('Update-TautWeeklyDeletedItemCache')) "$PackageName does not capture live presentation assets."
    Assert-True ($Renderer.Contains('function Get-RecipientWatchedMovies')) "$PackageName lacks historical recipient movie watched-state collection."
    Assert-True ($Renderer.Contains('grouping         = 1') -and $Renderer.Contains('include_activity = 0') -and $Renderer.Contains('media_type       = "movie"') -and $Renderer.Contains('user_id          = $ExpectedUserId')) "$PackageName lacks recipient/movie-scoped historical Tautulli parameters."
    Assert-True ($Renderer.Contains('(Safe-Int $row.watched_status) -eq 1') -and $Renderer.Contains('(Safe-Int $row.percent_complete) -ge $watchedThreshold')) "$PackageName does not distinguish definitive Tautulli v2.18 watched state from partial grades."
    Assert-True ($Renderer.Contains('if ($rowUserId -ne $ExpectedUserId) { continue }')) "$PackageName does not fail closed on cross-user history rows."
    Assert-True ($Renderer.Contains('function Test-RecipientHasWatchedMovie') -and $Renderer.Contains('MetadataGuids.ContainsKey($metadataGuid)')) "$PackageName lacks exact movie key/GUID watched-state matching."
    Assert-True ($Renderer.Contains('function Get-RecipientWatchedTitleIconHtml') -and $Renderer.Contains('function Get-RecipientWatchedDesktopHeroPosterHtml')) "$PackageName lacks shared watched-marker rendering helpers."
    Assert-True ($Renderer.Contains('width="16" height="16" alt="Watched" title="Watched"')) "$PackageName lacks accessible circular watched-icon markup."
    Assert-True ($Renderer.Contains('vertical-align:middle;margin-left:8px;') -and $Renderer.Contains('function Get-RecipientWatchedTitleHtml') -and $Renderer.Contains('class="recipient-watched-title-tail" style="white-space:nowrap;"')) "$PackageName has inconsistent circular watched-icon centering, spacing, or wrapping."
    Assert-True ($Renderer.Contains('width="26" height="26" alt="Watched" title="Watched"') -and $Renderer.Contains('width="147" height="26"') -and $Renderer.Contains('width="7" height="26"') -and $Renderer.Contains('padding:5px 0 0;')) "$PackageName lacks the approved table-based desktop poster-badge placement."
    Assert-True ($Renderer.Contains('<v:group') -and $Renderer.Contains('coordsize="180,275"') -and $Renderer.Contains('left:147;top:0;width:26;height:26;')) "$PackageName lacks the fixed-coordinate Outlook poster-badge fallback."
    Assert-True ($Renderer.Contains('Cid = "recipient_watched"; MediaType = "image/png"') -and $Renderer.Contains('Cid = "recipient_watched_desktop"; MediaType = "image/png"')) "$PackageName does not MIME-link both watched assets."
    Assert-True (-not $Renderer.Contains('$trendingTitleWithStatus') -and -not $Renderer.Contains('$trendWatchedSuffix')) "$PackageName marks compact footer Trending."
    $recapSource = [regex]::Match($Renderer, '(?s)function Get-StatsMovieRowsHtml.*?(?=function Get-StatsTvShowRatingHtml)').Value
    Assert-True ($recapSource.Length -gt 0 -and -not $recapSource.Contains('RecipientWatched')) "$PackageName marks personal footer movies."
    foreach ($value in @('$timeText', '$(HtmlEncode $bingeTimeLine)', '$(HtmlEncode $topGenreName)', '$trendingDisplay')) {
        $valueMatches = [regex]::Matches($Renderer, '<div style="([^"]+)">' + [regex]::Escape($value) + '</div>')
        $expectedCount = if ($value -eq '$(HtmlEncode $bingeTimeLine)') { 2 } else { 1 }
        Assert-True ($valueMatches.Count -eq $expectedCount) "$PackageName is missing a footer primary-value variant."
        foreach ($valueMatch in $valueMatches) {
            foreach ($style in @('font-size:27px;', 'font-weight:800;', 'line-height:1.1;')) {
                Assert-True ($valueMatch.Groups[1].Value.Contains($style)) "$PackageName footer value lost $style"
            }
        }
    }
    Assert-True (([regex]::Matches($Renderer, 'margin-left:8px;color:#e5a00d;font-size:12px;font-weight:700;white-space:nowrap;')).Count -eq 2) "$PackageName does not size both main TV IMDb paths at 12px."
    Assert-True ($Renderer.Contains('function Get-RecipientWatchedPlainTextSuffix')) "$PackageName lacks plain-text watched semantics."
}

function Assert-DeletedItemCacheContract([string]$PackageName, [string]$CacheModule) {
    foreach ($required in @(
        '$script:TwDeletedCacheSchemaVersion = 1',
        'DeletedItemCacheRetentionDays',
        'DeletedItemCacheMaxItems',
        'DeletedItemCacheMaxBytesMB',
        'Get-TwDeletedCacheFileSha256',
        'Move-TwDeletedCacheCorruptManifest',
        'Restore-TautWeeklyDeletedItemCachePoster',
        'Update-TautWeeklyDeletedItemCache',
        'Get-TautWeeklyDeletedItemCacheDiagnostics',
        'Test-TwDeletedCacheWritable'
    )) {
        Assert-True ($CacheModule.Contains($required)) "$PackageName cache module is missing: $required"
    }
    Assert-True ($CacheModule.Contains('ProviderValue')) "$PackageName cache module does not retain the bounded selected rating value."
    foreach ($forbidden in @('PlexToken', 'ApiKey', 'SmtpPassword', 'RecipientEmail', 'play_duration', 'watched_status')) {
        Assert-True (-not $CacheModule.Contains($forbidden)) "$PackageName cache module accepts a forbidden private field: $forbidden"
    }
}

function Assert-CacheDiagnosticContract([string]$PackageName, [string]$Diagnostic) {
    foreach ($required in @(
        'Write-CacheDiagnosticLine "ShareSafe" $true',
        'Get-TautWeeklyDeletedItemCacheDiagnostics',
        'Write-CacheDiagnosticLine "Backup"',
        'Write-CacheDiagnosticLine "ExactGuidProbe"',
        'Write-CacheDiagnosticLine "PersistenceProbe"',
        'Read-Host "Enter the exact Plex metadata GUID (input is hidden and never printed)" -AsSecureString',
        'ZeroFreeBSTR',
        'SetPersistenceProbe',
        'VerifyPersistenceProbe',
        'ClearPersistenceProbe'
    )) {
        Assert-True ($Diagnostic.Contains($required)) "$PackageName cache diagnostic is missing: $required"
    }
    Assert-True ($Diagnostic -notmatch '(?im)Write-(?:Output|Host)[^\r\n]*\$(?:guid|resolvedRoot|configPath|cacheRoot|probePath)\b') "$PackageName cache diagnostic can print a private input or path."
}

function Assert-MetadataReadinessContract([string]$PackageName, [string]$Content) {
    foreach ($required in @(
        'Ratings Source',
        'Refresh All Metadata',
        'Media Info',
        'Refresh media info'
    )) {
        Assert-True ($Content.Contains($required)) "$PackageName omits metadata-readiness instruction: $required"
    }
    Assert-True ($Content -match '(?i)per[- ]library') "$PackageName does not identify Tautulli's per-library refresh scope."
}

$expected = [ordered]@{
    'TautWeekly-windows.zip' = @(
        'TautWeekly-windows/TautWeekly.ps1',
        'TautWeekly-windows/DeletedItemCache.ps1',
        'TautWeekly-windows/Cache-Diagnostics.ps1',
        'TautWeekly-windows/Configuration-Backups.ps1',
        'TautWeekly-windows/Smtp-Transport.ps1',
        'TautWeekly-windows/config.example.json',
        'TautWeekly-windows/15-MANAGE-LIBRARIES.bat',
        'TautWeekly-windows/16-LIST-LIBRARIES.bat',
        'TautWeekly-windows/17-CHECK-FOR-UPDATE.bat',
        'TautWeekly-windows/Check-Update.ps1',
        'TautWeekly-windows/Windows-Update.ps1',
        'TautWeekly-windows/Operation-Lock.ps1',
        'TautWeekly-windows/TautWeekly.ico',
        'TautWeekly-windows/00-OPEN-MANAGER.bat',
        'TautWeekly-windows/START-MANAGER.ps1',
        'TautWeekly-windows/18-RESET-MANAGER-ACCESS.bat',
        'TautWeekly-windows/19-CACHE-DIAGNOSTICS.bat',
        'TautWeekly-windows/20-REFRESH-DELETED-ITEM-CACHE.bat',
        'TautWeekly-windows/RESET-MANAGER-ACCESS.ps1',
        'TautWeekly-windows/SCHEDULE-HELPER.ps1',
        'TautWeekly-windows/TAILSCALE-HELPER.ps1',
        'TautWeekly-windows/manager-assets/tautweekly-social-preview.jpg',
        'TautWeekly-windows/tautweekly-manager.exe',
        'TautWeekly-windows/TautWeekly-Uninstall.exe',
        'TautWeekly-windows/THIRD_PARTY_NOTICES.md',
        'TautWeekly-windows/RELEASE-FILES.txt',
        'TautWeekly-windows/RELEASE-METADATA.txt',
        'TautWeekly-windows/README.md'
    )
    'TautWeekly-nas-docker.zip' = @(
        'TautWeekly-nas-docker/app/TautWeekly.ps1',
        'TautWeekly-nas-docker/app/refresh-assets.py',
        'TautWeekly-nas-docker/app/DeletedItemCache.ps1',
        'TautWeekly-nas-docker/app/Cache-Diagnostics.ps1',
        'TautWeekly-nas-docker/app/Configuration-Backups.ps1',
        'TautWeekly-nas-docker/app/Smtp-Transport.ps1',
        'TautWeekly-nas-docker/app/Schedule-Time.ps1',
        'TautWeekly-nas-docker/app/healthcheck.sh',
        'TautWeekly-nas-docker/app/bin/run-as-user.sh',
        'TautWeekly-nas-docker/app/bin/funnel-adapter.sh',
        'TautWeekly-nas-docker/app/bin/tautweekly-funnel',
        'TautWeekly-nas-docker/app/bin/run-mode.sh',
        'TautWeekly-nas-docker/app/bin/run-script.sh',
        'TautWeekly-nas-docker/app/product-branding/favicon.ico',
        'TautWeekly-nas-docker/app/product-branding/tautweekly-app-icon-128.png',
        'TautWeekly-nas-docker/tautweekly.sh',
        'TautWeekly-nas-docker/package-update.sh',
        'TautWeekly-nas-docker/container-update.sh',
        'TautWeekly-nas-docker/compose.yaml',
        'TautWeekly-nas-docker/RELEASE-FILES.txt',
        'TautWeekly-nas-docker/README.md'
    )
    'TautWeekly-mac-docker.zip' = @(
        'TautWeekly-mac-docker/app/TautWeekly.ps1',
        'TautWeekly-mac-docker/app/refresh-assets.py',
        'TautWeekly-mac-docker/app/DeletedItemCache.ps1',
        'TautWeekly-mac-docker/app/Cache-Diagnostics.ps1',
        'TautWeekly-mac-docker/app/Configuration-Backups.ps1',
        'TautWeekly-mac-docker/app/Smtp-Transport.ps1',
        'TautWeekly-mac-docker/app/Schedule-Time.ps1',
        'TautWeekly-mac-docker/app/bin/run-as-user.sh',
        'TautWeekly-mac-docker/app/bin/funnel-adapter.sh',
        'TautWeekly-mac-docker/app/bin/tautweekly-funnel',
        'TautWeekly-mac-docker/app/bin/run-mode.sh',
        'TautWeekly-mac-docker/app/bin/run-script.sh',
        'TautWeekly-mac-docker/manager/tautweekly-manager-linux-amd64',
        'TautWeekly-mac-docker/manager/tautweekly-manager-linux-arm64',
        'TautWeekly-mac-docker/app/product-branding/favicon.ico',
        'TautWeekly-mac-docker/app/product-branding/tautweekly-app-icon-128.png',
        'TautWeekly-mac-docker/tautweekly.sh',
        'TautWeekly-mac-docker/check-release.sh',
        'TautWeekly-mac-docker/mac-update.sh',
        'TautWeekly-mac-docker/package-update.sh',
        'TautWeekly-mac-docker/INSTALL-MAC.command',
        'TautWeekly-mac-docker/RELEASE-FILES.txt',
        'TautWeekly-mac-docker/README.md'
    )
    'TautWeekly-linux.zip' = @(
        'TautWeekly-linux/app/TautWeekly.ps1',
        'TautWeekly-linux/app/refresh-assets.py',
        'TautWeekly-linux/app/DeletedItemCache.ps1',
        'TautWeekly-linux/app/Cache-Diagnostics.ps1',
        'TautWeekly-linux/app/Configuration-Backups.ps1',
        'TautWeekly-linux/app/Smtp-Transport.ps1',
        'TautWeekly-linux/app/Schedule-Time.ps1',
        'TautWeekly-linux/app/bin/run-as-user.sh',
        'TautWeekly-linux/app/bin/run-mode.sh',
        'TautWeekly-linux/app/bin/run-script.sh',
        'TautWeekly-linux/app/manager-assets/tautweekly-social-preview.jpg',
        'TautWeekly-linux/app/product-branding/favicon.ico',
        'TautWeekly-linux/app/product-branding/tautweekly-app-icon-128.png',
        'TautWeekly-linux/install-linux.sh',
        'TautWeekly-linux/systemd/tautweekly.service',
        'TautWeekly-linux/systemd/tautweekly-remote-access.socket',
        'TautWeekly-linux/systemd/tautweekly-remote-access@.service',
        'TautWeekly-linux/tautweekly',
        'TautWeekly-linux/check-release.sh',
        'TautWeekly-linux/package-update.sh',
        'TautWeekly-linux/manager/tautweekly-manager-linux-amd64',
        'TautWeekly-linux/manager/tautweekly-manager-linux-arm64',
        'TautWeekly-linux/RELEASE-METADATA.txt',
        'TautWeekly-linux/RELEASE-FILES.txt',
        'TautWeekly-linux/README.md'
    )
    'TautWeekly-freebsd-podman.zip' = @(
        'TautWeekly-freebsd-podman/app/TautWeekly.ps1',
        'TautWeekly-freebsd-podman/app/refresh-assets.py',
        'TautWeekly-freebsd-podman/app/DeletedItemCache.ps1',
        'TautWeekly-freebsd-podman/app/Cache-Diagnostics.ps1',
        'TautWeekly-freebsd-podman/app/Configuration-Backups.ps1',
        'TautWeekly-freebsd-podman/app/Smtp-Transport.ps1',
        'TautWeekly-freebsd-podman/app/Schedule-Time.ps1',
        'TautWeekly-freebsd-podman/app/bin/run-as-user.sh',
        'TautWeekly-freebsd-podman/app/bin/run-mode.sh',
        'TautWeekly-freebsd-podman/app/bin/run-script.sh',
        'TautWeekly-freebsd-podman/app/product-branding/favicon.ico',
        'TautWeekly-freebsd-podman/app/product-branding/tautweekly-app-icon-128.png',
        'TautWeekly-freebsd-podman/install-freebsd.sh',
        'TautWeekly-freebsd-podman/rc.d/tautweekly',
        'TautWeekly-freebsd-podman/tautweekly',
        'TautWeekly-freebsd-podman/package-update.sh',
        'TautWeekly-freebsd-podman/RELEASE-FILES.txt',
        'TautWeekly-freebsd-podman/README.md'
    )
}

$assetRoots = [ordered]@{
    'TautWeekly-windows.zip'         = 'TautWeekly-windows/assets'
    'TautWeekly-nas-docker.zip'      = 'TautWeekly-nas-docker/app/assets-default'
    'TautWeekly-mac-docker.zip'      = 'TautWeekly-mac-docker/app/assets-default'
    'TautWeekly-linux.zip'           = 'TautWeekly-linux/app/assets-default'
    'TautWeekly-freebsd-podman.zip'  = 'TautWeekly-freebsd-podman/app/assets-default'
}
$platformAssetManifestPath = Join-Path $Root 'assets/platforms/NEWSLETTER-ASSET-SHA256SUMS.txt'
Assert-True (Test-Path -LiteralPath $platformAssetManifestPath -PathType Leaf) 'Newsletter platform asset checksum manifest is missing.'
$expectedPlatformHashes = [ordered]@{}
$expectedGenreHashes = [ordered]@{}
foreach ($line in Get-Content -LiteralPath $platformAssetManifestPath) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
    Assert-True ($line -match '^(?<hash>[0-9a-f]{64})  (?<name>(?:platform-[a-z0-9-]+[.]png|genre-[a-z0-9-]+[.]gif))$') "Invalid newsletter asset manifest line: $line"
    $name = $Matches['name']
    if ($name.StartsWith('platform-', [StringComparison]::Ordinal)) {
        $expectedPlatformHashes[$name] = $Matches['hash'].ToUpperInvariant()
    }
    else {
        $expectedGenreHashes[$name] = $Matches['hash'].ToUpperInvariant()
    }
}
Assert-True ($expectedPlatformHashes.Count -eq 22) "Expected 22 newsletter platform assets, found $($expectedPlatformHashes.Count)."
Assert-True ($expectedGenreHashes.Count -eq 12) "Expected 12 Top Genre assets, found $($expectedGenreHashes.Count)."
$gifManifest = Get-Content -LiteralPath (Join-Path $Root 'assets/email-gifs.json') -Raw | ConvertFrom-Json
$expectedGifHashes = [ordered]@{}
foreach ($asset in $gifManifest.assets) {
    $expectedGifHashes[$asset.name] = $asset.sha256.ToUpperInvariant()
}
Assert-True ($expectedGifHashes.Count -eq 32) 'Expected all 32 optimized GIFs in every release archive.'
foreach ($genreName in $expectedGenreHashes.Keys) {
    Assert-True ($expectedGifHashes[$genreName] -ceq $expectedGenreHashes[$genreName]) "Genre manifests disagree: $genreName"
}
$expectedWatchedPngs = [ordered]@{
    'watched.png' = @{ Hash='26744BE4A08445006673CEE9757E88937FF6A98406ECA4ACF6C4DA4FC2B20498'; Width=20; Height=20 }
    'watched-desktop.png' = @{ Hash='714BBB0D84C41A22AD38717A52BF177029F8854EC3ACE48E753C162D7E97A52E'; Width=26; Height=26 }
}
$expectedWindowsManagerSocialHash = '1AB6B9CE65FD8E6A9587453484E1969348C952057F8087A734B602856DAC761D'
$windowsManagerSocialPath = Join-Path $Root 'platforms/windows/manager-assets/tautweekly-social-preview.jpg'
Assert-True (Test-Path -LiteralPath $windowsManagerSocialPath -PathType Leaf) 'Windows Manager social preview is missing.'
$windowsManagerSocialBytes = [IO.File]::ReadAllBytes($windowsManagerSocialPath)
Assert-True ($windowsManagerSocialBytes.Length -eq 581202) 'Windows Manager social preview byte size changed unexpectedly.'
Assert-True ((Get-FileHash -LiteralPath $windowsManagerSocialPath -Algorithm SHA256).Hash -ceq $expectedWindowsManagerSocialHash) 'Windows Manager social preview hash changed unexpectedly.'
Assert-WindowsManagerSocialJpeg 'Windows source' $windowsManagerSocialBytes

$expectedBrandFiles = [ordered]@{
    'TautWeekly-windows.zip' = [ordered]@{
        'TautWeekly-windows/TautWeekly.ico' = 'A77AA803DFE9D026DB37744FF646A6197C0C3C402CA03DA8EEA76962212B892C'
    }
    'TautWeekly-nas-docker.zip' = [ordered]@{
        'TautWeekly-nas-docker/app/product-branding/favicon.ico' = 'A55139823F3DA079E270049EF232B7919979E94605734A7C0DC0864AF4C0E83A'
        'TautWeekly-nas-docker/app/product-branding/tautweekly-app-icon-128.png' = '7938FAA3711FCF51BF53A6ED530B4D1D7DCA73B6A8EF7F5CA9D1E674B461251E'
    }
    'TautWeekly-mac-docker.zip' = [ordered]@{
        'TautWeekly-mac-docker/app/product-branding/favicon.ico' = 'A55139823F3DA079E270049EF232B7919979E94605734A7C0DC0864AF4C0E83A'
        'TautWeekly-mac-docker/app/product-branding/tautweekly-app-icon-128.png' = '7938FAA3711FCF51BF53A6ED530B4D1D7DCA73B6A8EF7F5CA9D1E674B461251E'
    }
    'TautWeekly-linux.zip' = [ordered]@{
        'TautWeekly-linux/app/product-branding/favicon.ico' = 'A55139823F3DA079E270049EF232B7919979E94605734A7C0DC0864AF4C0E83A'
        'TautWeekly-linux/app/product-branding/tautweekly-app-icon-128.png' = '7938FAA3711FCF51BF53A6ED530B4D1D7DCA73B6A8EF7F5CA9D1E674B461251E'
    }
    'TautWeekly-freebsd-podman.zip' = [ordered]@{
        'TautWeekly-freebsd-podman/app/product-branding/favicon.ico' = 'A55139823F3DA079E270049EF232B7919979E94605734A7C0DC0864AF4C0E83A'
        'TautWeekly-freebsd-podman/app/product-branding/tautweekly-app-icon-128.png' = '7938FAA3711FCF51BF53A6ED530B4D1D7DCA73B6A8EF7F5CA9D1E674B461251E'
    }
}
$zipReleaseManifests = @{}
$releaseVersions = New-Object System.Collections.Generic.List[string]

$forbiddenNames = @(
    '.tautweekly-asset-bundle',
    'config.json', '.env', 'state.json', 'access-state.json', 'remote-access.json',
    'scheduler-state.json', 'scheduler-heartbeat.json', 'service-heartbeat.json',
    'configuration-status.json', 'authkey.local'
)

$zipArchives = @(Get-ChildItem -LiteralPath $DistPath -File -Filter '*.zip')
Assert-True ($zipArchives.Count -eq 5) "Expected five ZIP release artifacts, found $($zipArchives.Count)."

$installerPath = Join-Path $DistPath 'TautWeekly-Setup.exe'
Assert-True (Test-Path -LiteralPath $installerPath -PathType Leaf) 'The one-click Windows installer is missing.'
$installerBytes = [IO.File]::ReadAllBytes($installerPath)
Assert-True ($installerBytes.Length -gt 2 -and $installerBytes[0] -eq 0x4d -and $installerBytes[1] -eq 0x5a) 'TautWeekly-Setup.exe is not a Windows PE executable.'
Assert-True ($installerBytes.Length -gt (Get-Item -LiteralPath (Join-Path $DistPath 'TautWeekly-windows.zip')).Length) 'TautWeekly-Setup.exe does not appear to contain the portable Windows payload.'
Write-Host "[PASS] Windows installer contract: TautWeekly-Setup.exe ($($installerBytes.Length) bytes)"

foreach ($archiveName in $expected.Keys) {
    $archivePath = Join-Path $DistPath $archiveName
    Assert-True (Test-Path -LiteralPath $archivePath) "Missing release artifact: $archiveName"
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        $unsafeEntries = @($entryNames | Where-Object {
            $_ -match '^(?:/|[A-Za-z]:)' -or @($_ -split '/' | Where-Object { $_ -eq '..' }).Count -gt 0
        })
        Assert-True ($unsafeEntries.Count -eq 0) "$archiveName contains unsafe archive paths: $($unsafeEntries -join ', ')"
        $composeEntries = @($archive.Entries | Where-Object { $_.FullName -match '/compose(?:\.qnap)?\.yaml$' })
        foreach ($composeEntry in $composeEntries) {
            $composeReader = New-Object IO.StreamReader($composeEntry.Open())
            try { $identityText = $composeReader.ReadToEnd() } finally { $composeReader.Dispose() }
            Assert-True ($identityText -notmatch '__TAUTWEEKLY_RELEASE_VERSION__') "$archiveName retains an unresolved release-version token in $($composeEntry.FullName)."
            Assert-True ($identityText -match 'TAUTWEEKLY_PACKAGE_KIND' -and $identityText -match 'TAUTWEEKLY_PACKAGE_VERSION') "$archiveName omits package identity from $($composeEntry.FullName)."
            Assert-True ($identityText -match 'TAUTWEEKLY_HOST_ADAPTER_API:\s*"4"') "$archiveName has a stale host-adapter API in $($composeEntry.FullName)."
            Assert-True ($identityText -match 'TAUTWEEKLY_FUNNEL_ADAPTER' -and $identityText -match '/var/lib/tautweekly-tailscale') "$archiveName omits the explicit Funnel adapter or root-only provider state from $($composeEntry.FullName)."
            Assert-True ($identityText -notmatch '(?m)^\s*-\s*["'']?(?:0[.]0[.]0[.]0:|\$\{PREVIEW_BIND:-0[.]0[.]0[.]0\})') "$archiveName broadly publishes Manager in $($composeEntry.FullName)."
            if ($composeEntry.FullName -match '/compose[.]qnap[.]yaml$') {
                Assert-True ($identityText -match '127[.]0[.]0[.]1:8787:8080') "$archiveName QNAP Compose asset is not loopback-only."
            }
        }
        Assert-True (@($entryNames | Where-Object { $_ -match '/compose[.]tailscale[.]yaml$|/tailscale/config/serve[.]json$' }).Count -eq 0) "$archiveName still contains the retired private Serve deployment."
        foreach ($requiredEntry in $expected[$archiveName]) {
            Assert-True ($entryNames -ccontains $requiredEntry) "$archiveName is missing $requiredEntry"
        }
        if ($archiveName -notin @('TautWeekly-windows.zip', 'TautWeekly-linux.zip')) {
            Assert-True (@($entryNames | Where-Object { $_ -match '/manager-assets/tautweekly-social-preview[.]jpg$' }).Count -eq 0) "$archiveName contains the Windows-only Manager social preview."
        }
        $thirdPartyNoticeEntry = @($archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -match '/THIRD_PARTY_NOTICES[.]md$' })
        Assert-True ($thirdPartyNoticeEntry.Count -eq 1) "$archiveName has no unique third-party notices file."
        $thirdPartyNoticeReader = New-Object IO.StreamReader($thirdPartyNoticeEntry[0].Open())
        try { $thirdPartyNoticeText = $thirdPartyNoticeReader.ReadToEnd() }
        finally { $thirdPartyNoticeReader.Dispose() }
        Assert-True ($thirdPartyNoticeText.Contains('Simple Icons 9.21.0') -and $thirdPartyNoticeText.Contains('CC0 1.0 Universal')) "$archiveName omits the bundled platform glyph provenance."
        Assert-True ($thirdPartyNoticeText.Contains('tailscale/tailscale:v1.102.2') -and $thirdPartyNoticeText.Contains('Copyright (c) 2020 Tailscale Inc & contributors.')) "$archiveName omits the bundled Tailscale runtime provenance or BSD license."

        if ($archiveName -ne 'TautWeekly-windows.zip') {
            foreach ($entry in $archive.Entries) {
                if ([string]::IsNullOrEmpty($entry.Name)) { continue }
                $entryPath = $entry.FullName.Replace('\', '/')
                $isExecutable = $entryPath -match '\.sh$' -or
                    $entryPath -match '/manager/tautweekly-manager-linux-(?:amd64|arm64)$' -or
                    $entryPath -match '/(?:rc\.d/)?tautweekly$'
                $rawAttributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
                $unixMode = ($rawAttributes -shr 16) -band 0xffff
                $expectedMode = if ($isExecutable) { 0x81ed } else { 0x81a4 }
                Assert-True ($unixMode -eq $expectedMode) "$archiveName has unsafe or missing Unix ZIP mode metadata for $entryPath (expected $($expectedMode.ToString('x4')), found $($unixMode.ToString('x4')))."
            }
        }

        if ($archiveName -eq 'TautWeekly-windows.zip') {
            $socialEntry = @($archive.Entries | Where-Object { $_.FullName -ceq 'TautWeekly-windows/manager-assets/tautweekly-social-preview.jpg' })
            Assert-True ($socialEntry.Count -eq 1) 'Windows archive has no unique Manager social preview.'
            Assert-True ((Get-ZipEntrySha256 $socialEntry[0]) -ceq $expectedWindowsManagerSocialHash) 'Windows archive Manager social preview hash changed.'
            Assert-WindowsManagerSocialJpeg 'Windows archive' (Get-ZipEntryBytes $socialEntry[0])

            $managerEntry = @($archive.Entries | Where-Object { $_.FullName -ceq 'TautWeekly-windows/tautweekly-manager.exe' })
            Assert-True ($managerEntry.Count -eq 1) 'Windows archive has no unique Manager executable.'
            $managerStream = $managerEntry[0].Open()
            try {
                $signature = New-Object byte[] 2
                Assert-True ($managerStream.Read($signature, 0, 2) -eq 2) 'Windows Manager executable is empty.'
                Assert-True ($signature[0] -eq 0x4d -and $signature[1] -eq 0x5a) 'Windows Manager is not a PE executable.'
            }
            finally { $managerStream.Dispose() }

            $uninstallerEntry = @($archive.Entries | Where-Object { $_.FullName -ceq 'TautWeekly-windows/TautWeekly-Uninstall.exe' })
            Assert-True ($uninstallerEntry.Count -eq 1) 'Windows archive has no unique release-owned uninstaller.'
            $uninstallerStream = $uninstallerEntry[0].Open()
            try {
                $signature = New-Object byte[] 2
                Assert-True ($uninstallerStream.Read($signature, 0, 2) -eq 2) 'Windows uninstaller executable is empty.'
                Assert-True ($signature[0] -eq 0x4d -and $signature[1] -eq 0x5a) 'Windows uninstaller is not a PE executable.'
            }
            finally { $uninstallerStream.Dispose() }

            $noticeEntry = @($archive.Entries | Where-Object { $_.FullName -ceq 'TautWeekly-windows/THIRD_PARTY_NOTICES.md' })
            Assert-True ($noticeEntry.Count -eq 1) 'Windows archive has no unique third-party notices file.'
            $noticeReader = New-Object IO.StreamReader($noticeEntry[0].Open())
            try { $noticeText = $noticeReader.ReadToEnd() }
            finally { $noticeReader.Dispose() }
            Assert-True ($noticeText -match 'Copyright 2009 The Go Authors') 'Windows archive omits the Go binary redistribution notice.'
        }

        if ($archiveName -eq 'TautWeekly-linux.zip') {
            $socialEntry = @($archive.Entries | Where-Object { $_.FullName -ceq 'TautWeekly-linux/app/manager-assets/tautweekly-social-preview.jpg' })
            Assert-True ($socialEntry.Count -eq 1) 'Linux archive has no unique Manager social preview.'
            Assert-True ((Get-ZipEntrySha256 $socialEntry[0]) -ceq $expectedWindowsManagerSocialHash) 'Linux archive Manager social preview differs from the verified shared asset.'
            Assert-WindowsManagerSocialJpeg 'Linux archive' (Get-ZipEntryBytes $socialEntry[0])

            $previewEntry = @($archive.Entries | Where-Object { $_.FullName -ceq 'TautWeekly-linux/app/preview-home.html' })
            Assert-True ($previewEntry.Count -eq 1) 'Linux archive has no unique preview landing page.'
            $previewReader = New-Object IO.StreamReader($previewEntry[0].Open())
            try { $previewText = $previewReader.ReadToEnd() } finally { $previewReader.Dispose() }
            Assert-True ($previewText -match 'authenticated native Linux Manager endpoint') 'Linux archive does not contain the native Linux Manager adapter.'
            Assert-True ($previewText -notmatch 'Docker Compose|Unraid container Console') 'Linux archive retained container-only preview setup language.'
            foreach ($architecture in @('amd64', 'arm64')) {
                $path = "TautWeekly-linux/manager/tautweekly-manager-linux-$architecture"
                $managerEntry = @($archive.Entries | Where-Object { $_.FullName -ceq $path })
                Assert-True ($managerEntry.Count -eq 1) "Linux archive has no unique $architecture Manager executable."
                $managerStream = $managerEntry[0].Open()
                try {
                    $signature = New-Object byte[] 4
                    Assert-True ($managerStream.Read($signature, 0, 4) -eq 4) "Linux $architecture Manager executable is empty."
                    Assert-True ($signature[0] -eq 0x7f -and $signature[1] -eq 0x45 -and $signature[2] -eq 0x4c -and $signature[3] -eq 0x46) "Linux $architecture Manager is not an ELF executable."
                }
                finally { $managerStream.Dispose() }
            }
        }

        if ($archiveName -eq 'TautWeekly-mac-docker.zip') {
            $wrapperEntry = @($archive.Entries | Where-Object { $_.FullName -ceq 'TautWeekly-mac-docker/tautweekly.sh' })
            $serviceEntry = @($archive.Entries | Where-Object { $_.FullName -ceq 'TautWeekly-mac-docker/app/run-service.sh' })
            $composeEntry = @($archive.Entries | Where-Object { $_.FullName -ceq 'TautWeekly-mac-docker/compose.yaml' })
            Assert-True ($wrapperEntry.Count -eq 1 -and $serviceEntry.Count -eq 1 -and $composeEntry.Count -eq 1) 'Mac archive is missing its Manager host adapter.'
            $wrapperReader = New-Object IO.StreamReader($wrapperEntry[0].Open())
            try { $wrapperText = $wrapperReader.ReadToEnd() } finally { $wrapperReader.Dispose() }
            $serviceReader = New-Object IO.StreamReader($serviceEntry[0].Open())
            try { $serviceText = $serviceReader.ReadToEnd() } finally { $serviceReader.Dispose() }
            $composeReader = New-Object IO.StreamReader($composeEntry[0].Open())
            try { $composeText = $composeReader.ReadToEnd() } finally { $composeReader.Dispose() }
            Assert-True ($wrapperText -match 'manager-bootstrap' -and $wrapperText -match 'manager-reset-access' -and $wrapperText -match 'open-manager') 'Mac archive omits Manager bootstrap, recovery, or browser launch.'
            Assert-True ($serviceText -match 'runtime-profile\.sh' -and $serviceText -match '--runtime-mode "\$manager_runtime_mode"' -and $serviceText -match '--runtime-profile' -and $serviceText -match 'health/live' -and $serviceText -match 'wait_for_delivery') 'Mac archive omits unified profile selection, the tailored Manager runtime, or graceful delivery drain.'
            Assert-True ($composeText -match 'read_only:\s*true' -and $composeText -match 'stop_grace_period:\s*30m' -and $composeText -match 'no-new-privileges:true') 'Mac archive omits container hardening or graceful stop configuration.'
            foreach ($architecture in @('amd64', 'arm64')) {
                $path = "TautWeekly-mac-docker/manager/tautweekly-manager-linux-$architecture"
                $managerEntry = @($archive.Entries | Where-Object { $_.FullName -ceq $path })
                Assert-True ($managerEntry.Count -eq 1) "Mac archive has no unique $architecture Manager executable."
                $managerStream = $managerEntry[0].Open()
                try {
                    $signature = New-Object byte[] 4
                    Assert-True ($managerStream.Read($signature, 0, 4) -eq 4) "Mac $architecture Manager executable is empty."
                    Assert-True ($signature[0] -eq 0x7f -and $signature[1] -eq 0x45 -and $signature[2] -eq 0x4c -and $signature[3] -eq 0x46) "Mac $architecture Manager is not an ELF executable."
                }
                finally { $managerStream.Dispose() }
            }
        }

        if ($archiveName -eq 'TautWeekly-freebsd-podman.zip') {
            $wrapperEntry = @($archive.Entries | Where-Object { $_.FullName -ceq 'TautWeekly-freebsd-podman/tautweekly' })
            $rcEntry = @($archive.Entries | Where-Object { $_.FullName -ceq 'TautWeekly-freebsd-podman/rc.d/tautweekly' })
            Assert-True ($wrapperEntry.Count -eq 1 -and $rcEntry.Count -eq 1) 'FreeBSD archive is missing its Manager host adapter.'
            $wrapperReader = New-Object IO.StreamReader($wrapperEntry[0].Open())
            try { $wrapperText = $wrapperReader.ReadToEnd() } finally { $wrapperReader.Dispose() }
            $rcReader = New-Object IO.StreamReader($rcEntry[0].Open())
            try { $rcText = $rcReader.ReadToEnd() } finally { $rcReader.Dispose() }
            Assert-True ($wrapperText -match 'manager-bootstrap' -and $wrapperText -match 'manager-reset-access' -and $wrapperText -match 'access-recover') 'FreeBSD archive omits Manager bootstrap or narrow recovery.'
            Assert-True ($rcText -match '--stop-timeout=1800' -and $rcText -match 'stop --time 1800') 'FreeBSD archive omits the graceful delivery drain.'
            Assert-True ($rcText -match '--read-only' -and $rcText -match '--security-opt no-new-privileges' -and $rcText -match '--cap-drop ALL') 'FreeBSD archive omits container hardening.'
        }

        $forbidden = @($entryNames | Where-Object {
            $name = ($_ -split '/')[-1]
            $name -in $forbiddenNames -or $_ -match '/(logs|output|cache|\.manager-data)/' -or
                $_ -match '/tailscale/state/(?!\.keep(?:/|$)).+'
        })
        Assert-True ($forbidden.Count -eq 0) "$archiveName contains runtime/private paths: $($forbidden -join ', ')"

        $manifestEntry = @($archive.Entries | Where-Object { $_.FullName -match '/RELEASE-FILES\.txt$' })
        Assert-True ($manifestEntry.Count -eq 1) "$archiveName has no unique release-owned file manifest."
        $manifestReader = New-Object IO.StreamReader($manifestEntry[0].Open())
        try { $releaseManifest = $manifestReader.ReadToEnd() }
        finally { $manifestReader.Dispose() }
        $packageName = $archiveName.Substring(0, $archiveName.Length - '.zip'.Length)
        $zipReleaseManifests[$packageName] = ($releaseManifest -replace "`r`n", "`n").Trim()
        Assert-True ($releaseManifest -match '(?m)^[0-9a-f]{64}\s{2}RELEASE-METADATA\.txt\r?$') "$archiveName release manifest does not hash release metadata."
        Assert-True ($releaseManifest -notmatch '(?im)(?:^|/)(?:config\.json|state\.json|access-state\.json|scheduler-state\.json|\.tautweekly-operation\.lock)$') "$archiveName release manifest owns private runtime files."
        $manifestLines = @($releaseManifest -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Assert-True ($manifestLines.Count -eq ($entryNames.Count - 1)) "$archiveName release manifest does not cover every packaged file except itself."
        $seenManifestPaths = @{}
        foreach ($manifestLine in $manifestLines) {
            Assert-True ($manifestLine -match '^(?<hash>[0-9a-f]{64})\s{2}(?<path>.+)$') "$archiveName has an invalid release manifest line: $manifestLine"
            $expectedFileHash = $Matches['hash']
            $relativePath = $Matches['path'].Replace('\', '/')
            Assert-True (-not $seenManifestPaths.ContainsKey($relativePath.ToLowerInvariant())) "$archiveName release manifest duplicates $relativePath."
            $seenManifestPaths[$relativePath.ToLowerInvariant()] = $true
            $packagedPath = ($manifestEntry[0].FullName -replace 'RELEASE-FILES\.txt$', '') + $relativePath
            $packagedEntry = @($archive.Entries | Where-Object { $_.FullName -ceq $packagedPath })
            Assert-True ($packagedEntry.Count -eq 1) "$archiveName release manifest references a missing or duplicate file: $relativePath"
            $sha256 = [Security.Cryptography.SHA256]::Create()
            $entryStream = $packagedEntry[0].Open()
            try {
                $actualHash = ([BitConverter]::ToString($sha256.ComputeHash($entryStream))).Replace('-', '').ToLowerInvariant()
            }
            finally {
                $entryStream.Dispose()
                $sha256.Dispose()
            }
            Assert-True ($actualHash -eq $expectedFileHash) "$archiveName release manifest hash failed for $relativePath."
        }

        $metadataEntry = @($archive.Entries | Where-Object { $_.FullName -match '/RELEASE-METADATA\.txt$' })
        Assert-True ($metadataEntry.Count -eq 1) "$archiveName has no unique release metadata file."
        $metadataReader = New-Object IO.StreamReader($metadataEntry[0].Open())
        try { $metadata = $metadataReader.ReadToEnd() }
        finally { $metadataReader.Dispose() }
        Assert-True ($metadata -match '(?m)^Repository version:\s*(?<version>\S+)\s*$') "$archiveName does not identify its repository version."
        $packageReleaseVersion = $Matches['version']
        $releaseVersions.Add($packageReleaseVersion)
        foreach ($composeEntry in $composeEntries) {
            $composeReader = New-Object IO.StreamReader($composeEntry.Open())
            try { $identityText = $composeReader.ReadToEnd() } finally { $composeReader.Dispose() }
            $versionPattern = 'TAUTWEEKLY_PACKAGE_VERSION[^\r\n]*' + [regex]::Escape($packageReleaseVersion)
            Assert-True ($identityText -match $versionPattern) "$archiveName does not embed repository version $packageReleaseVersion in $($composeEntry.FullName)."
        }

        $rendererEntry = @($archive.Entries | Where-Object { $_.FullName -match '/(?:app/)?TautWeekly\.ps1$' } | Select-Object -First 1)
        Assert-True ($rendererEntry.Count -eq 1) "$archiveName has no production renderer."
        $reader = New-Object IO.StreamReader($rendererEntry[0].Open())
        try { $renderer = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
        Assert-RendererContract -PackageName $archiveName -Renderer $renderer

        $configExampleEntry = @($archive.Entries | Where-Object { $_.FullName -match '/(?:app/)?config[.]example[.]json$' })
        Assert-True ($configExampleEntry.Count -eq 1) "$archiveName does not contain one config.example.json."
        $configExampleReader = New-Object IO.StreamReader($configExampleEntry[0].Open())
        try { $configExample = $configExampleReader.ReadToEnd() }
        finally { $configExampleReader.Dispose() }
        Assert-True ($configExample.Contains('"UserEmailOverrides": {}')) "$archiveName config example omits the managed-user fallback map."

        $cacheEntry = @($archive.Entries | Where-Object { $_.FullName -match '/(?:app/)?DeletedItemCache\.ps1$' } | Select-Object -First 1)
        Assert-True ($cacheEntry.Count -eq 1) "$archiveName has no persistent cache module."
        $cacheReader = New-Object IO.StreamReader($cacheEntry[0].Open())
        try { $cacheModule = $cacheReader.ReadToEnd() }
        finally { $cacheReader.Dispose() }
        Assert-DeletedItemCacheContract -PackageName $archiveName -CacheModule $cacheModule

        $cacheDiagnosticEntry = @($archive.Entries | Where-Object { $_.FullName -match '/(?:app/)?Cache-Diagnostics\.ps1$' } | Select-Object -First 1)
        Assert-True ($cacheDiagnosticEntry.Count -eq 1) "$archiveName has no share-safe cache diagnostic."
        $cacheDiagnosticReader = New-Object IO.StreamReader($cacheDiagnosticEntry[0].Open())
        try { $cacheDiagnostic = $cacheDiagnosticReader.ReadToEnd() }
        finally { $cacheDiagnosticReader.Dispose() }
        Assert-CacheDiagnosticContract -PackageName $archiveName -Diagnostic $cacheDiagnostic

        $readinessEntries = @($archive.Entries | Where-Object {
            $_.FullName -match '/(?:app/)?(?:Setup-First|Verify-Setup)\.ps1$'
        })
        Assert-True ($readinessEntries.Count -eq 2) "$archiveName does not contain one setup and one verification readiness surface."
        $readinessText = New-Object Text.StringBuilder
        foreach ($readinessEntry in $readinessEntries) {
            $readinessReader = New-Object IO.StreamReader($readinessEntry.Open())
            try { [void]$readinessText.AppendLine($readinessReader.ReadToEnd()) }
            finally { $readinessReader.Dispose() }
        }
        Assert-MetadataReadinessContract -PackageName $archiveName -Content $readinessText.ToString()

        foreach ($gifName in $expectedGifHashes.Keys) {
            $gifEntryName = "$($assetRoots[$archiveName])/$gifName"
            $gifEntry = @($archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -ceq $gifEntryName })
            Assert-True ($gifEntry.Count -eq 1) "$archiveName is missing $gifEntryName"
            $actualGifHash = Get-ZipEntrySha256 -Entry $gifEntry[0]
            Assert-True ($actualGifHash -ceq $expectedGifHashes[$gifName]) "$archiveName contains stale $gifName bytes."
        }
        foreach ($watchedAssetName in $expectedWatchedPngs.Keys) {
            $expectedWatchedAsset = $expectedWatchedPngs[$watchedAssetName]
            $watchedEntryName = "$($assetRoots[$archiveName])/$watchedAssetName"
            $watchedEntry = @($archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -ceq $watchedEntryName })
            Assert-True ($watchedEntry.Count -eq 1) "$archiveName is missing $watchedEntryName"
            Assert-True ((Get-ZipEntrySha256 -Entry $watchedEntry[0]) -ceq $expectedWatchedAsset.Hash) "$archiveName contains stale $watchedAssetName bytes."
            $watchedBytes = Get-ZipEntryBytes -Entry $watchedEntry[0]
            Assert-WatchedPngBytes -PackageName $archiveName -AssetName $watchedAssetName -Bytes $watchedBytes -Expected $expectedWatchedAsset
        }
        $packagedPlatformEntries = @($archive.Entries | Where-Object {
            $_.FullName.Replace('\', '/') -match ('^' + [regex]::Escape($assetRoots[$archiveName]) + '/platform-[a-z0-9-]+[.]png$')
        })
        Assert-True ($packagedPlatformEntries.Count -eq $expectedPlatformHashes.Count) "$archiveName does not contain the complete newsletter platform asset set."
        foreach ($platformAssetName in $expectedPlatformHashes.Keys) {
            $platformEntryName = "$($assetRoots[$archiveName])/$platformAssetName"
            $platformEntry = @($packagedPlatformEntries | Where-Object { $_.FullName.Replace('\', '/') -ceq $platformEntryName })
            Assert-True ($platformEntry.Count -eq 1) "$archiveName is missing $platformEntryName"
            Assert-True ((Get-ZipEntrySha256 -Entry $platformEntry[0]) -ceq $expectedPlatformHashes[$platformAssetName]) "$archiveName contains stale $platformAssetName bytes."
            $platformBytes = Get-ZipEntryBytes -Entry $platformEntry[0]
            Assert-True ($platformBytes.Length -gt 24 -and $platformBytes[0] -eq 0x89 -and $platformBytes[1] -eq 0x50 -and $platformBytes[2] -eq 0x4e -and $platformBytes[3] -eq 0x47) "$archiveName $platformAssetName is not a PNG."
            $platformWidth = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($platformBytes, 16))
            $platformHeight = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($platformBytes, 20))
            Assert-True ($platformWidth -eq 42 -and $platformHeight -eq 42) "$archiveName $platformAssetName is not the expected email-safe 2x asset."
        }
        foreach ($brandFile in $expectedBrandFiles[$archiveName].GetEnumerator()) {
            $brandEntry = @($archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -ceq $brandFile.Key })
            Assert-True ($brandEntry.Count -eq 1) "$archiveName is missing exact brand asset $($brandFile.Key)."
            Assert-True ((Get-ZipEntrySha256 -Entry $brandEntry[0]) -ceq $brandFile.Value) "$archiveName changed canonical brand bytes for $($brandFile.Key)."
        }

        Write-Host "[PASS] Release payload contract: $archiveName ($($archive.Entries.Count) entries)"
    }
    finally {
        $archive.Dispose()
    }
}

$tarArchives = @(Get-ChildItem -LiteralPath $DistPath -File -Filter '*.tar.gz')
Assert-True ($tarArchives.Count -eq 4) "Expected four TAR.GZ release artifacts, found $($tarArchives.Count)."
foreach ($tarArchive in $tarArchives) {
    $packageName = $tarArchive.Name.Substring(0, $tarArchive.Name.Length - '.tar.gz'.Length)
    $zipName = "$packageName.zip"
    Assert-True ($expected.Contains($zipName)) "$($tarArchive.Name) has no corresponding ZIP package contract."

    $rawTarEntries = @(& tar -tzf $tarArchive.FullName)
    Assert-True ($LASTEXITCODE -eq 0) "Could not list $($tarArchive.Name)."
    $unsafeEntries = @($rawTarEntries | Where-Object {
        $entry = ([string]$_).Replace('\', '/')
        $entry -match '^(?:/|[A-Za-z]:)' -or @($entry -split '/' | Where-Object { $_ -eq '..' }).Count -gt 0
    })
    Assert-True ($unsafeEntries.Count -eq 0) "$($tarArchive.Name) contains unsafe archive paths: $($unsafeEntries -join ', ')"
    $tarEntries = @($rawTarEntries | ForEach-Object {
        $entry = ([string]$_).Replace('\', '/')
        if ($entry.StartsWith('./', [StringComparison]::Ordinal)) { $entry.Substring(2) } else { $entry }
    })
    $rawTarDetails = @(& tar -tvzf $tarArchive.FullName)
    Assert-True ($LASTEXITCODE -eq 0) "Could not inspect modes in $($tarArchive.Name)."
    $tarModes = @{}
    foreach ($detail in $rawTarDetails) {
        $line = [string]$detail
        $pathOffset = $line.IndexOf("$packageName/", [StringComparison]::Ordinal)
        if ($pathOffset -ge 0 -and $line.Length -ge 10) {
            $tarModes[$line.Substring($pathOffset).TrimEnd('/')] = $line.Substring(0, 10)
        }
    }
    $requiredExecutables = @($tarEntries | Where-Object {
        $_ -match '\.sh$' -or
        $_ -match '/manager/tautweekly-manager-linux-(?:amd64|arm64)$' -or
        $_ -match '/(?:rc\.d/)?tautweekly$'
    })
    foreach ($requiredExecutable in $requiredExecutables) {
        Assert-True ($tarModes.ContainsKey($requiredExecutable)) "$($tarArchive.Name) has no mode metadata for $requiredExecutable."
        Assert-True ($tarModes[$requiredExecutable] -match '^-rwxr-xr-x$') "$($tarArchive.Name) does not mark $requiredExecutable executable (mode $($tarModes[$requiredExecutable]))."
    }
    foreach ($requiredEntry in $expected[$zipName]) {
        Assert-True ($tarEntries -ccontains $requiredEntry) "$($tarArchive.Name) is missing $requiredEntry"
    }

    $extractRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-release-test-' + [Guid]::NewGuid().ToString('N'))
    $extractRoot = [IO.Path]::GetFullPath($extractRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    Assert-True ($extractRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) "Unsafe release test extraction root: $extractRoot"
    try {
        New-Item -ItemType Directory -Path $extractRoot | Out-Null
        & tar -xzf $tarArchive.FullName -C $extractRoot
        Assert-True ($LASTEXITCODE -eq 0) "Could not extract $($tarArchive.Name)."

        $packageRoot = Join-Path $extractRoot $packageName
        Assert-True (Test-Path -LiteralPath $packageRoot -PathType Container) "$($tarArchive.Name) has the wrong top-level directory."
        $files = @(Get-ChildItem -LiteralPath $packageRoot -File -Recurse -Force)
        $relativeFiles = @($files | ForEach-Object {
            $_.FullName.Substring($packageRoot.Length).TrimStart('\', '/').Replace('\', '/')
        })
        $unixScripts = @($files | Where-Object {
            $relativePath = $_.FullName.Substring($packageRoot.Length).TrimStart('\', '/').Replace('\', '/')
            $relativePath -match '\.sh$' -or $relativePath -match '^(?:rc\.d/)?tautweekly$'
        })
        foreach ($unixScript in $unixScripts) {
            $relativePath = $unixScript.FullName.Substring($packageRoot.Length).TrimStart('\', '/').Replace('\', '/')
            $scriptBytes = [IO.File]::ReadAllBytes($unixScript.FullName)
            Assert-True ($scriptBytes.Length -ge 2 -and $scriptBytes[0] -eq 0x23 -and $scriptBytes[1] -eq 0x21) "$($tarArchive.Name) has no shebang for executable script $relativePath."
            Assert-True (-not ($scriptBytes -contains [byte]0x0d)) "$($tarArchive.Name) contains CRLF bytes in executable script $relativePath."
        }
        foreach ($unixTextFile in $files) {
            $relativePath = $unixTextFile.FullName.Substring($packageRoot.Length).TrimStart('\', '/').Replace('\', '/')
            if (-not (Test-UnixTextReleasePath -RelativePath $relativePath)) { continue }
            $textBytes = [IO.File]::ReadAllBytes($unixTextFile.FullName)
            Assert-True (-not ($textBytes -contains [byte]0x0d)) "$($tarArchive.Name) contains CR bytes in Unix text file $relativePath."
        }
        $forbidden = @($relativeFiles | Where-Object {
            $name = ($_ -split '/')[-1]
            $name -in $forbiddenNames -or $_ -match '(^|/)(logs|output|cache)/' -or
                $_ -match '(^|/)tailscale/state/(?!\.keep$).+'
        })
        Assert-True ($forbidden.Count -eq 0) "$($tarArchive.Name) contains runtime/private paths: $($forbidden -join ', ')"

        $manifestFiles = @($files | Where-Object { $_.Name -ceq 'RELEASE-FILES.txt' })
        Assert-True ($manifestFiles.Count -eq 1) "$($tarArchive.Name) has no unique release-owned file manifest."
        $releaseManifest = Get-Content -LiteralPath $manifestFiles[0].FullName -Raw
        $normalizedManifest = ($releaseManifest -replace "`r`n", "`n").Trim()
        Assert-True ($normalizedManifest -ceq $zipReleaseManifests[$packageName]) "$($tarArchive.Name) does not match its corresponding ZIP file manifest."
        Assert-True ($releaseManifest -notmatch '(?im)(?:^|/)(?:config\.json|state\.json|access-state\.json|scheduler-state\.json|\.tautweekly-operation\.lock)$') "$($tarArchive.Name) release manifest owns private runtime files."

        $manifestLines = @($releaseManifest -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Assert-True ($manifestLines.Count -eq ($files.Count - 1)) "$($tarArchive.Name) release manifest does not cover every packaged file except itself."
        $seenManifestPaths = @{}
        foreach ($manifestLine in $manifestLines) {
            Assert-True ($manifestLine -match '^(?<hash>[0-9a-f]{64})\s{2}(?<path>.+)$') "$($tarArchive.Name) has an invalid release manifest line: $manifestLine"
            $relativePath = $Matches['path'].Replace('\', '/')
            Assert-True (@($relativePath -split '/' | Where-Object { $_ -eq '..' }).Count -eq 0) "$($tarArchive.Name) release manifest contains an unsafe path: $relativePath"
            Assert-True (-not $seenManifestPaths.ContainsKey($relativePath.ToLowerInvariant())) "$($tarArchive.Name) release manifest duplicates $relativePath."
            $seenManifestPaths[$relativePath.ToLowerInvariant()] = $true
            $packagedPath = [IO.Path]::GetFullPath((Join-Path $packageRoot $relativePath))
            Assert-True ($packagedPath.StartsWith($packageRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) "$($tarArchive.Name) release manifest escapes its package root: $relativePath"
            Assert-True (Test-Path -LiteralPath $packagedPath -PathType Leaf) "$($tarArchive.Name) release manifest references a missing file: $relativePath"
            $actualHash = (Get-FileHash -LiteralPath $packagedPath -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-True ($actualHash -eq $Matches['hash']) "$($tarArchive.Name) release manifest hash failed for $relativePath."
        }

        $metadataFiles = @($files | Where-Object { $_.Name -ceq 'RELEASE-METADATA.txt' })
        Assert-True ($metadataFiles.Count -eq 1) "$($tarArchive.Name) has no unique release metadata file."
        $metadata = Get-Content -LiteralPath $metadataFiles[0].FullName -Raw
        Assert-True ($metadata -match '(?m)^Repository version:\s*(?<version>\S+)\s*$') "$($tarArchive.Name) does not identify its repository version."
        $releaseVersions.Add($Matches['version'])

        $rendererFiles = @($files | Where-Object { $_.Name -ceq 'TautWeekly.ps1' })
        Assert-True ($rendererFiles.Count -eq 1) "$($tarArchive.Name) has no unique production renderer."
        $renderer = Get-Content -LiteralPath $rendererFiles[0].FullName -Raw
        Assert-RendererContract -PackageName $tarArchive.Name -Renderer $renderer

        $cacheFiles = @($files | Where-Object { $_.Name -ceq 'DeletedItemCache.ps1' })
        Assert-True ($cacheFiles.Count -eq 1) "$($tarArchive.Name) has no unique persistent cache module."
        Assert-DeletedItemCacheContract -PackageName $tarArchive.Name -CacheModule (Get-Content -LiteralPath $cacheFiles[0].FullName -Raw)

        $cacheDiagnosticFiles = @($files | Where-Object { $_.Name -ceq 'Cache-Diagnostics.ps1' })
        Assert-True ($cacheDiagnosticFiles.Count -eq 1) "$($tarArchive.Name) has no unique share-safe cache diagnostic."
        Assert-CacheDiagnosticContract -PackageName $tarArchive.Name -Diagnostic (Get-Content -LiteralPath $cacheDiagnosticFiles[0].FullName -Raw)

        $readinessFiles = @($files | Where-Object { $_.Name -in @('Setup-First.ps1', 'Verify-Setup.ps1') })
        Assert-True ($readinessFiles.Count -eq 2) "$($tarArchive.Name) does not contain one setup and one verification readiness surface."
        $readinessText = ($readinessFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        Assert-MetadataReadinessContract -PackageName $tarArchive.Name -Content $readinessText

        foreach ($gifName in $expectedGifHashes.Keys) {
            $assetRoot = $assetRoots[$zipName].Substring($packageName.Length + 1)
            $gifPath = Join-Path $packageRoot (Join-Path $assetRoot $gifName)
            Assert-True (Test-Path -LiteralPath $gifPath -PathType Leaf) "$($tarArchive.Name) is missing $assetRoot/$gifName"
            $actualGifHash = (Get-FileHash -LiteralPath $gifPath -Algorithm SHA256).Hash
            Assert-True ($actualGifHash -ceq $expectedGifHashes[$gifName]) "$($tarArchive.Name) contains stale $gifName bytes."
        }
        foreach ($watchedAssetName in $expectedWatchedPngs.Keys) {
            $expectedWatchedAsset = $expectedWatchedPngs[$watchedAssetName]
            $assetRoot = $assetRoots[$zipName].Substring($packageName.Length + 1)
            $watchedPath = Join-Path $packageRoot (Join-Path $assetRoot $watchedAssetName)
            Assert-True (Test-Path -LiteralPath $watchedPath -PathType Leaf) "$($tarArchive.Name) is missing $assetRoot/$watchedAssetName"
            $actualWatchedHash = (Get-FileHash -LiteralPath $watchedPath -Algorithm SHA256).Hash
            Assert-True ($actualWatchedHash -ceq $expectedWatchedAsset.Hash) "$($tarArchive.Name) contains stale $watchedAssetName bytes."
            $watchedBytes = [IO.File]::ReadAllBytes($watchedPath)
            Assert-WatchedPngBytes -PackageName $tarArchive.Name -AssetName $watchedAssetName -Bytes $watchedBytes -Expected $expectedWatchedAsset
        }
        foreach ($brandFile in $expectedBrandFiles[$zipName].GetEnumerator()) {
            $relativeBrandPath = $brandFile.Key.Substring($packageName.Length + 1)
            $brandPath = Join-Path $packageRoot $relativeBrandPath
            Assert-True (Test-Path -LiteralPath $brandPath -PathType Leaf) "$($tarArchive.Name) is missing exact brand asset $relativeBrandPath."
            Assert-True ((Get-FileHash -LiteralPath $brandPath -Algorithm SHA256).Hash -ceq $brandFile.Value) "$($tarArchive.Name) changed canonical brand bytes for $relativeBrandPath."
        }

        Write-Host "[PASS] Release payload contract: $($tarArchive.Name) ($($files.Count) files)"
    }
    finally {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Assert-True ($releaseVersions.Count -eq 9) "Expected repository version metadata from all nine packages, found $($releaseVersions.Count)."
Assert-True (@($releaseVersions | Select-Object -Unique).Count -eq 1) 'Release packages do not identify one consistent repository version.'

$repositoryVersion = @($releaseVersions | Select-Object -Unique)[0]
$macComposePath = Join-Path $DistPath 'TautWeekly-mac-compose.yaml'
Assert-True (Test-Path -LiteralPath $macComposePath -PathType Leaf) 'The standalone Mac Compose release asset is missing.'
$macCompose = Get-Content -LiteralPath $macComposePath -Raw
Assert-True (-not $macCompose.Contains('__TAUTWEEKLY_RELEASE_VERSION__')) 'The standalone Mac Compose asset contains an unresolved release token.'
Assert-True ($macCompose.Contains("ghcr.io/sparkmoxie/tautweekly:$repositoryVersion")) 'The standalone Mac Compose asset does not default to the unified release-semver image.'
Assert-True ($macCompose.Contains("TAUTWEEKLY_VERSION:-$repositoryVersion")) 'The standalone Mac Compose asset does not report the same package version.'
Assert-True ($macCompose.Contains('TAUTWEEKLY_RUNTIME_PROFILE: "desktop"')) 'The standalone Mac Compose asset does not select the desktop profile.'
Assert-True ($macCompose.Contains('TAUTWEEKLY_PACKAGE_KIND: "container-desktop"')) 'The standalone Mac Compose asset does not identify unified desktop ownership.'
Assert-True ($macCompose.Contains('${PREVIEW_BIND:-127.0.0.1}:${PREVIEW_PORT:-8787}:8080')) 'The standalone Mac Compose asset is not loopback-first.'
Assert-True ($macCompose.Contains('tautweekly-data:/data') -and $macCompose.Contains('volumes:')) 'The standalone Mac Compose asset does not persist /data in a named volume.'
Assert-True ($macCompose.Contains('read_only: true') -and $macCompose.Contains('no-new-privileges:true') -and $macCompose.Contains('cap_drop:')) 'The standalone Mac Compose asset is missing the read-only security boundary.'
Assert-True ($macCompose.Contains('stop_grace_period: 30m')) 'The standalone Mac Compose asset does not preserve the delivery shutdown grace.'
Assert-True ($macCompose -notmatch '(?m)^\s*build\s*:') 'The standalone Mac Compose asset unexpectedly requires a local source build.'

$serverComposePath = Join-Path $DistPath 'TautWeekly-compose.yaml'
Assert-True (Test-Path -LiteralPath $serverComposePath -PathType Leaf) 'The standalone server Compose release asset is missing.'
$serverCompose = Get-Content -LiteralPath $serverComposePath -Raw
Assert-True (-not $serverCompose.Contains('__TAUTWEEKLY_RELEASE_VERSION__')) 'The standalone server Compose asset contains an unresolved release token.'
Assert-True ($serverCompose.Contains("ghcr.io/sparkmoxie/tautweekly:$repositoryVersion")) 'The standalone server Compose asset does not default to the unified release-semver image.'
Assert-True ($serverCompose.Contains('TAUTWEEKLY_RUNTIME_PROFILE: "server"')) 'The standalone server Compose asset does not select the server profile.'
Assert-True ($serverCompose.Contains('TAUTWEEKLY_PACKAGE_KIND: "container-compose"')) 'The standalone server Compose asset does not report unified Compose ownership.'
Assert-True ($serverCompose.Contains('${PREVIEW_BIND:-127.0.0.1}:${PREVIEW_PORT:-8787}:8080')) 'The standalone server Compose asset is not loopback-first for public Funnel ingress.'
Assert-True ($serverCompose.Contains('./data:/data')) 'The standalone server Compose asset does not preserve its bind-mounted /data path.'
Assert-True ($serverCompose.Contains('read_only: true') -and $serverCompose.Contains('no-new-privileges:true') -and $serverCompose.Contains('stop_grace_period: 30m')) 'The standalone server Compose asset is missing security or graceful-stop controls.'
Assert-True ($serverCompose -notmatch '(?m)^\s*build\s*:') 'The standalone server Compose asset unexpectedly requires a local source build.'

$nasZip = [IO.Compression.ZipFile]::OpenRead((Join-Path $DistPath 'TautWeekly-nas-docker.zip'))
$macZip = [IO.Compression.ZipFile]::OpenRead((Join-Path $DistPath 'TautWeekly-mac-docker.zip'))
try {
    $nasPayload = @($nasZip.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) -and $_.FullName.StartsWith('TautWeekly-nas-docker/app/') })
    foreach ($nasEntry in $nasPayload) {
        $relative = $nasEntry.FullName.Substring('TautWeekly-nas-docker/app/'.Length)
        $macEntry = $macZip.GetEntry('TautWeekly-mac-docker/app/' + $relative)
        Assert-True ($null -ne $macEntry) "The Mac fallback is missing canonical app payload entry $relative."
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $nasStream = $nasEntry.Open()
            try { $nasHash = [Convert]::ToHexString($sha.ComputeHash($nasStream)) } finally { $nasStream.Dispose() }
            $macStream = $macEntry.Open()
            try { $macHash = [Convert]::ToHexString($sha.ComputeHash($macStream)) } finally { $macStream.Dispose() }
        }
        finally { $sha.Dispose() }
        Assert-True ($nasHash -ceq $macHash) "The Mac fallback diverges from canonical app payload entry $relative."
    }
}
finally {
    $nasZip.Dispose()
    $macZip.Dispose()
}
$checksumPath = Join-Path $DistPath 'SHA256SUMS.txt'
Assert-True (Test-Path -LiteralPath $checksumPath) 'SHA256SUMS.txt is missing.'
$checksumLines = @(Get-Content -LiteralPath $checksumPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$artifacts = @(Get-ChildItem -LiteralPath $DistPath -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' })
Assert-True ($artifacts.Count -eq 12) "Expected twelve release artifacts, found $($artifacts.Count)."
Assert-True ($checksumLines.Count -eq $artifacts.Count) 'Checksum manifest does not cover every artifact exactly once.'
foreach ($artifact in $artifacts) {
    $line = @($checksumLines | Where-Object { $_ -match ('\s\s' + [regex]::Escape($artifact.Name) + '$') })
    Assert-True ($line.Count -eq 1) "Checksum entry is missing or duplicated for $($artifact.Name)."
    $expectedHash = ($line[0] -split '\s+', 2)[0].ToUpperInvariant()
    $actualHash = (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    Assert-True ($expectedHash -eq $actualHash) "SHA-256 mismatch for $($artifact.Name)."
}

Write-Host 'Release artifact functional contracts and SHA-256 checks passed.' -ForegroundColor Green
