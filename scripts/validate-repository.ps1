[CmdletBinding()]
param(
    [string]$Root = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([string]$Message)
    $script:failures.Add($Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Add-Pass {
    param([string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

$required = @(
    'README.md', 'LICENSE', 'SECURITY.md', 'CONTRIBUTING.md', 'CONTRIBUTORS.md', 'CHANGELOG.md',
    'CODE_OF_CONDUCT.md', 'THIRD_PARTY_NOTICES.md', '.gitignore', '.gitattributes',
    'ca_profile.xml', 'templates/tautweekly.xml',
    'platforms/windows/TautWeekly.ps1',
    'platforms/windows/assets/watched.png',
    'platforms/windows/assets/watched-desktop.png',
    'platforms/windows/DeletedItemCache.ps1',
    'platforms/windows/Cache-Diagnostics.ps1',
    'platforms/windows/Smtp-Transport.ps1',
    'platforms/windows/Check-Update.ps1',
    'platforms/windows/Windows-Update.ps1',
    'platforms/windows/Operation-Lock.ps1',
    'platforms/windows/SCHEDULE-HELPER.ps1',
    'platforms/windows/TAILSCALE-HELPER.ps1',
    'platforms/windows/START-MANAGER.ps1',
    'platforms/windows/00-OPEN-MANAGER.bat',
    'platforms/windows/RESET-MANAGER-ACCESS.ps1',
    'platforms/windows/18-RESET-MANAGER-ACCESS.bat',
    'platforms/windows/19-CACHE-DIAGNOSTICS.bat',
    'platforms/windows/20-REFRESH-DELETED-ITEM-CACHE.bat',
    'platforms/windows/17-CHECK-FOR-UPDATE.bat',
    'platforms/nas-docker/compose.yaml',
    'platforms/nas-docker/compose.qnap.yaml',
    'platforms/nas-docker/tautweekly.sh',
    'platforms/nas-docker/container-update.sh',
    'platforms/nas-docker/app/preview-home.html',
    'platforms/nas-docker/app/bin/run-as-user.sh',
    'platforms/nas-docker/app/bin/funnel-adapter.sh',
    'platforms/nas-docker/app/bin/tautweekly-funnel',
    'platforms/nas-docker/app/bin/run-script.sh',
    'platforms/nas-docker/app/Schedule-Time.ps1',
    'platforms/nas-docker/app/TautWeekly.ps1',
    'platforms/nas-docker/app/assets-default/watched.png',
    'platforms/nas-docker/app/assets-default/watched-desktop.png',
    'platforms/nas-docker/app/DeletedItemCache.ps1',
    'platforms/nas-docker/app/Cache-Diagnostics.ps1',
    'platforms/nas-docker/app/Smtp-Transport.ps1',
    'platforms/mac-docker/compose.yaml',
    'platforms/mac-docker/tautweekly.sh',
    'platforms/mac-docker/check-release.sh',
    'platforms/mac-docker/mac-update.sh',
    'platforms/mac-docker/app/preview-home.html',
    'platforms/mac-docker/app/bin/run-as-user.sh',
    'platforms/mac-docker/app/bin/funnel-adapter.sh',
    'platforms/mac-docker/app/bin/tautweekly-funnel',
    'platforms/mac-docker/app/bin/run-script.sh',
    'platforms/mac-docker/app/Schedule-Time.ps1',
    'platforms/mac-docker/app/TautWeekly.ps1',
    'platforms/mac-docker/app/assets-default/watched.png',
    'platforms/mac-docker/app/assets-default/watched-desktop.png',
    'platforms/mac-docker/app/DeletedItemCache.ps1',
    'platforms/mac-docker/app/Cache-Diagnostics.ps1',
    'platforms/mac-docker/app/Smtp-Transport.ps1',
    'platforms/linux/install-linux.sh',
    'platforms/linux/tautweekly',
    'platforms/linux/check-release.sh',
    'platforms/linux/preview-home.html',
    'platforms/linux/systemd/tautweekly.service',
    'platforms/linux/systemd/tautweekly-remote-access.socket',
    'platforms/linux/systemd/tautweekly-remote-access@.service',
    'platforms/freebsd-podman/install-freebsd.sh',
    'platforms/freebsd-podman/tautweekly',
    'platforms/freebsd-podman/rc.d/tautweekly',
    'docs/index.html', 'docs/windows/README.md', 'docs/nas-docker/README.md',
    'docs/mac/README.md', 'docs/linux/README.md', 'docs/freebsd/README.md',
    'assets/branding/tautweekly-logo-source.png',
    'assets/branding/tautweekly-logo-transparent-source.png',
    'assets/branding/tautweekly-logo-master.png',
    'assets/branding/tautweekly-app-icon-1024.png',
    'assets/branding/build-assets.py',
    'assets/branding/SHA256SUMS.txt',
    'assets/platforms/README.md', 'assets/platforms/ASSET-SHA256SUMS.txt',
    'docs/favicon.ico', 'docs/site.webmanifest',
    'docs/assets/quickstart.css', 'docs/assets/quickstart.js',
    'platforms/windows/TautWeekly.ico',
    'docs/WEBGUI-IMPLEMENTATION.md',
    'manager/go.mod', 'manager/cmd/tautweekly-manager/main.go',
    'manager/internal/manager/server.go', 'manager/internal/manager/web/index.html',
    'installer/go.mod', 'installer/assets/tautweekly.ico',
    'installer/cmd/tautweekly-setup/main.go', 'installer/cmd/tautweekly-setup/rsrc_windows_amd64.syso',
    'scripts/build-releases.ps1', 'scripts/validate-branding.ps1', 'scripts/validate-platforms.ps1',
    'scripts/test-container-health.sh',
    'scripts/test-linux-manager-package.sh',
    'scripts/test-deleted-item-cache.ps1', 'scripts/test-cache-diagnostics.ps1',
    'scripts/test-recipient-watched-movies.ps1',
    'scripts/test-recipient-watched-visuals.mjs',
    'scripts/test-release-reproducibility.ps1',
    'scripts/validate-release-history.ps1',
    'scripts/test-windows-installer.ps1',
    'scripts/test-scheduler-timezone.ps1',
    'scripts/test-manager-accessibility.py',
    'scripts/test-manager-header-refresh.mjs',
    'scripts/test-manager-user-email-overrides.mjs',
    'scripts/test-smtp-transport.py',
    'scripts/optimize-email-gifs.py',
    'scripts/test-asset-refresh.py',
    'assets/email-gifs.json',
    'platforms/nas-docker/app/refresh-assets.py',
    'platforms/mac-docker/app/refresh-assets.py',
    'scripts/test-support/fake-smtp.py',
    'scripts/test-support/fake-tautulli.py',
    'scripts/test-update-checks.ps1',
    'scripts/test-update-management.sh',
    'scripts/validate-unraid-template.ps1',
    '.github/workflows/ci.yml', '.github/workflows/pages.yml',
    '.github/workflows/release.yml',
    '.github/workflows/container.yml'
)

foreach ($relative in $required) {
    $path = Join-Path $Root $relative
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Failure "Required path is missing: $relative"
    }
}
if ($failures.Count -eq 0) { Add-Pass "Required repository structure is present." }

$readme = [IO.File]::ReadAllText((Join-Path $Root 'README.md'))
$contributing = [IO.File]::ReadAllText((Join-Path $Root 'CONTRIBUTING.md'))
$contributors = [IO.File]::ReadAllText((Join-Path $Root 'CONTRIBUTORS.md'))
if (-not $readme.Contains('[Contributors](CONTRIBUTORS.md)')) {
    Add-Failure 'README.md is missing its prominent contributor-attribution link.'
}
if (-not $contributing.Contains('[contributors ledger](CONTRIBUTORS.md)')) {
    Add-Failure 'CONTRIBUTING.md is missing the contributor-attribution hierarchy.'
}
$contributorContract = @(
    '[All Contributors](https://allcontributors.org/en/reference/)',
    '| Contributor | Contribution | Evidence | Shipped correction |',
    '`bug`',
    '`enhancement`',
    'https://github.com/Demonmeister',
    'https://github.com/gianfelicevincenzo',
    'https://github.com/Joloxx9',
    'https://github.com/sparkmoxie/TautWeekly/issues/6',
    'https://github.com/sparkmoxie/TautWeekly/issues/7',
    'https://github.com/sparkmoxie/TautWeekly/issues/11',
    'https://github.com/sparkmoxie/TautWeekly/issues/15',
    'https://github.com/sparkmoxie/TautWeekly/issues/31',
    'https://github.com/sparkmoxie/TautWeekly/pull/36',
    'https://github.com/sparkmoxie/TautWeekly/releases/tag/v0.6.2',
    'https://github.com/sparkmoxie/TautWeekly/issues/38',
    'https://github.com/sparkmoxie/TautWeekly/pull/39',
    'https://github.com/sparkmoxie/TautWeekly/releases/tag/v0.6.3'
)
foreach ($expected in $contributorContract) {
    if (-not $contributors.Contains($expected)) {
        Add-Failure "Contributor attribution is missing required structure or evidence: $expected"
    }
}
if (-not ($failures | Where-Object { $_ -like '*contributor*' -or $_ -like '*Contributor*' })) {
    Add-Pass 'Contributor attribution structure and evidence links are present.'
}

$forbiddenNames = @(
    '.tautweekly-asset-bundle',
    'config.json', '.env', 'state.json', 'access-state.json', 'remote-access.json',
    'scheduler-state.json', 'scheduler-heartbeat.json', 'service-heartbeat.json',
    'configuration-status.json', 'last-run.json', 'deleted-item-cache.json',
    '.tautweekly-operation.lock', 'authkey.local'
)
$forbiddenDirectories = @('logs', 'output', 'cache', '.manager-data', '__pycache__')

$items = Get-ChildItem -LiteralPath $Root -Force -Recurse |
    Where-Object { $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)' }

foreach ($item in $items) {
    $relative = $item.FullName.Substring($Root.Length).TrimStart('\','/')
    if (-not $item.PSIsContainer -and ($item.Name -in $forbiddenNames -or $item.Name -like 'config.backup.*.json')) {
        Add-Failure "Forbidden runtime file is present: $relative"
    }
    if (-not $item.PSIsContainer -and $relative -match '(?i)(^|[\\/])tailscale[\\/]state[\\/](?!\.keep$)') {
        Add-Failure "Forbidden Tailscale node state is present: $relative"
    }
    if ($item.PSIsContainer -and $item.Name -in $forbiddenDirectories) {
        Add-Failure "Forbidden runtime directory is present: $relative"
    }
    if (-not $item.PSIsContainer -and ($item.Name -like '*.log' -or $item.Name -like '*.log.*' -or $item.Extension -in @('.pfx', '.pem', '.key'))) {
        Add-Failure "Forbidden credential/log file is present: $relative"
    }
}
if (-not ($items | Where-Object {
    (-not $_.PSIsContainer -and ($_.Name -in $forbiddenNames -or $_.Name -like 'config.backup.*.json' -or $_.Name -like '*.log' -or $_.Name -like '*.log.*' -or $_.Extension -in @('.pfx','.pem','.key') -or $_.FullName -match '[\\/]tailscale[\\/]state[\\/](?!\.keep$)')) -or
    ($_.PSIsContainer -and $_.Name -in $forbiddenDirectories)
})) { Add-Pass "No forbidden runtime or credential files are present." }

$textExtensions = @('.ps1','.psm1','.sh','.command','.bat','.json','.yaml','.yml','.md','.txt','.html','.css','.js','.xml','.env','.example')
$textNames = @('LICENSE','Dockerfile','.gitignore','.gitattributes','.dockerignore')
$textFiles = Get-ChildItem -LiteralPath $Root -Force -Recurse -File | Where-Object {
    $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)' -and
    $_.FullName -notmatch '[\\/]dist(?:[\\/]|$)' -and
    ($_.Extension -in $textExtensions -or $_.Name -in $textNames)
}

$retiredBrandPattern = '(?i)Plex' + '[\s_.-]*' + 'Weekly'
$retiredBrandFindings = [System.Collections.Generic.List[string]]::new()
foreach ($item in $items) {
    if ($item.Name -match $retiredBrandPattern) {
        $relative = $item.FullName.Substring($Root.Length).TrimStart('\','/')
        $retiredBrandFindings.Add("path: $relative")
    }
}
foreach ($file in $textFiles) {
    $content = [IO.File]::ReadAllText($file.FullName)
    if ($content -match $retiredBrandPattern) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\','/')
        $retiredBrandFindings.Add("text: $relative")
    }
}
if ($retiredBrandFindings.Count -gt 0) {
    Add-Failure "Retired product branding is present: $($retiredBrandFindings -join ', ')"
}
else {
    Add-Pass 'No retired product branding is present in paths or text files.'
}

$checks = [ordered]@{
    'private IPv4 address' = '(?<!\d)(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})(?!\d)'
    'Windows user path' = '(?i)[A-Z]:\\Users\\[^\\\s"<>]+'
    'Unix user path' = '(?i)/(?:Users|home)/[^/\s"<>]+'
    'GitHub token' = '(?i)\bgh[pousr]_[A-Za-z0-9]{20,}\b'
    'private key block' = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
}

foreach ($file in $textFiles) {
    $content = [IO.File]::ReadAllText($file.FullName)
    $relative = $file.FullName.Substring($Root.Length).TrimStart('\','/')
    foreach ($check in $checks.GetEnumerator()) {
        if ($content -match $check.Value) {
            Add-Failure "$($check.Key) found in $relative"
        }
    }

    foreach ($emailMatch in [regex]::Matches($content, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b')) {
        $email = $emailMatch.Value.ToLowerInvariant()
        if ($email -notmatch '@(?:example\.com|example\.org|example\.net|users\.noreply\.github\.com)$') {
            Add-Failure "Non-example email address found in ${relative}: $email"
        }
    }
}
if ($failures.Count -eq 0) { Add-Pass "Privacy and high-confidence secret patterns are clean." }

$jsonFiles = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.json' |
    Where-Object { $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)' }
foreach ($json in $jsonFiles) {
    try {
        [void](Get-Content -LiteralPath $json.FullName -Raw | ConvertFrom-Json)
    }
    catch {
        Add-Failure "Invalid JSON: $($json.FullName.Substring($Root.Length).TrimStart('\','/')) - $($_.Exception.Message)"
    }
}
if ($jsonFiles.Count -gt 0 -and -not ($failures | Where-Object { $_ -like 'Invalid JSON:*' })) {
    Add-Pass "Parsed $($jsonFiles.Count) JSON file(s)."
}

$examples = Get-ChildItem -LiteralPath (Join-Path $Root 'platforms') -Recurse -File -Filter 'config.example.json'
foreach ($example in $examples) {
    $config = Get-Content -LiteralPath $example.FullName -Raw | ConvertFrom-Json
    if ([string]$config.ApiKey -notmatch '^PASTE_') {
        Add-Failure "ApiKey is not a placeholder in $($example.FullName.Substring($Root.Length).TrimStart('\','/'))"
    }
    if ([string]$config.SmtpPassword -notmatch '^PASTE_') {
        Add-Failure "SmtpPassword is not a placeholder in $($example.FullName.Substring($Root.Length).TrimStart('\','/'))"
    }
    if (-not [string]::IsNullOrEmpty([string]$config.PlexToken)) {
        Add-Failure "PlexToken must be blank in $($example.FullName.Substring($Root.Length).TrimStart('\','/'))"
    }
}
if (-not ($failures | Where-Object { $_ -like '*placeholder*' -or $_ -like 'PlexToken must*' })) {
    Add-Pass "Sanitized configuration examples use safe placeholders."
}

if ($failures.Count -gt 0) {
    throw "Repository validation failed with $($failures.Count) finding(s)."
}

Write-Host "Repository validation passed." -ForegroundColor Green
