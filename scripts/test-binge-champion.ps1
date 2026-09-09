[CmdletBinding()]
param(
    [string]$Root = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$Root = [IO.Path]::GetFullPath($Root)

$rendererPaths = @(
    'platforms/windows/TautWeekly.ps1',
    'platforms/nas-docker/app/TautWeekly.ps1',
    'platforms/mac-docker/app/TautWeekly.ps1'
)

$requiredFunctions = @(
    'Get-OptionalStringProperty',
    'Safe-Int',
    'Format-WatchTime',
    'Get-HistoryRowPlayCount',
    'Test-HistoryRowQualifiedView',
    'Get-NewsletterPlatformHistoryTimestamp',
    'Test-TautulliLocalUserId',
    'Get-BingeChampion',
    'Get-BingeChampionDisplay',
    'Get-BingeChampionTitleBreakdown'
)

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

foreach ($relativePath in $rendererPaths) {
    $path = Join-Path $Root $relativePath
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -gt 0) {
        throw "Cannot test Binge Champion with parser errors: $relativePath"
    }

    foreach ($functionName in $requiredFunctions) {
        $definition = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
        }, $true) | Select-Object -First 1

        if ($null -eq $definition) {
            throw "Missing $functionName in $relativePath"
        }

        Invoke-Expression $definition.Extent.Text
    }

    $script:Config = [PSCustomObject]@{ WatchedPercent = 85 }

    $history = @(
        [PSCustomObject]@{
            media_type = 'movie'; play_duration = 14400; watched_status = 1
            percent_complete = 100; group_count = 2; rating_key = 'movie-1'
            title = 'Private Movie'; user_id = '10'; friendly_name = 'Private Winner'; started = 100
        },
        [PSCustomObject]@{
            media_type = 'episode'; play_duration = 7200; watched_status = 1
            percent_complete = 100; group_count = 20; grandparent_rating_key = 'show-1'
            grandparent_title = 'Private Show'; title = 'Episode'
            user_id = '10'; friendly_name = 'Private Winner'; started = 200
        },
        [PSCustomObject]@{
            media_type = 'episode'; play_duration = 18000; watched_status = 0
            percent_complete = 50; group_count = 10; grandparent_rating_key = 'show-2'
            grandparent_title = 'Runner Show'; title = 'Episode'
            user_id = '20'; friendly_name = 'Partial Runner'; started = 300
        },
        [PSCustomObject]@{
            media_type = 'movie'; play_duration = 21600; watched_status = 1
            percent_complete = 100; group_count = 50; rating_key = 'movie-3'
            title = 'Tie Movie'; user_id = '30'; friendly_name = 'Runner With Equal Time'; started = 150
        }
    )

    $champion = Get-BingeChampion -GlobalHistory $history
    Assert-True ($null -ne $champion) "$relativePath did not select a Binge Champion"
    Assert-True ($champion.UserId -eq '10') "$relativePath did not rank watch time first and plays second"
    Assert-True ($champion.Seconds -eq 21600) "$relativePath returned the wrong aggregate watch time"
    Assert-True ($champion.Plays -eq 2) "$relativePath multiplied grouped fragments into extra plays"
    Assert-True ($champion.MoviePlays -eq 1) "$relativePath returned the wrong movie-play count"
    Assert-True ($champion.TvPlays -eq 1) "$relativePath returned the wrong TV-play count"
    Assert-True ($champion.QualifyingTitles -eq 2) "$relativePath did not count one movie and one TV show as two qualifying titles"
    Assert-True ($champion.QualifyingMovies -eq 1) "$relativePath returned the wrong unique movie count"
    Assert-True ($champion.QualifyingTvShows -eq 1) "$relativePath returned the wrong unique TV-show count"
    Assert-True ($champion.TotalTimeText -eq '6h 0m') "$relativePath returned the wrong watch-time label"

    foreach ($localId in @(0, '0', '000')) {
        $anonymousHistory = @(
            [PSCustomObject]@{ media_type = 'movie'; play_duration = 90000; watched_status = 1; percent_complete = 100; rating_key = 'anonymous-movie'; title = 'Anonymous Movie'; user_id = $localId; friendly_name = 'Renamed reserved user'; started = 400 }
        )
        $withAnonymous = Get-BingeChampion -GlobalHistory @($history + $anonymousHistory)
        Assert-True ($withAnonymous.UserId -eq '10') "$relativePath selected reserved user '$localId' as Binge Champion"
        Assert-True ($null -eq (Get-BingeChampion -GlobalHistory $anonymousHistory)) "$relativePath selected a champion when history only contains Local"
        Assert-True ($anonymousHistory.Count -eq 1 -and $anonymousHistory[0].play_duration -eq 90000) "$relativePath mutated anonymous playback history while selecting a champion"
    }
    $namedLocalHistory = @(
        [PSCustomObject]@{ media_type = 'movie'; play_duration = 3600; watched_status = 1; percent_complete = 100; rating_key = 'real-local-movie'; title = 'Real Local Movie'; user_id = '42'; friendly_name = 'Local'; started = 500 }
    )
    Assert-True ((Get-BingeChampion -GlobalHistory $namedLocalHistory).UserId -eq '42') "$relativePath excluded a real positive-ID profile named Local from Binge Champion"

    $winnerView = Get-BingeChampionDisplay -BingeChampion $champion -User ([PSCustomObject]@{
        UserId = '10'; FriendlyName = 'Private Winner'
    })
    $otherView = Get-BingeChampionDisplay -BingeChampion $champion -User ([PSCustomObject]@{
        UserId = '20'; FriendlyName = 'Runner With More Plays'
    })

    Assert-True $winnerView.IsWinner "$relativePath did not mark the winning recipient"
    Assert-True (-not $otherView.IsWinner) "$relativePath marked a non-winner as the champion"
    Assert-True ($winnerView.Plays -eq 2 -and $otherView.Plays -eq 2) "$relativePath did not share the total-play aggregate"
    Assert-True ($winnerView.MoviePlays -eq 1 -and $otherView.MoviePlays -eq 1) "$relativePath did not share the movie aggregate"
    Assert-True ($winnerView.TvPlays -eq 1 -and $otherView.TvPlays -eq 1) "$relativePath did not share the TV aggregate"
    Assert-True ($winnerView.QualifyingTitles -eq 2 -and $otherView.QualifyingTitles -eq 2) "$relativePath did not share the qualifying-title aggregate"
    Assert-True ($winnerView.QualifyingMovies -eq 1 -and $otherView.QualifyingMovies -eq 1) "$relativePath did not share the unique movie aggregate"
    Assert-True ($winnerView.QualifyingTvShows -eq 1 -and $otherView.QualifyingTvShows -eq 1) "$relativePath did not share the unique TV-show aggregate"
    Assert-True ($winnerView.TotalTimeText -eq '6h 0m' -and $otherView.TotalTimeText -eq '6h 0m') "$relativePath did not share the watch-time aggregate"

    $cumulativeEpisodeHistory = @(
        [PSCustomObject]@{
            media_type = 'movie'; play_duration = 5400; watched_status = 1
            percent_complete = 100; group_count = 1; rating_key = 'movie-cumulative'
            title = 'Private Movie'; user_id = '40'; friendly_name = 'Episode Winner'; started = 400
        },
        [PSCustomObject]@{
            media_type = 'episode'; play_duration = 1800; watched_status = 1
            percent_complete = 100; group_count = 1; rating_key = 'episode-a1'
            grandparent_rating_key = 'show-a'; grandparent_title = 'Private Show A'
            title = 'Episode A1'; user_id = '40'; friendly_name = 'Episode Winner'; started = 401
        },
        [PSCustomObject]@{
            media_type = 'episode'; play_duration = 1800; watched_status = 1
            percent_complete = 100; group_count = 1; rating_key = 'episode-a2'
            grandparent_rating_key = 'show-a'; grandparent_title = 'Private Show A'
            title = 'Episode A2'; user_id = '40'; friendly_name = 'Episode Winner'; started = 402
        },
        [PSCustomObject]@{
            media_type = 'episode'; play_duration = 1800; watched_status = 1
            percent_complete = 100; group_count = 1; rating_key = 'episode-b1'
            grandparent_rating_key = 'show-b'; grandparent_title = 'Private Show B'
            title = 'Episode B1'; user_id = '40'; friendly_name = 'Episode Winner'; started = 403
        }
    )
    $cumulativeChampion = Get-BingeChampion -GlobalHistory $cumulativeEpisodeHistory
    Assert-True ($cumulativeChampion.Plays -eq 4) "$relativePath lost the cumulative total-play count"
    Assert-True ($cumulativeChampion.QualifyingMovies -eq 1) "$relativePath lost the cumulative unique-movie count"
    Assert-True ($cumulativeChampion.QualifyingTvShows -eq 2) "$relativePath repeated an episode count as the TV-show count"
    Assert-True ($cumulativeChampion.TvPlays -eq 3) "$relativePath did not total qualifying episodes across TV shows"

    $bullet = [char]0x2022
    Assert-True ((Get-BingeChampionTitleBreakdown -BingeDisplay ([PSCustomObject]@{ Plays = 1; QualifyingMovies = 1; QualifyingTvShows = 0 })) -eq "1 play $bullet 1 movie") "$relativePath lost singular play/movie copy"
    Assert-True ((Get-BingeChampionTitleBreakdown -BingeDisplay ([PSCustomObject]@{ Plays = 2; QualifyingMovies = 2; QualifyingTvShows = 0 })) -eq "2 plays $bullet 2 movies") "$relativePath lost plural play/movie copy"
    Assert-True ((Get-BingeChampionTitleBreakdown -BingeDisplay ([PSCustomObject]@{ Plays = 1; QualifyingMovies = 0; QualifyingTvShows = 1 })) -eq "1 play $bullet 1 TV show") "$relativePath lost singular TV-show copy"
    Assert-True ((Get-BingeChampionTitleBreakdown -BingeDisplay ([PSCustomObject]@{ Plays = 3; QualifyingMovies = 0; QualifyingTvShows = 3 })) -eq "3 plays $bullet 3 TV shows") "$relativePath lost plural TV-show copy"
    Assert-True ((Get-BingeChampionTitleBreakdown -BingeDisplay ([PSCustomObject]@{ Plays = 7; QualifyingMovies = 5; QualifyingTvShows = 2 })) -eq "7 plays $bullet 5 movies $bullet 2 TV shows") "$relativePath lost the mixed play/title breakdown"
    Assert-True ((Get-BingeChampionTitleBreakdown -BingeDisplay ([PSCustomObject]@{ Plays = 2; QualifyingMovies = 0; QualifyingTvShows = 1; TvPlays = 1 })) -eq "2 plays $bullet 1 TV show") "$relativePath did not suppress a single-episode suffix"
    Assert-True ((Get-BingeChampionTitleBreakdown -BingeDisplay ([PSCustomObject]@{ Plays = 7; QualifyingMovies = 1; QualifyingTvShows = 2; TvPlays = 7 })) -eq "7 plays $bullet 1 movie $bullet 2 TV shows: 7 episodes") "$relativePath lost cumulative episode summary or singular/plural copy"
    Assert-True ((Get-BingeChampionTitleBreakdown -BingeDisplay (Get-BingeChampionDisplay -BingeChampion $cumulativeChampion -User ([PSCustomObject]@{ UserId = '50'; FriendlyName = 'Observer' }))) -eq "4 plays $bullet 1 movie $bullet 2 TV shows: 3 episodes") "$relativePath repeated the TV-show count instead of summing episodes"
    Assert-True ([string]::IsNullOrWhiteSpace((Get-BingeChampionTitleBreakdown -BingeDisplay ([PSCustomObject]@{ Plays = 0; QualifyingMovies = 0; QualifyingTvShows = 0 })))) "$relativePath rendered zero-count categories"

    $legacyDisplay = Get-BingeChampionDisplay -BingeChampion ([PSCustomObject]@{
        UserId = '10'; FriendlyName = 'Private Winner'; Seconds = 21600
        TotalTimeText = '6h 0m'; MoviePlays = 20; TvPlays = 30
    }) -User ([PSCustomObject]@{ UserId = '20'; FriendlyName = 'Observer' })
    Assert-True ($legacyDisplay.QualifyingTitles -eq 0) "$relativePath substituted play counts for a missing title count"
    Assert-True ($legacyDisplay.QualifyingMovies -eq 0 -and $legacyDisplay.QualifyingTvShows -eq 0) "$relativePath substituted play counts for missing media-title counts"

    foreach ($privateProperty in @('UserId', 'FriendlyName', 'Title', 'Titles', 'TopTitles')) {
        Assert-True (
            $otherView.PSObject.Properties.Name -notcontains $privateProperty
        ) "$relativePath leaked $privateProperty through the non-winner display model"
    }

    $source = Get-Content -LiteralPath $path -Raw
    Assert-True ($source -notmatch 'WinningTitle|TopTitles|YOUR TOP TITLES') "$relativePath retains title-based Binge Champion output"
    Assert-True ($source -notmatch '\$bingeHeadline|\$bingeTitleCount|\$bingeTitleWord') "$relativePath retains the retired one-line Binge Champion metric"
    $sharedSupportStyle = 'padding-top:3px;font-size:12px;line-height:1.35;font-weight:400;color:#8e8e8e;'
    Assert-True ($source.Contains("`$summarySupportingStyle = '$sharedSupportStyle'")) "$relativePath does not define the shared supporting typography"
    Assert-True ($source.Contains('$bingeBreakdownHtml = "<div style=`"$summarySupportingStyle`">')) "$relativePath does not use the shared style for the Binge breakdown"
    Assert-True ($source.Contains('<div style="$summarySupportingStyle">total watch time</div>')) "$relativePath does not use the shared style for total watch time"
    Assert-True ($source.Contains('$footerFeature += "`r`n${winnerLine}`r`n$($bingeDisplay.TotalTimeText) watched"')) "$relativePath does not use the two-line Binge Champion plain-text format"
    Assert-True ($source -notmatch 'movie/TV play split') "$relativePath retains the retired Binge Champion play-split copy"
    $winnerEyebrow = 'YOU WON ' + [char]0x2022 + ' BINGE CHAMPION'
    Assert-True ($source.Contains($winnerEyebrow)) "$relativePath lost the winner presentation"
    Assert-True ($source -match "THIS WEEK'S BINGE CHAMPION") "$relativePath lost the non-winner presentation"
    Assert-True ($source -match 'if \(\$isBingeWinner\) \{ 54 \} else \{ 42 \}') "$relativePath does not preserve winner/non-winner trophy sizing"

    Write-Host "[PASS] Binge Champion privacy and ranking: $relativePath"
}
