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
    'Get-DesignProviderRating',
    'Get-DesignProviderRatingHtml',
    'Convert-DesignRatingPercent',
    'Find-DesignProviderRatingsRecursive',
    'ConvertTo-DesignGenreList',
    'Invoke-DesignPlexJson',
    'Get-DesignPlexMetadata',
    'Add-DesignRatingMetadata',
    'Get-DesignEpisodeImdbRating',
    'Get-DesignEpisodeRtRating',
    'Enrich-TvEpisodeMetadata',
    'Get-TvEpisodeSnapshotFromTautulli',
    'Merge-TvEpisodeSnapshots',
    'Get-DesignRatingLine',
    'Get-DesignGenreLine',
    'Get-StatsMovieRatingHtml',
    'Get-StatsMovieRowsHtml',
    'Test-RecipientHasWatchedMovie',
    'Get-RecipientWatchedPlainTextSuffix',
    'Get-StatsEpisodeRowsHtml',
    'Get-StatsTvShowRatingHtml',
    'Get-StatsTvShowRowsHtml',
    'Get-TvEpisodeLinesHtml',
    'Get-DesignRtIconUrl',
    'HtmlEncode',
    'Truncate-Text',
    'Get-PlexMetadataProviderBaseUrl',
    'Get-PlexHostedMetadataLookupPath',
    'Get-PlexHostedMetadataMatchPayload',
    'Get-PlexHostedMetadataItemFromResponse',
    'Test-PlexHostedMetadataExactMatch',
    'Get-PlexHostedMetadata',
    'Get-PlexWatchBaseUrl',
    'Get-PlexWatchRatings',
    'Get-TautulliDefaultPosterHash',
    'Get-FileSha256',
    'Test-TautulliLocalUserId',
    'Get-TautulliUser',
    'Get-TautulliUserNames',
    'Get-TautulliUsers',
    'Resolve-TautulliUserId',
    'Add-AccessStateUser',
    'Test-UserNeedsWelcome',
    'Mark-UserWelcomed',
    'Get-NewsletterUser',
    'Get-UserSkipReason',
    'Safe-Int',
    'Safe-Int64',
    'New-ReleaseData',
    'Get-LatestReleaseQueryScopes',
    'Get-HistoryRowPlayCount',
    'Test-HistoryRowQualifiedView',
    'Get-HistoryRowViewerKey',
    'Get-NewsletterPlatformCatalog',
    'ConvertTo-NewsletterPlatformAlias',
    'Resolve-NewsletterPlatform',
    'Get-NewsletterPlatformHistoryTimestamp',
    'Get-NewsletterPlatform',
    'Get-NewsletterLastPlatform',
    'Get-NewsletterPlatformHeadingHtml',
    'Format-WatchTime',
    'Get-ConfiguredServerName',
    'Get-ConfiguredPlexWebUrl',
    'Get-ConfiguredPlexButtonLabel',
    'Get-ConfiguredDeliveryDay',
    'Get-BoundedCustomTextValue',
    'Get-CustomTextCardTitleGifAsset',
    'Get-ConfiguredCustomTextCard',
    'Get-CustomTextCardTableHtml',
    'Get-CustomTextCardPlainText',
    'Get-UserStats',
    'Add-UserStatsMediaMetadata',
    'New-ZeroPreviewStats',
    'Get-PopulatedPreviewStats',
    'Get-HotNewRelease',
    'Get-GlobalTitleTotals',
    'Get-GlobalTrendingStat',
    'New-HeroItemFromGlobalStat',
    'Get-GlobalTrendingHero',
    'Get-NewsletterReleaseDisplayData',
    'Prepare-PosterAssets',
    'Get-DynamicPreheader',
    'Build-PlainText'
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
    $assetFolder = if ($relativePath -like 'platforms/windows/*') { 'assets' } else { 'assets-default' }
    $script:AssetsDir = Join-Path (Split-Path -Parent $path) $assetFolder
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -gt 0) {
        throw "Cannot test renderer with parser errors: $relativePath"
    }

    $rendererSource = [IO.File]::ReadAllText($path)
    Assert-True (-not $rendererSource.Contains('Title="Sample Movie') -and -not $rendererSource.Contains('Title="Sample Series')) "$relativePath fabricates watch rows for empty preview states"
    Assert-True (([regex]::Matches($rendererSource, 'Get-PopulatedPreviewStats -RealStats')).Count -eq 1) "$relativePath allows populated-state fixture statistics outside Build-AllEmailVariants"
    Assert-True ($rendererSource.Contains('Invoke-TautulliApi -Command "get_libraries"')) "$relativePath does not enumerate real movie/TV libraries for quiet-week fallback"
    Assert-True (([regex]::Matches($rendererSource, 'Get-NewsletterLastPlatform -ExpectedUserId \$user\.UserId')).Count -eq 3) "$relativePath does not apply Last Platform to manual, preview/test, and standard recipient paths"

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

    Assert-True ((Get-FileSha256 -Path $path) -eq (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) "$relativePath portable SHA-256 helper disagrees with the platform cmdlet"

    $platformCatalog = @(Get-NewsletterPlatformCatalog)
    Assert-True ($platformCatalog.Count -eq 22) "$relativePath does not expose the complete conservative platform catalog"
    Assert-True (@($platformCatalog.Key | Select-Object -Unique).Count -eq $platformCatalog.Count) "$relativePath duplicates a platform catalog key"
    Assert-True (@($platformCatalog.Cid | Select-Object -Unique).Count -eq $platformCatalog.Count) "$relativePath duplicates a platform content ID"
    Assert-True (@($platformCatalog.FileName | Select-Object -Unique).Count -eq $platformCatalog.Count) "$relativePath duplicates a platform asset filename"
    foreach ($platform in $platformCatalog) {
        Assert-True (@($platform.Aliases).Count -gt 0) "$relativePath has a platform without a conservative alias"
        $platformAssetPath = Join-Path $script:AssetsDir ([string]$platform.FileName)
        Assert-True (Test-Path -LiteralPath $platformAssetPath -PathType Leaf) "$relativePath is missing $($platform.FileName)"
        $platformBytes = [IO.File]::ReadAllBytes($platformAssetPath)
        Assert-True ($platformBytes.Length -gt 24 -and $platformBytes[0] -eq 0x89 -and $platformBytes[1] -eq 0x50 -and $platformBytes[2] -eq 0x4e -and $platformBytes[3] -eq 0x47) "$relativePath $($platform.FileName) is not a PNG"
        $platformWidth = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($platformBytes, 16))
        $platformHeight = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($platformBytes, 20))
        Assert-True ($platformWidth -eq 42 -and $platformHeight -eq 42) "$relativePath $($platform.FileName) is not the expected 2x 42px asset"
    }

    $platformRows = @(
        [PSCustomObject]@{ user_id = '1'; platform_name = 'chrome'; platform = 'ignored'; group_count = 2; started = 100 },
        [PSCustomObject]@{ user_id = '1'; platform = ' Android-TV '; group_count = 2; date = 200 },
        [PSCustomObject]@{ user_id = '1'; platform = 'Windows'; group_count = 1; stopped = 300 },
        [PSCustomObject]@{ user_id = '1'; platform = '<script>alert(1)</script>'; group_count = 500; started = 500 },
        [PSCustomObject]@{ user_id = '2'; platform = 'Roku'; group_count = 999; started = 999 },
        [PSCustomObject]@{ platform = 'Xbox'; group_count = 1000; started = 1000 }
    )
    $selectedPlatform = Get-NewsletterPlatform -History $platformRows -ExpectedUserId '1'
    Assert-True ($null -ne $selectedPlatform -and $selectedPlatform.Key -eq 'windows') "$relativePath did not use recency after treating each grouped reference as one play"
    Assert-True ((Resolve-NewsletterPlatform -Row ([PSCustomObject]@{ platform_name = 'windows'; platform = 'Android' })).Key -eq 'windows') "$relativePath did not prefer canonical platform_name"
    Assert-True ((Resolve-NewsletterPlatform -Row ([PSCustomObject]@{ platform_name = 'msedge' })).Key -eq 'microsoft-edge') "$relativePath did not recognize Tautulli's normalized Edge key"
    Assert-True ((Resolve-NewsletterPlatform -Row ([PSCustomObject]@{ platform_name = 'unknown'; platform = 'Google Chrome' })).Key -eq 'chrome') "$relativePath did not safely fall back from an unknown platform_name"
    Assert-True ((Get-NewsletterPlatform -History @(
        [PSCustomObject]@{ user_id = '1'; platform = 'Android'; group_count = 2; started = 500 },
        [PSCustomObject]@{ user_id = '1'; platform = 'Windows'; group_count = 3; started = 1000 }
    ) -ExpectedUserId '1').Key -eq 'windows') "$relativePath let group_count override one-reference play semantics"
    Assert-True ((Get-NewsletterPlatform -History @(
        [PSCustomObject]@{ user_id = '1'; platform = 'Chrome'; group_count = 1; date = '2026-08-22T08:00:00Z' },
        [PSCustomObject]@{ user_id = '1'; platform = 'Android'; group_count = 1; date = '2026-08-22T09:00:00Z' }
    ) -ExpectedUserId '1').Key -eq 'android') "$relativePath did not parse a textual history timestamp for tie-breaking"
    Assert-True ((Get-NewsletterPlatform -History @(
        [PSCustomObject]@{ user_id = '1'; platform = 'Chrome'; group_count = 1; started = 100 },
        [PSCustomObject]@{ user_id = '1'; platform = 'Android'; group_count = 1; started = 100 }
    ) -ExpectedUserId '1').Key -eq 'android') "$relativePath lost its deterministic final tie-break"
    Assert-True ($null -eq (Get-NewsletterPlatform -History @() -ExpectedUserId '1')) "$relativePath invented a platform for no activity"
    Assert-True ($null -eq (Get-NewsletterPlatform -History @(
        [PSCustomObject]@{ user_id = '1'; platform = '   '; group_count = 10; started = 100 },
        [PSCustomObject]@{ user_id = '1'; platform = '<unknown & unsafe>'; group_count = 10; started = 200 }
    ) -ExpectedUserId '1')) "$relativePath did not omit blank and unknown platforms"
    Assert-True ((Resolve-NewsletterPlatform -Row ([PSCustomObject]@{ platform = 'Vizio SmartCast' })).Key -eq 'opera') "$relativePath did not recognize Tautulli's Vizio SmartCast Last Platform value"

    $script:lastPlatformApiCalls = @()
    $script:lastPlatformApiResponse = [PSCustomObject]@{
        data = @(
            [PSCustomObject]@{ user_id = '1'; platform = 'tvOS' },
            [PSCustomObject]@{ user_id = '2'; platform = 'Roku' }
        )
    }
    $script:lastPlatformApiThrows = $false
    function Invoke-TautulliApi {
        param([string]$Command, [hashtable]$Parameters = @{})
        $script:lastPlatformApiCalls += [PSCustomObject]@{ Command = $Command; Parameters = $Parameters }
        if ($script:lastPlatformApiThrows) { throw 'Simulated Last Platform API failure' }
        return $script:lastPlatformApiResponse
    }
    $lastPlatform = Get-NewsletterLastPlatform -ExpectedUserId '1'
    Assert-True ($null -ne $lastPlatform -and $lastPlatform.Key -eq 'apple-tv') "$relativePath did not resolve the exact recipient's Last Platform"
    Assert-True ($script:lastPlatformApiCalls.Count -eq 1 -and $script:lastPlatformApiCalls[0].Command -eq 'get_users_table') "$relativePath did not use Tautulli's Users table for the fallback"
    Assert-True ([string]$script:lastPlatformApiCalls[0].Parameters.user_id -eq '1' -and [int]$script:lastPlatformApiCalls[0].Parameters.start -eq 0 -and [int]$script:lastPlatformApiCalls[0].Parameters.length -eq 1) "$relativePath did not bound Last Platform lookup to the exact recipient"

    $script:lastPlatformApiResponse = [PSCustomObject]@{ data = @([PSCustomObject]@{ user_id = '2'; platform = 'Roku' }) }
    Assert-True ($null -eq (Get-NewsletterLastPlatform -ExpectedUserId '1')) "$relativePath accepted another user's Last Platform"
    $script:lastPlatformApiResponse = [PSCustomObject]@{ data = @([PSCustomObject]@{ user_id = '1'; platform = 'Unknown Platform' }) }
    Assert-True ($null -eq (Get-NewsletterLastPlatform -ExpectedUserId '1')) "$relativePath invented an icon for an unknown Last Platform"
    $script:lastPlatformApiThrows = $true
    Assert-True ($null -eq (Get-NewsletterLastPlatform -ExpectedUserId '1')) "$relativePath did not safely omit a failed Last Platform lookup"
    $callsBeforeBlankId = $script:lastPlatformApiCalls.Count
    Assert-True ($null -eq (Get-NewsletterLastPlatform -ExpectedUserId ' ')) "$relativePath invented a Last Platform for a blank recipient ID"
    Assert-True ($script:lastPlatformApiCalls.Count -eq $callsBeforeBlankId) "$relativePath queried Tautulli without an exact recipient ID"

    $previewAssetBase = if ($relativePath -like 'platforms/windows/*') { '../assets' } else { 'assets' }
    $previewPlatformHtml = Get-NewsletterPlatformHeadingHtml -Platform $selectedPlatform -ImageMode Preview -PreviewAssetBase $previewAssetBase
    Assert-True ($previewPlatformHtml.Contains('YOUR WEEK ON PLEX') -and $previewPlatformHtml.Contains($previewAssetBase + '/platform-windows.png')) "$relativePath did not render the selected local preview asset immediately after the heading"
    Assert-True ($previewPlatformHtml.Contains('width="21" height="21"') -and $previewPlatformHtml.Contains('width:21px;height:21px;max-height:21px')) "$relativePath did not normalize the platform icon to a 21px maximum height"
    Assert-True ($previewPlatformHtml.Contains('alt="Platform: Windows"') -and $previewPlatformHtml.Contains('role="presentation"')) "$relativePath platform heading is not accessible or email-table-safe"
    $emailPlatformHtml = Get-NewsletterPlatformHeadingHtml -Platform $selectedPlatform -ImageMode Email
    Assert-True ($emailPlatformHtml.Contains('src="cid:platform_windows"')) "$relativePath did not render the selected embedded email CID"
    $encodedPlatform = [PSCustomObject]@{
        FileName = 'platform-android.png'
        Cid = 'platform_android'
        Label = '<Android & unsafe>'
    }
    $encodedHeading = Get-NewsletterPlatformHeadingHtml -Platform $encodedPlatform -ImageMode Email
    Assert-True ($encodedHeading.Contains('Platform: &lt;Android &amp; unsafe&gt;') -and -not $encodedHeading.Contains('alt="Platform: <')) "$relativePath did not HTML-encode the accessible platform label"
    $missingHeading = Get-NewsletterPlatformHeadingHtml -Platform ([PSCustomObject]@{
        FileName = 'platform-missing.png'
        Cid = 'platform_missing'
        Label = 'Missing'
    }) -ImageMode Email
    Assert-True ($missingHeading.Contains('YOUR WEEK ON PLEX') -and -not $missingHeading.Contains('<img') -and -not $missingHeading.Contains('padding-left')) "$relativePath left a gap when a recognized platform asset was unavailable"

    # Plex's published metadata contract treats Rating[] as optional. Model a
    # server that returns only the selected IMDb fields by default, but returns
    # the full RT pair when the optional Rating element is explicitly requested.
    $script:DesignPlexMetadataCache = @{}
    $script:optionalRatingRequests = 0
    $script:optionalRatingXmlRequests = 0
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }
    function Get-DesignPlexContext {
        return [PSCustomObject]@{
            Available = $true
            ServerUrl = 'https://127.0.0.1:32400'
            Token = 'virtual-token'
        }
    }
    function Invoke-RestMethod {
        param([string]$Uri, [hashtable]$Headers, [string]$Method, [int]$TimeoutSec)
        $script:optionalRatingRequests++
        Assert-True ($Method -eq 'Get' -and $TimeoutSec -eq 60) "$relativePath changed the direct metadata request contract"
        Assert-True ([string]$Headers['X-Plex-Token'] -eq 'virtual-token') "$relativePath omitted the Plex token from direct metadata"
        Assert-True ([string]$Headers['X-Plex-Pms-Api-Version'] -eq '1.2.2') "$relativePath omitted the published Plex API version"

        $metadata = [ordered]@{ ratingImage = 'imdb://image.rating' }
        if ($Uri -notmatch '[?&]excludeFields=rating(?:&|$)') {
            $metadata.rating = '6.6'
        }
        if ($Uri -match '\?includeOptionalElements=Rating&excludeFields=rating$') {
            $metadata.Rating = @(
                [PSCustomObject]@{ image = 'rottentomatoes://image.rating.ripe'; type = 'critic'; value = '8.7' },
                [PSCustomObject]@{ image = 'rottentomatoes://image.rating.upright'; type = 'audience'; value = '8.3' }
            )
        }

        return [PSCustomObject]@{
            MediaContainer = [PSCustomObject]@{
                Metadata = @([PSCustomObject]$metadata)
            }
        }
    }
    function Invoke-DesignPlexLegacyXml {
        param([string]$Path)
        $script:optionalRatingXmlRequests++
        throw "$relativePath unexpectedly used XML after JSON returned the optional Rating array"
    }
    $optionalRatingMetadata = Get-DesignPlexMetadata -RatingKey 'virtual-movie'
    $cachedOptionalRatingMetadata = Get-DesignPlexMetadata -RatingKey 'virtual-movie'
    Assert-True ($script:optionalRatingRequests -eq 1) "$relativePath did not cache the optional direct Plex rating response"
    Assert-True ($script:optionalRatingXmlRequests -eq 0) "$relativePath used XML even though JSON supplied the optional Rating array"
    Assert-True ($cachedOptionalRatingMetadata -eq $optionalRatingMetadata) "$relativePath changed the cached optional direct Plex rating response"
    Assert-True (
        $null -ne $optionalRatingMetadata.PSObject.Properties['Rating'] -and
        @($optionalRatingMetadata.Rating).Count -eq 2
    ) "$relativePath did not request Plex's optional Rating element without the colliding scalar rating field"

    # PMS response customization is explicitly best-effort: a server may
    # ignore excludeFields or omit optional children from JSON while exposing
    # the same native Rating elements in XML. Model the reporter's observable
    # split so movie RT does not depend on a JSON-only response shape.
    $script:DesignPlexMetadataCache = @{}
    $script:jsonSparseRatingRequests = 0
    $script:xmlRatingFallbackRequests = 0
    function Invoke-RestMethod {
        param([string]$Uri, [hashtable]$Headers, [string]$Method, [int]$TimeoutSec)
        $script:jsonSparseRatingRequests++
        return [PSCustomObject]@{
            MediaContainer = [PSCustomObject]@{
                Metadata = @([PSCustomObject]@{
                    ratingKey = 'virtual-json-sparse-movie'
                    type = 'movie'
                    ratingImage = 'imdb://image.rating'
                    Rating = @([PSCustomObject]@{
                        image = 'imdb://image.rating'
                        type = 'audience'
                        value = '7.0'
                    })
                    Genre = @([PSCustomObject]@{ tag = 'Drama' })
                })
            }
        }
    }
    function Invoke-DesignPlexLegacyXml {
        param([string]$Path)
        $script:xmlRatingFallbackRequests++
        Assert-True ($Path -eq '/library/metadata/virtual-json-sparse-movie?includeOptionalElements=Rating') "$relativePath changed the native XML rating fallback request"
        return [xml]'<MediaContainer><Video ratingKey="virtual-json-sparse-movie" rating="6.6" ratingImage="imdb://image.rating"><Rating image="rottentomatoes://image.rating.ripe" type="critic" value="8.7" /><Rating image="rottentomatoes://image.rating.upright" type="audience" value="8.3" /></Video></MediaContainer>'
    }
    $xmlFallbackMetadata = Get-DesignPlexMetadata -RatingKey 'virtual-json-sparse-movie'
    $cachedXmlFallbackMetadata = Get-DesignPlexMetadata -RatingKey 'virtual-json-sparse-movie'
    Assert-True ($script:jsonSparseRatingRequests -eq 1) "$relativePath did not cache the JSON-sparse metadata response"
    Assert-True ($script:xmlRatingFallbackRequests -eq 1) "$relativePath did not cache the native XML rating fallback"
    Assert-True ($cachedXmlFallbackMetadata -eq $xmlFallbackMetadata) "$relativePath changed the cached XML-enriched metadata response"
    Assert-True (
        $null -ne $xmlFallbackMetadata.PSObject.Properties['Rating'] -and
        @($xmlFallbackMetadata.Rating).Count -eq 3
    ) "$relativePath did not merge native XML provider ratings when JSON retained only selected IMDb"

    function Get-DesignPlexMetadata { param([string]$RatingKey) return [PSCustomObject]@{} }
    function Invoke-DesignPlexLegacyXml {
        param([string]$Path)
        Assert-True ($Path -eq '/library/metadata/virtual-episode?includeOptionalElements=Rating') "$relativePath did not request optional Rating elements from the XML episode fallback"
        return [xml]'<MediaContainer><Video><Rating image="imdb://image.rating" type="audience" value="8.6" /></Video></MediaContainer>'
    }
    $optionalEpisodeImdb = Get-DesignEpisodeImdbRating -RatingKey 'virtual-episode'
    Assert-True ($optionalEpisodeImdb -eq '8.6') "$relativePath did not recover exact-episode IMDb from the optional XML Rating element"

    $flatCritic = ''
    $flatAudience = ''
    $flatImdb = ''
    $flatProvider = ''
    $flatProviderValue = ''
    Find-DesignProviderRatingsRecursive `
        -Node ([PSCustomObject]@{
            rating = '5.3'
            ratingImage = 'rottentomatoes://image.rating.rotten'
            audienceRating = '4.0'
            audienceRatingImage = 'rottentomatoes://image.rating.spilled'
        }) `
        -Critic ([ref]$flatCritic) `
        -Audience ([ref]$flatAudience) `
        -Imdb ([ref]$flatImdb) `
        -Provider ([ref]$flatProvider) `
        -ProviderValue ([ref]$flatProviderValue)
    Assert-True ($flatCritic -eq '53' -and $flatAudience -eq '40' -and [string]::IsNullOrWhiteSpace($flatImdb) -and [string]::IsNullOrWhiteSpace($flatProvider)) "$relativePath did not parse Tautulli's flattened low-score RT export"

    $flatShowCritic = ''
    $flatShowAudience = ''
    $flatShowImdb = ''
    $flatShowProvider = ''
    $flatShowProviderValue = ''
    Find-DesignProviderRatingsRecursive `
        -Node ([PSCustomObject]@{
            rating = ''
            audienceRating = '7.4'
            audienceRatingImage = 'themoviedb://image.rating'
        }) `
        -Critic ([ref]$flatShowCritic) `
        -Audience ([ref]$flatShowAudience) `
        -Imdb ([ref]$flatShowImdb) `
        -Provider ([ref]$flatShowProvider) `
        -ProviderValue ([ref]$flatShowProviderValue)
    Assert-True ($flatShowProvider -eq 'TMDB' -and $flatShowProviderValue -eq '7.4' -and [string]::IsNullOrWhiteSpace($flatShowImdb) -and [string]::IsNullOrWhiteSpace($flatShowCritic) -and [string]::IsNullOrWhiteSpace($flatShowAudience)) "$relativePath did not parse Tautulli's official TV selected-provider export shape"

    $nestedCritic = ''
    $nestedAudience = ''
    $nestedImdb = ''
    $nestedProvider = ''
    $nestedProviderValue = ''
    Find-DesignProviderRatingsRecursive `
        -Node ([PSCustomObject]@{
            Rating = @(
                [PSCustomObject]@{
                    image = 'rottentomatoes://image.rating.rotten'
                    type = 'critic'
                    value = '5.3'
                },
                [PSCustomObject]@{
                    image = 'rottentomatoes://image.rating.spilled'
                    type = 'audience'
                    value = '4.0'
                },
                [PSCustomObject]@{
                    image = 'imdb://image.rating'
                    type = 'critic'
                    value = '7.4'
                }
            )
        }) `
        -Critic ([ref]$nestedCritic) `
        -Audience ([ref]$nestedAudience) `
        -Imdb ([ref]$nestedImdb) `
        -Provider ([ref]$nestedProvider) `
        -ProviderValue ([ref]$nestedProviderValue)
    Assert-True ($nestedCritic -eq '53' -and $nestedAudience -eq '40' -and $nestedImdb -eq '7.4' -and [string]::IsNullOrWhiteSpace($nestedProvider)) "$relativePath did not parse nested provider-labelled entries"

    $unlabelledCritic = ''
    $unlabelledAudience = ''
    $unlabelledImdb = ''
    $unlabelledProvider = ''
    $unlabelledProviderValue = ''
    Find-DesignProviderRatingsRecursive `
        -Node ([PSCustomObject]@{ rating = '9.9'; audienceRating = '9.8' }) `
        -Critic ([ref]$unlabelledCritic) `
        -Audience ([ref]$unlabelledAudience) `
        -Imdb ([ref]$unlabelledImdb) `
        -Provider ([ref]$unlabelledProvider) `
        -ProviderValue ([ref]$unlabelledProviderValue)
    Assert-True (
        [string]::IsNullOrWhiteSpace($unlabelledCritic) -and
        [string]::IsNullOrWhiteSpace($unlabelledAudience) -and
        [string]::IsNullOrWhiteSpace($unlabelledImdb) -and
        [string]::IsNullOrWhiteSpace($unlabelledProvider) -and
        [string]::IsNullOrWhiteSpace($unlabelledProviderValue)
    ) "$relativePath mislabeled provider-free numeric ratings"

    $tvdb = Get-DesignProviderRating -RatingImage 'thetvdb://image.rating' -RatingValue '8.2'
    Assert-True ($tvdb.Provider -eq 'TVDB' -and $tvdb.Value -eq '8.2') "$relativePath did not recognize a provider-labelled TVDB rating"
    $unknown = Get-DesignProviderRating -RatingImage 'unknown://image.rating' -RatingValue '9.9'
    Assert-True ([string]::IsNullOrWhiteSpace($unknown.Provider)) "$relativePath accepted an unknown rating provider"
    $invalid = Get-DesignProviderRating -RatingImage 'themoviedb://image.rating' -RatingValue '12.4'
    Assert-True ([string]::IsNullOrWhiteSpace($invalid.Provider)) "$relativePath accepted an out-of-range provider rating"

    # Provider-only collection tests isolate the legacy best-effort path. The
    # persistent cache has its own exact-ID, privacy, and lifecycle suite.
    function Get-TautWeeklyDeletedItemCacheEntry {
        param([string]$MediaType, [string]$MetadataGuid, [switch]$LogHit)
        return $null
    }
    function Register-TautWeeklyDeletedItemCacheCaptureSkip {
        param([ValidateSet('metadata','poster')][string]$Reason)
    }
    function Update-TautWeeklyDeletedItemCache {
        param([object]$Item, [string]$PosterPath)
        return $false
    }

    $posterProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-poster-probe-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force -Path $posterProbeRoot | Out-Null
        $script:PosterDir = $posterProbeRoot
        $script:TautulliDefaultPosterHash = ''
        $script:posterProbeOutFile = ''
        $script:posterProbeRequestCount = 0
        $script:posterProbeWarnings = New-Object System.Collections.Generic.List[string]

        function Write-Log {
            param([string]$Message, [string]$Level = 'INFO')
            if ($Level -eq 'WARN') { $script:posterProbeWarnings.Add($Message) }
        }

        function Build-TautulliUri {
            param([string]$Command, [hashtable]$Parameters = @{})
            Assert-True ($Command -eq 'pms_image_proxy') "$relativePath used the wrong command for the generic-poster probe"
            Assert-True ([string]$Parameters.fallback -eq 'poster') "$relativePath did not request Tautulli's poster fallback"
            return 'https://tautulli.invalid/api/v2'
        }

        function Invoke-WebRequest {
            param(
                [string]$Uri,
                [string]$OutFile,
                [int]$TimeoutSec
            )

            $script:posterProbeOutFile = $OutFile
            $script:posterProbeRequestCount++
            [IO.File]::WriteAllBytes($OutFile, [Text.Encoding]::UTF8.GetBytes(('GENERIC-POSTER' * 64)))
        }

        $posterHash = Get-TautulliDefaultPosterHash
        $cachedPosterHash = Get-TautulliDefaultPosterHash
        $probeWarningText = $script:posterProbeWarnings -join '; '
        Assert-True (-not [string]::IsNullOrWhiteSpace($posterHash)) "$relativePath could not fingerprint Tautulli's generic poster on this platform: $probeWarningText"
        Assert-True ($cachedPosterHash -eq $posterHash -and $script:posterProbeRequestCount -eq 1) "$relativePath did not cache Tautulli's generic-poster fingerprint"
        Assert-True ($script:posterProbeWarnings.Count -eq 0) "$relativePath logged an unexpected generic-poster probe warning: $probeWarningText"
        Assert-True (-not ([IO.Path]::GetFileName($script:posterProbeOutFile)).StartsWith('.')) "$relativePath used a Unix-hidden generic-poster probe"
        Assert-True (-not (Test-Path -LiteralPath $script:posterProbeOutFile)) "$relativePath did not clean up the generic-poster probe"
    }
    finally {
        Remove-Item -LiteralPath $posterProbeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $script:PlexWatchRatingCache = @{}
    $script:plexWatchRequestCount = 0
    $env:TAUTWEEKLY_TEST_PLEX_WATCH_URL = 'http://127.0.0.1:32123/watch'
    function Invoke-WebRequest {
        param(
            [switch]$UseBasicParsing,
            [string]$Uri,
            [hashtable]$Headers,
            [int]$TimeoutSec
        )
        Assert-True ($Uri -eq 'http://127.0.0.1:32123/watch/movie/deleted-movie') "$relativePath did not use the exact validated Plex slug"
        Assert-True (-not $Headers.ContainsKey('X-Plex-Token')) "$relativePath forwarded a Plex token to the public rating page"
        Assert-True ([string]$Headers['Accept-Language'] -eq 'en-US,en;q=0.9') "$relativePath did not request stable English provider labels"
        $script:plexWatchRequestCount++
        return [PSCustomObject]@{
            Content = '<div data-testid="metadata-ratings"><span title="53% critic rating on Rotten Tomatoes">53%</span><span title="40% audience rating on Rotten Tomatoes">40%</span><span title="5.4 audience rating on IMDb">5.4</span></div>'
        }
    }
    try {
        $watchRatings = Get-PlexWatchRatings -Slug 'deleted-movie' -MediaType 'movie'
        $cachedWatchRatings = Get-PlexWatchRatings -Slug 'deleted-movie' -MediaType 'movie'
        Assert-True ($watchRatings.RtCritic -eq '53' -and $watchRatings.RtAudience -eq '40') "$relativePath did not parse provider-labelled RT ratings"
        Assert-True ($watchRatings.Imdb -eq '5.4') "$relativePath did not parse a provider-labelled IMDb rating"
        Assert-True ($cachedWatchRatings.RtCritic -eq '53' -and $script:plexWatchRequestCount -eq 1) "$relativePath did not cache public Plex ratings"
        $unsafeSlugRatings = Get-PlexWatchRatings -Slug '../private-title' -MediaType 'movie'
        Assert-True ([string]::IsNullOrWhiteSpace($unsafeSlugRatings.RtCritic) -and $script:plexWatchRequestCount -eq 1) "$relativePath accepted an unsafe public-rating slug"
    }
    finally {
        Remove-Item Env:TAUTWEEKLY_TEST_PLEX_WATCH_URL -ErrorAction SilentlyContinue
    }

    $script:Config = [PSCustomObject]@{
        WatchedPercent       = 85
        FooterServerName     = 'Test Plex'
        PlexWebUrl           = 'https://app.plex.tv/'
        PlexButtonLabel      = 'View & Request'
        ScheduleDay          = 'Friday'
        CustomTextCardEnabled = $true
        CustomTextCardBorderColor = '#72aef7'
        CustomTextCardBorderOpacity = 34
        CustomTextCardTitle = 'Custom <Title>'
        CustomTextCardTitleGif = 'celebrate'
        CustomTextCardSubheading = 'Maintenance & more'
        CustomTextCardBody = "First <line> & safe`r`nSecond line"
    }

    Assert-True ((Get-ConfiguredPlexButtonLabel) -eq 'View & Request') "$relativePath did not return the configured button label"
    $customCardHtml = Get-CustomTextCardTableHtml -ImageMode Preview
    Assert-True ($customCardHtml.Contains('class="email-card custom-text-card"')) "$relativePath did not render the enabled custom text card"
    Assert-True ($customCardHtml.Contains('CUSTOM &lt;TITLE&gt;') -and $customCardHtml.Contains('Maintenance &amp; more')) "$relativePath did not HTML-encode custom card headings"
    Assert-True ($customCardHtml.Contains('First &lt;line&gt; &amp; safe<br>Second line')) "$relativePath did not safely preserve custom card body line breaks"
    Assert-True ($customCardHtml.Contains('border-color:rgba(114,174,247,0.34)')) "$relativePath did not render the configured border color and opacity"
    Assert-True ($customCardHtml.Contains('<span>CUSTOM &lt;TITLE&gt;</span><img src="../assets/celebrate.gif"')) "$relativePath did not append the allowlisted preview GIF immediately after the uppercase title"
    Assert-True ($customCardHtml.Contains('width="18" height="18" style="display:inline-block;width:18px;height:18px;border:0;vertical-align:-4px;margin-left:6px;"')) "$relativePath changed the approved title GIF dimensions or alignment"
    $customCardEmailHtml = Get-CustomTextCardTableHtml -ImageMode Email
    Assert-True ($customCardEmailHtml.Contains('cid:custom_title_celebrate')) "$relativePath did not map the selected title GIF to its deterministic email CID"
    $script:Config.CustomTextCardTitleGif = '../celebrate.gif'
    Assert-True (-not (Get-CustomTextCardTableHtml -ImageMode Email).Contains('custom_title_')) "$relativePath accepted an unsafe title GIF identifier"
    $script:Config.CustomTextCardTitleGif = 'celebrate.gif'
    Assert-True (-not (Get-CustomTextCardTableHtml -ImageMode Preview).Contains('../assets/celebrate.gif')) "$relativePath accepted a filename in place of an allowlisted title GIF ID"
    $script:Config.CustomTextCardTitleGif = 'celebrate'
    $script:Config.CustomTextCardEnabled = $false
    Assert-True ([string]::IsNullOrWhiteSpace((Get-CustomTextCardTableHtml))) "$relativePath rendered the disabled custom text card"
    $script:Config.CustomTextCardEnabled = $true
    $configuredValues = $script:Config
    $script:Config = [PSCustomObject]@{ PlexWebUrl = 'javascript:alert(1)' }
    Assert-True ((Get-ConfiguredPlexWebUrl) -eq 'https://app.plex.tv/desktop/') "$relativePath accepted a non-HTTP custom button URL"
    $script:Config = [PSCustomObject]@{ PlexButtonLabel = "  View`r`nRequests  " }
    Assert-True ((Get-ConfiguredPlexButtonLabel) -eq 'ViewRequests') "$relativePath did not remove control characters from a legacy button label"
    $script:Config = [PSCustomObject]@{}
    Assert-True ((Get-ConfiguredPlexButtonLabel) -eq 'Open Plex') "$relativePath did not default a missing button label"
    $script:Config = $configuredValues

    $script:tautulliUserCalls = New-Object System.Collections.Generic.List[string]
    function Invoke-TautulliApi {
        param(
            [string]$Command,
            [hashtable]$Parameters = @{}
        )

        $script:tautulliUserCalls.Add($Command)
        if ($Command -eq 'get_user') {
            throw 'Simulated per-user lookup rejection'
        }
        if ($Command -eq 'get_users') {
            return @(
                [PSCustomObject]@{
                    user_id = '145330906'
                    username = 'viewer'
                    email = 'viewer@example.com'
                    is_active = 1
                    do_notify = 1
                }
            )
        }

        throw "Unexpected Tautulli command: $Command"
    }

    $fallbackUser = Get-TautulliUser -Id '145330906'
    Assert-True ([string]$fallbackUser.user_id -eq '145330906') "$relativePath did not recover the requested user from get_users"
    Assert-True (($script:tautulliUserCalls -join ',') -eq 'get_user,get_users') "$relativePath did not use the bulk-user fallback after get_user failed"

    # Tautulli can return its default Local record for an unavailable get_user ID.
    # Identity, not the requested query or a friendly name, must authorize a result.
    $realLocal = [PSCustomObject]@{ user_id = '42'; username = 'local-profile'; friendly_name = 'Local'; email = 'local-profile@example.com'; is_active = 1; deleted_user = 0; do_notify = 1 }
    $reservedLocal = [PSCustomObject]@{ user_id = 0; username = 'Local'; friendly_name = 'Local'; email = ''; is_active = 1; deleted_user = 0; do_notify = 1 }
    $script:bulkLookupUsers = @($reservedLocal, $realLocal)
    $script:directLookupUser = $reservedLocal
    function Invoke-TautulliApi {
        param([string]$Command, [hashtable]$Parameters = @{})
        $script:tautulliUserCalls.Add($Command)
        if ($Command -eq 'get_user') { return $script:directLookupUser }
        if ($Command -in @('get_users', 'get_user_names')) { return $script:bulkLookupUsers }
        throw "Unexpected identity-test command: $Command"
    }
    foreach ($mismatchedResponse in @(
        $reservedLocal,
        [PSCustomObject]@{ user_id = '0'; email = 'reserved@example.com' },
        [PSCustomObject]@{ user_id = '99'; email = 'wrong-user@example.com' },
        [PSCustomObject]@{ email = 'missing-id@example.com' }
    )) {
        $script:directLookupUser = $mismatchedResponse
        $script:tautulliUserCalls.Clear()
        $identityFallback = Get-TautulliUser -Id '42'
        Assert-True ([string]$identityFallback.user_id -eq '42' -and $identityFallback.email -eq 'local-profile@example.com') "$relativePath accepted mismatched direct lookup details"
        Assert-True (($script:tautulliUserCalls -join ',') -eq 'get_user,get_users') "$relativePath did not use the exact bulk match after a mismatched direct response"
    }
    $script:bulkLookupUsers = @($reservedLocal)
    $script:directLookupUser = $reservedLocal
    $unavailableThrew = $false
    try { Get-TautulliUser -Id '42' | Out-Null } catch { $unavailableThrew = $true }
    Assert-True $unavailableThrew "$relativePath substituted Local for an unavailable requested user"
    foreach ($localId in @(0, '0', '000')) {
        $script:tautulliUserCalls.Clear()
        $reservedThrew = $false
        try { Get-TautulliUser -Id $localId | Out-Null } catch { $reservedThrew = $true }
        Assert-True ($reservedThrew -and $script:tautulliUserCalls.Count -eq 0) "$relativePath looked up reserved user '$localId' instead of rejecting it locally"
        Assert-True (Test-TautulliLocalUserId -Id $localId) "$relativePath failed to recognize reserved zero '$localId'"
    }
    Assert-True (-not (Test-TautulliLocalUserId -Id '42')) "$relativePath classified a real positive user ID as reserved"
    $script:bulkLookupUsers = @($reservedLocal, [PSCustomObject]@{ user_id = '0'; friendly_name = 'Renamed reserved user' }, $realLocal)
    Assert-True ((@(Get-TautulliUsers).user_id -join ',') -eq '42') "$relativePath exposed reserved Local through the detailed user roster"
    Assert-True ((@(Get-TautulliUserNames).user_id -join ',') -eq '42') "$relativePath exposed reserved Local through the name roster"
    Assert-True ((Resolve-TautulliUserId -Identifier 'Local') -eq '42') "$relativePath excluded a real user whose friendly name is Local"
    $script:bulkLookupUsers = @([PSCustomObject]@{ user_id = '42'; username = '0'; friendly_name = '0'; email = 'real-zero-name@example.com' })
    foreach ($localIdentifier in @('0', '000')) {
        $script:tautulliUserCalls.Clear()
        $reservedIdentifierThrew = $false
        try { Resolve-TautulliUserId -Identifier $localIdentifier | Out-Null } catch { $reservedIdentifierThrew = $true }
        Assert-True ($reservedIdentifierThrew -and $script:tautulliUserCalls.Count -eq 0) "$relativePath interpreted reserved identifier '$localIdentifier' as another profile's name"
    }
    $script:bulkLookupUsers = @($reservedLocal, $realLocal)
    $script:directLookupUser = $realLocal
    $script:tautulliUserCalls.Clear()
    $directMatch = Get-TautulliUser -Id '42'
    Assert-True ([string]$directMatch.user_id -eq '42' -and ($script:tautulliUserCalls -join ',') -eq 'get_user') "$relativePath did not accept an exact direct lookup match"

    $recipientConfig = $script:Config
    $script:Config = [PSCustomObject]@{ UserEmailOverrides = [PSCustomObject]@{ '0' = 'legacy-local@example.com' }; ExcludedUserIds = @(); ExcludedEmails = @() }
    $localRecipient = [PSCustomObject]@{ UserId = '0'; IsActive = 1; DeletedUser = 0; Email = 'legacy-local@example.com'; DeliveryEmail = 'legacy-local@example.com' }
    Assert-True ((Get-UserSkipReason -User $localRecipient) -eq 'excludedUserId') "$relativePath allowed a legacy fallback or native email to make reserved Local eligible"
    Assert-True ([string]::IsNullOrWhiteSpace((Get-UserSkipReason -User (Get-NewsletterUser -Id '42')))) "$relativePath made a real Local-named profile ineligible"
    $state = [PSCustomObject]@{ Users = [PSCustomObject]@{} }
    Add-AccessStateUser -State $state -User $reservedLocal -IsBaseline $true
    Assert-True ($null -eq $state.Users.PSObject.Properties['0']) "$relativePath added reserved Local to a fresh access baseline"
    Add-AccessStateUser -State $state -User $realLocal -IsBaseline $false
    Assert-True (Test-UserNeedsWelcome -State $state -UserId '42') "$relativePath lost welcome eligibility for a real Local-named profile"
    $legacyEntry = [PSCustomObject]@{ UserId = '0'; IsBaseline = $false; FirstSeenUtc = [DateTime]::UtcNow.ToString('o'); WelcomeSentUtc = '' }
    $state.Users | Add-Member -NotePropertyName '0' -NotePropertyValue $legacyEntry
    Assert-True (-not (Test-UserNeedsWelcome -State $state -UserId '0')) "$relativePath welcomed a legacy Local access-state entry"
    function Save-AccessState { throw 'Reserved Local must not save welcome state.' }
    Mark-UserWelcomed -State $state -UserId '0'
    Assert-True ([string]::IsNullOrWhiteSpace($legacyEntry.WelcomeSentUtc)) "$relativePath marked reserved Local as welcomed"
    $script:Config = $recipientConfig

    $movie = [PSCustomObject]@{
        media_type      = 'movie'
        play_duration   = 7200
        watched_status  = 1
        percent_complete = 100
        rating_key      = 'movie-1'
        guid            = 'plex://movie/movie-guid-1'
        title           = 'Movie One'
        year            = '2026'
    }
    $episode = [PSCustomObject]@{
        media_type             = 'episode'
        play_duration          = 1800
        watched_status         = 1
        percent_complete       = 100
        rating_key             = 'episode-1'
        guid                   = 'plex://episode/episode-guid-1'
        grandparent_rating_key = 'show-1'
        grandparent_title      = 'Show One'
        parent_title           = 'Season 1'
        title                  = 'Pilot'
        parent_media_index     = 1
        media_index            = 1
        rating_image           = 'imdb://image.rating'
        rating                 = '8.5'
    }

    $oneMovie = Get-UserStats -History @($movie)
    Assert-True ($oneMovie.MovieItems -is [object[]]) "$relativePath collapsed one movie into a scalar"
    Assert-True ($oneMovie.MovieItems.Count -eq 1) "$relativePath lost the one-movie item"
    Assert-True ($oneMovie.MovieItems[0].MetadataGuid -eq 'plex://movie/movie-guid-1') "$relativePath lost the retained movie metadata GUID"
    Assert-True ($oneMovie.EpisodeItems.Count -eq 0) "$relativePath created an unexpected episode"
    Assert-True ($oneMovie.TvShowItems.Count -eq 0) "$relativePath created an unexpected TV show"

    $oneEpisode = Get-UserStats -History @($episode)
    Assert-True ($oneEpisode.EpisodeItems -is [object[]]) "$relativePath collapsed one episode into a scalar"
    Assert-True ($oneEpisode.EpisodeItems.Count -eq 1) "$relativePath lost the one-episode item"
    Assert-True ($oneEpisode.MovieItems.Count -eq 0) "$relativePath created an unexpected movie"
    Assert-True ($oneEpisode.TvShowItems.Count -eq 1) "$relativePath did not group the episode into one TV show"
    Assert-True ($oneEpisode.TvShowItems[0].EpisodeCount -eq 1) "$relativePath returned the wrong unique episode count"
    Assert-True ($oneEpisode.TvShowItems[0].MetadataGuid -eq 'plex://episode/episode-guid-1') "$relativePath lost the representative episode GUID for TV artwork"
    Assert-True ($oneEpisode.TvShowItems[0].MetadataParentIndex -eq 1 -and $oneEpisode.TvShowItems[0].MetadataIndex -eq 1) "$relativePath detached the representative episode indexes from its GUID"
    Assert-True ($oneEpisode.TvShowItems[0].ShowTitle -eq 'Show One') "$relativePath lost the grouped TV show title"
    Assert-True ($oneEpisode.EpisodeItems[0].ImdbRating -eq '8.5') "$relativePath lost an available episode IMDb rating"
    Assert-True ([string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $oneEpisode.TvShowItems[0] -Name 'Rating')) -and [string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $oneEpisode.TvShowItems[0] -Name 'RatingImage')) -and [string]::IsNullOrWhiteSpace((Get-OptionalStringProperty -InputObject $oneEpisode.TvShowItems[0] -Name 'DesignImdbRating'))) "$relativePath promoted an episode IMDb rating into unverified show-level metadata"

    $partialEpisodeStats = Get-UserStats -History @([PSCustomObject]@{
        media_type = 'episode'; play_duration = 120; watched_status = 0; percent_complete = 10
        rating_key = 'partial-episode'; grandparent_rating_key = 'partial-show'
        grandparent_title = 'Partial Show'; title = 'Barely Started'
    })
    Assert-True ($partialEpisodeStats.TotalSeconds -eq 120) "$relativePath removed partial playback from total watch time"
    Assert-True ($partialEpisodeStats.EpisodeItems.Count -eq 0 -and $partialEpisodeStats.TvShowItems.Count -eq 0) "$relativePath treated a 120-second partial episode as watched"


    $sparseMovieRows = @(
        [PSCustomObject]@{
            media_type = 'movie'; play_duration = 600; watched_status = 1; percent_complete = 100
            rating_key = 'sparse-movie'; guid = 'plex://movie/sparse-movie'; title = 'Sparse Movie'
            year = ''; summary = ''; genres = @(); rating = ''; rating_image = 'rottentomatoes://image.rating.ripe'
            audience_rating = '7.7'; audience_rating_image = ''; group_count = 1
        },
        [PSCustomObject]@{
            media_type = 'movie'; play_duration = 500; watched_status = 1; percent_complete = 100
            rating_key = 'sparse-movie'; guid = ''; title = 'Sparse Movie'
            year = ''; summary = ''; genres = @(); rating = '7.6'; rating_image = ''
            audience_rating = ''; audience_rating_image = 'rottentomatoes://image.rating.upright'; group_count = 1
        },
        [PSCustomObject]@{
            media_type = 'movie'; play_duration = 400; watched_status = 1; percent_complete = 100
            rating_key = 'sparse-movie'; guid = ''; title = 'Sparse Movie'
            year = '2026'; summary = 'Rich movie history metadata.'; genres = @('Drama', 'Mystery')
            rating = '8.1'; rating_image = 'rottentomatoes://image.rating.ripe'
            audience_rating = '9.2'; audience_rating_image = 'rottentomatoes://image.rating.upright'; group_count = 1
        }
    )
    $sparseMovieStats = Get-UserStats -History $sparseMovieRows
    $sparseMovieItem = @($sparseMovieStats.MovieItems)[0]
    Assert-True ($sparseMovieStats.MovieItems.Count -eq 1) "$relativePath did not group sparse-to-rich rows for one watched movie"
    Assert-True ($sparseMovieItem.Summary -eq 'Rich movie history metadata.' -and $sparseMovieItem.Year -eq '2026' -and ($sparseMovieItem.DesignGenres -join ',') -eq 'Drama,Mystery') "$relativePath did not backfill rich movie fields from a later authentic row"
    Assert-True ($sparseMovieItem.Rating -eq '8.1' -and $sparseMovieItem.RatingImage -eq 'rottentomatoes://image.rating.ripe' -and $sparseMovieItem.AudienceRating -eq '9.2' -and $sparseMovieItem.AudienceRatingImage -eq 'rottentomatoes://image.rating.upright') "$relativePath did not backfill complete movie rating pairs atomically"
    Assert-True ($sparseMovieItem.Rating -ne '7.6' -and $sparseMovieItem.AudienceRating -ne '7.7') "$relativePath combined incompatible movie rating halves across history rows"

    $sparseTvRows = @(
        [PSCustomObject]@{
            media_type = 'episode'; play_duration = 1800; watched_status = 1; percent_complete = 100
            rating_key = 'sparse-episode-1'; guid = 'plex://episode/sparse-episode-1'
            grandparent_rating_key = 'sparse-show'; grandparent_title = 'Sparse Show'
            parent_title = 'Season 1'; title = 'Sparse Premiere'; parent_media_index = 1; media_index = 1
            added_at = 200; rating = '8.7'; rating_image = 'imdb://image.rating'
            grandparent_year = ''; grandparent_summary = ''; grandparent_genres = @()
            grandparent_rating = ''; grandparent_rating_image = 'imdb://image.rating'
            grandparent_audience_rating = '7.3'; grandparent_audience_rating_image = ''
        },
        [PSCustomObject]@{
            media_type = 'episode'; play_duration = 3600; watched_status = 1; percent_complete = 100
            rating_key = 'sparse-episode-2'; guid = 'plex://episode/sparse-episode-2'
            grandparent_rating_key = 'sparse-show'; grandparent_title = 'Sparse Show'
            parent_title = 'Season 1'; title = 'Rich Follow-up'; parent_media_index = 1; media_index = 2
            added_at = 100; rating = '6.2'; rating_image = 'rottentomatoes://image.rating.ripe'
            grandparent_year = '2026'; grandparent_summary = 'Rich show-level history metadata.'
            grandparent_genres = @('Science Fiction', 'Drama')
            grandparent_rating = '8.4'; grandparent_rating_image = 'imdb://image.rating'
            grandparent_audience_rating = ''; grandparent_audience_rating_image = 'rottentomatoes://image.rating.upright'
        }
    )
    $sparseTvStats = Get-UserStats -History $sparseTvRows
    $sparseShowItem = @($sparseTvStats.TvShowItems)[0]
    Assert-True ($sparseTvStats.TvShowItems.Count -eq 1 -and $sparseTvStats.EpisodeItems.Count -eq 2) "$relativePath lost sparse-to-rich TV history rows"
    Assert-True ($sparseShowItem.Summary -eq 'Rich show-level history metadata.' -and $sparseShowItem.Year -eq '2026' -and ($sparseShowItem.DesignGenres -join ',') -eq 'Science Fiction,Drama') "$relativePath did not backfill authentic grandparent show fields"
    Assert-True ($sparseShowItem.EpisodeCount -eq 2) "$relativePath did not count two distinct qualified episodes"
    Assert-True ($sparseShowItem.Rating -eq '8.4' -and $sparseShowItem.RatingImage -eq 'imdb://image.rating' -and [string]::IsNullOrWhiteSpace([string]$sparseShowItem.AudienceRating)) "$relativePath mixed episode fields or incomplete audience halves into show metadata"
    Assert-True (@($sparseTvStats.EpisodeItems | Where-Object { $_.RatingKey -eq 'sparse-episode-1' })[0].ImdbRating -eq '8.7') "$relativePath lost the exact episode IMDb value"

    $sparseTvRelease = New-ReleaseData -RecentItems $sparseTvRows
    $sparseReleaseShow = @($sparseTvRelease.TV)[0]
    Assert-True ($sparseReleaseShow.Summary -eq 'Rich show-level history metadata.' -and $sparseReleaseShow.Year -eq '2026' -and ($sparseReleaseShow.DesignGenres -join ',') -eq 'Science Fiction,Drama') "$relativePath did not preserve sparse-to-rich show fields in release projection"
    Assert-True ($sparseReleaseShow.Rating -eq '8.4' -and $sparseReleaseShow.RatingImage -eq 'imdb://image.rating') "$relativePath promoted an episode provider or lost the complete show IMDb pair"
    Assert-True (@($sparseReleaseShow.Episodes | Where-Object { $_.RatingKey -eq 'sparse-episode-1' })[0].ImdbRating -eq '8.7') "$relativePath lost exact episode IMDb during release projection"

    $globalSparseTotals = @(Get-GlobalTitleTotals -GlobalHistory $sparseMovieRows)
    Assert-True ($globalSparseTotals.Count -eq 1) "$relativePath did not group global sparse movie history"
    Assert-True ($globalSparseTotals[0].Year -eq '2026') "$relativePath coupled sparse global year backfill to an unrelated metadata GUID"
    Assert-True ($globalSparseTotals[0].Rating -eq '8.1' -and $globalSparseTotals[0].RatingImage -eq 'rottentomatoes://image.rating.ripe' -and $globalSparseTotals[0].AudienceRating -eq '9.2' -and $globalSparseTotals[0].AudienceRatingImage -eq 'rottentomatoes://image.rating.upright') "$relativePath manufactured a global rating pair from different sparse rows"

    function Invoke-TautulliApi {
        param([string]$Command, [hashtable]$Parameters = @{})
        Assert-True ($Command -eq 'get_metadata' -and [string]$Parameters.rating_key -eq 'sparse-movie') "$relativePath used an unexpected global hero metadata lookup"
        return [PSCustomObject]@{
            title = 'Sparse Movie'; year = ''; summary = ''; genres = @()
            rating = ''; rating_image = 'imdb://image.rating'
            audience_rating = '7.7'; audience_rating_image = ''
        }
    }
    $partialReleaseMovie = [PSCustomObject]@{
        Type = 'movie'; ReleaseKey = 'movie:sparse-movie'; RatingKey = 'sparse-movie'; PosterRatingKey = 'sparse-movie'
        MetadataGuid = 'plex://movie/sparse-movie'; Title = 'Sparse Movie'; Year = '2026'
        Summary = 'Release summary.'; DesignGenres = @('Drama', 'Mystery')
        Rating = '7.6'; RatingImage = ''; AudienceRating = ''; AudienceRatingImage = 'rottentomatoes://image.rating.upright'
        AddedAt = 200; EpisodeCount = 0; SeasonCount = 0; IsNewSeries = $false; Episodes = @()
    }
    $atomicGlobalHero = Get-GlobalTrendingHero -GlobalHistory $sparseMovieRows -ReleaseData ([PSCustomObject]@{ Movies = @($partialReleaseMovie); TV = @() })
    Assert-True ($atomicGlobalHero.Item.Rating -eq '8.1' -and $atomicGlobalHero.Item.RatingImage -eq 'rottentomatoes://image.rating.ripe' -and $atomicGlobalHero.Item.AudienceRating -eq '9.2' -and $atomicGlobalHero.Item.AudienceRatingImage -eq 'rottentomatoes://image.rating.upright') "$relativePath did not preserve complete history pairs through sparse metadata and partial release correlation"
    Assert-True ($atomicGlobalHero.Item.Summary -eq 'Release summary.' -and ($atomicGlobalHero.Item.DesignGenres -join ',') -eq 'Drama,Mystery') "$relativePath discarded richer correlated release metadata from the global hero"
    Assert-True ((Get-PlexHostedMetadataLookupPath -MetadataGuid 'plex://movie/5d123abc?lang=en' -MediaType 'movie') -eq '/library/metadata/5d123abc') "$relativePath did not normalize a retained Plex GUID"
    Assert-True ((Get-PlexHostedMetadataLookupPath -MetadataGuid 'com.plexapp.agents.themoviedb://12345?lang=en' -MediaType 'movie') -eq '/library/metadata/matches?guid=tmdb%3A%2F%2F12345&type=1') "$relativePath did not normalize a legacy TMDB movie GUID"
    Assert-True ((Get-PlexHostedMetadataLookupPath -MetadataGuid 'com.plexapp.agents.tmdb://54321?lang=en' -MediaType 'movie') -eq '/library/metadata/matches?guid=tmdb%3A%2F%2F54321&type=1') "$relativePath did not normalize the alternate legacy TMDB movie agent"
    Assert-True ((Get-PlexHostedMetadataLookupPath -MetadataGuid 'com.plexapp.agents.themoviedb://24680/1/2?lang=en' -MediaType 'show') -eq '/library/metadata/matches?guid=tmdb%3A%2F%2F24680&type=2') "$relativePath did not reduce a legacy TMDB episode GUID to its exact show identifier"
    Assert-True ((Get-PlexHostedMetadataLookupPath -MetadataGuid 'com.plexapp.agents.thetvdb://999/1/2?lang=en' -MediaType 'show') -eq '/library/metadata/matches?guid=tvdb%3A%2F%2F999&type=2') "$relativePath did not reduce a legacy TVDB episode GUID to its exact show identifier"
    Assert-True ([string]::IsNullOrWhiteSpace((Get-PlexHostedMetadataLookupPath -MetadataGuid 'tmdb://private-title' -MediaType 'movie'))) "$relativePath accepted a non-numeric external metadata identifier"
    Assert-True ([string]::IsNullOrWhiteSpace((Get-PlexHostedMetadataLookupPath -MetadataGuid 'local://private-library-item' -MediaType 'movie'))) "$relativePath sent a private local-library GUID to hosted metadata"

    $modernMoviePayload = Get-PlexHostedMetadataMatchPayload -MetadataGuid 'plex://movie/5d123abc?lang=en' -MediaType 'movie' -LookupPath '/library/metadata/5d123abc' -MatchTitle 'Sanitized Movie' -MatchYear '2024'
    $modernEpisodePayload = Get-PlexHostedMetadataMatchPayload -MetadataGuid 'plex://episode/5d456def?lang=en' -MediaType 'show' -LookupPath '/library/metadata/5d456def' -MatchTitle 'Sanitized Show' -ParentIndex 2 -Index 3
    $legacyMoviePayload = Get-PlexHostedMetadataMatchPayload -MetadataGuid 'com.plexapp.agents.tmdb://12345?lang=en' -MediaType 'movie' -LookupPath '/library/metadata/matches?guid=tmdb%3A%2F%2F12345&type=1' -MatchTitle 'Sanitized Movie' -MatchYear '2024'
    Assert-True ([string]$modernMoviePayload.guid -eq 'plex://movie/5d123abc' -and [int]$modernMoviePayload.type -eq 1 -and [string]$modernMoviePayload.title -eq 'Sanitized Movie' -and [int]$modernMoviePayload.year -eq 2024) "$relativePath did not build a provider-valid modern movie payload"
    Assert-True ([string]$modernEpisodePayload.guid -eq 'plex://episode/5d456def' -and [int]$modernEpisodePayload.type -eq 4 -and [string]$modernEpisodePayload.grandparentTitle -eq 'Sanitized Show' -and [int]$modernEpisodePayload.parentIndex -eq 2 -and [int]$modernEpisodePayload.index -eq 3) "$relativePath did not preserve the required episode match context"
    Assert-True ([string]$legacyMoviePayload.guid -eq 'tmdb://12345' -and [int]$legacyMoviePayload.type -eq 1 -and [string]$legacyMoviePayload.title -eq 'Sanitized Movie') "$relativePath did not build a provider-valid legacy movie payload"
    Assert-True ($null -eq (Get-PlexHostedMetadataMatchPayload -MetadataGuid 'plex://episode/5d456def' -MediaType 'show' -LookupPath '/library/metadata/5d456def' -MatchTitle 'Sanitized Show')) "$relativePath sent an incomplete episode match payload"
    Assert-True (Test-PlexHostedMetadataExactMatch -Metadata ([PSCustomObject]@{ guid = 'plex://movie/5d123abc' }) -MatchPayload $modernMoviePayload) "$relativePath rejected an exact canonical Plex GUID"
    Assert-True (Test-PlexHostedMetadataExactMatch -Metadata ([PSCustomObject]@{ Guid = @([PSCustomObject]@{ id = 'tmdb://12345' }) }) -MatchPayload $legacyMoviePayload) "$relativePath rejected an exact external provider GUID"
    Assert-True (Test-PlexHostedMetadataExactMatch -Metadata ([PSCustomObject]@{ type = 'movie'; title = 'Sanitized Movie' }) -MatchPayload $legacyMoviePayload) "$relativePath rejected a compatible exact external lookup response without Guid[]"
    Assert-True (-not (Test-PlexHostedMetadataExactMatch -Metadata ([PSCustomObject]@{ Guid = @([PSCustomObject]@{ id = 'tmdb://99999' }); type = 'movie'; title = 'Sanitized Movie' }) -MatchPayload $legacyMoviePayload)) "$relativePath accepted a mismatched returned external GUID"
    Assert-True (-not (Test-PlexHostedMetadataExactMatch -Metadata ([PSCustomObject]@{ guid = 'plex://movie/different' }) -MatchPayload $modernMoviePayload)) "$relativePath accepted a title-hinted response with the wrong canonical GUID"

    $script:PlexHostedMetadataCache = @{}
    $script:hostedMetadataRequestCount = 0
    $script:hostedMetadataWarnings = New-Object System.Collections.Generic.List[string]
    $script:hostedMetadataMessages = New-Object System.Collections.Generic.List[string]
    $env:TAUTWEEKLY_TEST_PLEX_METADATA_PROVIDER_URL = 'http://127.0.0.1:32123/hosted'
    function Write-Log {
        param([string]$Message, [string]$Level = 'INFO')
        $script:hostedMetadataMessages.Add($Message)
        if ($Level -eq 'WARN') { $script:hostedMetadataWarnings.Add($Message) }
    }
    function Get-DesignPlexContext {
        return [PSCustomObject]@{ Token = 'virtual-plex-token' }
    }
    function Invoke-RestMethod {
        param(
            [string]$Uri,
            [hashtable]$Headers,
            [string]$Method,
            [string]$Body,
            [string]$ContentType,
            [int]$TimeoutSec
        )
        Assert-True ([string]$Headers['X-Plex-Token'] -eq 'virtual-plex-token') "$relativePath omitted the administrator Plex token from hosted metadata"
        $script:hostedMetadataRequestCount++

        if ($Uri -eq 'http://127.0.0.1:32123/hosted/library/metadata/noexactmatch') {
            Assert-True ($Method -eq 'Get') "$relativePath changed the direct retained Plex GUID request method"
            Assert-True ([string]::IsNullOrWhiteSpace($Body)) "$relativePath sent a request body with a direct retained Plex GUID"
            return [PSCustomObject]@{ MediaContainer = [PSCustomObject]@{ Metadata = @() } }
        }

        if ($Uri -eq 'http://127.0.0.1:32123/hosted/library/metadata/matches?guid=tmdb%3A%2F%2F12345&type=1') {
            Assert-True ($Method -eq 'Get') "$relativePath did not preserve the compatible query-form exact match"
            return [PSCustomObject]@{ MediaContainer = [PSCustomObject]@{ Metadata = @() } }
        }

        Assert-True ($Uri -eq 'http://127.0.0.1:32123/hosted/library/metadata/matches') "$relativePath changed the provider-contract exact-match endpoint"
        Assert-True ($Method -eq 'Post') "$relativePath did not retry an empty query match with the provider POST contract"
        Assert-True ($ContentType -eq 'application/json') "$relativePath omitted the exact-match JSON content type"
        $payload = $Body | ConvertFrom-Json
        if ([string]$payload.guid -eq 'plex://movie/noexactmatch') {
            Assert-True ([int]$payload.type -eq 1) "$relativePath changed the retained modern movie type in the POST body"
            Assert-True ([string]$payload.title -eq 'Missing Movie') "$relativePath omitted the required retained movie title hint"
            return [PSCustomObject]@{ MediaContainer = [PSCustomObject]@{ Metadata = @() } }
        }
        Assert-True ([string]$payload.guid -eq 'tmdb://12345') "$relativePath changed the retained external identifier in the POST body"
        Assert-True ([int]$payload.type -eq 1) "$relativePath changed the retained legacy movie type in the POST body"
        Assert-True ([string]$payload.title -eq 'Sanitized Movie') "$relativePath omitted the required retained legacy movie title hint"
        return [PSCustomObject]@{
            MediaContainer = [PSCustomObject]@{
                Metadata = @([PSCustomObject]@{
                    type = 'movie'
                    title = 'Sanitized exact-ID match'
                    Guid = @([PSCustomObject]@{ id = 'tmdb://12345' })
                })
            }
        }
    }
    try {
        $emptyHostedMetadata = Get-PlexHostedMetadata -MetadataGuid 'plex://movie/noexactmatch' -MediaType 'movie' -MatchTitle 'Missing Movie'
        $cachedEmptyHostedMetadata = Get-PlexHostedMetadata -MetadataGuid 'plex://movie/noexactmatch' -MediaType 'movie' -MatchTitle 'Missing Movie'
        Assert-True ($null -eq $emptyHostedMetadata -and $null -eq $cachedEmptyHostedMetadata) "$relativePath accepted an empty hosted metadata response"
        Assert-True ($script:hostedMetadataRequestCount -eq 2) "$relativePath did not retry and cache an empty exact-match response"
        Assert-True (@($script:hostedMetadataMessages | Where-Object { $_ -like '*found no exact match*' }).Count -eq 1) "$relativePath did not report an empty exact-match response exactly once"
        Assert-True (@($script:hostedMetadataWarnings | Where-Object { $_ -like '*no exact match*' }).Count -eq 0) "$relativePath presented a best-effort hosted metadata miss as a warning"

        $legacyHostedMetadata = Get-PlexHostedMetadata -MetadataGuid 'com.plexapp.agents.tmdb://12345?lang=en' -MediaType 'movie' -MatchTitle 'Sanitized Movie'
        $cachedLegacyHostedMetadata = Get-PlexHostedMetadata -MetadataGuid 'com.plexapp.agents.tmdb://12345?lang=en' -MediaType 'movie' -MatchTitle 'Sanitized Movie'
        Assert-True ($null -ne $legacyHostedMetadata -and $legacyHostedMetadata.title -eq 'Sanitized exact-ID match') "$relativePath did not recover an empty query match through the provider POST contract"
        Assert-True ($cachedLegacyHostedMetadata -eq $legacyHostedMetadata) "$relativePath did not cache the provider POST match"
        Assert-True ($script:hostedMetadataRequestCount -eq 4) "$relativePath did not perform exactly one GET compatibility attempt and one POST contract retry"
        Assert-True (@($script:hostedMetadataMessages | Where-Object { $_ -like '*found no exact match*' }).Count -eq 1) "$relativePath reported a hosted miss after a successful provider POST retry"

        $unsupportedHostedMetadata = Get-PlexHostedMetadata -MetadataGuid 'local://private-library-item' -MediaType 'movie'
        $cachedUnsupportedHostedMetadata = Get-PlexHostedMetadata -MetadataGuid 'local://private-library-item' -MediaType 'movie'
        Assert-True ($null -eq $unsupportedHostedMetadata -and $null -eq $cachedUnsupportedHostedMetadata) "$relativePath accepted an unsupported private-library GUID"
        Assert-True ($script:hostedMetadataRequestCount -eq 4) "$relativePath sent an unsupported private-library GUID to hosted metadata"
        Assert-True (@($script:hostedMetadataWarnings | Where-Object { $_ -like '*provider format is unsupported*' }).Count -eq 1) "$relativePath did not report an unsupported retained GUID exactly once"
        Assert-True (-not (($script:hostedMetadataWarnings -join '; ').Contains('private-library-item'))) "$relativePath leaked a retained private-library identifier into diagnostics"
    }
    finally {
        Remove-Item Env:TAUTWEEKLY_TEST_PLEX_METADATA_PROVIDER_URL -ErrorAction SilentlyContinue
    }

    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }
    $script:providerDirectCalls = 0
    $script:providerExportCalls = 0
    function Invoke-TautulliApi {
        param([string]$Command, [hashtable]$Parameters = @{})
        Assert-True ($Command -eq 'get_metadata') "$relativePath used an unexpected Tautulli request for selected-provider metadata"
        if ([string]$Parameters.rating_key -eq 'preferred-provider-movie') {
            return [PSCustomObject]@{
                rating = '8.1'
                rating_image = 'imdb://image.rating'
                audience_rating = ''
                audience_rating_image = ''
            }
        }
        if ([string]$Parameters.rating_key -eq 'fallback-provider-movie') {
            return [PSCustomObject]@{
                rating = '6.6'
                rating_image = 'imdb://image.rating'
                audience_rating = ''
                audience_rating_image = ''
            }
        }
        if ([string]$Parameters.rating_key -eq 'rt-provider-show') {
            return [PSCustomObject]@{
                rating = '5.7'
                rating_image = 'rottentomatoes://image.rating.rotten'
                audience_rating = '7.8'
                audience_rating_image = 'rottentomatoes://image.rating.upright'
            }
        }
        Assert-True ([string]$Parameters.rating_key -eq 'selected-provider-show') "$relativePath requested an unexpected selected-provider rating key"
        return [PSCustomObject]@{
            rating = ''
            rating_image = ''
            audience_rating = '7.4'
            audience_rating_image = 'themoviedb://image.rating'
        }
    }
    function Get-DesignPlexMetadata {
        param([string]$RatingKey)
        $script:providerDirectCalls++
        if ($RatingKey -eq 'preferred-provider-movie') {
            return [PSCustomObject]@{
                Rating = @(
                    [PSCustomObject]@{ image = 'rottentomatoes://image.rating.rotten'; type = 'critic'; value = '5.3' },
                    [PSCustomObject]@{ image = 'rottentomatoes://image.rating.spilled'; type = 'audience'; value = '4.0' }
                )
            }
        }
        if ($RatingKey -eq 'selected-provider-show') {
            return [PSCustomObject]@{
                Rating = @(
                    [PSCustomObject]@{ image = 'imdb://image.rating'; type = 'audience'; value = '8.4' },
                    [PSCustomObject]@{ image = 'rottentomatoes://image.rating.ripe'; type = 'critic'; value = '7.1' },
                    [PSCustomObject]@{ image = 'rottentomatoes://image.rating.upright'; type = 'audience'; value = '8.2' }
                )
            }
        }
        return $null
    }
    function Get-DesignRichExport {
        param([string]$RatingKey, [string]$MediaType, [switch]$NeedLogo)
        $script:providerExportCalls++
        return [PSCustomObject]@{ RtCritic = ''; RtAudience = ''; Imdb = ''; Provider = ''; ProviderValue = '' }
    }
    $selectedProviderShow = [PSCustomObject]@{
        RatingKey = 'selected-provider-show'
        Type = 'show'
        Title = 'Selected Provider Show'
    }
    $selectedProviderMovie = [PSCustomObject]@{
        RatingKey = 'preferred-provider-movie'
        Type = 'movie'
        Title = 'Preferred Provider Movie'
        Year = '2026'
    }
    $rtProviderShow = [PSCustomObject]@{
        RatingKey = 'rt-provider-show'
        Type = 'show'
        Title = 'RT Provider Show'
    }
    $fallbackProviderMovie = [PSCustomObject]@{
        RatingKey = 'fallback-provider-movie'
        Type = 'movie'
        Title = 'Fallback Provider Movie'
        Year = '2026'
    }
    Add-DesignRatingMetadata -ReleaseData ([PSCustomObject]@{ Movies = @($selectedProviderMovie, $fallbackProviderMovie); TV = @($selectedProviderShow, $rtProviderShow) })
    Assert-True ($selectedProviderShow.DesignRatingProvider -eq 'TMDB' -and $selectedProviderShow.DesignRatingValue -eq '7.4') "$relativePath ignored Tautulli's selected TV audience-rating provider"
    Assert-True ($selectedProviderShow.DesignImdbRating -eq '8.4') "$relativePath let a selected TMDB score prevent an available show IMDb fallback"
    Assert-True ($selectedProviderShow.DesignRtCritic -eq '71' -and $selectedProviderShow.DesignRtAudience -eq '82') "$relativePath did not retain show-level RT values behind the preferred IMDb score"
    Assert-True ($rtProviderShow.DesignRtCritic -eq '57' -and $rtProviderShow.DesignRtAudience -eq '78' -and [string]::IsNullOrWhiteSpace($rtProviderShow.DesignImdbRating)) "$relativePath did not retain a show-level RT fallback when IMDb was absent"
    Assert-True ($selectedProviderMovie.DesignRtCritic -eq '53' -and $selectedProviderMovie.DesignRtAudience -eq '40') "$relativePath let a selected movie IMDb score prevent available Rotten Tomatoes ratings"
    Assert-True ($fallbackProviderMovie.DesignImdbRating -eq '6.6') "$relativePath did not retain labelled IMDb as the final movie fallback"
    Assert-True ($script:providerDirectCalls -eq 4 -and $script:providerExportCalls -eq 2) "$relativePath did not exhaust preferred rating sources before accepting selected-provider fallbacks"

    $preferredMovieLine = Get-DesignRatingLine -Item $selectedProviderMovie -ImageMode Preview
    Assert-True ($preferredMovieLine.Contains('53%') -and $preferredMovieLine.Contains('40%') -and -not $preferredMovieLine.Contains('8.1')) "$relativePath did not render RT exclusively when a movie also retained an IMDb fallback"
    $preferredMovieStats = Get-StatsMovieRatingHtml -Item $selectedProviderMovie -ImageMode Preview
    Assert-True ($preferredMovieStats.Contains('53%') -and $preferredMovieStats.Contains('40%') -and -not $preferredMovieStats.Contains('8.1')) "$relativePath personal stats did not prefer RT over a movie IMDb fallback"
    $unratedMovieStats = Get-StatsMovieRatingHtml -Item ([PSCustomObject]@{}) -ImageMode Preview
    Assert-True ([string]::IsNullOrWhiteSpace($unratedMovieStats)) "$relativePath personal stats did not omit an unavailable movie rating"

    function Get-ImageSource {
        param([string]$RatingKey, [object[]]$PosterAssets, [string]$ImageMode)
        return ''
    }
    $unratedMovieRows = Get-StatsMovieRowsHtml -Items @([PSCustomObject]@{
        Title = 'Unrated Movie'; PosterRatingKey = ''; Genres = @()
    }) -PosterAssets @() -ImageMode Preview
    Assert-True ($unratedMovieRows.Contains('Unrated Movie') -and -not $unratedMovieRows.Contains('unavailable')) "$relativePath personal movie stats rendered an unavailable-rating placeholder"

    $unratedTvRows = Get-StatsTvShowRowsHtml -Items @([PSCustomObject]@{
        ShowTitle = 'Grouped Show'; PosterRatingKey = ''; EpisodeCount = 1; TotalTimeText = '1h 2m'; Seconds = 3720; DesignImdbRating = ''
    }) -PosterAssets @() -ImageMode Preview
    Assert-True ($unratedTvRows.Contains('Grouped Show') -and $unratedTvRows.Contains('1 episode') -and -not $unratedTvRows.Contains('1h 2m watched') -and -not $unratedTvRows.Contains('unavailable')) "$relativePath grouped TV stats did not replace duration with a singular episode count"

    $manyMovieRowsInput = @(1..12 | ForEach-Object {
        [PSCustomObject]@{
            Title = "Uncapped Movie $($_.ToString('00'))"; PosterRatingKey = ''; Genres = @('Drama'); DesignGenres = @('Drama'); Seconds = (5400 * $_)
            DesignRtCritic = if ($_ -eq 1) { '91' } else { '' }
            DesignRtCriticImage = 'rottentomatoes://image.rating.ripe'
        }
    })
    $manyMovieRows = Get-StatsMovieRowsHtml -Items $manyMovieRowsInput -PosterAssets @() -ImageMode Preview
    Assert-True (([regex]::Matches($manyMovieRows, 'Uncapped Movie \d{2}')).Count -eq 12) "$relativePath did not render every one of twelve personal movie rows"
    Assert-True ($manyMovieRows.Contains('Uncapped Movie 12') -and $manyMovieRows.Contains('91%')) "$relativePath lost the final movie row or an eligible movie rating"
    Assert-True (([regex]::Matches($manyMovieRows, 'class="stats-title-cell"')).Count -eq 12 -and -not $manyMovieRows.Contains('stats-title-spacer')) "$relativePath did not pair an even movie count into two desktop columns"

    $manyTvRowsInput = @(1..11 | ForEach-Object {
        [PSCustomObject]@{
            ShowTitle = "Uncapped Show $($_.ToString('00'))"; PosterRatingKey = ''; Seconds = (3600 * $_); EpisodeCount = $_
            TotalTimeText = "${_}h 0m"; DesignImdbRating = if ($_ -eq 1) { '8.4' } else { '' }
        }
    })
    $manyTvRows = Get-StatsTvShowRowsHtml -Items $manyTvRowsInput -PosterAssets @() -ImageMode Preview
    Assert-True (([regex]::Matches($manyTvRows, 'Uncapped Show \d{2}')).Count -eq 11) "$relativePath did not render every one of eleven personal TV rows"
    Assert-True ($manyTvRows.Contains('Uncapped Show 11') -and $manyTvRows.Contains('11 episodes') -and $manyTvRows.Contains('IMDb') -and $manyTvRows.Contains('8.4')) "$relativePath lost the final TV row, episode count, or eligible show rating"
    Assert-True (([regex]::Matches($manyTvRows, 'class="stats-title-cell stats-tv-title-cell stats-tv-title-(?:left|right)"')).Count -eq 11 -and ([regex]::Matches($manyTvRows, 'class="stats-title-spacer stats-tv-title-spacer"')).Count -eq 1) "$relativePath did not pair an odd TV count into two desktop/mobile columns with one safe spacer"

    # Recap text uses the approved 12px sizes without changing each role's weight/leading.
    Assert-True ($manyMovieRows.Contains('font-size:12px;line-height:1.3;color:#9b9b9b;font-weight:500;')) "$relativePath changed movie genre typography"
    Assert-True ($manyMovieRows.Contains('font-size:12px;line-height:1.35;color:#e5a00d;font-weight:700;')) "$relativePath changed movie rating typography"
    Assert-True ($manyTvRows.Contains('font-size:12px;line-height:1.35;color:#e5a00d;font-weight:700;">' + '<span style="display:inline-block;white-space:nowrap;"><img')) "$relativePath did not apply 12px to the TV IMDb number"
    Assert-True ($manyTvRows.Contains('font-size:12px;line-height:1.35;color:#9b9b9b;font-weight:600;')) "$relativePath changed TV episode-count typography"
    Assert-True (-not ($manyMovieRows + $manyTvRows).Contains('recipient-watched')) "$relativePath marked a footer recap"
    Assert-True (($preferredMovieStats -split 'width="16" height="16"').Count -eq 3) "$relativePath did not size both footer Rotten Tomatoes icons at 16px"

    $preferredShowStats = Get-StatsTvShowRatingHtml -Item $selectedProviderShow -ImageMode Preview
    Assert-True ($preferredShowStats.Contains('IMDb') -and $preferredShowStats.Contains('8.4') -and -not $preferredShowStats.Contains('%')) "$relativePath grouped TV stats did not prefer show-level IMDb over show-level RT"
    $rtShowStats = Get-StatsTvShowRatingHtml -Item $rtProviderShow -ImageMode Preview
    Assert-True ($rtShowStats.Contains('Rotten Tomatoes critic') -and $rtShowStats.Contains('57%')) "$relativePath grouped TV stats did not fall back to the show-level RT critic score"
    $audienceOnlyShowStats = Get-StatsTvShowRatingHtml -Item ([PSCustomObject]@{
        DesignImdbRating = ''; DesignRtCritic = ''; DesignRtAudience = '42'; DesignRtAudienceImage = 'rottentomatoes://image.rating.spilled'
    }) -ImageMode Preview
    Assert-True ($audienceOnlyShowStats.Contains('Rotten Tomatoes audience') -and $audienceOnlyShowStats.Contains('42%')) "$relativePath grouped TV stats did not fall back to the show-level RT audience score"

    $unratedEpisodeRows = Get-StatsEpisodeRowsHtml -Items @([PSCustomObject]@{
        ShowTitle = 'Legacy Show'; EpisodeTitle = 'Pilot'; PosterRatingKey = ''; Season = 1; Episode = 1; ImdbRating = ''
    }) -PosterAssets @() -ImageMode Preview -ImdbIconSrc '../assets/imdb.png'
    Assert-True ($unratedEpisodeRows.Contains('S01 EP01: Pilot') -and -not $unratedEpisodeRows.Contains('unavailable')) "$relativePath legacy episode stats rendered an unavailable-rating placeholder"

    $fallbackMovieLine = Get-DesignRatingLine -Item $fallbackProviderMovie -ImageMode Preview
    Assert-True ($fallbackMovieLine.Contains('IMDb') -and $fallbackMovieLine.Contains('6.6')) "$relativePath did not render labelled IMDb when no movie RT rating exists"

    function Invoke-TautulliApi {
        param([string]$Command, [hashtable]$Parameters = @{})
        if ($Command -eq 'get_children_metadata' -and [string]$Parameters.rating_key -eq 'sparse-child-show') {
            return [PSCustomObject]@{
                children_type = 'episode'
                children_list = @([PSCustomObject]@{
                    media_type = 'episode'; rating_key = 'sparse-child-episode'
                    grandparent_rating_key = 'sparse-child-show'; grandparent_title = 'Sparse Child Show'
                    title = 'Sparse Snapshot Title'; added_at = 150
                    parent_media_index = 1; media_index = 1
                    rating = ''; rating_image = 'imdb://image.rating'
                    audience_rating = ''; audience_rating_image = ''
                })
            }
        }
        Assert-True ($Command -eq 'get_metadata') "$relativePath used an unexpected episode metadata command"
        if ([string]$Parameters.rating_key -eq 'sparse-child-episode') {
            return [PSCustomObject]@{
                media_index = 1; parent_media_index = 1
                rating = ''; rating_image = 'imdb://image.rating'
                audience_rating = ''; audience_rating_image = ''
            }
        }
        if ([string]$Parameters.rating_key -eq 'rt-fallback-episode') {
            return [PSCustomObject]@{
                media_index = 6
                parent_media_index = 1
                rating = '8.3'
                rating_image = 'rottentomatoes://image.rating.ripe'
                audience_rating = ''
                audience_rating_image = ''
            }
        }
        if ([string]$Parameters.rating_key -eq 'rt-audience-fallback-episode') {
            return [PSCustomObject]@{
                media_index = 7
                parent_media_index = 1
                rating = ''
                rating_image = ''
                audience_rating = '4.5'
                audience_rating_image = 'rottentomatoes://image.rating.spilled'
            }
        }
        Assert-True ([string]$Parameters.rating_key -eq 'selected-provider-episode') "$relativePath requested unexpected episode metadata"
        return [PSCustomObject]@{
            media_index = 2
            parent_media_index = 1
            rating = ''
            rating_image = ''
            audience_rating = '7.4'
            audience_rating_image = 'themoviedb://image.rating'
        }
    }
    function Get-DesignPlexMetadata {
        param([string]$RatingKey)
        if ($RatingKey -eq 'rt-fallback-episode') {
            return [PSCustomObject]@{
                Rating = @(
                    [PSCustomObject]@{ image = 'rottentomatoes://image.rating.ripe'; type = 'critic'; value = '8.3' }
                )
            }
        }
        if ($RatingKey -eq 'rt-audience-fallback-episode') {
            return [PSCustomObject]@{
                Rating = @(
                    [PSCustomObject]@{ image = 'rottentomatoes://image.rating.spilled'; type = 'audience'; value = '4.5' }
                )
            }
        }
        Assert-True ($RatingKey -eq 'selected-provider-episode') "$relativePath requested ratings for the wrong episode"
        return [PSCustomObject]@{
            Rating = @(
                [PSCustomObject]@{ image = 'themoviedb://image.rating'; type = 'audience'; value = '7.4' },
                [PSCustomObject]@{ image = 'imdb://image.rating'; type = 'audience'; value = '8.6' },
                [PSCustomObject]@{ image = 'rottentomatoes://image.rating.ripe'; type = 'critic'; value = '8.3' }
            )
        }
    }
    function Invoke-DesignPlexLegacyXml {
        param([string]$Path)
        if ($Path -eq '/library/metadata/rt-fallback-episode?includeOptionalElements=Rating') {
            return [xml]'<MediaContainer><Video ratingKey="rt-fallback-episode" type="episode"><Rating image="rottentomatoes://image.rating.ripe" type="critic" value="8.3" /></Video></MediaContainer>'
        }
        Assert-True ($Path -eq '/library/metadata/rt-audience-fallback-episode?includeOptionalElements=Rating') "$relativePath used legacy XML for the wrong episode"
        return [xml]'<MediaContainer><Video ratingKey="rt-audience-fallback-episode" type="episode"><Rating image="rottentomatoes://image.rating.spilled" type="audience" value="4.5" /></Video></MediaContainer>'
    }
    $selectedProviderEpisode = [PSCustomObject]@{
        RatingKey = 'selected-provider-episode'
        Title = 'Sanitized Episode'
        Season = 1
        Episode = 2
        ImdbRating = ''
        RatingImage = ''
    }
    $episodeShow = [PSCustomObject]@{
        Title = 'Sanitized Show'
        Episodes = @($selectedProviderEpisode)
    }
    Enrich-TvEpisodeMetadata -ReleaseData ([PSCustomObject]@{ TV = @($episodeShow) })
    Assert-True ($selectedProviderEpisode.ImdbRating -eq '8.6') "$relativePath let a selected TMDB score prevent exact-episode IMDb recovery"
    $episodeHtml = Get-TvEpisodeLinesHtml -Item $episodeShow -ImageMode Preview
    Assert-True ($episodeHtml.Contains('font-size:12px;font-weight:700;white-space:nowrap;')) "$relativePath main TV episode IMDb number is not 12px"
    Assert-True ($episodeHtml.Contains('IMDb') -and $episodeHtml.Contains('8.6') -and -not $episodeHtml.Contains('Rotten Tomatoes') -and -not $episodeHtml.Contains('83%') -and -not $episodeHtml.Contains('TMDB') -and -not $episodeHtml.Contains('7.4')) "$relativePath did not keep exact-episode IMDb ahead of RT and generic providers"

    $sparseSeededEpisode = [PSCustomObject]@{
        RatingKey = 'sparse-child-episode'; Title = 'Exact Seeded Episode'
        AddedAt = 150; Season = 1; Episode = 1
        ImdbRating = '8.7'; RatingImage = 'imdb://image.rating'
        DesignRatingProvider = 'IMDb'; DesignRatingValue = '8.7'
    }
    $sparseChildShow = [PSCustomObject]@{
        RatingKey = 'sparse-child-show'; Title = 'Sparse Child Show'
        AddedAt = 150; EpisodeCount = 1; IsNewSeries = $false
        Episodes = @($sparseSeededEpisode)
    }
    Enrich-TvEpisodeMetadata `
        -ReleaseData ([PSCustomObject]@{ TV = @($sparseChildShow) }) `
        -ContextLabel 'Sparse child success' `
        -StartEpoch 100 `
        -EndEpochExclusive 200 `
        -CountRecentEpisodes $true
    $mergedSparseEpisode = @($sparseChildShow.Episodes | Where-Object { $_.RatingKey -eq 'sparse-child-episode' })[0]
    Assert-True ($sparseChildShow.Episodes.Count -eq 1 -and $sparseChildShow.EpisodeCount -eq 1) "$relativePath duplicated or lost the sparse child snapshot episode"
    Assert-True ($mergedSparseEpisode.Title -eq 'Sparse Snapshot Title' -and $mergedSparseEpisode.ImdbRating -eq '8.7' -and $mergedSparseEpisode.DesignRatingProvider -eq 'IMDb' -and $mergedSparseEpisode.DesignRatingValue -eq '8.7') "$relativePath let sparse child/get_metadata responses erase the exact episode IMDb pair"

    $rtFallbackEpisode = [PSCustomObject]@{
        RatingKey = 'rt-fallback-episode'
        Title = 'Sanitized RT Episode'
        Season = 1
        Episode = 6
        ImdbRating = ''
        RatingImage = ''
    }
    $rtFallbackShow = [PSCustomObject]@{
        Title = 'Sanitized RT Show'
        Episodes = @($rtFallbackEpisode)
    }
    Enrich-TvEpisodeMetadata -ReleaseData ([PSCustomObject]@{ TV = @($rtFallbackShow) })
    Assert-True ([string]::IsNullOrWhiteSpace($rtFallbackEpisode.ImdbRating)) "$relativePath invented exact-episode IMDb when Plex exposed only RT"
    Assert-True ($rtFallbackEpisode.RtRating -eq '83' -and $rtFallbackEpisode.RtRatingKind -eq 'critic') "$relativePath did not retain the exact-episode RT fallback and provider state"
    $rtEpisodeHtml = Get-TvEpisodeLinesHtml -Item $rtFallbackShow -ImageMode Preview
    Assert-True ($rtEpisodeHtml.Contains('Rotten Tomatoes critic') -and $rtEpisodeHtml.Contains('83%') -and -not $rtEpisodeHtml.Contains('IMDb')) "$relativePath did not render RT only after exact-episode IMDb was unavailable"

    $rtAudienceEpisode = [PSCustomObject]@{
        RatingKey = 'rt-audience-fallback-episode'
        Title = 'Sanitized RT Audience Episode'
        Season = 1
        Episode = 7
        ImdbRating = ''
        RatingImage = ''
    }
    $rtAudienceShow = [PSCustomObject]@{
        Title = 'Sanitized RT Audience Show'
        Episodes = @($rtAudienceEpisode)
    }
    Enrich-TvEpisodeMetadata -ReleaseData ([PSCustomObject]@{ TV = @($rtAudienceShow) })
    Assert-True ($rtAudienceEpisode.RtRating -eq '45' -and $rtAudienceEpisode.RtRatingKind -eq 'audience') "$relativePath did not retain the exact-episode RT audience fallback"
    $rtAudienceHtml = Get-TvEpisodeLinesHtml -Item $rtAudienceShow -ImageMode Preview
    Assert-True ($rtAudienceHtml.Contains('Rotten Tomatoes audience') -and $rtAudienceHtml.Contains('45%') -and $rtAudienceHtml.Contains('rt_spilled.png') -and -not $rtAudienceHtml.Contains('IMDb')) "$relativePath did not render the score-dependent RT audience fallback"

    function Get-TautWeeklyDeletedItemCacheEntry {
        param([string]$MediaType, [string]$MetadataGuid, [switch]$LogHit)
        if ($MediaType -eq 'movie' -and $MetadataGuid -eq 'plex://movie/atomic-cache') {
            return [PSCustomObject]@{
                Summary = 'Cached summary.'; Year = '2026'; Genres = @('Drama', 'Mystery')
                Ratings = [PSCustomObject]@{
                    RtCritic = '81'; RtCriticImage = 'rottentomatoes://image.rating.ripe'
                    RtAudience = '92'; RtAudienceImage = 'rottentomatoes://image.rating.upright'
                    Imdb = ''; Provider = ''; ProviderValue = ''
                }
            }
        }
        return $null
    }
    function Invoke-TautulliApi {
        param([string]$Command, [hashtable]$Parameters = @{})
        throw 'Simulated sparse local metadata'
    }
    function Get-DesignPlexMetadata { param([string]$RatingKey) return $null }
    function Get-DesignRichExport {
        param([string]$RatingKey, [string]$MediaType, [switch]$NeedLogo)
        return [PSCustomObject]@{ RtCritic = ''; RtAudience = ''; Imdb = ''; Provider = ''; ProviderValue = '' }
    }
    function Get-PlexHostedMetadata {
        param([string]$MetadataGuid, [string]$MediaType, [string]$MatchTitle, [string]$MatchYear, [int]$ParentIndex, [int]$Index)
        return $null
    }
    $atomicCacheMovie = [PSCustomObject]@{
        RatingKey = 'atomic-cache'; MetadataGuid = 'plex://movie/atomic-cache'
        Type = 'movie'; Title = 'Atomic Cache Movie'; Summary = 'Source summary.'; Year = '2026'
        DesignGenres = @('Drama', 'Mystery')
        Rating = '7.6'; RatingImage = ''
        AudienceRating = ''; AudienceRatingImage = 'rottentomatoes://image.rating.upright'
    }
    Add-DesignRatingMetadata -ReleaseData ([PSCustomObject]@{ Movies = @($atomicCacheMovie); TV = @() })
    Assert-True ($atomicCacheMovie.DesignRtCritic -eq '81' -and $atomicCacheMovie.DesignRtCriticImage -eq 'rottentomatoes://image.rating.ripe') "$relativePath did not consume the cached critic value/image pair atomically"
    Assert-True ($atomicCacheMovie.DesignRtAudience -eq '92' -and $atomicCacheMovie.DesignRtAudienceImage -eq 'rottentomatoes://image.rating.upright') "$relativePath did not consume the cached audience value/image pair atomically"
    Assert-True ($atomicCacheMovie.DesignRtCritic -ne '76') "$relativePath combined a source rating value with a cached provider image"

    function Invoke-TautulliApi { param([string]$Command, [hashtable]$Parameters = @{}) throw 'Simulated deleted metadata' }
    function Get-DesignPlexMetadata { param([string]$RatingKey) return $null }
    function Get-DesignRichExport {
        param([string]$RatingKey, [string]$MediaType, [switch]$NeedLogo)
        return [PSCustomObject]@{ RtCritic = ''; RtAudience = ''; Imdb = ''; Provider = ''; ProviderValue = '' }
    }
    function Get-PlexHostedMetadata {
        param([string]$MetadataGuid, [string]$MediaType, [string]$MatchTitle, [string]$MatchYear, [int]$ParentIndex, [int]$Index)
        Assert-True ($MetadataGuid -eq 'plex://movie/deleted-movie-guid') "$relativePath changed the retained GUID during hosted enrichment"
        Assert-True ($MediaType -eq 'movie') "$relativePath used the wrong hosted metadata type"
        Assert-True ($MatchTitle -eq 'Deleted Movie') "$relativePath omitted the retained movie title match hint"
        return [PSCustomObject]@{
            type = 'movie'
            summary = 'Retained exact-GUID summary.'
            year = '2024'
            Genre = @([PSCustomObject]@{ tag = 'Mystery' }, [PSCustomObject]@{ tag = 'Drama' })
            rating = '8.7'
            ratingImage = 'rottentomatoes://image.rating.ripe'
            audienceRating = '9.3'
            audienceRatingImage = 'rottentomatoes://image.rating.upright'
        }
    }
    $deletedMovieItem = [PSCustomObject]@{
        RatingKey = 'deleted-movie'
        MetadataGuid = 'plex://movie/deleted-movie-guid'
        Type = 'movie'
        Title = 'Deleted Movie'
    }
    Add-DesignRatingMetadata -ReleaseData ([PSCustomObject]@{ Movies = @($deletedMovieItem); TV = @() })
    Assert-True ($deletedMovieItem.Summary -eq 'Retained exact-GUID summary.') "$relativePath did not restore a deleted movie summary"
    Assert-True ($deletedMovieItem.Year -eq '2024') "$relativePath did not restore a deleted movie year"
    Assert-True (($deletedMovieItem.DesignGenres -join ',') -eq 'Mystery,Drama') "$relativePath did not restore deleted movie genres"
    Assert-True ($deletedMovieItem.DesignRtCritic -eq '87') "$relativePath did not restore the deleted movie critic rating"
    Assert-True ($deletedMovieItem.DesignRtAudience -eq '93') "$relativePath did not restore the deleted movie audience rating"

    function Get-PlexHostedMetadata {
        param([string]$MetadataGuid, [string]$MediaType, [string]$MatchTitle, [string]$MatchYear, [int]$ParentIndex, [int]$Index)
        Assert-True ($MetadataGuid -eq 'plex://episode/deleted-episode-guid') "$relativePath changed the retained episode GUID during hosted enrichment"
        Assert-True ($MediaType -eq 'show') "$relativePath used the wrong hosted TV metadata type"
        Assert-True ($MatchTitle -eq 'Deleted Show' -and $ParentIndex -eq 1 -and $Index -eq 2) "$relativePath omitted the retained TV episode match hints"
        return [PSCustomObject]@{
            type = 'show'
            summary = 'Retained TV summary.'
            year = '2024'
            rating = '8.4'
            ratingImage = 'imdb://image.rating'
        }
    }
    $deletedShowItem = [PSCustomObject]@{
        RatingKey = 'deleted-show'
        MetadataGuid = 'plex://episode/deleted-episode-guid'
        Type = 'show'
        Title = 'Deleted Show'
        MetadataParentIndex = 1
        MetadataIndex = 2
    }
    Add-DesignRatingMetadata -ReleaseData ([PSCustomObject]@{ Movies = @(); TV = @($deletedShowItem) })
    Assert-True ($deletedShowItem.DesignImdbRating -eq '8.4') "$relativePath did not restore the deleted TV IMDb rating"
    Assert-True ([string]::IsNullOrWhiteSpace($deletedShowItem.DesignRtCritic)) "$relativePath mislabeled a TV IMDb rating as Rotten Tomatoes"
    Assert-True ([string]::IsNullOrWhiteSpace($deletedShowItem.DesignRtAudience)) "$relativePath invented a TV Rotten Tomatoes audience rating"

    $script:statsMetadataInput = $null
    function Add-DesignRatingMetadata {
        param([object]$ReleaseData)
        $script:statsMetadataInput = $ReleaseData
    }
    Add-UserStatsMediaMetadata -Stats ([PSCustomObject]@{
        MovieItems  = @($deletedMovieItem)
        TvShowItems = @($deletedShowItem)
    })
    Assert-True ($null -ne $script:statsMetadataInput) "$relativePath skipped personal-stat metadata enrichment"
    Assert-True (@($script:statsMetadataInput.Movies).Count -eq 1) "$relativePath lost watched movies during personal-stat enrichment"
    Assert-True (@($script:statsMetadataInput.TV).Count -eq 1) "$relativePath omitted watched TV shows from IMDb enrichment"

    $manyMetadataMovies = @(1..12 | ForEach-Object {
        [PSCustomObject]@{ Type = 'movie'; Title = "Metadata Movie $_"; RatingKey = "metadata-movie-$_" }
    })
    $manyMetadataShows = @(1..11 | ForEach-Object {
        [PSCustomObject]@{ Type = 'show'; Title = "Metadata Show $_"; RatingKey = "metadata-show-$_" }
    })
    Add-UserStatsMediaMetadata -Stats ([PSCustomObject]@{
        MovieItems  = $manyMetadataMovies
        TvShowItems = $manyMetadataShows
    })
    Assert-True (@($script:statsMetadataInput.Movies).Count -eq 12) "$relativePath capped movie metadata enrichment before the final personal-stat row"
    Assert-True (@($script:statsMetadataInput.TV).Count -eq 11) "$relativePath capped TV metadata enrichment before the final personal-stat row"

    $secondEpisode = [PSCustomObject]@{
        media_type             = 'episode'
        play_duration          = 3600
        watched_status         = 1
        percent_complete       = 100
        rating_key             = 'episode-2'
        grandparent_rating_key = 'show-1'
        grandparent_title      = 'Show One'
        parent_title           = 'Season 1'
        title                  = 'Second Episode'
        parent_media_index     = 1
        media_index            = 2
    }
    $sameShow = Get-UserStats -History @($episode, $secondEpisode)
    Assert-True ($sameShow.EpisodeItems.Count -eq 2) "$relativePath lost qualifying episode detail"
    Assert-True ($sameShow.TvShowItems.Count -eq 1) "$relativePath counted episodes as separate TV shows"
    Assert-True ($sameShow.TvShowItems[0].Seconds -eq 5400) "$relativePath did not aggregate watch time by TV show"

    $episodeWithoutRatingMetadata = [PSCustomObject]@{
        media_type             = 'episode'
        play_duration          = 1800
        watched_status         = 1
        percent_complete       = 100
        rating_key             = 'episode-without-rating'
        grandparent_rating_key = 'show-without-rating'
        grandparent_title      = 'Show Without Rating'
        parent_title           = 'Season 1'
        title                  = 'Unrated Episode'
        year                   = '2026'
        added_at               = 1785800000
        parent_media_index     = 1
        media_index            = 2
    }
    $missingRating = Get-UserStats -History @($episodeWithoutRatingMetadata)
    Assert-True ($missingRating.EpisodeItems.Count -eq 1) "$relativePath rejected an episode without rating metadata"
    Assert-True ([string]::IsNullOrWhiteSpace([string]$missingRating.EpisodeItems[0].ImdbRating)) "$relativePath invented an IMDb rating for missing metadata"

    $missingReleaseRating = New-ReleaseData -RecentItems @($episodeWithoutRatingMetadata)
    Assert-True ($missingReleaseRating.TV.Count -eq 1) "$relativePath rejected a TV release without rating metadata"
    Assert-True ($missingReleaseRating.TV[0].Episodes.Count -eq 1) "$relativePath lost an unrated TV release episode"
    Assert-True ([string]::IsNullOrWhiteSpace([string]$missingReleaseRating.TV[0].Episodes[0].ImdbRating)) "$relativePath invented a release IMDb rating for missing metadata"

    $empty = Get-UserStats -History @()
    Assert-True ($empty.MovieItems -is [object[]]) "$relativePath lost the empty movie array"
    Assert-True ($empty.EpisodeItems -is [object[]]) "$relativePath lost the empty episode array"
    Assert-True ($empty.TvShowItems -is [object[]]) "$relativePath lost the empty TV-show array"
    Assert-True ($empty.MovieItems.Count -eq 0) "$relativePath has unexpected empty-state movies"
    Assert-True ($empty.EpisodeItems.Count -eq 0) "$relativePath has unexpected empty-state episodes"
    Assert-True ($empty.TvShowItems.Count -eq 0) "$relativePath has unexpected empty-state TV shows"

    $script:activeReleaseData = [PSCustomObject]@{
        Movies = @([PSCustomObject]@{
            Type = 'movie'; RatingKey = 'sample-release'; PosterRatingKey = 'sample-release'
            Title = 'Sanitized Sample Release'; Year = '2026'; Summary = 'Fictional sample metadata.'
        })
        TV = @()
    }
    $samplePreview = Get-PopulatedPreviewStats -RealStats $empty
    Assert-True (-not $samplePreview.IsSample) "$relativePath labels authentic empty selected-user history as sample activity"
    Assert-True ((Safe-Int64 $samplePreview.Stats.TotalSeconds) -eq 0) "$relativePath fabricated watch time for an empty preview state"
    Assert-True ($samplePreview.Stats.MovieItems.Count -eq 0 -and $samplePreview.Stats.EpisodeItems.Count -eq 0 -and $samplePreview.Stats.TvShowItems.Count -eq 0) "$relativePath fabricated watched titles for an empty preview state"
    $samplePlainText = Build-PlainText `
        -User ([PSCustomObject]@{ FriendlyName = 'Viewer' }) `
        -Stats $samplePreview.Stats `
        -ReleaseData $script:activeReleaseData `
        -HotRelease $null `
        -TrendingTitle '' `
        -SystemWarmingUp $false `
        -RecentAccess $false `
        -StartLabel 'August 1' `
        -EndLabel 'August 7'
    Assert-True (-not $samplePlainText.Contains('Sample Movie') -and -not $samplePlainText.Contains('Sample Series')) "$relativePath rendered fictional preview activity as plain text"
    Assert-True ($samplePlainText.Contains('View & Request: https://app.plex.tv/')) "$relativePath did not render the custom button label and URL in plain text"
    Assert-True ($samplePlainText.Contains("CUSTOM <TITLE>`r`nMaintenance & more`r`nFirst <line> & safe`nSecond line")) "$relativePath did not render the plain-text custom card"
    $customPlainIndex = $samplePlainText.IndexOf('CUSTOM <TITLE>', [StringComparison]::Ordinal)
    $releasePlainIndex = if ($customPlainIndex -ge 0) { $samplePlainText.IndexOf('1 NEW MOVIE', $customPlainIndex + 1, [StringComparison]::Ordinal) } else { -1 }
    Assert-True ($customPlainIndex -ge 0 -and $releasePlainIndex -gt $customPlainIndex) "$relativePath placed the plain-text custom card after the release metadata (custom=$customPlainIndex release=$releasePlainIndex)"

    $uncappedPlainText = Build-PlainText `
        -User ([PSCustomObject]@{ FriendlyName = 'Viewer' }) `
        -Stats ([PSCustomObject]@{
            TotalSeconds = 9999; TotalTimeText = '2h 46m'
            MovieItems = $manyMovieRowsInput
            TvShowItems = $manyTvRowsInput
        }) `
        -ReleaseData $script:activeReleaseData `
        -HotRelease $null `
        -TrendingTitle '' `
        -SystemWarmingUp $false `
        -RecentAccess $false `
        -StartLabel 'August 1' `
        -EndLabel 'August 7'
    Assert-True ($uncappedPlainText.Contains('12 movies watched') -and $uncappedPlainText.Contains('Uncapped Movie 12')) "$relativePath capped the personal movie list in plain text"
    Assert-True ($uncappedPlainText.Contains('11 TV shows watched') -and $uncappedPlainText.Contains(('Uncapped Show 11 {0} 11 episodes' -f [char]0x2014))) "$relativePath capped the personal TV list or lost its episode count in plain text"
    Assert-True ($uncappedPlainText.Contains(('Uncapped Show 01 {0} 1 episode' -f [char]0x2014))) "$relativePath lost singular episode copy in plain text"
    Assert-True (-not $uncappedPlainText.Contains('11h 0m')) "$relativePath retained per-show TV duration in plain text"
    Assert-True ($uncappedPlainText.Contains('2h 46m total watch time') -and -not $uncappedPlainText.Contains('total watched')) "$relativePath retained the old personal-time label in plain text"

    $threeMovies = Get-UserStats -History @(
        $movie,
        [PSCustomObject]@{
            media_type = 'movie'; play_duration = 5400; watched_status = 1
            percent_complete = 100; rating_key = 'movie-2'; title = 'Movie Two'; year = '2026'
        },
        [PSCustomObject]@{
            media_type = 'movie'; play_duration = 3600; watched_status = 1
            percent_complete = 100; rating_key = 'movie-3'; title = 'Movie Three'; year = '2026'
        }
    )
    Assert-True ($threeMovies.MovieItems.Count -eq 3) "$relativePath failed the three-movie adaptive branch"

    $heroMovie = [PSCustomObject]@{
        ReleaseKey = 'movie:hero-movie'; RatingKey = 'hero-movie'
        Title = 'Movie Hero'; Type = 'movie'; AddedAt = 100
    }
    $tvRelease = [PSCustomObject]@{
        ReleaseKey = 'show:tv-release'; RatingKey = 'tv-release'
        Title = 'TV Release'; Type = 'show'; AddedAt = 200
    }
    $releaseFixture = [PSCustomObject]@{ Movies = @($heroMovie); TV = @($tvRelease) }
    $movieOnlyHero = Get-HotNewRelease -ReleaseData $releaseFixture -GlobalHistory @(
        [PSCustomObject]@{ media_type = 'episode'; grandparent_rating_key = 'tv-release'; play_duration = 7200; watched_status = 1; percent_complete = 100 },
        [PSCustomObject]@{ media_type = 'movie'; rating_key = 'hero-movie'; play_duration = 600; watched_status = 1; percent_complete = 100; group_count = 4; user_id = '1'; started = 100 }
    )
    Assert-True ($movieOnlyHero.Item.Type -eq 'movie') "$relativePath allowed a TV release to become HOT NEW RELEASE"
    Assert-True (-not $movieOnlyHero.IsTrending) "$relativePath mislabeled a movie release hero as Trending"
    Assert-True ($movieOnlyHero.Plays -eq 1) "$relativePath multiplied a grouped HOT movie reference into extra plays"

    $partialHotFallback = Get-HotNewRelease -ReleaseData $releaseFixture -GlobalHistory @(
        [PSCustomObject]@{ media_type = 'movie'; rating_key = 'hero-movie'; play_duration = 120; watched_status = 0; percent_complete = 10; group_count = 99 }
    )
    Assert-True (-not $partialHotFallback.IsPopular -and $partialHotFallback.Plays -eq 0) "$relativePath treated partial new-release playback as qualifying activity"

    $trendingStat = Get-GlobalTrendingStat -GlobalHistory @(
        [PSCustomObject]@{ media_type = 'movie'; rating_key = 'viewer-winner'; title = 'Viewer Winner'; play_duration = 600; watched_status = 1; percent_complete = 100; group_count = 20; user_id = '1'; started = 100 },
        [PSCustomObject]@{ media_type = 'movie'; rating_key = 'viewer-winner'; title = 'Viewer Winner'; play_duration = 600; watched_status = 1; percent_complete = 100; group_count = 30; user_id = '2'; started = 200 },
        [PSCustomObject]@{ media_type = 'movie'; rating_key = 'time-runner'; title = 'Time Runner'; play_duration = 3600; watched_status = 1; percent_complete = 100; group_count = 40; user_id = '1'; started = 300 },
        [PSCustomObject]@{ media_type = 'movie'; rating_key = 'time-runner'; title = 'Time Runner'; play_duration = 3600; watched_status = 1; percent_complete = 100; group_count = 50; user_id = '1'; started = 400 },
        [PSCustomObject]@{ media_type = 'movie'; rating_key = 'partial'; title = 'Partial'; play_duration = 9999; watched_status = 0; percent_complete = 10; group_count = 500; user_id = '3'; started = 500 }
    )
    Assert-True ($trendingStat.RatingKey -eq 'viewer-winner') "$relativePath did not use unique viewers after the play-count tie"
    Assert-True ($trendingStat.Plays -eq 2 -and $trendingStat.ViewerKeys.Count -eq 2) "$relativePath returned the wrong Trending play/viewer totals"

    $tvOnlyHero = Get-HotNewRelease -ReleaseData ([PSCustomObject]@{
        Movies = @(); TV = @($tvRelease)
    }) -GlobalHistory @()
    Assert-True ($null -eq $tvOnlyHero) "$relativePath promoted a TV-only release as HOT NEW RELEASE"

    $quietMovies = @(1..6 | ForEach-Object {
        [PSCustomObject]@{
            ReleaseKey = "movie:quiet-$($_)"; RatingKey = "quiet-movie-$($_)"; PosterRatingKey = "quiet-movie-$($_)"
            Title = "Quiet Movie $($_)"; Type = "movie"; AddedAt = (1000 - $_)
        }
    })
    $quietTv = @(1..5 | ForEach-Object {
        [PSCustomObject]@{
            ReleaseKey = "show:quiet-$($_)"; RatingKey = "quiet-show-$($_)"; PosterRatingKey = "quiet-show-$($_)"
            Title = "Quiet Show $($_)"; Type = "show"; AddedAt = (900 - $_)
        }
    })
    $quietReleaseFixture = [PSCustomObject]@{ Movies = $quietMovies; TV = $quietTv }
    $quietHero = [PSCustomObject]@{ Item = $quietMovies[0]; IsTrending = $true; Plays = 4 }
    $script:Config | Add-Member -NotePropertyName MaxMovies -NotePropertyValue 2 -Force
    $script:Config | Add-Member -NotePropertyName MaxTv -NotePropertyValue 1 -Force
    $limitedQuietDisplay = Get-NewsletterReleaseDisplayData `
        -ReleaseData $quietReleaseFixture `
        -HotRelease $quietHero `
        -QuietReleaseMode $true
    Assert-True (($limitedQuietDisplay.Movies.ReleaseKey -join ",") -eq "movie:quiet-2,movie:quiet-3") "$relativePath did not exclude the quiet hero before applying MaxMovies=2"
    Assert-True ($limitedQuietDisplay.TV.Count -eq 1 -and $limitedQuietDisplay.TV[0].ReleaseKey -eq "show:quiet-1") "$relativePath did not honor MaxTv=1 in quiet mode"
    $quietCountSeparator = " $([char]0x2022) "
    Assert-True ($limitedQuietDisplay.CountLine -eq ("1 TRENDING MOVIE" + $quietCountSeparator + "2 RECENT MOVIE RELEASES")) "$relativePath quiet count line ignored configured movie shelf cap"

    function Get-PosterPath {
        param(
            [string]$RatingKey, [string]$MetadataGuid, [string]$MediaType,
            [string]$MatchTitle, [string]$MatchYear, [int]$ParentIndex, [int]$Index,
            [ref]$LivePlexPoster
        )
        $LivePlexPoster.Value = $false
        return [IO.Path]::Combine([IO.Path]::GetTempPath(), ($RatingKey + ".jpg"))
    }
    function Get-SafeFilePart {
        param([string]$Value)
        return $Value
    }
    $limitedPosterAssets = @(Prepare-PosterAssets `
        -ReleaseData $quietReleaseFixture `
        -FeaturedRatingKey $quietHero.Item.PosterRatingKey `
        -HotRelease $quietHero `
        -QuietReleaseMode $true)
    Assert-True (($limitedPosterAssets.RatingKey -join ",") -eq "quiet-movie-1,quiet-movie-2,quiet-movie-3,quiet-show-1") "$relativePath did not prepare the hero plus every displayed MaxMovies=2/MaxTv=1 poster"

    $script:Config.MaxMovies = 8
    $script:Config.MaxTv = 8
    $defaultQuietDisplay = Get-NewsletterReleaseDisplayData -ReleaseData $quietReleaseFixture -HotRelease $quietHero -QuietReleaseMode $true
    Assert-True ($defaultQuietDisplay.Movies.Count -eq 4 -and $defaultQuietDisplay.Movies[-1].ReleaseKey -eq "movie:quiet-5") "$relativePath did not cap quiet movies at four after excluding the hero"
    Assert-True ($defaultQuietDisplay.TV.Count -eq 4 -and $defaultQuietDisplay.TV[-1].ReleaseKey -eq "show:quiet-4") "$relativePath did not cap quiet TV at four"
    $defaultPosterAssets = @(Prepare-PosterAssets `
        -ReleaseData $quietReleaseFixture `
        -FeaturedRatingKey $quietHero.Item.PosterRatingKey `
        -HotRelease $quietHero `
        -QuietReleaseMode $true)
    Assert-True ($defaultPosterAssets.RatingKey -contains "quiet-movie-5" -and $defaultPosterAssets.RatingKey -contains "quiet-show-4") "$relativePath did not prepare the final displayed quiet 4/4 shelf posters"
    Assert-True ($defaultPosterAssets.RatingKey -notcontains "quiet-movie-6" -and $defaultPosterAssets.RatingKey -notcontains "quiet-show-5") "$relativePath prepared posters beyond the displayed quiet 4/4 shelves"

    $script:Config.MaxMovies = 0
    $script:Config.MaxTv = 0
    $zeroQuietDisplay = Get-NewsletterReleaseDisplayData -ReleaseData $quietReleaseFixture -HotRelease $quietHero -QuietReleaseMode $true
    Assert-True ($zeroQuietDisplay.Movies.Count -eq 0 -and $zeroQuietDisplay.TV.Count -eq 0 -and $zeroQuietDisplay.CountLine -eq ("1 TRENDING MOVIE" + $quietCountSeparator + "0 RECENT MOVIE RELEASES")) "$relativePath did not honor valid zero content-card limits in quiet mode"
    $zeroPosterAssets = @(Prepare-PosterAssets `
        -ReleaseData $quietReleaseFixture `
        -FeaturedRatingKey $quietHero.Item.PosterRatingKey `
        -HotRelease $quietHero `
        -QuietReleaseMode $true)
    Assert-True ($zeroPosterAssets.Count -eq 1 -and $zeroPosterAssets[0].RatingKey -eq "quiet-movie-1") "$relativePath prepared shelf posters when configured limits were zero"

    $script:Config.MaxMovies = 8
    $script:Config.MaxTv = 8
    $script:GlobalTrendingStat = $null
    $noHistoryPlainText = Build-PlainText `
        -User ([PSCustomObject]@{ FriendlyName = "Viewer" }) `
        -Stats $empty `
        -ReleaseData $quietReleaseFixture `
        -HotRelease $null `
        -TrendingTitle "" `
        -SystemWarmingUp $false `
        -RecentAccess $false `
        -QuietReleaseMode $true `
        -StartLabel "August 1" `
        -EndLabel "August 7"
    Assert-True (-not $noHistoryPlainText.Contains("TRENDING THIS WEEK") -and -not $noHistoryPlainText.Contains("Warp core preparing")) "$relativePath invented a compact Trending footer without authentic global history"

    Assert-True ((Get-DynamicPreheader -ReleaseData ([PSCustomObject]@{
        Movies = @(); TV = @($tvRelease, $tvRelease)
    })) -eq '2 new TV titles!') "$relativePath inbox preview counted TV episodes instead of titles"
    $mixedPreheader = '1 new movie ' + [char]0x2022 + ' 1 new TV title!'
    Assert-True ((Get-DynamicPreheader -ReleaseData $releaseFixture) -eq $mixedPreheader) "$relativePath inbox preview lost mixed release counts"

    $twoTitleReleaseFixture = [PSCustomObject]@{
        Movies = @()
        TV = @([PSCustomObject]@{ Title = 'Show One' }, [PSCustomObject]@{ Title = 'Show Two' })
    }
    $plainText = Build-PlainText `
        -User ([PSCustomObject]@{ FriendlyName = 'Viewer' }) `
        -Stats ([PSCustomObject]@{ TotalSeconds = 0; TotalTimeText = '0m'; MovieItems = @(); TvShowItems = @() }) `
        -ReleaseData $twoTitleReleaseFixture `
        -HotRelease $null `
        -TrendingTitle '' `
        -SystemWarmingUp $false `
        -RecentAccess $false `
        -StartLabel 'August 1' `
        -EndLabel 'August 7'
    Assert-True ($plainText.Contains('2 new TV titles!')) "$relativePath plain-text inbox preview lost TV title semantics"
    Assert-True ($plainText.Contains('0 NEW MOVIES') -and $plainText.Contains('2 TV TITLES')) "$relativePath plain-text body counted TV episodes instead of shows"

    $source = Get-Content -LiteralPath $path -Raw
    Assert-True ($source -match '\$hotRelease = if \(@\(\$releaseData\.Movies\)\.Count -gt 0\)') "$relativePath does not fall back from a movie-empty release hero"
    Assert-True ($source -notmatch '\$Stats\.MovieItems \| Select-Object -First 4') "$relativePath still caps personal movies before enrichment or rendering"
    Assert-True ($source -notmatch '\$Stats\.TvShowItems \| Select-Object -First 4') "$relativePath still caps personal TV shows before enrichment or rendering"
    Assert-True ($source -notmatch '\$stats\.MovieItems \| Select-Object -First 4') "$relativePath still caps personal movie poster preparation"
    Assert-True ($source -notmatch '\$stats\.TvShowItems \| Select-Object -First 4') "$relativePath still caps personal TV poster preparation"
    Assert-True ($source -match '\$summaryCardHeight = 178') "$relativePath does not decouple the compact summary-card height from media row counts"
    Assert-True ($source -notmatch '\$statsCardHeight') "$relativePath still derives compact summary-card height from personal media rows"
    Assert-True ($source.Contains('colspan="2" width="100%" valign="top"')) "$relativePath does not render personal media cards at full width"
    Assert-True ($source.Contains('class="stats-title-cell" width="50%"') -and $source.Contains('.stats-title-cell { display:block !important; width:100% !important;')) "$relativePath does not render two desktop movie titles per row and one per row on mobile"
    Assert-True ($source.Contains('stats-title-cell stats-tv-title-cell stats-tv-title-left') -and $source.Contains('.stats-title-cell.stats-tv-title-cell { display:table-cell !important; width:50% !important;')) "$relativePath does not preserve two TV titles per row on mobile"
    Assert-True ($source.Contains('stats-title-spacer stats-tv-title-spacer') -and $source.Contains('.stats-title-spacer.stats-tv-title-spacer { display:table-cell !important; width:50% !important;')) "$relativePath does not preserve the odd TV-row spacer on mobile"
    Assert-True ($source.Contains('class="stats-summary-cell"') -and $source.Contains('.stats-summary-cell { display:block !important; width:100% !important;')) "$relativePath does not keep desktop summary cards side by side and stack them on mobile"
    Assert-True ($source.Contains('YOU CLOCKED') -and $source.Contains('total watch time') -and -not $source.Contains('>total watched<')) "$relativePath did not update the personal total-watch-time presentation"
    Assert-True ($source -match 'width="42" height="42" alt="Movies watched"') "$relativePath does not render the movie GIF at the standard stat-icon size"
    Assert-True ($source -match 'width="42" height="42" alt="TV shows watched"') "$relativePath does not render the TV GIF at the standard stat-icon size"
    Assert-True ($source -match 'Get-OptionalStringProperty -InputObject \$item -Name "DesignImdbRating"') "$relativePath does not render enriched TV IMDb ratings in personal stats"
    Assert-True ($source -notmatch '\$qualifyingPlayCount qualifying') "$relativePath retains qualifying-play copy in Total Watched"
    Assert-True ($source -match '\$assetUri\.Scheme -ieq \$providerUri\.Scheme') "$relativePath can forward a Plex token across an artwork scheme change"
    Assert-True ($source.Contains('The real email layout, across every state.')) "$relativePath lost the Preview All headline"
    Assert-True ($source.Contains('Go ahead, shrink my window.')) "$relativePath lost the responsive Preview All subtitle"
    Assert-True ($source.Contains('$(HtmlEncode $plexButtonLabel)</a>')) "$relativePath does not HTML-encode the configured button label"
    Assert-True ($source -notmatch '>OPEN PLEX</a>') "$relativePath retains a hard-coded HTML button label"

    Write-Host "[PASS] Renderer collection edges: $relativePath"
}

$expectedAssetHashes = @{
    'movies.gif' = 'B484EEA5855CB98DF6E346A4D60795EDAB9C00B06A3C1B9932C8AC62629ABDD6'
    'tv.gif'     = 'B0432E7316CE0F510D36C71D930AAD4AA153F8C71DBA39FC125FE2D04778F5C8'
}
$assetRoots = @(
    'docs/assets',
    'platforms/windows/assets',
    'platforms/nas-docker/app/assets-default',
    'platforms/mac-docker/app/assets-default'
)
foreach ($assetRoot in $assetRoots) {
    foreach ($assetName in $expectedAssetHashes.Keys) {
        $assetPath = Join-Path (Join-Path $Root $assetRoot) $assetName
        Assert-True (Test-Path -LiteralPath $assetPath -PathType Leaf) "Missing packaged asset: $assetRoot/$assetName"
        $actualHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash
        Assert-True ($actualHash -eq $expectedAssetHashes[$assetName]) "Packaged $assetName diverges in $assetRoot"
    }
}

Write-Host '[PASS] Supplied movie/TV GIFs are byte-identical across packages'
