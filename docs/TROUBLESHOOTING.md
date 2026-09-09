# Troubleshooting

On Windows, NAS/Docker, macOS Docker Desktop, native Linux, and FreeBSD Podman,
start with the
authenticated Manager's Dashboard and **Verify** page and correct the first
reported failure. Use the terminal verifier as a recovery/expert fallback.

## Container command reports `/data` access denied

Docker and Podman Console/exec sessions start as the image's root user. Use
the packaged `./tautweekly.sh` host wrapper, or use
`/opt/tautweekly/bin/run-script.sh SCRIPT.ps1` and
`/opt/tautweekly/bin/run-mode.sh MODE` inside an Unraid container Console.
Those launchers run commands as the configured PUID/PGID and repair only
legacy root-owned entries within the dedicated `/data` filesystem.

If an older release already created root-owned logs, update the container and
run any supported launcher command once. For example:

```bash
/opt/tautweekly/bin/run-mode.sh ListUsers
```

Do not work around the error with world-writable permissions or by running the
service as root. The launcher does not follow symlinks or cross another mount,
and it does not display or copy private configuration, logs, or output.

## Tautulli cannot be reached

- Confirm the URL opens from the TautWeekly for Plex runtime, not only from your laptop.
- In Docker, `127.0.0.1` refers to the TautWeekly for Plex container. Use a shared-network
  service name, `host.docker.internal` on Docker Desktop, or a resolvable host
  name.
- Confirm Tautulli's published port and API key.

## SMTP authentication or TLS fails

Start with the sanitized failure stage and numeric SMTP response in Manager.
Do not paste credentials, addresses, private hostnames, response text, or raw
logs into a support report.

Use the exact SMTP submission hostname and STARTTLS submission port issued for
the account; TautWeekly does not support implicit-TLS port 465. Confirm whether
the username is a full address or another issued identifier and use an
application password when account policy requires one. The normal `verify`
operation does not authenticate or submit mail.

| Stage | Provider-neutral checks |
|---|---|
| `configuration` | Confirm a nonblank submission host, port 1-65535 other than unsupported implicit-TLS port 465, timeout 5-300 seconds, and both username and password when authentication is enabled. |
| `connect` or `greeting` | Resolve and reach the exact outbound SMTP host from the TautWeekly runtime. Check egress firewall/DNS, the documented submission port, and whether the service is accepting connections. |
| `ehlo`, `starttls`, or `tls` | Use the service's STARTTLS endpoint with `SmtpEnableSsl=true`. Confirm it advertises STARTTLS, the host clock is correct, and the operating system trusts the certificate chain for the configured hostname. |
| `auth` | Use the exact issued username and an SMTP-capable password or application-specific credential. Keep `SmtpAuthenticationMethod=Auto` unless the administrator explicitly requires advertised `LOGIN` or `PLAIN`; keep `SmtpStripPasswordSpaces=false` unless displayed spaces are separators. |
| `mail-from` | Set `FromEmail` to the authenticated account or another sender identity that account is explicitly authorized to use. Changing `FromName` or `ReplyToEmail` does not authorize a sender. |
| `rcpt-to` | Confirm the controlled test address is valid and the account may send to it. Test with one recipient before a batch. |
| `data-command` or `data-acceptance` | Check account quota/policy, message acceptance, and any temporary service condition. Unknown final-DATA acceptance is treated as batch-fatal so TautWeekly does not risk duplicate sends. |

A 4xx response is temporary; stop repeated tests and allow the service's stated
quiet period. A 5xx response is a permanent rejection of that attempt; correct
the relevant account, sender, recipient, or policy setting before retrying.
`verify` proves only configuration shape and TCP reachability. Use one numeric
ID from `list-users` with `send-test` (or Manager TestEmail) for the authoritative
STARTTLS/authentication/submission check. Listing users never saves a default.
If Manager reports success but the message is absent, inspect the controlled
mailbox's junk/quarantine and the mail administrator's delivery trace; do not
increase batch volume to test delivery.

## SMTP provider temporarily locks or limits the account

- Stop Test All, manual production sends, and repeated checks. Do not run them
  near the scheduled batch.
- Use `SendDelaySeconds=30` for production and `TestSendDelaySeconds=10` for
  controlled Test All delivery. Spacing reduces cadence but cannot override
  provider account, quota, reputation, or abuse controls.
- v0.19.1 and newer stop the batch after authentication failure, a temporary
  4xx response such as `421`, a batch-wide rejection, transport failure, or
  unknown final-DATA acceptance. The Manager shows only fixed sanitized stage,
  numeric response, and recovery guidance.
- Follow the provider notice and allow a quiet period. A short lock may clear
  quickly; if it does not, wait up to 24 hours before using the provider's
  normal account-recovery process.
- Do not share provider response text, addresses, account data, configuration,
  credentials, or raw logs in an issue.

## User exclusions cannot be loaded

Manager Config preserves exclusions from an existing configuration when the
Tautulli roster is temporarily unavailable. Correct the integration failure on
**Verify**, then reopen Config and retry the roster. Recovery/expert fallbacks
are `14-MANAGE-USER-EXCLUSIONS.bat` on Windows,
`./tautweekly.sh exclude-users` on Docker, and
`sudo tautweekly exclude-users` on Linux or FreeBSD. Update to v0.5.2 or newer
if every row reports that its user is unavailable. That release replaces
the fragile per-user lookup loop with a two-call merge of `get_user_names` and
`get_users`, keyed by stable user ID. Confirm the Tautulli API key can run both
bulk commands and that the runtime can reach the exact configured URL. A row
from `get_user_names` remains selectable if detailed data is unavailable; no
exclusion changes are saved only when neither endpoint yields selectable users.

## A managed user has no delivery address

Open Manager **Config** and refresh Tautulli choices. The separate
**Managed-user delivery addresses** card appears only for active users whose
live Tautulli record has no native email. Enter a valid address and save; shared
inboxes are allowed. If the card is absent, confirm the user is active and the
discovery result is current. A live native Tautulli email always takes
precedence, so an assignment cannot redirect that account.

If the user is still skipped, check `ExcludedUserIds` first and then
`ExcludedEmails` for the assigned effective address. Clearing an assignment
intentionally returns the user to `missingEmail`; it does not change prior
welcome/history state. A failed discovery refresh retains the prior sanitized
choices and private assignments. Do not post `config.json` or its backups when
requesting help because they contain the fallback addresses.

## Container is unhealthy

Update to v0.5.3 or newer before investigating an unhealthy Docker service.
Earlier releases used scheduler progress as container liveness, so a normal
scheduled `SendAll` lasting several minutes could age out the heartbeat even
while delivery and previews continued working. Current releases use a separate
five-second service-supervisor heartbeat. The supervisor already exits the
container if either the scheduler or Manager process terminates.

Inspect the recorded reason with:

```bash
docker inspect tautweekly --format '{{range .State.Health.Log}}{{.End}} exit={{.ExitCode}} {{printf "%q" .Output}}{{println}}{{end}}'
```

An unavailable `/health/live` endpoint or a missing, unreadable, or stale
`service-heartbeat.json` remains a real liveness failure. Artwork repair is
separate from Manager liveness; run `./tautweekly.sh repair-assets` only when
generated output reports missing packaged assets. Scheduler progress remains
visible through Manager, `./tautweekly.sh schedule-status`, and
`scheduler-heartbeat.json`, but it no longer controls Docker health.

## Unified container profile is refused or Manager looks new

v0.23.0 accepts only `desktop`, `server`, or `unraid`. Exit status 64 with a
profile/package error means the host definition is invalid; correct
`TAUTWEEKLY_RUNTIME_PROFILE` and its package kind instead of removing the
refusal. Desktop uses `container-desktop`, generic Compose normally uses
`container-compose`, and Unraid requires `unraid`.

If a recreated container unexpectedly asks for first-run pairing, stop it and
verify the original named volume or bind mount is still attached at `/data`.
Do not pair an empty replacement or delete the old volume. Once the correct data
is attached, the existing password, configuration, schedule, state, history,
and backups should return. Settings > Updates should then report the active
profile and `ghcr.io/sparkmoxie/tautweekly`. Follow the
[unified migration and interrupted-recovery guide](CONTAINER-MIGRATION.md) for
v0.22.0 Mac/NAS image transitions, permissions, rollback, and safe recreate
steps.

## Manager or preview does not open

The Docker/NAS and Native Linux services are both headless and use the same
Manager and newsletter behavior. Both keep local recovery on host loopback.
Open it directly on the host or use the documented SSH local forward; optional
password-gated public Funnel is the only ordinary remote-browser path.

## Windows Setup asks for a folder during an update

v0.25.0 reads a validated existing Setup installation through the native
current-user Windows Registry API and uses that registered folder directly, so
a normal Setup-managed update should not open the legacy folder picker. If it
does, cancel instead of selecting an arbitrary directory and confirm the
installed application is still registered and contains its valid release
ownership marker. A fresh installation, an unresolved registration, or an
explicit older portable/BAT migration still requires a deliberate folder
choice. Setup never scans drives or guesses an installation path.

### Native public Funnel address does not open

- Remote viewers need only an ordinary HTTPS browser; they do not install or
  connect Tailscale. Confirm the native Windows or Linux host has the official
  Tailscale client installed, running, and signed in, then use **Settings >
  Tailscale Funnel > Verify**. On Linux, `tautweekly
  remote-access-status` must report authorized; otherwise run `sudo
  tautweekly remote-access-authorize`. Do not share the real `.ts.net`
  address in support material.
- **Manager password required** means create and enable a unique password first.
  **Approval required** means approve the Windows UAC prompt and any official
  one-time Funnel page, then verify again. **Publication pending** means the
  exact loopback route exists but the fixed public DNS and certificate-validated
  TLS checks have not passed. The URL remains available and the card glows gold;
  it is not an active public Funnel. **Needs attention** means the observed route
  did not exactly match TautWeekly's fixed loopback target.
- Confirm the tailnet has MagicDNS, HTTPS certificates, and a `funnel`
  `nodeAttrs` policy target that includes this node. The default
  `autogroup:member` target does not include a tagged service node; a separately
  managed tagged container or Kubernetes node needs an explicit tag target.
  TautWeekly never reads or changes policy, tags, devices, or authentication.
- A separately managed declarative tagged sidecar also requires
  `AllowFunnel=true` for the exact `${TS_CERT_DOMAIN}:443` entry. TautWeekly's
  shipped NAS/macOS sidecar intentionally has neither that public entry nor a
  policy file, and the container Manager refuses public lifecycle operations.
  This is a container-only capability boundary from
  [tailscale/tailscale#11849](https://github.com/tailscale/tailscale/issues/11849#issuecomment-2211623437),
  not a Windows workaround. Do not modify Windows Tailscale state files or tag
  an untagged member-owned Windows device to try it.
- Tailscale documents that public DNS can take up to 10 minutes. After that,
  choose **Verify**. On Windows only, restarting the official Tailscale service
  once is a bounded diagnostic; it is not proof of publication. Open upstream
  reports cover Windows missing DNS
  ([#19508](https://github.com/tailscale/tailscale/issues/19508)), Linux/iOS and
  Docker off-tailnet resolution failures
  ([#11849](https://github.com/tailscale/tailscale/issues/11849)), Docker
  userspace DNS failure ([#8680](https://github.com/tailscale/tailscale/issues/8680)),
  and Linux public-DNS success followed by CDN-edge TLS stalls
  ([#19290](https://github.com/tailscale/tailscale/issues/19290)). Local
  `Funnel on` remains **Publication pending** until independent public DNS and
  trusted TLS both pass. Do not create an A record, share the machine,
  repeatedly reset certificates, add firewall/router rules, or replace the
  transport; those actions do not satisfy TautWeekly's publication proof.
- A successful CLI configuration check does not replace public edge acceptance.
  TautWeekly queries the exact intended-public hostname through `1.1.1.1`,
  rejects non-public answers, and requires a trusted TLS certificate before
  showing **Active**. On Windows, it uses the system `nslookup.exe` diagnostic
  path so NRPT and MagicDNS cannot intercept the fixed public-resolver query;
  `Resolve-DnsName -Server` still honors that split-DNS policy and is not a
  valid public-publication check. No DNS answer, certificate, raw CLI output,
  or private network detail is returned to Manager or written to diagnostics.
  From a separate network, open the generated HTTPS address, sign in, verify a
  read and a CSRF-protected change, sign out, and confirm the local Dashboard
  still works. Do not expose port 8788 or add a firewall/router rule.
- If password-lock disable, access reset, explicit stop, adapter
  revocation, or uninstall refuses, restore the official Tailscale service and
  the fixed platform adapter, then retry so TautWeekly can verify its owned
  Funnel is off. On Windows approve the fixed UAC shutdown; on Linux restore
  the authorized socket. Do not remove the password boundary first.

### Container-package Funnel is unavailable or publication remains pending

- Confirm `TAUTWEEKLY_FUNNEL_ADAPTER=enabled`, recreate the container, and run
  its documented `remote-access-login` or `remote-access-authorize` command.
  Authentication is interactive; auth keys, OAuth secrets, and tokens are
  deliberately refused.
- Do not mount a Docker/Podman socket, host CLI, TUN device, or privileged
  network access. The packaged official userspace runtime needs none of them.
- **Publication pending** means the exact local Funnel is configured but public
  DNS and trusted TLS have not both passed. Check MagicDNS, HTTPS certificates,
  and the applicable Funnel node attribute, wait for provider publication, then
  choose Verify. Do not add DNS, firewall, or router rules.
- If disable, stop, reset, recovery, or removal refuses, restore the
  adapter and its root-only state and retry exact-route cleanup. Do not remove
  the Manager password first.
- The remote viewer needs only an ordinary browser and the Manager password.
  Every session has full administration; there is no read-only role.

Windows, NAS/Docker, macOS Docker Desktop, native Linux, and FreeBSD serve previews through the
authenticated Manager. NAS/Docker normally maps host port 8787 to container
port 8080; macOS publishes container port 8080 at `http://localhost:8787/` by
default; native Linux uses loopback port 8788; FreeBSD uses loopback port 8787.
Use the platform `status` and `logs` commands, then confirm the mapped, local,
or tunneled URL is the one the browser opens.

The Manager requires pairing on service/container packages and never has a
default password. On macOS and release-archive NAS/Compose installs,
`./tautweekly.sh manager-bootstrap` is a host-side wrapper command. It does not
exist inside an Unraid or other vendor container Console, and a no-clone
Compose install does not download it. Those deployments use the documented
direct `access-bootstrap` container command instead; Native Linux uses
`sudo tautweekly manager-bootstrap`. The token is never in installer,
container, systemd, or rc.d logs. Complete Config to create the
persistent `config.json`, then use **Validate, save, and verify**, PreviewAll, and TestEmail
in the GUI. Terminal setup and preview commands are recovery or expert
fallbacks on Manager-capable packages.

### Preview generation fails or reports Operation busy

Open **Previews** and read the fixed failure category beside the sanitized
support code. `operation-busy` means a scheduled delivery, update, or explicit
terminal operation currently owns the shared package renderer; wait for that
work to finish and retry. Manager-triggered service-package operations do not
wait on this lock, while host CLI, scheduler, updater, and shutdown workflows
retain their bounded waits. Do not delete the lock file: the live operating-
system file handle, not file presence, determines ownership.

`configuration-invalid`, `tautulli-unavailable`, `plex-unavailable`,
`asset-unavailable`, `render-failed`, `output-failed`, and `smtp-failed` identify
only the fixed stage that stopped. Follow the Manager guidance, run **Verify**
when directed, and retry. Existing preview history remains available unless a
new file was successfully replaced. Browser-extension `content-script.js`,
`ObjectMultiplex`, or `MaxListenersExceededWarning` messages and the expected
blocked-script messages from the script-disabled preview iframe do not identify
a package-renderer failure. Do not add `allow-scripts` to the preview sandbox.

Provide the fixed category, support code, package kind, and whether another
scheduled/update/manual operation was active when asking for help. Do not post
configuration, raw logs, generated previews, private addresses, or identities.

Use **Settings > Updates** as the first update diagnostic. **Unknown** means no
successful stable check is available, the local version is not a release
version, or the configured channel is unsupported; use **Check now** and read
the sanitized failure. **Legacy** means the external wrapper/template predates
the running Manager contract. **Mismatched** means the application/image and
host package report different releases, commonly after an image-only update.
**Newer** means the local application is ahead of the latest stable release and
must not be downgraded automatically. A timeout/offline result does not make
Manager health or newsletter delivery unhealthy, and rapid retries are
temporarily backed off.

The card's update owner is authoritative for the next step: Windows can show a
confirmed install button; Linux, Mac, FreeBSD, Compose/NAS, and QNAP show their
host command; Unraid directs to Docker/Apps and template comparison; generic
Docker directs to the original deployment tool. Never solve a legacy or
mismatched state by mounting the Docker socket, running the Manager as root, or
adding a privileged web helper.

If a NAS user updated the image but `./tautweekly.sh help` does not list
`manager-bootstrap`, the external host wrapper is older than the running image.
The container still supports the GUI. Retrieve the token from the trusted host
without searching logs:

```bash
docker compose exec -T tautweekly /opt/tautweekly/bin/run-as-user.sh \
  /opt/tautweekly/bin/tautweekly-manager access-bootstrap --data-dir /data/manager
```

For Unraid, run the same command in the container Console without the
`docker compose exec -T tautweekly` prefix. For a release-archive Compose/QNAP
install, download the current stable NAS archive and `SHA256SUMS.txt`, verify
the checksum, and extract it over the same package directory while preserving
`.env` and `data/`. Future `./tautweekly.sh update` runs verify and advance host
files and the image together. For Unraid, edit the app and compare/apply the
current Community Apps template while keeping the existing appdata path and
identity settings; a `legacy` host-adapter startup warning means this template
refresh is still required.

The same one-time host-package bridge applies to older Mac Docker packages that
updated only the image: verify and extract the current stable Mac archive over
the same package directory while preserving `.env` and `data/`, then run
`./tautweekly.sh update`. On FreeBSD, verify and extract the current stable
FreeBSD Podman archive to a temporary directory and run
`sudo ./install-freebsd.sh --upgrade-and-update`; this preserves
`/var/db/tautweekly` and its root-owned environment file. Native Linux releases
were already package-based: verify the current Linux archive and run
`sudo ./install-linux.sh --upgrade`.

If the browser reports **connection refused**, run:

```bash
# Release-archive host wrapper:
./tautweekly.sh status
./tautweekly.sh logs
# Any Compose project:
docker compose ps
docker compose port tautweekly 8080
docker compose exec tautweekly tail -n 40 /data/logs/manager.log
```

`docker compose port tautweekly 8080` must report a `127.0.0.1` host mapping,
never Docker's `*:PORT` notation. Open it on the host or through the documented
SSH local forward. A vendor UI or differently named service should use its
equivalent status and port-mapping view.

The container scheduler reads only `/data/config.json`, mapped from the
distribution's `./data/config.json`, configured Unraid appdata directory, or
FreeBSD `/var/db/tautweekly`. If logs keep waiting for that file, sign in and
complete Manager Config. Do not place configuration under `/opt/tautweekly`;
that is the disposable application layer.

For public access, use only the URL returned by the active Funnel card. Its
exact hostname is admitted only after backend route ownership, public DNS, and
trusted TLS verification. Do not add a LAN/DNS host, proxy rewrite, wildcard,
router port, or firewall rule as a workaround.
An Origin rejection now reports a sanitized code: `invalid-origin` for a
malformed value, `origin-host-mismatch` or `origin-scheme-mismatch` for a real
same-origin difference, and `remote-http` when a saved Tailscale hostname was
used over HTTP. Forwarded headers cannot override these checks. If default
`http://localhost:8787` still fails, provide only the browser address scheme
and sanitized Host shape (localhost or `.ts.net`); do not post the private
hostname or credentials.

## Container permission errors

Confirm `PUID` and `PGID` are non-root and can write the project `data/`
directory. Do not solve the problem by running the application as root. On
Unix-like hosts, restore launcher permissions with:

```bash
chmod +x tautweekly.sh qnap-install.sh mac-install.sh INSTALL-MAC.command app/*.sh app/bin/*.sh
```

Use only the files that exist in your platform distribution.

## Schedule does not send or sends at the wrong local time

- Confirm scheduling is enabled.
- Confirm timezone, day, time, grace window, and the same-day attempt guard.
- On non-Windows packages, `Configured TZ`, `Control zone`, and `Scheduler TZ`
  must agree. `Scheduler now` must show the expected local wall time and UTC
  offset. A plausible `Configured TZ` line alone does not prove that the
  long-running scheduler is using it.
- If `Control zone` is invalid, correct the IANA zone before re-enabling the
  schedule. The scheduler deliberately refuses to fall back to UTC.
- If the control and scheduler zones differ after an environment change,
  restart the native Linux service or recreate/restart the Docker or Podman
  container, then run status again.
- Windows: open Manager **Schedule** and review ownership, state, and the
  upcoming run. Choose **Refresh** after changing the install path or schedule
  settings. Use `09-VERIFY-SCHEDULE.bat` as the terminal recovery fallback.
- Docker: run `./tautweekly.sh schedule-status` and inspect container logs.
- Linux and FreeBSD: run `sudo tautweekly schedule-status`, then inspect the
  systemd journal or Podman logs respectively.

## Custom title GIF is missing or does not clear

Open Manager **Config > Custom text card** and inspect **Optional title**. The
empty add-reaction glyph means no GIF is selected. Select Celebrate,
Construction, Rocket, Tickets, Warning, or Alert; selecting the active choice
again clears it. With the in-field control focused, Delete or Backspace also
clears it. Save and regenerate previews after changing the selection.

The GIF renders only when the custom card is enabled, its required body is
present, and its optional title is non-empty. A missing packaged asset or an
unsafe legacy value such as a path, URL, or filename falls back to no GIF. Use
the package's verified update/repair path if an approved asset is missing; do
not add remote image URLs or rename files. Delivered email uses an inline CID,
so a mail client that blocks animation may show only the first frame even when
the MIME attachment and preview are correct.

## Native Linux service does not start

Run `sudo systemctl status tautweekly` and
`sudo journalctl -u tautweekly -n 200 --no-pager`. Confirm PowerShell 7.2 or
newer, Python 3, and util-linux are installed. Application code must remain
root-owned under `/opt/tautweekly`; private data must be writable only by the
`tautweekly` service account under `/var/lib/tautweekly`.

## FreeBSD Podman container does not start

Confirm FreeBSD 15.1+ amd64, then run `sudo service linux status`,
`sudo service podman status`, and
`sudo podman run --rm --os=linux alpine uname -s`. If that Linux-container
probe fails, correct the FreeBSD/Podman host before troubleshooting TautWeekly.
Use `sudo podman logs tautweekly` for application startup errors.

## Mail-client rendering differs from preview

Browser preview is a structural check; the controlled TestEmail is authoritative
for MIME, linked images, and the actual client. Retest after changing branding,
assets, SMTP providers, or email clients.

## Trending shelves or inbox preview text are wrong

Update every maintained package component to v0.21.0 or newer; do not combine a
new Manager/container wrapper with an older renderer. In a Trending week with
new TV, **Recent Releases / Movies** holds up to four movies other than the hero,
**New Releases / TV** holds up to four series, and both the visible count and
inbox preview text must say `0 NEW MOVIES • X TV TITLE(S)`. Without new TV, the
TV shelf is **Recent Releases**, limited to series strictly newer than one month,
and both count locations say
`1 TRENDING MOVIE • X RECENT MOVIE RELEASE(S)` when the real hero exists.

Regenerate PreviewAll after the metadata refresh finishes; an older saved HTML
file cannot change in place. Then send a controlled TestEmail and compare its
inbox preview text with the line above the message date. Preview, PreviewAll,
SendTest, SendTestAll, scheduled delivery, and confirmed manual delivery use the
same computed count in the current renderer.

A Trending hero should end with **Top Genre This Week**, not another Trending
card. A neutral movie animation and **No qualifying genre yet** mean that no
qualifying movie supplied usable first-genre metadata in the report window. A
recognized genre with neutral artwork means the genre is valid but has no
dedicated mapping. In either case, refresh Plex and then Tautulli media info for
every included movie library before retesting. Never post the generated message,
configuration, logs, recipient details, or viewing history.

## Posters render but ratings, backgrounds, or logos do not

These resources do not all use the same path. Posters and hero art can load
through Tautulli's `pms_image_proxy` even when TautWeekly cannot connect to
Plex Media Server directly. Provider-labelled ratings and selected clear logos
may instead require direct Plex metadata or a compatible Tautulli item export.

Update to v0.9.1 or newer if the log says that a rich export failed with HTTP
400. Earlier builds incorrectly requested Tautulli's library/user-only
`individual_files` option for a single `rating_key` export, then expected a
ZIP where Tautulli correctly returns a rating-only JSON file. v0.9.1 follows
the item-export contract and requests metadata level 1 with media information
disabled.

Update to v0.9.2 or newer if the log says TautWeekly could not enumerate
exporter fields or v0.9.1 still produces no movie ratings. Some Tautulli
implementations require a non-null `sub_media_type` despite documenting it as
optional. v0.9.2 sends that compatibility value and explicitly requests only
the four provider-labelled rating fields. It applies the item-export fallback
to movie RT and show IMDb, and validates controlled SendTest delivery
separately from browser preview.

Update to v0.9.5 or newer if movies show IMDb even though another supported
Plex/Tautulli path contains Rotten Tomatoes values. v0.9.4 treated any
recognized selected provider as complete, so a flattened IMDb movie score
could prevent the later rating-only Tautulli export from supplying RT. v0.9.5
exhausts the supported RT sources first and uses labelled IMDb only when no RT
critic or audience value exists.

For TV release rows, v0.10.2 ignores selected TMDB/TVDB as a display substitute
and continues to the exact episode's provider entries. Exact-episode IMDb has
priority. If IMDb is unavailable, the row uses that same episode's Rotten
Tomatoes critic value, then its audience value. It remains unrated when none of
those exact-episode values exist rather than showing a series-level, movie, or
unrelated provider score.

If ratings work on Windows but not in Docker, that can mean Windows reached
Plex directly while the container fell through to Tautulli; it does not imply
that the packages maintain different rating renderers. Comparative logs can
also show Windows receiving RT directly from Tautulli while Docker receives
only a flattened selected IMDb/TMDB value. Versions through v0.9.7 did not
explicitly request Plex's optional `Rating` element in that direct fallback;
v0.9.8 requests it and excludes the case-colliding scalar JSON `rating` field
that can mask the provider array in PowerShell. Update first, then rerun
PreviewAll or SendTest.

Plex documents response include/exclude customization as best-effort rather
than guaranteed. v0.10.1 therefore retries the same authenticated local item
as XML when JSON lacks the media-specific provider entries: movie RT
critic/audience or exact-episode IMDb/RT. This
does not contact a third-party ratings service or change the configured Plex
Ratings Source; it recovers only provider-labelled values already returned by
the user's Plex server.

If the log also says every direct Plex request failed, verify
`PlexServerUrl` from the TautWeekly runtime. In a separate Docker container,
`localhost` and `127.0.0.1` refer to TautWeekly itself, not the Plex
container or NAS host. Use a shared-network Plex service name or another
trusted LAN URL reachable from inside the container, normally on port 32400,
and keep `PlexToken` private. The platform verifier now exercises the same
resolved direct-Plex path used by newsletter generation: it requests
`/identity` and authenticated `/library/sections`, sends the token only in an
HTTP header, and never prints it. An unreachable or unauthorized resolved
connection fails verification instead of surfacing for the first time during
Preview or SendTest. If no URL/token pair can be resolved, verification warns
that only Tautulli's selected/flattened rating and other fallbacks are
available. Re-run the verifier, PreviewAll, and a controlled SendTest after
correcting the private configuration or container networking.

A passing verifier proves authenticated reachability, not that a particular
Plex item publishes each provider score or that Plex/Tautulli metadata is
current. After first install—or when a metadata-recovery update still shows
stale results—prepare every included movie/TV library before acceptance:

1. In Plex Web, confirm the intended **Edit → Advanced → Ratings Source** for
   each included Plex Movie library.
2. Run **Manage Library → Refresh All Metadata** for each included movie/TV
   library and wait for every refresh to finish. A full refresh can be slow and
   can update metadata or artwork; do not refresh unrelated libraries.
3. In Tautulli, open each same **Library → Media Info** tab and choose
   **Refresh media info**. The current control is per library, so repeat it for
   every included section and wait for completion.
4. Re-run the verifier, PreviewAll, and a controlled TestEmail. On v0.9.8 or
   newer, inspect only the sanitized `Design ratings:` lines.

Tautulli's media-info-table refresh does not choose a ratings provider and does
not replace Plex's refresh. If IMDb/TMDB is selected deliberately in Plex,
labelled IMDb is the expected movie fallback. Do not share the configuration,
token, generated preview, recipient information, or full log.

Routine TautWeekly updates do not require this full sequence when current
output already renders correctly.

A passing Tautulli check does not prove direct Plex works. Tautulli and
TautWeekly can run in different containers, networks, DNS contexts, and trust
stores. Likewise, a poster loaded through Tautulli's image proxy does not prove
TautWeekly can query Plex's full alternate `Rating[]`, exact episodes,
backgrounds, or selected logos directly.

TautWeekly omits a rating rather than guessing its provider. A dedicated IMDb
or Rotten Tomatoes badge still requires that provider label. TMDB/TVDB values
are not substituted for movie RT or exact-episode IMDb/RT. Unknown labels and
unlabeled numbers remain hidden, and a logo is omitted when Plex/Tautulli has
no selected logo resource.
Do not post `config.json`, diagnostic JSON, generated previews, or full logs;
share only sanitized warning text if further help is required.

`Optional Plex hosted metadata recovery found no exact match ...` is a
best-effort informational fallback for an exact retained metadata GUID. It may
be attempted for a missing summary, year, genre, or rating and is not proof
that the authenticated local rating lookup failed. Use the final sanitized
`Design ratings:` line to determine which provider values reached rendering.

## Deleted item still has no poster or metadata

v0.8.3's Plex hosted-provider recovery is best-effort. Tautulli history may
retain GUID/rating keys, titles, years, indexes, and viewing fields, but those
rows do not preserve durable image bytes. If Plex/Tautulli discarded the asset
before v0.9.0 observed it live, TautWeekly cannot recover it reliably and will
not guess by title. This is expected for already-deleted items and is not fixed
by changing the cache settings.

Enabling the cache does not crawl the whole Plex library or retroactively
recover an item that is already gone. On **Validate, save, and verify**, the
dedicated cache refresh checks every production-eligible included user's
current `DaysBack` newsletter history in the selected movie/TV libraries. A
qualifying item still needs live metadata, a stable GUID, and a non-generic
poster at that moment. The cache step shows blue **Running** and is independent
of PreviewAll; it sends no email and does not need one owner/administrator
sample. At its terminal state, Manager automatically checks configuration,
initialization, manifest/backup structure, aggregate entry and artwork counts,
retention/bounds, write access, and artwork integrity.

Start with Manager Dashboard **Config status → Deleted-item cache**, then open
**Verify → Check deleted-item cache**. The manual check validates configuration,
initialization, manifest/backup structure, current entry and artwork counts,
retention/bounds, write access, and artwork hashes without contacting Plex,
Tautulli, SMTP, or recipients.

The Verify result is retained across refreshes; this manual action is an
optional recheck for later filesystem or configuration changes.

If configuration was edited outside Manager, or an explicit refresh is useful,
run the non-sending refresh first:

```text
Windows:        20-REFRESH-DELETED-ITEM-CACHE.bat
NAS/Compose:    ./tautweekly.sh cache-refresh
macOS Docker:   ./tautweekly.sh cache-refresh
native Linux:   sudo tautweekly cache-refresh
FreeBSD Podman: sudo tautweekly cache-refresh
```

For generic Compose without the packaged wrapper:

```bash
docker compose exec tautweekly /opt/tautweekly/bin/run-mode.sh CacheWarm
```

The same share-safe health summary is available from each package:

```text
Windows:        19-CACHE-DIAGNOSTICS.bat
NAS/Compose:    ./tautweekly.sh cache-status
macOS Docker:   ./tautweekly.sh cache-status
native Linux:   sudo tautweekly cache-status
FreeBSD Podman: sudo tautweekly cache-status
```

For generic Compose without the packaged wrapper:

```bash
docker compose exec tautweekly /opt/tautweekly/bin/run-script.sh \
  Cache-Diagnostics.ps1 -DataRoot /data
```

In an Unraid container Console, omit the `docker compose exec tautweekly`
prefix. Append `-VerifyArtworkHashes` to hash every cached artwork file.
Append `-ProbeMediaType movie` or `-ProbeMediaType show` for a hidden prompt
that tests one exact GUID locally and prints only `hit`, `miss`, or `invalid`.
Never paste or share the GUID entered at that prompt.

Interpret the summary as follows:

- `Enabled: false` means saved configuration has intentionally stopped cache
  reads and writes.
- `Manifest: unseeded` with `Available: true` means local storage works but no
  qualifying live refresh or render has captured an entry. Run the applicable
  cache-refresh command, then run the status command again and compare only
  the aggregate counts.
- `Writability: failed` means the runtime identity cannot safely initialize or
  update the private cache volume.
- `backup-recovered` or `reset-after-corruption` records bounded automatic
  recovery. The latter starts empty because neither manifest generation was
  valid.
- expired entries are removed at initialization and after writes; the newest
  remaining entries are retained within the item/byte limits, so older excess
  entries are evicted. The summary shows current counts and configured bounds;
  it does not expose which item was evicted.
- an exact probe `miss` means that exact movie/show GUID is absent. The item may
  never have been captured live, may have lacked an eligible poster/GUID, or may
  have expired or been evicted. Titles and rating keys are never substitutes.
- a hash mismatch means damaged artwork fails closed. Rendering continues
  without using those bytes.

To prove that a container recreate keeps the same private data mount, create a
non-sensitive persistence marker, perform the package's normal restart/recreate,
verify it, and clear it:

```bash
./tautweekly.sh cache-status -Action SetPersistenceProbe
./tautweekly.sh restart
./tautweekly.sh cache-status -Action VerifyPersistenceProbe
./tautweekly.sh cache-status -Action ClearPersistenceProbe
```

Use `sudo tautweekly ...` on Linux/FreeBSD, or pass the same `-Action` values to
`19-CACHE-DIAGNOSTICS.bat` on Windows. A missing marker after recreation means
the runtime is attached to different or ephemeral storage. Do not delete the
old volume or pair/configure an empty replacement while investigating.

The command output is designed to share verbatim. Never post the cache
manifest, cached artwork, `config.json`, GUID input, tokens, viewing history,
recipient data, raw logs, generated output, or private paths. If a clean rebuild
is appropriate, stop TautWeekly and remove only the cache directory under the
private data root; do not do this merely to hide a mount or permission problem.

When requesting help, share the platform, source/release version, failing
command, and sanitized error text. Never attach configuration, state, logs, or
generated mail without removing credentials and personal data.
