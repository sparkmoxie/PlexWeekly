# Changelog

All notable public changes to TautWeekly for Plex will be documented here. The project
uses [Semantic Versioning](https://semver.org/) for GitHub releases and follows
the structure of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.26.1] - 2026-09-09

### Fixed

- Exclude Tautulli's reserved Local user ID `0` from newsletter discovery, delivery-address prompts, recipient selection, personalized generation, welcome tracking, and deleted-item cache recipient coverage. A saved fallback address cannot make the anonymous identity eligible; real users named Local with a nonzero ID remain supported.
- Validate that individual Tautulli user lookups return the requested identity. If Tautulli substitutes its Local fallback or another user, resolve only an exact matching bulk-roster entry or fail closed without generating or sending that user's newsletter.

## [0.26.0] - 2026-09-09

### Added

- Add private `UserEmailOverrides` assignments for active Tautulli managed users who have no native email address. Manager shows a separate accessible card only for those users, accepts shared inboxes, preserves temporarily undiscovered assignments, and lets clearing an assignment restore the normal missing-email result.

### Changed

- Resolve production recipients in the fixed order inactive/deleted, stable-ID exclusion, native Tautulli email or managed-user fallback, missing email, then effective-address exclusion. A native email can never be rerouted by the fallback map; `SendAll`, `SendWelcome`, and cache coverage use the effective address while every TestEmail mode remains isolated.
- Treat changes to managed-user assignments as recipient coverage changes, regenerating previews and refreshing enabled deleted-item cache coverage through the existing post-save workflow.

### Security

- Keep managed-user addresses only in private `config.json` and its private backups. Sanitized discovery, retained choice caches, configuration summaries, operation results, diagnostics, and shareable cache reports expose only an address-needed flag or aggregate counts—not the mapping or an address.

## [0.25.5] - 2026-09-01

### Fixed

- Prevent a Manager-driven Windows update from leaving the local Dashboard offline when process teardown succeeds but Windows reports a post-stop verification failure. The updater now records relaunch responsibility before termination and recovers either the exact healthy Manager or a new verified instance without changing retained Tailscale Funnel state.
- Extend the Windows installer lifecycle test with the post-stop failure window that escaped v0.25.4 validation, proving both failure recovery and the subsequent normal update path restore the fixed loopback listener.

## [0.25.4] - 2026-09-01

### Changed

- Recolor the Manager header update badge, border, focus state, and animated halo from violet to the established Manager blue.
- Label the top-right Windows package badge Windows Manager while retaining the compact macOS Docker label.

### Fixed

- Preserve an active Windows Tailscale Funnel across Manager-driven update and rollback by keeping the update-internal process restart separate from the explicit shutdown lifecycle that deliberately disables public access.
- Apply the upstream Tailscale light SVG fill and opacity directly to its inline paths so active or publication-pending states show four bright and five muted circles while every other state mutes all nine circles.

## [0.25.3] - 2026-09-01

### Changed

- Match the Manager header's Tailscale badge to the upstream light icon: active or publication-pending states retain its four full-opacity circles, while every other state mutes all nine circles.
- Shorten the Manager package badge to Windows for both installed and ZIP Windows Managers and macOS Docker for the macOS Docker Desktop package.

### Fixed

- Restore Windows Manager data-directory resolution in the update helper so an update or rollback can relaunch a Manager that was running when the update began.

## [0.25.2] - 2026-09-01

### Changed

- Binge Champion winner and non-winner summaries retain total plays plus unique
  movie and TV-show counts, and now append the cumulative qualifying episode
  count when it is greater than one, with correct singular/plural labels.
- Central Markdown documentation now provides a more detailed, provider-neutral
  SMTP setup, verification, security, and stage-by-stage troubleshooting path;
  platform Quickstarts remain focused on package operation.
- The Manager header now places a locally bundled Tailscale-light badge after
  the access lock. Verified Active and Publication pending use the source SVG's
  default bright/faded-dot appearance; Off, unsupported, unconfigured,
  disabled, blocked, failed, and every other non-active state use one uniform
  off appearance. Its animated tooltip reports the exact sanitized state.
- The Dashboard Tailscale Funnel row is now borderless, uses a smoother hover
  transition and animated accessible tooltip, and its deep link clears the
  sticky header so the beginning of the complete Settings card is visible.

### Fixed

- Restored the direct Unraid Apps catalog shortcut on the NAS / Docker landing
  card and added a documentation contract to prevent it from disappearing
  while the combined NAS/Docker/QNAP/Unraid Quickstart remains the main guide.
- Removed the Unraid template's optional literal-loopback `WebUI` metadata,
  which Community Apps automatically blacklisted under its launch-URL policy.
  The fixed loopback publish, SSH recovery path, and verified Funnel option are
  unchanged; validation now prevents the rejected metadata from returning.
- Manager discovery now falls back to Tautulli's table-backed library and user
  rosters when the primary Plex-backed commands fail or return a valid empty
  response, and accepts the supported numeric, string, and Boolean response
  variants returned by real Tautulli installations.
- A failed discovery refresh still reports HTTP 502 and a failed Choices step,
  while a valid exact-revision cache remains readable and usable with an
  explicit retained marker and timestamp. Older Tautulli, Plex, and SMTP
  connection results are labeled as separate retained evidence instead of
  contradicting the current discovery failure.
- Discovery diagnostics expose only allowlisted connection, library-roster,
  and user-roster codes with sanitized guidance; raw provider output and
  private server data remain excluded.
- Windows Manager/installer updates no longer invoke destructive
  `remote-access-cleanup` before package replacement. The password lock,
  verified public hostname, publication proof, enabled preference, and fixed
  loopback Funnel route remain retained through update and rollback.
- Corrected the native Linux wrapper and candidate installer so subsequent
  verified updates also preserve retained Funnel state and the fixed route.
  Explicit Disable, stop, access reset/recovery, adapter revocation, and
  uninstall remain fail-closed cleanup operations on every applicable package.

## [0.25.1] - 2026-09-01

### Changed

- The Dashboard Integrations card now includes Tailscale Funnel directly below
  SMTP on every maintained Manager. Safely disabled and independently verified
  Active routes contribute **Passed** while visible supporting text distinguishes
  **Off** from **Active**.
- Local route configuration that is still waiting for independent public DNS
  and trusted-TLS postconditions now contributes gold **Attention**. Missing
  password protection while enablement is retained, route mismatch, stale or
  malformed state, and incomplete cleanup contribute **Failed**; unsupported or
  genuinely unconfigured surfaces remain neutral and do not fail the optional
  integration.
- The Funnel row links to the canonical **Settings > Tailscale Funnel** panel
  with focus transfer, browser history, mobile reflow, reduced-motion, and
  forced-color support. The synchronized fictional GUI preview exposes the same
  behavior without contacting a provider or host.

### Security

- Passive Dashboard rendering reuses the existing authenticated, sanitized,
  typed retained-status API and never invokes a Tailscale provider command or
  independent verification. The row renders only fixed state copy and never
  exposes a command, argument, target, hostname, URL, raw output, identity,
  address, token, or sensitive path.

## [0.25.0] - 2026-08-31

### Added

- Replaced maintained private Tailscale Serve deployments with an explicit,
  password-gated Tailscale Funnel that keeps Manager on its fixed local target
  and provides a stable public HTTPS `.ts.net` address to ordinary remote
  browsers on Windows, native Linux, Docker/NAS, QNAP/Synology, Unraid, macOS
  Docker Desktop, and FreeBSD/Podman.
- Added Windows Funnel states, setup guidance, sanitized diagnostics,
  notification-area status, and deterministic recovery, access-reset, and
  uninstall cleanup for the exact TautWeekly-owned route.
- Added a shared provider-neutral public-access controller with fixed typed
  operations, exact route ownership, legacy-state migration, public DNS and
  trusted-TLS verification, and fail-closed lifecycle cleanup.
- Added native Linux Funnel states and a root-owned, socket-activated fixed
  adapter while keeping Manager unprivileged.
- Added an opt-in container/NAS Funnel adapter that pins the official Tailscale
  runtime, uses userspace networking and separate root-only state, refuses auth
  keys/tokens, requires interactive console sign-in, and exposes only a
  UID-checked fixed-operation Unix socket to the non-root Manager.
- Added native Manager link previews with an optimized 1280×640 product card,
  concise Open Graph and large-card metadata, canonical Funnel HTTPS URLs, and
  explicit ICO, PNG, touch-icon, and manifest declarations.

### Changed

- All Funnel changes use only fixed typed enable/disable/verify operations and
  exact postcondition verification. Native packages use the official installed
  Tailscale CLI; container packages ship the declared pinned official binaries
  without installing or controlling Tailscale on the host.
- Kept every host recovery surface on loopback. Generic Compose, QNAP, macOS,
  and FreeBSD bind host port 8787 to `127.0.0.1`; the Unraid template replaces
  its generated broad Port entry with a fixed package-owned loopback publish.
  Setup/recovery may use an SSH local forward, while Funnel is the only public
  ordinary-browser ingress.
- Removed the maintained `compose.tailscale.yaml`, static Serve configuration,
  auth-key file, private URL input, and Funnel-off confirmation surfaces. Serve
  remains backend-only for exact legacy ownership detection and cleanup.
- Documented MagicDNS, HTTPS certificates, and a matching Funnel `nodeAttrs`
  target as host-admin prerequisites. Local `Funnel on` never substitutes for
  independent public DNS plus trusted-TLS verification.
- Installer updates preserve Manager configuration, password verification
  material, history, previews, and schedule, but first disable and verify the
  exact public route. Funnel stays off for explicit re-enable after update.
  Removal stops safely if the owned public route cannot be verified off.
- Windows dashboard launches now navigate the validated loopback URL even when
  an existing browser window is found, and add only internal build and one-use
  navigation tokens. This forces a new document request after an upgrade
  without accepting browser-supplied hosts, ports, commands, or arguments.

### Fixed

- Windows Setup now reads the validated current-user application registration
  through the native Windows Registry API and uses that folder directly for
  Update or Migrate instead of reopening the legacy folder picker, whose initial
  selection can be ignored on some Windows hosts. New and unresolved
  installations still require an explicit folder selection.
- Fixed the Windows public-publication probe so a fixed-resolver lookup cannot
  be intercepted by Tailscale's Windows NRPT/MagicDNS policy. The elevated
  helper now invokes the system `nslookup.exe` against `1.1.1.1`, accepts only
  bounded globally routable IPv4 answers, and retains the trusted-TLS
  postcondition before reporting **Active**.
- Stopped native Funnel from reporting **Active** when Tailscale had only saved
  the local route. Enable and Verify now require public DNS through a fixed
  public resolver plus a certificate-validated TLS handshake before the green
  active state appears. Missing public publication remains safely configured as
  a gold **Publication pending** state with the generated address available.
- Fixed the Windows Funnel card renderer so its public/private presentation is
  selected before transition state is evaluated. This prevents the upgraded
  dashboard from retaining the retired private Serve labels.
- Fixed Windows Setup updates of a running Manager so the elevated updater
  waits for its finite helper process without remaining attached to the
  successfully restarted Manager and blocking Setup completion.
- Windows updates now verify the candidate executable's exact version and that
  the restarted process itself owns the healthy loopback listener. If an older
  Manager from another installation still owns port 8788, Setup refuses with a
  clear recovery action instead of mistaking that process for update success.
- Fixed upgraded Windows installations with an owned legacy private Serve route
  incorrectly disabling both Funnel Enable and Verify. The migration state now
  preserves the passive installed-client signal so explicit conversion remains
  available after the Manager password lock is enabled.

### Security

- Public verification sends only the intended-public `.ts.net` hostname to the
  fixed `1.1.1.1` resolver and then connects only to a returned globally
  routable IPv4 address on TLS port 443. It rejects private, carrier-grade NAT,
  loopback, documentation, multicast, and other non-public answers; it never
  returns or stores DNS answers, certificate details, raw CLI output, or Manager
  data. It does not restart Tailscale or change DNS, firewall, or router state.
- Public Funnel enablement requires the Windows Manager password lock. Disabling
  that lock first disables and verifies the owned Funnel or refuses safely;
  changing the password preserves the route while revoking other sessions.
- Container Manager remains non-root and cannot read provider state, execute
  the provider CLI, access Docker/Podman, use a TUN device, or receive an auth
  key. Normal stop/update/recovery asks Manager to disable and verify its exact
  route before the isolated adapter exits.
- Manager remains loopback-bound. Public-host admission, secure/HttpOnly/
  SameSite cookies, same-origin and CSRF checks, authenticated sensitive
  endpoints, and secret-reveal boundaries remain enforced through Funnel.
- Funnel preview URLs are derived only from the already validated request Host;
  forwarded host/protocol headers cannot rewrite them. The public login shell
  remains marked no-index, and the social image contains no EXIF, XMP, or editor
  metadata.
- No new Internet login-attempt limiter was added in this delivery. A unique
  Manager password is strongly recommended because a public login page retains
  brute-force risk.

## [0.24.1] - 2026-08-31

### Fixed

- Preserved privacy-safe SMTP category, protocol stage, numeric response code,
  batch-fatal status, acceptance state, and failed-attempt count when TestEmail,
  single-test, or Manual Welcome delivery fails. Manager now validates and
  displays that evidence instead of collapsing every such failure to the
  generic SMTP handoff message.

## [0.24.0] - 2026-08-28

### Changed

- A dedicated, non-sending deleted-item cache refresh now inspects the
  current newsletter window for every production-eligible included user and
  selected movie/TV library. Manager starts it automatically after applicable
  configuration saves, and every maintained package exposes a `cache-refresh`
  recovery command.
- Cache refresh is independent of PreviewAll and does not require an
  owner/administrator preview user. Manager shows the cache step as blue
  **Running** immediately, then retains the automatic full local storage,
  bounds, manifest, backup, writability, and artwork-integrity result.
- Preview, TestEmail, and delivery paths can still refresh qualifying live
  entries opportunistically, but cache coverage no longer depends on which
  single user was selected for preview.
- Updated the Verify SMTP boundary to the outlined `mail_shield` symbol while
  preserving its existing local styling and interaction behavior.

### Fixed

- Fixed a multi-user coverage gap that could leave another included user's
  upcoming personal-history items uncached before deletion.
- Preserved existing nonblank titles, years, summaries, genres, ratings, and
  rating keys when a later live metadata response is sparse, while still
  allowing valid poster and hash refreshes.

### Security

- The independent refresh sends no email, changes no recipient or welcome
  state, and reports aggregate counts only. Manager and package diagnostics
  continue to exclude titles, GUIDs, rating keys, hashes, viewing metrics,
  recipient data, credentials, cache contents, and private paths.

## [0.23.3] - 2026-08-27

### Changed

- Unified completed-view qualification for personal movie/TV cards, Movie
  Trending, Hot New Release, Top Genre, and Binge Champion: a finished history
  row now requires definitive `watched_status=1` or
  `percent_complete >= WatchedPercent` (85 by default). Active sessions are
  excluded, while partial movie/episode playback remains included only in
  personal total watch time.
- Counted each grouped Tautulli history reference as one play instead of
  multiplying `group_count`. Separate qualifying references, including
  rewatches, still add another play and their qualified watch time.
- Ranked Movie Trending by plays, unique viewers, qualified watch time, then
  recency; ranked Hot New Release by plays, unique viewers, qualified watch
  time, then added date. Updated Hot New Release activity/fallback copy to name
  the configured server and use `Freshly added!` when no new movie qualifies.
- Replaced personal TV per-show duration with a singular/plural unique episode
  count while preserving the existing layout and show-level rating treatment.
- Added total plays before the nonzero movie and TV-show counts in the Binge
  Champion supporting line.

### Removed

- Retired the obsolete `MinimumEpisodeSeconds` setup/Manager control. Existing
  configuration keys are safely ignored.

## [0.23.2] - 2026-08-27

### Changed

- **Validate, save, and verify** now treats no-email PreviewAll as a cache
  prerequisite: cache health is **Waiting** while warm-up runs, then the full
  local storage, bounds, manifest, backup, writability, and artwork-integrity
  check runs automatically and remains available on Verify.
- Disabled cache verification now offers **Enable Cache Storage**, which opens
  and focuses the Config cache setting without changing or saving it. The
  manual cache check remains available as an optional later recheck.
- Cache verification cards, badges, text, borders, backgrounds, and glows now
  transition consistently, and the local cache boundary uses the outlined
  home-storage settings symbol.

### Fixed

- Healthy cache and storage cards no longer remain at Warning after a
  successful configuration workflow, and Warning is reserved for completed,
  actionable health findings.
- Full local verification still completes after a PreviewAll failure or
  cancellation and when preview start is skipped.

### Security

- Automatic and manual cache checks remain local: they send no email, perform
  no SMTP authentication, change no schedules, expose no private cache data,
  and remove their fixed-content writability probe.

## [0.23.1] - 2026-08-27

### Changed

- Added a privacy-safe deleted-item cache row to Manager Config status and an
  on-demand Verify check for configuration, initialization, manifest/backup
  health, writability, bounds, aggregate entry/artwork counts, expiry, and
  artwork hashes without returning media identifiers or private file data.
- Added `cache-status` launchers across Windows, Docker, native Linux, and
  FreeBSD with hidden exact-GUID hit/miss checks and a non-sensitive
  restart-persistence marker.

- Enabled cache-setting saves now start the existing no-email PreviewAll
  workflow when Manager has an unambiguous owner/administrator, making the
  required render-triggered warm-up visible while preserving manual fallback.
- Cache initialization now proves local writability, records bounded recovery
  state, and emits one aggregate capture/skip/hit/miss summary per render.

### Fixed

- Clarified that enabling the cache is not a whole-library or retroactive
  snapshot. Only qualifying items selected by a render while still live can be
  restored after deletion.

### Security

- Cache diagnostic responses and commands expose no paths, titles, GUIDs,
  rating keys, hashes, artwork, viewing metrics, recipients, credentials, or
  cache contents.

## [0.23.0] - 2026-08-26

### Added

- Published one shared multi-architecture OCI image at
  `ghcr.io/sparkmoxie/tautweekly` for Docker Desktop, generic Compose, NAS,
  QNAP, Unraid, FreeBSD/Podman, and compatible container systems. Explicit
  `desktop`, `server`, and `unraid` profiles preserve each host's proven
  network, storage, Manager, scheduling, health, and lifecycle behavior.
- Added the checksummed `TautWeekly-compose.yaml` no-clone server asset and
  converted `TautWeekly-mac-compose.yaml` into a transitional desktop-profile
  entrypoint to the same unified image.
- Added authenticated Manager reporting for the active runtime profile, unified
  image repository, recommended semver reference, immutable digest policy, and
  old-Mac-image migration state without granting Docker control to the web
  process.
- Added a canonical migration guide covering the v0.22.0 Mac-specific and
  NAS/generic images, named volumes, bind mounts, PUID/PGID/UMASK, networking,
  backups, health acceptance, interrupted recovery, rollback, and Manager
  credential persistence.

### Changed

- Consolidated the Mac and NAS release image workflows into one release-gated
  amd64/arm64 build with Buildx/QEMU boot coverage for every supported profile.
- Made release Compose and FreeBSD/Podman defaults full-semver pinned. Mutable
  minor, `latest`, and `edge` tags remain available where appropriate but
  are not the recommended automation reference.
- Made the canonical NAS application tree the shared container payload used by
  the Mac fallback archive, eliminating duplicated runtime implementations.
- Preserved Windows native packaging, native systemd Linux, the FreeBSD Podman
  beta route, and verified archive/local-build fallbacks where appropriate.
- Advanced the NAS and Mac container source baselines to 1.6.0.

### Compatibility

- Existing definitions without an explicit profile keep a bounded migration
  bridge: Mac package identities infer `desktop`, Unraid infers `unraid`,
  and supported NAS/generic identities infer `server`. Unknown or
  incompatible explicit combinations refuse startup with status 64.
- `ghcr.io/sparkmoxie/tautweekly-mac:0.22.0` remains pullable for rollback
  but receives no v0.23.0 or later tags. The transitional Mac Compose asset
  remains through v0.24.x and may be retired no earlier than v0.25.0 with
  release-note notice.
- Existing `/data` configuration, credentials, Manager pairing, schedules,
  state, history, output, backups, named volumes, bind mounts, and non-root
  ownership settings are preserved when users recreate against the same mount.

### Security

- Preserved the read-only filesystem, non-root identity and root refusal,
  capability drop, no-new-privileges, credential privacy, authenticated
  Manager, liveness-only health endpoint, host-owned updates, and 30-minute
  graceful-stop boundary across all unified profiles.

## [0.22.0] - 2026-08-26

### Added

- Published the first supported registry-first macOS / Docker Desktop image as
  `ghcr.io/sparkmoxie/tautweekly-mac` for both amd64 and arm64. Mac users can
  now install one service without cloning the repository or building locally.
- Added `TautWeekly-mac-compose.yaml` as a checksummed standalone release asset.
  It pins the full release semver, exposes the authenticated Manager only on
  Mac loopback by default, and persists private runtime state under `/data` in
  a named volume.
- Added a truthful `mac-docker-registry` Manager package profile with image,
  package, host-adapter, pull/recreate, digest-pin, and rollback guidance.

### Changed

- Made the container workflow reusable by the tag release workflow. A GitHub
  release now waits for successful NAS and Mac amd64/arm64 image publication,
  preventing release assets and advertised registry images from silently
  diverging.
- Documented full-semver and immutable manifest-digest pins for automation;
  mutable `latest`, minor, and `edge` tags are not recommended CI/CD pins.
- Extended container checks across Mac registry boot/health, authentication,
  version/profile metadata, bind ownership, named-volume ownership, recreation,
  persisted Manager bootstrap state, and the existing read-only/non-root
  boundary.
- Advanced the macOS source baseline to 1.5.0. Windows packaging and the native
  Linux/FreeBSD deployment choices are unchanged.

### Compatibility

- Existing Mac archive installations keep their `.env`, bind-mounted `data/`,
  verified local build, coordinated updater, health verification, and rollback
  path. Registry migration is optional and no private data is moved or deleted.
- The registry image keeps the established Mac Manager mode, embedded scheduler,
  health check, 30-minute delivery shutdown grace, `host.docker.internal`
  behavior, and hardened container settings.

## [0.21.4] - 2026-08-25

### Changed

- Refreshed the public GUI Preview from the current Manager frontend and release
  metadata, including package-specific startup, private-access, login, update,
  and refresh behavior with an isolated fictional API. Added a synchronization
  gate to prevent future frontend/version drift.
- Aligned both public newsletter previews with current watched markers, rating
  and summary typography, platform glyphs, and TV-only/quiet-week behavior.
  The email gallery now uses the same optimized local stock artwork.
- Simplified the repository README's newsletter summary to its main user-facing
  features, leaving detailed rendering rules in the reference documentation.
- Optimized all 32 bundled email GIFs at an explicitly approved 2x email
  display resolution, followed by lossless compression: 21,435,442 to
  2,704,515 bytes (87.38% smaller). Preserved all animation frames, timing,
  loops, transparency, first-frame fallback, and every email PNG byte.
- Added reproducible development-only optimization, complete asset metadata,
  mirror/archive integrity coverage, and a standing AGENTS policy requiring
  automatic lossless optimization of future local assets before deployment.
- Advanced source baselines to Windows 1.10.4, NAS/Docker 1.5.4, macOS 1.4.4,
  native Linux 1.3.4, and FreeBSD/Podman 1.2.4. Kept the accepted layout and
  v0.21.0 feature spotlight unchanged.

### Fixed

- Refresh every shipped persistent asset filename on a bundled-content
  transition or missing-marker migration, including customized stock files.
  Refresh the browser-preview mirror too; preserve custom-only filenames and
  unrelated runtime data without wiping directories.
- Preserve later edits across ordinary same-bundle restarts, restore missing
  assets, fail safely on linked paths, and leave failed copies retryable.
  Explicit repair restores all stock files. Verified the existing Windows
  updater's same-name overwrite, custom-only preservation, and rollback path.

## [0.21.3] - 2026-08-25

### Fixed

- Completed the 12px IMDb-number refinement in main TV cards: exact episode
  scores and show-level fallback scores now match the 12px footer rating text.
  Preserved weight 700, existing spacing, icon dimensions, rating selection,
  and all other main-card typography. v0.21.2 had only updated footer recaps.
- Extended existing renderer, visual, and package assertions to cover main TV
  IMDb numbers as well as footer ratings.
- Advanced source baselines to Windows 1.10.3, NAS/Docker 1.5.3, macOS 1.4.3,
  native Linux 1.3.3, and FreeBSD/Podman 1.2.3. All v0.21.2 footer values,
  marker placement, privacy, lifecycle behavior, and validation policy remain.

## [0.21.2] - 2026-08-25

### Fixed

- Displayed watched title circles at 16x16px with 8px left spacing only in
  main movie heroes and release cards. Kept centered, safely wrapping titles,
  accessible Watched labels, unchanged PNG bytes, no unwatched gap, and the
  existing 26x26px desktop poster shield. Removed all footer watched markers.
- Matched footer recap labels, titles, genres, ratings (including TV IMDb
  numbers), and TV watch durations at 12px; count numbers remain 18px/800/1.
  Footer Rotten Tomatoes icons now display at 16x16px.
- Normalized Watch Time, Binge Champion, Top Genre, and compact Trending
  headings to 12px/900 with 1.1px letter spacing, support to 12px/400/1.35,
  and all four primary values to exactly 27px/800/1.1, including Binge winner,
  non-winner, and standalone variants.
- Preserved the intended outer stats padding of 0px 20px 0px and TV label
  margin-bottom of -7px, artwork/card dimensions, and winner highlighting.
  Recipient logic, privacy, lifecycle behavior, and inbox preheaders are unchanged.
- Advanced source baselines to Windows 1.10.2, NAS/Docker 1.5.2, macOS 1.4.2,
  native Linux 1.3.2, and FreeBSD/Podman 1.2.2. Retained the v0.21.0 feature spotlight.

### Changed

- Documented proportionate risk-based validation and reuse of exact-tree CI
  evidence in the repository instructions, without changing required workflows.

## [0.21.1] - 2026-08-25

### Fixed

- Marked movie titles from only the recipient's qualifying all-time Tautulli
  history, including watches outside the weekly window. Exact recipient ID,
  movie type, selected-library scope, and rating-key/GUID identity are required;
  another user's activity and global popularity never mark a movie.
- Used definitive `watched_status=1` or the configured `WatchedPercent`
  threshold, explicitly excluded active sessions, and retained full historical
  pagination. Partial Tautulli watched grades do not qualify by themselves.
- Added the supplied transparent desktop poster shield and title-circle assets
  across maintained renderers and packages. Circular marks use uniform 6px
  spacing and vertical centering, both assets expose `title="Watched"` and
  accessible text, and unwatched movies leave no gap. TV is unchanged.
- Kept the same recipient state across all preview, test, welcome, scheduled,
  and confirmed manual delivery paths, with local preview paths, conditional
  CID/MIME resources, plain-text status, and an Outlook desktop fallback.
- Verified the consumed Tautulli v2.18.0 history and metadata contracts with
  deterministic partial-status, pagination, privacy, and HTTP-error fixtures.
  Preserved dynamic Trending shelves/preheaders, Top Genre, Binge Champion
  typography/privacy, and the v0.21.0 Quickstart feature spotlight.
- Advanced maintained package source baselines to Windows 1.10.1, NAS/Docker
  1.5.1, macOS 1.4.1, native Linux 1.3.1, and FreeBSD/Podman 1.2.1.

## [0.21.0] - 2026-08-25

### Added

- Added a privacy-preserving, server-wide **TOP GENRE THIS WEEK** footer for
  Trending-hero weeks. It aggregates only qualifying movie activity in the
  configured report window and included libraries, resolves each distinct
  movie once, and uses only the first genre returned by Plex metadata.
- Added case-insensitive genre normalization, including `Science Fiction`,
  `Sci-fi`, `Sci Fi`, and `SciFi` aliases, plus twelve validated animated genre
  assets. Unsupported winners and weeks without usable genre metadata render
  the existing neutral movie animation instead of a broken image.
- Added deterministic coverage for first-genre extraction, aliases, watch-time
  aggregation, unique movie counts, tie-breaking, missing metadata, neutral
  fallbacks, complementary hero/footer states, dynamic preview text, packaged
  GIF integrity, and all maintained renderer mirrors.

### Changed

- Made the hero and full-width footer complementary: **HOT NEW RELEASE** pairs
  with the existing **TRENDING THIS WEEK** footer, while a **TRENDING THIS
  WEEK** hero pairs with **TOP GENRE THIS WEEK**. Trending is never duplicated.
- Refined Trending weeks. When new TV exists, the hero is followed by up to
  four different recent movies and up to four new TV series; the count line and
  email preview text read `0 NEW MOVIES • X TV TITLE(S)`. Without new TV, up to
  four recent movies and four recent TV series strictly newer than one month
  appear under Recent Releases; the shared count/preheader reads
  `1 TRENDING MOVIE • X RECENT MOVIE RELEASE(S)` when a real hero is available.
- Ranked Top Genre by total qualified watch time, then unique movie count, then
  qualifying play count, and finally normalized genre name. The card reports
  only aggregate duration and unique movies, never a viewer or recipient.
- Normalized Binge Champion breakdown typography and the Top Genre duration
  line to the same supporting font size, weight, line height, and color used by
  the personal total-watch-time supporting text. Winner eligibility, privacy,
  treatment, and Manual Welcome omission remain unchanged.
- Advanced maintained package source baselines to Windows 1.10.0, NAS/Docker
  1.5.0, macOS 1.4.0, native Linux 1.3.0, and FreeBSD/Podman 1.2.0.

## [0.20.10] - 2026-08-25

### Fixed

- Unified Preview, Preview All, Send Test, Send Test All, and one-off welcome
  rendering around one real active-or-quiet release payload. Quiet weeks now
  feature a metadata-rich movie-only Trending hero when authentic server-wide
  history supplies one, up to four other recent movies, and up to four TV titles
  strictly newer than one calendar month. When present, the hero is not repeated
  in Latest Releases or the server-wide footer.
- Preserved authentic personal-stat presentation and metadata fallbacks:
  movie rows keep poster, genres, and provider-labelled Rotten Tomatoes scores;
  TV rows keep poster, watch duration, and IMDb when available; recipient
  platform icons remain intact and previews never synthesize watch activity.
- Made Manager header **Refresh** repeat the saved-revision LAN-only Tautulli
  choices lookup and an eligible stable update check after local status, reset
  cooldown UI automatically, serialize repeated clicks, retain discovery
  failures, and avoid starting preview generation.

## [0.20.9] - 2026-08-25

### Fixed

- Restored content-rich **Trending** heroes when Tautulli returns sparse
  secondary metadata, preserving the source title's genres, year, summary, and
  provider-labelled critic/audience ratings.
- Made quiet weeks enumerate real active movie/TV libraries when no explicit
  library filter is configured, so **Latest Releases** still shows up to four
  recent movies and four recent TV titles instead of trusting an empty global
  hub.
- Removed fictional watch time and sample titles from **Preview All** and
  **Send Test All**; every state now uses only the selected recipient's real
  activity while retaining the existing stat layout and platform icons.

## [0.20.8] - 2026-08-25

### Fixed

- Restored distinct populated lifecycle states in **Preview All** and **Send Test
  All** when the selected recipient has no report-window activity, using
  sanitized scenario-only statistics while ordinary Preview and Send Test keep
  using the recipient's real state.
- Kept the **Trending** hero in the quiet-week **Latest Releases** shelves, capped
  at four movies and four TV titles, so newsletters still contain recent library
  choices when no titles were added during the report window.

## [0.20.7] - 2026-08-24

### Fixed

- Kept Preview and Send Test all-state layouts authentic by using only the
  selected recipient's real report-window statistics, including true zero-history
  states instead of fabricated viewing rows.
- Added an exact-recipient Tautulli Last Platform fallback when report-window
  activity has no recognized platform, and changed all embedded 21px platform
  glyphs to white without exposing platform details in logs or Manager history.
- Made Manager header **Refresh** invoke the same manual update check as **Check
  now** even when an unrelated authenticated local-status request fails.

## [0.20.6] - 2026-08-23

### Fixed

- Made the main header **Refresh** run the same stable-release lookup and visible
  result handling as Settings **Check now** after local status refresh, instead
  of waiting for the background release cache to become stale.

## [0.20.5] - 2026-08-23

### Changed

- Show the selected recipient's most-played recognized platform icon directly
  after the weekly heading, using most-recent activity to break play-count ties.
  Icons remain local and embedded; blank, unknown, missing, or mismatched-user
  platform data is omitted without leaving a gap.

## [0.20.4] - 2026-08-22

### Fixed

- Made the shared Manager header **Refresh** render local and cached status
  first, then start an eligible stale or missing stable-release check in the
  background without delaying or failing the local refresh. Repeated clicks
  reuse the existing cache, backoff, and active-check guards.

## [0.20.3] - 2026-08-21

### Changed

- Kept the full-width TV watched card at two titles per row on mobile while
  Movies watched continues to stack one title per mobile row.

### Fixed

- Prevented synthetic personal-stat poster sizing from stretching nested IMDb
  badges, preserving the production 28-by-14 badge treatment in GUI previews.

## [0.20.2] - 2026-08-21

### Fixed

- Refreshed the shared Manager preview inventory after a successful manual
  generation and reloaded the selected state's new artifact without a click or
  browser refresh, while preserving the selected scenario when available.

## [0.20.1] - 2026-08-21

### Changed

- Clarified `origin-host-mismatch` recovery in the shared Manager and macOS
  guidance: reverse proxies must preserve the original public Host, and a
  Cloudflare Tunnel route must not rewrite it with `httpHostHeader`.

### Fixed

- Regression-locked the custom text card toggle so disabling the card hides it
  without clearing its saved title, GIF, subheading, body, border color, or
  opacity; re-enabling restores the retained content.

## [0.20.0] - 2026-08-21

### Added

- Added uncapped personal movie and TV statistics so every qualifying unique
  title in the reporting window appears in HTML email, local previews, and
  plain text with its eligible poster, metadata, and rating treatment.

### Changed

- Moved Movies watched and TV shows watched into separate full-width cards.
  Each card pairs two titles per desktop row and stacks one title per mobile
  row, while preserving watch-time-then-plays ranking and one-sided/empty
  states.
- Kept personal total watch time and Binge Champion in equal-height compact
  cards independent of personal title count. The personal card now uses the
  `YOU CLOCKED` eyebrow and `total watch time` label; its all-playback duration
  remains intentionally distinct from qualifying Binge Champion duration.
- Expanded the network-blocked synthetic GUI preview with uncapped, uneven,
  winner/non-winner, rated/unrated, desktop, and mobile personal-stat fixtures.

### Fixed

- Stopped personal rows beyond the former four-title limit from missing
  metadata enrichment, posters, ratings, HTML output, or plain-text output.
- Restored production-equivalent Rotten Tomatoes and IMDb treatment inside
  synthetic personal movie and TV rows without inventing unavailable ratings.

## [0.19.2] - 2026-08-21

### Changed

- Added passive authenticated dashboard polling so scheduled and manually
  started production delivery state updates without pressing Refresh on
  Windows, NAS/Docker, macOS Docker, native Linux, and FreeBSD.
- Added conservative gold ready-state glows to valid upcoming-run and
  generated-preview timeline cards, plus a green successful-run glow to the
  latest application-attempt card.

### Fixed

- Replaced Windows Task Scheduler's active `267009` result with an explicit
  blue `Running` delivery state and prevented an older successful renderer
  result from masking a newer active run.
- Made the Delivery card, badge, and mail icon transition through a blue
  running pulse and return automatically to the existing green SMTP-accepted
  state when sanitized completion evidence appears. Reduced-motion settings
  retain the state colors without animation.
- Kept long container and native-service deliveries visibly running after the
  scheduler heartbeat pauses for the synchronous send. A fresh package
  supervisor heartbeat now confirms that the scheduler's persistent running
  state is live rather than stale.

## [0.19.1] - 2026-08-21

### Fixed

- Restored production `SendAll` eligibility for active Tautulli users with an
  email address when the legacy upstream `do_notify` notification-agent flag
  is disabled. Explicit user/email exclusions, inactive or deleted users, and
  missing addresses remain hard skips in manual and scheduled delivery.
- Made the shared manual/scheduled `SendAll` path synchronously refresh
  Tautulli's Plex user list exactly once before reading the live roster. A new
  eligible user no longer requires a Manager discovery refresh; an unconfirmed
  upstream refresh fails before SMTP with the fixed sanitized
  `user-roster-refresh-failed` category.
- Made an all-skipped production run fail with a fixed
  `no-eligible-recipients` category instead of appearing SMTP-accepted, and
  added sanitized aggregate skip counts to the Manager status and operation
  views without retaining recipient identities or addresses.
- Stopped a production batch after the first authentication failure,
  temporary provider/service response, batch-wide rejection, transport
  failure, or unknown final-DATA acceptance instead of reconnecting for every
  remaining recipient. Address/mailbox-specific RCPT rejections remain
  per-recipient,
  and configured spacing now also applies after those failed attempts.
- Fixed first-run access-roster creation for numeric Tautulli user IDs under
  Windows PowerShell 5.1, which could stop a first production send before
  recipient classification. The explicit member form is synchronized across
  Windows, macOS, NAS/Docker, native Linux, and FreeBSD renderer packages.
- Made supported macOS and NAS/Docker restart commands force-recreate the app
  service so changed `.env` values are applied, and documented the equivalent
  recreate requirement for vendor-managed Compose interfaces.
- Applied documented exact DNS host allowlisting to the native Linux managed
  service path while preserving same-origin, scheme, authentication, CSRF,
  and secure-cookie enforcement.

### Changed

- Clarified in Config that checked user boxes are delivery exclusions and that
  Tautulli notification-agent settings do not control TautWeekly delivery.
  Clarified that **Repeat this Tautulli lookup** updates Manager choices only;
  it is not required to refresh production recipients.
- Raised new-install and missing-value cadence defaults to 30 seconds for
  production recipients and 10 seconds for controlled Test All messages.
  Existing explicit values are preserved; operators should avoid running Test
  All or manual production delivery near the scheduled batch and leave the
  provider quiet after a temporary account lock.
- Replaced opaque origin rejection text with fixed, sanitized recovery
  guidance and support codes, and tightened the macOS reverse-proxy workflow
  around exact hostnames, original `Host` preservation, secure cookies, and
  container recreation.

### Security

- Kept delivery diagnostics count-only and allowlisted, retained every explicit
  exclusion and access-state boundary, and continued to ignore untrusted
  `Forwarded` and `X-Forwarded-*` headers.
- Added only fixed SMTP category, stage, numeric response code/class,
  batch-fatal, and acceptance-state evidence. Provider response text,
  accounts, hosts, recipients, and credentials remain excluded.

## [0.19.0] - 2026-08-20

### Added

- Added an optional in-field title GIF selector to the custom text card across
  Windows, NAS/Docker, macOS, native Linux, and FreeBSD packages. The six
  allowlisted choices—Celebrate, Construction, Rocket, Tickets, Warning, and
  Alert—render beside the uppercase title in all six newsletter states and as
  a deterministic selected-only 18×18 CID asset in delivered email.

### Changed

- Made configuration backups a newest-first rolling set of 10 across Manager
  and expert/recovery writers, including safe startup normalization of legacy
  timestamped backups and pre-restore safety backups.
- Changed recent completed Manager operations and sanitized configuration
  diagnostics to count-only FIFO retention of the newest 20 records. Existing
  excess is normalized at startup; record age no longer removes an otherwise
  retained entry.

### Security

- Kept title text separate from the selected asset ID, normalized missing or
  unsafe stored IDs to no selection, rejected unsafe submissions, and mapped
  only fixed local GIF filenames, MIME types, and CIDs without runtime network
  or Google Fonts dependencies.

## [0.18.3] - 2026-08-20

### Fixed

- Preserved a fixed, allowlisted renderer failure category in Manager operation
  records across Windows, NAS/Docker, macOS, native Linux, and FreeBSD. Preview
  and delivery failures now distinguish configuration, Tautulli, Direct Plex,
  asset, HTML-render, preview-output, SMTP, and package-lock stages without
  retaining raw process output or private values.
- Made Manager-triggered service-package operations attempt the shared renderer
  lock without waiting, so a scheduled delivery, update, or terminal operation
  reports **Operation busy** immediately instead of failing generically after
  30 seconds. Existing bounded terminal, scheduler, update, and shutdown waits
  remain unchanged.
- Replaced the opaque preview-failure sentence with category-specific recovery
  guidance while keeping the sanitized support code and sandboxed preview
  boundary.

## [0.18.2] - 2026-08-20

### Fixed

- Made configuration saves rerun only the checks affected by normalized field
  changes. Presentation, newsletter-content, and library changes now preserve
  sanitized discovery and connection evidence while regenerating previews;
  cache, email, schedule, and delivery-delay-only saves run no connection
  checks or preview work, and exact no-op saves create no backup or setup work.
- Kept the Config workflow as the primary automatic validation path while
  retaining **Verify** for detailed manual diagnostics. A successful manual
  Refresh or Verify can now resume a pending preview without another save, and
  failed discovery reports that preview generation was skipped instead of
  incorrectly reporting a missing owner.
- Canonicalized same-origin authorities for DNS case, one trailing dot, and
  equivalent omitted/default ports while preserving exact Host, scheme, CSRF,
  authentication, HTTPS, and Tailscale boundaries. Rejections now return
  sanitized support codes and continue to ignore forwarding headers.

## [0.18.1] - 2026-08-20

### Changed

- Clarified the capability-aware application and package status card by placing
  **Latest stable** beside **Manager build**, renaming **Release layers** to
  **Release alignment**, and removing the deprecated **Package baseline**
  field from the production Manager and live synthetic GUI Preview.
- Made **Host adapter** conditional on an applicable reported contract and
  reflowed the status grid across desktop and mobile widths without changing
  update classification, checks, caching, indicators, or installation
  boundaries.

## [0.18.0] - 2026-08-20

### Added

- Added an optional custom text card before the newsletter release-count and
  date block across Windows, NAS/Docker, macOS, native Linux, and FreeBSD
  packages. The card supports an optional gold title, optional white
  subheading, required plain-text body, and configurable border color and
  opacity, with matching HTML, plain-text, preview, and welcome-state output.

### Changed

- Added a card-level attention glow whenever capability-aware update status is
  not **Current**, while retaining the existing green Current treatment and
  showing the purple header update SVG only after a successful validated check
  finds a newer running-application release.
- Reused successful update-check results for five minutes across all maintained
  package kinds while preserving the 24-hour authenticated-entry refresh,
  explicit **Check now** control, short failure retry backoff, and offline-safe
  Manager navigation and health behavior.

### Fixed

- Removed the phantom grey Config and Settings rectangles by making incomplete
  separator-backed grid rows span the intended black surface consistently.
- Prevented validation, save, and verification when the custom card is enabled
  without its required body text, with matching accessible client and server
  validation.

## [0.17.1] - 2026-08-18

### Fixed

- Changed the validated **Update available** status chip from the generic blue
  checking state to the agreed violet/purple treatment with a subtle purple
  pulse. The purple header update icon beside the Manager lock is unchanged,
  and active update checks remain blue so discovery and availability are
  visually distinct.

## [0.17.0] - 2026-08-18

### Added

- Added optional Windows Tailscale Serve controls below Browser access, with a
  narrowly elevated UAC helper, exact route ownership and hostname enforcement,
  private HTTPS cookie/origin hardening, conflict-safe recovery, and no Funnel
  or router exposure. The existing Windows Manager password remains optional.
- Added the same optional private-access card to native Linux, macOS Docker,
  FreeBSD Podman, Compose/NAS, Unraid, QNAP, and compatible Docker packages.
  Native Linux uses a one-time root-owned fixed-action socket adapter while
  host-managed packages save only one exact externally created private
  `.ts.net` address and keep mandatory Manager authentication.
- Added optional userspace Tailscale Compose sidecars for generic NAS/Docker and
  macOS Docker hosts without a supported native client. The sidecars use a
  file-backed one-off key, persistent node state, a fixed private Serve config,
  and no Docker socket, TUN device, added capability, or Funnel configuration.
- Added an active-route pulse around the full Tailscale card, with a static
  reduced-motion treatment.

### Fixed

- Returned first-time Tailscale HTTPS approval links to Manager without waiting
  indefinitely for the provider CLI, and made Verify and enable failures visibly
  confirm their result in the global status surface.
- Warned explicitly that Tailscale's first-use consent page can preselect Funnel
  and requires HTTPS certificates only with Funnel turned off.

## [0.16.0] - 2026-08-18

### Added

- Added an accessible, passive update-available indicator beside the Manager
  access lock across every supported package. It appears only after a validated
  stable release is unequivocally newer than the running application and links
  directly to **Settings > Application and package status**.

### Changed

- Authenticated Manager entry now renders cached update state immediately and
  performs one non-blocking refresh only when the cache is absent or at least
  24 hours stale and the existing retry backoff permits it. Login, health,
  ordinary navigation, and offline operation remain independent of release
  checks.

## [0.15.2] - 2026-08-18

### Changed

- Consolidated Manager build, package baseline, platform, edition, and release
  layer health into the existing application and package status surface without
  repeating identical release versions.

### Fixed

- Made the Windows verified-update view reconnect to the restarted Manager and
  advance to current automatically instead of waiting for a manual refresh.
- Made generated configuration switches fully clickable and preserved explicit
  `false` values through the shared Manager API on every shipped package type.

## [0.15.1] - 2026-08-18

### Fixed

- Restored macOS Docker Desktop Manager previews, test delivery, and manual
  delivery by honoring the Manager's private operation snapshot and structured
  result contract in the Mac runtime package.

## [0.15.0] - 2026-08-18

### Added

- Added a capability-aware **Settings > Updates** card and authenticated update
  API across Windows, native Linux, macOS Docker Desktop, FreeBSD Podman,
  Compose/NAS, QNAP, Unraid, and compatible Docker hosts. It distinguishes
  application, package, image, and host-adapter versions, performs explicit
  bounded stable-release checks with sanitized persistent results and backoff,
  and keeps ordinary Manager health offline-capable.
- Integrated Windows-only confirmed installation with the existing verified,
  elevated updater. Every host-managed package instead reports exact native
  guidance without a Docker socket, root web process, privileged helper, or
  browser-controlled command.

### Changed

- Advanced container host-adapter identity to API 3, embedded release package
  versions in staged Compose manifests, and documented Settings as the primary
  update-status source while retaining each platform's existing update owner.

## [0.14.1] - 2026-08-17

### Changed

- Made NAS/QNAP Compose, macOS Docker Desktop, native Linux, and FreeBSD Podman
  update commands download and verify the matching stable host package and its
  internal release-file manifest before advancing package adapters and runtime;
  private configuration/data are preserved and container packages restore host
  files together with the prior image on failure.
- Added an Unraid host-adapter compatibility marker and documented saved-template
  migration so current hardening, stop timeout, and Manager settings advance
  with Apps-owned image updates.
- Added authenticated, CSRF-protected, individually confirmed permanent deletion
  for Manager configuration backups across all GUI-capable packages, while
  keeping the live configuration untouched.

- Added a distinct authenticated macOS Docker Desktop Manager profile and
  GUI-first installer flow, with Mac-specific setup, schedule, lifecycle,
  update, recovery, and loopback-access language.
- Added amd64 and arm64 Manager binaries to the Mac archive, a hardened
  read-only container contract, authenticated liveness checks, and a 30-minute
  graceful delivery drain during Docker Desktop stop/restart.
- Made the authenticated Manager the explicit setup source across the NAS,
  Docker, native Linux, and FreeBSD Podman documentation and shipped fallback
  landing pages; terminal configuration tools are now labelled as expert or
  recovery paths.
- Added a FreeBSD Podman Manager adapter with explicit bootstrap and narrow
  access recovery commands, loopback/reverse-proxy settings, hardened
  container flags, and a 30-minute graceful delivery drain for rc.d stops.
- Replaced the retired console-first NAS Quickstart body with a canonical,
  accessible redirect to the current Manager installation, update, backup,
  rollback, recovery, and uninstall guide.

### Fixed

- Fixed v0.14-era NAS and FreeBSD host wrappers that could omit
  `manager-bootstrap`, and prevented image-only updates from leaving supported
  release-archive host adapters behind the running Manager.
- Removed stale NAS and FreeBSD text that described the v0.14 container
  endpoint as an unauthenticated or read-only preview server.
- Made shared setup and verification fallbacks return administrators to the
  Manager instead of printing Unraid-specific next steps on other hosts.
- Preserved explicit Unix executable modes in NAS, macOS Docker, Linux, and
  FreeBSD ZIP/TAR packages even when artifacts are built on Windows, with
  release contracts covering every launcher and packaged Manager binary.
- Made macOS Docker UID/GID remapping compatible with its read-only image by
  dropping directly to the configured numeric identity instead of mutating
  the container account database during startup.
- Routed NAS, FreeBSD-container, and macOS Docker PowerShell home and XDG state
  into the bounded temporary filesystem so scheduler and recovery commands
  remain operable without writing to the immutable image.

## [0.14.0] - 2026-08-16

### Added

- Added an authenticated, capability-aware NAS Manager for Unraid Apps, QNAP
  Container Station, Linux NAS appliances, and compatible Docker hosts, with
  persistent bootstrap/recovery state, embedded schedule controls, and
  sanitized operation results.
- Added hardened generic and QNAP Compose definitions, an updated Unraid
  Community Apps template, multi-architecture Manager image builds, and an
  exact NAS lifecycle and recovery guide.
- Added authenticated native Linux Manager binaries for amd64 and arm64,
  architecture-aware installation, loopback-first systemd service access,
  explicit bootstrap/recovery commands, and a Linux-specific preview adapter.

### Changed

- Replaced the unauthenticated NAS preview server and console-first setup with
  the shared Manager core, while suppressing Windows tray, sign-in startup,
  Scheduled Task, browser-launch, and installer/update language on NAS.
- Made the NAS container use an immutable root filesystem, an explicit
  persistent `/data` boundary, numeric UID/GID execution, minimal capabilities,
  authenticated LAN access, and graceful delivery-aware shutdown.
- Made native Linux setup GUI-first while preserving the `tautweekly` wrapper
  as an expert/recovery path, and documented checksum-verified updates, backup,
  rollback, reinstall, recovery, and data-preserving uninstall behavior.

### Fixed

- Included the Manager executable required by the native Linux systemd service
  and selected the correct packaged architecture during install and upgrade.
- Made shared verification and setup helpers distinguish a native Linux service
  from a container, accept host-local Plex/Tautulli endpoints, and probe the
  configured Linux preview listener instead of the container-only port.

### Security

- Required a one-time pairing token and user-chosen Manager password on NAS,
  with PBKDF2 credential storage, bounded sessions, CSRF protection, login
  throttling, Host-header validation, secure-proxy cookie mode, and narrow
  access recovery that preserves newsletter data.
- Required the same protected first-run and session boundary on native Linux,
  with a loopback default, explicit reverse-proxy host policy, secure-cookie
  mode, and bootstrap-token redaction from installer and service logs.

## [0.13.0] - 2026-08-16

### Added

- Added a native Windows notification-area experience for the interactive
  Manager. The TautWeekly artwork stays visible while the Manager is running,
  left-click opens the existing Dashboard, and the native context menu reports
  **Healthy**, **Needs attention**, or **Failed** with a colored icon plus an
  explicit **Exit TautWeekly for Plex** action. Selecting the status row also
  focuses the existing Dashboard, opening one only when needed.
- Added current-user **Start Manager when I sign in** and dependent **Open
  Dashboard after sign-in** controls under Settings, with sanitized status,
  diagnostics, and exact startup-entry ownership.
- Added a configurable newsletter button label and custom HTTP/HTTPS destination
  under the Manager's Identity settings. Existing configurations keep the Plex
  web app destination and **Open Plex** label by default.

### Changed

- Enforced one Windows Manager per installation and local address. A repeated
  launch reuses the ready Manager and opens its Dashboard instead of starting a
  second server or tray process.
- Made Manager exit and installer upgrades request graceful control-surface
  shutdown, while preserving the independent weekly Scheduled Task and
  restart-safe reconciliation for an already-running non-cancellable delivery.
- Reconciled owned per-user startup entries across installer update, portable
  migration, and path changes, and removed them during uninstall so private
  data can remain without leaving a stale sign-in command.

### Fixed

- Made generic-poster and deleted-item-cache fingerprinting independent of the
  optional PowerShell `Get-FileHash` cmdlet, preserving exact artwork recovery
  across supported Windows and container runtimes.

## [0.12.7] - 2026-08-15

### Fixed

- Resolved the per-user Windows Start-menu folder through the native Shell API
  instead of a PowerShell COM lookup. If Windows does not return a usable
  known-folder path, Setup now uses a bounded per-user `APPDATA`/`USERPROFILE`
  fallback so an otherwise valid update can finish without touching private
  configuration or history.
- Recovered an existing installer-owned application folder from its registered
  uninstaller or icon when the primary Windows `InstallLocation` value is
  missing or stale, so updates preselect the current folder without scanning
  arbitrary user directories.

## [0.12.6] - 2026-08-15

### Changed

- Distinguished unsaved delivery choices from persisted exclusions in the
  guided Tautulli roster. Checkbox changes now show a gold **selected** count;
  after validation and save, the same count is reported as soft-red
  **excluded** state.

### Fixed

- Recovered legacy `ExcludedEmails` matches when a Tautulli installation omits
  email fields from `get_users`. The Manager now uses a bounded
  `get_users_table` compatibility lookup only when legacy rules remain
  unmatched, then keeps matched users visible, checked, and grouped first.
- Prevented upgraded Manager pages from retaining stale embedded JavaScript or
  styles by serving the local application shell and assets with `no-store`.

### Security

- Kept legacy email matching entirely server-side during the compatibility
  lookup. Email addresses, API keys, and raw Tautulli responses are not returned
  to the browser, cached in discovery state, or written to diagnostics.

## [0.12.5] - 2026-08-14

### Changed

- Summarized the guided Tautulli roster as **found ● excluded**, with the
  effective exclusion count covering both configured user IDs and users matched
  privately by retained legacy email rules.
- Kept legacy email-rule matches visibly checked at the top of the delivery
  roster while preserving the underlying email rule as the source of truth.

### Fixed

- Displayed Manual Welcome and all-recipient production sends only in the
  dedicated **Current or latest manual send** card instead of duplicating the
  same operation in the generic current-run card.
- Started the installed Manager directly after Setup's completion dialog closes
  and prevented hidden Windows child processes from inheriting Setup handles.
  The completed installer now exits without retaining its downloaded EXE.
- Added fictional loopback browser fixtures and regression coverage for 78
  discovered users, two retained exclusions, the single manual-send status
  surface, and the Windows handle-inheritance boundary.

## [0.12.4] - 2026-08-14

### Changed

- Opened every Tautulli user selector from the full field surface so users can
  immediately type to search or scroll the same bounded, styled result list.
- Grouped configured ID and legacy email delivery exclusions first in the
  guided roster. Existing email-rule matches remain visibly checked and are
  identified without exposing an email address.
- Embedded the approved TautWeekly popcorn artwork and `TautWeekly for Plex`
  product identity in the Windows Manager executable while retaining its
  compatibility-sensitive installed filename.

### Fixed

- Routed links in the generated preview index back through the Manager's
  authenticated preview selector. **Open preview** now replaces the current
  preview in place and highlights the matching scenario instead of navigating
  to an invalid nested or separate browser target.
- Handed Manager startup to a detached post-exit process after Windows Setup's
  completion dialog closes. Setup now terminates and releases the downloaded
  EXE before the Manager and browser are opened.
- Added installer lifecycle coverage that waits for the real Setup process to
  exit, moves the exact candidate EXE to prove its file lock is released, and
  verifies the installed Manager's identity and extractable application icon.

## [0.12.3] - 2026-08-14

### Changed

- Styled the production Manual Welcome user selector with the same bounded
  control geometry used by preview generation and TestEmail delivery.
- Displayed retained safe-save results on Dashboard and Verify when a newer
  manual diagnostic result is not available for the saved configuration.

### Fixed

- Reconciled legacy `ExcludedEmails` rules with Tautulli's guided delivery
  exclusions. Matching users now remain visibly excluded without converting,
  exposing, or discarding the original email rules; unmatched rules are
  counted so they cannot disappear silently.
- Kept legacy email exclusions protected when ID-based delivery choices are
  edited, preventing a visually unchecked user from remaining excluded by a
  hidden legacy rule.
- Restored consistent sizing, borders, typography, and responsive containment
  across the production newsletter and Tautulli user selectors.
- Kept the Windows Setup completion dialog in the foreground and delayed the
  Manager/browser launch until that dialog is dismissed, preventing a hidden
  Setup process from retaining the downloaded EXE after installation.

### Security

- Legacy exclusion matching remains server-side. The Manager returns and
  caches only a per-user match flag and bounded aggregate counts; email
  addresses are never returned to the browser or stored in discovery state.

## [0.12.2] - 2026-08-14

### Changed

- Styled the production-newsletter selector with the same bounded chevron and
  state transition used by the Manager's Tautulli user selectors.

### Fixed

- Retained sanitized Tautulli, direct Plex, and SMTP validation evidence for
  the current saved configuration so Dashboard and Verify remain synchronized
  after validation, refresh, or a Manager restart.
- Refreshed Manager runtime, Config status, and Integration cards together when
  **Validate, save, and verify** finishes. Manual Verify actions remain optional
  targeted reruns for diagnosing an individual failure.
- Cleared retained verification evidence whenever the configuration revision
  changes or a backup is restored, preventing stale successful checks from
  appearing against different settings.

## [0.12.1] - 2026-08-14

### Added

- Added a guarded **Manual Welcome** choice to the Windows Manager's production
  delivery card. It sends the renderer's existing one-user welcome state or,
  when **All eligible recipients** is selected, retains the established full
  production-send behavior.
- Added guided legacy direct-Plex recovery status without returning tokens to
  the browser. The Windows Manager can use a same-account Plex registry token
  or `PLEX_TOKEN` at runtime and can use the Plex URL reported by Tautulli.

### Changed

- Documented a shared migration contract for future Windows, container, Linux,
  macOS, NAS, and FreeBSD Manager packages: preserve private configuration,
  distinguish absent legacy fields from explicit clears, recover only from
  trusted platform sources, and never silently copy recovered secrets.
- Added a focused Config notice when an older configuration never contained
  the newer direct-Plex fields, with same-computer URL guidance and a direct
  path to the relevant controls.

### Fixed

- Normalized absent direct-Plex keys only after an explicit validated save,
  preserving the legacy configuration and its timestamped backup instead of
  treating updater-era omissions as lost values.
- Allowed direct-Plex verification to use safe runtime recovery sources while
  retaining the existing private/loopback destination checks and precise
  skipped-state diagnostics when recovery is unavailable.

### Security

- Runtime-recovered Plex tokens remain process-local: they are not copied to
  `config.json`, returned by the API, logged, or exposed to the browser.
- Manual Welcome accepts only a validated numeric Tautulli user ID for the
  current run. That ID is cleared after start and is not retained in Manager
  operation history or API responses.

## [0.12.0] - 2026-08-14

### Added

- Added a guarded **Send this week's newsletter now** control to the Windows
  Manager. It invokes only the packaged `SendAll` renderer mode, requires a
  separate real-recipient confirmation, and retains a dedicated aggregate
  result card after the operation starts.
- Added explicit sanitized connection diagnostics that identify Tautulli,
  direct Plex, or combined verification failures without retaining URLs,
  addresses, credentials, identities, upstream responses, or raw process
  output.

### Changed

- Ordered and labelled generated previews by scenario: Index, Manual Welcome,
  New User - No History, New User - With History, Normal Newsletter,
  Established Quiet, and Established Warnings.
- Treated an omitted optional direct Plex connection as a successful Tautulli
  verification with a clear informational note instead of a generic warning.
- Documented the Manager as the normal one-off production-send interface and
  retained the numbered BAT/PowerShell senders as expert break/fix fallbacks.

### Fixed

- Restored the trusted-local browser session automatically after a Manager
  restart or update when the optional password lock is disabled. Protected
  actions retry once with a fresh CSRF token instead of displaying a stale
  `Authentication is required` error or requiring a manual page refresh.
- Preserved valid partial `SendAll` renderer results even when PowerShell exits
  with its documented partial-delivery status, so accepted, skipped, and failed
  counts remain visible with a sanitized support code.

### Security

- The browser cannot choose an executable, script, command, recipient, or user
  for a production send. The Manager supplies a private configuration snapshot
  to the fixed packaged renderer and discards process output.
- Manual production history contains only operation type, timestamps, package
  version, aggregate SMTP accepted/skipped/failed counts, exit status, and a
  sanitized support code. SMTP acceptance is not presented as inbox delivery.

## [0.11.1] - 2026-08-14

### Changed

- Made the Start Menu launcher the authoritative post-install entry point.
  Setup still adds the Desktop launcher when Windows exposes a usable Desktop,
  but a missing or unavailable optional Desktop no longer aborts an otherwise
  successful install, update, or migration.
- Reworked the Windows README and Quickstart around the one-click Setup and
  local Manager workflow. BAT and PowerShell launchers remain documented as
  portable recovery and advanced fallbacks rather than the primary setup path.

### Fixed

- Resolved Windows Desktop and Programs locations through the Windows shell
  instead of guessing `%USERPROFILE%\Desktop`. This supports redirected and
  OneDrive-managed Desktops and fixes the v0.11.0 `DirectoryNotFoundException`
  reported while Setup was creating `Open TautWeekly Manager.lnk`.
- Added regression coverage for redirected Desktops, an unavailable optional
  Desktop, a failed optional Desktop shortcut write, required Start Menu
  launchers, and cleanup through the same Windows shell locations.

### Security

- The shortcut correction does not read or move configuration, credentials,
  history, previews, or recipient data. The Setup executable remains unsigned;
  verify it against the release `SHA256SUMS.txt` before running it.

## [0.11.0] - 2026-08-14

### Added

- Added `TautWeekly-Setup.exe` as the authoritative Windows installer. It
  installs the self-contained Manager for the current Windows account, creates
  Desktop and Start Menu shortcuts, registers an uninstaller, and keeps
  private Manager state outside the application directory.
- Added the loopback-only Windows Manager with Dashboard, guided Config,
  connection verification, persistent setup status, sandboxed six-state
  previews, guarded TestEmail delivery, Windows schedule lifecycle, local
  diagnostics, and optional browser password lock.
- Added typed Task Scheduler Install/Refresh, Enable, Disable, and Remove
  operations. Only the packaged helper receives elevation; it revalidates the
  saved configuration and exact task ownership before and after each change.
- Added installer lifecycle coverage for fresh install, Manager boot, verified
  update, portable migration, application icons, privacy-preserving uninstall,
  and cross-builds of the Manager for Windows, Linux, macOS, and FreeBSD on
  amd64 and arm64.

### Changed

- Made Setup and the Manager the Windows source of truth throughout the main
  README, Windows Quickstart, platform guide, troubleshooting, issue templates,
  release automation, and packaged documentation. Numbered BAT/PowerShell tools
  remain supported recovery and expert fallbacks.
- Running a newer Setup now preselects an existing installer-owned location and
  performs an Update. Selecting the exact folder of an older manifest-verified
  portable/BAT release performs an in-place Migrate; Setup never scans drives
  or guesses at legacy locations.
- Windows first launch now trusts the local Windows account and opens the
  Dashboard without an unrecoverable pairing token. An optional eight-character
  password lock and local reset shortcut remain available when the Windows
  account is shared.
- Updated the renderer's public product version identifier to `0.11.0` across
  maintained source copies without changing provider, recipient, or schedule
  behavior on non-Windows packages.

### Fixed

- Preserved generated preview status after the preview process finishes so the
  Config workflow reports the actual completed result rather than a stale
  `Skipped` state.
- Repaired authenticated preview image routing while keeping images confined to
  the approved `output/` and packaged `assets/` roots, including symlink escape
  rejection.
- Prevented a fresh install from removing a predictable sibling directory and
  prevented verified updates from disabling or enabling a same-named Scheduled
  Task that is not owned by the selected TautWeekly installation.

### Security

- Setup verifies its embedded ZIP checksum and the release ownership manifest,
  replaces only release-owned files, keeps the original candidate untouched,
  uses an operation lock, refuses a running send, and automatically rolls back
  after a failed replacement verification.
- Configuration, API keys, Plex tokens, SMTP credentials, delivery history,
  previews, logs, deleted-item cache, backups, and Manager access state are
  excluded from release ownership and preserved across update and uninstall.
- Manager secrets remain omitted from ordinary API responses. A single secret
  can be revealed only through an authenticated, CSRF-protected, revision-bound
  request and is cleared from the page automatically.
- The Windows Setup executable is unsigned in this release. Users must verify
  it against the release `SHA256SUMS.txt`; code signing remains a documented
  follow-up.

## [0.10.4] - 2026-08-13

### Fixed

- Personal TV statistics continue to consolidate episode activity by show and
  total watch duration, but now prefer that show's IMDb score and fall back to
  its Rotten Tomatoes critic score, then its audience score. Episode-level
  ratings remain limited to TV release rows.
- Personal movie and TV rows now omit the rating line when no eligible score
  exists instead of rendering `Ratings unavailable` or `IMDb unavailable`.
- Added cross-platform renderer regressions for populated IMDb/RT priority,
  score-dependent RT icons, aggregate TV duration, and absent-rating layout
  across Windows, NAS/Docker/Linux/FreeBSD, and macOS sources.

### Security

- Reused the existing exact show rating key and bounded provider-labelled
  metadata sources. The refinement adds no title search and does not persist or
  expose configuration, credentials, viewing history, recipient data, upstream
  responses, logs, or generated newsletters.

## [0.10.3] - 2026-08-13

### Changed

- Added a consistent metadata-readiness sequence to every maintained setup
  wizard, verifier, Quickstart, platform guide, update/install completion path,
  and private container preview landing page. Before first acceptance, users
  confirm each included Plex Movie library's Ratings Source, run Plex **Refresh
  All Metadata** for every included movie/TV library, then use Tautulli's
  per-library **Library > Media Info > Refresh media info** control before
  Verify, PreviewAll, or TestEmail.
- The guided macOS and QNAP installers now pause before their automatic
  verifier so the administrator can finish those upstream refreshes. Other
  platforms print the same ordered checklist before their test commands.
- Clarified that Plex full-library refreshes can be slow and can update
  metadata or artwork, Tautulli's table refresh does not replace Plex's
  refresh, and routine TautWeekly updates do not require the full sequence
  when current output already renders correctly.
- Pinned the canonical branding build script to byte-preserving Git handling
  so its approved SHA-256 remains stable in Windows and Unix checkouts.

### Security

- Kept metadata refreshes manual and scoped to the administrator-selected
  Plex libraries. TautWeekly does not invoke either upstream refresh API and
  does not expose configuration, tokens, history, recipients, private
  infrastructure, responses, logs, or generated newsletters.

## [0.10.2] - 2026-08-13

### Fixed

- Added an exact-episode Rotten Tomatoes fallback for TV release rows. An
  available IMDb score for that exact episode still has priority; otherwise
  the renderer uses the exact episode's RT critic score, then its RT audience
  score. Show-level, movie, TMDB, TVDB, unknown, and unlabelled values remain
  ineligible.
- Extended sanitized PreviewAll, SendTest, and renderer regressions across the
  maintained Windows, NAS/Docker/Linux/FreeBSD, and macOS sources. The tests
  prove IMDb wins when both providers exist and that an RT-only exact episode
  receives the score-dependent tomato or popcorn presentation.

### Security

- Reused the authenticated, exact-rating-key Plex and bounded Tautulli
  metadata paths introduced for rating recovery. The fallback adds no external
  rating search and does not persist or expose configuration, tokens, history,
  recipients, responses, or generated newsletter output.

## [0.10.1] - 2026-08-13

### Fixed

- Added an authenticated native Plex XML fallback for provider `Rating`
  elements when PMS omits required provider entries from JSON or ignores the
  requested scalar-field exclusion. Movies still prefer available Rotten
  Tomatoes critic/audience values, while TV rows still accept only
  exact-episode IMDb.
- Extended the sanitized PreviewAll and SendTest regression to cover a Plex
  server that exposes selected IMDb in JSON but the retained RT pair only in
  XML. The original optional-JSON path remains covered across the shared
  Windows, NAS/Docker/Linux/FreeBSD, and macOS renderer sources.
- Reclassified an empty optional Plex hosted-metadata exact-match fallback as
  informational. It can be unrelated to ratings and no longer appears as a
  warning when rendering can continue with local Plex or Tautulli metadata.

### Security

- Kept both direct requests on the user-configured Plex server, with the
  administrator token in an HTTP header. Regression output contains only
  synthetic provider labels and scores; no private response, rating key,
  configuration, recipient, history, or generated newsletter is committed.

## [0.10.0] - 2026-08-13

### Added

- Added the exact approved detailed popcorn `TW` raster provenance, corrected
  transparent source, transparent normalized logo master, padded transparent
  app-icon master, reproducible Pillow build, fixed SHA-256 evidence,
  raster-preserving SVG wrappers, web/app sizes, and Windows ICO to the durable
  public brand source.
- Added a Pages favicon, touch icon, web manifest, and social preview image,
  plus packaged product icons for the private container preview landing page
  and the Windows portable distribution.

### Changed

- Replaced global placeholder `TW`, chevron/play, popcorn emoji, Community Apps,
  and preview-service marks with exact raster derivatives. Platform-specific
  README badges remain their own identities; generic documentation
  abbreviations were replaced by verified Windows, Apple, Docker, QNAP,
  Unraid, Linux, and FreeBSD marks with fixed provenance and hashes.
- Preserved each platform mark's native colors and proportions, except for the
  user-approved Apple geometry-only derivative in TautWeekly gold; its original
  black SVG is retained untouched as provenance.
- Classified and documented unsupported package surfaces rather than inventing
  them: current `main` has no QNAP QPKG/App Center package, Windows
  Setup/uninstaller/executable, macOS app bundle, Linux desktop entry, or
  FreeBSD GUI metadata. The approved Windows ICO is packaged for those future
  Setup/shortcut consumers without changing portable installation behavior.
- Kept product artwork out of generated newsletter HTML and left the existing
  mail-state and provider assets unchanged.

## [0.9.8] - 2026-08-13

### Fixed

- Explicitly requested Plex's optional `Rating` metadata element for direct
  item JSON and exact-episode XML fallback requests, while excluding the
  case-colliding scalar JSON `rating` field. This restores alternate Rotten
  Tomatoes critic/audience values and exact-episode IMDb values when Tautulli
  exposes only Plex's flattened selected IMDb or TMDB score.
- Added a sanitized cross-platform regression that models the reported split:
  the default metadata response contains only selected IMDb, while the
  opt-in response contains the provider-labelled RT pair.
- Setup, verification, quickstarts, and troubleshooting now identify Plex's
  library-wide **Ratings Source → Rotten Tomatoes** setting and metadata refresh
  as prerequisites for intentional RT movie output. A passing direct-Plex check
  proves reachability, not provider choice.

### Security

- Kept the existing private direct-Plex boundary. The administrator token
  remains in an HTTP header, the request targets only the configured server
  and exact rating key, and no metadata response, viewing history, recipient
  data, generated newsletter, or private configuration is committed.

## [0.9.7] - 2026-08-13

### Fixed

- Routed container shells, setup, verification, library/user management,
  roster, asset-repair, and schedule controls through the configured non-root
  PUID/PGID. This prevents Docker, Unraid, QNAP, macOS Docker, and
  FreeBSD/Podman Console or exec commands from creating root-owned
  configuration and logs that later newsletter operations cannot update.
- Added bounded migration recovery for root-owned entries left by prior
  container commands under the dedicated `/data` filesystem.

### Security

- Restricted ownership recovery to root-owned entries on the `/data`
  filesystem without following symlinks or crossing mount points. The
  launchers continue to reject UID/GID 0 and do not expose private data.

## [0.9.6] - 2026-08-11

### Fixed

- Made direct Plex a clearly recommended setup step for full rating and artwork
  fidelity across Windows, NAS/Docker, macOS, native Linux, and
  FreeBSD/Podman. The guides now distinguish Tautulli-only fallback operation
  from the direct Plex path used for alternate RT values, exact-episode IMDb,
  backgrounds, and selected logos.
- Extended setup verification beyond Tautulli: it now tests the same resolved
  direct Plex URL and token that the renderer will use, including both the
  public identity endpoint and an authenticated library request. Unreachable,
  unauthorized, or invalid configured connections fail before Preview or
  SendTest; an entirely absent optional connection produces a reduced-fidelity
  warning.

### Security

- Kept the Plex token in the request header only. Verification does not place
  it in a URL, child-process command line, or status output, and does not write
  Plex responses or private server details to disk.

## [0.9.5] - 2026-08-11

### Fixed

- Continued through the bounded Plex and Tautulli rating fallbacks when a
  movie's flattened selected provider is IMDb, so available Rotten Tomatoes
  critic/audience values take precedence. A clearly labelled IMDb score is
  rendered only when no RT value is available.
- Restored exact-episode semantics for TV release rows: a selected TMDB or TVDB
  score no longer blocks the native Plex `Rating[]` / legacy XML IMDb lookup,
  and generic or show-level scores are not substituted beside episode titles.
- Added a sanitized regression where direct Plex returns 404, normal Tautulli
  movie metadata selects IMDb, and the rating-only item export supplies RT.
  Preview and decoded SendTest output must prefer RT and retain the individual
  episode IMDb score across every maintained renderer.

### Security

- Preserved the existing four-field, metadata-level-1 Tautulli export boundary.
  No external ratings search, media information, file paths, viewing history,
  recipient data, credentials, or generated output is added or persisted.

## [0.9.4] - 2026-08-11

### Fixed

- Accepted recognized provider-labelled IMDb, TMDB, and TVDB values from both
  Tautulli rating field pairs while preserving the dedicated Rotten Tomatoes
  movie and IMDb TV presentation. Current Tautulli TV metadata can place its
  selected TMDB score in `audience_rating` / `audience_rating_image` while
  leaving `rating_image` empty; v0.9.2 ignored that valid shape.
- Rendered the selected-provider fallback on movie, TV, episode, and personal
  statistics rows across Windows, NAS/Docker, and macOS, and retained the two
  bounded presentation fields in the exact-GUID deleted-item cache.
- Replaced the prior synthetic show-export fixture with Tautulli's maintained
  TV field contract, then exercised PreviewAll and decoded SendTest delivery
  with direct Plex deliberately unavailable. Follow-up evidence was provided
  by [@Rocknrolldoggie](https://github.com/Rocknrolldoggie) in
  [#58](https://github.com/sparkmoxie/TautWeekly/issues/58).

### Security

- Kept rating export requests at metadata level 1 with media information and
  file locations disabled. Only known provider identifiers with a numeric
  score from 0 through 10 are accepted; unknown or unlabeled values remain
  omitted.

## [0.9.3] - 2026-08-11

### Fixed

- Replaced the standards-valid but insufficiently supported `dark only` email
  declaration with Apple Mail's documented `light dark` opt-in. The base styles,
  dark-mode override, inline colors, and table fallbacks still render the same
  single dark-first design without adding a recipient-facing theme selector.
- Extended PreviewAll and decoded SendTest MIME assertions across every
  maintained renderer so delivered HTML must contain the compatible scheme
  metadata and must not retain the prior dark-only declaration.

## [0.9.2] - 2026-08-11

### Fixed

- Made Tautulli exporter-field discovery compatible with implementations that
  require a non-null `sub_media_type` even though the API documents it as
  optional.
- Explicitly requested the provider-labelled `rating`, `ratingImage`,
  `audienceRating`, and `audienceRatingImage` fields instead of relying on a
  Tautulli version's metadata-level mapping when field discovery is unavailable.
- Added the same item-export fallback for show IMDb ratings when Tautulli's
  normal metadata response and direct/hosted Plex lookups do not provide one,
  and display the recovered rating on the TV release card.
- Stopped rejecting valid rating-only JSON exports merely because their
  serialized response is shorter than 64 bytes.
- Extended the sanitized direct-Plex-failure regression through SendTest and
  now decode the captured MIME message to require movie RT, show IMDb, and
  their icons in the delivered HTML. This follow-up correction was reported by
  [@Rocknrolldoggie](https://github.com/Rocknrolldoggie) in
  [#58](https://github.com/sparkmoxie/TautWeekly/issues/58).

### Security

- Kept the exporter fallback limited to rating presentation fields at metadata
  level 1 with media information and file locations disabled. Unlabelled
  numeric values still fail closed.

## [0.9.1] - 2026-08-10

### Fixed

- Corrected the Tautulli fallback for movie Rotten Tomatoes ratings: item
  exports no longer request the library-only `individual_files` option, and
  rating-only downloads are parsed as JSON instead of being rejected for not
  being ZIP archives. Reported by
  [@Rocknrolldoggie](https://github.com/Rocknrolldoggie) in
  [#58](https://github.com/sparkmoxie/TautWeekly/issues/58).
- Accepted Tautulli's flattened rating fields and Plex's nested rating entries,
  including the Rotten/spilled low-score icon states. A sanitized integration
  scenario now keeps direct Plex unavailable and requires the item-export
  fallback to restore both critic and audience scores on every renderer.
- Documented why posters can remain available through Tautulli's image proxy
  while direct Plex ratings, backgrounds, or selected logos are unavailable,
  and how Docker operators must provide a Plex URL reachable from inside the
  TautWeekly container.

### Security

- Reduced the fallback from metadata level 9 to level 1 with media information
  disabled. The temporary export requests only presentation rating fields and
  cannot include library file locations or media-stream details.
- Kept provider-free numeric values fail-closed: TautWeekly does not label an
  unidentifiable rating as Rotten Tomatoes or IMDb.

## [0.9.0] - 2026-08-10

### Added

- Added a schema-versioned, persistent pre-deletion cache that records only an
  exact stable media GUID, bounded newsletter presentation metadata, and one
  SHA-256-verified poster while the Plex item is still available. PreviewAll,
  SendTest, and normal delivery can reuse the entry after later deletion on
  Windows, NAS/Docker, macOS, native Linux, and FreeBSD/Podman.
- Added default 365-day, 1,000-item, and 256 MiB retention controls, deterministic
  newest-first cleanup, atomic primary/backup manifests, corruption recovery,
  and cross-platform creation, deletion, eviction, privacy, and package tests.

### Changed

- Advanced the repository release to the next SemVer minor because this feature
  creates persistent state. Existing configurations migrate without a rewrite:
  omitted cache settings receive bounded defaults, while setup preserves later
  operator changes.
- Documented that the v0.8.3 Plex hosted-provider path is best-effort. Tautulli
  history can retain descriptive fields and identifiers, but neither Tautulli
  history nor a deleted Plex library item guarantees durable artwork bytes.
  The new cache protects future items observed after upgrade and cannot
  retroactively repair assets already discarded.

### Security

- The cache accepts a fixed presentation-field allowlist and excludes API keys,
  Plex and SMTP credentials, recipients, viewing metrics, and generated output.
  It never persists the Plex administrator token or sends it to third parties.
- Cache lookup requires the exact stable GUID and media type; malformed paths,
  missing identifiers, hash failures, and ambiguous title-only history fail
  closed. The total byte ceiling accounts for artwork and both manifests.

## [0.8.4] - 2026-08-10

### Fixed

- Preserved the newsletter's single dark-first palette in Apple Mail by
  declaring dark-only color-scheme support, and reinforced every maintained
  renderer with explicit longhand backgrounds and table `bgcolor` fallbacks
  for clients such as Gmail and Outlook that ignore or override scheme hints.
  Reported by [@Demonmeister](https://github.com/Demonmeister) in
  [#44](https://github.com/sparkmoxie/TautWeekly/issues/44).
- Captured and decoded the integration test's delivered MIME message so the
  preview variants and SMTP HTML must both retain the dark-mode metadata,
  outer canvas, card colors, and compatibility fallbacks.

## [0.8.3] - 2026-08-10

### Fixed

- Supplied Plex's required retained movie/show title and episode index context
  when its hosted provider retries deleted-history GUIDs, and preserved the
  representative episode indexes alongside aggregated TV history. This fixes
  the production `400 Bad Request` and empty-match behavior left in v0.8.2.
- Kept missing deleted-history artwork nonfatal under PowerShell strict mode when
  no hosted match is available.

### Security

- Validated title-hinted hosted responses against the retained canonical Plex
  GUID or returned external TMDB/TVDB/IMDb identifier. When Plex omits its
  external-ID array, the response must still agree with the retained title and
  media type from that exact external-ID request. Recipient identity and viewing
  metrics remain outside the Plex request.

## [0.8.2] - 2026-08-10

### Fixed

- Retried empty modern Plex and legacy TMDB/TVDB hosted lookups through Plex's
  current JSON `POST /library/metadata/matches` provider contract while
  preserving the compatible direct/query-form attempts. Follow-up reported by
  [@gianfelicevincenzo](https://github.com/gianfelicevincenzo) in
  [#51](https://github.com/sparkmoxie/TautWeekly/issues/51).

### Security

- Limited the provider-contract retry body to the validated exact
  GUID and numeric media type. It sends no title, year, recipient identity, or
  watch-history fields, and keeps the Plex token confined to the hosted Plex
  request.

## [0.8.1] - 2026-08-10

### Fixed

- Extended exact-GUID recovery for deleted Plex history to legacy TMDB agent
  aliases and legacy TVDB episode/show identifiers, and made unsupported or
  empty exact matches visible through privacy-safe warnings. Follow-up reported
  by [@gianfelicevincenzo](https://github.com/gianfelicevincenzo) in
  [#41](https://github.com/sparkmoxie/TautWeekly/issues/41).

### Security

- Kept legacy deleted-history recovery limited to validated numeric provider
  identifiers. It performs no title search and never writes the retained
  identifier or Plex token to diagnostics.

## [0.8.0] - 2026-08-10

### Fixed

- Made the generic-poster fingerprint probe portable to Unix so deleted Plex
  history artwork can proceed to the exact-GUID hosted recovery added in
  v0.7.0. Follow-up reported by
  [@gianfelicevincenzo](https://github.com/gianfelicevincenzo)
  in [#41](https://github.com/sparkmoxie/TautWeekly/issues/41).
- Routed watched TV-show statistics through the same exact-GUID enrichment as
  movies and rendered the recovered IMDb score in each personal TV row. The
  prior regression could match an unrelated global rating and now scopes its
  assertion to the TV statistics card. Follow-up reported by
  [@gianfelicevincenzo](https://github.com/gianfelicevincenzo) and corroborated
  by [@Rocknrolldoggie](https://github.com/Rocknrolldoggie) in
  [#41](https://github.com/sparkmoxie/TautWeekly/issues/41).
- Recovered provider-labelled movie Rotten Tomatoes and TV IMDb scores from
  Plex's public watch page when exact-GUID hosted metadata returns artwork and
  genres without ratings. The fallback uses only Plex's exact returned slug,
  performs no title search, and leaves genuinely unavailable scores blank.

### Security

- Kept the public Plex rating fallback tokenless and limited its request to the
  exact validated movie/show slug returned by Plex's authenticated GUID lookup.
  Recipient identity and watch-history values are never sent.

## [0.7.0] - 2026-08-10

### Fixed

- Recovered posters, summaries, genres, years, movie Rotten Tomatoes ratings,
  and TV IMDb ratings for deleted Plex items by resolving the exact metadata
  GUID retained in Tautulli history, and rejected Tautulli's generic poster
  placeholder as usable artwork. Reported by
  [@gianfelicevincenzo](https://github.com/gianfelicevincenzo)
  in [#41](https://github.com/sparkmoxie/TautWeekly/issues/41).

### Security

- Limited deleted-item recovery to Plex's hosted metadata service using the
  existing administrator Plex token and exact retained GUID. No title search,
  recipient identity, or watch-history payload is sent, and the token is not
  forwarded to external artwork hosts returned by Plex.

## [0.6.3] - 2026-08-09

### Fixed

- Made root-started Docker and Podman console newsletter commands drop to the
  configured PUID/PGID before writing locks, logs, posters, or diagnostics.

## [0.6.2] - 2026-08-09

### Fixed

- Treated sparse Tautulli hero metadata fields as optional so recoverable direct
  Plex 404 fallbacks cannot be followed by a strict-mode crash in previews or
  test email delivery.

## [0.6.1] - 2026-08-09

### Changed

- Limited **HOT NEW RELEASE** hero selection to new movies. Movie-empty weeks
  now promote the normal **TRENDING THIS WEEK** result while retaining new TV
  titles in the release shelf.
- Revised personal stats to list up to four most-watched movie titles and four
  most-watched TV shows, grouping qualifying episodes by show and omitting an
  empty TV card.
- Replaced the movie and TV stat artwork in every packaged renderer with the
  supplied animated GIFs while retaining the established CID/repair pipeline.
- Split Binge Champion into a bold watch-duration line and a smaller unique
  movie/TV-show breakdown for winners and non-winners, omitting zero categories.
- Removed qualifying-play copy from Total Watched.

### Fixed

- Accepted section-scoped Tautulli recently-added rows when Plex omits the
  redundant library identifier, while continuing to reject explicit library
  mismatches and unscoped rows.
- Made inbox preview and body counts describe unique TV titles/shows rather
  than episode rows when multiple series are added or watched.

## [0.6.0] - 2026-08-07

### Added

- Added an explicit Windows `U` action that downloads the official latest
  stable ZIP and checksum, validates a per-file release manifest, and applies
  the update only after user confirmation and Windows elevation.
- Added a shared Windows installation lock so newsletter runs and updates
  cannot overlap, plus functional regression coverage for checksum refusal,
  private-file preservation, deprecated-file cleanup, and rollback.
- Added `RELEASE-FILES.txt` with SHA-256 hashes to every packaged platform so
  release ownership is deterministic without claiming runtime data.

### Changed

- Advanced the Windows portable source baseline to 1.7.0 and documented the
  difference between manual update checking, explicit application, and the
  absence of unattended Windows update tasks.

### Security

- Windows updates now pause and restore Task Scheduler state, keep a private
  full-folder sibling backup, replace only verified release-owned files, verify
  the installed version and PowerShell syntax, and automatically restore the
  previous installation after a failed apply.

## [0.5.5] - 2026-08-07

### Added

- Added explicit stable-release checks for Windows, macOS, and native Linux,
  plus stage-only image checks for NAS/QNAP and FreeBSD.
- Added regression contracts for stable-channel defaults, check/apply
  separation, operation-lock refusal, health/version verification, and
  automatic container-image rollback.

### Changed

- Defined one package-by-package update policy across the README, Markdown
  guides, and rendered Quickstarts. Stable releases remain the default,
  unattended application is opt-in, and `edge` is documented as unreleased
  `main` rather than an update channel.
- Made NAS/QNAP Compose and FreeBSD updates preserve state, reject concurrent
  TautWeekly operations, verify the replacement container, and restore the
  prior image automatically after a failed health check.

### Fixed

- Corrected macOS `update`: it now builds the verified release package present
  on disk, records that repository version in the image, verifies health and
  version, and rolls back on failure instead of only refreshing the base image.
- Removed FreeBSD's ineffective Podman registry auto-update label; Podman auto
  update requires a systemd-managed container, while this package uses rc.d.

## [0.5.4] - 2026-08-07

### Added

- Added global movie/TV library discovery and selection to every primary setup
  flow, using stable Tautulli section IDs and preserving legacy all-library
  behavior for configurations without an explicit selection.
- Added standalone list and management commands for Windows, NAS/Unraid,
  macOS, native Linux, and FreeBSD, including configuration backup and stale-ID
  verification.
- Added deterministic virtual Tautulli/Plex integration scenarios for active
  and quiet release weeks, cross-platform command-routing tests, packaged
  runtime contract checks, and checksum verification for every distribution.

### Changed

- Consolidated the separate Docker Compose quick-start page into the canonical
  NAS / Docker guide. Compose, QNAP Container Station, Unraid Apps, and Docker
  Desktop are now presented as deployment paths for one package; the retired
  `quickstart.html` URL redirects to the consolidated guide.
- Routed top-level Unraid references through the consolidated NAS Quickstart or
  Markdown documentation; the detailed NAS guides retain the published
  Community Apps installation destination in context, including the platform
  comparison shortcut.
- Separated interactive Quickstarts from source-oriented documentation and
  standardized the platform labels across the README, Pages hub, rendered HTML,
  and standalone installation guides.
- Query each selected Tautulli section independently for history and
  recently-added media, then fail closed on mismatched rows before calculating
  releases, quiet mode, Trending, hero content, Binge Champion, and personal
  statistics. Busy private libraries can no longer crowd selected releases out
  of paged API results.
- Allow the FreeBSD Podman binary path to be set with
  `TAUTWEEKLY_PODMAN_BIN`, while retaining `/usr/local/bin/podman` as the
  package default.

### Fixed

- Clarified that `./tautweekly.sh` is a host-side Docker Compose wrapper, not a
  command inside the Unraid Apps container, and replaced container-generated
  follow-up guidance with commands that exist in the Unraid Console.
- Made every non-Windows scheduler resolve and convert UTC through the configured
  IANA `TZ` explicitly instead of trusting process-local `Get-Date`; invalid
  zones now fail closed instead of silently scheduling in UTC. Schedule status
  now distinguishes the control process from the active scheduler heartbeat,
  including the resolved zone, local time, and UTC offset.
- Replaced the legacy SMTP send path with an explicit STARTTLS and
  `AUTH LOGIN`/`AUTH PLAIN` transport that requires authentication success
  before `MAIL FROM`, including compatibility with Proton SMTP submission.
- Corrected Unraid Console examples to pass the required numeric `USER_ID`,
  clarified that `ListUsers` is display-only across every launcher and guide,
  and documented that `verify` checks SMTP reachability rather than login or
  sender authorization.
- Corrected the selected-library row predicate on all renderers. PowerShell
  previously accepted an unsupported parameter without binding the row,
  causing every history and release item to be rejected whenever an explicit
  library scope was enabled.

## [0.5.3] - 2026-08-05

### Fixed

- Replaced Docker health's scheduler-progress dependency with a five-second
  service-supervisor heartbeat, preventing long scheduled deliveries from
  making a working container appear unhealthy.
- Made missing decorative preview artwork a repair warning rather than a
  liveness failure, while retaining hard failures for an unavailable preview
  listener and a missing, unreadable, or stale supervisor heartbeat.
- Added actionable health-probe errors and an eight-scenario functional suite
  covering failure isolation and automatic recovery.

## [0.5.2] - 2026-08-05

### Fixed

- Replaced exclusion setup's per-user `get_user` requests with a two-call merge
  of Tautulli's `get_user_names` and `get_users` rosters. Stable IDs from the
  name roster remain selectable when detailed rows are unavailable.
- Added a bulk-roster fallback for newsletter user resolution when a Tautulli
  installation rejects an otherwise valid single-user lookup.

## [0.5.1] - 2026-08-05

### Added

- Added a standalone, responsive eight-state newsletter showcase with real
  public Plex Discover posters and title art, dated Rotten Tomatoes movie and
  IMDb episode score examples, production-formatted TV episode rows, dense
  movie/TV releases, both anonymous Binge Champion treatments, onboarding and
  warmup variants, and the production quiet-week latest-release fallback.

### Fixed

- Treat Tautulli episode `rating_image` and `rating` fields as optional when
  building personal statistics, preventing `preview-all` from failing under
  strict PowerShell property handling when either field is omitted.
- Added a permanent first-run page to the container preview endpoint, verified
  its listener before starting the scheduler, and made an unexpected preview
  or scheduler process exit fail the container visibly.
- Corrected NAS documentation that pointed to a nonexistent `preview-all/`
  subdirectory; the generated index is `/preview-all-00-INDEX.html`.

### Changed

- Docker and Unraid startup logs now identify the exact persistent
  `/data/config.json` path and provide the appropriate Compose or Console setup
  command. Documentation and Community Apps metadata now distinguish the
  read-only preview viewer from an administration Web UI.

## [0.5.0] - 2026-08-04

### Added

- Added a standalone native Linux distribution with PowerShell 7.2+, a
  hardened systemd service, protected `/var/lib/tautweekly` storage, safe
  in-place upgrades, and matching administrative commands.
- Added a FreeBSD 15.1+ amd64 beta distribution using FreeBSD Podman Linux
  containers, rc.d lifecycle integration, protected `/var/db/tautweekly`
  storage, image pinning, updates, and private backups.
- Added rich searchable Linux and FreeBSD Pages walkthroughs, standalone
  Markdown install guides, platform troubleshooting, security boundaries, and
  support-matrix entries.
- Added Linux and FreeBSD ZIP/TAR.GZ release artifacts, checksum coverage,
  launcher-permission checks, and platform-contract validation.

### Changed

- Made container runtime wrappers honor configurable application and data roots
  so the canonical renderer can be packaged for native Linux without source
  drift.

## [0.4.0] - 2026-08-04

### Added

- Added interactive Tautulli user exclusion selection to every platform's
  primary setup and a standalone exclusion manager for later recipient-policy
  updates.
- Added Windows and Docker launch commands, selection behavior tests, and
  matching Markdown and rendered walkthrough guidance.

### Changed

- Setup replacement now carries forward existing `ExcludedUserIds` and
  `ExcludedEmails`; a temporary Tautulli lookup failure no longer silently
  clears established exclusions.
- Binge Champion now ranks qualifying users by total watch time, with total
  plays as the exact-time tie-breaker.
- Binge Champion output now shares only anonymous movie-play, TV-play, and
  watch-time totals. Friendly names, user identifiers, and titles are hidden;
  only the winner receives the gold **YOU WON** treatment.

## [0.3.0] - 2026-08-04

### Added

- Added an official Unraid Community Applications v2 Docker template and root
  `ca_profile.xml` with safe appdata, port, identity, and timezone defaults.
- Added automated amd64/arm64 container publishing to
  `ghcr.io/sparkmoxie/tautweekly` with OCI source metadata, SBOM, provenance,
  version tags, and a stable `latest` tag.
- Added a pull-based QNAP Container Station Compose application while keeping
  the source Dockerfile and local-build workflow maintainable.
- Added repository validation for Community Applications metadata and Docker
  template configuration.

### Changed

- Updated the NAS/Docker baseline to 1.1.0 and made routine NAS installation
  and updates pull the published image without touching persistent data.
- Documented why QNAP App Center is not used for the Docker edition: App Center
  catalogs native QPKG packages, while Container Station is QNAP's Compose UI.

## [0.2.0] - 2026-08-04

### Changed

- Renamed the public product to **TautWeekly for Plex** and standardized the
  repository, Pages site, documentation, UI, email, source, and release
  branding around `TautWeekly`.
- Renamed the PowerShell entry points to `TautWeekly.ps1`, Docker launchers to
  `tautweekly.sh` and `tautweekly-docker.ps1`, and release archives to the
  `TautWeekly-<platform>` convention.
- Renamed Docker services, images, internal application paths, operation
  locks, backups, and environment variables to the lowercase `tautweekly` or
  uppercase `TAUTWEEKLY_` convention.
- Moved repository and rendered documentation links to
  `sparkmoxie/TautWeekly` and `sparkmoxie.github.io/TautWeekly`.

### Migration

- Preserve private configuration and the Docker `data` directory, but replace
  program files with the 0.2.0 package and use the newly named launchers.
- Recreate Docker services with `docker compose up -d --build` after replacing
  the application files. Windows users should verify the scheduled-task name
  in `config.json` before reinstalling the schedule.

## [0.1.1] - 2026-08-03

### Fixed

- Preserved Docker dotfiles in ZIP release archives, including
  `.dockerignore`, `.env.example`, and `data/.keep`.
- Added a build-time ZIP payload parity check so archive creation fails if any
  staged source file is omitted.

## [0.1.0] - 2026-08-03

### Fixed

- Pointed the README documentation entry at the live Pages site, removed
  premature download links to an empty Releases page, and made current source
  locations explicit until the first version tag is published.
- Replaced user-facing links to HTML source blobs with rendered GitHub Pages
  URLs for the documentation home, all three platform walkthroughs, and the
  NAS / Docker Compose quick start.
- Made the Pages deployment follow the repository's current default launch
  branch and replaced a stale `blob/main` footer link with a default-branch
  (`HEAD`) URL.
- Preserved array semantics for exactly one adaptive movie or episode under
  Windows PowerShell 5.1 strict mode.
- Derived archive source-baseline metadata from each platform's shipped
  `VERSION.txt` instead of stale hard-coded values.

### Added

- Initial public, maintainable source tree for Windows, NAS/Docker, and macOS
  Docker Desktop.
- Sanitized configuration examples and repository-wide runtime-file guards.
- Interactive GitHub Pages documentation based on the supplied rich
  walkthroughs.
- Cross-platform validation, release packaging, checksums, Pages deployment,
  and tagged-release automation.
- Adaptive personal activity cards with posters, movie genres and ratings,
  episode metadata, and equal content-driven heights.
- A server-wide Binge Champion user award and counted Trending title feature.

### Changed

- Scheduled weekly mail now discloses the Binge Champion friendly name and
  winning aggregate; one-off welcome mail remains award-free.

### Source baselines

- Windows portable implementation: 1.6.11.
- NAS/Docker implementation: 1.0.7.
- macOS Docker Desktop implementation: 1.0.3.

These baseline numbers describe the imported platform distributions. Future
public GitHub releases use one repository-level semantic version.
