# macOS Docker Desktop Manager

[Open the macOS Quickstart](https://sparkmoxie.github.io/TautWeekly/mac/)

The supported first-choice Mac deployment is one standalone Compose file backed
by the shared public `ghcr.io/sparkmoxie/tautweekly` image and its explicit
`desktop` profile. It needs no repository clone and no local application build
on either Intel or Apple-silicon Macs. The profile keeps the proven loopback
Manager, `host.docker.internal` behavior, embedded scheduler, health check,
graceful shutdown, named-volume persistence, and read-only security boundary.
Manager **Config** remains the source of truth for setup, verification, previews,
controlled TestEmail delivery, scheduling, profile/image status, and recovery.

The verified Mac archive and local image build remain a supported break-fix
fallback. The unified registry deployment is the preferred installation.

Current source baseline: **1.8.0**.

Manager Config shows a separate **Managed-user delivery addresses** card when
Tautulli reports an active user without native email. Assignments stay in the
private data volume and its backups, may share an inbox, and never override a
native address. Existing user-ID and effective-address exclusions still apply;
TestEmail remains isolated. See the
[configuration reference](../CONFIGURATION.md#interactive-user-exclusions).

## Requirements

- Intel (`x86_64`) or Apple silicon (`arm64`) macOS host.
- Current Docker Desktop with Docker Compose available in Terminal.
- A private working directory for the standalone Compose file and backups.
- Network access from the container to Tautulli, Plex, and an SMTP STARTTLS
  endpoint. No real service is contacted during package validation.

## Registry-first install

The release Compose asset pins a full semantic version. `latest` is published
only as a convenience and is not the supported automation pin. For v0.25.0:

```bash
mkdir -p ~/TautWeekly && cd ~/TautWeekly
TAUTWEEKLY_VERSION=0.25.0
curl -fLO "https://github.com/sparkmoxie/TautWeekly/releases/download/v${TAUTWEEKLY_VERSION}/TautWeekly-mac-compose.yaml"
curl -fLO "https://github.com/sparkmoxie/TautWeekly/releases/download/v${TAUTWEEKLY_VERSION}/SHA256SUMS.txt"
grep '  TautWeekly-mac-compose.yaml$' SHA256SUMS.txt | shasum -a 256 -c -
mv TautWeekly-mac-compose.yaml compose.yaml
docker compose pull tautweekly
docker compose up -d tautweekly
docker compose ps
```

The Compose file pulls the matching public amd64 or arm64 manifest, publishes
Manager only on `127.0.0.1:8787`, and stores all private state in the named
`tautweekly-data` volume mounted at `/data`. It does not generate or print a
default password. `docker compose ps` should report the service as healthy;
startup may take up to the configured 90-second health start period.

For CI/CD, keep the full tag or pin the same manifest by digest:

```yaml
image: ghcr.io/sparkmoxie/tautweekly:0.25.0@sha256:<manifest-digest>
```

Inspect the release manifest with
`docker buildx imagetools inspect ghcr.io/sparkmoxie/tautweekly:0.25.0`.
A digest pin is immutable; a full-semver pin is the readable supported default.
The `0.25`, `latest`, and `edge` tags are mutable and unsuitable for unattended
promotion.

## First-run Manager setup

The Manager is published only at `http://localhost:8787/` by default.

1. Retrieve the one-time pairing token from the working directory:

   ```bash
   docker compose exec -T tautweekly /opt/tautweekly/bin/run-as-user.sh \
     /opt/tautweekly/bin/tautweekly-manager access-bootstrap --data-dir /data/manager
   ```

2. Open `http://localhost:8787/` in a Mac browser.
3. Enter the token and create a unique administrator password. The token is
   read only by that explicit command, never written to Docker logs or
   diagnostics, and invalidated after pairing.
4. Open **Config**, enter the Tautulli, Plex, SMTP, content, and schedule
   settings, then select **Validate, save, and verify**.
5. Confirm the saved setup results for libraries/users, Tautulli and Plex,
   non-sending SMTP preflight, local previews, and deleted-item cache health.
6. In **Previews**, review all six newsletter states. In **Operations**, send
   the explicit controlled TestEmail check. Enable **Schedule** only after the
   configured timezone, next run, previews, and SMTP result are correct.

When deleted-item cache storage is enabled or its coverage changes,
**Validate, save, and verify** starts a separate no-email refresh for every
production-eligible included user's current newsletter window in the selected
movie/TV libraries. It does not depend on PreviewAll or one selected preview
user. Run `./tautweekly.sh cache-refresh` for an explicit refresh. Disabling
the cache stops reads and writes without deleting retained entries.

Pairing, login, CSRF protection, session expiry, throttling, credential reveal,
and diagnostics use the shared Manager security contracts. Browser reads never
return stored secrets. A service restart invalidates active browser sessions
without disabling the newsletter schedule.

### Optional custom newsletter text card

The optional Config card immediately after **Cache** places administrator text
before the newsletter release-count/date block. It is disabled by default.

| Option | Default | Accepted value |
|---|---:|---|
| Enabled | `false` | On or off |
| Border color | `#72aef7` | Six-digit hex color |
| Border opacity | `34` | Integer 0-100; 0 hides the border |
| Title | empty | Optional gold uppercase text, 0-120 characters |
| Subheading | empty | Optional large white text, 0-200 characters |
| Body | empty | Required plain text, 1-2000 characters when enabled |

Title and subheading are independently optional, and the layout rebalances
when either is omitted. Line breaks are preserved, and content is escaped for
normal and welcome HTML, the plain-text alternative, and generated previews.
An empty or whitespace-only body blocks browser and Manager API validation,
save, and verification. See the
[configuration reference](../CONFIGURATION.md#optional-custom-text-card).

## Connect to Mac-hosted Plex and Tautulli

Docker Desktop exposes software running directly on the Mac through
`host.docker.internal`:

```text
http://host.docker.internal:8181   # example Tautulli URL
http://host.docker.internal:32400  # example direct Plex URL
```

For another server, use a name or address reachable from the container. For a
service on the same user-defined Docker network, use its container service
name. Container `127.0.0.1` refers to TautWeekly itself, not the Mac.

Direct Plex access is recommended for full provider ratings, exact-episode
metadata, backgrounds, and selected logos. Manager verification sends the Plex
token in the `X-Plex-Token` header and tests `/identity` plus authenticated
`/library/sections`; it does not put the token in a URL or browser response.

## Metadata readiness before acceptance

After first setup, after changing a Plex metadata agent or **Ratings Source**,
or after a ratings/artwork recovery update when upstream data may be stale:

1. Confirm **Edit > Advanced > Ratings Source** for every included Plex Movie
   library.
2. Run Plex **Manage Library > Refresh All Metadata** for every included movie
   and TV library, and wait for completion.
3. In Tautulli, open each same **Library > Media Info** tab, select
   **Refresh media info**, and wait. The current control is per-library, so
   repeat it for every included section.
4. Return to Manager **Verify**, regenerate PreviewAll, and repeat the
   controlled TestEmail acceptance check.

A full Plex refresh may take substantial time and change artwork. Routine TautWeekly updates do not require a full refresh when current output already
renders correctly.

## Scheduling and graceful lifecycle

The newsletter scheduler is independent from the browser session. Manager
Schedule changes only the typed persistent enable/disable setting; it cannot
alter Docker Desktop, ports, volumes, UID/GID, or host startup settings.
Disabling a future schedule does not cancel a newsletter already running.

Docker Compose grants stop/restart up to 30 minutes. On shutdown, the Manager
stops accepting new work, the supervisor waits for an active newsletter
operation to finish, and only then stops the scheduler. The bounded grace
prevents an ordinary Docker Desktop restart from silently cancelling delivery.

Use Compose from the working directory for lifecycle status:

```bash
docker compose ps
docker compose logs -f --tail=200 tautweekly
docker compose up -d tautweekly
docker compose down
docker compose up -d --force-recreate tautweekly
```

Recreation replaces only the service container. The named `/data` volume—and
therefore configuration, credentials, Manager access state, schedules, output,
and delivery history—remains attached. The archive fallback offers equivalent
commands through `./tautweekly.sh`.

## Network and TLS

Both macOS Compose paths keep the authenticated Manager on
`127.0.0.1:8787`. Keep that fixed loopback mapping; do not override it with
`0.0.0.0`, a LAN address, host networking, or a router/firewall rule. Local
recovery uses `http://127.0.0.1:8787/`; the selected public ingress is the
fixed-target Tailscale Funnel below.

Exact Host/origin admission, CSRF, HttpOnly/SameSite sessions, and the public
Secure-cookie decision remain backend-owned. An independently verified active
Funnel hostname is admitted automatically. `Forwarded` and `X-Forwarded-*`
never override Host, origin, or TLS checks. `GET /health/live` exposes only
liveness; configuration, paths, versions, credentials, and newsletter state
remain authenticated.

### Optional public Tailscale Funnel

The maintained macOS Docker Desktop package includes the same isolated Funnel
adapter as NAS/Docker. A remote viewer needs only an ordinary browser and the
Manager password; the viewer does not install Tailscale or join a tailnet.
Manager stays on its fixed container-local target.

1. Set `TAUTWEEKLY_FUNNEL_ADAPTER=enabled` in `.env`.
2. Run `./tautweekly.sh restart` to recreate the service.
3. Run `./tautweekly.sh remote-access-login` and complete the official browser
   sign-in. TautWeekly never receives an auth key, token, or account password.
4. Create and enable the Manager password lock locally.
5. In **Settings > Tailscale Funnel**, choose **Enable**. Use the public address
   only after status is green **Active**. Gold **Publication pending** means the
   exact local route exists but public DNS or trusted TLS is not ready.

The root-only userspace adapter owns separate persistent state and only the
fixed target `http://127.0.0.1:8080`. The non-root Manager has no Docker socket,
host executable, TUN device, host network, added networking capability,
credential, arbitrary command, hostname, port, path, or CLI argument.

Disable from Settings or run `./tautweekly.sh remote-access-disable` before
maintenance. Stop, reset, recovery, and removal use the same verified
cleanup and fail closed if the exact owned public route cannot be disabled.
Normal Manager restart, verified package/image update, recreate, and rollback
preserve Funnel. Retain local access for recovery after abrupt host power loss
or `SIGKILL`, when no process can perform shutdown cleanup.

## Newsletter behavior

A Hot New Release movie hero pairs with the server-wide Trending footer. A
movie-empty Trending week uses up to four other recent movies and instead pairs
the hero with the privacy-preserving Top Genre footer. With new TV, up to four
series appear under **New Releases / TV**, and the visible count plus inbox
preview text say `0 NEW MOVIES • X TV TITLE(S)`. Without new TV, up to four
series strictly newer than one month appear under **Recent Releases / TV**, and
both count locations say
`1 TRENDING MOVIE • X RECENT MOVIE RELEASE(S)` when the real hero exists.

Top Genre uses only aggregate qualified movie watch time and unique movie
count; it never includes viewer identity and safely falls back to the neutral
movie animation. Its supporting line and every Binge Champion movie/TV
breakdown use the same supporting typography as personal total watch time.

Watched marks use only the selected recipient's all-time Tautulli movie history.
Review the desktop poster shield and the title circles with uniform 6px spacing,
vertical centering, and `title="Watched"`. Unwatched movies leave no icon gap and
TV is unchanged. See the [watched-state rule and privacy boundary](../CONFIGURATION.md#recipient-movie-watched-markers).

## Persistent data, permissions, and backup

The image is read-only. Writable runtime state is limited to `/data` and a
bounded in-memory `/tmp`. The standalone Compose file uses a Docker named volume
by default, so no host-path permissions or repository checkout are required.
The entrypoint runs the service as the non-root `PUID`/`PGID` identity (1000:1000
by default), creates private paths, and repairs only legacy ownership within
the dedicated `/data` filesystem.

For a visible host bind mount, create `data/`, replace
`tautweekly-data:/data` with `./data:/data`, and set the Mac identity in a
mode-0600 `.env` before the first start:

```bash
mkdir -p data
printf 'PUID=%s\nPGID=%s\nUMASK=077\n' "$(id -u)" "$(id -g)" > .env
chmod 600 .env
docker compose up -d --force-recreate tautweekly
```

Do not use UID/GID 0. The container refuses a root runtime identity. Docker
Desktop file sharing must allow the chosen bind path. Named volumes are the
recommended no-clone default; bind mounts are supported when host-visible files
are an explicit requirement.

Back up before updates or recovery:

```bash
umask 077
docker compose exec -T tautweekly tar -C /data -czf - . > "tautweekly-data-$(date +%Y%m%d-%H%M%S).tar.gz"
```

The backup contains configuration, credentials, Manager authentication state,
schedules, output, and the bounded deleted-item cache; keep it private. For a
bind mount, a stopped copy of `.env` and `data/` is also a complete private
filesystem backup.

## Unified image updates and rollback

Manager **Settings > Updates** is the primary Mac status source. It separately
reports the container application/image, registry Compose deployment,
host-adapter compatibility, stable channel, latest stable release, check
history, sanitized failure, and release notes. A stable release is accepted
only when it contains the matching standalone Compose asset. Authenticated
entry renders cached status first and makes one non-blocking bounded check only
when the last success is missing or at least 24 hours old and backoff permits.
Successful results are reused for five minutes before **Check now** refreshes
the same endpoint. Navigation, Dashboard rendering, and Manager health remain
offline-capable. The containerized web process cannot invoke Docker Desktop or
change Compose, so the card exposes a copyable pull/recreate command but no
install button.

The release workflow publishes both the NAS and Mac multi-architecture
manifests before it can publish the GitHub release and its Compose asset. This
prevents a successful release from silently advertising a Mac image that did
not publish. macOS does not enable unattended updates.

To upgrade:

1. Create a private `/data` backup and record the current exact image reference.
2. Review the new release notes. Set both the readable version and, for an
   immutable CI/CD pin, the reviewed manifest digest in `.env`:

   ```dotenv
   TAUTWEEKLY_VERSION=0.25.0
   TAUTWEEKLY_IMAGE=ghcr.io/sparkmoxie/tautweekly:0.25.0@sha256:<manifest-digest>
   ```

3. Pull and recreate only the service:

   ```bash
   docker compose pull tautweekly
   docker compose up -d --force-recreate tautweekly
   docker compose ps
   ```

4. Open Manager, sign in again if recreation invalidated the session, and
   verify **Settings > Updates**, Manager/scheduler health, Config status, all
   six previews, and the controlled TestEmail result.

Compose never replaces the named or bind-mounted `/data`. If a pull is
interrupted, rerun it; the old container continues until recreate. If recreate
is interrupted, rerun `docker compose up -d --force-recreate tautweekly` and
check health. If the candidate is unhealthy, restore the previous
`TAUTWEEKLY_VERSION` and `TAUTWEEKLY_IMAGE`, pull if needed, and recreate. The
same `/data` then attaches to the previous image. Do not delete the volume or
run `docker compose down -v` during upgrade or rollback.

## Migrate the v0.22.0 Mac-specific image

The old `ghcr.io/sparkmoxie/tautweekly-mac:0.22.0` manifest remains pullable
for rollback but receives no v0.23.0 or later tags. Back up `/data`, record the
old digest, preserve the exact named volume or bind mount and
`PUID`/`PGID`/`UMASK`, then replace only the image reference and add
`TAUTWEEKLY_RUNTIME_PROFILE=desktop` plus
`TAUTWEEKLY_PACKAGE_KIND=container-desktop`. Pull before recreation, wait for
healthy status, sign in with the existing Manager password, and verify Config,
schedule/history persistence, all six previews, and TestEmail. If the pull or
recreate is interrupted, rerun it against the same mount; if health fails,
restore the recorded v0.22.0 image reference and recreate. Never use
`docker compose down -v`.

The transitional `TautWeekly-mac-compose.yaml` remains through v0.24.x and may
be retired no earlier than v0.25.0 with release-note notice. See the
[complete unified image migration contract](../CONTAINER-MIGRATION.md#migrate-the-v0220-mac-specific-image)
for named-volume and bind-mount backups, intentional LAN exposure,
`host.docker.internal`, permission recovery, pairing, rollback, and
interrupted-delivery guidance.

## Archive/local-build fallback

Download `TautWeekly-mac-docker.tar.gz` or the matching ZIP plus
`SHA256SUMS.txt` from one stable release when registry access is unavailable or
the standalone path needs break-fix isolation. Verify SHA-256, extract to a
permanent directory, and run `./mac-install.sh`. The installer detects the Mac
UID/GID, creates a private `.env`, builds the architecture-specific image
locally, and keeps private state in the package `data/` bind mount.

The fallback `./tautweekly.sh update` path still verifies the release checksum
and internal `RELEASE-FILES.txt`, coordinates the operation lock, rebuilds the
local image, verifies health/version, and rolls package files plus the previous
image back together on failure. Existing archive installations may remain on this supported break-fix path.
Migration to the unified registry image is recommended but never requires a
private-data move when the same bind mount is reused.

For packages at or before v0.14.0 whose Manager reports a `legacy` host adapter,
verify and extract the current Mac archive over the same directory without
deleting `.env` or `data/`, then run `./tautweekly.sh update` once.

Manager **Config > Configuration backups** can permanently delete one selected
configuration backup only after **Confirm delete**. This leaves the live
configuration unchanged and cannot be undone.

## Password recovery, reinstall, and uninstall

If the Manager password is lost:

```bash
docker compose exec -T tautweekly /opt/tautweekly/bin/run-as-user.sh \
  /opt/tautweekly/bin/tautweekly-manager access-recover --data-dir /data/manager --confirm
docker compose restart tautweekly
docker compose exec -T tautweekly /opt/tautweekly/bin/run-as-user.sh \
  /opt/tautweekly/bin/tautweekly-manager access-bootstrap --data-dir /data/manager
```

Recovery resets only the administrator password and active sessions, waits for
any active newsletter during the controlled restart, and preserves
configuration, schedules, history, output, and delivery state.

For repair/reinstall, pull the same exact tag or digest and run
`docker compose up -d --force-recreate tautweekly`; `/data` remains attached.
To uninstall the service but retain data, run `docker compose down` without
`-v` and keep the private backup plus `.env`/Compose files. Delete the Docker
volume, bind-mounted `data/`, `.env`, and backups only when the user explicitly
wants all configuration, credentials, schedules, history, output, and cache
removed. Neither deployment path deletes them implicitly.

Archive fallback users may use `./tautweekly.sh manager-reset-access`,
`manager-bootstrap`, `update`, and `stop` for the same scoped operations.

## Expert/recovery commands

Registry users can invoke the allowlisted `/opt/tautweekly/bin/run-script.sh`
and `run-mode.sh` helpers through `docker compose exec tautweekly`; the archive
fallback exposes the same `setup`, `verify`, `preview-all USER_ID`,
`cache-refresh`, `cache-status`, `send-test-all USER_ID`, library/user
selectors, and schedule commands through
`./tautweekly.sh`. They are not the normal Mac setup source.
Real-recipient `welcome` and `send-all` commands retain explicit confirmation.
Manager's **Repeat this Tautulli lookup** refreshes only the displayed choices;
every manual or scheduled SendAll performs one bounded Tautulli/Plex user-list
refresh before reading the live roster. A newly eligible user is included
unless explicitly excluded, and an unconfirmed refresh stops before SMTP with
fixed sanitized guidance.

Direct configured SMTP remains the standard path. New configurations use
`SendDelaySeconds=30` and `TestSendDelaySeconds=10`. SendAll stops after an
authentication, temporary provider/service, batch-wide, transport, or
ambiguous-DATA failure instead of reconnecting for every remaining recipient;
an address/mailbox-specific RCPT rejection may continue after the configured
delay. Avoid
Test All or a manual production run near the scheduled batch, and stop retries
during a provider account lock.

## Limitations

- Docker Desktop must be installed, running, and allowed to keep the service
  active; this package does not add a macOS Login Item or background agent.
- It does not ship a native `.app`, menu-bar item, or Apple-notarized installer.
- The Manager is containerized Linux with a truthful `macOS Docker Desktop`
  capability profile; it does not pretend to control native macOS services.
- Automated validation covers shell contracts, amd64/arm64 Manager builds,
  archive contents, security/accessibility behavior, synthetic integrations,
  and Docker-compatible lifecycle rules. A physical Intel/Apple-silicon Mac
  and Docker Desktop remain release acceptance gaps when unavailable in CI.

See [configuration](../CONFIGURATION.md), [security](../SECURITY.md), and
[troubleshooting](../TROUBLESHOOTING.md).

## Bundled asset updates

Shipped email asset filenames are release-owned: updates may replace same-name
custom artwork. Custom-only filenames and unrelated private/runtime data are
preserved. For the bundle marker, restart behavior, explicit repair, and Windows
update differences, see [bundled email assets](../EMAIL-ASSETS.md).
