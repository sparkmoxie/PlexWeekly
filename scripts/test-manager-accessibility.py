#!/usr/bin/env python3
"""Dependency-free structural accessibility checks for the embedded Manager UI."""

from __future__ import annotations

import argparse
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse


class Node:
    def __init__(self, tag: str, attrs: list[tuple[str, str | None]], parent: Node | None):
        self.tag = tag
        self.attrs = {name: value or "" for name, value in attrs}
        self.parent = parent
        self.children: list[Node] = []
        self.text: list[str] = []

    def ancestors(self):
        current = self.parent
        while current is not None:
            yield current
            current = current.parent

    def accessible_text(self) -> str:
        if self.attrs.get("aria-hidden", "").lower() == "true":
            return ""
        values = list(self.text)
        values.extend(child.accessible_text() for child in self.children)
        return " ".join(" ".join(values).split())


class DocumentParser(HTMLParser):
    void_elements = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("document", [], None)
        self.stack = [self.root]

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        node = Node(tag, attrs, self.stack[-1])
        self.stack[-1].children.append(node)
        if tag not in self.void_elements:
            self.stack.append(node)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        if tag not in self.void_elements:
            self.stack.pop()

    def handle_endtag(self, tag: str) -> None:
        for index in range(len(self.stack) - 1, 0, -1):
            if self.stack[index].tag == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        if data.strip():
            self.stack[-1].text.append(data)


def descendants(node: Node):
    for child in node.children:
        yield child
        yield from descendants(child)


def local_asset(value: str) -> bool:
    if not value or value.startswith(("#", "data:")):
        return True
    parsed = urlparse(value)
    return not parsed.scheme and not parsed.netloc and not value.startswith("//")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--html", type=Path, default=Path("manager/internal/manager/web/index.html"))
    parser.add_argument("--css", type=Path, default=Path("manager/internal/manager/web/app.css"))
    parser.add_argument("--js", type=Path, default=Path("manager/internal/manager/web/app.js"))
    args = parser.parse_args()

    html = args.html.read_text(encoding="utf-8")
    document = DocumentParser()
    document.feed(html)
    nodes = list(descendants(document.root))
    failures: list[str] = []

    ids: dict[str, Node] = {}
    for node in nodes:
        identifier = node.attrs.get("id", "")
        if not identifier:
            continue
        if identifier in ids:
            failures.append(f"duplicate id: {identifier}")
        ids[identifier] = node

    if not any(node.tag == "main" for node in nodes):
        failures.append("no main landmark")
    if not any(node.tag == "nav" for node in nodes):
        failures.append("no navigation landmark")
    if "main-content" not in ids:
        failures.append("skip-link main-content target is missing")
    skip_links = [node for node in nodes if "skip-link" in node.attrs.get("class", "").split()]
    if len(skip_links) != 1 or skip_links[0].attrs.get("href") != "#main-content":
        failures.append("exactly one skip link must target #main-content")

    labels_by_target = {
        node.attrs["for"]
        for node in nodes
        if node.tag == "label" and node.attrs.get("for")
    }
    controls = [node for node in nodes if node.tag in {"input", "select", "textarea"} and node.attrs.get("type", "").lower() != "hidden"]
    for control in controls:
        identifier = control.attrs.get("id", "")
        nested_label = any(ancestor.tag == "label" for ancestor in control.ancestors())
        named = bool(control.attrs.get("aria-label") or control.attrs.get("aria-labelledby"))
        if not nested_label and identifier not in labels_by_target and not named:
            failures.append(f"unlabelled {control.tag}: {identifier or '<no id>'}")

    for button in (node for node in nodes if node.tag == "button"):
        if not button.attrs.get("aria-label") and not button.attrs.get("aria-labelledby") and not button.accessible_text():
            failures.append(f"button has no accessible name: {button.attrs.get('id', '<no id>')}")

    reference_attributes = ("for", "aria-labelledby", "aria-describedby")
    for node in nodes:
        for attribute in reference_attributes:
            for target in node.attrs.get(attribute, "").split():
                if target and target not in ids:
                    failures.append(f"{attribute} references missing id: {target}")

    for frame in (node for node in nodes if node.tag == "iframe"):
        if not frame.attrs.get("title"):
            failures.append("iframe has no title")
        sandbox = frame.attrs.get("sandbox")
        if sandbox is None:
            failures.append("iframe has no sandbox")
        elif "allow-scripts" in sandbox.split():
            failures.append("preview iframe unexpectedly allows scripts")

    for node in nodes:
        asset = ""
        if node.tag in {"script", "img"}:
            asset = node.attrs.get("src", "")
        elif node.tag == "link":
            asset = node.attrs.get("href", "")
        if asset and not local_asset(asset):
            failures.append(f"external runtime asset: {asset}")

    css = args.css.read_text(encoding="utf-8")
    if ":focus-visible" not in css:
        failures.append("CSS has no focus-visible treatment")
    if "prefers-reduced-motion:reduce" not in css.replace(" ", ""):
        failures.append("CSS has no reduced-motion override")
    if ".skip-link:focus" not in css:
        failures.append("skip link has no visible focus state")
    if "@keyframes schedule-state-swap" not in css:
        failures.append("schedule action state change has no CSS transition")
    if "white-space:nowrap" not in css or "grid-template-rows:auto 44px minmax(1.1rem,auto)" not in css:
        failures.append("Manager lock chip or password fields can distort their layout")
    if ".access-status-button:after" not in css or "content:attr(data-tooltip)" not in css:
        failures.append("access lock control has no downward status tooltip")
    if ".setup-workflow-steps article:last-child:nth-child(odd){grid-column:1/-1}" not in css:
        failures.append("an odd final setup check leaves an exposed grid cell")

    javascript = args.js.read_text(encoding="utf-8")
    required_dynamic_contracts = {
        'document.createElement("label")': "dynamic controls are not created with label elements",
        'setAttribute("aria-invalid", "true")': "dynamic validation does not expose aria-invalid",
        'role="status"': "status live regions are missing from the HTML source",
    }
    combined = javascript + "\n" + html
    for evidence, message in required_dynamic_contracts.items():
        if evidence not in combined:
            failures.append(message)

    if "function renderIntegrationStatus()" not in javascript:
        failures.append("dashboard integration details have no shared verification renderer")
    if "function configFieldIsHidden(field)" not in javascript or 'isServiceRuntime() && field.name === "ScheduledTaskName"' not in javascript:
        failures.append("service Manager modes do not suppress the Windows Scheduled Task configuration field")
    title_gif_contract = (
        'const noTitleGifChoice = Object.freeze({ id: "none", label: "None", file: "" });',
        '{ id: "celebrate", label: "Celebrate", file: "celebrate.gif" }',
        '{ id: "construction", label: "Construction", file: "construction.gif" }',
        '{ id: "rocket", label: "Rocket", file: "rocket.gif" }',
        '{ id: "tickets", label: "Tickets", file: "tickets.gif" }',
        '{ id: "warning", label: "Warning", file: "warning.gif" }',
        '{ id: "alert", label: "Alert", file: "alert.gif" }',
        'function attachTitleGifPicker(control, titleInput)',
        'assetInput.type = "hidden";',
        'trigger.setAttribute("aria-haspopup", "listbox")',
        'picker.setAttribute("role", "listbox")',
        'option.setAttribute("role", "option")',
        '["Enter", " "]',
        '["ArrowRight", "ArrowDown"]',
        '["ArrowLeft", "ArrowUp"]',
        'event.key === "Home"',
        'event.key === "End"',
        'event.key === "Escape"',
        '["Delete", "Backspace"]',
        'picker.hidden ? openPicker() : closePicker(true);',
        'selectedImage.width = 24;',
        'selectedImage.height = 24;',
        'selectedImage.src = `/media/${choice.file}`;',
    )
    for marker in title_gif_contract:
        if marker not in javascript:
            failures.append(f"optional title GIF selector contract is missing: {marker}")
    if javascript.count('if (["Enter", " "].includes(event.key))') < 2:
        failures.append("optional title GIF trigger does not suppress native Enter/Space activation before opening the picker")
    if 'id="icon-add-reaction"' not in html or 'data-symbol="add_reaction" data-fill="0" data-weight="400" data-grade="0" data-optical-size="24"' not in html:
        failures.append("local Material Symbols Outlined add_reaction SVG metadata is missing")
    if ".title-gif-trigger:focus-visible" not in css or ".title-gif-options{display:grid" not in css:
        failures.append("optional title GIF selector lacks focus or responsive grid styling")
    if "fonts.googleapis.com" in combined or "fonts.gstatic.com" in combined:
        failures.append("Manager title GIF selector added a runtime Google Fonts dependency")
    for marker in (
        "state.backupMaximum = Number(backups.maximumEntries) || 10;",
        "state.historyMaximum = Number(history.maximumEntries) || 20;",
        "const diagnosticMaximum = Number(diagnostics.maximumEntries) || 20;",
        'id="operation-history-count"',
        "count-only-fifo",
    ):
        if marker not in combined:
            failures.append(f"rolling retention UI contract is missing: {marker}")
    for marker in (
        'function isMacDocker()',
        'runtimeMode() === "mac"',
        'macOS Docker Desktop',
        './tautweekly.sh manager-bootstrap',
        './tautweekly.sh manager-reset-access',
    ):
        if marker not in javascript:
            failures.append(f"macOS Manager capability copy is missing: {marker}")
    if "function retainedSetupCheckState(" not in javascript or 'last?.overall || retainedLANState' not in javascript:
        failures.append("dashboard integrations do not fall back to retained save-verification state")
    if javascript.count("renderIntegrationStatus();") < 2:
        failures.append("status and verification refreshes do not share integration evidence")
    if "snapshot.integrations.tautulli" in javascript:
        failures.append("runtime status can overwrite live integration evidence with stale defaults")
    if 'setSwappingText("schedule-install-heading", installLabel);' not in javascript:
        failures.append("schedule action heading does not switch between Install and Refresh")
    if 'setSwappingText("schedule-install-button-label", installLabel);' not in javascript:
        failures.append("schedule action button does not switch between Install and Refresh")
    if "function setSwappingText(" not in javascript or "schedule-state-swap" not in javascript:
        failures.append("schedule action state change has no animated text transition")
    if "function setSwappingButtonText(" not in javascript or javascript.count("setSwappingButtonText(") < 8:
        failures.append("dynamic Manager buttons do not share the state-swap animation")
    if 'area === "lan-verification" ? "Connection Verification"' not in javascript:
        failures.append("retained verification diagnostics expose an internal LAN label")
    if 'id="metadata-readiness-confirm"' in combined or "metadataReady" in javascript:
        failures.append("automatic preview generation is still blocked by a separate readiness gate")
    if 'runPostSaveSetup(result.editor.revision, result.postSave);' not in javascript or 'plan.generatePreviews' not in javascript or 'type: "preview-all"' not in javascript:
        failures.append("validated configuration saves do not follow the backend-scoped preview plan")
    for marker in (
        'cacheDisabled ? setupWorkflowSteps.filter((name) => name !== "cache")',
        'All four applicable safe setup checks passed; the deleted-item cache is disabled.',
        'name === "cache" && state.cache?.enabled === false ? "Disabled"',
        'cache storage was not inspected.',
        'appendVerificationResult(cacheResults, "Deleted-item cache", "disabled", cache.summary);',
    ):
        if marker not in javascript:
            failures.append(f"disabled deleted-item cache presentation is missing: {marker}")
    for post_save_flag in ("runDiscovery", "runIntegration", "runSmtp", "generatePreviews", "warmCache", "verifyCache"):
        if f"result.postSave.{post_save_flag}" not in javascript:
            failures.append(f"configuration saves do not consume backend impact flag: {post_save_flag}")
    if "window.TautWeeklyUpdateUI.routeFromHash(window.location.hash)" not in javascript or "updateHistory: false" not in javascript:
        failures.append("Manager does not restore a local route safely after authentication")
    if 'id="first-time-setup"' not in combined or 'data-open-view="configuration"' not in combined:
        failures.append("Dashboard has no direct first-time setup route to Config")
    if 'state.editor?.state === "unconfigured"' not in javascript or 'prompt.hidden = !firstRun;' not in javascript:
        failures.append("first-time setup prompt is not limited to unconfigured installations")
    if 'id="dashboard-greeting"' not in combined or "function renderDashboardGreeting(" not in javascript:
        failures.append("Dashboard has no last-observed time greeting")
    if "minuteOfDay >= 360 && minuteOfDay <= 720" not in javascript or "minuteOfDay >= 721 && minuteOfDay <= 1080" not in javascript:
        failures.append("Dashboard greeting does not implement the requested morning and afternoon boundaries")
    if 'suggestedSelectablePreviewUserID()' not in javascript or 'name ? `${greeting}, ${name}.` : `${greeting}.`' not in javascript:
        failures.append("Dashboard greeting lacks the unambiguous administrator-name fallback")
    if 'id="access-status-button"' not in combined or 'addEventListener("click", openAccessSettings)' not in javascript:
        failures.append("access lock status does not route to password settings")
    if 'return "Container access"' not in javascript or 'return "Browser access"' not in javascript:
        failures.append("access lock tooltip is not platform-aware")
    for control in ("startup-manager", "startup-dashboard", "startup-settings-controls", "startup-settings-message"):
        if f'id="{control}"' not in combined:
            failures.append(f"Manager startup settings omit accessible control: {control}")
    if 'id="startup-settings-save"' in combined or 'submitStartupSettings' in javascript:
        failures.append("Manager startup settings still require a redundant save button")
    if 'request("/api/v1/startup")' not in javascript or 'method: "PUT"' not in javascript:
        failures.append("Manager startup settings do not read and write the typed API")
    if 'dashboardToggle.disabled = state.startupSaving || unavailable || !managerToggle.checked;' not in javascript:
        failures.append("Open Dashboard after sign-in is not visibly dependent on Manager startup")
    if 'const savedManagerEnabled = Boolean(startup.startManager);' not in javascript:
        failures.append("Manager startup badge follows unsaved form state instead of the saved setting")
    if 'label.className = "state-chip-label";' not in javascript:
        failures.append("state badges do not inherit the smooth shared text transition")
    if 'chip.replaceChildren(...(iconName ?' in javascript or 'chip.insertBefore(nextIcon, label);' not in javascript:
        failures.append("unchanged state badges are detached and replay their animation during form edits")
    if 'cacheWorkflowState === "running"' not in javascript or 'overallLabel = "Running";' not in javascript or 'overallTone = "pending";' not in javascript:
        failures.append("independent cache refresh is not presented as blue Running across setup and Verify")
    if '"Enable Cache Storage"' not in javascript or 'selectView("configuration", { section: "cache" });' not in javascript:
        failures.append("disabled cache does not expose a Config-only enable action")
    if 'cacheToggle.scrollIntoView({ block: "center", behavior: "smooth" });' not in javascript or 'cacheToggle.focus({ preventScroll: true });' not in javascript:
        failures.append("Enable Cache Storage does not smoothly navigate and focus the cache setting")
    if '.state-chip.waiting,.state-chip.warning' not in css or 'animation:state-pulse-amber' not in css:
        failures.append("Waiting and completed Warning do not share the accessible amber treatment")
    if '.health-card,.setup-workflow-steps article,.verification-result' not in css or 'background-color .22s ease' not in css or 'box-shadow .22s ease' not in css:
        failures.append("state cards do not transition text, border, background, and glow consistently")
    if '.state-chip.bad{' not in css or 'animation:state-pulse-bad' not in css or '.state-card-bad{' not in css:
        failures.append("failed cache state does not retain its red badge and card glow")
    if '.state-chip.pending{' not in css or 'animation:state-pulse-pending' not in css or '.state-card-pending{' not in css:
        failures.append("running cache state does not retain its blue badge and card glow")
    if 'Optional local recheck' not in combined or 'Validate, save, and verify runs the independent cache refresh' not in combined:
        failures.append("Verify still presents the manual deleted-item cache action as a required second step")
    if '#startup-settings-chip{animation:none}' not in css:
        failures.append("Manager startup saved-state badge inherits a looping status animation")
    if 'state.startupDraft = requested;' not in javascript or 'body: JSON.stringify(requested)' not in javascript:
        failures.append("Manager startup toggles do not retain an atomic optimistic selection while saving")
    if 'state.startupError = error.message;' not in javascript or 'state.startupDraft = null;' not in javascript:
        failures.append("Manager startup toggle failures do not restore saved state with a truthful error")
    if 'panel.setAttribute("aria-busy", String(state.startupSaving));' not in javascript:
        failures.append("Manager startup controls do not expose their brief busy state accessibly")
    if '.startup-setting{display:flex' not in css or 'cursor:pointer;transition:opacity .18s ease}' not in css:
        failures.append("Manager startup toggle availability does not transition smoothly")
    for control in (
        "integration-status-card",
        "tailscale-status-button",
        "funnel-settings-link",
        "funnel-integration-value",
        "funnel-state",
        "funnel-detail",
        "tailscale-settings-panel",
        "tailscale-settings-heading",
        "tailscale-settings-chip",
        "tailscale-enabled",
        "tailscale-host-authorization",
        "tailscale-copy-authorization",
        "tailscale-funnel-status",
        "tailscale-url",
        "tailscale-password-status",
        "tailscale-password-setup-button",
        "tailscale-refresh-button",
        "tailscale-setup-link",
        "tailscale-provider-warning",
        "tailscale-copy-button",
        "tailscale-settings-message",
    ):
        if f'id="{control}"' not in combined:
            failures.append(f"Tailscale remote access card omits accessible control: {control}")
    integration_card_start = html.find('id="integration-status-card"')
    integration_card_end = html.find("</article>", integration_card_start)
    integration_card = html[integration_card_start:integration_card_end]
    smtp_position = integration_card.find('id="smtp-state"')
    funnel_position = integration_card.find('class="funnel-integration-row"')
    if integration_card_start < 0 or integration_card_end < 0 or smtp_position < 0 or funnel_position <= smtp_position:
        failures.append("Dashboard Integrations card does not place Tailscale Funnel directly below SMTP")
    if 'id="funnel-settings-link"' not in integration_card or "data-tooltip=" not in integration_card or "title=" in integration_card:
        failures.append("Dashboard Funnel row does not use the animated tooltip contract or retains a native title")
    if 'id="access-status-button"' not in html or html.find('id="tailscale-status-button"') <= html.find('id="access-status-button"'):
        failures.append("Tailscale Funnel status badge is not placed immediately after the access lock")
    tailscale_button_start = html.find('id="tailscale-status-button"')
    tailscale_button_end = html.find("</button>", tailscale_button_start)
    tailscale_button = html[tailscale_button_start:tailscale_button_end]
    if tailscale_button_start < 0 or tailscale_button_end < 0 or 'class="tailscale-logo" viewBox="0 0 512 512"' not in tailscale_button or "cdn.jsdelivr.net" in combined:
        failures.append("Tailscale status badge is not bundled locally from the approved SVG geometry")
    if tailscale_button.count("<path") != 7 or tailscale_button.count('class="tailscale-fade"') != 4 or "<use" in tailscale_button:
        failures.append("Tailscale status badge does not retain the upstream seven-path geometry and four muted path groups")
    for marker in (
        "function funnelIntegrationPresentation(remote)",
        "function tailscaleStatusBadgePresentation(remote)",
        "function renderTailscaleStatusButton(remote = state.tailscale)",
        'setText("funnel-state", funnel.label);',
        'setText("funnel-detail", funnel.detail);',
        'funnelValue.setAttribute("aria-label"',
        'funnelLink.setAttribute("aria-label"',
        'addEventListener("click", openTailscaleSettings)',
        'selectView("about", { section: "tailscale" });',
        'byId("tailscale-settings-heading").focus',
        'renderIntegrationStatus();',
    ):
        if marker not in javascript:
            failures.append(f"Dashboard Funnel status interaction contract is missing: {marker}")
    if 'id="tailscale-settings-heading" tabindex="-1"' not in html:
        failures.append("Dashboard Funnel deep link cannot move focus to the Settings heading")
    if ".metric-link:focus-visible" not in css or ".integration-value.publication-pending span" not in css:
        failures.append("Dashboard Funnel row lacks visible focus or gold Attention styling")
    if ".metric-link:after{content:attr(data-tooltip)" not in css or ".metric-link:hover:after" not in css:
        failures.append("Dashboard Funnel row lacks its animated non-native tooltip")
    if ".metric-link{position:relative;padding:0;border:0;appearance:none" not in css:
        failures.append("Dashboard Funnel link retains a surrounding button box")
    if ".tailscale-settings-panel{scroll-margin-top:90px" not in css:
        failures.append("Dashboard Funnel deep link does not clear the sticky header at the beginning of the card")
    if (
        '.tailscale-status-button .tailscale-logo{width:21px;height:21px;display:block}' not in css
        or '.tailscale-status-button .tailscale-logo path{fill:#f0f0f0;opacity:.2' not in css
        or '.tailscale-status-button.active .tailscale-logo path:not(.tailscale-fade){opacity:1}' not in css
        or '.tailscale-status-button.active .tailscale-fade{opacity:.2}' not in css
    ):
        failures.append("Tailscale badge does not preserve the exact upstream active/default and uniform off SVG appearances")
    if '((remote.state === "active" && remote.active === true) || remote.state === "starting")' not in javascript:
        failures.append("Tailscale badge active color is not restricted to active or publication-pending state")
    expected_mode_badge = 'setText("mode-pill-label", nas ? "NAS / container" : linux ? "Native Linux" : mac ? "macOS Docker" : "Windows Manager");'
    if expected_mode_badge not in javascript:
        failures.append("Package badge does not use the Windows Manager and compact macOS Docker labels")
    if 'button.dataset.tooltip = tooltip;' not in javascript or 'button.setAttribute("aria-label", tooltip);' not in javascript:
        failures.append("Tailscale badge tooltip does not reflect its exact retained state")
    if "funnelValue.title" in javascript or "funnelLink.disabled" in javascript:
        failures.append("Dashboard Funnel row still relies on a native title or disabled-button tooltip suppression")
    if "@media(max-width:580px){.funnel-integration-row" not in css:
        failures.append("Dashboard Funnel row lacks its narrow mobile layout")
    if "prefers-reduced-motion:reduce" not in css or "forced-colors:active" not in css:
        failures.append("Dashboard Funnel row lacks reduced-motion or forced-color support")
    for marker in (
        'request("/api/v1/remote-access/tailscale")',
        'method: "PUT"',
        'JSON.stringify({ operation: state.tailscaleRequestedOperation })',
        'navigator.clipboard.writeText(state.tailscale.url)',
        'parsed.search === "" && parsed.hash === "" && parsed.hostname.endsWith(".ts.net")',
        'panel.setAttribute("aria-busy", String(state.tailscaleSaving));',
    ):
        if marker not in javascript:
            failures.append(f"Tailscale remote access interaction contract is missing: {marker}")
    for retired_marker in ('tailscale-private-confirm', 'tailscale-external-url', 'confirmedPrivate'):
        if retired_marker in combined:
            failures.append(f"retired private Serve control remains in the Funnel-only Manager: {retired_marker}")
    for marker in (
        "Funnel makes the Manager login page publicly reachable over HTTPS",
        "Remote viewers do not need Tailscale or a VPN",
        "Internet login attempts remain a brute-force risk",
        'case "manager-password-required"',
        'case "approval-required"',
        'case "starting"',
        'case "stopping"',
        'byId("access-password").focus({ preventScroll: true })',
    ):
        if marker not in combined:
            failures.append(f"Integrated Funnel disclosure or accessible state is missing: {marker}")
    for marker in (
        "Manager remains non-root and receives no credential or provider CLI",
        '"sudo tautweekly remote-access-authorize"',
        '"./tautweekly.sh remote-access-login"',
        '"/opt/tautweekly/bin/tautweekly-funnel login"',
    ):
        if marker not in combined:
            failures.append(f"Funnel adapter credential/command boundary is missing: {marker}")
    if 'remote.management' in javascript:
        failures.append("Funnel-only card still branches into the retired host-managed private architecture")
    if 'panel.classList.toggle("enabled-glow", Boolean(remote.enabled && remote.active));' not in javascript:
        failures.append("Active Tailscale state does not drive the full-card glow")
    if 'panel.classList.toggle("publication-pending-glow", Boolean(publicFunnel && remote.enabled && remote.state === "starting"));' not in javascript:
        failures.append("Publication-pending Funnel state does not drive the requested gold full-card glow")
    tailscale_renderer_start = javascript.find("function renderTailscaleSettings()")
    tailscale_renderer_end = javascript.find("\n}\n\nasync function updateTailscaleAccess", tailscale_renderer_start)
    tailscale_renderer = javascript[tailscale_renderer_start:tailscale_renderer_end]
    funnel_declaration = tailscale_renderer.find("const publicFunnel = true;")
    funnel_first_use = tailscale_renderer.find("const displayRemote = publicFunnel")
    if tailscale_renderer_start < 0 or tailscale_renderer_end < 0 or funnel_declaration < 0 or funnel_first_use < 0 or funnel_declaration > funnel_first_use:
        failures.append("Integrated Funnel renderer uses publicFunnel before its declaration")
    if ".tailscale-settings-panel.enabled-glow" not in css or "prefers-reduced-motion:reduce" not in css:
        failures.append("Active Tailscale card glow lacks its motion-safe styling contract")
    if ".state-chip.publication-pending" not in css or ".tailscale-settings-panel.publication-pending-glow" not in css or "tailscale-publication-pending-glow" not in css:
        failures.append("Publication-pending Funnel state lacks synchronized gold badge/card styling")
    if '.tailscale-settings-panel' not in css or '.tailscale-status-grid' not in css or '.tailscale-security-boundary' not in css:
        failures.append("Tailscale remote access card lacks its responsive security treatment")
    if "function materializeMaterialIcons(" not in javascript or "materializeMaterialIcons();" not in javascript:
        failures.append("local Material Symbols are not materialized for embedded-webview compatibility")
    if 'accessButton.replaceChildren(createMaterialIcon(locked ? "lock" : "lock-open"));' not in javascript:
        failures.append("access lock icon state can target a removed SVG use element")
    if 'request("/api/v1/config/status")' not in javascript:
        failures.append("configuration status is not loaded from durable Manager state")
    if 'request("/api/v1/config/status/previews/skipped"' not in javascript:
        failures.append("automatic preview skips are not retained by the Manager")
    if 'id="configuration-status-card"' not in combined or "function renderDashboardConfigStatus()" not in javascript:
        failures.append("Dashboard has no durable Config status health card")
    for step in ("choices", "lan", "smtp", "previews", "cache"):
        if f'id="configuration-status-{step}"' not in combined:
            failures.append(f"Dashboard Config status omits step: {step}")
        if f'id="setup-{step}-step"' not in combined:
            failures.append(f"Config setup workflow omits permanent step card: {step}")
    for symbol in ("dashboard", "tune", "calendar-clock", "verified", "preview", "settings", "lock", "lock-open", "deployed-code-update", "visibility"):
        if f'id="icon-{symbol}"' not in combined:
            failures.append(f"local Material Symbol missing: {symbol}")
    if "function initializeMaskedInputToggles(" not in javascript or "initializeMaskedInputToggles();" not in javascript:
        failures.append("static masked typing fields do not receive show/hide controls")
    if "function concealMaskedInputs(" not in javascript or ".masked-input-shell" not in css:
        failures.append("masked typing fields do not share concealment and layout behavior")
    if "function renewTrustedLocalSession(" not in javascript or "return await request(path, options, false);" not in javascript:
        failures.append("trusted-local sessions do not recover once after a Manager restart")
    if "function reloadAfterTrustedLocalRestart(" not in javascript or "window.location.reload();" not in javascript:
        failures.append("trusted-local restart races do not recover without a manual refresh")
    if "const authBootstrapEndpoint =" not in javascript or 'path.startsWith("/api/v1/auth/")' in javascript:
        failures.append("protected access-policy requests are incorrectly excluded from session recovery")
    if 'id="manual-send-runner-heading"' not in combined or 'id="manual-send-status"' not in combined:
        failures.append("Preview center has no guarded production delivery and retained status cards")
    for control in (
        "update-settings-panel",
        "update-status-button",
        "update-settings-chip",
        "update-manager-version",
        "update-latest-version",
        "update-platform",
        "update-edition",
        "update-release-alignment",
        "update-host-adapter-row",
        "update-host-adapter",
        "update-channel",
        "update-last-success",
        "update-check-button",
        "update-guidance-summary",
        "update-copy-command",
        "update-install-confirm",
        "update-install-button",
        "update-settings-message",
    ):
        if f'id="{control}"' not in combined:
            failures.append(f"Settings update card omits accessible control: {control}")
    if 'class="build-details"' in combined or 'id="update-application-version"' in combined or 'id="update-package-version"' in combined:
        failures.append("Manager and package identity is still duplicated outside the consolidated update status surface")
    if "function releaseAlignmentSummary(" not in javascript or 'matching.length === 1 ? "matches" : "match"' not in javascript:
        failures.append("application and package release alignment is not summarized without duplicate version values")
    update_surfaces = (
        ("Manager", html, javascript, css),
        (
            "GUI preview",
            Path("docs/gui-preview/index.html").read_text(encoding="utf-8"),
            Path("docs/gui-preview/app.js").read_text(encoding="utf-8"),
            Path("docs/gui-preview/app.css").read_text(encoding="utf-8"),
        ),
    )
    expected_update_labels = (
        "Manager build",
        "Latest stable",
        "Platform",
        "Edition",
        "Release alignment",
        "Host adapter",
        "Update channel",
        "Last successful check",
    )
    for surface, surface_html, surface_javascript, surface_css in update_surfaces:
        grid_start = surface_html.find('<dl class="update-version-grid host-adapter-hidden">')
        grid_end = surface_html.find("</dl>", grid_start)
        grid_html = surface_html[grid_start:grid_end] if grid_start >= 0 and grid_end >= 0 else ""
        label_positions = [grid_html.find(f"<dt>{label}</dt>") for label in expected_update_labels]
        if not grid_html or any(position < 0 for position in label_positions) or label_positions != sorted(label_positions):
            failures.append(f"{surface} update fields do not use the approved visible order")
        if "Package baseline" in surface_html or "update-package-baseline" in surface_html + surface_javascript:
            failures.append(f"{surface} still exposes the deprecated Package baseline field")
        if "Release layers" in surface_html or "update-release-layers" in surface_html + surface_javascript:
            failures.append(f"{surface} still exposes the replaced Release layers label or ID")
        if 'id="update-host-adapter-row" hidden' not in grid_html:
            failures.append(f"{surface} host adapter is visible before applicability is known")
        for marker in (
            'Boolean(update.hostAdapterState) && update.hostAdapterState !== "not-applicable"',
            "hostAdapterRow.hidden = !hostAdapterApplicable;",
            'classList.toggle("host-adapter-hidden", !hostAdapterApplicable)',
            'if (hostAdapterApplicable) {',
        ):
            if marker not in surface_javascript:
                failures.append(f"{surface} host-adapter visibility contract is missing: {marker}")
        for marker in (
            ".update-version-grid.host-adapter-hidden>div:last-child{grid-column:span 2}",
            ".update-version-grid.host-adapter-hidden>div:last-child{grid-column:1/-1}",
            ".update-version-grid.host-adapter-hidden>div:last-child{grid-column:auto}",
        ):
            if marker not in surface_css:
                failures.append(f"{surface} conditional update grid reflow is missing: {marker}")
    for marker in (
        'request("/api/v1/updates")',
        'request("/api/v1/updates/check", { method: "POST", body: "{}" })',
        'request("/api/v1/updates/install", { method: "POST", body: "{}" })',
        'navigator.clipboard.writeText(command)',
        '!byId("update-install-confirm").checked',
    ):
        if marker not in javascript:
            failures.append(f"Settings update interaction contract is missing: {marker}")
    if "function pollUpdateInstall()" not in javascript or "updateInstallPollTimer = setTimeout(pollUpdateInstall" not in javascript:
        failures.append("verified update installation has no automatic status transition")
    if 'id="update-status-button"' not in combined or 'aria-controls="update-settings-panel"' not in combined:
        failures.append("header update notification does not expose its Settings target")
    if 'id="update-settings-heading" tabindex="-1"' not in combined or 'byId("update-settings-heading").focus' not in javascript:
        failures.append("header update notification does not move focus to the status heading")
    if 'addEventListener("click", openUpdateSettings)' not in javascript or 'selectView("about", { section: "updates" });' not in javascript:
        failures.append("header update notification does not route to the consolidated status section")
    if 'addEventListener("popstate", applyLocationRoute)' not in javascript or 'addEventListener("hashchange", applyLocationRoute)' not in javascript:
        failures.append("Manager update route does not preserve browser back and forward navigation")
    if "function checkForUpdatesInBackground()" not in javascript or "backgroundUpdateCheckAttempted" in javascript:
        failures.append("background checks retain a session-wide suppression flag")
    if 'state.updateChecking || !state.updates?.backgroundCheckRecommended' not in javascript or 'void runUpdateCheck(true);' not in javascript:
        failures.append("background update refresh is not gated by server cache freshness and backoff")
    header_refresh_markers = (
        'if (applicationRefreshPromise) return applicationRefreshPromise;',
        'const refreshWork = (async () => {\n    await loadAll();',
        'recoverPendingPreviews: false,',
        'if (updateCheckIsAvailable()) refreshes.push(checkForUpdates());',
        'await Promise.allSettled(refreshes);',
        'scheduleUpdateCheckAvailabilityRefresh(cooldown);',
        'clearUpdateCheckAvailabilityTimer();',
        'if (refreshed && recoverPendingPreviews) await recoverPendingPreviewsFromChoices(discoveryAuthenticationEpoch);',
        'state.discoveryError = discoveryFailureMessage(error.message);',
        'authenticationEpoch += 1;',
        'const loadAuthenticationEpoch = authenticationEpoch;',
        'const discoveryAuthenticationEpoch = authenticationEpoch;',
        'applicationRefreshPromise = null;',
        'byId("refresh-button").disabled = false;',
        'state.discoveryRunning = false;',
        'if (updateAuthenticationEpoch === authenticationEpoch && !byId("app-shell").hidden) {',
        'cooldown.delayMilliseconds + 1000',
        'byId("refresh-button").addEventListener("click", refreshApplicationStatus)',
    )
    if any(marker not in javascript for marker in header_refresh_markers):
        failures.append("header Refresh does not serialize isolated local-first discovery/update work with dedicated-only preview recovery and safe cooldown/auth cleanup")
    if 'id="refresh-button" type="button" aria-label="Refresh Manager, Tautulli choices, and update status"' not in html:
        failures.append("header Refresh accessible name omits its Tautulli or update side effect")
    preview_html = Path("docs/gui-preview/index.html").read_text(encoding="utf-8")
    if 'id="refresh-button" type="button" aria-label="Refresh synthetic Manager, Tautulli choices, and update status"' not in preview_html:
        failures.append("GUI preview Refresh accessible name diverges from combined production behavior")
    if "No connection is attempted on page load or passive dashboard rendering." not in html or "it does not run this direct-Plex verification." not in html:
        failures.append("Manager connection-boundary copy still claims Header Refresh performs no network work")
    if 'Update available — Version' in args.html.read_text(encoding="utf-8"):
        failures.append("static header markup exposes a stale update version before validated state is rendered")
    if ".update-status-button" not in css or "color:var(--blue)" not in css or "rgba(114,174,247,.44)" not in css or "animation:hero-pulse" not in css:
        failures.append("header update notification does not reuse the Manager blue badge and established halo pulse")
    if 'case "update-available": return { label: "Update available", tone: "update-available"' not in javascript or ".state-chip.update-available" not in css or "animation:state-pulse-update" not in css:
        failures.append("update-available status chip does not use the dedicated violet pulse")
    if "forced-colors:active" not in css or ".update-status-halo{animation:none!important" not in css:
        failures.append("header update notification does not preserve forced-colors and reduced-motion behavior")
    if ".topbar .brand-lockup>div{display:none}" not in css:
        failures.append("narrow mobile header does not preserve space for lock and update controls")
    if '.update-settings-panel' not in css or '.update-command' not in css or '.update-install-confirm' not in css:
        failures.append("Settings update card lacks its responsive and accessible visual treatment")
    if 'const toggle = document.createElement("label");' not in javascript or "toggle.htmlFor = id;" not in javascript:
        failures.append("generated boolean switches do not associate their full visible surface with the checkbox")
    if ".config-control-boolean .config-toggle{width:max-content;cursor:pointer" not in css:
        failures.append("generated boolean switches do not expose a full clickable pointer surface")
    if 'value="send-all"' not in combined or 'value="send-welcome"' not in combined:
        failures.append("manual production delivery does not expose both all-recipient and Manual Welcome scopes")
    if 'type === "send-welcome"' not in javascript or "confirmProductionSend: true" not in javascript:
        failures.append("manual production delivery does not use the fixed confirmed operation contracts")
    if javascript.count("smtpFailureEvidenceCopy(operation.smtpFailure)") < 4:
        failures.append("test, welcome, partial, and failed delivery summaries do not all expose sanitized SMTP evidence")
    if 'id="manual-send-user-id"' not in combined or 'state.history.find((candidate) => manualTypes.has(candidate.type))' not in javascript:
        failures.append("Manual Welcome lacks selected-user input or shared sanitized status")
    if 'id="direct-plex-notice"' not in combined or "legacyFieldsMissing" not in javascript:
        failures.append("legacy direct Plex omissions have no guided completion message")
    for marker in (
        'method: "DELETE"',
        'setSwappingButtonElementText(deleteButton, "Confirm delete")',
        'Permanently delete configuration backup from',
        'Deletion is manual, confirmed, and permanent.',
    ):
        if marker not in combined:
            failures.append(f"configuration backup deletion contract is missing: {marker}")
    if "legacyRuleExcluded" not in javascript or "Excluded by existing config" not in javascript:
        failures.append("legacy email exclusions are not represented in guided delivery choices")
    if 'status.className = changed ? "discovery-selected-count" : "discovery-excluded-count"' not in javascript or "rgba(255,122,114,.48)" not in css:
        failures.append("guided delivery choices do not show the requested effective exclusion count")
    if 'status.textContent = `${effective} excluded${changed ? " (unsaved)" : ""}`' not in javascript or ".discovery-selected-count{color:var(--gold-bright)" not in css:
        failures.append("guided delivery choices do not distinguish unsaved selections from saved exclusions")
    if "const orderedUsers = [...users].sort" not in javascript or "leftExcluded ? -1 : 1" not in javascript:
        failures.append("configured delivery exclusions are not grouped visibly at the top of discovered users")
    if ".user-combobox>input" not in css or ".manual-send-mode-field select{border-color:var(--line-strong)" not in css:
        failures.append("guided user and delivery-mode selectors do not share consistent control styling")
    for marker in (
        'id="managed-user-delivery-addresses"',
        'aria-labelledby="managed-user-delivery-heading"',
        'id="managed-user-delivery-list" role="list"',
        'Native Tautulli email always wins, exclusions still apply, and multiple profiles may use the same inbox.',
    ):
        if marker not in html:
            failures.append(f"managed-user delivery-address card is missing: {marker}")
    for marker in (
        'user.needsDeliveryAddress === true',
        'input.type = "email";',
        'input.maxLength = 254;',
        'input.setAttribute("aria-describedby", status.id);',
        'input.setAttribute("aria-invalid", String(!valid));',
    ):
        if marker not in javascript:
            failures.append(f"managed-user delivery-address control is missing: {marker}")
    if ".managed-user-delivery-row" not in css or "@media(max-width:800px){.managed-user-delivery-row{grid-template-columns:1fr}" not in css:
        failures.append("managed-user delivery-address card lacks responsive styling")
    if 'input.addEventListener("click"' not in javascript or 'if (open) input.focus();' not in javascript:
        failures.append("guided user selectors do not open from the full input field for typing or mouse selection")
    if 'card.hidden = !manualSend;' not in javascript:
        failures.append("manual production status is visible before a manual send exists")
    if 'card.hidden = manualSend;' not in javascript:
        failures.append("manual production delivery is duplicated in the generic current-run card")
    for label in ("Index", "Manual Welcome", "New User - No History", "New User - With History", "Normal Newsletter", "Established Quiet", "Established Warnings"):
        if label not in javascript:
            failures.append(f"preview scenario label is missing: {label}")
    if "function orderedPreviews(" not in javascript or "previewScenarioIndex(left) - previewScenarioIndex(right)" not in javascript:
        failures.append("available previews are not rendered in deterministic scenario order")
    if "function initializePreviewIndexNavigation()" not in javascript or 'link.addEventListener("click"' not in javascript:
        failures.append("preview index links do not select their scenario in the existing authenticated viewer")

    if failures:
        for failure in sorted(set(failures)):
            print(f"[FAIL] {failure}")
        return 1
    print(f"[PASS] Manager accessibility structure: {len(ids)} unique IDs, {len(controls)} static controls, local assets only.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
