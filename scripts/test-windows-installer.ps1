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

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-InstallerFailureDetail([string]$OperationLog) {
    if (-not (Test-Path -LiteralPath $OperationLog -PathType Leaf)) {
        return 'The installer did not create its operation log.'
    }
    $tail = @(Get-Content -LiteralPath $OperationLog -Tail 12)
    if ($tail.Count -eq 0) {
        return 'The installer operation log is empty.'
    }
    return "Installer log tail:`n$($tail -join "`n")"
}

$setup = Join-Path $DistPath 'TautWeekly-Setup.exe'
Assert-True (Test-Path -LiteralPath $setup -PathType Leaf) 'TautWeekly-Setup.exe is missing.'
$setupHashBefore = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash

$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempParent ('tautweekly-installer-test-' + [Guid]::NewGuid().ToString('N'))
$testRoot = [IO.Path]::GetFullPath($testRoot)
Assert-True ($testRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase)) "Unsafe installer test root: $testRoot"
$installRoot = Join-Path $testRoot 'program'
$dataRoot = Join-Path $testRoot 'private-data'
$logPath = Join-Path $testRoot 'installer.log'
$originalLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $testRoot 'isolated-local-app-data'

function Invoke-TestInstaller([switch]$Uninstall, [switch]$UseRecordedData, [string]$ExitMarker = '') {
    $arguments = @('--test-mode', '--install-dir', $installRoot, '--log', $logPath)
    if (-not $UseRecordedData) { $arguments += @('--data-dir', $dataRoot) }
    if ([string]::IsNullOrWhiteSpace($ExitMarker)) { $arguments += '--no-launch' } else { $arguments += @('--test-exit-marker', $ExitMarker) }
    if ($Uninstall) { $arguments = @('--uninstall') + $arguments }
    $process = Start-Process -FilePath $setup -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    Assert-True ($process.ExitCode -eq 0) "Installer exited with code $($process.ExitCode).`n$(Get-InstallerFailureDetail -OperationLog $logPath)"
    $process.Dispose()
}

function Invoke-TestInstallerAt([string]$ApplicationRoot, [string]$PrivateRoot, [string]$OperationLog) {
    $arguments = @('--test-mode', '--no-launch', '--install-dir', $ApplicationRoot, '--data-dir', $PrivateRoot, '--log', $OperationLog)
    $process = Start-Process -FilePath $setup -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    Assert-True ($process.ExitCode -eq 0) "Installer exited with code $($process.ExitCode) while migrating a verified portable release.`n$(Get-InstallerFailureDetail -OperationLog $OperationLog)"
    $process.Dispose()
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $exitMarker = Join-Path $testRoot 'setup-exited.txt'
    Invoke-TestInstaller -ExitMarker $exitMarker
    $exitMarkerDeadline = (Get-Date).AddSeconds(8)
    while (-not (Test-Path -LiteralPath $exitMarker -PathType Leaf) -and (Get-Date) -lt $exitMarkerDeadline) {
        Start-Sleep -Milliseconds 100
    }
    Assert-True ((Get-Content -LiteralPath $exitMarker -Raw) -eq 'exited') 'Post-exit handoff did not observe the Setup process terminating.'
    $lockProbe = [IO.Path]::GetFullPath((Join-Path $DistPath 'TautWeekly-Setup.lock-probe.exe'))
    Assert-True ([string]::Equals([IO.Path]::GetDirectoryName($lockProbe), $DistPath, [StringComparison]::OrdinalIgnoreCase)) 'Unsafe Setup lock-probe path.'
    try {
        Move-Item -LiteralPath $setup -Destination $lockProbe -ErrorAction Stop
        Move-Item -LiteralPath $lockProbe -Destination $setup -ErrorAction Stop
    }
    finally {
        if ((Test-Path -LiteralPath $lockProbe -PathType Leaf) -and -not (Test-Path -LiteralPath $setup)) {
            Move-Item -LiteralPath $lockProbe -Destination $setup -ErrorAction SilentlyContinue
        }
    }
    Assert-True (Test-Path -LiteralPath $setup -PathType Leaf) 'Setup remained locked or was not restored after its process exited.'
    foreach ($relative in @(
        'tautweekly-manager.exe', 'TautWeekly.ps1', 'START-MANAGER.ps1', 'RESET-MANAGER-ACCESS.ps1', 'TAILSCALE-HELPER.ps1',
        'Open-TautWeekly.cmd', 'Reset-TautWeekly-Access.cmd', 'Uninstall-TautWeekly.cmd', 'TautWeekly-Uninstall.exe',
        'tautweekly.ico', 'INSTALL-METADATA.txt', 'RELEASE-FILES.txt'
    )) {
        Assert-True (Test-Path -LiteralPath (Join-Path $installRoot $relative) -PathType Leaf) "Fresh install is missing $relative."
    }
    $managerExecutable = Join-Path $installRoot 'tautweekly-manager.exe'
    $managerInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($managerExecutable)
    Assert-True ($managerInfo.FileDescription -eq 'TautWeekly for Plex') 'Installed Manager does not use the requested TautWeekly for Plex Task Manager name.'
    Assert-True ($managerInfo.ProductName -eq 'TautWeekly for Plex') 'Installed Manager does not use the requested TautWeekly for Plex product metadata.'
    Add-Type -AssemblyName System.Drawing
    $managerIcon = [Drawing.Icon]::ExtractAssociatedIcon($managerExecutable)
    try {
        Assert-True ($null -ne $managerIcon) 'Installed Manager has no extractable popcorn/TW application icon.'
    }
    finally {
        if ($null -ne $managerIcon) { $managerIcon.Dispose() }
    }
    Assert-True (Test-Path -LiteralPath $dataRoot -PathType Container) 'Fresh install did not create the external private data directory.'
    $metadata = Get-Content -LiteralPath (Join-Path $installRoot 'INSTALL-METADATA.txt') -Raw
    Assert-True ($metadata.Contains("DataDirectory=$dataRoot")) 'Installer metadata does not bind the external private data directory.'
    $launcher = Get-Content -LiteralPath (Join-Path $installRoot 'Open-TautWeekly.cmd') -Raw
    Assert-True ($launcher.Contains('-DataRoot')) 'Installed launcher does not pass the external Manager data directory.'
    $managerLauncher = Get-Content -LiteralPath (Join-Path $installRoot 'START-MANAGER.ps1') -Raw
    Assert-True ($managerLauncher.Contains('[switch]$Startup')) 'Installed Manager launcher has no silent sign-in mode.'
    Assert-True ($managerLauncher.Contains('[switch]$OpenDashboard')) 'Installed Manager launcher has no dependent sign-in Dashboard mode.'
    Assert-True ($managerLauncher.Contains('-not $Startup -or $OpenDashboard')) 'Installed Manager launcher does not keep browser opening dependent on the sign-in setting.'
    Assert-True ($managerLauncher.Contains("& `$manager open '--listen=127.0.0.1:8788'")) 'Installed Manager launcher does not delegate repeated opens to Dashboard activation.'
    Assert-True (-not $managerLauncher.Contains('Start-Process -FilePath $baseUri')) 'Installed Manager launcher still creates a new browser window for every repeated open.'
    $resetLauncher = Get-Content -LiteralPath (Join-Path $installRoot 'Reset-TautWeekly-Access.cmd') -Raw
    Assert-True ($resetLauncher.Contains('-DataRoot')) 'Installed access reset launcher does not pass the external Manager data directory.'

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    $manager = Start-Process `
        -FilePath (Join-Path $installRoot 'tautweekly-manager.exe') `
        -ArgumentList @('serve', "--listen=127.0.0.1:$port", "--tautweekly-root=$installRoot", "--data-dir=$dataRoot") `
        -WorkingDirectory $installRoot `
        -WindowStyle Hidden `
        -PassThru
    try {
        $deadline = (Get-Date).AddSeconds(10)
        $healthy = $false
        do {
            Start-Sleep -Milliseconds 200
            if ($manager.HasExited) { throw "Installed Manager stopped during boot with exit code $($manager.ExitCode)." }
            try {
                $health = Invoke-RestMethod -UseBasicParsing -Uri "http://127.0.0.1:$port/health/live" -TimeoutSec 2
                $healthy = [string]$health.status -eq 'alive'
            }
            catch { }
        } while (-not $healthy -and (Get-Date) -lt $deadline)
        Assert-True $healthy 'Installed Manager did not become healthy from the external private data directory.'
        $setupState = Invoke-RestMethod -UseBasicParsing -Uri "http://127.0.0.1:$port/api/v1/setup" -TimeoutSec 2
        Assert-True (-not [bool]$setupState.authenticationRequired) 'Fresh Windows Manager unexpectedly requires authentication.'
        Assert-True (-not [bool]$setupState.pairingRequired) 'Fresh Windows Manager unexpectedly requires a pairing token.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'bootstrap-token.txt'))) 'Fresh Windows Manager wrote an obsolete pairing token.'
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $authSession = Invoke-RestMethod -UseBasicParsing -Uri "http://127.0.0.1:$port/api/v1/auth/session" -WebSession $session -TimeoutSec 2
        $startupState = Invoke-RestMethod -UseBasicParsing -Uri "http://127.0.0.1:$port/api/v1/startup" -WebSession $session -TimeoutSec 2
        Assert-True ([bool]$startupState.supported) 'Installed Windows Manager did not report sign-in startup capability.'
        $startupJson = $startupState | ConvertTo-Json -Compress
        Assert-True (-not $startupJson.Contains($installRoot) -and -not $startupJson.Contains($dataRoot)) 'Startup status leaked an application or private-data path.'
        $authHeaders = @{ 'X-CSRF-Token' = [string]$authSession.csrfToken; Origin = "http://127.0.0.1:$port" }
        Invoke-RestMethod -UseBasicParsing -Uri "http://127.0.0.1:$port/api/v1/auth/access/password" -Method Post -ContentType 'application/json' -Headers $authHeaders -WebSession $session -Body '{"password":"synthetic installer preservation password"}' -TimeoutSec 3 | Out-Null
        Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'auth.json') -PathType Leaf) 'Manager password setup did not create its private verifier.'
        Assert-True ((Get-Content -LiteralPath (Join-Path $dataRoot 'auth-settings.json') -Raw).Contains('"passwordLockEnabled": true')) 'Manager password setup did not activate the Windows lock.'
        $shutdown = Start-Process `
            -FilePath $managerExecutable `
            -ArgumentList @('shutdown', "--listen=127.0.0.1:$port", "--tautweekly-root=$installRoot") `
            -WorkingDirectory $installRoot `
            -Wait `
            -PassThru `
            -WindowStyle Hidden
        Assert-True ($shutdown.ExitCode -eq 0) 'Installed Manager rejected its named graceful-shutdown request.'
        $shutdown.Dispose()
        Assert-True ($manager.WaitForExit(10000)) 'Installed Manager did not release its tray, listener, and executable promptly.'
    }
    finally {
        if (-not $manager.HasExited) {
            Stop-Process -Id $manager.Id -Force -ErrorAction SilentlyContinue
            [void]$manager.WaitForExit(10000)
        }
        $manager.Dispose()
    }

    [IO.File]::WriteAllText((Join-Path $installRoot 'config.json'), '{"private":"preserve"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $dataRoot 'access-state.json'), '{"session":"preserve"}', [Text.UTF8Encoding]::new($false))
    $authHashBefore = (Get-FileHash -LiteralPath (Join-Path $dataRoot 'auth.json') -Algorithm SHA256).Hash
    $authSettingsBefore = Get-Content -LiteralPath (Join-Path $dataRoot 'auth-settings.json') -Raw
    $privateManagerFixtures = [ordered]@{
        'operation-history.jsonl' = '{"schemaVersion":1,"id":"synthetic-history-preserve"}'
        'schedule-operation.json' = '{"schemaVersion":1,"state":"synthetic-schedule-preserve"}'
        # This valid synthetic record proves update preservation without
        # contacting Tailscale. Ordinary update must never invoke the provider.
        'windows-funnel.json' = '{"schemaVersion":2,"enabled":true,"hostname":"installer-preserve.test-tailnet.ts.net","publiclyPublished":true}'
    }
    foreach ($fixture in $privateManagerFixtures.GetEnumerator()) {
        [IO.File]::WriteAllText((Join-Path $dataRoot $fixture.Key), $fixture.Value, [Text.UTF8Encoding]::new($false))
    }
    $previewRoot = Join-Path $installRoot 'output\previews'
    New-Item -ItemType Directory -Path $previewRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $previewRoot 'synthetic-preview.html'), '<!doctype html><title>Synthetic preserved preview</title>', [Text.UTF8Encoding]::new($false))
    $legacyData = Join-Path $installRoot '.manager-data'
    New-Item -ItemType Directory -Path $legacyData | Out-Null
    [IO.File]::WriteAllText((Join-Path $legacyData 'legacy-state.json'), '{"legacy":"migrate"}', [Text.UTF8Encoding]::new($false))

    # Do not pass --data-dir on update: a production update must retain the
    # private path already recorded in INSTALL-METADATA.txt.
    Invoke-TestInstaller -UseRecordedData
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'config.json') -Raw) -eq '{"private":"preserve"}') 'Upgrade replaced private config.json.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $dataRoot 'access-state.json') -Raw) -eq '{"session":"preserve"}') 'Upgrade replaced external Manager data.'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $dataRoot 'auth.json') -Algorithm SHA256).Hash -eq $authHashBefore) 'Upgrade replaced the Manager password verifier.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $dataRoot 'auth-settings.json') -Raw) -eq $authSettingsBefore) 'Upgrade replaced the Manager password-lock setting.'
    foreach ($fixture in $privateManagerFixtures.GetEnumerator()) {
        Assert-True ((Get-Content -LiteralPath (Join-Path $dataRoot $fixture.Key) -Raw) -eq $fixture.Value) "Upgrade replaced private Manager fixture $($fixture.Key)."
    }
    Assert-True ((Get-Content -LiteralPath (Join-Path $previewRoot 'synthetic-preview.html') -Raw) -eq '<!doctype html><title>Synthetic preserved preview</title>') 'Upgrade replaced a private generated preview.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'legacy-state.json') -PathType Leaf) 'Upgrade did not migrate legacy .manager-data state.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot '.manager-data'))) 'Upgrade retained a duplicate legacy .manager-data directory.'
    $updatedMetadata = Get-Content -LiteralPath (Join-Path $installRoot 'INSTALL-METADATA.txt') -Raw
    Assert-True ($updatedMetadata.Contains("DataDirectory=$dataRoot")) 'Upgrade replaced the recorded private data directory.'
    $updatedLauncher = Get-Content -LiteralPath (Join-Path $installRoot 'Open-TautWeekly.cmd') -Raw
    Assert-True ($updatedLauncher.Contains($dataRoot)) 'Upgrade rewrote the Manager launcher to a different private data directory.'
    $rollbackBackups = @(Get-ChildItem -LiteralPath $testRoot -Directory -Filter 'program.backup-v*')
    Assert-True ($rollbackBackups.Count -eq 1) "Upgrade created $($rollbackBackups.Count) rollback backups instead of exactly one."
    Assert-True ((Get-Content -LiteralPath (Join-Path $rollbackBackups[0].FullName 'config.json') -Raw) -eq '{"private":"preserve"}') 'Upgrade rollback backup did not preserve private config.json.'
    Assert-True (Test-Path -LiteralPath (Join-Path $rollbackBackups[0].FullName 'INSTALL-METADATA.txt') -PathType Leaf) 'Upgrade rollback backup did not capture the installed application state.'

    $existingFixedPortOwners = @(Get-NetTCPConnection -State Listen -LocalPort 8788 -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.LocalAddress -in @('127.0.0.1', '::1') } |
        Select-Object -ExpandProperty OwningProcess -Unique)
    Assert-True ($existingFixedPortOwners.Count -eq 0) 'Automatic update relaunch test requires 127.0.0.1:8788 to be available.'
    $relaunchExtractRoot = Join-Path $testRoot 'update-relaunch-candidate'
    Expand-Archive -LiteralPath (Join-Path $DistPath 'TautWeekly-windows.zip') -DestinationPath $relaunchExtractRoot
    $relaunchCandidateRoot = Join-Path $relaunchExtractRoot 'TautWeekly-windows'
    $candidateVersionMatch = [regex]::Match(
        (Get-Content -LiteralPath (Join-Path $relaunchCandidateRoot 'RELEASE-METADATA.txt') -Raw),
        '(?m)^Repository version:\s*v?(?<version>[0-9A-Za-z][0-9A-Za-z._-]*)\s*$'
    )
    Assert-True $candidateVersionMatch.Success 'Automatic update relaunch candidate has invalid release metadata.'
    $candidateVersion = [string]$candidateVersionMatch.Groups['version'].Value
    $relaunchResultPath = Join-Path $dataRoot 'automatic-relaunch-result.json'
    $runningManager = Start-Process -FilePath $managerExecutable -ArgumentList @('serve', '--listen=127.0.0.1:8788', "--tautweekly-root=$installRoot", "--data-dir=$dataRoot") -WorkingDirectory $installRoot -WindowStyle Hidden -PassThru
    $restartedManagerId = 0
    try {
        $restartDeadline = (Get-Date).AddSeconds(10)
        $restartHealthy = $false
        do {
            Start-Sleep -Milliseconds 200
            if ($runningManager.HasExited) { throw "Upgraded Manager stopped before automatic update recovery with exit code $($runningManager.ExitCode)." }
            try { $restartHealthy = [string](Invoke-RestMethod -UseBasicParsing -Uri 'http://127.0.0.1:8788/health/live' -TimeoutSec 2).status -eq 'alive' } catch { }
        } while (-not $restartHealthy -and (Get-Date) -lt $restartDeadline)
        Assert-True $restartHealthy 'Upgraded Manager was not healthy before automatic update recovery.'

        # Reproduce the v0.25.4 stranding window: the exact Manager has exited,
        # but post-stop verification fails before package mutation begins. The
        # updater must remember that it owns relaunch responsibility.
        $stopFailureResultPath = Join-Path $dataRoot 'post-stop-recovery-result.json'
        $stopFailureArguments = @{
            InstallRoot = $installRoot
            CandidateRoot = $relaunchCandidateRoot
            TargetVersion = $candidateVersion
            ResultPath = $stopFailureResultPath
            InstallerTestMode = $true
            SimulateManagerStopFailure = $true
        }
        $stopFailureObserved = $false
        $stopFailureMessage = ''
        try {
            & (Join-Path $relaunchCandidateRoot 'Windows-Update.ps1') @stopFailureArguments
        }
        catch {
            $stopFailureMessage = [string]$_.Exception.Message
            $stopFailureObserved = $stopFailureMessage -match 'Simulated post-stop failure'
        }
        Assert-True $stopFailureObserved "Post-stop recovery fixture did not report the simulated updater failure. Actual error: $stopFailureMessage"
        Assert-True ($runningManager.WaitForExit(20000)) 'Post-stop recovery fixture did not stop the original Manager process.'
        $stopFailureResult = Get-Content -LiteralPath $stopFailureResultPath -Raw | ConvertFrom-Json
        Assert-True ([string]$stopFailureResult.Status -eq 'failed') 'Post-stop recovery fixture did not retain the expected failed update result.'

        $restartDeadline = (Get-Date).AddSeconds(10)
        $restartHealthy = $false
        $stopRecoveryOwners = @()
        do {
            Start-Sleep -Milliseconds 200
            try {
                $restartHealthy = [string](Invoke-RestMethod -UseBasicParsing -Uri 'http://127.0.0.1:8788/health/live' -TimeoutSec 2).status -eq 'alive'
                if ($restartHealthy) {
                    $stopRecoveryOwners = @(Get-NetTCPConnection -State Listen -LocalPort 8788 -ErrorAction Stop |
                        Where-Object { [string]$_.LocalAddress -in @('127.0.0.1', '::1') } |
                        Select-Object -ExpandProperty OwningProcess -Unique)
                }
            }
            catch { }
        } while ((-not $restartHealthy -or $stopRecoveryOwners.Count -ne 1) -and (Get-Date) -lt $restartDeadline)
        Assert-True ($restartHealthy -and $stopRecoveryOwners.Count -eq 1) "Post-stop updater failure stranded the Manager listener. Updater result: $([string]$stopFailureResult.Message)"
        Assert-True ([int]$stopRecoveryOwners[0] -ne $runningManager.Id) 'Post-stop updater failure did not replace the terminated Manager process.'
        $runningManager.Dispose()
        $runningManager = Get-Process -Id ([int]$stopRecoveryOwners[0]) -ErrorAction Stop

        # Match the in-Manager update path: the staged helper receives no
        # ManagerDataRoot and must recover the recorded private directory.
        $updateArguments = @{
            InstallRoot = $installRoot
            CandidateRoot = $relaunchCandidateRoot
            TargetVersion = $candidateVersion
            ResultPath = $relaunchResultPath
            InstallerTestMode = $true
        }
        & (Join-Path $relaunchCandidateRoot 'Windows-Update.ps1') @updateArguments
        Assert-True (Test-Path -LiteralPath $relaunchResultPath -PathType Leaf) 'Automatic update did not write its relaunch result.'
        $relaunchResult = Get-Content -LiteralPath $relaunchResultPath -Raw | ConvertFrom-Json
        Assert-True ([string]$relaunchResult.Status -eq 'success') "Automatic update failed to relaunch the Manager: $([string]$relaunchResult.Message)"
        Assert-True ($runningManager.WaitForExit(20000)) 'Automatic update did not stop the original Manager process.'

        $restartDeadline = (Get-Date).AddSeconds(10)
        $restartHealthy = $false
        $restartOwners = @()
        do {
            Start-Sleep -Milliseconds 200
            try {
                $restartHealthy = [string](Invoke-RestMethod -UseBasicParsing -Uri 'http://127.0.0.1:8788/health/live' -TimeoutSec 2).status -eq 'alive'
                if ($restartHealthy) {
                    $restartOwners = @(Get-NetTCPConnection -State Listen -LocalPort 8788 -ErrorAction Stop |
                        Where-Object { [string]$_.LocalAddress -in @('127.0.0.1', '::1') } |
                        Select-Object -ExpandProperty OwningProcess -Unique)
                }
            }
            catch { }
        } while ((-not $restartHealthy -or $restartOwners.Count -ne 1) -and (Get-Date) -lt $restartDeadline)
        Assert-True ($restartHealthy -and $restartOwners.Count -eq 1) 'Automatic update did not restore the Manager listener on 127.0.0.1:8788.'
        $restartedManagerId = [int]$restartOwners[0]
        Assert-True ($restartedManagerId -ne $runningManager.Id) 'Automatic update did not replace the original Manager process.'
        $restartedManager = Get-Process -Id $restartedManagerId -ErrorAction Stop
        Assert-True (([IO.Path]::GetFullPath([string]$restartedManager.Path)) -ieq ([IO.Path]::GetFullPath($managerExecutable))) 'Automatic update restarted a Manager from the wrong installation.'

        $restartSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        Invoke-RestMethod -UseBasicParsing -Uri 'http://127.0.0.1:8788/api/v1/auth/login' -Method Post -ContentType 'application/json' -WebSession $restartSession -Body '{"password":"synthetic installer preservation password"}' -TimeoutSec 3 | Out-Null
        $recoveredFunnel = Invoke-RestMethod -UseBasicParsing -Uri 'http://127.0.0.1:8788/api/v1/remote-access/tailscale' -WebSession $restartSession -TimeoutSec 3
        $cleanupRequired = if ($null -eq $recoveredFunnel.PSObject.Properties['cleanupRequired']) { $false } else { [bool]$recoveredFunnel.cleanupRequired }
        Assert-True ([bool]$recoveredFunnel.enabled -and $cleanupRequired) 'Automatically relaunched Manager discarded the retained enabled Funnel state.'
        Assert-True ([string]$recoveredFunnel.url -eq 'https://installer-preserve.test-tailnet.ts.net') 'Automatically relaunched Manager changed the retained public Funnel hostname.'
        Assert-True ([string]$recoveredFunnel.networkKind -eq 'public-funnel') 'Automatically relaunched Manager reverted to the obsolete private remote-access controller.'
        # The synthetic enabled record has no real provider route to disable.
        # An explicit stop must therefore accept the local signal but leave the
        # Manager open, preserving the password and retained exposure evidence.
        $restartShutdown = Start-Process -FilePath $managerExecutable -ArgumentList @('shutdown', '--listen=127.0.0.1:8788', "--tautweekly-root=$installRoot") -WorkingDirectory $installRoot -Wait -PassThru -WindowStyle Hidden
        Assert-True ($restartShutdown.ExitCode -eq 0) 'Upgraded Manager rejected the local shutdown signal after restart recovery.'
        $restartShutdown.Dispose()
        Start-Sleep -Seconds 2
        Assert-True ($null -ne (Get-Process -Id $restartedManagerId -ErrorAction SilentlyContinue)) 'Upgraded Manager exited even though synthetic public Funnel shutdown could not be verified.'
    }
    finally {
        if (-not $runningManager.HasExited) { Stop-Process -Id $runningManager.Id -Force -ErrorAction SilentlyContinue; [void]$runningManager.WaitForExit(10000) }
        $runningManager.Dispose()
        if ($restartedManagerId -gt 0) {
            $processToStop = Get-Process -Id $restartedManagerId -ErrorAction SilentlyContinue
            if ($null -ne $processToStop) {
                try {
                    if (([IO.Path]::GetFullPath([string]$processToStop.Path)) -ieq ([IO.Path]::GetFullPath($managerExecutable))) {
                        Stop-Process -Id $restartedManagerId -Force -ErrorAction SilentlyContinue
                        [void]$processToStop.WaitForExit(10000)
                    }
                }
                finally {
                    $processToStop.Dispose()
                }
            }
        }
        # The synthetic retained-Funnel shutdown intentionally leaves its
        # privileged helper waiting for a callback after the Manager is forced
        # down. Stop only helpers launched from this isolated test installation
        # so they cannot hold the disposable program directory open.
        $isolatedHelperPath = [IO.Path]::GetFullPath((Join-Path $installRoot 'TAILSCALE-HELPER.ps1'))
        $isolatedHelpers = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            [string]$_.CommandLine -and [string]$_.CommandLine.IndexOf($isolatedHelperPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        foreach ($isolatedHelper in $isolatedHelpers) {
            $helperProcess = Get-Process -Id ([int]$isolatedHelper.ProcessId) -ErrorAction SilentlyContinue
            if ($null -eq $helperProcess) { continue }
            try {
                Stop-Process -Id $helperProcess.Id -Force -ErrorAction SilentlyContinue
                [void]$helperProcess.WaitForExit(10000)
            }
            finally {
                $helperProcess.Dispose()
            }
        }
    }
    # Explicit uninstall remains fail-closed. Return the synthetic state to Off
    # before that separate lifecycle test so no host Tailscale client is used.
    [IO.File]::WriteAllText((Join-Path $dataRoot 'windows-funnel.json'), '{"schemaVersion":2,"enabled":false}', [Text.UTF8Encoding]::new($false))

    $portableExtractRoot = Join-Path $testRoot 'portable-extract'
    Expand-Archive -LiteralPath (Join-Path $DistPath 'TautWeekly-windows.zip') -DestinationPath $portableExtractRoot
    $portableRoot = Join-Path $portableExtractRoot 'TautWeekly-windows'
    $portableDataRoot = Join-Path $testRoot 'portable-private-data'
    $portableLog = Join-Path $testRoot 'portable-installer.log'
    [IO.File]::WriteAllText((Join-Path $portableRoot 'config.json'), '{"portable":"preserve"}', [Text.UTF8Encoding]::new($false))
    $portableLegacyData = Join-Path $portableRoot '.manager-data'
    New-Item -ItemType Directory -Path $portableLegacyData | Out-Null
    [IO.File]::WriteAllText((Join-Path $portableLegacyData 'access-state.json'), '{"legacy":"preserve"}', [Text.UTF8Encoding]::new($false))

    Invoke-TestInstallerAt -ApplicationRoot $portableRoot -PrivateRoot $portableDataRoot -OperationLog $portableLog
    Assert-True ((Get-Content -LiteralPath (Join-Path $portableRoot 'config.json') -Raw) -eq '{"portable":"preserve"}') 'Portable migration replaced private config.json.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $portableDataRoot 'access-state.json') -Raw) -eq '{"legacy":"preserve"}') 'Portable migration did not retain legacy Manager state externally.'
    Assert-True (-not (Test-Path -LiteralPath $portableLegacyData)) 'Portable migration retained duplicate in-folder Manager state.'
    Assert-True (Test-Path -LiteralPath (Join-Path $portableRoot 'INSTALL-METADATA.txt') -PathType Leaf) 'Portable migration did not convert the folder to an installer-owned application.'
    Assert-True (@(Get-ChildItem -LiteralPath $portableExtractRoot -Directory -Filter 'TautWeekly-windows.backup-v*').Count -eq 1) 'Portable migration did not create exactly one rollback backup.'

    # The virtual lifecycle remains inactive before removal so it never
    # invokes the real Tailscale client.
    $uninstaller = Join-Path $installRoot 'TautWeekly-Uninstall.exe'
    # The installed uninstaller must recover both the custom application root
    # and external data root without caller-supplied path arguments.
    $uninstallArguments = @('--test-mode', '--no-launch', '--log', $logPath)
    $uninstallProcess = Start-Process -FilePath $uninstaller -ArgumentList $uninstallArguments -Wait -PassThru -WindowStyle Hidden
    Assert-True ($uninstallProcess.ExitCode -eq 0) "Installed uninstaller exited with code $($uninstallProcess.ExitCode)."
    $uninstallProcess.Dispose()
    $selfRemovalDeadline = (Get-Date).AddSeconds(8)
    while ((Test-Path -LiteralPath $uninstaller) -and (Get-Date) -lt $selfRemovalDeadline) {
        Start-Sleep -Milliseconds 200
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot 'tautweekly-manager.exe'))) 'Uninstall retained an application-owned Manager executable.'
    Assert-True (-not (Test-Path -LiteralPath $uninstaller)) 'Installed uninstaller did not remove its exact executable after exit.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'config.json') -PathType Leaf) 'Uninstall removed private configuration.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'access-state.json') -PathType Leaf) 'Uninstall removed external Manager data.'
    foreach ($name in @('auth.json', 'auth-settings.json', 'operation-history.jsonl', 'schedule-operation.json', 'windows-funnel.json')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot $name) -PathType Leaf) "Uninstall removed private Manager fixture $name."
    }
    Assert-True (Test-Path -LiteralPath $logPath -PathType Leaf) 'Installer did not retain its diagnostic log.'

    $embeddedIcon = [Drawing.Icon]::ExtractAssociatedIcon($setup)
    try {
        Assert-True ($null -ne $embeddedIcon) 'Setup executable has no extractable application icon.'
        $embeddedBitmap = $embeddedIcon.ToBitmap()
        try {
            Assert-True ($embeddedBitmap.Width -eq 32 -and $embeddedBitmap.Height -eq 32) 'Setup icon does not expose the expected Windows shell size.'
            $goldPixels = 0
            $whitePixels = 0
            $transparentCorners = 0
            for ($x = 0; $x -lt $embeddedBitmap.Width; $x++) {
                for ($y = 0; $y -lt $embeddedBitmap.Height; $y++) {
                    $pixel = $embeddedBitmap.GetPixel($x, $y)
                    if ($pixel.R -gt 180 -and $pixel.G -gt 100 -and $pixel.B -lt 100) { $goldPixels++ }
                    if ($pixel.R -gt 200 -and $pixel.G -gt 200 -and $pixel.B -gt 200) { $whitePixels++ }
                }
            }
            foreach ($corner in @(@(0,0), @(31,0), @(0,31), @(31,31))) {
                if ($embeddedBitmap.GetPixel($corner[0], $corner[1]).A -lt 20) { $transparentCorners++ }
            }
            Assert-True ($goldPixels -gt 125 -and $whitePixels -gt 75 -and $transparentCorners -eq 4) 'Setup executable does not expose the approved gold, white, transparent popcorn/TW shell icon.'
        }
        finally {
            $embeddedBitmap.Dispose()
        }
    }
    finally {
        if ($null -ne $embeddedIcon) { $embeddedIcon.Dispose() }
    }

    Write-Host '[PASS] Windows installer fresh install, process-lock release, verified upgrade, portable migration, icon, and privacy-preserving uninstall lifecycle.' -ForegroundColor Green
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        if ($resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved).StartsWith('tautweekly-installer-test-', [StringComparison]::Ordinal)) {
            try {
                Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
            }
            catch {
                if (Test-Path -LiteralPath $resolved) {
                    Write-Warning "Could not completely remove installer test workspace '$resolved': $($_.Exception.Message)"
                }
            }
        }
    }
}
Assert-True ((Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash -eq $setupHashBefore) 'Installer lifecycle changed the release-candidate Setup executable.'
