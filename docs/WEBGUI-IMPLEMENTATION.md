# TautWeekly Manager WebGUI implementation specification

Status: Windows setup, recovery, verification, preview, guarded test delivery,
schedule lifecycle, Setup EXE install/update/migration, reproducibility, update
rollback, and desktop/mobile QA implemented. Final release validation,
review/merge, CI, and publication are tracked by the v0.11.0 delivery; code
signing remains a documented follow-up.

Baseline: TautWeekly v0.10.4 with current `main` at commit
`4b026ad38cbe37b8eaaaa52eac78e79d98e52d02`

This document records the implemented Windows Manager design and the remaining
cross-platform engineering plan. It does not remove the existing command-line
recovery workflows or broaden the newsletter renderer's delivery authority.

## 1. Executive decision

Build a self-contained TautWeekly Manager in Go with an embedded browser
frontend. Keep the existing PowerShell newsletter renderer and its safety
gates. Deliver the complete setup and management workflow on Windows first,
then add the shared Docker adapter immediately for NAS and macOS. Follow with
native Linux and the existing FreeBSD Podman distribution.

The Manager is a management plane, not a generic shell:

- It exposes a versioned, typed local API.
- It invokes only packaged, allowlisted TautWeekly operations.
- It never accepts an arbitrary command, script path, or shell fragment.
- It does not mount or access the Docker or Podman socket.
- Normal configuration reads never return stored API keys, SMTP passwords, or
  Plex tokens. One explicitly selected value can be revealed temporarily after
  the local reveal confirmation and, when enabled, password reauthentication;
  it is cleared from the page after 30 seconds.
- Existing BAT, PowerShell, and shell commands remain supported recovery and
  automation interfaces.

## 2. Product outcomes

An administrator should be able to install a package, open one local URL, and:

1. Complete first-run setup without editing JSON or using a terminal.
2. Test Tautulli and optional direct Plex connectivity.
3. Choose included libraries and excluded recipients, and privately assign
   fallback addresses to active managed users without native Tautulli email.
4. Configure SMTP and send a controlled test message.
5. Generate and inspect all newsletter preview states.
6. Install, enable, disable, verify, or remove the schedule.
7. See whether the runtime and scheduler are healthy.
8. See the last attempted and last successful delivery.
9. See the next scheduled attempt in both local time and UTC.
10. Edit configuration with validation, backup, review, and rollback.
11. Run safe maintenance operations and obtain sanitized diagnostics.

The WebGUI must not imply that SMTP acceptance proves inbox delivery. Delivery
copy should use terms such as "accepted by SMTP" and clearly distinguish an
attempt, a successful application run, and downstream email delivery.

## 3. Scope

### 3.1 Version 1 scope

- Windows first-run wizard and ongoing configuration
- Runtime, scheduler, delivery, and integration status
- Preview and all-state preview generation
- Controlled test and all-state test delivery
- Included-library and excluded-user management
- Schedule installation and lifecycle controls
- Configuration backup and rollback
- Sanitized operation progress and diagnostics
- NAS and macOS Docker integration
- Native Linux systemd integration
- FreeBSD Podman integration through the maintained Linux container
- Responsive, accessible dark-and-gold TautWeekly design

### 3.2 Deferred

- Multi-server or fleet management
- Internet-hosted control plane
- Mobile application
- Arbitrary SMTP composition
- Arbitrary Docker, Podman, PowerShell, or shell execution
- Recipient-level delivery analytics
- Opening the manager to the public internet
- Replacing the PowerShell newsletter renderer
- Automatic unattended application updates

## 4. Delivery order

### Milestone A: contracts and portable skeleton

Define the configuration schema, status contract, operation contract, delivery
history, authentication model, and platform adapter interface. Build the Go
server, embedded frontend shell, and test harness.

### Milestone B: Windows vertical slice

Deliver setup, configuration, verification, previews, test delivery, schedule
management, status, history, backup, and rollback on Windows. The manager runs
on demand under the signed-in user by default; weekly delivery remains
independent in Task Scheduler.

### Milestone C: Docker operational dashboard

Replace the read-only Python preview listener with the Manager HTTP service
inside the maintained container. Preserve the existing non-root identity,
operation lock, scheduler process, service heartbeat, persistent data root,
and container healthcheck. Deliver this adapter for NAS and macOS together.

### Milestone D: maintained secondary platforms

Add native Linux systemd packaging. Reuse the Linux container adapter for
FreeBSD Podman and retain native rc.d lifecycle control outside the container.

### Milestone E: release hardening

Complete accessibility, browser compatibility, security testing, upgrade and
rollback behavior, documentation, reproducible packaging, and real-host
acceptance.

## 5. Architecture

~~~mermaid
flowchart LR
    B["Local browser"] --> M["TautWeekly Manager<br>Go HTTP/API service"]
    M --> C["Typed configuration store"]
    M --> O["Allowlisted operation runner"]
    M --> H["Health and schedule adapters"]
    M --> P["Authenticated preview service"]
    O --> W["Existing PowerShell renderer"]
    H --> A["Windows Task Scheduler"]
    H --> D["Container heartbeats and scheduler state"]
    H --> L["systemd service state"]
    W --> T["Tautulli"]
    W -. optional .-> X["Plex Media Server"]
    W --> S["SMTP"]
    M <--> R["Sanitized operation and delivery records"]
~~~

### 5.1 Manager process

The same Go codebase provides:

- serve: run the WebGUI and API
- run: execute one typed TautWeekly operation headlessly
- status: print a sanitized status document for scripts and support
- version: print release and contract versions

Static HTML, CSS, JavaScript, fonts, and original TautWeekly visual assets are
embedded into the executable. The user does not install Go, Node.js, Python,
or a separate web server.

### 5.2 Frontend

Use TypeScript and a component-based frontend compiled to static assets. React
with Vite is an acceptable default, but the API and accessibility contracts
must not depend on React-specific behavior.

Design requirements:

- Original TautWeekly identity with dark surfaces and restrained gold accents
- No copied Plex layout, proprietary artwork, fonts, or interaction assets
- Visible keyboard focus and complete keyboard operation
- Reduced-motion support
- WCAG AA color contrast
- Semantic form labels, landmarks, headings, tables, and live regions
- Desktop, tablet, and narrow mobile layouts
- No third-party CDN assets or runtime analytics

### 5.3 Existing renderer

The Manager initially treats the renderer as a packaged subsystem. It invokes
known modes using argument arrays rather than a shell command string:

- ListUsers
- Preview
- PreviewAll
- CacheWarm
- SendTest
- SendTestAll
- SendWelcome
- SendAll

Production send and welcome modes retain explicit confirmation gates. The
existing operation lock remains authoritative during the transition.

The implemented renderer operations are `PreviewAll`, `CacheWarm`,
`SendTestAll`, `SendWelcome`, and `SendAll` on Windows. Preview, TestEmail, and
Manual Welcome operations pass only a validated numeric user ID; the cache
refresh and all-recipient production delivery do not accept one. Every mode receives a
private per-run configuration snapshot through the fixed packaged PowerShell
script, discards raw process output, and records only a sanitized operation
result.
`PreviewAll` adds `-NoOpen`. `CacheWarm` enumerates every currently eligible
included user's selected-library newsletter window without rendering previews.
Neither mode contacts SMTP or updates the access roster or welcome state.
`SendTestAll` requires a separate confirmation,
delivers six variants only to the configured `TestEmail`, and cannot be
cancelled after starting because a partial set may already have been accepted
by SMTP. `SendWelcome` requires a selected user plus production confirmation,
sends one real welcome newsletter, updates that user's welcome state, and
retains no user identifier. `SendAll` requires a distinct production
confirmation, runs the same fixed delivery contract as the weekly schedule,
exposes no cancellation, and retains only aggregate accepted, skipped, and
failed counts.

The renderer should gain an optional structured result path. On completion it
writes a sanitized result containing mode, outcome, duration, sent count,
skipped count, failed count, and generated preview paths. It must not write
recipient names, addresses, titles, tokens, or viewing details into this
record.

## 6. Platform adapters

### 6.1 Windows

Responsibilities:

- Resolve the portable installation and private data paths.
- Inspect Task Scheduler state using Windows APIs or fixed PowerShell cmdlets.
- Report task installed state, enabled state, runtime state, next run, last
  run, and last task result.
- Install, update, and remove the scheduled task through a narrowly scoped UAC
  operation.
- Preserve the existing SYSTEM task behavior unless a later delivery changes
  that contract.
- Apply and verify the existing restrictive config ACL.
- Launch generated previews through the authenticated Manager route.

The normal Manager web process must not run as Administrator or SYSTEM. The
implemented schedule adapter launches only the packaged
`SCHEDULE-HELPER.ps1`, with a fixed action enum and the expected configuration
SHA-256 revision. The helper requests UAC, rechecks that revision after
elevation, and accepts no browser-supplied executable, script path, working
directory, environment block, or command string. Before modifying an existing
same-named task, both the helper and the post-operation probe verify the
PowerShell action, exact renderer/result arguments, installation working
directory, and SYSTEM principal. A mismatch fails closed.

The weekly task should eventually call the Manager's headless run mode so
scheduled and interactive operations produce the same status and history.
The Manager does not need to remain open for the schedule to work.

### 6.2 NAS and macOS Docker

Responsibilities:

- Serve the WebGUI and previews on the existing mapped preview port.
- Continue running as the configured non-root UID and GID.
- Read and write only the existing persistent data root.
- Consume service-heartbeat.json, scheduler-heartbeat.json, and
  scheduler-state.json.
- Invoke the existing in-container run-mode wrapper for renderer operations.
- Preserve flock-based operation serialization.
- Keep the Docker socket absent.

The existing supervisor may continue to own the scheduler and Manager child
processes. The Manager replaces the Python static preview server, and the
container healthcheck probes the Manager liveness route plus the supervisor
heartbeat.

### 6.3 Native Linux

Responsibilities:

- Run under the existing dedicated service identity.
- Read service and scheduler status without granting general sudo access.
- Preserve private data under /var/lib/tautweekly.
- Bind to loopback by default.
- Keep install, upgrade, and system service lifecycle changes in the
  root-owned installer or a narrowly scoped helper.

### 6.4 FreeBSD Podman

The first WebGUI release should reuse the maintained Linux OCI image and its
Manager binary. The UI reports internal Manager, preview, scheduler, and
delivery health. The native host wrapper remains responsible for rc.d and
Podman lifecycle status.

The container must not gain access to the Podman socket merely to show the
host's external container state.

### 6.5 Shared configuration migration contract

Every maintained package must follow the same upgrade behavior when the
Manager is added or its schema grows:

- Preserve the existing private configuration before replacing release-owned
  files; never infer that a missing newer field was deleted by the updater.
- Distinguish a legacy field that never existed from a configured value that
  is present, empty, or explicitly cleared.
- Normalize missing current-schema keys only after an explicit validated save
  and retain the original file as a private timestamped backup.
- Recover a secret only from an explicit trusted runtime source appropriate to
  that package (for example the same-account Windows Plex registry or an
  operator-supplied container secret). Never scrape an unrelated profile,
  return the secret to the browser, write it into diagnostics, or silently copy
  it into `config.json`.
- Use a runtime-reachable service URL: loopback for a same-host native service,
  and a service name, host gateway, or private LAN address for a separate
  container. Never rewrite that boundary by guessing.
- If safe recovery is unavailable, keep the package operational through its
  documented fallback and show one precise completion step in Config.

This contract is shared by Windows, NAS/macOS Docker, native Linux, and FreeBSD
Podman even though their credential sources and scheduler adapters differ.

## 7. Health model

Health is a shared product contract, not a single green badge.

### 7.1 Health categories

| Category | Purpose | Examples |
|---|---|---|
| Runtime | Is the local service functioning? | Manager HTTP, preview route, supervisor and scheduler processes |
| Readiness | Can configured work run safely? | Config parses, private data is writable, timezone resolves, assets exist |
| Scheduler | Is automatic delivery active and fresh? | Enabled, heartbeat age, active timezone, next attempt |
| Delivery | What happened most recently? | Last attempt, last success, outcome, counts, duration |
| Integrations | Are dependencies reachable or safely retained? | Tautulli, optional Plex, SMTP network check, optional retained Funnel state |

### 7.2 Endpoints

- GET /health/live
  - Unauthenticated and minimal.
  - Returns success when the Manager can serve requests.
  - In containers, the external healthcheck also validates the supervisor
    heartbeat and scheduler process.
  - Never reports paths, versions, configuration, or dependency details.

- GET /health/ready
  - Authenticated unless a platform requires a minimal local probe.
  - Reports configured, ready, degraded, or blocked.
  - A missing first-run configuration is unconfigured, not crashed.

- GET /api/v1/status
  - Authenticated detailed snapshot for the dashboard.
  - Contains no credentials or recipient identity.

- GET /api/v1/config/status
  - Authenticated, revision-scoped results for libraries/users, Tautulli/Plex,
    SMTP preflight, and local previews.
  - Persists sanitized states across refreshes and Manager restarts. A save
    classifies normalized old/new values on the backend, safely rebases only
    unaffected sanitized evidence to the new full revision, and marks only
    affected results for rerun. A restore remains a full not-run boundary.

Temporary Tautulli, Plex, or SMTP failures set integration state to degraded.
They must not cause Docker to restart an otherwise healthy process.

### 7.3 Normalized status example

~~~json
{
  "schemaVersion": 1,
  "observedAtUtc": "2031-04-18T16:30:00Z",
  "overall": "degraded",
  "runtime": {
    "manager": "healthy",
    "preview": "healthy",
    "scheduler": "healthy",
    "heartbeatAgeSeconds": 4
  },
  "schedule": {
    "supported": true,
    "installed": true,
    "enabled": true,
    "timeZone": "America/Phoenix",
    "nextRunUtc": "2031-04-25T16:30:00Z",
    "nextRunLocal": "2031-04-25T09:30:00-07:00"
  },
  "delivery": {
    "lastAttemptUtc": "2031-04-18T16:30:01Z",
    "lastSuccessUtc": "2031-04-18T16:34:22Z",
    "result": "success",
    "sent": 12,
    "skipped": 2,
    "failed": 0
  },
  "integrations": {
    "tautulli": "healthy",
    "plex": "optional-unavailable",
    "smtp": "not-recently-verified"
  }
}
~~~

All example values are fictional. Production status documents must omit
server hostnames, user identity, email addresses, media titles, and secrets.

### 7.4 Upcoming send

The normalized adapter returns local and UTC times:

- Windows reads Task Scheduler NextRunTime and converts it explicitly.
- Containers compute the next eligible weekly window from configured
  day/time, the scheduler's resolved timezone, enabled state, grace period,
  and same-day attempt guard.
- Linux uses the same internal scheduler contract as the native service.
- FreeBSD uses the scheduler inside the maintained container.

Timezone and daylight-saving boundary tests are mandatory. The UI must warn
when the configured timezone differs from the active scheduler heartbeat.

### 7.5 Container health wording

The dashboard reports "internal service health." It must not claim to have
queried Docker's or Podman's external container object unless a separately
trusted host component supplied that information. No such host component is
required for version 1.

## 8. Delivery and operation history

Current platform state is useful but not equivalent across packages. Add a
versioned, privacy-preserving operation record.

### 8.1 Record fields

- operation ID
- operation type
- trigger: gui, cli, or scheduled
- release version
- start and finish timestamps
- outcome: success, failed, cancelled, or blocked
- exit code
- sent, skipped, and failed aggregate counts
- generated preview identifiers
- sanitized error category and support code

### 8.2 Excluded fields

- Recipient ID, name, username, or email
- Newsletter subject
- Media title or rating key
- Tautulli, Plex, or SMTP credential
- Private URL, hostname, or network address
- Viewing totals tied to an individual
- Raw command line

### 8.3 Storage

For the first release, use schema-versioned JSON for the current operation and
an append-only JSON Lines history with bounded rotation. This is easy to
inspect, back up, and implement without adding a database migration surface.

Writes must be serialized by the operation lock, flushed, and completed using
same-directory temporary files plus atomic replacement where supported.
Malformed history entries are skipped with a local warning rather than
blocking newsletter delivery.

History defaults to 90 days or 500 operations, whichever bound is reached
first. This operational history is private runtime data and is excluded from
public diagnostics.

## 9. Configuration contract

### 9.1 Versioned schema

Create one machine-readable schema that defines:

- key and stable field ID
- JSON type
- default
- required and optional conditions
- secret classification
- numeric and length bounds
- enum values
- platform applicability
- setup step and help copy
- whether a restart or schedule refresh is required

The PowerShell verifier and Manager should share fixtures proving that the
schema and runtime interpretation agree.

### 9.2 Secret handling

GET configuration never returns a stored secret. A secret field returns only:

~~~json
{
  "configured": true,
  "source": "config"
}
~~~

Saving an unchanged form preserves the existing secret. Replacing or clearing
a secret requires an explicit operation. Secrets never appear in frontend
state persistence, URLs, browser storage, API logs, operation records, or
support bundles.

### 9.3 Safe writes

Every change follows:

1. Validate the submitted typed patch.
2. Re-read the current configuration revision.
3. Reject a stale edit with a clear conflict response.
4. Create a private timestamped backup.
5. Write a same-directory temporary file.
6. Apply restrictive file permissions.
7. Parse and validate the temporary file.
8. Atomically replace the current file.
9. Re-run lightweight readiness checks.
10. Offer rollback if a dependent check fails.

The Manager never coerces all form fields to strings. In particular, false,
zero, an empty array, and a missing value remain distinct.

## 10. API surface

Application routes require a valid server-side session. The minimal liveness,
setup policy, login/pairing, and trusted-local session bootstrap endpoints are
unauthenticated. In Windows trusted-local mode, session bootstrap is automatic;
mutations still require same-origin CSRF validation.

### Setup and configuration

- GET /api/v1/setup
- GET /api/v1/config/schema
- GET /api/v1/config
- PATCH /api/v1/config
- POST /api/v1/config/validate
- GET /api/v1/config/backups
- POST /api/v1/config/backups
- POST /api/v1/config/backups/{id}/restore

### Integrations

- GET /api/v1/checks/integrations
- POST /api/v1/checks/integrations
- POST /api/v1/checks/tautulli
- POST /api/v1/checks/plex
- POST /api/v1/checks/smtp-network
- GET /api/v1/discovery/tautulli
- POST /api/v1/discovery/tautulli
- GET /api/v1/libraries
- GET /api/v1/users

The current Windows Manager implements the combined integration endpoint for a
post-save or manually repeated real compatibility check. It requires the
current configuration revision and an explicit request, allows only private or
loopback destinations, disables environment proxies and redirects, and never
runs from page load or status refresh. It validates Tautulli API authentication, user lookup, active
movie/TV libraries, and optional server information; direct Plex validation
uses `/identity` plus authenticated `/library/sections`. The implemented
`POST /api/v1/discovery/tautulli` route returns only sanitized active-library
and user display choices. The matching GET route restores the locally retained
choices only when their saved configuration revision still matches. The cache
excludes service addresses, email addresses, credentials, and raw responses.
For an active user without native email it may return only
`needsDeliveryAddress=true`; the private `UserEmailOverrides` map remains in
authenticated configuration editing and is never written to the discovery
cache or shareable diagnostics.
The separate implemented
`POST /api/v1/checks/smtp-network` route permits routable private or public
unicast SMTP providers and stops after DNS/TCP, greeting, EHLO, and
certificate-validated STARTTLS when configured. It never authenticates or
sends envelope/message data; TestEmail remains the authentication and sender
permission check. The other granular planned endpoints remain pending.

### Operations

- POST /api/v1/operations
- GET /api/v1/operations/{id}
- GET /api/v1/operations/{id}/events
- POST /api/v1/operations/{id}/cancel
- GET /api/v1/history

Operation creation accepts a typed enum and validated fields. It never accepts
an executable, script path, working directory, environment block, or command
string.

### Schedule and status

- GET /api/v1/status
- GET /api/v1/schedule
- PUT /api/v1/schedule
- POST /api/v1/schedule/install
- POST /api/v1/schedule/enable
- POST /api/v1/schedule/disable
- POST /api/v1/schedule/remove

The current Windows slice exposes `GET /api/v1/schedule/operation` and the
equivalent typed mutation route `POST /api/v1/schedule/{action}`, where
`action` is limited to `install`, `enable`, `disable`, or `remove`. Each
mutation requires CSRF protection, the current configuration revision, and an
explicit confirmation. The latest record stores only the action, timestamps,
exit code, sanitized category, and support code. Real UAC/SYSTEM-task
acceptance remains deferred to the live Windows host.

### Previews and diagnostics

- GET /api/v1/previews
- GET /preview/{opaque-id}
- POST /api/v1/diagnostics
- GET /api/v1/diagnostics/{id}

Preview routes map opaque identifiers to files already indexed beneath the
configured output root. User-supplied paths and path traversal are rejected.
Newsletter HTML is displayed in a sandboxed frame without script permission.

## 11. Operation behavior

Operations run asynchronously and expose structured progress:

- queued
- validating
- waiting-for-lock
- running
- finalizing
- succeeded, partial, failed, cancelled, or blocked

Server-sent events are preferred for progress, with polling as a fallback.
Progress text is emitted from known stage codes and sanitized arguments, not
raw log lines.

Only operations that can stop safely may expose Cancel. SendAll cannot be
blindly terminated after SMTP delivery begins because that can create an
unknown partial-recipient state. The UI instead shows that delivery is in
progress and explains the safety restriction.

Destructive or externally visible operations require confirmation:

- Test delivery: confirm the configured test recipient.
- Welcome delivery: confirm the selected account and one-off nature.
- Production delivery: explicitly confirm the real-recipient scope and review
  aggregate results.
- Schedule enable: confirm timezone, next run, and successful test prerequisite.
- Backup restore: show configuration revision and create a pre-restore backup.
- Update check: authenticated and explicit, with a fixed stable endpoint,
  bounded timeout/body, strict metadata verification, sanitized cache/backoff,
  and no network dependency in normal health or page load.
- Update install: Windows only, after a fresh verified check and a separate
  confirmation, through the fixed existing guarded updater. Host-managed
  packages show exact platform guidance and never receive web-process host
  mutation authority.

## 12. Screens and user flows

### 12.1 First-run wizard

1. Welcome and privacy boundary
2. Installation and private-data readiness
3. Tautulli URL and write-only API key
4. Active movie and TV library selection
5. Recipient exclusion selection
6. Optional direct Plex configuration
7. Sender and SMTP configuration
8. Schedule day, time, and timezone review
9. Theme and server display labels
10. Configuration review and save
11. Full verification
12. Generate all preview states
13. Send controlled test
14. Explicitly enable the schedule

The user can leave after configuration and return without losing completed
steps. Automatic delivery remains disabled until explicitly enabled.

### 12.2 Dashboard

- Overall state and concise explanation
- Manager, configuration, preview, scheduler, and integration cards
- Integrations lists Tailscale Funnel directly below SMTP. Verified Off and
  Active contribute Passed with distinct supporting text; publication pending
  contributes gold Attention; password, mismatch, stale/malformed, and cleanup
  blockers contribute Failed; unsupported or genuinely unconfigured surfaces
  remain neutral. The row deep-links and transfers focus to Settings > Tailscale
  Funnel.
- Last attempted delivery
- Last successful delivery
- Upcoming send with timezone
- Active operation and progress
- Configuration warnings
- Recent sanitized operation history
- Current release, cached update state, passive header notification, and bounded
  authenticated-entry refresh when status is missing or stale
- Direct links to preview, schedule, configuration, and diagnostics

### 12.3 Preview center

- Generate a selected-user preview
- Generate all six supported email states
- Clearly label real current-window data versus synthetic layout filler
- State that preview does not send mail or update welcome state
- Responsive frame presets for desktop and narrow email layout inspection
- Open the raw local preview in a separate authenticated tab

### 12.4 Configuration

Group typed controls by Connections, Branding, Sender, Schedule, Newsletter,
Libraries, Recipients, Cache, and Advanced. Provide search, changed-field
review, inline validation, backup creation, and rollback.

Keep all five revision-scoped setup results, including the full deleted-item
cache result, permanently visible for every valid configuration. Update each
result as automatic or manual checks complete, retain only aggregate evidence
in private Manager state, and show all five in the Dashboard Config status
health card. A dedicated cache refresh changes the cache step directly to blue
**Running** and remains independent of PreviewAll; reserve Warning for a
completed, actionable finding and Failed for a failed or cancelled refresh.
The full local result is retained for Verify and refresh, while manual
verification remains an optional later recheck. Results from an older
configuration revision must never update the current summary.

### 12.5 Diagnostics

Show sanitized checks and support codes. A downloadable support bundle is
opt-in and must exclude configuration values, previews, newsletters, state
containing user identity, raw logs, credentials, and private network details.

## 13. Authentication and network security

### 13.1 Binding defaults

- Windows on-demand: loopback only
- macOS Docker: loopback host mapping only
- Native Linux: loopback only
- NAS Docker, QNAP/Synology, and Unraid: loopback host mapping only
- FreeBSD Podman: loopback host mapping only

Maintained packages do not offer a broad bind. Local recovery uses loopback or
an SSH local forward. Optional public-internet exposure uses only the exact
password-gated Tailscale Funnel route after public DNS and trusted TLS verify.

### 13.2 Bootstrap and local access

Windows on-demand mode trusts the local Windows account by default: the
loopback-only Manager creates a protected browser session automatically and
does not generate a pairing token. Settings provide an optional password lock
with create, change, disable, and OS-local recovery. Recovery disables only the
Manager lock and preserves configuration, credentials, schedule, history, and
previews.

Any runtime mode that permits network access requires authentication. On its
first start, generate a one-time pairing secret in the private data root with
restrictive permissions. Container users retrieve a short pairing code from
the local console or install workflow. Pairing creates the administrator
credential and immediately invalidates the bootstrap secret.

Passwords are stored only as a modern salted password hash. Sessions use
random server-side tokens in Secure, HttpOnly, SameSite=Strict cookies where
transport permits. A non-TLS trusted-LAN deployment receives a persistent
warning.

Every platform reuses the same visible access-state control. The closed green
lock or open gold lock opens the password controls directly. Its tooltip uses
the platform boundary rather than Windows-only copy: `Browser access` for the
loopback Windows package, `Container access` for maintained container builds,
and `Manager access` for other native packages. Required-auth deployments may
change their password there but cannot disable the mandatory boundary.

### 13.3 Web controls

- No permissive CORS
- Origin and Host validation
  - Canonical authority comparison lower-cases DNS, removes one trailing dot,
    and treats omitted `:80`/`:443` like the explicit default while still
    requiring the exact request scheme and host. Malformed origins, different
    hosts, and HTTP mutations through an admitted Tailscale hostname use
    sanitized support codes and are rejected. Forwarded headers are ignored.
- CSRF protection on mutations
- Content Security Policy
- Frame restrictions except the dedicated sandboxed preview route
- Login and pairing rate limits
- Request body and upload size limits
- Secure cache headers for secrets and status
- No secrets in errors or logs
- Dependency pinning and software bill of materials

## 14. Packaging

### Windows

The release builder cross-compiles the Manager and one-click installer as
reproducible Windows amd64 PE executables. The installer embeds the verified
portable ZIP and approved application icon, installs per-user application
files under the user-selected application folder (defaulting to
`%LOCALAPPDATA%\Programs\TautWeekly`), records and reuses that location for
in-place upgrades, keeps Manager state under
`%LOCALAPPDATA%\TautWeekly\data`, registers per-user shortcuts/uninstall, and
opens the Manager. It requires no UAC; only the typed Task Scheduler lifecycle
helper elevates. `00-OPEN-MANAGER.bat` in the portable fallback invokes a
fixed PowerShell launcher that starts the Manager hidden on
`127.0.0.1:8788`; the Manager opens the browser only after binding the listener
and enters trusted-local setup directly. The installer and portable package
also include a local optional-lock recovery helper. Existing BAT files remain
available. Release manifests and the guarded Windows updater own
the binary and launcher, explicitly exclude `.manager-data`, and stop/restart
only the exact packaged Manager executable when necessary.

The installer lifecycle test covers fresh install, Manager boot/health,
upgrade, legacy Manager-state migration, approved shell icon, and uninstall
while preserving private files. Code signing is strongly recommended before
broad release; the current executable is intentionally unsigned.

### NAS and macOS containers

Build Manager binaries for Linux amd64 and arm64 and copy the matching binary
into the existing image. Embed frontend assets in the binary. Keep one mapped
HTTP port and the current data volume. Do not add a Docker socket, privileged
mode, or root runtime.

### Native Linux

Include the matching binary in the Linux archive. The installer owns program
files under /opt and preserves data under /var/lib. Update the hardened
systemd unit and acceptance tests.

### FreeBSD

Use the same multi-architecture Linux OCI image through Podman. Preserve the
current rc.d host integration and private /var/db data root.

## 15. Upgrade and compatibility behavior

- Existing valid config.json is imported in place; secrets remain write-only.
- Existing state, access roster, deleted-item cache, output, and backups are
  preserved.
- A migration has a version, preflight, private backup, validation, and
  rollback path.
- Starting an older package against a newer unsupported manager schema fails
  closed with recovery instructions.
- The WebGUI package version, API contract version, config schema version, and
  renderer version are reported separately.
- BAT and shell launchers continue to work during migration.
- Scheduled delivery remains disabled by default on a new installation.

## 16. Testing strategy

### Go unit tests

- Configuration typing, validation, redaction, migration, and rollback
- Schedule computation across timezones and daylight-saving transitions
- Heartbeat freshness and degraded-state rules
- Windows, Docker, Linux, and FreeBSD adapter normalization
- Operation allowlist and argument validation
- Path containment and preview identifier mapping
- History rotation and malformed-record recovery
- Secret and private-data redaction

### API integration tests

- Trusted-local session bootstrap, optional password lifecycle, recovery, and
  mandatory-mode pairing
- Unauthorized access to every protected route
- CSRF and Origin enforcement
- Stale configuration conflict
- Operation queuing and lock contention
- Structured progress and failure mapping
- Fake Tautulli, Plex, and SMTP services
- No secret returned by configuration, errors, events, or diagnostics

### Frontend tests

- Wizard completion and resume
- Configuration type preservation
- Preview labeling and sandbox behavior
- Schedule enable confirmation
- Keyboard-only operation
- Screen-reader names and live announcements
- Automated accessibility checks
- Desktop, tablet, and narrow mobile visual regression
- Reduced-motion behavior

### Platform tests

- Windows portable install, UAC schedule helper, SYSTEM task, upgrade, rollback
- Windows PowerShell 5.1 compatibility for the retained renderer
- Container amd64 and arm64 build and boot
- Container health during a long SendAll operation
- Container remains healthy but reports unconfigured before setup
- Scheduler heartbeat staleness becomes unhealthy without checking external
  Tautulli or SMTP
- Native Linux systemd hardening and private-data permissions
- FreeBSD real-host Podman and rc.d acceptance
- Reproducible archives, checksums, manifests, and software bill of materials

## 17. Acceptance criteria

The Windows MVP is complete when:

- A new user can configure, verify, preview, test, and schedule without opening
  a terminal or editing JSON.
- The existing BAT workflows still work.
- Normal configuration reads never return a stored secret; the only exception
  is the explicit, single-field, temporary reveal workflow.
- Task Scheduler status matches the dashboard.
- A failed or partial send is not displayed as a successful delivery.
- Configuration changes are typed, backed up, and recoverable.
- No operation can execute an arbitrary command.
- Desktop and mobile browser QA passes.

The Docker MVP is complete when:

- The Manager replaces the read-only preview server without changing the data
  volume contract.
- Runtime, scheduler heartbeat, last attempt, last success, and upcoming send
  are visible.
- Long newsletter runs do not create false container-health failures.
- Missing configuration is shown as unconfigured rather than crashed.
- External dependency outages are degraded status, not restart triggers.
- The container remains non-root and has no Docker or Podman socket.
- NAS and macOS Compose upgrades preserve all private data.

The multi-platform release is complete when:

- The same frontend and API contracts pass on all maintained packages.
- Only platform lifecycle and scheduler adapters differ.
- Linux and FreeBSD host acceptance is documented.
- Release archives, containers, checksums, rollback behavior, and support
  boundaries are verified.

## 18. Effort estimate

These are engineering estimates, not release promises.

| Workstream | One experienced engineer |
|---|---:|
| Contracts, threat model, and portable skeleton | 2-3 weeks |
| Windows production MVP | 5-7 additional weeks |
| NAS and macOS Docker adapter | 3-5 weeks |
| Native Linux and FreeBSD integration | 3-5 weeks |
| Accessibility, security, release hardening, and real-host acceptance | 3-4 weeks |

Expected production-quality total: approximately 16-24 engineer-weeks. A
small team can overlap frontend, Go backend, platform integration, and tests,
but security and release acceptance remain sequential gates.

## 19. Historical first implementation batch

The first code delivery was intentionally scoped to this narrow foundation:

1. Add the Manager source tree and reproducible frontend build.
2. Define status, configuration-redaction, and operation schemas.
3. Implement loopback-only serving and trusted-local session bootstrap.
4. Implement a read-only Windows adapter for config readiness, Task Scheduler,
   previews, and version.
5. Render the production dashboard with fictional test fixtures and live local
   status.
6. Add unit, API, accessibility, and desktop/mobile browser tests.

Configuration mutation, guarded TestEmail delivery, and typed elevation were
added only after the read-only trust boundary and contracts were reviewed.
Container packaging remains a later delivery.

Implementation progress: the portable Go service, loopback and trusted-local
session boundary, optional recoverable password lock, mandatory-mode pairing,
Windows read-only status adapter, secret-redacted configuration API,
sandboxed preview viewer, responsive frontend, and unit/API coverage now exist
under `manager/`. The Windows configuration editor adds schema validation,
optimistic revision checks, atomic replacement, private backups, and write-only
secret updates. Configuration backups can be listed without exposing their
contents and restored after schema validation, revision confirmation, and a
pre-restore safety backup. A successful save now consumes a typed backend
impact plan: Tautulli changes rerun discovery and integration checks, Plex
changes rerun integration checks, SMTP-card changes rerun only SMTP preflight,
and identity/newsletter-content/custom-card/library changes regenerate local
  previews. Enabled cache and coverage changes start the dedicated all-included-
  user cache refresh independently; cache disable, email, schedule, and
  delivery-delay-only saves retain all applicable results and run no setup
  check or preview work. Each check remains
manually repeatable under Verify; page load and status refresh never contact
external services. Local loopback fixtures cover the adapters in automated
tests and explicit live-LAN acceptance has passed.
The four sanitized discovery/network/SMTP/preview results are persisted in
private, revision-scoped Manager state and rendered with the live aggregate
cache result as permanent Config rows and a Dashboard Config status card. The
cache result is never added to that evidence file. A save safely rebases
unaffected sanitized results when their relevant inputs are unchanged; a
restore resets them to not-run. Manual retests update the same record, and late
results from an older revision are rejected.
Guided Tautulli discovery returns only stable numeric IDs, sanitized library
names, user display names, media types, counts, eligibility enums, and explicit
owner/administrator roles. Its private local cache is revision-scoped; API keys,
service URLs, email addresses, credentials, and raw responses are excluded. A
separate SMTP preflight validates reachability and
STARTTLS without sending credentials or message data, with deterministic plain,
missing-STARTTLS, certificate-validated STARTTLS, CSRF, and redaction tests.
The typed Windows renderer operations now run `PreviewAll`, userless
`CacheWarm`, guarded `SendTestAll`, and explicitly confirmed `SendAll`.
`CacheWarm` applies the production eligibility and selected-library scope to
every included user's current newsletter window, reports aggregate counts only,
and automatically hands off to full local cache verification. Preview generation adds
headless `-NoOpen` behavior, supports
safe cancellation and restart recovery, and attributes only files changed by
that run. Test delivery is limited by the renderer to the saved `TestEmail`,
records aggregate SMTP acceptance only, and exposes no unsafe cancellation.
Manual production delivery uses the same fixed renderer contract as the
schedule, accepts no browser-supplied user or command input, cannot be
cancelled, and retains aggregate accepted, skipped, and failed counts. The
shared `SendAll` path makes exactly one bounded `refresh_users_list` request
under the renderer lock before reading or classifying Tautulli's live roster;
failure stops before SMTP with an allowlisted count-only category. Manager
discovery cache is never the production recipient source. All
three write bounded sanitized current/history records without the user ID,
    configuration, service addresses, command line, or raw process output. The
    renderer's opt-in structured result contains only mode, outcome, one fixed
    allowlisted failure category, timing, delivery scope, aggregate counts, and
    preview basenames. Schema v3 may additionally retain a fixed SMTP category
    and stage, numeric response code/class, batch-fatal state, and acceptance
    state; raw provider text, accounts, hosts, recipients, and credentials are
    rejected. Authentication, temporary provider/service, batch-wide,
    transport, and ambiguous-DATA failures stop SendAll before another SMTP
    connection. A permanent 5xx RCPT rejection is recipient-specific only when
    its enhanced status identifies an address or mailbox condition,
    and the configured delay applies before the next attempt even after that
    failure. Manager-triggered service-package work attempts the
    shared renderer lock without waiting and maps lock exit 75 to
    `operation-busy`; host CLI and lifecycle waits are unchanged. Scheduled Windows
    `SendAll` writes this to ignored private `last-run.json` so the dashboard can
distinguish process execution, SMTP acceptance, and inbox delivery.

The Windows schedule page reports installed, enabled, runtime, next-run, and
ownership state, and exposes typed install/refresh, enable, disable, and remove
actions through the narrowly scoped UAC helper. API and process-boundary tests
use injected fictional runners and probes. A separate live Windows acceptance
run verified install/refresh, disable, enable, idempotent refresh, and removal
without executing the newsletter task. Desktop/mobile browser QA uses reviewed
fictional fixtures by default; separately authorized live-LAN checks have also
verified Tautulli, direct Plex, SMTP preflight, preview generation, and
TestEmail delivery. The extracted Setup lifecycle now covers fresh install,
verified in-place update, old-portable-folder migration, rollback, Manager
launch, and uninstall privacy. Task ownership and installer private-path
collisions have negative tests. Remaining Windows risks are the unsigned
SmartScreen/code-signing experience, full screen-reader/assistive-technology
acceptance, and the absence of a multi-run production delivery journal. Static
accessibility structure, keyboard focus, reduced-motion CSS, and desktop/mobile
browser checks are automated or completed with fictional fixtures.

The shared Settings surface adds package-aware Tailscale access below the
existing browser/access card. Native Windows and native Linux use the shared
provider-neutral public controller: enablement requires the active password
lock, and the browser submits only typed `enable`, `disable`, or `verify`.
The platform adapter owns the fixed Manager loopback target and CLI arguments,
verifies exact TCP/Web/AllowFunnel plus public DNS/trusted-TLS postconditions,
and refuses unrelated configuration. Windows uses the fixed UAC helper; Linux
uses the root-owned socket-activated one-shot helper. Password-lock disable,
access reset, explicit stop, adapter revocation, update, and uninstall first
verify the owned route off. Only an exact publicly verified hostname is
persisted and admitted; Secure/HttpOnly/SameSite cookies, HTTPS origin, CSRF,
HSTS, authenticated endpoints, and secret boundaries apply through the proxy.

Container, macOS, FreeBSD, QNAP, Synology, Unraid, and compatible Docker modes
use the same public controller through an isolated userspace adapter copied
from the pinned official Tailscale image. A root-only process owns separate
provider state and the fixed local target; the non-root Manager receives no
provider credential, Docker/Podman socket, host executable, TUN device,
network privilege, arbitrary command, hostname, port, path, or CLI argument.
Browser requests remain typed operations only. The detailed state model,
inventory, and adapter boundary are in [REMOTE-ACCESS.md](REMOTE-ACCESS.md).

## 20. Decision gates

Review and approve these before implementation expands:

- Configuration schema and secret lifecycle
- Authentication experience for trusted-local and network-accessible modes
- Operation and delivery record privacy fields
- Windows elevation helper design
- Container liveness versus readiness rules
- Whether the frontend uses React or a smaller TypeScript stack
- Visual identity and trademark review
- Release signing and support policy

These gates prevent UI convenience from weakening the safety boundaries
already present in the maintained TautWeekly packages.
