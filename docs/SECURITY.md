# Security and hardening

## Secrets at rest

`config.json` stores a Tautulli API key and SMTP password in plain text, may
store a Plex token, and may contain private managed-user fallback addresses in
`UserEmailOverrides`. Limit filesystem access to the account that runs
TautWeekly for Plex. Docker installations use `UMASK=077` and a non-root UID/GID;
Windows installations should use a private directory with appropriate NTFS
permissions. Native Linux uses a dedicated service account and mode-0700
`/var/lib/tautweekly`; FreeBSD uses mode-0700 `/var/db/tautweekly` mounted into
the container with a non-root runtime identity.

Backups contain the same secrets. Encrypt them or place them in protected
storage. Manager and expert/recovery writers retain the newest 10 recognized
timestamped backups and remove the oldest on overflow. Manager **Config > Configuration
backups** exposes only metadata. Restore validates the selected file and first
saves the live configuration. Delete accepts only the exact Manager-listed
backup filename, refuses symlinks/non-files, requires an authenticated
same-origin CSRF-protected request plus a separate browser confirmation, and
permanently removes only that backup. It never changes `config.json`.

Custom-title GIF configuration accepts only six fixed asset IDs. IDs map to
packaged byte-verified filenames, `image/gif` MIME types, and deterministic CIDs;
paths, URLs, filenames, arbitrary MIME types, and arbitrary CIDs are rejected.
Email attaches only the selected referenced asset, and the Manager serves the
same local files without a runtime font or network dependency.

## SMTP submission

Use the mail service's outbound submission endpoint, not an incoming-mail host
or webmail URL. Keep `SmtpEnableSsl=true` so the connection upgrades with
STARTTLS and validates the configured hostname against the operating-system
trust store. Implicit TLS on port 465 is unsupported. Disable authentication
only for an explicitly administered, network-restricted relay that authorizes
the TautWeekly runtime without credentials.

Use a dedicated SMTP-capable or application-specific credential when account
policy supports it, grant only the sender identities needed by `FromEmail`, and
rotate the credential after exposure or account changes. `SmtpPassword` is
stored in private `config.json` and its backups; Manager returns only a fixed
presence marker unless an authenticated password re-entry authorizes a
short-lived reveal. Do not place credentials in environment examples, logs,
screenshots, issues, or generated previews.

Verification checks reachability without authenticating. Perform the first
real check with one controlled TestEmail recipient. Each production message has
exactly one envelope recipient, and the transport stops a batch on
authentication failure, temporary service rejection, batch-wide rejection,
transport failure, or unknown final-DATA acceptance. Diagnostics retain only
the sanitized failure category/stage, numeric response code, acceptance state,
attempt count, and local support code—not provider response text, addresses,
credentials, or message content.

## Deleted-item cache

The persistent cache is private media-library data even though it contains no
credentials or recipient records. It stores exact stable media GUIDs, titles,
years, bounded summaries and genres, displayed rating values, poster bytes and
hashes, and timestamps. It deliberately excludes Tautulli API keys, the Plex
administrator token, SMTP settings, recipient identity, playback metrics, and
generated newsletter output. The Plex token is never passed into the cache.

Cache locations are `cache/deleted-items` beside the Windows application,
`/data/cache/deleted-items` in Docker/macOS, `/var/lib/tautweekly/cache/deleted-items`
on native Linux, and `/var/db/tautweekly/cache/deleted-items` on FreeBSD. Apply
the same filesystem permissions and backup protections as `config.json`.
Exact GUID plus media type is the only lookup identity; title-only and malformed
manifest entries fail closed. Posters are verified by SHA-256 before reuse.

Retention defaults to 365 days, 1,000 items, and 256 MiB total. Deterministic
cleanup, atomic primary/backup manifests, a one-megabyte corrupt-manifest cap,
and orphan removal keep storage bounded. To purge without changing
configuration, stop the service/application and remove only this directory.
Disabling the feature stops access but does not erase the existing cache.

## Network boundaries

- NAS/Docker, macOS Docker Desktop, native Linux, and FreeBSD Podman require
  Manager authentication.
  There is no default password. Retrieve a random first-run token only through
  the platform's explicit `manager-bootstrap` command; it is intentionally
  absent from normal logs and diagnostics.
- The Manager uses HttpOnly SameSite cookies, per-session CSRF tokens,
  same-origin mutation checks, bounded sessions, and login throttling. A
  service restart invalidates sessions without changing newsletter delivery
  state. Access recovery resets only Manager authentication material.
- Keep every Manager listener off the public internet. NAS/FreeBSD/macOS use
  port 8787 and native Windows/Linux use port 8788; public native access still
  reaches only the loopback listener through the verified proxy. Prefer the
  documented localhost bind or a trusted LAN bind restricted by the host
  firewall. macOS binds to Mac loopback by default; changing that bind requires
  the same explicit allowed-host and TLS review as any other network-reachable
  Manager.
- Every maintained package can opt in to public HTTPS Tailscale Funnel while
  the Manager remains on its fixed local target. Native Windows uses a fixed
  UAC helper, native Linux uses a root-owned one-shot socket adapter, and the
  Docker/NAS, macOS Docker Desktop, FreeBSD/Podman, QNAP, Synology, and Unraid
  packages use an isolated userspace adapter built from the pinned official
  Tailscale image. Each adapter accepts only the exact TautWeekly operation and
  target and verifies the observed route. A
  green active state additionally requires the exact public hostname to resolve
  through the fixed `1.1.1.1` resolver to a globally routable IPv4 address and
  complete a certificate-validated TLS handshake. Only that intended-public
  hostname is disclosed for the verification; answers, certificates, raw
  output, Manager data, and private network details are not returned or stored.
  Failure remains a gold publication-pending state and never triggers an
  automatic service restart, DNS change, firewall rule, or router change. The
  password lock is mandatory before Funnel enablement. A remote viewer needs no
  Tailscale client or VPN because the login page is public; use a unique
  password and retain local recovery because Internet brute-force risk remains.
  This delivery adds no new Internet login-attempt limiter.
- The container adapter has its own root-only Tailscale state and runtime
  sockets. The non-root Manager has no Docker/Podman socket, host executable,
  TUN device, host network, added networking capability, auth key, OAuth
  secret, or arbitrary CLI input. The adapter uses userspace networking,
  authenticates only through an explicit interactive administrator command,
  and proxies only to the fixed Manager target inside the same container.
  Adapter state is separate from `/data` and is never exposed in diagnostics.
- Every remote session has full Manager administration because no read-only
  role exists. Keep the installed or bundled official Tailscale runtime
  current, protect the tailnet identity with MFA, and promptly revoke a lost
  node. A remote viewer needs only an ordinary browser and the independent
  Manager password.
- The browser API accepts only allowlisted `enable`, `disable`, and `verify`
  operations. It never accepts a hostname, port, URL, path, command, executable,
  CLI argument, credential, or raw provider response. Never expose or retain
  auth keys in Manager, Compose YAML, `.env`, Community Apps templates,
  screenshots, logs, or support bundles.
- Funnel state contains only a schema version, selected state, and the
  exact verified public hostname. It never stores raw CLI output, auth keys,
  control-plane tokens, tailnet identity, device lists, private IPs, or
  sensitive paths. Password-lock disable, local access reset, and uninstall
  first disable and verify the owned Funnel or fail closed. Password changes
  keep Funnel and the current session but revoke other sessions. Installer
  Windows, native Linux, and package updates preserve private Manager data,
  the selected remote-access preference, and its fixed route across replacement
  and rollback. Explicit stop, access recovery, adapter revocation, and
  uninstall still disable and verify the route first. Legacy exact-owned Serve
  state is parsed only during migration or cleanup and is never offered as a
  deployment mode.
  See the [remote-access architecture](REMOTE-ACCESS.md) for the complete
  platform and lifecycle matrix.
- Maintained packages keep recovery on loopback and use only the independently
  verified Funnel hostname for public ingress. Do not add LAN/all-interface
  binds, proxy Host rewrites, wildcard hosts, router ports, or firewall rules as
  a workaround. The Manager does not infer TLS or client identity from
  forwarded headers. Same-origin comparison
  lower-cases DNS, removes one trailing dot, and normalizes omitted/default
  `:80` or `:443`; malformed origins, different hosts, and Tailscale HTTP
  mutations remain rejected with sanitized reason codes.
- Unauthenticated health endpoints expose liveness only. They do not return
  configuration, credentials, sessions, paths, diagnostics, or newsletter
  state.
- Normal Manager/Dashboard health and `GET /api/v1/updates` are offline-only.
  After authenticated application entry renders that cached result, the GUI
  makes one non-blocking check only when no successful result exists or it is at
  least 24 hours old and retry backoff permits. The main header **Refresh**
  completes its local status load first, repeats the saved-revision LAN-only
  Tautulli choices lookup when configuration is ready, and starts the same
  non-blocking update check when its cooldown permits. The lookup cannot start
  preview generation or contact Plex/SMTP. Successful results are reused for
  five minutes before **Check now** can use the same
  endpoint for another explicit refresh. All paths use a fixed HTTPS GitHub
  endpoint, reject redirects and unexpected hosts/assets, bound time and
  response size, cache only public release fields plus fixed sanitized
  failures, and back off repeated checks. The login/bootstrap page, navigation,
  scoped refresh controls, and health endpoints never initiate a check. Update
  mutations require the
  same session, same-origin, CSRF, Host, proxy, and secure-cookie controls as
  every other protected Manager action.
- Only Windows exposes a GUI install action, and it can start only the fixed
  packaged checksum/manifest-verified updater behind explicit confirmation and
  Windows elevation. Container/native service Managers never receive a Docker
  socket, privileged helper, root identity, `sudo`, Podman, systemd, or rc.d
  authority; Settings reports the exact host-owned next step instead.
- Use HTTPS for remote Tautulli/Plex endpoints when your environment provides a
  trusted certificate.
- Best-effort hosted deleted-item recovery sends only Tautulli's retained exact media GUID and the
  configured administrator/server Plex token to
  `https://metadata.provider.plex.tv`. It sends no recipient identity, email,
  or watch-history values and does not perform title searches.
- Hosted recovery cannot reliably reconstruct artwork already discarded by
  Plex/Tautulli. The persistent cache protects future items only after a live
  run captured them; it does not create a retroactive title-matching path.
- Manager and CLI cache diagnostics return aggregate health, bounds, and counts
  only. Their write/persistence probes contain no media or account data, and
  exact-GUID input is hidden and reduced locally to `hit`, `miss`, or `invalid`.
  They never return paths, titles, identifiers, hashes, artwork, recipients,
  viewing metrics, tokens, or manifest contents.
- Hosted artwork returned on a different origin is fetched without the Plex
  token. The token is attached only to Plex server and Plex metadata-provider
  requests.
- Use SMTP STARTTLS and provider-specific application credentials.

## Delivery safeguards

- Keep `TestEmail` under operator control.
- Review all six preview states and test messages after setup or upgrades.
- Review exclusions and the user roster before a bulk send.
- Treat exclusion-selector output as private: it contains Tautulli names, IDs,
  and recipient email addresses.
- Keep the built-in recipient delay unless your SMTP provider explicitly allows
  a different rate.
- Do not bypass the confirmation switches or wrapper prompts.

## Recipient privacy

Managed-user fallback addresses are private configuration, not discovery data.
Authenticated Config editing can read and change the map, and private backups
contain it. Sanitized discovery and its retained cache expose only whether an
active native-email-blank user needs an address; config summaries, operation
results, diagnostics, and shareable cache reports omit the map and addresses.
Production uses a fallback only when Tautulli has no native email and evaluates
the effective address against the existing exclusion policy. Every
personalized preview, TestEmail, welcome, and production mode enforces that
saved policy. TestEmail modes may inspect the effective address only to apply
`ExcludedEmails`; they never deliver to it and still send solely to the
configured `TestEmail`.

The reserved Tautulli Local identity (user ID `0`) is never a newsletter
recipient, even if private configuration contains a fallback address for it.
Individual user lookups must match the requested ID; Tautulli's default Local
response is not accepted as another user's identity. Failed matches use an
exact bulk-roster match or fail closed before personalized generation or send.

Scheduled weekly messages share only the Binge Champion's anonymous aggregate:
total watch time, total plays, and nonzero unique movie and TV-show counts. When
more than one episode qualifies, the cumulative episode count across those TV
shows is included. The champion's friendly name, username, user ID, and watched
titles are not disclosed. Only the winning recipient sees the gold **YOU WON**
treatment. Detailed personal recap rows remain private to each recipient, and
one-off welcome messages do not contain the award.

## Credential rotation

If a credential is exposed, revoke it first, then issue a replacement, update
the live configuration, and verify the affected integration. Deleting a commit
or issue does not make a published credential safe again.

Report vulnerabilities through the private process in the root
[security policy](../SECURITY.md).
