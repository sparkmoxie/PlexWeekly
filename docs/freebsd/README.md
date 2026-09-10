# FreeBSD installation with Podman

The FreeBSD distribution runs the maintained TautWeekly Linux OCI image through
FreeBSD's Podman Linux-container support. It integrates with the native `rc.d`
service system, exposes the authenticated Manager on host loopback by default,
and keeps configuration, Manager credentials, state, generated output, and
backups in `/var/db/tautweekly`.

[Open the FreeBSD Podman Quickstart](https://sparkmoxie.github.io/TautWeekly/freebsd/)

Current source baseline: **1.4.0**.

Manager Config shows a separate **Managed-user delivery addresses** card when
Tautulli reports an active user without native email. Assignments stay in
private `/var/db/tautweekly/config.json` and its backups, may share an inbox,
and never override a native address. Existing user-ID and effective-address
exclusions still apply; TestEmail remains isolated. See the
[configuration reference](../CONFIGURATION.md#interactive-user-exclusions).

## Supported target

- FreeBSD 15.1 or newer on amd64.
- Root access through `sudo`, `doas`, or a root shell.
- The configured FreeBSD package repository and internet access to GHCR.
- FreeBSD Linux emulation and Podman; the installer enables both.
- Network access from the Podman container to Plex is recommended for complete
  ratings, backgrounds, and selected logos.

FreeBSD documents the Podman services, automatic container startup, and Linux
container execution in the
[OCI Containers handbook chapter](https://docs.freebsd.org/en/books/handbook/containers/).
This platform is marked **beta** because GitHub-hosted CI performs static,
archive, and OCI checks but does not boot a FreeBSD host. Test preview and SMTP
delivery before enabling the scheduler.

This is not Docker-on-FreeBSD and it does not depend on a native FreeBSD
PowerShell build. The published Linux OCI image supplies the supported
PowerShell runtime and identical application renderer.

## Download and verify

Download `TautWeekly-freebsd-podman.tar.gz` and `SHA256SUMS.txt` from the
[latest release](https://github.com/sparkmoxie/TautWeekly/releases/latest):

```sh
grep 'TautWeekly-freebsd-podman.tar.gz' SHA256SUMS.txt
sha256 -r TautWeekly-freebsd-podman.tar.gz
tar -xzf TautWeekly-freebsd-podman.tar.gz
cd TautWeekly-freebsd-podman
```

Restore launcher permissions when transferring the ZIP through a filesystem
that does not preserve them:

```sh
chmod +x install-freebsd.sh tautweekly package-update.sh rc.d/tautweekly app/*.sh app/bin/*.sh
```

## Install

```sh
sudo ./install-freebsd.sh
sudo tautweekly manager-bootstrap
ssh -L 8787:127.0.0.1:8787 YOUR_FREEBSD_ADMIN@YOUR_FREEBSD_HOST
```

The installer performs explicit host changes: it installs Podman with `pkg` if
needed, enables and starts FreeBSD Linux emulation and the Podman service,
creates an unprivileged numeric data owner, installs the `rc.d` integration,
pulls the public GHCR image, and starts the container. It preserves an existing
settings file and private data directory. Open `http://127.0.0.1:8787/` through
the tunnel, enter the one-time token, create a unique administrator password,
and complete **Config** in the Manager. The token is returned only by the
explicit `manager-bootstrap` command and is never printed in installer,
container, or rc.d logs.

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

Manager Config asks for a direct Plex URL and administrator token. They remain optional
for the core Tautulli activity flow, but are recommended for complete movie RT
critic/audience ratings, exact-episode IMDb/RT ratings, backgrounds, and selected
logos. The URL must work from the Podman Linux container; its localhost is not
the FreeBSD host or a separate Plex service. **Validate, save, and verify**
checks Plex `/identity` plus authenticated `/library/sections` without printing
the token. A resolved but unusable connection fails verification; an unresolved
pair emits a Tautulli-only fallback warning.

When deleted-item cache storage is enabled or its coverage changes,
**Validate, save, and verify** starts a separate no-email refresh for every
production-eligible included user's current newsletter window in the selected
movie/TV libraries. It does not depend on PreviewAll or one selected preview
user. Run `sudo tautweekly cache-refresh` for an explicit refresh. Disabling
the cache stops reads and writes without deleting retained entries.

Verification proves reachability and authentication, not that every item has
every provider score. The renderer explicitly requests Plex's optional
`Rating` element so available movie RT pairs and exact-episode IMDb/RT values are not
hidden by a selected IMDb/TMDB fallback. If JSON lacks movie RT or
exact-episode provider entries, the renderer retries the same authenticated local
item as XML and reads only provider-labelled `Rating` elements.
For intended movie RT output, set every applicable Plex Movie library's
**Edit → Advanced → Ratings Source** to **Rotten Tomatoes**. This is a
library-wide Plex choice, not a TautWeekly setting; leave IMDb/TMDB selected if
that fallback is intentional.

## Metadata readiness before acceptance

After first setup, after changing a Plex metadata agent or Ratings Source, and
after a ratings/artwork recovery update when upstream data may be stale:

1. Confirm **Edit → Advanced → Ratings Source** in every included Plex Movie
   library.
2. Run Plex **Manage Library → Refresh All Metadata** for every included movie
   and TV library, then wait for all refreshes to finish.
3. In Tautulli, open each same **Library → Media Info** tab, select
   **Refresh media info**, and wait. The current control is per library, so
   repeat it for every included section.
4. Return to Manager **Verify**, generate PreviewAll, and use TestEmail only
   after both refresh stages complete.

[Plex documents](https://support.plex.tv/articles/200289306-scanning-vs-refreshing-a-library/)
that a full refresh can take significant time and can update existing metadata
and artwork. Do not refresh unrelated music/photo libraries for TautWeekly.
Tautulli's [section-specific media-info refresh](https://github.com/Tautulli/Tautulli/wiki/Tautulli-API-Reference#get_library_media_info)
updates its table after Plex; it does not replace Plex's refresh or choose a
ratings provider. Routine TautWeekly updates do not require a full refresh when
current output already renders correctly.

In Manager **Config**, review the active movie/TV library scope and delivery
exclusions. Then use **Verify**, generate all six previews, send only to
TestEmail, and inspect **Schedule**. Enable automatic sends only after those
checks pass. The CLI roster and selection commands remain expert/recovery
fallbacks and never save a default preview user.

Before enabling delivery, confirm `Configured TZ`, `Control zone`, and
`Scheduler TZ` agree and that `Scheduler now` has the expected local time and
UTC offset. Restart the `tautweekly` service after changing
`TAUTWEEKLY_TIMEZONE`.

## Files and trust boundaries

| Path | Purpose |
|---|---|
| `/var/db/tautweekly` | Private `config.json`, Manager password hash/pairing state, schedule state, logs, previews, custom assets, bounded deleted-item cache, and backups |
| `/usr/local/etc/tautweekly/tautweekly.env` | Root-owned image, timezone, identity, bind, port, and URL settings |
| `/usr/local/etc/rc.d/tautweekly` | Native FreeBSD service lifecycle |
| `/usr/local/sbin/tautweekly` | Administrative command wrapper |
| `ghcr.io/sparkmoxie/tautweekly` | Multi-architecture Linux OCI application image |

The settings file contains no SMTP or API credential. Those secrets remain in
`/var/db/tautweekly/config.json`; Manager access state remains under
`/var/db/tautweekly/manager`. Neither path may be committed or shared. Backups,
logs, and previews are also private, and diagnostics never include bootstrap
tokens or raw credentials.

The cache is `/var/db/tautweekly/cache/deleted-items`. It protects future items
observed while live and cannot reconstruct assets already discarded before
v0.9.0. Image updates preserve it with the rest of the data root. To purge,
stop the rc.d service and remove only that directory. During full uninstall,
retain the data root unless configuration, state, output, cache entries, and
backups are all intentionally being removed.

Port 8787 binds to `127.0.0.1` by default. Use an SSH tunnel for Manager access:

```sh
ssh -L 8787:127.0.0.1:8787 admin@example.com
```

Open `http://127.0.0.1:8787/` locally. There is no default password. Sessions
are HttpOnly/SameSite, state changes require CSRF protection, and repeated
failed logins are throttled. Keep the recovery listener on loopback and do not
publish it through a LAN bind, router, or firewall. The selected public ingress
is the fixed-target Tailscale Funnel below. Leave
`TAUTWEEKLY_MANAGER_ALLOWED_HOSTS` empty for loopback recovery; the exact
active Funnel hostname and Secure-cookie boundary are applied automatically
only after backend verification.

### Optional public Tailscale Funnel

The maintained FreeBSD package runs the pinned official Linux Tailscale
userspace runtime inside the existing Podman container. It does not depend on
the community-maintained FreeBSD host client. A remote viewer needs only an
ordinary browser and the Manager password; the viewer does not install
Tailscale or join a tailnet.

1. Run `sudo tautweekly remote-access-authorize`. The wrapper enables the
   isolated adapter, recreates the container, and starts the official
   interactive browser sign-in. TautWeekly never receives an auth key or token.
2. Create and enable the Manager password lock locally.
3. In **Settings > Tailscale Funnel**, choose **Enable**. Use the public address
   only after status is green **Active**. Gold **Publication pending** means the
   exact local route exists but public DNS or trusted TLS is not ready.

The root-only adapter owns separate persistent state and accepts only the fixed
Manager target inside the container. The non-root Manager has no Podman socket,
host executable, TUN device, host network, added networking capability,
credential, arbitrary command, hostname, port, path, or CLI argument.

Use `sudo tautweekly remote-access-disable` before maintenance or when public
access is no longer wanted. The rc.d wrapper disables and verifies the exact
owned route before deliberate stop, reset, recovery, or removal and
fails closed if cleanup cannot be proven. Normal Manager restart preserves
Funnel; verified package/image update, recreate, and rollback preserve it.
Abrupt power loss or `SIGKILL` cannot run cleanup, so retain local access for
recovery.

## Operations

Use the Manager GUI for normal configuration, verification, library/user
selection, previews, TestEmail, scheduling, status, and sanitized diagnostics.
These commands are host lifecycle, bootstrap, or expert/recovery fallbacks:

```text
sudo tautweekly manager-bootstrap      retrieve the one-time pairing token
sudo tautweekly manager-reset-access   reset only Manager authentication
sudo tautweekly setup                 expert fallback: replace private configuration
sudo tautweekly verify                validate API, mail, storage, and schedule
sudo tautweekly cache-refresh         refresh every included user's cache window
sudo tautweekly cache-status          report share-safe deleted-item cache health
sudo tautweekly list-users            inspect Tautulli recipients
sudo tautweekly exclude-users         revise stable user exclusions
sudo tautweekly list-libraries         inspect the global movie/TV scope
sudo tautweekly manage-libraries       replace the global movie/TV scope
sudo tautweekly preview-all USER_ID   render all deterministic browser states
sudo tautweekly send-test-all USER_ID send only to TestEmail
sudo tautweekly send-all              guarded production delivery
sudo tautweekly schedule-status       inspect scheduler state
sudo tautweekly status                inspect the rc.d service
sudo tautweekly logs                  follow container logs
sudo tautweekly backup                stop briefly and archive private data
sudo tautweekly check-update          compare verified host package and image
sudo tautweekly update                verify package, install adapter, update image
```

The wrapper always requires an explicit confirmation for real welcome or
production delivery. Saved exclusions block the user from preview, TestEmail,
welcome, and scheduled or confirmed `SendAll` modes. An included user without
a production address can still be sampled; TestEmail sends only to its
configured test inbox.

Manager's **Repeat this Tautulli lookup** updates only its displayed choices.
Every manual or scheduled SendAll performs one bounded Tautulli/Plex user-list
refresh before reading the live roster. New eligible users are included unless
explicitly excluded; an unconfirmed refresh stops before SMTP with sanitized
guidance.

Direct configured SMTP remains the standard path. New configurations use
`SendDelaySeconds=30` and `TestSendDelaySeconds=10`. SendAll stops after an
authentication, temporary provider/service, batch-wide, transport, or
ambiguous-DATA failure instead of reconnecting for every remaining recipient;
an address/mailbox-specific RCPT rejection may continue after the configured
delay. Avoid
Test All or a manual production run near the scheduled batch, and stop retries
during a provider account lock.

Manager Config (or the `manage-libraries` expert fallback) queries active
movie/TV libraries and saves stable section IDs in `IncludedLibraryIds`. This global scope is applied
before releases, quiet mode, Trending, Binge Champion, and personal statistics
are calculated. The manager backs up private configuration before writing;
empty/absent IDs retain legacy all-library behavior.

The inherited newsletter payload lists every qualifying unique personal movie
and TV show in responsive full-width cards. Personal total watch time remains
distinct from Binge Champion eligibility; the Binge movie/TV breakdown now uses
the same supporting typography as total watch time.

Only new movies qualify for **HOT NEW RELEASE**. That hero pairs with the
server-wide Trending footer. A movie-empty week promotes an authentic Trending
movie when server history supplies one, excludes it from up to four **Recent
Releases / Movies** cards, and pairs it with the privacy-preserving Top Genre
footer. With new TV, up to four series remain **New Releases / TV** and the
visible count plus inbox preview text say `0 NEW MOVIES • X TV TITLE(S)`.
Without new TV, up to four series strictly newer than one month become **Recent
Releases / TV**, while both count locations say
`1 TRENDING MOVIE • X RECENT MOVIE RELEASE(S)` when the real hero exists. Top
Genre reports only aggregate qualified movie watch time and unique movie count;
missing or unsupported artwork uses the neutral local movie animation.

Watched marks use only the selected recipient's all-time Tautulli movie history.
Review the desktop poster shield and the title circles with uniform 6px spacing,
vertical centering, and `title="Watched"`. Unwatched movies leave no icon gap and
TV is unchanged. See the [watched-state rule and privacy boundary](../CONFIGURATION.md#recipient-movie-watched-markers).

## Update and pinning

Manager **Settings > Updates** is the primary FreeBSD status source. It
distinguishes the running container application/image from the installed
FreeBSD Podman package, reports host-adapter compatibility, stable channel,
latest stable release, check history, sanitized failure, and release notes.
Authenticated entry renders cached status first and makes one non-blocking
bounded check only when the last success is missing or at least 24 hours old
and backoff permits. Successful results are reused for five minutes before
**Check now** refreshes the same endpoint. The main header **Refresh** completes
its local status reload first, repeats the saved-revision LAN-only Tautulli
choices lookup when configuration is ready, and starts that check when its
cooldown permits. It never generates previews or contacts Plex/SMTP, and scoped
refresh controls remain isolated. Navigation, Dashboard rendering, and Manager
health stay offline-capable. **Current** retains its green glow.
The passive purple header SVG appears only for a validated newer running
application; the card glows for every non-current state. The web process cannot
run `sudo`, Podman, or rc.d; the
card provides the copyable host command `sudo tautweekly update` but no install
button.

The FreeBSD package uses its rc.d-aware TautWeekly wrapper as the update
authority. Podman's `io.containers.autoupdate=registry` mechanism requires a
systemd-managed container, so the rc.d service deliberately has no auto-update
label or timer. No update is applied periodically by default.

`check-update` compares installed release metadata with the latest stable
package and asks Podman to pull the configured image for a read-only comparison;
it does not restart or replace the container. Before applying, create a private
backup and record the current image ID:

```sh
sudo tautweekly backup
sudo podman image inspect ghcr.io/sparkmoxie/tautweekly:0.25.0 --format '{{.Id}}'
sudo tautweekly check-update
sudo tautweekly update
# sign back in; verify Settings > Updates, then Verify, PreviewAll, and TestEmail
```

The apply command downloads the matching stable TAR archive and checksum file,
verifies both the published SHA-256 and internal `RELEASE-FILES.txt`, installs
the current wrapper/rc.d adapter, and then updates the image. It refuses a busy
TautWeekly operation, verifies the in-container health probe and version label,
and retags/restarts the prior image automatically if the new container fails.
Manager-triggered preview and delivery operations make one non-blocking lock
attempt and report **Operation busy** immediately; terminal, scheduler, updater,
and rc.d lifecycle waits retain their existing bounds.
Private data under `/var/db/tautweekly` and the existing root-owned environment
file are never replaced. Normal stop/restart gives
the shared service up to 30 minutes to let an already-running newsletter
delivery finish after Manager HTTP access closes.

### One-time update from v0.14.0 or an older image-only wrapper

If `sudo tautweekly help` does not list `manager-bootstrap`, the installed rc.d
host package is older than the Manager inside the image. Download the current
stable **FreeBSD Podman** TAR archive and `SHA256SUMS.txt`, verify the published
checksum, extract it to a temporary directory, and run:

```sh
sudo ./install-freebsd.sh --upgrade-and-update
```

The current installer replaces release-owned application, wrapper, and rc.d
files, preserves `/var/db/tautweekly` and the existing root-owned environment
file, then verifies the updated image. Future `sudo tautweekly update` commands
advance the verified host package and image together. Do not copy individual
wrapper files from an unreleased branch.

If the update addresses missing ratings/artwork or output remains stale,
complete metadata readiness before the listed verify/TestEmail checks.

Manager **Config > Configuration backups** can permanently delete one selected
configuration backup only after **Confirm delete**. The current configuration
is unchanged and the deleted backup cannot be recovered.

The v0.25.0 package defaults `TAUTWEEKLY_IMAGE` to the full release semver and
sets `TAUTWEEKLY_RUNTIME_PROFILE=server`. For immutable automation, append the
published manifest digest in
`/usr/local/etc/tautweekly/tautweekly.env`, then restart the service. The release archive also contains the
Dockerfile and complete application source for local inspection or building:

```sh
sudo podman build --os=linux -t localhost/tautweekly:local .
```

Set `TAUTWEEKLY_IMAGE=localhost/tautweekly:local` and restart only after the
local image build succeeds.

The packaged default is full semver. The minor, `latest`, and `edge` tags are
mutable and are not recommended automation references. Administrators who
intentionally want unattended updates may schedule `tautweekly update` with a
FreeBSD host facility, but that is an explicit local policy and is not installed
by this package.

The package defaults to `/usr/local/bin/podman`. If Podman is installed in a
different administrator-managed location, set `TAUTWEEKLY_PODMAN_BIN` in the
same root-owned environment file before restarting the service.

## Manager access recovery

Run `sudo tautweekly manager-reset-access` only when the administrator password
is lost. It removes Manager credentials, pairing material, and active sessions,
then restarts the rc.d service and preserves `config.json`, Tautulli/Plex/SMTP
secrets, newsletter scheduling and delivery state, output, cache, and backups.
Retrieve the replacement one-time token with
`sudo tautweekly manager-bootstrap`. Never delete `/var/db/tautweekly` merely
to recover Manager access.

## Troubleshooting

- `cannot clone: Operation not supported`: confirm FreeBSD 15.1+, run
  `sudo service linux start`, and verify the host's Podman package is current.
- Image does not start: run `sudo podman run --rm --os=linux alpine uname -s`
  to isolate Linux-container support from TautWeekly.
- Service remains stopped: run `sudo service tautweekly status` and
  `sudo podman logs tautweekly`.
- Manager is unreachable: retain the localhost bind and use the SSH tunnel
  above; confirm `sockstat -4 -l | grep 8787`.
- Pairing is requested after an update or browser reset: run
  `sudo tautweekly manager-bootstrap`; do not search logs for the token.
- Permission error: restore the numeric owner with
  `sudo chown -R 8787:8787 /var/db/tautweekly` and keep directory mode `0700`.

TautWeekly for Plex is an independent community project and is not affiliated
with, endorsed by, or sponsored by Plex, Tautulli, or the FreeBSD Project.

## Bundled asset updates

Shipped email asset filenames are release-owned: updates may replace same-name
custom artwork. Custom-only filenames and unrelated private/runtime data are
preserved. For the bundle marker, restart behavior, explicit repair, and Windows
update differences, see [bundled email assets](../EMAIL-ASSETS.md).
