<div align="center">

<img src="assets/branding/tautweekly-logo-256.png" alt="TautWeekly detailed popcorn TW logo" width="220">

# TautWeekly for Plex

**A portable, preview-first weekly Plex activity newsletter powered by Tautulli [🩷 JonnyWong16](https://github.com/JonnyWong16).** 

[![CI](https://github.com/sparkmoxie/TautWeekly/actions/workflows/ci.yml/badge.svg)](https://github.com/sparkmoxie/TautWeekly/actions/workflows/ci.yml)
[![Pages](https://github.com/sparkmoxie/TautWeekly/actions/workflows/pages.yml/badge.svg)](https://sparkmoxie.github.io/TautWeekly/)
[![License: MIT](https://img.shields.io/badge/code%20license-MIT-e5a00d.svg)](LICENSE)
![Windows](https://img.shields.io/badge/Windows-PowerShell%205.1-0078d4?logo=windows)
![NAS](https://img.shields.io/badge/NAS-Docker%20Compose-2496ed?logo=docker)
[![Unraid Community Apps](https://img.shields.io/badge/Unraid-Community%20Apps-f15a2c?logo=unraid)](https://sparkmoxie.github.io/TautWeekly/nas-docker/#unraid)
![Container](https://img.shields.io/badge/GHCR-amd64%20%7C%20arm64-2496ed?logo=docker)
![macOS](https://img.shields.io/badge/macOS-Docker%20Desktop-000000?logo=apple)
![Linux](https://img.shields.io/badge/Linux-native%20systemd-4d8f28?logo=linux)
![FreeBSD](https://img.shields.io/badge/FreeBSD-Podman%20beta-b7292f?logo=freebsd)

Turn Plex activity into polished new-release, personal-recap, welcome, quiet-week,
and milestone emails. Preview locally, send controlled tests, then schedule delivery.

[TautWeekly Quickstart](https://sparkmoxie.github.io/TautWeekly/) ·
[GUI Preview](https://sparkmoxie.github.io/TautWeekly/gui-preview/) ·
[Preview the email states](https://sparkmoxie.github.io/TautWeekly/examples/preview-all-00-INDEX.html) ·
[Download the latest release](https://github.com/sparkmoxie/TautWeekly/releases/latest) ·
[Read the documentation](docs/README.md)

</div>

> [!IMPORTANT]
> TautWeekly handles private Plex/Tautulli activity and mail credentials. Preview
> first, use a controlled test recipient, and never commit or publicly share live
> configuration, tokens, logs, previews, newsletters, state, or backups. See
> [Security and hardening](docs/SECURITY.md).

## Choose a platform

| Platform | Best fit | Start here |
|---|---|---|
| Windows Manager | Always-on Windows 10/11 host | [Windows Quickstart](https://sparkmoxie.github.io/TautWeekly/windows/) · [Documentation](docs/windows/README.md) · [Download Setup](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-Setup.exe) |
| NAS / Docker | Debian, Ubuntu, or another Linux Docker server; QNAP and Unraid too—dedicated NAS hardware is not required | [NAS/Docker/QNAP/Unraid Quickstart](https://sparkmoxie.github.io/TautWeekly/nas-docker/) · [Unraid Apps](https://ca.unraid.net/apps/tautweekly-for-plex-16l668j1jpt7jb) · [Documentation](docs/nas-docker/README.md) · [Standalone Compose](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-compose.yaml) · [Archive fallback](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-nas-docker.tar.gz) |
| macOS | Docker Desktop on Intel or Apple silicon | [macOS Quickstart](https://sparkmoxie.github.io/TautWeekly/mac/) · [Documentation](docs/mac/README.md) · [Standalone Compose](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-mac-compose.yaml) · [Archive fallback](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-mac-docker.tar.gz) |
| Native Linux | Docker-free Ubuntu, Debian, or RHEL host with systemd | [Native Linux Quickstart](https://sparkmoxie.github.io/TautWeekly/linux/) · [Documentation](docs/linux/README.md) · [Download](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-linux.tar.gz) |
| FreeBSD / Podman **beta** | FreeBSD 15.1+ amd64 host | [FreeBSD Podman Quickstart](https://sparkmoxie.github.io/TautWeekly/freebsd/) · [Documentation](docs/freebsd/README.md) · [Download](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-freebsd-podman.tar.gz) |

For a Linux server that already uses Docker or Compose, choose **NAS / Docker**;
“NAS” names the container distribution and does not require a NAS appliance.
Choose **Native Linux** for a Docker-free systemd installation. Both are
headless and provide the same Manager workflow and newsletter behavior, but
their normal Manager access paths differ as described below.

Manager release updates:

- An optional custom text card before the newsletter release-count/date block,
  with configurable border color/opacity, optional title and subheading, and a
  required plain-text body when enabled.
- Optional public HTTPS administration through password-gated **Tailscale
  Funnel** on every maintained package, so an ordinary remote browser needs no
  VPN client. Native packages use fixed host adapters; container/NAS, macOS,
  Unraid, QNAP/Synology, and FreeBSD/Podman use the isolated opt-in userspace
  adapter with root-only provider state and explicit interactive sign-in.
- Capability-aware **Settings > Updates** status for application, package, image,
  and host-adapter layers. A header SVG appears only for a validated newer
  release; Windows can launch its verified updater, while other packages keep
  update authority with the host.
- A responsive Dashboard with guided **Config**, **Verify**, **Previews**,
  **Schedule**, and **Settings** workflows, plus private backups and preview-first
  delivery controls.

See the platform guides for exact setup, mobile access, update, and recovery
steps.

### Windows Manager

Run the native Setup EXE, choose the permanent application folder for a new
installation, and finish the guided local GUI. A validated existing Setup
installation reuses its registered folder directly during update. Windows adds
tray health/actions, optional sign-in startup and password lock, plus an
independent Scheduled Task; **Settings > Updates** can start the existing
verified elevated updater.

### NAS / Docker Manager

Use the unified `ghcr.io/sparkmoxie/tautweekly` image with the explicit
`server` or `unraid` profile, bootstrap the authenticated Manager, and keep
private state under `/data`. QNAP/Compose wrappers and Unraid Apps retain
their host-owned verified update and recovery paths. The service is fully
headless: local recovery stays at `http://127.0.0.1:8787/` on the Docker host
and is reached through an SSH local forward when needed. Optional public
Manager access uses only the independently verified Tailscale Funnel URL.

### macOS Manager

Pull that same public amd64/arm64 image with the `desktop` profile and one
checksummed standalone Compose file—no clone or local build—then bootstrap
Manager access. Private state persists under `/data`; Mac-owned
semver/digest pull, recreate, and rollback keep Docker control outside the
container. The verified archive/local-build wrapper remains a supported
break-fix fallback.

### Native Linux Manager

Install the matching amd64 or arm64 archive and access the authenticated,
loopback-only GUI through the documented SSH tunnel/bootstrap flow. This
service is also headless and needs no local desktop, and it does not publish its
Manager directly to the LAN. systemd owns the service and schedule while
`tautweekly update` retains verified host update and recovery authority. A
root-owned fixed adapter can optionally publish that loopback Manager through
password-gated Tailscale Funnel.

### FreeBSD Podman Manager

Install the beta Podman package, bootstrap Manager access through the documented
tunnel, and use the same guided GUI. rc.d and the host wrapper retain service,
backup, verified update, health-check, and rollback ownership.

Container users upgrading from either v0.22.0 image should follow the
[unified image and migration guide](docs/CONTAINER-MIGRATION.md); it preserves
existing data and documents the old Mac-image compatibility window.

## GUI Manager

The responsive Manager is the primary workflow on every maintained package:

- **Set up and configure:** Dashboard guides first run; Config manages
  connections, SMTP, branding, library scope, delivery exclusions, private
  fallback addresses for managed users without native Tautulli email, schedule,
  rolling backups, and the optional custom newsletter text card—including its
  six-choice local title GIF selector—without hand-editing JSON. Stored secrets
  remain write-only.
- **Verify before sending:** one non-sending validation records connection,
  library/user, SMTP preflight, and local-preview evidence. Previews renders six
  newsletter states, and controlled TestEmail delivery stays separate from
  production recipients.
- **Operate deliberately:** Schedule reports and controls only the package's
  supported delivery lifecycle; Settings covers access, public Tailscale Funnel
  on every maintained package, capability-aware update status, release notes,
  diagnostics, and recovery. The Dashboard Integrations card distinguishes
  retained Funnel **Off**, verified **Active**, publication-pending
  **Attention**, blocked **Failed**, and neutral non-applicable states without
  invoking Tailscale during rendering. Manual and scheduled production delivery
  share one guarded live-roster refresh and eligibility path, 30-second default
  attempt spacing, and fail-fast handling for batch-wide SMTP failures.
  Host-owned packages keep update and service authority outside the web process.

## Current newsletter behavior

- **New releases:** Movie and TV additions with artwork, summaries, ratings,
  and episode details.
- **Weekly highlights:** Hot new releases, trending movies, and the week's
  top movie genre keep discovery useful even during quieter weeks.
- **Personal recaps:** Each recipient sees their own watch time, viewing
  highlights, and movie **Watched** marks.
- **Managed profiles:** An active Tautulli user without native email can receive
  a personalized recap through an administrator-assigned private fallback;
  native email always wins and existing exclusions still apply.
- **Binge Champion:** A privacy-preserving award celebrates the week's
  leading viewer.
- **Adaptive layouts:** Welcome, active-week, quiet-week, and milestone
  newsletters fit each recipient's activity.
- **Custom announcements:** Add an optional branded text card for your own
  message.

Tautulli is the required activity source. Optional direct Plex access enriches
ratings and artwork when the server exposes them. Detailed provider, privacy,
cache, and rendering rules live in the references linked below.

## Get started

1. Choose your platform above and open its interactive Quickstart.
2. Install the latest stable package, open the Manager, and complete its guided
   GUI setup. Platform commands are only for installation, private bootstrap,
   or documented expert/recovery work.
3. In the GUI, run **Validate, save, and verify**, inspect all six private
   previews, and send a controlled TestEmail.
4. Enable scheduled delivery in the GUI only after the result is correct.

The platform guides contain the exact requirements, commands, metadata-readiness
sequence, update and rollback behavior, network guidance, and troubleshooting.

## Quick links

- [Interactive Quickstart home](https://sparkmoxie.github.io/TautWeekly/)
- [GUI Preview](https://sparkmoxie.github.io/TautWeekly/gui-preview/)
- [Email States Preview](https://sparkmoxie.github.io/TautWeekly/examples/preview-all-00-INDEX.html)
- [Latest release and notes](https://github.com/sparkmoxie/TautWeekly/releases/latest)
- [SHA-256 checksums](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/SHA256SUMS.txt)
- [Configuration reference](docs/CONFIGURATION.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Security and hardening](docs/SECURITY.md)
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md) · [Contributors](CONTRIBUTORS.md)

## License and affiliation

TautWeekly for Plex source code, documentation, and bundled custom artwork are
licensed under the [MIT License](LICENSE). Asset provenance is recorded in
[Third-party notices](THIRD_PARTY_NOTICES.md).

TautWeekly for Plex is an independent community project. It is not affiliated
with, endorsed by, or sponsored by Plex, [Tautulli](https://github.com/tautulli/tautulli), or the other platforms and
providers it integrates with. All product names and marks belong to their
respective owners.
