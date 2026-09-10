# Native Linux installation

The native Linux distribution runs TautWeekly for Plex directly with
PowerShell 7 and no Docker. It is fully headless: no desktop is required on the
server. A hardened systemd service keeps the authenticated Manager and guarded
scheduler alive. The shared Manager GUI is the primary setup, verification,
preview, TestEmail, scheduling, and administration surface; `tautweekly`
remains the host recovery and expert command wrapper.

If a Debian, Ubuntu, or other Linux server uses Docker or Compose, use the
[NAS/Docker distribution](../nas-docker/README.md) instead. “NAS” is only the
container distribution name; dedicated NAS hardware is not required. Both
distributions use the same Manager and newsletter behavior. Their access model
differs only in lifecycle ownership: both keep the host Manager endpoint on
loopback and use an SSH local forward for recovery or their optional
password-gated public Tailscale Funnel for an ordinary remote browser.

[Open the Native Linux Quickstart](https://sparkmoxie.github.io/TautWeekly/linux/)

Current source baseline: **1.5.0**.

Manager Config shows a separate **Managed-user delivery addresses** card when
Tautulli reports an active user without native email. Assignments stay in
private `/var/lib/tautweekly/config.json` and its backups, may share an inbox,
and never override a native address. Existing user-ID and effective-address
exclusions still apply; TestEmail remains isolated. See the
[configuration reference](../CONFIGURATION.md#interactive-user-exclusions).

## Supported target

- A current 64-bit Ubuntu, Debian, or RHEL release supported by PowerShell 7.
- PowerShell 7.2 or newer (`pwsh`), with a current LTS release recommended.
- systemd, Python 3, ImageMagick (`identify` and `convert`), `tar`, and
  util-linux (`runuser` and `flock`).
- Network access to Tautulli, the configured SMTP STARTTLS endpoint, GitHub
  Releases for updates, and recommended direct Plex metadata endpoints for
  complete ratings, backgrounds, and selected logos.

Microsoft publishes the current distro and PowerShell support table in its
[PowerShell on Linux overview](https://learn.microsoft.com/powershell/scripting/install/linux-overview).
Install PowerShell from Microsoft's supported repository for your distribution
before running this package. The TautWeekly installer deliberately does not add
third-party package repositories or download a runtime as root.

Linux systems without systemd, or servers where Docker is the chosen operating
model, should use the maintained [NAS/Docker distribution](../nas-docker/README.md).

## Download and verify

Download `TautWeekly-linux.tar.gz` from the
[latest release](https://github.com/sparkmoxie/TautWeekly/releases/latest) with
`SHA256SUMS.txt`, then verify before extracting:

```bash
sha256sum --check SHA256SUMS.txt --ignore-missing
tar -xzf TautWeekly-linux.tar.gz
cd TautWeekly-linux
```

The ZIP contains the same payload for administrators who transfer packages
from Windows. Preserve the executable bits or restore them with:

```bash
chmod +x install-linux.sh tautweekly check-release.sh package-update.sh app/*.sh app/bin/*.sh
```

## Install

```bash
sudo ./install-linux.sh
```

The installer validates dependencies, creates the locked `tautweekly` service
account, selects the packaged amd64 or arm64 Manager for the host, installs
application files, starts the loopback-only service, and preserves any existing
environment and private data. The GUI writes live configuration only under
`/var/lib/tautweekly`. The server does not need a desktop and the Manager is not
published directly to the LAN.

From a separate administrator workstation, keep the Manager on host loopback
and open an SSH tunnel:

```bash
ssh -L 8788:127.0.0.1:8788 YOUR_LINUX_ADMIN@YOUR_LINUX_HOST
```

In that host session, retrieve the first-run token explicitly:

```bash
sudo tautweekly manager-bootstrap
```

Open `http://127.0.0.1:8788`, enter the one-time token, and create a unique
administrator password. The token is returned only to this explicit command;
it is never printed by the installer or written to systemd/Manager logs. In the
GUI, open **Config**, complete guided setup, and choose **Validate, save, and
verify**. Automatic sending remains disabled until it is explicitly enabled on
the GUI **Schedule** page.

When deleted-item cache storage is enabled or its coverage changes,
**Validate, save, and verify** starts a separate no-email refresh for every
production-eligible included user's current newsletter window in the selected
movie/TV libraries. It does not depend on PreviewAll or one selected preview
user. Run `sudo tautweekly cache-refresh` for an explicit refresh. Disabling
the cache stops reads and writes without deleting retained entries.

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

Setup asks for a direct Plex URL and administrator token. They remain optional
for the core Tautulli activity flow, but are recommended for complete movie RT
critic/audience ratings, exact-episode IMDb/RT ratings, backgrounds, and selected
logos. The GUI verification uses the same resolved connection as newsletter
generation and checks Plex `/identity` plus authenticated `/library/sections`
without printing the token. A resolved but unusable connection fails
verification; an unresolved pair emits a Tautulli-only fallback warning.
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
4. In the Manager, run connection verification, PreviewAll, and TestEmail only
   after both refresh stages complete.

[Plex documents](https://support.plex.tv/articles/200289306-scanning-vs-refreshing-a-library/)
that a full refresh can take significant time and can update existing metadata
and artwork. Do not refresh unrelated music/photo libraries for TautWeekly.
Tautulli's [section-specific media-info refresh](https://github.com/Tautulli/Tautulli/wiki/Tautulli-API-Reference#get_library_media_info)
updates its table after Plex; it does not replace Plex's refresh or choose a
ratings provider. Routine TautWeekly updates do not require a full refresh when
current output already renders correctly.

Review the user roster and exclusions before testing:

```bash
sudo tautweekly list-users
sudo tautweekly exclude-users
sudo tautweekly list-libraries
sudo tautweekly manage-libraries
sudo tautweekly preview-all USER_ID
sudo tautweekly send-test-all USER_ID
sudo tautweekly cache-refresh
sudo tautweekly cache-status
sudo tautweekly schedule-status
```

Replace `USER_ID` with a numeric value printed by `list-users`. The roster is
informational and does not select or save a default user.

Before enabling delivery, confirm `Configured TZ`, `Control zone`, and
`Scheduler TZ` agree and that `Scheduler now` has the expected local time and
UTC offset. Restart `tautweekly.service` after changing the timezone in
`/etc/tautweekly/tautweekly.env`.

Automatic delivery is opt-in. Enable it only after the controlled `TestEmail`
messages match the intended production output:

```bash
sudo tautweekly schedule-enable
```

## Files and trust boundaries

| Path | Purpose | Ownership |
|---|---|---|
| `/opt/tautweekly` | Replaceable application code and bundled default assets | `root:root`, read-only to the service |
| `/var/lib/tautweekly` | Configuration, state, logs, previews, custom assets, bounded deleted-item cache, and private backups | `tautweekly:tautweekly`, mode `0700` |
| `/etc/tautweekly/tautweekly.env` | Non-secret service paths, timezone, Manager listener, and renderer preview URL | `root:root`, mode `0600` |
| `/etc/systemd/system/tautweekly.service` | Hardened service definition | `root:root` |
| `/usr/local/bin/tautweekly` | Administrative command wrapper | `root:root` |

`config.json` contains the Tautulli API key and SMTP credential and may contain a
Plex token. Backups contain the same secrets. Never attach the data directory,
logs, or generated previews to a public issue.

The cache is `/var/lib/tautweekly/cache/deleted-items`. It captures only future
items observed live and cannot recover assets discarded before v0.9.0. It is
included in a private data backup and preserved on upgrade. To purge it, stop
the service and remove only that directory. A full uninstall should retain the
data root until configuration, state, output, cache entries, and backups are no
longer required.

The authenticated Manager defaults to `127.0.0.1:8788` and serves protected
preview content inside the same session. This is a headless service; open it
from an administrator workstation rather than installing a desktop on the
server. For remote administration, keep it on loopback and tunnel the Manager
port:

```bash
ssh -L 8788:127.0.0.1:8788 admin@example.com
```

Then open `http://127.0.0.1:8788/` locally. Keep the recovery listener on
loopback and do not publish it through a LAN bind, router, or firewall. The
selected public ingress is the fixed-target Tailscale Funnel below.

### Optional public Tailscale Funnel

Native Linux can publish the password-protected Manager through public HTTPS
Tailscale Funnel while Manager stays on `127.0.0.1:8788`. Install and update
the official Tailscale Linux package yourself, start it, and sign this host in;
TautWeekly never installs Tailscale, runs `tailscale up`, or accepts an auth
key. Then run the one-time fixed host authorization:

```bash
sudo tautweekly remote-access-authorize
```

Create and enable the unique Manager password under **Settings > Browser
access**, then use **Settings > Tailscale Funnel**. The root-owned,
socket-activated helper accepts only Inspect, Enable, or Disable for the fixed
loopback target. It verifies the installed `tautweekly` service UID and the
exact owned Funnel route. Browser input cannot provide an executable, command,
argument, port, hostname, target, or path. Manager remains unprivileged and
never receives general Tailscale, systemd, sudo, or root access.

Complete any one-time Funnel provider approval outside Manager. A route saved
locally is gold **Publication pending** until explicit verification finds the
exact route, public DNS through the fixed resolver, and a trusted TLS
certificate for the expected hostname. Only then is it green **Active** and
admitted as a Host. Do not create a DNS record or open a firewall/router port.
The tailnet must have MagicDNS, HTTPS certificates, and a `funnel` node
attribute that includes this host. If the Linux host uses a tag identity, the
default `autogroup:member` policy example does not target it; the administrator
must add an explicit tag-targeted node attribute outside Manager. A local
`Funnel on` result is not publication proof, even after the documented
10-minute DNS window.
An ordinary remote browser needs no Tailscale client or VPN because the login
page is public. Every successful login has full administration; there is no
read-only role and this release adds no new Internet login-attempt limiter, so
use a unique password and retain local recovery.

Ordinary `sudo tautweekly restart`, verified update, and rollback preserve the
selected persistent Funnel and fixed loopback route. Explicit stop, access
reset, adapter revocation, and uninstall first disable and verify the exact
owned route or stop safely. Use
`sudo tautweekly remote-access-revoke` to perform that cleanup and remove the
fixed host authorization. A legacy exact private Serve route is never silently
converted; Settings requires explicit migration or verified cleanup.

## Operations

Use the Manager GUI for routine configuration, connection checks, library and
exclusion choices, previews, TestEmail, schedule enable/disable, status, and
sanitized diagnostics. The commands below are recovery and expert fallbacks:

```text
sudo tautweekly manager-bootstrap      retrieve the one-time pairing token
sudo tautweekly manager-reset-access   reset only Manager authentication
sudo tautweekly remote-access-authorize authorize the fixed Tailscale adapter
sudo tautweekly remote-access-revoke   disable/verify Funnel, then revoke the adapter
tautweekly remote-access-status        inspect adapter authorization
sudo tautweekly setup                 create or replace private configuration
sudo tautweekly verify                validate files, API, SMTP, and schedule
sudo tautweekly cache-refresh         refresh every included user's cache window
sudo tautweekly cache-status          report share-safe deleted-item cache health
sudo tautweekly list-users            inspect Tautulli recipients
sudo tautweekly exclude-users         revise stable user exclusions
sudo tautweekly list-libraries         inspect the global movie/TV scope
sudo tautweekly manage-libraries       replace the global movie/TV scope
sudo tautweekly preview-all USER_ID   generate all deterministic browser states
sudo tautweekly send-test-all USER_ID send only to TestEmail
sudo tautweekly send-all              guarded production delivery
sudo tautweekly schedule-status       inspect scheduler state and heartbeat
sudo tautweekly logs                  follow the systemd journal
sudo tautweekly backup                create a private data archive
sudo tautweekly check-update          compare with the latest stable release
sudo tautweekly update                verify and install the latest stable package
```

The backup command briefly stops an active service for a consistent snapshot
and restores its previous running state afterward.

Saved exclusions block a user from preview, TestEmail, welcome, and manual or
scheduled SendAll modes. An included user without a production address can
still be sampled; TestEmail sends only to its configured test inbox.

Manager Config (or the `manage-libraries` expert fallback) discovers active
movie/TV libraries through Tautulli and saves stable section IDs in
`IncludedLibraryIds`. That scope is
applied before releases, quiet mode, Trending, Binge Champion, and personal
statistics are calculated. The manager backs up the private config before
writing; empty/absent IDs retain legacy all-library behavior.
One-off welcome mail remains a separate, explicit administrator action, but it
enforces the same saved user exclusion policy as every other personalized mode.

Manager's **Repeat this Tautulli lookup** updates only its displayed choices.
Every manual or scheduled SendAll performs one bounded Tautulli/Plex user-list
refresh before it reads the live roster. New eligible users are included unless
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

## Upgrade and rollback

Start with Manager **Settings > Updates**. It is the primary view of the running
application, native package, stable channel, latest stable release, check time,
sanitized failure, and release notes. Authenticated entry renders the cache and
makes one non-blocking bounded check only when the last success is missing or
at least 24 hours old and backoff permits. Successful results are reused for
five minutes before **Check now** refreshes the same fixed endpoint. The main
header **Refresh** completes its local status reload first, repeats the
saved-revision LAN-only Tautulli choices lookup when configuration is ready,
and starts that check when its cooldown permits. It never generates previews or
contacts Plex/SMTP, and scoped refresh controls remain isolated. Manager
navigation, Dashboard rendering, and health remain offline-capable. **Current**
retains its green glow. The passive purple header SVG appears only for a
validated newer running application; the card glows for every non-current
state.
The card never invokes `sudo`, systemd, or the
package updater and provides the copyable host command `sudo tautweekly update`.

For a terminal-only comparison, run `tautweekly check-update` between the installed
`RELEASE-METADATA.txt` and GitHub's latest stable release. This check never
installs code, has no periodic timer, and never follows `main` or the container
`edge` tag. To upgrade, run:

```bash
sudo tautweekly backup
sudo tautweekly update
```

The update downloads the matching stable TAR archive and `SHA256SUMS.txt`,
verifies the published SHA-256 plus the archive's internal
`RELEASE-FILES.txt`, and only then runs the packaged upgrade installer. An
upgrade stores the previous application payload under
`/var/lib/tautweekly/backups/program-<timestamp>.tar.gz`, replaces only
`/opt/tautweekly`, and restarts an already configured service. It does not
replace `config.json`, state, output, logs, the deleted-item cache, custom assets, or the environment
file. The installer holds the same operation lock used by preview and send
commands, records and verifies the repository release metadata, and confirms a
previously active service becomes active again. Sign back into the Manager,
review **Settings > Updates** and **Dashboard**, rerun verification, PreviewAll, and TestEmail, and only
then leave the schedule enabled for the next production delivery.
Manager-triggered preview and delivery operations make one non-blocking lock
attempt and report **Operation busy** immediately; terminal, scheduler, updater,
and service-lifecycle waits retain their existing bounds.

If the upgrade addresses missing ratings/artwork or output remains stale,
complete metadata readiness before those checks.

Manager **Config > Configuration backups** can permanently delete one selected
configuration backup only after **Confirm delete**. The current configuration
is not modified; deletion cannot be undone.

To roll back, stop the service, restore the recorded program archive into
`/opt`, and start the service:

```bash
sudo systemctl stop tautweekly
sudo tar -xzf /var/lib/tautweekly/backups/program-TIMESTAMP.tar.gz -C /opt
sudo chown -R root:root /opt/tautweekly
sudo systemctl start tautweekly
```

Reinstall uses the same installer and preserves `/var/lib/tautweekly`. For an
uninstall, stop and disable the service, remove only the replaceable application,
unit, environment, and wrapper files, then reload systemd. Keep the private data
directory until its backup is verified and deletion is explicitly intended:

```bash
sudo systemctl disable --now tautweekly.service
sudo rm -rf /opt/tautweekly
sudo rm -f /etc/systemd/system/tautweekly.service /usr/local/bin/tautweekly /usr/local/libexec/tautweekly-check-release /usr/local/libexec/tautweekly-package-update
sudo systemctl daemon-reload
# Preserve /var/lib/tautweekly and /etc/tautweekly until intentionally purged.
```

## Troubleshooting

- `PowerShell 7.2 or newer is required`: install a supported `pwsh` package and
  rerun the installer.
- `systemd is required`: use the NAS/Docker edition on that host.
- Manager works locally but not remotely: keep the localhost bind and use the
  SSH tunnel above, or inspect **Settings > Tailscale Funnel**. Gold
  **Publication pending** means the exact local route exists but public DNS or
  trusted TLS has not passed; it is not Active. Confirm the fixed adapter is
  authorized with `tautweekly remote-access-status` and use Verify again.
- Forgotten Manager password: run `sudo tautweekly manager-reset-access`, then
  `sudo tautweekly manager-bootstrap`; this preserves configuration, schedules,
  output, delivery history, and newsletter state.
- Service exits: run `sudo systemctl status tautweekly` and
  `sudo journalctl -u tautweekly -n 200 --no-pager`.
- Permission error under `/var/lib/tautweekly`: restore ownership with
  `sudo chown -R tautweekly:tautweekly /var/lib/tautweekly` and mode `0700` on
  the root directory. Do not run the application as root.

TautWeekly for Plex is an independent community project and is not affiliated
with, endorsed by, or sponsored by Plex or Tautulli.

## Bundled asset updates

Shipped email asset filenames are release-owned: updates may replace same-name
custom artwork. Custom-only filenames and unrelated private/runtime data are
preserved. For the bundle marker, restart behavior, explicit repair, and Windows
update differences, see [bundled email assets](../EMAIL-ASSETS.md).
