# Configuration reference

TautWeekly for Plex writes live settings to `config.json`. Docker editions keep
it under `data/`; Windows keeps it beside the application; native Linux uses
`/var/lib/tautweekly`; and FreeBSD uses `/var/db/tautweekly`. Start from the
platform's `config.example.json` only for recovery or an expert manual setup.
Manager **Config** is the setup source on Windows, NAS/Docker, macOS Docker
Desktop, native Linux, and FreeBSD Podman. Terminal setup scripts remain
expert/recovery fallbacks on those packages.

Manager **Config > Configuration backups** lists private backup metadata, can
validate/restore one selected backup while first saving the current config, and
can permanently delete one selected backup only after **Confirm delete**.
Deletion leaves the live `config.json` unchanged and cannot be undone. Manager
and expert/recovery writers retain the newest 10 recognized backups; each new
overflow backup removes the oldest. Startup safely normalizes existing excess,
including legacy timestamp names, without adopting unrelated files or symlinks.

Manager operation history and configuration diagnostics each use count-only
FIFO retention of the newest 20 completed records. Each new overflow record
removes the oldest; record age does not otherwise expire an entry.

## Native Manager public access

Windows and native Linux Funnel state is Manager-owned private state, not a `config.json`
setting. The Manager remains bound to `127.0.0.1:8788`; the backend owns that
fixed target, Funnel HTTPS port 443, and every CLI argument. Browser requests
can submit only the allowlisted `enable`, `disable`, or `verify` operation. They cannot
supply a command, executable, port, hostname, target, or Tailscale argument.

Install, start, and sign in to the official Tailscale client yourself.
TautWeekly never stores auth keys, control-plane tokens, raw CLI output,
tailnet identities, device lists, private IPs, or sensitive paths. A verified
public `.ts.net` hostname is retained only to enforce exact Host/origin
admission. Funnel enablement requires an active Manager password lock. Access
reset, password-lock disable, explicit Exit or stop, adapter revocation, and
uninstall first verify the owned Funnel off. Ordinary Windows, native Linux,
container, macOS, and FreeBSD updates preserve the password verifier, retained
Funnel preference, and fixed route through replacement and rollback.

An exact local Funnel is reported as **Publication pending** until its hostname
resolves through the fixed `1.1.1.1` public resolver to a globally routable IPv4
address and a certificate-validated TLS handshake succeeds. The check discloses
only the intended-public hostname and stores neither the answer nor certificate.
The URL remains copyable while pending; no DNS, Tailscale service, firewall, or
router setting is changed automatically.

Before enabling, the host administrator must ensure the tailnet has MagicDNS,
HTTPS certificates, and a `funnel` `nodeAttrs` policy target for this node.
Tailscale's default `autogroup:member` example does not cover a node whose user
identity was replaced by a tag; separately managed tagged container or
Kubernetes nodes need an explicit tag-targeted attribute. Manager never reads
or edits that policy, and local `Funnel on` is not accepted as proof of public
publication on any platform.

Container/NAS, QNAP/Synology, Unraid, macOS Docker, and FreeBSD Podman use the
same public controller through an opt-in isolated userspace adapter. Set
`TAUTWEEKLY_FUNNEL_ADAPTER=enabled`, preserve the separate root-only provider
state mount, restart with the package tool, and run its fixed interactive login
command. Manager receives no root, Docker/Podman socket, host executable,
provider CLI, auth key, token, or arbitrary target. See the
[remote-access architecture and platform matrix](REMOTE-ACCESS.md).

## Bundled artwork and updates

Bundled email assets are release-owned. An asset-bundle transition (including
the v0.21.4 migration) replaces every shipped persistent filename, even if you
customized it; custom-only filenames and dynamic artwork are preserved.
Ordinary restarts with the same bundle keep later edits. Windows packaged
updates replace shipped assets through their existing verified updater.
See [bundled asset behavior](EMAIL-ASSETS.md) before customizing stock files.

## Tautulli and Plex

| Key | Required | Purpose |
|---|---:|---|
| `TautulliUrl` | Yes | Base URL reachable from the TautWeekly for Plex runtime, such as `http://media.example.test:8181` |
| `ApiKey` | Yes | Tautulli API key; treat as a secret |
| `PlexWebUrl` | Yes | Destination for the newsletter button; defaults to the Plex web app and may point to a custom service such as Seer |
| `PlexButtonLabel` | No | Newsletter button text; missing or blank values safely default to `Open Plex` |
| `PlexServerUrl` | No; recommended | Direct Plex base URL reachable from the TautWeekly runtime for the complete alternate rating set, exact-episode metadata, backgrounds, and selected logos; a separate container must not use its own localhost |
| `PlexToken` | No; recommended | Administrator/server Plex token for direct Plex access and exact-GUID deleted-item recovery; treat as a secret |

TautWeekly for Plex's core activity flow uses Tautulli. Direct Plex access is
optional for that core flow but recommended for full newsletter fidelity.
Tautulli may expose only its currently selected/flattened rating, while direct
Plex lets TautWeekly inspect alternate movie RT critic/audience ratings, the
exact episode's IMDb rating, backgrounds, and selected logos. When Plex has
deleted an item but Tautulli still retains its history GUID, TautWeekly can use
`PlexToken` to ask `https://metadata.provider.plex.tv` for that exact
identifier. This v0.8.3 compatibility path is best-effort, not durable storage:
the provider may return no record or asset after Plex has discarded the library
item. If a response omits provider scores, TautWeekly can use its exact returned
slug to read provider-labelled ratings on `https://watch.plex.tv`; that public
request receives no Plex token. Neither path searches by title or sends
recipient identity or watch-history values. An absolute artwork URL on another
host is also fetched without the Plex token.

Manager Config (or the platform's documented terminal fallback) stores the
private URL/token in `config.json`; container networking is a separate runtime
boundary. The URL must work from the TautWeekly process, not merely from a
desktop browser or the Tautulli container. **Validate, save, and verify** uses
the same discovery path as newsletter generation, sends the token only in the
`X-Plex-Token` header, and tests `/identity` plus authenticated
`/library/sections`. A resolved but unreachable or unauthorized connection is
a verification failure. If no URL/token pair can be resolved, verification
warns and preserves the supported Tautulli-only fallback.

An older configuration may legitimately contain neither direct-Plex key. A
guided migration preserves that file, identifies the omission, and adds the
current fields only after an explicit validated save. It never invents or
returns a Plex token. The Windows runtime may use `PlexOnlineToken` from the
current account's local Plex Media Server installation without copying it into
`config.json`; container/native runtimes may use an explicitly supplied
`PLEX_TOKEN` environment secret. The Manager reports only that a runtime token
is available. It never returns that value to the browser or writes it into a
configuration during normalization. A separately hosted Plex server still
requires a runtime-reachable `PlexServerUrl` and an explicitly supplied token.

### Metadata readiness before acceptance

Connection verification cannot prove that Plex or Tautulli holds current item
metadata. After first setup, after changing a Plex metadata agent or movie
Ratings Source, and after a ratings/artwork recovery update when upstream data
may be stale, complete these steps before PreviewAll or TestEmail:

1. Confirm **Edit → Advanced → Ratings Source** for every included Plex Movie
   library.
2. Run Plex **Manage Library → Refresh All Metadata** for every included movie
   and TV library, and wait for all refreshes to finish.
3. In Tautulli, open each same **Library → Media Info** tab, choose
   **Refresh media info**, and wait. The control is per library; repeat it for
   every included section.
4. In Manager, open **Verify**, generate PreviewAll, and send a controlled
   TestEmail. Use the documented terminal verifier only as a recovery fallback.

Plex documents that a full refresh can take significant time and can update
existing metadata and artwork. Scope it to TautWeekly's included movie/TV
libraries. Tautulli's media-info refresh updates its library table after Plex;
it neither changes the Plex Ratings Source nor replaces Plex's metadata
refresh. Routine TautWeekly updates do not require this full sequence when
current output is already correct.

Posters and hero art can still succeed through Tautulli's image proxy when the
direct Plex URL is unreachable. That does not prove that direct rating,
background, or selected-logo metadata is available. v0.9.5 uses Tautulli's
normal metadata and single-item JSON exporter for provider-labelled ratings;
it requests only metadata level 1, disables media information, and does not
request library/user individual files. Movie Rotten Tomatoes remains preferred
even when flattened metadata selects IMDb; a labelled movie IMDb score is the
final fallback only when no RT value exists. TV release rows prefer IMDb for
the exact episode, then use that exact episode's RT critic or audience value
when IMDb is absent. They do not substitute a selected show, movie, TMDB, or
TVDB score. Both rating field pairs are still parsed because Tautulli can place its
selected provider in either pair. Provider-free numbers, unknown provider
identifiers, out-of-range scores, and unavailable logo resources remain
omitted rather than guessed.

The [Tautulli `get_history` API](https://github.com/Tautulli/Tautulli/wiki/Tautulli-API-Reference#get_history)
retains descriptive fields such as GUID/rating keys, titles, years, episode
indexes, and play fields. Artwork fields are references, not durable image
bytes. Tautulli's [Exporter Guide](https://docs.tautulli.com/using-tautulli/exporter-guide)
likewise treats exported image resources as a separate explicit export. Once
Plex and Tautulli no longer have the asset, TautWeekly cannot reliably recover
it retroactively.

## Persistent deleted-item cache

| Key | Default | Accepted range | Purpose |
|---|---:|---:|---|
| `DeletedItemCacheEnabled` | `true` | Boolean | Enables capture and exact-ID fallback reads |
| `DeletedItemCacheRetentionDays` | `365` | 1-3650 | Expires entries by their last live observation |
| `DeletedItemCacheMaxItems` | `1000` | 1-10000 | Maximum retained entries before oldest-first eviction |
| `DeletedItemCacheMaxBytesMB` | `256` | 16-2048 | Total ceiling for artwork plus primary/backup manifests, with bounded overhead for atomic operations |

The schema-versioned cache records only the exact stable GUID and media type,
title, year, bounded summary, up to eight genres, newsletter rating values,
one poster with byte count and SHA-256 hash, and creation/last-seen timestamps.
It does not record playback metrics, recipient identity, generated newsletter
content, API keys, SMTP settings, or the Plex token. The token is never passed
to the cache and is never forwarded to an external poster host.

Entries are created only when live local metadata and a non-generic poster are
available. Later lookups require the same normalized stable GUID and media
type. Rating keys and titles are not fallback identities, so already-deleted
history with a missing or ambiguous identifier fails closed.

Enabling the setting does not take a whole-library snapshot. The dedicated
cache refresh enumerates every currently production-eligible included user,
loads that user's current `DaysBack` newsletter history from the selected
movie/TV libraries, and captures each unique qualifying live item. It also
uses the common current shared-item preparation performed by the renderer. It
does not crawl unrelated Plex library contents or retain recipient identity or
viewing metrics. Preview, PreviewAll, SendTest, SendTestAll, scheduled delivery,
and confirmed manual delivery can still refresh qualifying entries they select
while the live metadata and usable poster remain available.

Disabling the setting stops cache reads, writes, verification, and cleanup but
does not erase retained entries. Re-enabling it initializes the same private
cache and immediately applies the configured retention, item, and byte limits.

In Manager, enabling the cache or changing cache coverage and choosing
**Validate, save, and verify** starts the dedicated no-email cache refresh.
Cache health shows blue **Running** immediately; this independent operation
does not rerun unrelated discovery, Plex/Tautulli, SMTP, or preview checks.
When it ends, Manager automatically runs and retains the full local cache
verification. A failure or cancellation is shown as **Failed** and does not get
replaced by a stale healthy summary. The manual cache check remains an optional
later storage recheck and never substitutes for coverage. After direct edits to
`config.json`, run the package's `cache-refresh` command to establish coverage.

Cleanup runs at initialization and after writes. Expired entries are removed,
then the newest entries are retained deterministically until the item and total
byte limits are satisfied. `index.json` is replaced atomically on the same
volume and `index.backup.json` holds the previous valid generation. A corrupt
primary recovers from that backup; if neither generation is valid, one corrupt
copy is retained when practical and the cache starts empty. Poster hash failures
remove the damaged entry and rendering continues without it.

Manager Dashboard **Config status** includes a privacy-safe **Deleted-item
cache** row. **Verify → Check deleted-item cache** performs a fixed-content
local write probe and hashes cached artwork. Both surfaces expose only health
states, bounds, and aggregate counts. They never expose paths, titles, GUIDs,
rating keys, hashes, artwork, viewing metrics, recipients, credentials, or
manifest contents. An `unseeded` result means the cache is enabled but no
qualifying live refresh or render has written an entry; it is not evidence of
a cache hit.

The full result from **Validate, save, and verify** is retained for Verify,
including after refresh; the manual check is an optional later recheck. When
disabled, **Enable Cache Storage** only navigates to and focuses the Config
setting; it does not toggle or save it.

Existing configurations migrate safely because missing keys use the defaults
without rewriting `config.json`; setup preserves explicit values on
replacement. Windows stores the cache beside the application at
`cache/deleted-items`. Docker/macOS uses `/data/cache/deleted-items`, native
Linux uses `/var/lib/tautweekly/cache/deleted-items`, and FreeBSD uses
`/var/db/tautweekly/cache/deleted-items`.

Set `DeletedItemCacheEnabled` to `false` to stop reads and writes without
deleting data. To purge, stop TautWeekly and remove only the
`cache/deleted-items` directory under the applicable private data root. Backups
that include the cache must remain private. A full uninstall can remove the
entire private data root only after configuration, state, output, cache entries,
and backups are no longer needed.

## Optional custom text card

| Key | Default | Accepted range | Purpose |
|---|---:|---:|---|
| `CustomTextCardEnabled` | `false` | Boolean | Places the custom card before the newsletter title/date block; disabling hides it without clearing saved content |
| `CustomTextCardBorderColor` | `#72aef7` | Six-digit hex color | Selects the optional card-border color |
| `CustomTextCardBorderOpacity` | `34` | 0-100 | Sets border opacity; 0 removes the visible border |
| `CustomTextCardTitle` | empty | 0-120 characters | Optional gold uppercase label at the Welcome Aboard title size |
| `CustomTextCardTitleGif` | `none` | `celebrate`, `construction`, `rocket`, `tickets`, `warning`, `alert`, or `none` | Optional packaged GIF appended to a non-empty rendered title |
| `CustomTextCardSubheading` | empty | 0-200 characters | Optional large white heading |
| `CustomTextCardBody` | empty | 1-2000 characters when enabled | Required plain-text body when the card is enabled |

The Manager balances the card layout when either optional heading is omitted.
Saving the card disabled retains its title, GIF, subheading, body, border color,
and opacity. Re-enabling it restores those saved values; only rendering is
suppressed while disabled.
The in-field title control shows a local add-reaction glyph when no GIF is
selected and a 24×24 preview after selection. Selecting the active GIF again,
or pressing Delete/Backspace while the control is focused, clears it. The
stored asset ID never changes the title text. Delivered HTML places the
allowlisted GIF immediately after the uppercase title at 18×18 pixels using a
selected-only `image/gif` CID; previews use the byte-identical packaged asset.
If the ID or asset is missing or unsafe, rendering continues with no GIF.
Line breaks are preserved. Values remain plain text and are HTML-escaped before
rendering, so configured content cannot become executable markup. The card is
included in normal and welcome HTML newsletters, the plain-text alternative,
and generated previews. Enabling the card with an empty or whitespace-only
body blocks validation, save, and verification in both the browser and Manager
API. Existing configurations remain disabled by default and do not need to add
these keys; a missing title-GIF key means `none`.

## Branding and mail

| Key | Purpose |
|---|---|
| `ServerLabel` | Compact label used in newsletter identity |
| `FooterServerName` | Human-readable server name in the footer |
| `FromName` | Display name for outgoing mail |
| `FromEmail` | SMTP envelope/message sender allowed by the provider |
| `ReplyToEmail` | Reply destination |
| `SmtpHost`, `SmtpPort` | STARTTLS SMTP endpoint; port 587 is the usual default |
| `SmtpEnableSsl` | Enables TLS negotiation |
| `SmtpUseAuthentication` | Whether SMTP credentials are sent |
| `SmtpUsername`, `SmtpPassword` | Provider credential; the password is stored as plain text |
| `SmtpStripPasswordSpaces` | Optional normalization for providers that display grouped app passwords |
| `SmtpAuthenticationMethod` | `Auto` prefers challenge-style `LOGIN`, then `PLAIN`; set an explicit supported method only when required by the provider |
| `SmtpTimeoutSeconds` | Connection and protocol timeout; defaults to 30 seconds |
| `TestEmail` | Controlled recipient for all test modes |

### Provider-neutral SMTP setup

Before opening Manager Config, obtain the submission settings from the mail
service administrator. You need the outbound SMTP hostname, STARTTLS port,
whether authentication is required, the exact username format, an SMTP-capable
credential, and the sender addresses that account may use. Do not substitute an
incoming IMAP/POP host, a webmail URL, or settings copied from an unrelated
account.

1. Set `SmtpHost` to the submission hostname and `SmtpPort` to its documented
   STARTTLS port. Port 587 is common, but the administrator's submission setting
   is authoritative. Port 465 uses implicit TLS and is intentionally rejected.
2. Keep `SmtpEnableSsl=true` for STARTTLS. TautWeekly connects, reads the SMTP
   greeting, sends `EHLO`, requires the advertised `STARTTLS` capability,
   validates the TLS certificate with the operating-system trust store, then
   sends a second `EHLO` over the protected connection.
3. Keep `SmtpUseAuthentication=true` unless the administrator explicitly
   provides a network-restricted relay that accepts this TautWeekly runtime
   without credentials. Enter the username exactly as issued; it may be a full
   address, a short account name, or another service-defined identifier.
4. Store the SMTP password or application-specific credential in
   `SmtpPassword`. Leave `SmtpStripPasswordSpaces=false` unless the credential
   is displayed in grouped blocks whose spaces are presentation separators.
   Leave `SmtpAuthenticationMethod=Auto`; it selects a supported `LOGIN` or
   `PLAIN` exchange advertised by the server. Expert/recovery configuration may
   pin `Login` or `Plain` only when the service administrator requires that
   exact advertised method.
5. Set `FromEmail` to an envelope sender the account is authorized to use.
   `FromName` is display text and `ReplyToEmail` is the reply destination; they
   do not grant sender permission. Set `TestEmail` to one controlled mailbox
   you can inspect.
6. Validate and save in Manager. **Verify** checks configuration shape and TCP
   reachability but deliberately does not authenticate or submit a message.
   Run one controlled TestEmail/`send-test` to verify STARTTLS, authentication,
   sender authorization, recipient acceptance, final DATA acceptance, and
   actual delivery before enabling or relying on the schedule.

Implicit SMTPS on port 465 is not the supported transport. Use a provider's
STARTTLS settings. The SMTP transport completes authentication and requires a
successful `235` response before it sends `MAIL FROM`. The platform verifier
checks TCP reachability and configuration shape only; run a controlled
`SendTest` with a numeric `USER_ID` to validate credentials and sender
authorization.

## Content and eligibility

| Key | Default | Purpose |
|---|---:|---|
| `DaysBack` | 7 | Activity and recently-added window |
| `WatchedPercent` | 85 | Movie/episode qualification threshold; definitive `watched_status=1` also qualifies |
| `MaxMovies`, `MaxTv` | 8 | Content-card limits |
| `IncludedLibraryIds` | `[]` | Stable Tautulli section IDs defining the global newsletter scope; empty means all active movie/TV libraries for backward compatibility |
| `ExcludedUserIds` | `[]` | Users omitted by stable Tautulli ID |
| `ExcludedEmails` | `[]` | Email addresses omitted from delivery |
| `UserEmailOverrides` | `{}` | Private map from numeric Tautulli user ID to a fallback address, used only for an active user with no native email |
| `RecentAccessDays` | 7 | New/recent access classification |
| `SendDelaySeconds` | 30 | Pause between real production recipient attempts |
| `TestSendDelaySeconds` | 10 | Pause between controlled Test All messages |

Legacy configuration files may still contain `MinimumEpisodeSeconds`. Current
builds ignore that retired key; a fixed 120-second episode rule no longer
qualifies personal TV or server-wide activity.

Direct configured SMTP remains the standard delivery path. Production messages
stay personalized with exactly one envelope recipient. The recommended cadence
is 30 seconds between production attempts and 10 seconds between controlled
Test All messages; existing configurations keep their explicit values. Avoid
running Test All or a manual production batch near the scheduled send.

Spacing reduces cadence but cannot override provider quotas, reputation, or
account-protection controls. Authentication failure, a temporary 4xx
provider/service response such as `421`, a batch-wide rejection, a transport
failure, or unknown final-DATA acceptance stops SendAll before another SMTP
connection. A permanent 5xx RCPT rejection with an address/mailbox-specific
enhanced status may continue to later
recipients, but the same configured delay still applies before the next
attempt. Accepted or ambiguously accepted DATA is never retried. After a
provider lock, stop retries and allow a quiet period according to the provider
notice; if it does not clear sooner, wait up to 24 hours before escalating
through the provider's normal account-recovery path.

### Global library selection

Manager Config calls `get_libraries` after the Tautulli URL and API key are
entered and presents active movie and TV libraries for selection. The terminal
fallback accepts rows or ranges such as `1,3-4`, `all`, or Enter to keep the
displayed scope. At least one active movie or TV library is required for a
newly saved selection.

`IncludedLibraryIds` is applied to raw Tautulli history and recently-added
rows before any newsletter calculations. New/recent releases, Trending detection,
Trending, the hero, Binge Champion, and each user's personal totals therefore
share the selected scope. Per-user Plex sharing rules are not queried or
intersected; this is a single administrator-controlled scope.

### Weekly activity qualification

Weekly history requests use `grouping=1` and `include_activity=0`, so active
sessions are excluded. A movie or episode qualifies when Tautulli reports the
definitive `watched_status=1` (including its credits-aware decision), or when
`percent_complete >= WatchedPercent`. Partial grades `0.25`, `0.5`, and `0.75`
do not qualify by themselves.

Each returned grouped history reference counts as one play. `group_count` is
not multiplied into newsletter totals, so resumed fragments remain one play;
separate qualifying history references, including rewatches, count again and
add their own watch time. Transcode, Direct Stream, and Direct Play use the same
qualification rule.

Personal total watch time is the deliberate exception: it sums all movie and
episode playback in the report window, including partial rows. Personal movie
cards, personal TV cards, Trending, Hot New Release, Top Genre, and Binge
Champion use qualified rows only. Personal TV groups qualified episodes by
show, displays the unique episode count with correct singular/plural copy, and
retains the show-level rating; per-show duration and episode-level rating rows
are omitted.

Movie **TRENDING THIS WEEK** ranks qualified movies by play count, unique
viewers, qualified watch time, then most recent activity. Its hero/footer line
is `Most watched across <server> this week • N play(s)`.

A new movie produces the **HOT NEW RELEASE** hero. New movies with qualified
activity rank by play count, unique viewers, qualified watch time, then added
date. The line is
`Most-watched new release across <server> this week • N play(s)`; when no new
movie has qualified activity, the newest movie is featured with `Freshly
added!`. Its footer is the existing full-width **TRENDING THIS WEEK** movie
card, and new movie/TV shelves retain their established behavior.

**Binge Champion** considers qualified movie and episode rows and ranks users
by qualified watch time, play count, unique movie/TV-show count, then recency.
Its supporting line places total plays first, for example
`7 plays • 3 movies • 2 TV shows: 5 episodes`, omitting a zero media category.
The episode suffix appears only when more than one episode qualifies and totals
qualified episode plays across every included TV show; it never repeats the
unique TV-show count.

A report window with no new movies is a Trending state. When new TV exists, one
authentic movie-only **TRENDING THIS WEEK** result is used as the hero when
server history supplies it. **RECENT RELEASES / Movies** then contains up to
four different recent movies, and **NEW RELEASES / TV** contains up to four new
series. The line above the date and the email preview/preheader are the same
computed string: `0 NEW MOVIES • X TV TITLE(S)`.

When there is no new TV either, the hero and recent movie shelf are unchanged;
the TV shelf becomes **RECENT RELEASES / TV** with up to four series whose
`added_at` value is strictly newer than one calendar month before generation.
The shared count/preheader is
`1 TRENDING MOVIE • X RECENT MOVIE RELEASE(S)` when the authentic hero exists.
The hero is excluded from the movie shelf. Its complementary footer is **TOP
GENRE THIS WEEK**, so Trending never appears in both hero and footer.

Top Genre is calculated server-wide from qualifying movie activity in the same
report window and included-library scope. Each distinct movie is resolved once;
only Plex's first returned genre is used. Labels are normalized
case-insensitively, including `Science Fiction`, `Sci-fi`, `Sci Fi`, and `SciFi`.
Genres rank by total qualified watch seconds, unique movie count, qualifying
play count, then normalized genre name. The visible result contains only total
watch time and unique movie count. Metadata failures and movies without a genre
are skipped; no usable genre, or a winner without dedicated artwork, uses the
neutral local movie animation and never exposes an individual viewer.

Authentic recipient watch rows are not removed or fabricated. Preview,
PreviewAll, SendTest, SendTestAll, scheduled delivery, and confirmed manual
delivery all use these same computed release and footer values.

Movie and TV personal-stat cards keep their established layout and recipient
platform icon. When provider metadata exists, movie rows retain poster, genres,
and Rotten Tomatoes critic/audience ratings; TV rows retain poster, unique
episode count, and show-level IMDb rating.

Normally revise this scope in Manager Config. Recovery/expert fallbacks are
`15-MANAGE-LIBRARIES.bat` on Windows,
`./tautweekly.sh manage-libraries` on Docker editions, and
`sudo tautweekly manage-libraries` on Linux or FreeBSD. The write path backs up
`config.json` first. The corresponding `list-libraries` command (or
`16-LIST-LIBRARIES.bat`) is read-only. Verification warns about stale IDs and
fails when no configured ID matches an active video library.

### Recipient movie watched markers

A **Watched** mark belongs only to the newsletter recipient. For each included
library scope, TautWeekly pages through Tautulli `get_history` with
`grouping=1`, `include_activity=0`, `media_type=movie`, the exact recipient
`user_id`, and `start`/`length` pages of 1,000. The query deliberately has no
`after` or `before` filter: a movie watched before the weekly report window
still qualifies. Active sessions are excluded regardless of Tautulli's history
table setting.

Every returned row must prove the same recipient ID and movie type and pass
the selected-library predicate. A row qualifies when Tautulli reports the
definitive `watched_status=1` (including its credits-aware watched decision),
or `percent_complete >= WatchedPercent`. Partial Tautulli grades `0.25`,
`0.5`, and `0.75` do not qualify by themselves. Matching uses only a movie's
rating key or metadata GUID, never its title, popularity, server-wide plays, or
another user's state.

This is the most reliable recipient-specific evidence available through the
configured Tautulli connection. The administrator's optional Plex token is used
for metadata/artwork, not as a substitute for a recipient token. A movie marked
watched manually in Plex, or watched before Tautulli began retaining history,
cannot be inferred without a qualifying Tautulli history row. Missing identity
or a failed historical lookup omits the marker; it never guesses. The lookup
is in-memory for that recipient/render and does not add viewing-state files or
identity-bearing diagnostics.

The desktop full-width movie hero uses the unchanged 26×26 shield, inset 7px
from the poster's right edge and raised 5px above its top, with an Outlook VML
group; other clients use a table overlay without CSS positioning. Mobile
heroes and main movie release cards display the original circle PNG at 16×16px
immediately after the title with 8px left spacing
and shared text/icon vertical centering. Only the final title word stays with
its icon; preceding words wrap normally without orphaning the marker.
Footer statistics, including personal movie recaps and compact Trending, have
no watched markers. Both original PNG files remain byte-identical.
Both images have `alt="Watched"` and `title="Watched"`; plain text supplies the
equivalent status. Unwatched movies add neither markup nor a spacer, and TV
titles are unchanged. Preview, PreviewAll, SendTest, SendTestAll, welcome,
scheduled delivery, and confirmed manual delivery use the same recipient
state. Watched semantics are not added to the dynamic inbox preheader.

The consumed API contract was checked against
[Tautulli v2.18.0](https://github.com/Tautulli/Tautulli/releases/tag/v2.18.0).
Its SQL-backed history pagination preserves these parameters and fields.
Synthetic fixtures cover pagination, graded watched status, omitted redundant
section IDs, and the new HTTP error behavior for invalid metadata.

### Interactive user exclusions

Manager Config queries Tautulli after `TautulliUrl` and `ApiKey` are entered,
then presents the delivery roster. The terminal fallback accepts rows or ranges
such as `2,4-6`, Enter to keep the current list, or `none` to clear every
exclusion. Unknown IDs already in the configuration are preserved when a new
known-user selection is saved, which avoids dropping an exclusion merely
because a user is temporarily absent from the current Tautulli response.

Roster loading makes two bulk requests: `get_user_names` supplies stable IDs
and display names, while `get_users` supplies delivery details. The results are
merged by ID. TautWeekly for Plex does not call `get_user` once per roster row;
if the detailed bulk request fails, name-only rows remain selectable but are
not marked delivery-eligible in the selector.

The Config checkboxes are exclusions: checked means excluded. A separate
**Managed-user delivery addresses** card appears only for active users whose
Tautulli record has no native email. Its validated email controls update the
private `UserEmailOverrides` object by stable numeric user ID; multiple users
may intentionally share one inbox. Clearing a value removes that assignment,
while assignments for IDs absent from the current discovery remain preserved.
Tautulli's reserved **Local** user ID `0` represents unidentified or
unauthenticated activity, not a managed Plex profile. It is automatically
excluded from newsletter discovery, address-needed counts, personalized
generation, welcome tracking, delivery, and cache recipient coverage. No
manual exclusion is needed, and a saved fallback address cannot enable it.
This rule uses the reserved ID, not the name: a real nonzero user named Local
remains supported. Tautulli's anonymous playback history is not deleted.
Tautulli's legacy `do_notify` notification-agent value does not
grant or revoke TautWeekly delivery; explicit `ExcludedUserIds` and
`ExcludedEmails` remain the administrator-controlled opt-out policy. SendAll
records only fixed aggregate skip counts for inactive/deleted users, missing
email, stable-ID exclusions, and legacy email exclusions. It never stores a
recipient identity in Manager history or reports a zero-recipient run as SMTP
success.

Production eligibility uses one fixed precedence: inactive or deleted account,
`ExcludedUserIds`, native Tautulli email when present (otherwise the mapped
fallback), missing effective address, then `ExcludedEmails` against that
effective address. An override never replaces or reroutes a native email.
`SendAll`, the separately confirmed one-off welcome, and cache coverage use the
same effective recipient. Every personalized mode enforces the saved stable-ID
and effective-address exclusions before generation or SMTP. Preview and every
TestEmail mode may still sample an included user who lacks a production
address, and test delivery remains isolated to the configured `TestEmail`.
Removing a mapping does not alter welcome/history state and returns an
otherwise eligible native-blank user to `missingEmail` until another address
is assigned.

An individual user lookup must identify the exact requested user. If Tautulli
returns its Local fallback or a different user, TautWeekly tries an exact
matching bulk-roster entry and otherwise stops that lookup as unavailable.

Saving an assignment change regenerates previews and, when the deleted-item
cache is enabled, refreshes recipient coverage. Discovery retains only the
numeric ID, display name, role, eligibility, and an address-needed Boolean.
The address map is absent from the sanitized choice cache and all shareable
diagnostics. It remains private data in `config.json` and configuration backups.

**Repeat this Tautulli lookup** and the main header **Refresh** repeat the same
saved-revision, LAN-only lookup and refresh only the Manager's library and user
choices; neither action generates previews or contacts Plex or SMTP. Every
manually confirmed or scheduled SendAll instead makes one bounded, authenticated
`refresh_users_list` request at the start of the shared
production path, then fetches and classifies Tautulli's live roster. A newly
eligible Plex user is therefore included on the next production send unless
explicitly excluded; no Config save or daily Manager poll is required. If
Tautulli cannot confirm the refresh, delivery fails before any SMTP connection
with the fixed `user-roster-refresh-failed` category.

Normally revise exclusions in Manager Config. Recovery/expert fallbacks are
`14-MANAGE-USER-EXCLUSIONS.bat` on Windows,
`./tautweekly.sh exclude-users` on either Docker edition, and
`sudo tautweekly exclude-users` on Linux or FreeBSD. The standalone command
does not change `ExcludedEmails`, `UserEmailOverrides`, SMTP values, or
scheduling. Both exclusion lists affect Preview, PreviewAll, TestEmail,
TestEmail All, scheduled or confirmed SendAll, and the separately confirmed
one-off welcome. Manager operation selectors use the last successfully saved
policy; excluded users remain visible in Config so they can be included and
saved again.

## Scheduling

| Key | Purpose |
|---|---|
| `ScheduleDay`, `ScheduleTime` | Local delivery day and 24-hour time |
| `ScheduleEnabled` | Container and native-service scheduler opt-in; defaults to false in examples |
| `ScheduleGraceMinutes` | How long a delayed scheduler poll may still attempt the send |
| `SchedulerPollSeconds` | Container scheduler poll interval |
| `ScheduledTaskName` | Windows Task Scheduler identity |

Windows uses Task Scheduler and the host's local Windows time. Every other
package resolves the platform timezone as an IANA zone and converts UTC through
that zone for each schedule decision. An invalid zone blocks automatic delivery
instead of falling back to UTC.

`schedule-status` reports both the zone/time resolved by its short-lived control
process and the zone/time recorded by the active scheduler heartbeat. After
changing a timezone environment file, restart the native service. After changing
Docker environment configuration, run the package `./tautweekly.sh restart`
command, which recreates the application service so current `.env` values are
applied. Podman and NAS vendor controls must use their equivalent container
recreation flow. Then confirm that `Scheduler TZ` matches `Configured TZ` before
enabling delivery.

## Docker environment

| Variable | Purpose |
|---|---|
| `TZ` | IANA timezone, such as `Etc/UTC` |
| `PUID`, `PGID` | Non-root runtime identity with write access to `data/` |
| `UMASK` | File-creation mask; `077` is the secure default |
| `PREVIEW_BIND` | Compatibility name for the host interface that publishes the authenticated Manager; Mac defaults to `127.0.0.1` |
| `PREVIEW_PORT` | Compatibility name for the host Manager port, normally `8787` |
| `PREVIEW_BASE_URL` | Public/local Manager base URL used for authenticated preview links |
| `MANAGER_ALLOWED_HOSTS` | Comma-separated exact DNS names accepted in addition to IP literals/localhost; no wildcards or ports |
| `MANAGER_SECURE_COOKIES` | Leave `false` for loopback recovery; verified Funnel requests enforce the public HTTPS cookie boundary automatically |

Never paste live values into an issue, pull request, repository file, or public
release archive.

## Native service environment

Native Linux reads root-owned non-secret service values from
`/etc/tautweekly/tautweekly.env`. FreeBSD reads them from
`/usr/local/etc/tautweekly/tautweekly.env`. These files define the timezone,
data path, Manager bind/port, and-on FreeBSD-the OCI image reference. Keep SMTP,
Tautulli, and Plex secrets in the private `config.json`, not in service
environment files.
