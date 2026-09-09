[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)

function Read-RepoFile([string]$Relative) {
    return [IO.File]::ReadAllText((Join-Path $Root $Relative))
}

function Require-Text([string]$Relative, [string[]]$Patterns) {
    $content = Read-RepoFile $Relative
    foreach ($pattern in $Patterns) {
        if ($content -notmatch $pattern) {
            throw "Required platform contract '$pattern' is missing from $Relative"
        }
    }
    Write-Host "[PASS] Platform contract: $Relative"
}

function Forbid-Text([string]$Relative, [string[]]$Patterns) {
    $content = Read-RepoFile $Relative
    foreach ($pattern in $Patterns) {
        if ($content -match $pattern) {
            throw "Forbidden platform contract '$pattern' is present in $Relative"
        }
    }
    Write-Host "[PASS] Forbidden platform behavior absent: $Relative"
}

Require-Text 'platforms/linux/systemd/tautweekly.service' @(
    'User=tautweekly',
    'ProtectSystem=strict',
    'ReadWritePaths=/var/lib/tautweekly',
    'NoNewPrivileges=true',
    'TAUTWEEKLY_MANAGER_RUNTIME_MODE=linux',
    'TAUTWEEKLY_MANAGER_LISTEN=127\.0\.0\.1:8788',
    'TAUTWEEKLY_PACKAGE_KIND=linux-native',
    'TimeoutStopSec=30min'
)
Require-Text 'platforms/linux/systemd/tautweekly-remote-access.socket' @(
    'ConditionPathExists=/etc/tautweekly/remote-access\.enabled',
    'ListenStream=/run/tautweekly/remote-access\.sock',
    'SocketUser=root',
    'SocketGroup=tautweekly',
    'SocketMode=0660',
    'Accept=yes'
)
Require-Text 'platforms/linux/systemd/tautweekly-remote-access@.service' @(
    'User=root',
    'ExecStart=/opt/tautweekly/bin/tautweekly-manager remote-access-helper',
    'StandardInput=socket',
    'StandardOutput=socket',
    'CapabilityBoundingSet=',
    'NoNewPrivileges=true',
    'ProtectSystem=strict',
    'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6'
)
Require-Text 'platforms/linux/tautweekly.env.example' @(
    'TAUTWEEKLY_PREVIEW_BIND=127\.0\.0\.1',
    'TAUTWEEKLY_DATA_DIR=/var/lib/tautweekly',
    'TAUTWEEKLY_MANAGER_RUNTIME_MODE=linux',
    'TAUTWEEKLY_MANAGER_LISTEN=127\.0\.0\.1:8788',
    'TAUTWEEKLY_MANAGER_SECURE_COOKIES=false'
)
Require-Text 'platforms/linux/install-linux.sh' @(
    'PowerShell 7\.2 or newer',
    'runuser -u tautweekly -- python3 /opt/tautweekly/refresh-assets\.py --data-root /var/lib/tautweekly',
    'convert curl flock identify',
    'program-\$stamp\.tar\.gz',
    'Preserved existing /etc/tautweekly/tautweekly\.env',
    '\.tautweekly-operation\.lock',
    'RELEASE-METADATA\.txt',
    'tautweekly-check-release',
    'tautweekly-package-update',
    'systemctl is-active --quiet tautweekly\.service',
    'tautweekly-manager-linux-\$manager_arch',
    'manager-bootstrap',
    'http://127\.0\.0\.1:8788'
)
Require-Text 'platforms/linux/check-release.sh' @(
    'releases/latest',
    'TAUTWEEKLY_LATEST_RELEASE_VERSION',
    'Latest stable release',
    'A stable update is available'
)
Require-Text 'platforms/linux/tautweekly' @(
    'check-update',
    'tautweekly-package-update',
    'manager-bootstrap',
    'manager-reset-access',
    'access-recover',
    'http://127\.0\.0\.1:8788',
    'remote-access-authorize',
    'remote-access-revoke',
    'remote-access-status'
)
Require-Text 'platforms/linux/preview-home.html' @(
    'authenticated native Linux Manager endpoint',
    'The Manager is the setup source',
    'manager-bootstrap',
    'http://127\.0\.0\.1:8788',
    'Routine TautWeekly updates do not require'
)
Forbid-Text 'platforms/linux/preview-home.html' @('Docker Compose', 'Unraid container Console')
Require-Text 'platforms/freebsd-podman/rc.d/tautweekly' @(
    'REQUIRE: NETWORKING linux podman',
    '--os=linux',
    'TAUTWEEKLY_PREVIEW_BIND:=127\.0\.0\.1',
    'TAUTWEEKLY_PODMAN_BIN:=/usr/local/bin/podman',
    '/var/db/tautweekly',
    'TAUTWEEKLY_MANAGER_RUNTIME_MODE=nas',
    'TAUTWEEKLY_MANAGER_ALLOWED_HOSTS',
    'TAUTWEEKLY_MANAGER_SECURE_COOKIES',
    'TAUTWEEKLY_PACKAGE_KIND=freebsd-podman',
    'TAUTWEEKLY_PACKAGE_VERSION=',
    'TAUTWEEKLY_HOST_ADAPTER_API=4',
    'TAUTWEEKLY_FUNNEL_ADAPTER=',
    '/var/lib/tautweekly-tailscale',
    '--tmpfs /run:rw,noexec,nosuid,size=16m',
    '--read-only',
    '--security-opt no-new-privileges',
    '--cap-drop ALL',
    '--stop-timeout=1800',
    'stop --time 1800'
)
Require-Text 'platforms/freebsd-podman/install-freebsd.sh' @(
    'sysrc linux_enable=YES',
    '/usr/local/sbin/tautweekly update-image',
    'tautweekly-package-update',
    'Preserved existing /usr/local/etc/tautweekly/tautweekly\.env',
    'manager-bootstrap',
    'one-time pairing token',
    'never\s+written to the installer or service logs',
    'Automatic\s+sending remains disabled'
)
Require-Text 'platforms/freebsd-podman/tautweekly.env.example' @(
    'TAUTWEEKLY_PREVIEW_BIND=127\.0\.0\.1',
    'TAUTWEEKLY_MANAGER_ALLOWED_HOSTS=',
    'TAUTWEEKLY_MANAGER_SECURE_COOKIES=false'
)
Forbid-Text 'platforms/freebsd-podman/rc.d/tautweekly' @('io\.containers\.autoupdate')
Require-Text 'platforms/freebsd-podman/tautweekly' @(
    'check-update',
    'manager-bootstrap',
    'manager-reset-access',
    'access-bootstrap',
    'access-recover',
    'flock -n /data/\.tautweekly-operation\.lock',
    '\.tautweekly-update-holder',
    'pull --os=linux',
    'TAUTWEEKLY_PACKAGE_KIND=freebsd-podman',
    'Rollback to image version',
    'health verification',
    'run-script\.sh',
    'run-as-user\.sh /bin/bash'
)
Require-Text 'platforms/nas-docker/app/run-service.sh' @(
    'Authenticated (?:Linux|desktop-container|Unraid|server-container) Manager listening',
    'tautweekly-manager.*serve',
    '--runtime-mode "\$manager_runtime_mode"',
    'TAUTWEEKLY_MANAGER_RUNTIME_MODE',
    '--runtime-root',
    'curl --fail --silent --max-time 2',
    'service-heartbeat\.json',
    'write_service_heartbeat',
    'active newsletter operation to finish',
    "trap 'term; exit 0' TERM INT",
    'Manager exited unexpectedly',
    'Scheduler exited unexpectedly'
)
Require-Text 'platforms/nas-docker/app/healthcheck.sh' @(
    'service-heartbeat\.json',
    'TAUTWEEKLY_HEALTH_HEARTBEAT_MAX_SECONDS',
    'Service supervisor heartbeat is stale',
    'health/live',
    'Manager liveness did not respond'
)
Require-Text 'platforms/nas-docker/app/Scheduler.ps1' @(
    'only reads \$configPath',
    'authenticated Manager',
    'persistent storage',
    'Get-TautWeeklyScheduleNow',
    'TimeZoneId = \$scheduleTimeZone\.Id'
)
Require-Text 'platforms/nas-docker/app/Schedule-Time.ps1' @(
    'FindSystemTimeZoneById',
    'ConvertTime',
    'ConvertTimeToUtc',
    'refusing to fall back to UTC'
)
Require-Text 'platforms/nas-docker/app/preview-home.html' @(
    'Manager online',
    'The Manager is the setup source',
    'manager-bootstrap',
    '\/data\/config\.json',
    'Validate, save, and verify',
    'six previews',
    'Update and recovery',
    'Terminal helpers are expert and recovery fallbacks'
)
Forbid-Text 'platforms/nas-docker/app/preview-home.html' @(
    'Setup-First\.ps1',
    '\.\/tautweekly\.sh setup',
    'not an admin Web UI',
    'Unraid container Console'
)
Require-Text 'platforms/nas-docker/app/Setup-First.ps1' @(
    'return to the authenticated Manager',
    'Pairing fallback:',
    'Expert verification fallback:',
    'Metadata readiness before Verify, Preview, or TestEmail',
    'Refresh All Metadata',
    'Library > Media Info > Refresh media info',
    'current Tautulli control is per library',
    'Routine TautWeekly updates do'
)
Require-Text 'platforms/nas-docker/app/Verify-Setup.ps1' @(
    'Return to the authenticated Manager',
    'Terminal list-users/preview-all/send-test-all commands are expert fallbacks',
    '\/health\/live',
    'authenticated Manager liveness responds',
    'Preview HTML and assets require a Manager session',
    'prove metadata freshness',
    'Refresh All Metadata',
    'Library > Media Info > Refresh media info'
)
Forbid-Text 'platforms/nas-docker/app/Verify-Setup.ps1' @('assets\/movies\.gif', 'preview asset web check')
Require-Text 'platforms/windows/SETUP-FIRST.ps1' @(
    'Metadata readiness before Verify, Preview, or TestEmail',
    'Refresh All Metadata',
    'Library > Media Info > Refresh media info',
    'current Tautulli control is per library',
    'Routine TautWeekly updates do'
)
Require-Text 'platforms/windows/VERIFY-SETUP.ps1' @(
    'prove metadata freshness',
    'Refresh All Metadata',
    'Library > Media Info > Refresh media info'
)
foreach ($relative in @(
    'platforms/windows/INSTALL-SCHEDULE.ps1',
    'platforms/windows/REMOVE-SCHEDULE.ps1'
)) {
    Require-Text $relative @(
        'Get-FileHash -LiteralPath \$configPath -Algorithm SHA256',
        'SCHEDULE-HELPER\.ps1',
        '-ExpectedRevision \$revision'
    )
    Forbid-Text $relative @('Unregister-ScheduledTask', 'Register-ScheduledTask')
}
Require-Text 'platforms/windows/VERIFY-SCHEDULE.ps1' @(
    'Ownership:\s+Verified',
    'not owned by this TautWeekly installation',
    'Principal\.UserId -ieq ''SYSTEM'''
)
Require-Text 'platforms/mac-docker/app/Setup-First.ps1' @(
    'Metadata readiness before Verify, Preview, or TestEmail',
    'Refresh All Metadata',
    'Library > Media Info > Refresh media info',
    'current Tautulli control is per library',
    'Routine TautWeekly updates do'
)
Require-Text 'platforms/mac-docker/app/Verify-Setup.ps1' @(
    'prove metadata freshness',
    'Refresh All Metadata',
    'Library > Media Info > Refresh media info'
)
foreach ($relative in @(
    'platforms/windows/Windows-Update.ps1',
    'platforms/nas-docker/container-update.sh',
    'platforms/mac-docker/mac-update.sh',
    'platforms/linux/install-linux.sh',
    'platforms/freebsd-podman/tautweekly'
)) {
    Require-Text $relative @(
        'missing ratings/artwork|ratings/artwork\s+recovery update',
        'Refresh All Metadata',
        'Library > Media Info > Refresh media info'
    )
}
foreach ($relative in @(
    'platforms/nas-docker/app/preview-home.html',
    'platforms/mac-docker/app/preview-home.html'
)) {
    Require-Text $relative @(
        'Prepare Plex and Tautulli metadata before testing',
        'Refresh All Metadata',
        'Refresh media\s+info',
        'current control is per library'
    )
}
Require-Text 'platforms/nas-docker/qnap-install.sh' @(
    'manager-bootstrap',
    'one-time pairing token',
    'never printed to container logs',
    'Automatic\s+sending remains disabled',
    'MANAGER_ALLOWED_HOSTS'
)
Forbid-Text 'platforms/nas-docker/qnap-install.sh' @('Setup-First\.ps1', 'press Enter to run verification')
Require-Text 'platforms/mac-docker/mac-install.sh' @(
    'authenticated Manager is running',
    'manager-bootstrap',
    'one-time pairing token',
    'create the administrator password',
    'Save and verify',
    'all six authenticated previews',
    'TestEmail',
    'MANAGER_ALLOWED_HOSTS'
)
Forbid-Text 'platforms/mac-docker/mac-install.sh' @('Setup-First\.ps1', 'press Enter to run verification')
Require-Text 'docs/nas-docker/README.md' @(
    'host-side Compose wrapper',
    'does not exist inside the Unraid Apps container',
    "Unraid's Docker controls"
)
Require-Text 'docs/nas-docker/index.html' @('url=manager\.html', 'location\.replace\("manager\.html"')
Require-Text 'docs/nas-docker/index.html' @('authenticated Manager is the setup source', 'controlled TestEmail delivery, scheduling, unified-image profile/status, v0\.22\.0 migration, rollback, recovery')
Forbid-Text 'docs/nas-docker/index.html' @('Setup-First\.ps1', '\.\/tautweekly\.sh setup', 'read-only preview viewer')
Require-Text 'docs/nas-docker/manager.html' @(
    'Manager authentication',
    'manager-bootstrap',
    'manager-reset-access',
    'MANAGER_ALLOWED_HOSTS',
    'Secure session boundary',
    'Funnel hostname receives Secure cookies and HSTS automatically',
    '\/health\/live',
    'same image and Manager core',
    'wrapper does not exist inside an Unraid Apps container',
    'native QPKG is not part of this delivery',
    'docker build -f platforms\/nas-docker\/Dockerfile \.',
    'docker compose down',
    '30 minutes',
    'QNAP firmware\/Container Station behavior on physical hardware'
)
Forbid-Text 'docs/nas-docker/manager.html' @('Setup-First\.ps1', 'Windows Task Scheduler', 'preview server', 'notification area', 'tray icon')
Require-Text 'docs/freebsd/README.md' @(
    'manager-bootstrap',
    'manager-reset-access',
    'Manager Config',
    'TAUTWEEKLY_MANAGER_ALLOWED_HOSTS',
    'Secure-cookie boundary are applied automatically',
    'up to 30 minutes'
)
Forbid-Text 'docs/freebsd/README.md' @('unauthenticated\s+preview server', 'sudo tautweekly setup\s*# Complete')
Require-Text 'platforms/nas-docker/app/Smtp-Transport.ps1' @(
    "Command 'AUTH LOGIN'",
    "Command 'AUTH PLAIN'",
    "ExpectedCodes 235",
    'Authentication must complete with 235 before any envelope command',
    'MAIL FROM'
)
Require-Text 'platforms/nas-docker/app/TautWeekly.ps1' @(
    'Smtp-Transport\.ps1',
    'Send-TautWeeklySmtpMessage',
    'ListUsers only displays the roster',
    'ResultPath',
    'Write-TautWeeklyStructuredResult',
    'Mode -eq "CacheWarm"',
    'Eligible users checked:',
    'Get-TautWeeklyScheduleNow -TimeZone \$deliveryTimeZone',
    'ConvertTo-TautWeeklyScheduleUtc -TimeZone \$deliveryTimeZone'
)
Require-Text 'platforms/windows/TautWeekly.ps1' @(
    'Smtp-Transport\.ps1',
    'Operation-Lock\.ps1',
    'Enter-TautWeeklyOperationLock',
    'Send-TautWeeklySmtpMessage',
    'ListUsers only displays the roster',
    'Mode -eq "CacheWarm"',
    'Eligible users checked:'
)
foreach ($relative in @(
    'platforms/windows/DeletedItemCache.ps1',
    'platforms/nas-docker/app/DeletedItemCache.ps1',
    'platforms/mac-docker/app/DeletedItemCache.ps1'
)) {
    Require-Text $relative @(
        'TwDeletedCacheSchemaVersion = 1',
        'DeletedItemCacheRetentionDays',
        'DeletedItemCacheMaxItems',
        'DeletedItemCacheMaxBytesMB',
        'Get-TwDeletedCacheId',
        'File\]::Replace',
        'index\.backup\.json',
        'Get-TwDeletedCacheFileSha256 -Path \$source',
        'Get-TautWeeklyDeletedItemCacheDiagnostics',
        'Test-TwDeletedCacheWritable',
        'BackupState',
        'Deleted-item cache activity:',
        '\$fileName -eq \(\$id \+ "\.jpg"\)'
    )
}
$cacheModuleReference = (Read-RepoFile 'platforms/windows/DeletedItemCache.ps1') -replace "`r`n", "`n"
foreach ($relative in @(
    'platforms/nas-docker/app/DeletedItemCache.ps1',
    'platforms/mac-docker/app/DeletedItemCache.ps1'
)) {
    $candidate = (Read-RepoFile $relative) -replace "`r`n", "`n"
    if ($candidate.TrimEnd() -cne $cacheModuleReference.TrimEnd()) {
        throw "Deleted-item cache implementation drifted across renderers: $relative"
    }
}
Write-Host '[PASS] Deleted-item cache schema and implementation remain identical across renderers.'
$cacheDiagnosticReference = (Read-RepoFile 'platforms/windows/Cache-Diagnostics.ps1') -replace "`r`n", "`n"
foreach ($relative in @(
    'platforms/nas-docker/app/Cache-Diagnostics.ps1',
    'platforms/mac-docker/app/Cache-Diagnostics.ps1'
)) {
    $candidate = (Read-RepoFile $relative) -replace "`r`n", "`n"
    if ($candidate.TrimEnd() -cne $cacheDiagnosticReference.TrimEnd()) {
        throw "Cache diagnostic implementation drifted across renderers: $relative"
    }
}
Write-Host '[PASS] Share-safe cache diagnostics remain identical across renderers.'
foreach ($relative in @(
    'platforms/windows/SETUP-FIRST.ps1',
    'platforms/nas-docker/app/Setup-First.ps1',
    'platforms/mac-docker/app/Setup-First.ps1'
)) {
    Require-Text $relative @(
        'Get-ExistingBooleanValue',
        'Get-ExistingBoundedInteger',
        'DeletedItemCacheEnabled',
        'DeletedItemCacheRetentionDays.*1 3650',
        'DeletedItemCacheMaxItems.*1 10000',
        'DeletedItemCacheMaxBytesMB.*16 2048',
        'Ratings Source to',
        'Rotten Tomatoes, then refresh affected metadata',
        'Verification tests the resolved connection without printing the token'
    )
}
foreach ($relative in @(
    'platforms/nas-docker/app/Verify-Setup.ps1',
    'platforms/mac-docker/app/Verify-Setup.ps1',
    'platforms/windows/VERIFY-SETUP.ps1'
)) {
    Require-Text $relative @(
        'UserEmailOverrides',
        'more than 2000 assignments',
        'invalid delivery address',
        'SMTP authentication and sender authorization are not tested by verify',
        '-Mode VerifyPlex',
        'Direct Plex identity and authenticated library requests succeeded',
        'complete movie RT critic/audience ratings',
        'Reachability does not select a movie rating provider',
        'Ratings Source > Rotten Tomatoes'
    )
}
foreach ($relative in @(
    'platforms/nas-docker/app/TautWeekly.ps1',
    'platforms/mac-docker/app/TautWeekly.ps1',
    'platforms/windows/TautWeekly.ps1'
)) {
    Require-Text $relative @(
        'function Assert-TautWeeklyUserEmailOverrides',
        'UserEmailOverrides supports at most 2000 assignments',
        'DeliveryEmail = \$deliveryEmail',
        'User\.DeliveryEmail',
        '"VerifyPlex"',
        'function Test-TautWeeklyDirectPlexConnection',
        '"/identity"',
        '"/library/sections"',
        'X-Plex-Token',
        'Direct Plex verification passed',
        'errorCategory',
        'TautWeeklyResultErrorCategory = "tautulli-unavailable"',
        'TautWeeklyResultErrorCategory = "asset-unavailable"',
        'TautWeeklyResultErrorCategory = "render-failed"',
        'TautWeeklyResultErrorCategory = "output-failed"'
    )
}
foreach ($relative in @(
    'platforms/nas-docker/app/config.example.json',
    'platforms/mac-docker/app/config.example.json',
    'platforms/windows/config.example.json'
)) {
    Require-Text $relative @('"UserEmailOverrides"\s*:\s*\{\}')
}
foreach ($relative in @(
    'platforms/nas-docker/app/bin/run-mode.sh',
    'platforms/mac-docker/app/bin/run-mode.sh'
)) {
    Require-Text $relative @(
        'lock_args=\( -n 9 \)',
        'lock_args=\( -w 30 9 \)',
        'exit 75'
    )
}
Require-Text 'platforms/nas-docker/app/User-Exclusions.ps1' @(
    'get_user_names',
    'get_users',
    'ConvertTo-TautWeeklySelectableUsers',
    'DetailsAvailable'
)
Require-Text 'platforms/nas-docker/tautweekly.sh' @(
    '\.\/tautweekly\.sh setup',
    'list-libraries',
    'manage-libraries',
    '\.\/tautweekly\.sh start',
    '\.\/tautweekly\.sh stop',
    'preview-all USER_ID',
    'numeric value shown by list-users',
    'check-update',
    'package-update\.sh',
    'manager-bootstrap',
    'access-recover',
    'run-script\.sh Verify-Setup\.ps1',
    'cache-status',
    'cache-refresh',
    'run-mode.sh CacheWarm',
    'Cache-Diagnostics\.ps1',
    'run-as-user\.sh bash'
)
Require-Text 'platforms/nas-docker/app/bin/run-as-user.sh' @(
    'PUID/PGID 0 is refused',
    'find "\$data_root" -xdev',
    '-exec chown -h',
    'exec gosu'
)
Require-Text 'platforms/nas-docker/app/bin/run-script.sh' @(
    'Verify-Setup\.ps1',
    'Schedule-Control\.ps1',
    'Cache-Diagnostics\.ps1',
    'Unsupported TautWeekly helper script',
    'run-as-user\.sh'
)
Require-Text 'platforms/nas-docker/container-update.sh' @(
    'config --images',
    '\.tautweekly-operation\.lock',
    '\.tautweekly-update-holder',
    'compose_cmd pull tautweekly',
    'up -d --no-build',
    'wait_for_health',
    'no repository version label',
    'Restoring the previous image',
    'package-backup'
)
Forbid-Text 'platforms/nas-docker/compose.yaml' @('image:\s*.*:edge')
foreach ($relative in @('platforms/nas-docker/compose.yaml', 'platforms/nas-docker/compose.qnap.yaml')) {
    Require-Text $relative @(
        'ghcr\.io/sparkmoxie/tautweekly:__TAUTWEEKLY_RELEASE_VERSION__',
        'no-new-privileges:true',
        'read_only: true',
        '\/tmp:rw,noexec,nosuid,size=256m,mode=1777',
        'cap_drop:',
        '- ALL',
        'stop_grace_period: 30m',
        'TAUTWEEKLY_MANAGER_ALLOWED_HOSTS',
        'TAUTWEEKLY_MANAGER_SECURE_COOKIES',
        'TAUTWEEKLY_FUNNEL_ADAPTER',
        'TAUTWEEKLY_PACKAGE_KIND',
        'TAUTWEEKLY_RUNTIME_PROFILE',
        'TAUTWEEKLY_PACKAGE_VERSION.*__TAUTWEEKLY_RELEASE_VERSION__',
        'TAUTWEEKLY_HOST_ADAPTER_API: "4"',
        '/var/lib/tautweekly-tailscale',
        '/run:rw,noexec,nosuid,size=16m,mode=0755'
    )
    Forbid-Text $relative @('TS_AUTHKEY', 'TS_CLIENT_SECRET', 'TS_SERVE_CONFIG', 'compose\.tailscale', '(?m)^\s*privileged:')
}
foreach ($retired in @(
    'platforms/nas-docker/compose.tailscale.yaml',
    'platforms/nas-docker/tailscale/config/serve.json',
    'platforms/mac-docker/compose.tailscale.yaml',
    'platforms/mac-docker/tailscale/config/serve.json'
)) {
    if (Test-Path -LiteralPath (Join-Path $Root $retired)) { throw "Retired private Serve deployment still exists: $retired" }
}
foreach ($relative in @('platforms/nas-docker/app/bin/funnel-adapter.sh', 'platforms/mac-docker/app/bin/funnel-adapter.sh')) {
    Require-Text $relative @(
        '--tun=userspace-networking',
        '--state="\$state_root/tailscaled\.state"',
        '--socket="\$daemon_socket"',
        'TAUTWEEKLY_REMOTE_ACCESS_UID',
        'remote-access-sidecar',
        'TS_AUTHKEY TS_AUTH_KEY TS_CLIENT_ID TS_CLIENT_SECRET TS_ID_TOKEN TS_AUDIENCE TS_AUTHKEY_FILE',
        'chmod 700 "\$state_root"',
        'chmod 711 /run/tautweekly-remote-access'
    )
    Forbid-Text $relative @('(?i)docker\.sock', '(?i)/dev/net/tun', '(?i)tskey-', '(?m)^\s*privileged')
}
foreach ($relative in @('platforms/nas-docker/app/bin/tautweekly-funnel', 'platforms/mac-docker/app/bin/tautweekly-funnel')) {
    Require-Text $relative @('login\|disable', '--socket="\$daemon_socket" login', 'remote-access-cleanup', '--listen 0\.0\.0\.0:8080')
    Forbid-Text $relative @('(?i)authkey=', '(?i)logout', '(?i)status --json')
}
Write-Host '[PASS] Container packages use explicit userspace Funnel adapters with fixed operations, root-only state, and no stored authentication key.'
Require-Text 'platforms/nas-docker/Dockerfile' @(
    'FROM golang:1\.26\.6-bookworm AS manager-build',
    'GOOS=linux GOARCH="\$\{TARGETARCH:-amd64\}"',
    'tautweekly-manager',
    'FROM tailscale/tailscale:v1\.102\.2 AS tailscale-runtime',
    'COPY --from=tailscale-runtime /usr/local/bin/tailscale',
    'COPY --from=tailscale-runtime /usr/local/bin/tailscaled',
    'HOME=/tmp/tautweekly/home',
    'XDG_DATA_HOME=/tmp/tautweekly/share',
    'EXPOSE 8080',
    'io\.tautweekly\.host-adapter-api="4"',
    'io\.tautweekly\.remote-access="tailscale-funnel"',
    'io\.tautweekly\.image-repository="ghcr\.io/sparkmoxie/tautweekly"',
    'io\.tautweekly\.runtime-profiles="desktop,server,unraid"'
)
Require-Text 'platforms/nas-docker/Dockerfile.dockerignore' @(
    '!THIRD_PARTY_NOTICES\.md'
)
Require-Text 'platforms/nas-docker/app/entrypoint.sh' @(
    '/tmp/tautweekly/home',
    '/tmp/tautweekly/share',
    'host adapter API',
    'runtime-profile\.sh',
    'tautweekly_select_runtime_profile',
    'Unified container profile'
    'TAUTWEEKLY_FUNNEL_ADAPTER',
    'kill -TERM "\$service_pid"',
    'termination_requested',
    'Verified Funnel shutdown failed; the container remains running'
)
Require-Text 'templates/tautweekly.xml' @(
    '--read-only',
    '--publish 127\.0\.0\.1:8787:8080/tcp',
    '--stop-timeout 1800',
    'TAUTWEEKLY_PACKAGE_KIND',
    'TAUTWEEKLY_HOST_ADAPTER_API',
    'TAUTWEEKLY_RUNTIME_PROFILE',
    'TAUTWEEKLY_FUNNEL_ADAPTER',
    '/var/lib/tautweekly-tailscale',
    '--tmpfs /run:rw,noexec,nosuid,size=16m,mode=0755',
    '--security-opt no-new-privileges:true',
    '--cap-drop ALL'
)

Require-Text 'platforms/mac-docker/check-release.sh' @(
    'releases/latest',
    'TAUTWEEKLY_LATEST_RELEASE_VERSION',
    'Latest stable release'
)
Require-Text 'platforms/mac-docker/mac-update.sh' @(
    'BUILD_VERSION',
    '\.tautweekly-operation\.lock',
    '\.tautweekly-update-holder',
    'wait_for_health',
    'verified stable release package',
    'Rollback to macOS image version',
    'package-backup'
)
Require-Text 'platforms/mac-docker/Dockerfile' @(
    'ARG BUILD_VERSION=dev',
    'ARG TARGETARCH',
    'org\.opencontainers\.image\.version="\$BUILD_VERSION"',
    'tautweekly-manager-linux-\$manager_arch',
    'TAUTWEEKLY_MANAGER_LISTEN=0\.0\.0\.0:8080',
    'HOME=/tmp/tautweekly/home',
    'XDG_DATA_HOME=/tmp/tautweekly/share'
)
Require-Text 'platforms/mac-docker/Dockerfile.registry' @(
    'FROM golang:1\.26\.6-bookworm AS manager-build',
    'GOARCH="\$\{TARGETARCH:-amd64\}"',
    'FROM mcr\.microsoft\.com/dotnet/sdk:8\.0-bookworm-slim',
    'COPY platforms/mac-docker/app/ /opt/tautweekly/',
    'org\.opencontainers\.image\.version="\$BUILD_VERSION"',
    'io\.tautweekly\.runtime-profile="mac"',
    'io\.tautweekly\.host-adapter-api="4"',
    'FROM tailscale/tailscale:v1\.102\.2 AS tailscale-runtime',
    'TAUTWEEKLY_MANAGER_LISTEN=0\.0\.0\.0:8080'
)
Require-Text 'platforms/mac-docker/Dockerfile.registry.dockerignore' @(
    '!THIRD_PARTY_NOTICES\.md'
)
Require-Text 'platforms/mac-docker/compose.yaml' @(
    'image:\s*tautweekly-mac:stable',
    'read_only:\s*true',
    'stop_grace_period:\s*30m',
    'no-new-privileges:true',
    'cap_drop:',
    'TAUTWEEKLY_MANAGER_ALLOWED_HOSTS',
    'TAUTWEEKLY_MANAGER_SECURE_COOKIES',
    'TAUTWEEKLY_PACKAGE_KIND:\s*"mac-docker"',
    'TAUTWEEKLY_PACKAGE_VERSION.*__TAUTWEEKLY_RELEASE_VERSION__',
    'TAUTWEEKLY_HOST_ADAPTER_API:\s*"4"',
    'TAUTWEEKLY_FUNNEL_ADAPTER',
    '/var/lib/tautweekly-tailscale',
    'PREVIEW_BIND:-127\.0\.0\.1',
    'TAUTWEEKLY_HOST_ADAPTER_API'
)
Forbid-Text 'platforms/mac-docker/compose.yaml' @('(?m)^\s*build:', 'PREVIEW_BIND:-0\.0\.0\.0')
Require-Text 'platforms/mac-docker/compose.registry.yaml' @(
    'ghcr\.io/sparkmoxie/tautweekly:__TAUTWEEKLY_RELEASE_VERSION__',
    'TAUTWEEKLY_RUNTIME_PROFILE:\s*"desktop"',
    'TAUTWEEKLY_PACKAGE_KIND:\s*"container-desktop"',
    'TAUTWEEKLY_PACKAGE_VERSION.*TAUTWEEKLY_VERSION:-__TAUTWEEKLY_RELEASE_VERSION__',
    'TAUTWEEKLY_HOST_ADAPTER_API:\s*"4"',
    'TAUTWEEKLY_FUNNEL_ADAPTER',
    '/var/lib/tautweekly-tailscale',
    'PREVIEW_BIND:-127\.0\.0\.1',
    'tautweekly-data:/data',
    'read_only:\s*true',
    'stop_grace_period:\s*30m',
    'no-new-privileges:true',
    'cap_drop:'
)
Forbid-Text 'platforms/mac-docker/compose.registry.yaml' @(
    '(?m)^\s*build:',
    'ghcr\.io/sparkmoxie/tautweekly-mac'
)
Require-Text '.github/workflows/container.yml' @(
    'workflow_call:',
    'release_tag:',
    'ghcr\.io/sparkmoxie/tautweekly',
    'platforms/nas-docker/Dockerfile',
    'test-container-profiles\.sh',
    "'' server",
    "'' desktop",
    "'' unraid",
    'platforms:\s*linux/arm64',
    'linux/amd64,linux/arm64',
    'provenance:\s*mode=max',
    'sbom:\s*true'
)
Forbid-Text '.github/workflows/container.yml' @(
    'ghcr\.io/sparkmoxie/tautweekly-mac',
    'platforms/mac-docker/Dockerfile\.registry'
)
Require-Text '.github/workflows/release.yml' @(
    'needs:\s*\[build, windows-installer\]',
    'uses:\s*\./\.github/workflows/container\.yml',
    'release_tag:\s*\$\{\{ github\.ref_name \}\}',
    'needs:\s*\[build, windows-installer, container-images\]'
)
Forbid-Text 'platforms/mac-docker/tautweekly.sh' @('docker compose build --pull', 'docker-compose build --pull')
Require-Text 'platforms/mac-docker/tautweekly.sh' @(
    'run-script\.sh Verify-Setup\.ps1',
    'run-as-user\.sh bash',
    'manager-bootstrap',
    'manager-reset-access',
    'access-recover',
    'open-manager',
    'cache-status',
    'cache-refresh',
    'run-mode.sh CacheWarm',
    'Cache-Diagnostics\.ps1',
    'package-update\.sh'
)
Require-Text 'platforms/shared/package-update.sh' @(
    'SHA256SUMS\.txt',
    'RELEASE-FILES\.txt',
    'verify_archive_listing',
    'protected_runtime_path',
    'restore_backup',
    'TAUTWEEKLY_RELEASE_ASSET_DIR'
)
Require-Text 'platforms/mac-docker/app/run-service.sh' @(
    '--runtime-mode mac',
    'health/live',
    'wait_for_delivery',
    'SHUTDOWN_DELIVERY_GRACE_SECONDS',
    'ManagerProcessId',
    "trap 'term; exit 0' TERM INT"
)
Require-Text 'platforms/mac-docker/app/healthcheck.sh' @('health/live', 'service-heartbeat\.json')
Require-Text 'platforms/mac-docker/app/entrypoint.sh' @(
    'gosu "\$PUID:\$PGID" /opt/tautweekly/run-service\.sh',
    'kill -TERM "\$service_pid"',
    'funnel-adapter\.sh',
    'chown -R "\$PUID:\$PGID" /data',
    '/tmp/tautweekly/home',
    '/tmp/tautweekly/share'
)
Forbid-Text 'platforms/mac-docker/app/entrypoint.sh' @('groupmod', 'usermod')
Forbid-Text 'platforms/mac-docker/app/preview-home.html' @('not an admin Web UI', 'Unraid container Console', 'preview-all-00-INDEX\.html')

Require-Text 'platforms/nas-docker/app/bin/runtime-profile.sh' @(
    'desktop',
    'server',
    'unraid',
    'container-desktop',
    'container-compose',
    'docker-compatible',
    'mac-docker-registry',
    'return 64'
)
Require-Text 'scripts/build-releases.ps1' @(
    'platforms/nas-docker/app',
    'TautWeekly-compose\.yaml'
)
Require-Text 'platforms/windows/Check-Update.ps1' @(
    'releases/latest',
    'Latest stable release',
    'A stable update is available',
    'SHA-256 checksum verified',
    'Windows-Update\.ps1',
    'Apply this stable update safely',
    'Start-Process.*-Verb RunAs'
)
Require-Text 'platforms/windows/Windows-Update.ps1' @(
    'Enter-TautWeeklyOperationLock',
    'RELEASE-FILES\.txt',
    'Disable-ScheduledTask',
    'Enable-ScheduledTask',
    'backup-v',
    'restored automatically',
    'Assert-ManifestFiles',
    'Assert-PowerShellSyntax',
    'Get-InstalledManagerProcesses',
    'Start-InstalledManager',
    'Ensure-InstalledManagerRunning',
    '\$managerWasRunning\s*=\s*\$managerProcesses\.Count\s+-gt\s+0',
    'Resolve-ManagerDataRoot',
    'INSTALL-METADATA\.txt',
    'Get-HealthyManagerListenerProcessIds',
    'Get-NetTCPConnection.*LocalPort 8788',
    'OwningProcess',
    'different TautWeekly Manager installation',
    'TautWeekly Manager \$TargetVersion',
    '\.manager-data'
)
Forbid-Text 'platforms/windows/Windows-Update.ps1' @('remote-access-cleanup', 'Disable-InstalledPublicRoute', '&\s+\$managerPath\s+shutdown')
Forbid-Text 'platforms/linux/install-linux.sh' @('remote-access-cleanup')
Forbid-Text 'platforms/linux/tautweekly' @('(?s)update\)\s+require_root\s+if ! run_as_service_user.*?remote-access-cleanup')
Write-Host '[PASS] Ordinary Windows and native Linux updates preserve retained Funnel state and the fixed route.'
Require-Text 'platforms/windows/START-MANAGER.ps1' @(
    '127\.0\.0\.1:8788',
    '\.manager-data',
    'tautweekly-manager\.exe',
    '--open-browser',
    'WindowStyle Hidden'
)
Require-Text 'platforms/windows/00-OPEN-MANAGER.bat' @('START-MANAGER\.ps1', 'NoProfile', 'NonInteractive')
Require-Text 'platforms/windows/RESET-MANAGER-ACCESS.ps1' @('access-reset', 'Manager access', 'START-MANAGER\.ps1')
Require-Text 'platforms/windows/18-RESET-MANAGER-ACCESS.bat' @('RESET-MANAGER-ACCESS\.ps1', 'NoProfile')
Require-Text 'platforms/windows/19-CACHE-DIAGNOSTICS.bat' @('Cache-Diagnostics\.ps1', 'NoProfile')
Require-Text 'platforms/windows/20-REFRESH-DELETED-ITEM-CACHE.bat' @('TautWeekly\.ps1', 'CacheWarm', 'NoProfile')
Require-Text 'platforms/windows/Operation-Lock.ps1' @(
    '\.tautweekly-operation\.lock',
    'FileShare\]::None',
    'Another TautWeekly operation is already running'
)
Require-Text 'platforms/windows/17-CHECK-FOR-UPDATE.bat' @('Check-Update\.ps1', '-PromptForUpdate', 'pause')

foreach ($relative in @(
    'docs/windows/README.md',
    'docs/nas-docker/README.md',
    'docs/mac/README.md',
    'docs/linux/README.md',
    'docs/freebsd/README.md'
)) {
    Require-Text $relative @('check', 'stable', 'rollback|restore')
}

Require-Text 'platforms/linux/tautweekly' @('list-libraries', 'manage-libraries', 'Manage-Library-Selection\.ps1', 'cache-status', 'cache-refresh', 'run_mode CacheWarm', 'Cache-Diagnostics\.ps1')
Require-Text 'platforms/freebsd-podman/tautweekly' @('list-libraries', 'manage-libraries', 'Manage-Library-Selection\.ps1', 'cache-status', 'cache-refresh', 'run_mode CacheWarm', 'Cache-Diagnostics\.ps1')

foreach ($relative in @(
    'platforms/windows/Library-Selection.ps1',
    'platforms/windows/Manage-Library-Selection.ps1',
    'platforms/nas-docker/app/Library-Selection.ps1',
    'platforms/nas-docker/app/Manage-Library-Selection.ps1',
    'platforms/mac-docker/app/Library-Selection.ps1',
    'platforms/mac-docker/app/Manage-Library-Selection.ps1'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $relative))) {
        throw "Required library-selection source is missing: $relative"
    }
}
Write-Host '[PASS] Every directly shipped runtime contains library-selection management source.'

foreach ($relative in @(
    'app/bin/run-as-user.sh',
    'app/bin/run-script.sh',
    'app/Schedule-Time.ps1',
    'app/Smtp-Transport.ps1'
)) {
    $nas = Read-RepoFile ("platforms/nas-docker/$relative")
    $mac = Read-RepoFile ("platforms/mac-docker/$relative")
    if ($nas -cne $mac) {
        throw "Shared runtime wrapper drifted between NAS and macOS: $relative"
    }
}
Write-Host '[PASS] Capability-neutral renderer and scheduling wrappers remain identical across container editions.'

$forbiddenRuntimeNames = @('config.json', '.env', 'state.json', 'access-state.json', 'remote-access.json', 'scheduler-state.json', 'scheduler-heartbeat.json', 'service-heartbeat.json')
foreach ($platform in @('linux', 'freebsd-podman')) {
    $path = Join-Path (Join-Path $Root 'platforms') $platform
    $forbidden = @(Get-ChildItem -LiteralPath $path -Recurse -Force | Where-Object {
        (-not $_.PSIsContainer -and $_.Name -in $forbiddenRuntimeNames) -or
        ($_.PSIsContainer -and $_.Name -in @('logs', 'output'))
    })
    if ($forbidden) {
        throw "Forbidden runtime material is present in ${platform}: $($forbidden.FullName -join ', ')"
    }
}
Write-Host '[PASS] Linux and FreeBSD source packages contain no runtime data.'
