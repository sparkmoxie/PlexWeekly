[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$PythonPath = 'python'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$fakeTautulli = Join-Path $Root 'scripts/test-support/fake-tautulli.py'
$fakeSmtp = Join-Path $Root 'scripts/test-support/fake-smtp.py'
$headlessRunner = Join-Path $Root 'scripts/test-support/invoke-renderer-headless.ps1'
$powerShell7 = Get-Command pwsh -ErrorAction SilentlyContinue
$windowsHost = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe' } else { '' }
$processWindowArgs = @{}
if ($PSVersionTable.PSEdition -eq 'Desktop' -or $env:OS -eq 'Windows_NT') {
    $processWindowArgs.WindowStyle = 'Hidden'
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-ScenarioValue([object]$Scenario, [string]$Name, [object]$Default) {
    $property = $Scenario.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-FreeTcpPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function New-VirtualUser([string]$Id, [string]$Email, [int]$Active = 1, [int]$Notify = 1) {
    return [PSCustomObject]@{
        user_id = $Id
        username = "viewer-$Id"
        friendly_name = "Virtual Viewer $Id"
        email = $Email
        is_active = $Active
        deleted_user = 0
        do_notify = $Notify
    }
}

$scenarios = @(
    [PSCustomObject]@{
        Name = 'all-legacy-notify-disabled'
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com' -Notify 0),
            (New-VirtualUser -Id '2' -Email 'viewer2@example.com' -Notify 0)
        )
        ExcludedUserIds = @()
        ExcludedEmails = @()
        RejectRecipient = ''
        FreshAccessState = $true
        ExitCode = 0
        Outcome = 'succeeded'
        ErrorCategory = ''
        Accepted = 2
        Skipped = 0
        Failed = 0
        Reasons = @(0, 0, 0, 0)
        SendDelay = 1
        MinimumConnectionGapMilliseconds = 800
        ExpectedConnections = 2
    },
    [PSCustomObject]@{
        Name = 'stale-manager-discovery-new-user'
        DiscoveryUsers = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com')
        )
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com'),
            (New-VirtualUser -Id '2' -Email 'viewer2@example.com')
        )
        ExcludedUserIds = @()
        ExcludedEmails = @()
        RejectRecipient = ''
        FreshAccessState = $false
        ExitCode = 0
        Outcome = 'succeeded'
        ErrorCategory = ''
        Accepted = 2
        Skipped = 0
        Failed = 0
        Reasons = @(0, 0, 0, 0)
    },
    [PSCustomObject]@{
        Name = 'mixed-fixed-skip-reasons'
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com' -Notify 0),
            (New-VirtualUser -Id '2' -Email 'viewer2@example.com' -Active 0),
            (New-VirtualUser -Id '3' -Email ''),
            (New-VirtualUser -Id '4' -Email 'viewer4@example.com'),
            (New-VirtualUser -Id '5' -Email 'viewer5@example.com')
        )
        ExcludedUserIds = @('4')
        ExcludedEmails = @('viewer5@example.com')
        RejectRecipient = ''
        FreshAccessState = $false
        ExitCode = 0
        Outcome = 'succeeded'
        ErrorCategory = ''
        Accepted = 1
        Skipped = 4
        Failed = 0
        Reasons = @(1, 1, 1, 1)
    },
    [PSCustomObject]@{
        Name = 'managed-fallback-native-precedence-shared-inbox'
        Users = @(
            (New-VirtualUser -Id '1' -Email ''),
            (New-VirtualUser -Id '2' -Email 'native2@example.com'),
            (New-VirtualUser -Id '3' -Email '')
        )
        UserEmailOverrides = [ordered]@{
            '1' = 'shared-managed@example.com'
            '2' = 'must-not-reroute@example.com'
            '3' = 'shared-managed@example.com'
        }
        ExcludedUserIds = @()
        ExcludedEmails = @()
        RejectRecipient = ''
        FreshAccessState = $false
        ExitCode = 0
        Outcome = 'succeeded'
        ErrorCategory = ''
        Accepted = 3
        Skipped = 0
        Failed = 0
        Reasons = @(0, 0, 0, 0)
        ExpectedRecipients = @('shared-managed@example.com', 'native2@example.com', 'shared-managed@example.com')
        ExpectedConnections = 3
    },
    [PSCustomObject]@{
        Name = 'managed-fallback-exclusion-precedence'
        Users = @(
            (New-VirtualUser -Id '10' -Email ''),
            (New-VirtualUser -Id '11' -Email ''),
            (New-VirtualUser -Id '12' -Email '')
        )
        UserEmailOverrides = [ordered]@{
            '11' = 'blocked-managed@example.com'
        }
        ExcludedUserIds = @('10')
        ExcludedEmails = @('blocked-managed@example.com')
        RejectRecipient = ''
        FreshAccessState = $false
        ExitCode = 3
        Outcome = 'failed'
        ErrorCategory = 'no-eligible-recipients'
        Accepted = 0
        Skipped = 3
        Failed = 0
        Reasons = @(0, 1, 1, 1)
        ExpectedRecipients = @()
        ExpectedConnections = 0
    },
    [PSCustomObject]@{
        Name = 'all-explicitly-excluded'
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com'),
            (New-VirtualUser -Id '2' -Email 'viewer2@example.com')
        )
        ExcludedUserIds = @('1')
        ExcludedEmails = @('viewer2@example.com')
        RejectRecipient = ''
        FreshAccessState = $false
        ExitCode = 3
        Outcome = 'failed'
        ErrorCategory = 'no-eligible-recipients'
        Accepted = 0
        Skipped = 2
        Failed = 0
        Reasons = @(0, 0, 1, 1)
    },
    [PSCustomObject]@{
        Name = 'partial-smtp-failure'
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com'),
            (New-VirtualUser -Id '2' -Email 'viewer2@example.com')
        )
        ExcludedUserIds = @()
        ExcludedEmails = @()
        RejectRecipient = 'viewer2@example.com'
        FreshAccessState = $false
        ExitCode = 2
        Outcome = 'partial'
        ErrorCategory = 'smtp-recipient-rejected'
        Accepted = 1
        Skipped = 0
        Failed = 1
        Reasons = @(0, 0, 0, 0)
        SmtpFailureCategory = 'smtp-recipient-rejected'
        SmtpFailureStage = 'rcpt-to'
        SmtpFailureCode = 550
        SmtpFailureBatchFatal = $false
        SmtpFailureAcceptance = 'not-attempted'
        ExpectedConnections = 2
    },
    [PSCustomObject]@{
        Name = 'recipient-rejection-continues-spaced'
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com'),
            (New-VirtualUser -Id '2' -Email 'viewer2@example.com'),
            (New-VirtualUser -Id '3' -Email 'viewer3@example.com')
        )
        ExcludedUserIds = @()
        ExcludedEmails = @()
        RejectRecipient = 'viewer1@example.com'
        FreshAccessState = $false
        ExitCode = 2
        Outcome = 'partial'
        ErrorCategory = 'smtp-recipient-rejected'
        Accepted = 2
        Skipped = 0
        Failed = 1
        Reasons = @(0, 0, 0, 0)
        SendDelay = 1
        MinimumConnectionGapMilliseconds = 800
        ExpectedConnections = 3
        SmtpFailureCategory = 'smtp-recipient-rejected'
        SmtpFailureStage = 'rcpt-to'
        SmtpFailureCode = 550
        SmtpFailureBatchFatal = $false
        SmtpFailureAcceptance = 'not-attempted'
    },
    [PSCustomObject]@{
        Name = 'auth-failure-stops-batch'
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com'),
            (New-VirtualUser -Id '2' -Email 'viewer2@example.com')
        )
        ExcludedUserIds = @()
        ExcludedEmails = @()
        RejectRecipient = ''
        FakeSmtpMode = 'auth-failure'
        FreshAccessState = $false
        ExitCode = 2
        Outcome = 'failed'
        ErrorCategory = 'smtp-auth-failed'
        Accepted = 0
        Skipped = 0
        Failed = 1
        Reasons = @(0, 0, 0, 0)
        SmtpFailureCategory = 'smtp-auth-failed'
        SmtpFailureStage = 'auth'
        SmtpFailureCode = 535
        SmtpFailureBatchFatal = $true
        SmtpFailureAcceptance = 'not-attempted'
        ExpectedConnections = 1
    },
    [PSCustomObject]@{
        Name = 'rate-limit-stops-batch'
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com'),
            (New-VirtualUser -Id '2' -Email 'viewer2@example.com')
        )
        ExcludedUserIds = @()
        ExcludedEmails = @()
        RejectRecipient = ''
        FakeSmtpMode = 'rate-limit-greeting'
        FreshAccessState = $false
        ExitCode = 2
        Outcome = 'failed'
        ErrorCategory = 'smtp-rate-limited'
        Accepted = 0
        Skipped = 0
        Failed = 1
        Reasons = @(0, 0, 0, 0)
        SmtpFailureCategory = 'smtp-rate-limited'
        SmtpFailureStage = 'greeting'
        SmtpFailureCode = 421
        SmtpFailureBatchFatal = $true
        SmtpFailureAcceptance = 'not-attempted'
        ExpectedConnections = 1
    },
    [PSCustomObject]@{
        Name = 'ambiguous-data-stops-without-retry'
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com'),
            (New-VirtualUser -Id '2' -Email 'viewer2@example.com')
        )
        ExcludedUserIds = @()
        ExcludedEmails = @()
        RejectRecipient = ''
        FakeSmtpMode = 'drop-after-data'
        FreshAccessState = $false
        ExitCode = 2
        Outcome = 'failed'
        ErrorCategory = 'smtp-acceptance-unknown'
        Accepted = 0
        Skipped = 0
        Failed = 1
        Reasons = @(0, 0, 0, 0)
        SmtpFailureCategory = 'smtp-acceptance-unknown'
        SmtpFailureStage = 'data-acceptance'
        SmtpFailureCode = 0
        SmtpFailureBatchFatal = $true
        SmtpFailureAcceptance = 'unknown'
        ExpectedConnections = 1
    },
    [PSCustomObject]@{
        Name = 'batch-policy-rejection-stops-batch'
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com'),
            (New-VirtualUser -Id '2' -Email 'viewer2@example.com')
        )
        ExcludedUserIds = @()
        ExcludedEmails = @()
        RejectRecipient = ''
        FakeSmtpMode = 'reject-policy'
        FreshAccessState = $false
        ExitCode = 2
        Outcome = 'failed'
        ErrorCategory = 'smtp-provider-rejected'
        Accepted = 0
        Skipped = 0
        Failed = 1
        Reasons = @(0, 0, 0, 0)
        SmtpFailureCategory = 'smtp-provider-rejected'
        SmtpFailureStage = 'rcpt-to'
        SmtpFailureCode = 550
        SmtpFailureBatchFatal = $true
        SmtpFailureAcceptance = 'not-attempted'
        ExpectedConnections = 1
    },
    [PSCustomObject]@{
        Name = 'required-roster-refresh-failure'
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com')
        )
        FailRefresh = $true
        ExcludedUserIds = @()
        ExcludedEmails = @()
        RejectRecipient = ''
        FreshAccessState = $false
        ExitCode = 1
        Outcome = 'failed'
        ErrorCategory = 'user-roster-refresh-failed'
        Accepted = 0
        Skipped = 0
        Failed = 0
        Reasons = @(0, 0, 0, 0)
    }
)

$engines = @(
    [PSCustomObject]@{ Name = 'windows'; Source = 'platforms/windows'; Host = $windowsHost; Container = $false },
    [PSCustomObject]@{ Name = 'nas-docker-linux-freebsd'; Source = 'platforms/nas-docker/app'; Host = $(if ($powerShell7) { $powerShell7.Source } else { '' }); Container = $true },
    [PSCustomObject]@{ Name = 'mac-docker'; Source = 'platforms/mac-docker/app'; Host = $(if ($powerShell7) { $powerShell7.Source } else { '' }); Container = $true }
)

$executed = 0
foreach ($engine in $engines) {
    if ([string]::IsNullOrWhiteSpace([string]$engine.Host) -or -not (Test-Path -LiteralPath $engine.Host)) {
        Write-Warning "Skipping $($engine.Name) because its PowerShell runtime is unavailable."
        continue
    }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-sendall-policy-' + [Guid]::NewGuid().ToString('N'))
    $appRoot = Join-Path $tempRoot 'app'
    $dataRoot = Join-Path $tempRoot 'data'
    $usersFile = Join-Path $tempRoot 'users.json'
    $refreshUsersFile = Join-Path $tempRoot 'refresh-users.json'
    $failRefreshFile = Join-Path $tempRoot 'fail-refresh.flag'
    $tautulliLog = Join-Path $tempRoot 'tautulli-calls.jsonl'
    $tautulliReady = Join-Path $tempRoot 'tautulli-ready.txt'
    $tautulliStdout = Join-Path $tempRoot 'tautulli.stdout.txt'
    $tautulliStderr = Join-Path $tempRoot 'tautulli.stderr.txt'
    New-Item -ItemType Directory -Force -Path $appRoot, $dataRoot | Out-Null
    Copy-Item -Path (Join-Path (Join-Path $Root ([string]$engine.Source)) '*') -Destination $appRoot -Recurse -Force

    $tautulli = $null
    try {
        ConvertTo-Json -InputObject @($scenarios[0].Users) -Depth 8 | Set-Content -LiteralPath $usersFile -Encoding UTF8
        $tautulliPort = Get-FreeTcpPort
        $tautulli = Start-Process -FilePath $PythonPath -ArgumentList @(
            '-u', $fakeTautulli, '--port', [string]$tautulliPort, '--scenario', 'quiet',
            '--users-file', $usersFile, '--refresh-users-file', $refreshUsersFile,
            '--fail-refresh-file', $failRefreshFile, '--call-log', $tautulliLog, '--ready-file', $tautulliReady
        ) -PassThru @processWindowArgs -RedirectStandardOutput $tautulliStdout -RedirectStandardError $tautulliStderr
        for ($attempt = 0; $attempt -lt 100 -and -not (Test-Path $tautulliReady); $attempt++) {
            if ($tautulli.HasExited) { throw "Virtual Tautulli exited early: $(Get-Content $tautulliStderr -Raw -ErrorAction SilentlyContinue)" }
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path $tautulliReady) "Virtual Tautulli did not become ready for $($engine.Name)."
        $baseUrl = (Get-Content $tautulliReady -Raw).Trim()

        if ($engine.Container) {
            New-Item -ItemType Directory -Force -Path (Join-Path $dataRoot 'assets') | Out-Null
            Copy-Item -Path (Join-Path $appRoot 'assets-default/*') -Destination (Join-Path $dataRoot 'assets') -Recurse -Force
            $configPath = Join-Path $dataRoot 'config.json'
        }
        else {
            $configPath = Join-Path $appRoot 'config.json'
        }

        foreach ($scenario in $scenarios) {
            $discoveryUsers = if ($null -ne $scenario.PSObject.Properties['DiscoveryUsers']) { @($scenario.DiscoveryUsers) } else { @($scenario.Users) }
            ConvertTo-Json -InputObject @($discoveryUsers) -Depth 8 | Set-Content -LiteralPath $usersFile -Encoding UTF8
            if ($null -ne $scenario.PSObject.Properties['DiscoveryUsers']) {
                ConvertTo-Json -InputObject @($scenario.Users) -Depth 8 | Set-Content -LiteralPath $refreshUsersFile -Encoding UTF8
            }
            else {
                [IO.File]::WriteAllText($refreshUsersFile, '')
            }
            if ($null -ne $scenario.PSObject.Properties['FailRefresh'] -and [bool]$scenario.FailRefresh) {
                New-Item -ItemType File -Force -Path $failRefreshFile | Out-Null
            }
            else {
                Remove-Item -LiteralPath $failRefreshFile -Force -ErrorAction SilentlyContinue
            }
            $userProbe = Invoke-RestMethod -Uri ($baseUrl + '/api/v2?apikey=virtual-api-key&cmd=get_users') -Method Get
            Assert-True (@($userProbe.response.data).Count -eq @($discoveryUsers).Count) "$($engine.Name)/$($scenario.Name) virtual discovery roster did not load deterministically."
            $callBaseline = @(Get-Content -LiteralPath $tautulliLog -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
            $smtpPort = Get-FreeTcpPort
            $smtpLog = Join-Path $tempRoot ("smtp-$($scenario.Name).jsonl")
            $smtpReady = Join-Path $tempRoot ("smtp-$($scenario.Name)-ready.txt")
            $smtpStdout = Join-Path $tempRoot ("smtp-$($scenario.Name).stdout.txt")
            $smtpStderr = Join-Path $tempRoot ("smtp-$($scenario.Name).stderr.txt")
            $smtpArguments = @('-u', $fakeSmtp, '--port', [string]$smtpPort, '--call-log', $smtpLog, '--ready-file', $smtpReady)
            if (-not [string]::IsNullOrWhiteSpace([string]$scenario.RejectRecipient)) {
                $smtpArguments += @('--reject-recipient', [string]$scenario.RejectRecipient)
            }
            $fakeSmtpMode = [string](Get-ScenarioValue -Scenario $scenario -Name 'FakeSmtpMode' -Default '')
            switch ($fakeSmtpMode) {
                'auth-failure' { $smtpArguments += '--auth-failure' }
                'rate-limit-greeting' { $smtpArguments += '--rate-limit-greeting' }
                'drop-after-data' { $smtpArguments += '--drop-after-data' }
                'reject-policy' { $smtpArguments += '--reject-policy' }
            }
            $smtp = $null
            $smtp = Start-Process -FilePath $PythonPath -ArgumentList $smtpArguments -PassThru @processWindowArgs -RedirectStandardOutput $smtpStdout -RedirectStandardError $smtpStderr
            try {
                for ($attempt = 0; $attempt -lt 100 -and -not (Test-Path $smtpReady); $attempt++) {
                    if ($smtp.HasExited) { throw "Virtual SMTP exited early: $(Get-Content $smtpStderr -Raw -ErrorAction SilentlyContinue)" }
                    Start-Sleep -Milliseconds 50
                }
                Assert-True (Test-Path $smtpReady) "Virtual SMTP did not become ready for $($engine.Name)/$($scenario.Name)."

                $config = Get-Content (Join-Path $appRoot 'config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                $overrides = [ordered]@{
                    TautulliUrl = $baseUrl; ApiKey = 'virtual-api-key'; PlexServerUrl = $baseUrl; PlexToken = 'virtual-plex-token'
                    FooterServerName = 'Virtual Plex'; IncludedLibraryIds = @('10', '20')
                    ExcludedUserIds = @($scenario.ExcludedUserIds); ExcludedEmails = @($scenario.ExcludedEmails)
                    UserEmailOverrides = (Get-ScenarioValue -Scenario $scenario -Name 'UserEmailOverrides' -Default ([ordered]@{}))
                    DaysBack = 7; MaxMovies = 2; MaxTv = 2; SendDelaySeconds = [int](Get-ScenarioValue -Scenario $scenario -Name 'SendDelay' -Default 0)
                    SmtpHost = '127.0.0.1'; SmtpPort = $smtpPort; SmtpEnableSsl = $false; SmtpUseAuthentication = ($fakeSmtpMode -eq 'auth-failure'); SmtpTimeoutSeconds = 5
                    SmtpUsername = 'virtual-sender@example.com'; SmtpPassword = 'virtual-app-password'; SmtpAuthenticationMethod = 'Auto'
                    FromEmail = 'sender@example.com'; FromName = 'TautWeekly Policy Test'; TestEmail = 'test@example.com'
                }
                foreach ($entry in $overrides.GetEnumerator()) { $config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force }
                $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding UTF8

                $accessUsers = [ordered]@{}
                foreach ($user in @($scenario.Users)) {
                    $accessUsers[[string]$user.user_id] = [ordered]@{
                        UserId = [string]$user.user_id; Username = [string]$user.username; Email = [string]$user.email
                        FirstSeenUtc = [DateTime]::UtcNow.AddDays(-30).ToString('o'); IsBaseline = $true; WelcomeSentUtc = ''
                    }
                }
                $accessStatePath = Join-Path $(if ($engine.Container) { $dataRoot } else { $appRoot }) 'access-state.json'
                if ($scenario.FreshAccessState) {
                    Remove-Item -LiteralPath $accessStatePath -Force -ErrorAction SilentlyContinue
                }
                else {
                    [ordered]@{ BaselineUtc = [DateTime]::UtcNow.AddDays(-30).ToString('o'); Users = $accessUsers } |
                        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $accessStatePath -Encoding UTF8
                }

                $resultPath = Join-Path $tempRoot ("result-$($scenario.Name).json")
                $stdout = Join-Path $tempRoot ("renderer-$($scenario.Name).stdout.txt")
                $stderr = Join-Path $tempRoot ("renderer-$($scenario.Name).stderr.txt")
                $oldDataRoot = $env:TAUTWEEKLY_DATA_DIR
                $oldConfig = $env:TAUTWEEKLY_CONFIG
                try {
                    if ($engine.Container) {
                        $env:TAUTWEEKLY_DATA_DIR = $dataRoot
                        $env:TAUTWEEKLY_CONFIG = $configPath
                    }
                    if ($scenario.Name -eq 'all-legacy-notify-disabled') {
                        $unconfirmedResultPath = Join-Path $tempRoot ("result-unconfirmed-$($engine.Name).json")
                        $unconfirmedStdout = Join-Path $tempRoot ("renderer-unconfirmed-$($engine.Name).stdout.txt")
                        $unconfirmedStderr = Join-Path $tempRoot ("renderer-unconfirmed-$($engine.Name).stderr.txt")
                        $callsBeforeUnconfirmed = @(Get-Content -LiteralPath $tautulliLog -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
                        $unconfirmedProcess = Start-Process -FilePath $engine.Host -ArgumentList @(
                            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
                            '-RendererPath', (Join-Path $appRoot 'TautWeekly.ps1'), '-ConfigPath', $configPath,
                            '-UserId', '1', '-Mode', 'SendAll', '-ResultPath', $unconfirmedResultPath, '-NoConfirmSendAll'
                        ) -Wait -PassThru @processWindowArgs -RedirectStandardOutput $unconfirmedStdout -RedirectStandardError $unconfirmedStderr
                        Assert-True ($unconfirmedProcess.ExitCode -eq 1) "$($engine.Name) accepted an unconfirmed production SendAll."
                        $callsAfterUnconfirmed = @(Get-Content -LiteralPath $tautulliLog -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
                        Assert-True ($callsAfterUnconfirmed -eq $callsBeforeUnconfirmed) "$($engine.Name) contacted Tautulli before production confirmation."
                        $smtpCallsBeforeConfirmed = @(Get-Content -LiteralPath $smtpLog -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                        Assert-True ($smtpCallsBeforeConfirmed.Count -eq 0) "$($engine.Name) contacted SMTP before production confirmation."
                    }
                    $process = Start-Process -FilePath $engine.Host -ArgumentList @(
                        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
                        '-RendererPath', (Join-Path $appRoot 'TautWeekly.ps1'), '-ConfigPath', $configPath,
                        '-UserId', '1', '-Mode', 'SendAll', '-ResultPath', $resultPath
                    ) -Wait -PassThru @processWindowArgs -RedirectStandardOutput $stdout -RedirectStandardError $stderr
                }
                finally {
                    $env:TAUTWEEKLY_DATA_DIR = $oldDataRoot
                    $env:TAUTWEEKLY_CONFIG = $oldConfig
                }

                if ($process.ExitCode -ne $scenario.ExitCode) {
                    throw "$($engine.Name)/$($scenario.Name) exited $($process.ExitCode), expected $($scenario.ExitCode).`nRESULT:`n$(Get-Content $resultPath -Raw -ErrorAction SilentlyContinue)`nUSERS:`n$(Get-Content $usersFile -Raw -ErrorAction SilentlyContinue)`nSTDOUT:`n$(Get-Content $stdout -Raw -ErrorAction SilentlyContinue)`nSTDERR:`n$(Get-Content $stderr -Raw -ErrorAction SilentlyContinue)`nTAUTULLI CALLS:`n$(Get-Content $tautulliLog -Raw -ErrorAction SilentlyContinue)`nTAUTULLI STDERR:`n$(Get-Content $tautulliStderr -Raw -ErrorAction SilentlyContinue)"
                }
                Assert-True (Test-Path -LiteralPath $resultPath) "$($engine.Name)/$($scenario.Name) omitted its structured result."
                $resultRaw = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8
                $result = $resultRaw | ConvertFrom-Json
                Assert-True ($result.schemaVersion -eq 3 -and $result.outcome -eq $scenario.Outcome) "$($engine.Name)/$($scenario.Name) reported schema $($result.schemaVersion) / outcome $($result.outcome) / category $($result.errorCategory), expected 3 / $($scenario.Outcome)."
                Assert-True ([string]$result.errorCategory -eq [string]$scenario.ErrorCategory) "$($engine.Name)/$($scenario.Name) reported the wrong fixed error category."
                Assert-True ($result.smtpAcceptedCount -eq $scenario.Accepted -and $result.skippedCount -eq $scenario.Skipped -and $result.failedCount -eq $scenario.Failed) "$($engine.Name)/$($scenario.Name) reported inconsistent delivery aggregates."
                $actualReasons = @($result.skipReasonCounts.inactiveOrDeleted, $result.skipReasonCounts.missingEmail, $result.skipReasonCounts.excludedUserId, $result.skipReasonCounts.excludedEmail)
                Assert-True (($actualReasons -join ',') -eq (@($scenario.Reasons) -join ',')) "$($engine.Name)/$($scenario.Name) reported inconsistent fixed skip reasons."
                $expectedSmtpCategory = [string](Get-ScenarioValue -Scenario $scenario -Name 'SmtpFailureCategory' -Default '')
                if ([string]::IsNullOrWhiteSpace($expectedSmtpCategory)) {
                    Assert-True ($null -eq $result.smtpFailure) "$($engine.Name)/$($scenario.Name) retained unexpected SMTP failure evidence."
                }
                else {
                    Assert-True ($null -ne $result.smtpFailure) "$($engine.Name)/$($scenario.Name) omitted typed SMTP failure evidence."
                    Assert-True ([string]$result.smtpFailure.category -eq $expectedSmtpCategory) "$($engine.Name)/$($scenario.Name) reported the wrong sanitized SMTP category."
                    Assert-True ([string]$result.smtpFailure.stage -eq [string](Get-ScenarioValue $scenario 'SmtpFailureStage' '')) "$($engine.Name)/$($scenario.Name) reported the wrong sanitized SMTP stage."
                    Assert-True ([int]$result.smtpFailure.responseCode -eq [int](Get-ScenarioValue $scenario 'SmtpFailureCode' 0)) "$($engine.Name)/$($scenario.Name) reported the wrong sanitized SMTP response code."
                    Assert-True ([bool]$result.smtpFailure.batchFatal -eq [bool](Get-ScenarioValue $scenario 'SmtpFailureBatchFatal' $false)) "$($engine.Name)/$($scenario.Name) reported the wrong batch-fatal classification."
                    Assert-True ([string]$result.smtpFailure.acceptance -eq [string](Get-ScenarioValue $scenario 'SmtpFailureAcceptance' '')) "$($engine.Name)/$($scenario.Name) reported the wrong acceptance classification."
                }
                $smtpCalls = @(
                    Get-Content -LiteralPath $smtpLog -ErrorAction SilentlyContinue |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        ForEach-Object { $_ | ConvertFrom-Json }
                )
                $connections = @($smtpCalls | Where-Object { [string]$_.command -eq '<connection>' })
				$expectedRecipientsProperty = $scenario.PSObject.Properties['ExpectedRecipients']
				if ($null -ne $expectedRecipientsProperty) {
					$actualRecipients = @(
						$smtpCalls |
							ForEach-Object { [string]$_.command } |
							Where-Object { $_ -match '^RCPT TO:<([^>]+)>$' } |
							ForEach-Object { [regex]::Match($_, '^RCPT TO:<([^>]+)>$').Groups[1].Value }
					)
					$actualSorted = @($actualRecipients | Sort-Object)
					$expectedSorted = @(@($expectedRecipientsProperty.Value) | Sort-Object)
					Assert-True (($actualSorted -join ',') -ceq ($expectedSorted -join ',')) "$($engine.Name)/$($scenario.Name) sent to '$($actualSorted -join ',')' instead of '$($expectedSorted -join ',')'."
				}
                $expectedConnections = [int](Get-ScenarioValue -Scenario $scenario -Name 'ExpectedConnections' -Default -1)
                if ($expectedConnections -ge 0) {
                    Assert-True ($connections.Count -eq $expectedConnections) "$($engine.Name)/$($scenario.Name) opened $($connections.Count) SMTP connections instead of $expectedConnections."
                }
                $minimumGap = [int](Get-ScenarioValue -Scenario $scenario -Name 'MinimumConnectionGapMilliseconds' -Default 0)
                if ($minimumGap -gt 0 -and $connections.Count -gt 1) {
                    for ($connectionIndex = 1; $connectionIndex -lt $connections.Count; $connectionIndex++) {
                        $gapMilliseconds = ([double]$connections[$connectionIndex].timestamp - [double]$connections[$connectionIndex - 1].timestamp) * 1000
                        Assert-True ($gapMilliseconds -ge $minimumGap) "$($engine.Name)/$($scenario.Name) bypassed configured spacing after a recipient attempt ($([Math]::Round($gapMilliseconds)) ms)."
                    }
                }
                $tautulliCalls = @(
                    Get-Content -LiteralPath $tautulliLog -ErrorAction SilentlyContinue |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Select-Object -Skip $callBaseline |
                        ForEach-Object { $_ | ConvertFrom-Json }
                )
                $apiCommands = @(
                    $tautulliCalls |
                        Where-Object { [string]$_.path -eq '/api/v2' } |
                        ForEach-Object { [string]$_.query.cmd }
                )
                Assert-True (@($apiCommands | Where-Object { $_ -eq 'refresh_users_list' }).Count -eq 1) "$($engine.Name)/$($scenario.Name) did not refresh the Tautulli roster exactly once."
                Assert-True ($apiCommands.Count -gt 0 -and $apiCommands[0] -eq 'refresh_users_list') "$($engine.Name)/$($scenario.Name) did not refresh before reading production data."
                if ($scenario.Name -eq 'stale-manager-discovery-new-user') {
                    $refreshIndex = [Array]::IndexOf([object[]]$apiCommands, 'refresh_users_list')
                    $rosterIndex = [Array]::IndexOf([object[]]$apiCommands, 'get_users')
                    Assert-True ($refreshIndex -ge 0 -and $rosterIndex -gt $refreshIndex) "$($engine.Name) did not fetch the live roster after the required refresh."
                    Assert-True ($result.smtpAcceptedCount -eq 2) "$($engine.Name) did not include the synthetic user added after stale Manager discovery."
                }
                if ($scenario.Name -eq 'required-roster-refresh-failure') {
                    # A failed required refresh must stop before roster discovery,
                    # integration/media work, preview work, or SMTP preflight.
                    Assert-True ($apiCommands.Count -eq 1) "$($engine.Name) continued into production data calls after a failed roster refresh."
                    Assert-True ($smtpCalls.Count -eq 0) "$($engine.Name) contacted SMTP after the required roster refresh failed."
                    Assert-True (-not $resultRaw.Contains('virtual roster refresh rejected')) "$($engine.Name) exposed the raw upstream refresh failure."
                }
                foreach ($user in @($scenario.Users)) {
                    $privateValues = @([string]$user.email, [string]$user.friendly_name) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    foreach ($privateValue in $privateValues) {
                        Assert-True (-not $resultRaw.Contains($privateValue)) "$($engine.Name)/$($scenario.Name) exposed a recipient identity in its structured result."
                    }
                }
				$userEmailOverrides = Get-ScenarioValue -Scenario $scenario -Name 'UserEmailOverrides' -Default ([ordered]@{})
				foreach ($entry in $userEmailOverrides.GetEnumerator()) {
					Assert-True (-not $resultRaw.Contains([string]$entry.Value)) "$($engine.Name)/$($scenario.Name) exposed a managed-user delivery address in its structured result."
				}
				if ($scenario.Name -eq 'managed-fallback-native-precedence-shared-inbox') {
					$recipientBaseline = @($smtpCalls | Where-Object { [string]$_.command -match '^RCPT TO:' }).Count
					$cacheResultPath = Join-Path $tempRoot ("result-managed-cache-$($engine.Name).json")
					$cacheStdout = Join-Path $tempRoot ("renderer-managed-cache-$($engine.Name).stdout.txt")
					$cacheStderr = Join-Path $tempRoot ("renderer-managed-cache-$($engine.Name).stderr.txt")
					$testResultPath = Join-Path $tempRoot ("result-managed-test-$($engine.Name).json")
					$testStdout = Join-Path $tempRoot ("renderer-managed-test-$($engine.Name).stdout.txt")
					$testStderr = Join-Path $tempRoot ("renderer-managed-test-$($engine.Name).stderr.txt")
					$welcomeResultPath = Join-Path $tempRoot ("result-managed-welcome-$($engine.Name).json")
					$welcomeStdout = Join-Path $tempRoot ("renderer-managed-welcome-$($engine.Name).stdout.txt")
					$welcomeStderr = Join-Path $tempRoot ("renderer-managed-welcome-$($engine.Name).stderr.txt")
					$oldManagedDataRoot = $env:TAUTWEEKLY_DATA_DIR
					$oldManagedConfig = $env:TAUTWEEKLY_CONFIG
					try {
						if ($engine.Container) {
							$env:TAUTWEEKLY_DATA_DIR = $dataRoot
							$env:TAUTWEEKLY_CONFIG = $configPath
						}
						$cacheProcess = Start-Process -FilePath $engine.Host -ArgumentList @(
							'-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
							'-RendererPath', (Join-Path $appRoot 'TautWeekly.ps1'), '-ConfigPath', $configPath,
							'-Mode', 'CacheWarm', '-ResultPath', $cacheResultPath
						) -Wait -PassThru @processWindowArgs -RedirectStandardOutput $cacheStdout -RedirectStandardError $cacheStderr
						$testProcess = Start-Process -FilePath $engine.Host -ArgumentList @(
							'-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
							'-RendererPath', (Join-Path $appRoot 'TautWeekly.ps1'), '-ConfigPath', $configPath,
							'-UserId', '1', '-Mode', 'SendTest', '-ResultPath', $testResultPath
						) -Wait -PassThru @processWindowArgs -RedirectStandardOutput $testStdout -RedirectStandardError $testStderr
						$welcomeProcess = Start-Process -FilePath $engine.Host -ArgumentList @(
							'-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $appRoot 'TautWeekly.ps1'),
							'-ConfigPath', $configPath, '-UserId', '1', '-Mode', 'SendWelcome',
							'-ConfirmWelcome', '-ResultPath', $welcomeResultPath
						) -Wait -PassThru @processWindowArgs -RedirectStandardOutput $welcomeStdout -RedirectStandardError $welcomeStderr
					}
					finally {
						$env:TAUTWEEKLY_DATA_DIR = $oldManagedDataRoot
						$env:TAUTWEEKLY_CONFIG = $oldManagedConfig
					}
					if ($cacheProcess.ExitCode -ne 0 -or $testProcess.ExitCode -ne 0 -or $welcomeProcess.ExitCode -ne 0) {
						throw "$($engine.Name) managed CacheWarm/TestEmail/SendWelcome flow failed.`nCACHE:`n$(Get-Content $cacheStdout -Raw -ErrorAction SilentlyContinue)`nTEST:`n$(Get-Content $testStdout -Raw -ErrorAction SilentlyContinue)`nWELCOME:`n$(Get-Content $welcomeStdout -Raw -ErrorAction SilentlyContinue)"
					}
					$cacheOutput = Get-Content -LiteralPath $cacheStdout -Raw -Encoding UTF8
					$cacheResult = Get-Content -LiteralPath $cacheResultPath -Raw -Encoding UTF8
					Assert-True ($cacheOutput.Contains('Eligible users checked: 3')) "$($engine.Name) CacheWarm did not treat mapped users as eligible."
					Assert-True (-not $cacheResult.Contains('shared-managed@example.com')) "$($engine.Name) exposed the mapped address in a CacheWarm result."
					$managedCalls = @(
						Get-Content -LiteralPath $smtpLog -ErrorAction SilentlyContinue |
							Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
							ForEach-Object { $_ | ConvertFrom-Json }
					)
					$newRecipients = @(
						$managedCalls |
							Where-Object { [string]$_.command -match '^RCPT TO:<([^>]+)>$' } |
							Select-Object -Skip $recipientBaseline |
							ForEach-Object { [regex]::Match([string]$_.command, '^RCPT TO:<([^>]+)>$').Groups[1].Value }
					)
					Assert-True (($newRecipients -join ',') -ceq 'test@example.com,shared-managed@example.com') "$($engine.Name) did not isolate SendTest to TestEmail and route SendWelcome to the mapped address: $($newRecipients -join ',')."
					foreach ($resultFile in @($testResultPath, $welcomeResultPath)) {
						$managedResult = Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8
						Assert-True (-not $managedResult.Contains('shared-managed@example.com')) "$($engine.Name) exposed the mapped address in a renderer result."
					}
				}
                if ($scenario.Name -eq 'managed-fallback-exclusion-precedence') {
                    $blockedWelcomeResultPath = Join-Path $tempRoot ("result-managed-blocked-welcome-$($engine.Name).json")
                    $blockedWelcomeStdout = Join-Path $tempRoot ("renderer-managed-blocked-welcome-$($engine.Name).stdout.txt")
                    $blockedWelcomeStderr = Join-Path $tempRoot ("renderer-managed-blocked-welcome-$($engine.Name).stderr.txt")
                    $oldBlockedDataRoot = $env:TAUTWEEKLY_DATA_DIR
                    $oldBlockedConfig = $env:TAUTWEEKLY_CONFIG
                    try {
                        if ($engine.Container) {
                            $env:TAUTWEEKLY_DATA_DIR = $dataRoot
                            $env:TAUTWEEKLY_CONFIG = $configPath
                        }
                        $blockedWelcome = Start-Process -FilePath $engine.Host -ArgumentList @(
                            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $appRoot 'TautWeekly.ps1'),
                            '-ConfigPath', $configPath, '-UserId', '11', '-Mode', 'SendWelcome',
                            '-ConfirmWelcome', '-ResultPath', $blockedWelcomeResultPath
                        ) -Wait -PassThru @processWindowArgs -RedirectStandardOutput $blockedWelcomeStdout -RedirectStandardError $blockedWelcomeStderr
                    }
                    finally {
                        $env:TAUTWEEKLY_DATA_DIR = $oldBlockedDataRoot
                        $env:TAUTWEEKLY_CONFIG = $oldBlockedConfig
                    }
                    Assert-True ($blockedWelcome.ExitCode -ne 0) "$($engine.Name) SendWelcome bypassed ExcludedEmails for a managed-user effective address."
                    $blockedCalls = @(
                        Get-Content -LiteralPath $smtpLog -ErrorAction SilentlyContinue |
                            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    )
                    Assert-True ($blockedCalls.Count -eq 0) "$($engine.Name) SendWelcome contacted SMTP for an excluded managed-user effective address."
                }
                if ($scenario.Name -eq 'auth-failure-stops-batch') {
                    $testAllResultPath = Join-Path $tempRoot ("result-test-all-auth-failure-$($engine.Name).json")
                    $testAllStdout = Join-Path $tempRoot ("renderer-test-all-auth-failure-$($engine.Name).stdout.txt")
                    $testAllStderr = Join-Path $tempRoot ("renderer-test-all-auth-failure-$($engine.Name).stderr.txt")
                    $oldTestAllDataRoot = $env:TAUTWEEKLY_DATA_DIR
                    $oldTestAllConfig = $env:TAUTWEEKLY_CONFIG
                    try {
                        if ($engine.Container) {
                            $env:TAUTWEEKLY_DATA_DIR = $dataRoot
                            $env:TAUTWEEKLY_CONFIG = $configPath
                        }
                        $testAllProcess = Start-Process -FilePath $engine.Host -ArgumentList @(
                            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
                            '-RendererPath', (Join-Path $appRoot 'TautWeekly.ps1'), '-ConfigPath', $configPath,
                            '-UserId', '1', '-Mode', 'SendTestAll', '-ResultPath', $testAllResultPath
                        ) -Wait -PassThru @processWindowArgs -RedirectStandardOutput $testAllStdout -RedirectStandardError $testAllStderr
                    }
                    finally {
                        $env:TAUTWEEKLY_DATA_DIR = $oldTestAllDataRoot
                        $env:TAUTWEEKLY_CONFIG = $oldTestAllConfig
                    }

                    Assert-True ($testAllProcess.ExitCode -eq 1) "$($engine.Name) TestEmail authentication failure exited $($testAllProcess.ExitCode), expected 1."
                    Assert-True (Test-Path -LiteralPath $testAllResultPath) "$($engine.Name) TestEmail authentication failure omitted its structured result."
                    $testAllResultRaw = Get-Content -LiteralPath $testAllResultPath -Raw -Encoding UTF8
                    $testAllResult = $testAllResultRaw | ConvertFrom-Json
                    Assert-True ($testAllResult.schemaVersion -eq 3 -and $testAllResult.mode -eq 'SendTestAll' -and $testAllResult.outcome -eq 'failed') "$($engine.Name) TestEmail authentication failure reported an invalid result envelope."
                    Assert-True ([string]$testAllResult.errorCategory -eq 'smtp-auth-failed') "$($engine.Name) TestEmail authentication failure omitted its fixed error category."
                    Assert-True ($testAllResult.smtpAcceptedCount -eq 0 -and $testAllResult.skippedCount -eq 0 -and $testAllResult.failedCount -eq 1) "$($engine.Name) TestEmail authentication failure reported inconsistent aggregates."
                    Assert-True ($null -ne $testAllResult.smtpFailure) "$($engine.Name) TestEmail authentication failure omitted typed SMTP evidence."
                    Assert-True ([string]$testAllResult.smtpFailure.category -eq 'smtp-auth-failed' -and [string]$testAllResult.smtpFailure.stage -eq 'auth') "$($engine.Name) TestEmail authentication failure reported the wrong sanitized category or stage."
                    Assert-True ([int]$testAllResult.smtpFailure.responseCode -eq 535 -and [int]$testAllResult.smtpFailure.responseClass -eq 5) "$($engine.Name) TestEmail authentication failure reported the wrong sanitized response classification."
                    Assert-True ([bool]$testAllResult.smtpFailure.batchFatal -and [string]$testAllResult.smtpFailure.acceptance -eq 'not-attempted') "$($engine.Name) TestEmail authentication failure reported the wrong batch or acceptance classification."
                    foreach ($privateValue in @('virtual-sender@example.com', 'virtual-app-password', 'Authentication rejected')) {
                        Assert-True (-not $testAllResultRaw.Contains($privateValue)) "$($engine.Name) TestEmail authentication failure exposed credentials or provider response text."
                    }
                    $testAllSmtpCalls = @(
                        Get-Content -LiteralPath $smtpLog -ErrorAction SilentlyContinue |
                            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                            ForEach-Object { $_ | ConvertFrom-Json }
                    )
                    Assert-True (@($testAllSmtpCalls | Where-Object { [string]$_.command -eq '<connection>' }).Count -eq ($connections.Count + 1)) "$($engine.Name) TestEmail authentication failure did not stop after one additional SMTP connection."
                    Assert-True (@($testAllSmtpCalls | Where-Object { ([string]$_.command).StartsWith('MAIL FROM:', [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) "$($engine.Name) TestEmail authentication failure attempted an SMTP envelope after rejected authentication."
                    Write-Host "[PASS] TestEmail sanitized SMTP failure evidence: $($engine.Name)"
                }
                $executed++
                Write-Host "[PASS] SendAll recipient policy: $($engine.Name) / $($scenario.Name)"
            }
            finally {
                if ($null -ne $smtp -and -not $smtp.HasExited) {
                    Stop-Process -Id $smtp.Id -Force -ErrorAction SilentlyContinue
                    $smtp.WaitForExit()
                }
            }
        }
    }
    finally {
        if ($null -ne $tautulli -and -not $tautulli.HasExited) {
            Stop-Process -Id $tautulli.Id -Force -ErrorAction SilentlyContinue
            $tautulli.WaitForExit()
        }
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

foreach ($path in @('platforms/nas-docker/app/Scheduler.ps1', 'platforms/mac-docker/app/Scheduler.ps1')) {
    $scheduler = Get-Content -LiteralPath (Join-Path $Root $path) -Raw -Encoding UTF8
    Assert-True ($scheduler.Contains('& $runModePath SendAll --confirm-send-all')) "$path does not route scheduled delivery through the shared guarded SendAll mode."
}
$windowsSchedule = Get-Content -LiteralPath (Join-Path $Root 'platforms/windows/SCHEDULE-HELPER.ps1') -Raw -Encoding UTF8
Assert-True ($windowsSchedule.Contains('-Mode SendAll -ResultPath') -and $windowsSchedule.Contains('-ConfirmSendAll')) 'Windows scheduled delivery does not route through the shared guarded SendAll mode.'

foreach ($path in @('platforms/windows/TautWeekly.ps1', 'platforms/nas-docker/app/TautWeekly.ps1', 'platforms/mac-docker/app/TautWeekly.ps1')) {
    $renderer = Get-Content -LiteralPath (Join-Path $Root $path) -Raw -Encoding UTF8
    Assert-True ($renderer.Contains('Sync-AccessRoster -RequireFreshUsers:($Mode -eq "SendAll")')) "$path does not require the shared refresh-on-SendAll path."
}

$smtpHelpers = @('platforms/windows/Smtp-Transport.ps1', 'platforms/nas-docker/app/Smtp-Transport.ps1', 'platforms/mac-docker/app/Smtp-Transport.ps1')
$smtpHelperHashes = @($smtpHelpers | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $Root $_) -Algorithm SHA256).Hash } | Sort-Object -Unique)
Assert-True ($smtpHelperHashes.Count -eq 1) 'Maintained SMTP transport copies are not synchronized.'

Assert-True ($executed -gt 0) 'No SendAll recipient-policy scenarios executed.'
Write-Host "[PASS] SendAll recipient policy, privacy, platform synchronization, and schedule/manual parity validated ($executed scenarios)."
