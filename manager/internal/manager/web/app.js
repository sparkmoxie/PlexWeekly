"use strict";

const state = {
  csrfToken: "",
  status: null,
  config: null,
  editor: null,
  backups: [],
  backupMaximum: 10,
  verification: { last: null, smtp: null },
  verificationRunning: false,
  smtpVerificationRunning: false,
  cacheVerificationRunning: false,
  cache: null,
  discovery: null,
  discoveryError: "",
  discoveryRunning: false,
  setupWorkflow: null,
  setupWorkflowRunning: false,
  previews: [],
  selectedPreviewID: "",
  operation: null,
  history: [],
  historyMaximum: 20,
  operationStarting: false,
  operationStartingType: "",
  operationCancelling: false,
  scheduleOperation: null,
  schedulePendingAction: "",
  scheduleStarting: false,
  startup: null,
  startupDraft: null,
  startupSaving: false,
  startupError: "",
  authAccess: null,
  tailscale: null,
  tailscaleSaving: false,
  tailscaleVerifying: false,
  tailscaleRequestedOperation: "",
  tailscaleError: "",
  tailscaleSetupURL: "",
  about: null,
  diagnostics: { events: [], maximumEntries: 20, retentionPolicy: "count-only-fifo" },
  capabilities: null,
  updates: null,
  updateChecking: false,
  updateCheckBackground: false,
  updateInstalling: false,
  runtimeMode: "windows",
};
const byId = (id) => document.getElementById(id);
const titleCase = (value) => String(value || "unknown").replaceAll("-", " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
const guidedConfigFields = new Set(["IncludedLibraryIds", "ExcludedUserIds", "UserEmailOverrides"]);
const noTitleGifChoice = Object.freeze({ id: "none", label: "None", file: "" });
const titleGifChoices = Object.freeze([
  { id: "celebrate", label: "Celebrate", file: "celebrate.gif" },
  { id: "construction", label: "Construction", file: "construction.gif" },
  { id: "rocket", label: "Rocket", file: "rocket.gif" },
  { id: "tickets", label: "Tickets", file: "tickets.gif" },
  { id: "warning", label: "Warning", file: "warning.gif" },
  { id: "alert", label: "Alert", file: "alert.gif" },
]);
const activeSecretReveals = new Map();
let pendingSecretReveal = null;
let sessionRecoveryPromise = null;
let applicationRefreshPromise = null;
let authenticationEpoch = 0;
let updateInstallPollTimer;
let updateCheckAvailabilityTimer;
let deliveryStatusPollTimer;
let deliveryStatusPollInFlight = false;
let updateInstallExpectedVersion = "";
let updateInstallSawDisconnect = false;
let updateInstallPollDeadline = 0;
let lastRoutedURL = "";

function materializeMaterialIcon(svg) {
  const use = svg?.querySelector("use");
  const href = use?.getAttribute("href") || "";
  const symbol = href.startsWith("#") ? byId(href.slice(1)) : null;
  if (!symbol) return svg;
  const viewBox = symbol.getAttribute("viewBox");
  if (viewBox) svg.setAttribute("viewBox", viewBox);
  svg.replaceChildren(...Array.from(symbol.children, (child) => child.cloneNode(true)));
  return svg;
}

function materializeMaterialIcons(root = document) {
  root.querySelectorAll("svg.ui-icon").forEach(materializeMaterialIcon);
}

function maskedInputLabel(input) {
  const label = input.labels?.[0];
  const strongLabel = label?.querySelector(":scope > strong")?.textContent?.trim();
  if (strongLabel) return strongLabel;
  const directLabel = Array.from(label?.childNodes || []).find((node) => node.nodeType === Node.TEXT_NODE && node.textContent.trim());
  if (directLabel) return directLabel.textContent.trim();
  return input.getAttribute("aria-label") || input.name || "value";
}

function updateMaskedInputToggle(input, button) {
  const visible = input.type === "text";
  const label = maskedInputLabel(input);
  button.classList.toggle("visible", visible);
  button.setAttribute("aria-pressed", String(visible));
  button.setAttribute("aria-label", `${visible ? "Hide" : "Show"} ${label}`);
  button.title = `${visible ? "Hide" : "Show"} ${label}`;
}

function initializeMaskedInputToggles(root = document) {
  root.querySelectorAll('input[type="password"]').forEach((input) => {
    if (input.closest(".secret-input-shell") || input.closest(".masked-input-shell")) return;
    const shell = document.createElement("span");
    shell.className = "masked-input-shell";
    input.before(shell);
    shell.append(input);
    const button = document.createElement("button");
    button.type = "button";
    button.className = "secret-toggle-button";
    button.setAttribute("aria-controls", input.id);
    button.append(createMaterialIcon("visibility"));
    button.addEventListener("click", () => {
      input.type = input.type === "password" ? "text" : "password";
      updateMaskedInputToggle(input, button);
      input.focus({ preventScroll: true });
    });
    shell.append(button);
    updateMaskedInputToggle(input, button);
  });
}

function concealMaskedInputs(root = document) {
  root.querySelectorAll(".masked-input-shell>input").forEach((input) => {
    input.type = "password";
    const button = input.nextElementSibling;
    if (button?.classList.contains("secret-toggle-button")) updateMaskedInputToggle(input, button);
  });
}

async function performRequest(path, options = {}) {
  const method = options.method || "GET";
  const headers = new Headers(options.headers || {});
  if (options.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  if (method !== "GET" && method !== "HEAD" && state.csrfToken) headers.set("X-CSRF-Token", state.csrfToken);
  const response = await fetch(path, { ...options, method, headers, credentials: "same-origin" });
  const contentType = response.headers.get("Content-Type") || "";
  const payload = contentType.includes("application/json") ? await response.json() : null;
  if (!response.ok) {
    const code = payload?.error?.code || "request-failed";
    const error = new Error(sanitizedRequestErrorMessage(code, payload?.error?.message, response.status));
    error.status = response.status;
    error.code = code;
    error.fields = payload?.error?.fields || {};
    throw error;
  }
  return payload;
}

function sanitizedRequestErrorMessage(code, fallback, status) {
  const fixed = {
    "invalid-origin": "The browser sent a malformed origin. Open the Manager from its exact configured address and try again.",
    "origin-host-mismatch": "The browser origin does not match the Host received by this Manager. Reopen the exact loopback recovery URL or independently verified Funnel address, then retry. No configuration was saved.",
    "origin-scheme-mismatch": "The browser origin uses the wrong HTTP or HTTPS scheme. Reopen the exact configured Manager URL and try again.",
    "remote-http": "Remote Manager changes require HTTPS. Use the independently verified Funnel address and try again.",
  };
  if (fixed[code]) return `${fixed[code]} (${code})`;
  return fallback || `Request failed (${status}).`;
}

async function renewTrustedLocalSession() {
  const session = await performRequest("/api/v1/auth/session");
  state.csrfToken = session.csrfToken || "";
  return session;
}

async function reloadAfterTrustedLocalRestart() {
  try {
    const setup = await performRequest("/api/v1/setup");
    if (!setup?.authenticationRequired) {
      window.location.reload();
      return true;
    }
  } catch (_) {
    // Preserve the original authentication error when setup cannot be read.
  }
  return false;
}

async function request(path, options = {}, allowSessionRecovery = true) {
  try {
    return await performRequest(path, options);
  } catch (error) {
    const authBootstrapEndpoint = ["/api/v1/auth/session", "/api/v1/auth/login", "/api/v1/auth/pair", "/api/v1/auth/logout"].includes(path);
    if (error.status !== 401 || !allowSessionRecovery || authBootstrapEndpoint) throw error;
    if (!sessionRecoveryPromise) {
      sessionRecoveryPromise = renewTrustedLocalSession().finally(() => {
        sessionRecoveryPromise = null;
      });
    }
    try {
      await sessionRecoveryPromise;
      return await request(path, options, false);
    } catch (recoveryError) {
      if (recoveryError.status === 401 && await reloadAfterTrustedLocalRestart()) {
        const restoring = new Error("Manager restarted; restoring the trusted-local session.");
        restoring.code = "session-restoring";
        restoring.status = 0;
        throw restoring;
      }
      state.csrfToken = "";
      showAuthentication();
      throw recoveryError;
    }
  }
}

function pairingTokenFromFragment() {
  const params = new URLSearchParams(window.location.hash.slice(1));
  const token = params.get("pair") || "";
  if (token) history.replaceState(null, "", window.location.pathname + window.location.search);
  return token;
}

async function initialize() {
  const setup = await request("/api/v1/setup");
  state.runtimeMode = setup.runtimeMode || "windows";
  renderAuthenticationBoundary();
  try {
    const session = await request("/api/v1/auth/session");
    state.csrfToken = session.csrfToken;
    await enterApplication();
    return;
  } catch (error) {
    if (error.status !== 401) setAuthMessage(error.message);
  }
  byId("auth-shell").hidden = false;
  if (setup.pairingRequired) {
    byId("pair-form").hidden = false;
    const token = pairingTokenFromFragment();
    byId("pair-token").value = token;
    (token ? byId("pair-password") : byId("pair-token")).focus();
  } else {
    byId("login-form").hidden = false;
    byId("login-password").focus();
  }
}

async function enterApplication(preferredView = "") {
  byId("auth-shell").hidden = true;
  byId("app-shell").hidden = false;
  const localStatusLoaded = await loadAll();
  const route = preferredView ? { view: preferredView, section: "" } : window.TautWeeklyUpdateUI.routeFromHash(window.location.hash);
  lastRoutedURL = window.location.href;
  selectView(route.view, { section: route.section, updateHistory: false });
  if (localStatusLoaded) checkForUpdatesInBackground();
}

async function loadAll() {
  const loadAuthenticationEpoch = authenticationEpoch;
  setGlobalStatus("Refreshing local status…");
  try {
    const [status, config, editor, configurationStatus, backups, verification, discovery, previews, operation, history, scheduleOperation, startup, authAccess, about, diagnostics, capabilities, updates] = await Promise.all([
      request("/api/v1/status"),
      request("/api/v1/config"),
      request("/api/v1/config/editor"),
      request("/api/v1/config/status"),
      request("/api/v1/config/backups"),
      request("/api/v1/checks/integrations"),
      request("/api/v1/discovery/tautulli"),
      request("/api/v1/previews"),
      request("/api/v1/operations/current"),
      request("/api/v1/history"),
      request("/api/v1/schedule/operation"),
      request("/api/v1/startup"),
      request("/api/v1/auth/access"),
      request("/api/v1/about"),
      request("/api/v1/diagnostics"),
      request("/api/v1/capabilities"),
      request("/api/v1/updates"),
    ]);
    if (loadAuthenticationEpoch !== authenticationEpoch || byId("app-shell").hidden) return false;
    state.status = status;
    state.config = config;
    state.editor = editor;
    state.setupWorkflow = configurationStatus?.available ? configurationStatus : null;
    state.cache = configurationStatus?.cache || null;
    state.backupMaximum = Number(backups.maximumEntries) || 10;
    state.backups = (backups.backups || []).slice(0, state.backupMaximum);
    state.verification = verification || { last: null, smtp: null };
    state.discovery = discovery.last || null;
    state.previews = previews.previews || [];
    state.operation = operation.current || null;
    state.historyMaximum = Number(history.maximumEntries) || 20;
    state.history = (history.operations || []).slice(0, state.historyMaximum);
    state.scheduleOperation = scheduleOperation.current || null;
    state.startup = startup;
    state.startupDraft = null;
    state.startupError = "";
    state.authAccess = authAccess;
    state.about = about;
    const diagnosticMaximum = Number(diagnostics.maximumEntries) || 20;
    state.diagnostics = { ...diagnostics, maximumEntries: diagnosticMaximum, events: (diagnostics.events || []).slice(0, diagnosticMaximum) };
    state.capabilities = capabilities;
    state.updates = updates;
    state.runtimeMode = capabilities.runtimeMode || state.runtimeMode;
    renderCapabilities();
    renderStatus();
    renderFirstTimeSetup();
    renderConfigEditor();
    renderSetupWorkflow();
    renderBackups();
    renderVerification();
    renderPreviews();
    renderOperations();
    renderSchedule();
    renderStartupSettings();
    renderAccessSettings();
    renderTailscaleSettings();
    renderUpdates();
    renderAbout();
    manageOperationPolling();
    manageSchedulePolling();
    setGlobalStatus("Local status refreshed.", true);
    void loadTailscaleAccess();
    void recoverPendingCacheWarm();
    return true;
  } catch (error) {
    if (loadAuthenticationEpoch !== authenticationEpoch || byId("app-shell").hidden) return false;
    if (error.status === 401) {
      showAuthentication();
      return false;
    }
    setGlobalStatus(error.message, true);
    return false;
  }
}

function updateCheckIsAvailable(update = state.updates || {}) {
  const cooldown = window.TautWeeklyUpdateUI.updateCheckCooldown(update);
  return !state.updateChecking && !update.checkInProgress && !cooldown.active;
}

async function refreshApplicationStatus() {
  if (applicationRefreshPromise) return applicationRefreshPromise;
  const refreshAuthenticationEpoch = authenticationEpoch;
  const refreshButton = byId("refresh-button");
  refreshButton.disabled = true;
  const refreshWork = (async () => {
    await loadAll();
    if (refreshAuthenticationEpoch !== authenticationEpoch || byId("app-shell").hidden) return;
    const refreshes = [];
    if (state.editor?.state === "ready") {
      refreshes.push(runTautulliDiscovery({
        requireConfirmation: false,
        announceGlobalStatus: false,
        recoverPendingPreviews: false,
      }));
    }
    if (updateCheckIsAvailable()) refreshes.push(checkForUpdates());
    await Promise.allSettled(refreshes);
  })();
  applicationRefreshPromise = refreshWork;
  try {
    return await refreshWork;
  } finally {
    if (applicationRefreshPromise === refreshWork) applicationRefreshPromise = null;
    if (refreshAuthenticationEpoch === authenticationEpoch && !byId("app-shell").hidden) refreshButton.disabled = false;
  }
}

function runtimeMode() {
  return state.capabilities?.runtimeMode || state.runtimeMode;
}

function isNAS() {
  return runtimeMode() === "nas";
}

function isLinuxService() {
  return runtimeMode() === "linux";
}

function isMacDocker() {
  return runtimeMode() === "mac";
}

function isServiceRuntime() {
  return isNAS() || isLinuxService() || isMacDocker();
}

function embeddedRuntimeLabel() {
  return isLinuxService() ? "Linux service" : isMacDocker() ? "Mac container" : "container";
}

function configFieldIsHidden(field) {
  return field.type === "asset-id" || guidedConfigFields.has(field.name) || (isServiceRuntime() && field.name === "ScheduledTaskName");
}

function renderAuthenticationBoundary() {
  const boundary = document.querySelector(".auth-boundary p");
  const resetHint = document.querySelector("#login-form .field-hint");
  if (isServiceRuntime()) {
    const linux = isLinuxService();
    const mac = isMacDocker();
    setText("auth-runtime-eyebrow", linux ? "Private Linux administration" : mac ? "Private macOS administration" : "Private NAS administration");
    setText("auth-runtime-copy", "Review health, embedded scheduling, persistent configuration, and authenticated previews without exposing TautWeekly to a cloud service.");
    boundary.innerHTML = linux
      ? "<strong>Loopback by design.</strong> This authenticated Manager listens on the Linux host loopback interface. Use an SSH tunnel for recovery or the independently verified Funnel URL for public access. It makes no analytics or cloud-management requests."
      : mac
        ? "<strong>Loopback by design.</strong> Docker Desktop publishes this authenticated Manager only to the Mac loopback interface. Optional public access uses the independently verified Funnel URL. It makes no analytics or cloud-management requests."
        : "<strong>Loopback by design.</strong> This authenticated Manager uses the package's loopback recovery mapping. Use an SSH local forward for recovery or the independently verified Funnel URL for public access. It makes no analytics or cloud-management requests.";
    resetHint.innerHTML = linux
      ? "Forgot the password? Run <strong>sudo tautweekly manager-reset-access</strong> on the Linux host. Newsletter configuration and schedules are preserved."
      : mac
        ? "Forgot the password? Run <strong>./tautweekly.sh manager-reset-access</strong> in the Mac package directory. Newsletter configuration and schedules are preserved."
        : "Forgot the password? Run the packaged <strong>manager-reset-access</strong> host command or the documented container Console recovery. Newsletter configuration and schedules are preserved.";
    document.querySelector("#pair-form .form-heading p").textContent = linux
      ? "Retrieve the one-time token with sudo tautweekly manager-bootstrap, then create the administrator password. The token is returned only to that explicit terminal command and is never written to service logs."
      : mac
        ? "Retrieve the one-time token with ./tautweekly.sh manager-bootstrap in the Mac package directory, then create the administrator password. The token is never written to Docker logs."
        : "Retrieve the one-time token with the packaged host or container Console command, then create the administrator password. The token is never written to container logs.";
  } else {
    setText("auth-runtime-eyebrow", "Private local administration");
    setText("auth-runtime-copy", "Review health, schedule state, configuration, and generated previews without exposing TautWeekly to a cloud service.");
  }
}

function renderCapabilities() {
  renderAuthenticationBoundary();
  const nas = isNAS();
  const linux = isLinuxService();
  const mac = isMacDocker();
  const service = isServiceRuntime();
  setText("mode-pill-label", nas ? "NAS / container" : linux ? "Native Linux" : mac ? "macOS Docker" : "Windows Manager");
  setText("schedule-nav-copy", service ? "Embedded scheduler" : "Windows lifecycle");
  setText("configuration-platform-label", nas ? "Guided NAS setup" : linux ? "Guided Linux setup" : mac ? "Guided Mac setup" : "Guided Windows setup");
  setText("config-nav-copy", nas ? "Guided NAS setup" : linux ? "Guided Linux setup" : mac ? "Guided Mac setup" : "Guided local setup");
  setText("sidebar-connection-label", service ? "Manager connection" : "Local connection");
  setText("upcoming-run-label", service ? "Upcoming scheduler run" : "Upcoming task run");
  setText("schedule-state-label", service ? "Scheduler state" : "Task state");
  setText("schedule-lifecycle-copy", service
    ? "Disabling future starts never cancels a newsletter delivery that is already running."
    : "Disabling or removing a schedule never cancels a newsletter process that is already running.");
  setText("settings-page-heading", "Local access and truthful updates.");
  setText("settings-platform-copy", nas
    ? "This container requires an administrator password and keeps its recovery mapping on host loopback. Settings reports update and Funnel status; runtime lifecycle and installation remain under your NAS or container host."
    : linux
      ? "This systemd service requires an administrator password and listens on host loopback by default. Settings reports update status; installation remains an explicit, checksum-verified Linux package operation."
    : mac
      ? "This Docker Desktop service requires an administrator password and publishes only to Mac loopback by default. Settings reports update status; installation remains an explicit, checksum-verified Mac package operation."
    : "Windows trusts this computer by default. Settings reports update status and can start only the existing verified updater; add a password lock when the extra access boundary is useful.");
  setText("about-access-heading", "Loopback recovery and optional Funnel");
  setText("about-access-copy", nas
    ? "The Manager requires authentication and the package maps it only to host loopback. Use an SSH local forward for recovery or the independently verified Funnel URL for public access."
    : linux
      ? "The Manager requires authentication and listens on 127.0.0.1. Use an SSH tunnel for recovery or the independently verified Funnel URL for public access."
    : mac
      ? "Docker Desktop publishes the Manager only on 127.0.0.1. Optional public access uses the independently verified Funnel URL."
    : "The Manager accepts browser connections only from this computer and rejects unrecognized hostnames.");
  setText("update-edition", nas ? "NAS / Container Manager" : linux ? "Native Linux Manager" : mac ? "macOS Docker Desktop Manager" : "Windows Manager");
  setText("about-secret-copy", service
    ? "Secrets stay hidden during normal reads. Revealing returns only the selected credential, requires administrator password re-authentication, and automatically clears from the page."
    : "Secrets stay hidden during normal reads. Revealing returns only the selected credential, uses password re-authentication when the optional lock is enabled, and automatically clears from the page.");
  setText("about-delivery-copy", service
    ? "Renderer completion, SMTP acceptance, and inbox delivery remain distinct states in both API copy and interface labels."
    : "Task execution, SMTP acceptance, and inbox delivery remain distinct states in both API copy and interface labels.");
  setText("about-lifecycle-copy", nas
    ? "For packaged Compose or QNAP installs, run ./tautweekly.sh check-update and ./tautweekly.sh update. The host verifies the stable release package and its internal manifest, refreshes release-owned Compose and wrapper files, preserves .env and /data, then health-checks the image with automatic package-and-image rollback. Unraid retains its Apps-owned update flow."
    : linux
      ? "Run tautweekly check-update, back up private data, then run sudo tautweekly update. The host downloads and verifies the stable Linux archive plus its internal file manifest, backs up /opt, preserves /var/lib/tautweekly, and restores a previously active systemd service."
    : mac
      ? "Back up the package data directory, then run ./tautweekly.sh update. The host downloads and verifies the stable Mac archive plus its internal file manifest, preserves .env and data, verifies container health and version, and restores prior package files and the prior local image on rollback."
    : "Use the signed-in Windows installer workflow for verified update, migration, rollback, and removal while private Manager and newsletter data remain outside the replaceable application directory.");
  setText("preview-runner-copy", nas
    ? "Uses the saved configuration and Tautulli user ID to create local HTML in the persistent output volume. This action contacts the configured services, but does not contact SMTP, send email, or change welcome state."
    : linux
      ? "Uses the saved configuration and Tautulli user ID to create local HTML under the protected Linux data directory. This action contacts the configured services, but does not contact SMTP, send email, or change welcome state."
    : mac
      ? "Uses the saved configuration and Tautulli user ID to create local HTML under the package's persistent Mac data directory. This action contacts the configured services, but does not contact SMTP, send email, or change welcome state."
    : "Uses the saved configuration and Tautulli user ID to create local HTML in the package output folder. This action contacts the configured services, but does not contact SMTP, send email, or change welcome state.");
  setText("access-settings-eyebrow", service ? "Required Manager authentication" : "Optional Manager lock");
  setText("access-settings-heading", service ? "Administrator password" : "Browser access");
  byId("access-recovery-copy").innerHTML = nas
    ? "<strong>Console recovery remains available.</strong> Run the packaged <code>manager-reset-access</code> command from the trusted NAS host or the documented container Console command. Recovery resets only Manager credentials and sessions; configuration, schedules, history, output, and newsletter state are preserved."
    : linux
      ? "<strong>Host recovery remains available.</strong> Run <code>sudo tautweekly manager-reset-access</code>. Recovery stops and restarts only the systemd control service, resets Manager credentials and sessions, and preserves configuration, schedules, history, output, and newsletter state."
    : mac
      ? "<strong>Mac package recovery remains available.</strong> Run <code>./tautweekly.sh manager-reset-access</code> in the extracted package directory. Recovery resets only Manager credentials and sessions, restarts the Docker Desktop service, and preserves configuration, schedules, history, output, and newsletter state."
    : "<strong>Local recovery remains available.</strong> If the password is forgotten, run <code>18-RESET-MANAGER-ACCESS.bat</code> from the TautWeekly folder. Installed copies also include <code>Reset-TautWeekly-Access.cmd</code>. Recovery disables only the Manager lock and leaves configuration, credentials, schedules, history, and previews untouched.";
  setText("foundation-schedule-copy", service
    ? `A successful configuration save reruns only the discovery, non-sending checks, or previews affected by that card. Email delivery remains explicit, and schedule controls update only the embedded ${embeddedRuntimeLabel()} scheduler; they never stop a delivery already running.`
    : "A successful configuration save reruns only the discovery, non-sending checks, or previews affected by that card. Email delivery remains limited to an explicit TestEmail action, and schedule changes use a fixed UAC helper that verifies task ownership.");
  document.querySelectorAll("[data-windows-schedule-only]").forEach((element) => { element.hidden = service; });
  if (service) {
    setText("schedule-page-eyebrow", linux ? "Linux service delivery lifecycle" : mac ? "Mac Docker delivery lifecycle" : "Container delivery lifecycle");
    setText("schedule-page-copy", "Review the configured delivery window and explicitly enable or disable future starts in the embedded scheduler.");
    setText("schedule-boundary-eyebrow", "Narrow configuration boundary");
    setText("schedule-boundary-heading", "The browser never supplies a command.");
    setText("schedule-boundary-copy", linux
      ? "The Manager accepts only enable or disable for this package. It rechecks the saved configuration revision, writes a private backup, and changes no systemd unit, port, service account, application file, or host setting."
      : "The Manager accepts only enable or disable for this package. It rechecks the saved configuration revision, writes a private backup, and changes no container, image, port, volume, UID, or host setting.");
    setText("schedule-overview-heading", "Observed embedded scheduler state");
    setText("schedule-enable-copy", "Allow the embedded scheduler to begin a future newsletter run in the configured weekly window.");
    setText("schedule-disable-copy", "Prevent future scheduler starts while preserving configuration, history, output, and any delivery already running.");
    byId("schedule-actions").setAttribute("aria-label", linux ? "Linux service schedule actions" : mac ? "Mac Docker schedule actions" : "Container schedule actions");
  } else {
    setText("schedule-page-eyebrow", "Windows delivery lifecycle");
    setText("schedule-page-copy", "Review the configured delivery window, verify task ownership, and make one explicit elevated change at a time.");
    setText("schedule-boundary-eyebrow", "Narrow elevation boundary");
    setText("schedule-boundary-heading", "The browser never supplies a command.");
    setText("schedule-boundary-copy", "The Manager accepts only install/refresh, enable, disable, or remove. Windows asks for administrator approval, and the helper rechecks configuration and task ownership.");
    setText("schedule-overview-heading", "Observed Task Scheduler state");
    setText("schedule-enable-copy", "Allow an installed, verified task to begin future scheduled newsletter runs.");
    setText("schedule-disable-copy", "Prevent future task starts while preserving configuration, history, output, and the task definition.");
    byId("schedule-actions").setAttribute("aria-label", "Windows schedule actions");
  }
}

function renderFirstTimeSetup() {
  const prompt = byId("first-time-setup");
  const firstRun = state.editor?.state === "unconfigured";
  prompt.hidden = !firstRun;
  if (firstRun) {
    setChip("first-time-setup-chip", "Not run", "pending");
    setText("first-time-setup-copy", state.runtimeMode === "windows"
      ? "Add Tautulli, Plex, and email settings first. Optional public Funnel access stays off until you create a unique Manager password in Settings."
      : "Add Tautulli, Plex, and email settings, then let the Manager validate the non-sending setup checks.");
  }
}

function setupWorkflowPresentation(workflow = state.setupWorkflow) {
  if (!workflow?.available) {
    return {
      label: state.editor?.state === "unconfigured" ? "Not configured" : "Not run",
      tone: "neutral",
      summary: state.editor?.state === "unconfigured"
        ? "Complete the guided configuration before setup checks can run."
        : "Safe setup checks have not been recorded for this configuration.",
    };
  }
  const cacheDisabled = state.cache?.enabled === false && workflow.steps?.cache?.state === "skipped";
  const applicableStepNames = cacheDisabled ? setupWorkflowSteps.filter((name) => name !== "cache") : setupWorkflowSteps;
  const steps = applicableStepNames.map((name) => workflow.steps?.[name]).filter(Boolean);
  const states = steps.map((step) => step.state);
  const active = state.setupWorkflowRunning || states.includes("running");
  if (active) return { label: "Running", tone: "pending", summary: "Safe setup checks are running and each result is retained as it completes." };
  if (states.includes("failed")) {
    const retainedChoices = state.setupWorkflow?.steps?.choices?.state === "failed" &&
      state.discovery?.configRevision === state.editor?.revision;
    return {
      label: "Needs review",
      tone: "bad",
      summary: retainedChoices
        ? "Live Tautulli choice refresh failed. Cached library and user choices remain retained; other check labels are separate retained evidence."
        : "One or more saved setup checks need review before live delivery.",
    };
  }
  if (states.every((stepState) => stepState === "not-run")) return { label: "Not run", tone: "neutral", summary: "Validate and save to run the five safe setup checks." };
  if (states.includes("waiting")) return { label: "Waiting", tone: "waiting", summary: "One or more setup checks are waiting for a prerequisite." };
  if (states.some((stepState) => ["warning", "skipped"].includes(stepState))) return { label: "Completed with notes", tone: states.includes("warning") ? "warning" : "neutral", summary: "The saved configuration was checked; review the noted result before live delivery." };
  if (states.length === applicableStepNames.length && states.every((stepState) => stepState === "passed")) {
    return {
      label: "Passed",
      tone: "good",
      summary: cacheDisabled
        ? "All four applicable safe setup checks passed; the deleted-item cache is disabled."
        : "All five safe setup checks passed for the saved configuration.",
    };
  }
  return { label: "Incomplete", tone: "neutral", summary: "Some setup checks have not completed for the saved configuration." };
}

function renderDashboardConfigStatus() {
  const presentation = setupWorkflowPresentation();
  setChip("configuration-status-chip", presentation.label, presentation.tone);
  setText("configuration-status-copy", presentation.summary);
  for (const name of setupWorkflowSteps) {
    const displayState = name === "cache" && state.cache?.enabled === false
      ? "Disabled"
      : titleCase(state.setupWorkflow?.steps?.[name]?.state || "not-run");
    setSwappingText(`configuration-status-${name}`, displayState);
  }
}

const funnelIntegrationStates = new Set([
  "active", "inactive", "starting", "stopping", "manager-password-required", "approval-required", "ready",
  "authorization-required", "tailscale-required", "sign-in-required", "not-running", "funnel-unsupported",
  "migration-required", "needs-attention", "unavailable", "unsupported",
]);

function funnelIntegrationPresentation(remote) {
  if (remote === null || remote === undefined) {
    return { label: "Not checked", detail: "Loading retained status", tone: "neutral", outcome: "" };
  }
  const validShape = typeof remote === "object" && remote !== null &&
    typeof remote.supported === "boolean" && typeof remote.installed === "boolean" &&
    typeof remote.enabled === "boolean" && typeof remote.active === "boolean" &&
    typeof remote.state === "string" && funnelIntegrationStates.has(remote.state) &&
    (remote.cleanupRequired === undefined || typeof remote.cleanupRequired === "boolean") &&
    (remote.passwordRequired === undefined || typeof remote.passwordRequired === "boolean");
  if (!validShape) return { label: "Failed", detail: "Blocked · retained status invalid", tone: "bad", outcome: "failed" };

  const cleanupRequired = remote.cleanupRequired === true;
  const passwordRequired = remote.passwordRequired === true;
  if (!remote.supported) {
    if (remote.enabled || remote.active || cleanupRequired || remote.state !== "unsupported") {
      return { label: "Failed", detail: "Blocked · retained status invalid", tone: "bad", outcome: "failed" };
    }
    return { label: "Not applicable", detail: "Unsupported on this surface", tone: "neutral", outcome: "" };
  }
  if (remote.active) {
    if (remote.enabled && !passwordRequired && remote.state === "active") {
      return { label: "Passed", detail: "Active", tone: "good", outcome: "passed" };
    }
    return { label: "Failed", detail: "Blocked · retained status invalid", tone: "bad", outcome: "failed" };
  }
  if (remote.enabled) {
    if (remote.state === "starting" && !passwordRequired) {
      return { label: "Attention", detail: "Publication pending", tone: "publication-pending", outcome: "warning" };
    }
    if (remote.state === "stopping") {
      return { label: "Attention", detail: "Cleanup pending", tone: "publication-pending", outcome: "warning" };
    }
    return { label: "Failed", detail: passwordRequired ? "Blocked · password lock required" : "Blocked · verification failed", tone: "bad", outcome: "failed" };
  }
  if (cleanupRequired || ["migration-required", "needs-attention", "unavailable"].includes(remote.state)) {
    return { label: "Failed", detail: "Blocked · cleanup or verification required", tone: "bad", outcome: "failed" };
  }
  if (["inactive", "ready", "approval-required", "manager-password-required"].includes(remote.state)) {
    return { label: "Passed", detail: passwordRequired ? "Off · password required before enable" : "Off", tone: "good", outcome: "passed" };
  }
  if (["tailscale-required", "authorization-required", "sign-in-required", "not-running", "funnel-unsupported"].includes(remote.state)) {
    const details = {
      "tailscale-required": "Not configured",
      "authorization-required": "Not configured · host approval required",
      "sign-in-required": "Not configured · sign-in required",
      "not-running": "Not configured · Tailscale stopped",
      "funnel-unsupported": "Not configured · client update required",
    };
    return { label: "Not configured", detail: details[remote.state], tone: "neutral", outcome: "" };
  }
  return { label: "Failed", detail: "Blocked · retained status invalid", tone: "bad", outcome: "failed" };
}

function tailscaleStatusBadgePresentation(remote) {
  if (!remote || typeof remote !== "object") {
    return { active: false, label: "Checking retained status", settingsAvailable: false };
  }
  const settingsAvailable = remote.supported === true;
  const active = settingsAvailable && remote.enabled === true &&
    ((remote.state === "active" && remote.active === true) || remote.state === "starting");
  let label = "Unavailable";
  if (!settingsAvailable) label = remote.state === "unsupported" ? "Unsupported" : "Unavailable";
  else if (remote.state === "inactive") label = "Off";
  else label = tailscaleStatePresentation(remote).label;
  return { active, label, settingsAvailable };
}

function renderTailscaleStatusButton(remote = state.tailscale) {
  const button = byId("tailscale-status-button");
  if (!button) return;
  const presentation = !remote && state.tailscaleError
    ? { active: false, label: "Unavailable", settingsAvailable: false }
    : tailscaleStatusBadgePresentation(remote);
  const tooltip = `Tailscale Funnel: ${presentation.label}`;
  button.classList.toggle("active", presentation.active);
  button.classList.toggle("off", !presentation.active);
  button.setAttribute("aria-disabled", String(!presentation.settingsAvailable));
  button.setAttribute("aria-label", tooltip);
  button.dataset.tooltip = tooltip;
}

function renderIntegrationStatus() {
  const last = state.verification?.last || null;
  const smtp = state.verification?.smtp || null;
  const steps = new Map((last?.steps || []).map((step) => [step.service, step]));
  const retainedLANState = retainedSetupCheckState("lan");
  const retainedSMTPState = retainedSetupCheckState("smtp");
  const tautulliState = steps.get("tautulli")?.state || retainedLANState || "not checked";
  const plexState = steps.get("plex")?.state || retainedLANState || "not checked";
  const smtpState = smtp?.state || retainedSMTPState || "not checked";
  setText("tautulli-state", titleCase(tautulliState));
  setText("plex-state", titleCase(plexState));
  setText("smtp-state", titleCase(smtpState));

  const funnel = funnelIntegrationPresentation(state.tailscale);
  setText("funnel-state", funnel.label);
  setText("funnel-detail", funnel.detail);
  const funnelValue = byId("funnel-integration-value");
    funnelValue.className = "integration-value neutral";
  funnelValue.setAttribute("aria-label", `Tailscale Funnel status: ${funnel.label}; ${funnel.detail}`);
  const funnelLink = byId("funnel-settings-link");
  const settingsAvailable = state.tailscale?.supported === true;
  funnelLink.setAttribute("aria-disabled", String(!settingsAvailable));
  funnelLink.dataset.tooltip = settingsAvailable
    ? `Open Settings > Tailscale Funnel · ${funnel.detail}`
    : `Tailscale Funnel settings unavailable · ${funnel.detail}`;
  funnelLink.setAttribute("aria-label", !settingsAvailable
    ? `Tailscale Funnel: ${funnel.label}; Settings unavailable on this surface`
    : "Tailscale Funnel. Open Settings, Tailscale Funnel.");
  renderTailscaleStatusButton();

  const baseOutcomes = [last?.overall || retainedLANState, smtp?.overall || retainedSMTPState].filter(Boolean);
  const outcomes = [...baseOutcomes, funnel.outcome].filter(Boolean);
  let overall = "not-run";
  if (outcomes.includes("failed")) overall = "failed";
  else if (outcomes.includes("warning")) overall = "warning";
  else if (baseOutcomes.length === 2 && outcomes.every((outcome) => outcome === "passed")) overall = "passed";
  else if (outcomes.length) overall = "partial";
  const verificationActive = state.verificationRunning || state.smtpVerificationRunning;
  const overallTone = verificationActive ? "pending" : overall === "passed" ? "good" : overall === "failed" ? "bad" : overall === "warning" ? "warning" : "neutral";
  const overallLabel = verificationActive ? "Running" : overall === "not-run" ? "Not run" : overall === "warning" ? "Attention" : titleCase(overall);
  setChip("integration-chip", overallLabel, overallTone);
  setText("integration-copy", state.discoveryError && outcomes.length
    ? "Tautulli/Plex and SMTP labels are retained checks with their own timestamps; the failed live choices refresh did not rerun them."
    : outcomes.length
      ? "Latest checks from validation or a targeted retest are retained for this saved configuration."
      : "Safe real checks run after a successful save or when you start a manual retest.");
  return { overallLabel, overallTone, funnel };
}

function retainedSetupCheckState(name) {
  const checkState = state.setupWorkflow?.steps?.[name]?.state || "";
  return ["passed", "warning", "failed"].includes(checkState) ? checkState : "";
}

function renderStatus() {
  const snapshot = state.status;
  if (!snapshot) return;
  const overall = snapshot.overall;
  const healthy = overall === "healthy";
  const blocked = overall === "blocked";
  renderDashboardGreeting(snapshot.observedAtUtc);
  setText("observed-time", formatDate(snapshot.observedAtUtc));
  setText("overall-label", titleCase(overall));
  setText("overall-heading", overallHeading(overall));
  setText("overall-copy", overallCopy(overall));
  byId("overall-orb").className = `status-orb ${healthy ? "good" : blocked ? "bad" : ""}`;
  setText("manager-state", titleCase(snapshot.runtime.manager));
  setText("preview-state", titleCase(snapshot.runtime.preview));
  setText("scheduler-state", titleCase(snapshot.runtime.scheduler));
  setChip("runtime-chip", snapshot.runtime.manager === "healthy" ? "Healthy" : "Degraded", snapshot.runtime.manager === "healthy" ? "good" : "bad");
  setText("runtime-copy", `${titleCase(snapshot.readiness.configuration)} configuration · ${titleCase(snapshot.readiness.privateData)} private state.`);
  setText("schedule-installed", yesNo(snapshot.schedule.installed));
  setText("schedule-enabled", yesNo(snapshot.schedule.enabled));
  setText("schedule-ownership", titleCase(snapshot.schedule.ownership));
  setText("schedule-state", titleCase(snapshot.schedule.state));
  const scheduleOwned = !snapshot.schedule.installed || snapshot.schedule.owned;
  const embeddedSchedule = snapshot.schedule.provider?.startsWith("embedded-");
  const scheduleProbeFailed = ["probe-failed", "heartbeat-stale", "starting"].includes(snapshot.schedule.state);
  const scheduleHealthy = snapshot.schedule.installed && snapshot.schedule.enabled && scheduleOwned;
  setChip("schedule-chip", scheduleProbeFailed ? "Status unavailable" : !scheduleOwned ? "Ownership warning" : scheduleHealthy ? "Active" : snapshot.schedule.installed ? "Disabled" : "Not installed", scheduleProbeFailed || !scheduleOwned ? "bad" : scheduleHealthy ? "good" : "neutral");
  setText("schedule-copy", embeddedSchedule
    ? scheduleProbeFailed ? "The embedded scheduler heartbeat is unavailable or stale." : "Read from the package-managed scheduler heartbeat and persistent configuration."
    : scheduleProbeFailed ? "Windows Task Scheduler status could not be verified." : !scheduleOwned ? "A same-named task exists but does not match this installation." : snapshot.schedule.supported ? "Read directly from Windows Task Scheduler." : "Schedule management is unavailable on this platform.");
  const deliveryRunning = productionDeliveryIsRunning(snapshot);
  const deliveryAttemptUTC = productionDeliveryStartedAt(snapshot);
  setText("last-attempt", formatDate(deliveryAttemptUTC));
  setSwappingText("last-result", deliveryRunning ? "Running" : titleCase(snapshot.delivery.result));
  setText("last-success", formatDate(snapshot.delivery.lastSuccessUtc));
  setText("timeline-last-attempt", formatDate(deliveryAttemptUTC));
  const rendererEvidence = snapshot.delivery.evidence === "renderer-result";
  setText("last-accepted-count", deliveryRunning ? "In progress" : rendererEvidence ? String(snapshot.delivery.smtpAcceptedCount || 0) : "Not recorded");
  const deliveryFailureCopy = rendererEvidence && snapshot.delivery.errorCategory && snapshot.delivery.errorCategory !== "no-eligible-recipients"
    ? `${rendererFailureCopy(snapshot.delivery.errorCategory, "")}${smtpFailureEvidenceCopy(snapshot.delivery.smtpFailure)}`
    : "";
  setText("delivery-copy", rendererEvidence
    ? deliveryFailureCopy || "Application evidence records SMTP acceptance, not inbox delivery."
    : "Task execution is not presented as SMTP acceptance or inbox delivery.");
  setText("timeline-last-copy", rendererEvidence
    ? `${snapshot.delivery.smtpAcceptedCount || 0} accepted by SMTP · ${snapshot.delivery.skippedCount || 0} skipped · ${snapshot.delivery.failedCount || 0} failed.`
    : "No sanitized renderer result has been recorded.");
  if (deliveryRunning) {
    setText("delivery-copy", "A production delivery is running. SMTP acceptance will appear automatically when the run finishes.");
    setText("timeline-last-copy", "Production delivery is in progress. Sanitized result evidence will appear automatically when the run finishes.");
  }
  if (rendererEvidence && !deliveryRunning) {
    const deliveryPrefix = snapshot.delivery.errorCategory === "no-eligible-recipients"
      ? "No eligible production recipients; no message was accepted by SMTP."
      : byId("timeline-last-copy").textContent;
    setText("timeline-last-copy", `${deliveryPrefix}${skipReasonCopy(snapshot.delivery.skipReasonCounts)}${snapshot.delivery.errorCategory && snapshot.delivery.errorCategory !== "no-eligible-recipients" ? ` ${rendererFailureCopy(snapshot.delivery.errorCategory, "")}${smtpFailureEvidenceCopy(snapshot.delivery.smtpFailure)}` : ""}`);
  }
  const deliveryTone = deliveryRunning ? "pending" : snapshot.delivery.result === "smtp-accepted" ? "good" : snapshot.delivery.result === "failed" ? "bad" : "neutral";
  setChip("delivery-chip", deliveryRunning ? "Running" : snapshot.delivery.result === "not-recorded" ? "No history" : titleCase(snapshot.delivery.result), deliveryTone);
  byId("delivery-status-icon").classList.toggle("delivery-icon-running", deliveryRunning);
  renderIntegrationStatus();
  renderDashboardConfigStatus();
  setText("next-run", formatDate(snapshot.schedule.nextRunLocal));
  setText("next-run-utc", snapshot.schedule.nextRunUtc ? `UTC: ${formatDate(snapshot.schedule.nextRunUtc)}` : embeddedSchedule ? "The embedded scheduler has not reported a valid upcoming run." : "Task Scheduler has not reported an upcoming run.");
  setText("preview-count", snapshot.previewSummary);
  setTimelineCardState("timeline-upcoming-card", "timeline-ready", scheduleHasUpcomingRun(snapshot));
  setTimelineCardState("timeline-last-attempt-card", "timeline-success", rendererEvidence && !deliveryRunning && snapshot.delivery.result === "smtp-accepted");
  setTimelineCardState("timeline-previews-card", "timeline-ready", state.previews.length > 0);
  setText("sidebar-platform", `${titleCase(snapshot.platform)} · ${isNAS() ? "trusted LAN" : isLinuxService() ? "host loopback" : isMacDocker() ? "Mac loopback" : "local only"}`);
  setText("update-platform", titleCase(snapshot.platform));
  manageDeliveryStatusPolling();
}

function productionDeliveryOperationIsActive() {
  return state.operation?.type === "send-all" && operationIsActive(state.operation);
}

function productionDeliveryIsRunning(snapshot = state.status) {
  return Boolean(snapshot?.delivery?.running || productionDeliveryOperationIsActive());
}

function productionDeliveryStartedAt(snapshot = state.status) {
  return productionDeliveryOperationIsActive()
    ? state.operation?.startedAtUtc || snapshot?.delivery?.lastAttemptUtc
    : snapshot?.delivery?.lastAttemptUtc;
}

function scheduleHasUpcomingRun(snapshot) {
  const schedule = snapshot?.schedule;
  if (!schedule?.installed || !schedule.enabled || !schedule.owned) return false;
  const embedded = schedule.provider?.startsWith("embedded-");
  if (embedded ? schedule.state !== "running" : schedule.state !== "ready") return false;
  const next = new Date(schedule.nextRunUtc || schedule.nextRunLocal || "");
  const observed = new Date(snapshot.observedAtUtc || Date.now());
  return !Number.isNaN(next.getTime()) && !Number.isNaN(observed.getTime()) && next.getTime() > observed.getTime();
}

function setTimelineCardState(id, className, active) {
  byId(id).classList.toggle(className, Boolean(active));
}

function renderDashboardGreeting(observedAtUtc) {
  const observed = new Date(observedAtUtc || Date.now());
  const validObserved = !Number.isNaN(observed.getTime());
  const hour = validObserved ? observed.getHours() : new Date().getHours();
  const minute = validObserved ? observed.getMinutes() : new Date().getMinutes();
  const minuteOfDay = hour * 60 + minute;
  let greeting = "Good evening";
  if (minuteOfDay >= 360 && minuteOfDay <= 720) greeting = "Good morning";
  else if (minuteOfDay >= 721 && minuteOfDay <= 1080) greeting = "Good afternoon";
  const name = discoveredAdministratorName();
  setText("dashboard-greeting", name ? `${greeting}, ${name}.` : `${greeting}.`);
}

function discoveredAdministratorName() {
  const suggestedID = String(state.discovery?.suggestedPreviewUserId || "");
  if (!suggestedID) return "";
  const user = discoveredNewsletterUsers().find((candidate) => String(candidate.id) === suggestedID);
  const name = String(user?.name || "").trim();
  return name && !/^User \d+$/i.test(name) ? name : "";
}

function renderSchedule() {
  const snapshot = state.status;
  const editor = state.editor;
  const operation = state.scheduleOperation;
  if (!snapshot || !editor) return;
  const schedule = snapshot.schedule;
  const embeddedSchedule = schedule.provider?.startsWith("embedded-");
  const allowedActions = new Set(state.capabilities?.scheduleActions || []);
  const ready = editor.state === "ready";
  const owned = !schedule.installed || schedule.owned;
  const probeFailed = ["probe-failed", "heartbeat-stale", "starting"].includes(schedule.state);
  const scheduleActive = scheduleOperationIsActive(operation);
  const managerActive = operationIsActive(state.operation);
  const blocked = state.scheduleStarting || scheduleActive || managerActive || !ready || !schedule.supported || !owned || probeFailed;

  let chipText = "Not installed";
  let chipTone = "neutral";
  if (!schedule.supported) chipText = "Unsupported";
  else if (probeFailed) { chipText = "Status unavailable"; chipTone = "bad"; }
  else if (!owned) { chipText = "Ownership warning"; chipTone = "bad"; }
  else if (state.scheduleStarting) { chipText = "Starting"; chipTone = "pending"; }
  else if (scheduleActive) { chipText = "Changing"; chipTone = "pending"; }
  else if (schedule.installed && schedule.enabled) { chipText = "Active"; chipTone = "good"; }
  else if (schedule.installed) chipText = "Disabled";
  setChip("schedule-view-chip", chipText, chipTone);

  const day = configEditorValue("ScheduleDay") || "Friday";
  const time = configEditorValue("ScheduleTime") || "09:30";
  setText("schedule-configured-window", ready ? `${day} at ${time} ${embeddedSchedule ? `in the configured ${embeddedRuntimeLabel()} timezone` : "local Windows time"}` : "Complete configuration first");
  setText("schedule-view-installed", yesNo(schedule.installed));
  setText("schedule-view-enabled", yesNo(schedule.enabled));
  setText("schedule-view-ownership", titleCase(schedule.ownership));
  setText("schedule-view-state", titleCase(schedule.state));
  setText("schedule-view-next-run", formatDate(schedule.nextRunLocal));
  setText("schedule-observed", `Observed ${formatDate(snapshot.observedAtUtc)}`);

  const warning = byId("schedule-warning");
  warning.className = "schedule-warning";
  if (!schedule.supported) warning.textContent = "Schedule changes are unavailable on this platform.";
  else if (probeFailed) {
    warning.textContent = embeddedSchedule
      ? `The embedded scheduler heartbeat is unavailable or stale. Restart the ${isLinuxService() ? "systemd service" : isMacDocker() ? "Docker Desktop service" : "container"} and confirm its timezone before enabling delivery.`
      : "Task Scheduler status could not be verified. The Manager will not request a schedule mutation until the local probe succeeds.";
    warning.classList.add("bad");
  }
  else if (!ready) warning.textContent = "Complete and save configuration before requesting a schedule change.";
  else if (!owned) {
    warning.textContent = "Safety stop: a same-named task exists but its action, working directory, or SYSTEM principal does not match this TautWeekly installation. The Manager will not modify it.";
    warning.classList.add("bad");
  } else if (managerActive) warning.textContent = "Wait for the active preview or test-delivery operation before changing the schedule.";
  else if (scheduleActive) warning.textContent = embeddedSchedule ? "A schedule configuration change is completing. No second change can start." : "A fixed schedule operation is waiting for UAC approval or completing. No second change can start.";
  else warning.textContent = "Task execution is distinct from SMTP acceptance. The dashboard reports both signals separately.";

  const installLabel = schedule.installed ? "Refresh" : "Install";
  setSwappingText("schedule-install-heading", installLabel);
  setSwappingText("schedule-install-button-label", installLabel);
  setText("schedule-install-copy", schedule.installed
    ? "Safely refresh the verified SYSTEM task after configuration changes."
    : "Create the verified SYSTEM task from the configured day and local time.");

  for (const button of document.querySelectorAll("[data-schedule-action]")) {
    const action = button.dataset.scheduleAction;
    button.closest("article").hidden = !allowedActions.has(action);
    let available = action === "install";
    if (action === "enable") available = schedule.installed && !schedule.enabled;
    if (action === "disable") available = schedule.installed && schedule.enabled;
    if (action === "remove") available = schedule.installed;
    button.disabled = blocked || !allowedActions.has(action) || !available;
  }

  const confirmation = byId("schedule-confirmation");
  const pending = state.schedulePendingAction;
  confirmation.hidden = !pending;
  if (pending) {
    const copy = scheduleActionCopy(pending, day, time, schedule.installed);
    setText("schedule-confirmation-heading", copy.heading);
    setText("schedule-confirmation-copy", copy.copy);
    setText("schedule-confirm-label", copy.label);
    setText("schedule-confirm-help", copy.help);
    const confirmed = byId("schedule-confirm").checked;
    byId("schedule-confirm-run").disabled = blocked || !confirmed;
    setSwappingButtonText("schedule-confirm-run", state.scheduleStarting ? "Applying schedule change..." : embeddedSchedule ? "Apply schedule change" : "Request administrator approval");
  }
  renderScheduleOperation(operation);
}

function renderScheduleOperation(operation) {
  if (!operation) {
    setText("schedule-current-heading", "No schedule change recorded");
    setText("schedule-current-copy", isServiceRuntime() ? "No embedded scheduler change has been started by this Manager." : "No UAC request has been started by this Manager.");
    setText("schedule-current-time", "Not recorded");
    setChip("schedule-current-chip", "Idle", "neutral");
    return;
  }
  const action = titleCase(operation.action);
  let heading = `${action} schedule ${titleCase(operation.state)}`;
  let copy = "The fixed helper is waiting to report a sanitized result.";
  if (operation.state === "queued") {
    heading = `${action} schedule queued`;
    copy = isServiceRuntime() ? "The revision-checked configuration change is waiting to start." : "Windows may be preparing the UAC approval prompt.";
  } else if (operation.state === "running") {
    heading = `${action} schedule in progress`;
    copy = isServiceRuntime() ? "The Manager is applying one package-defined schedule setting." : "Approve the Windows UAC prompt if it is visible. This operation cannot be changed from browser input.";
  } else if (operation.state === "succeeded") {
    heading = `${action} schedule completed`;
    copy = isServiceRuntime() ? "The Manager saved and verified the embedded scheduler state." : "The helper completed and the Manager observed the expected Task Scheduler state.";
  } else if (operation.state === "failed") {
    heading = `${action} schedule was not completed`;
    copy = scheduleFailureCopy(operation.errorCategory, operation.supportCode);
  }
  setText("schedule-current-heading", heading);
  setText("schedule-current-copy", copy);
  const time = operation.finishedAtUtc ? `Finished ${formatDate(operation.finishedAtUtc)}` : `Started ${formatDate(operation.startedAtUtc)}`;
  setText("schedule-current-time", time);
  setChip("schedule-current-chip", titleCase(operation.state), operation.state === "succeeded" ? "good" : operation.state === "failed" ? "bad" : scheduleOperationIsActive(operation) ? "pending" : "neutral");
}

function configEditorValue(name) {
  return state.editor?.fields?.find((field) => field.name === name)?.value;
}

function scheduleOperationIsActive(operation) {
  return Boolean(operation && ["queued", "running"].includes(operation.state));
}

function scheduleActionCopy(action, day, time, scheduleInstalled = false) {
  if (isServiceRuntime() && action === "enable") return { heading: "Enable future scheduled delivery", copy: `Allow the embedded scheduler to start on ${day} at ${time} in the configured ${embeddedRuntimeLabel()} timezone.`, label: `Enable this ${embeddedRuntimeLabel()} schedule`, help: "This updates persistent configuration and does not send a newsletter immediately." };
  if (isServiceRuntime() && action === "disable") return { heading: "Disable future scheduled starts", copy: "Prevent future embedded-scheduler starts while preserving the package and its data.", label: `Disable this ${embeddedRuntimeLabel()} schedule`, help: "A newsletter delivery already running will not be cancelled." };
  switch (action) {
  case "install": return scheduleInstalled
    ? { heading: "Refresh the weekly task", copy: `Update the verified SYSTEM task for ${day} at ${time} local Windows time.`, label: "Refresh this owned TautWeekly schedule", help: "Windows will request administrator approval. An unrelated same-named task will be left untouched." }
    : { heading: "Install the weekly task", copy: `Create the verified SYSTEM task for ${day} at ${time} local Windows time.`, label: "Install this TautWeekly schedule", help: "Windows will request administrator approval. An unrelated same-named task will be left untouched." };
  case "enable": return { heading: "Enable future scheduled delivery", copy: "Allow the installed and ownership-verified task to start on its configured weekly window.", label: "Enable this verified schedule", help: "This does not send a newsletter immediately." };
  case "disable": return { heading: "Disable future scheduled starts", copy: "Keep the verified task definition but prevent it from starting future newsletter runs.", label: "Disable this verified schedule", help: "A newsletter process already running will not be cancelled." };
  case "remove": return { heading: "Remove the verified schedule", copy: "Delete only the ownership-verified Windows task while preserving configuration, state, history, previews, and logs.", label: "Remove this verified schedule", help: "This cannot be undone from operation history, but it can be installed again later." };
  default: return { heading: "Confirm schedule change", copy: "Review this typed operation.", label: "Confirm this schedule change", help: "Windows will request administrator approval." };
  }
}

function scheduleFailureCopy(category, supportCode) {
  const suffix = supportCode ? ` Support code: ${supportCode}.` : "";
  switch (category) {
  case "elevation-declined": return "Windows administrator approval was declined or closed." + suffix;
  case "configuration-changed": return (isServiceRuntime() ? "Configuration changed before the schedule update could be applied." : "Configuration changed while Windows approval was pending. Refresh and review before retrying.") + suffix;
  case "task-not-found": return "The expected verified task was not found. Refresh local status before retrying." + suffix;
  case "task-ownership-mismatch": return "The same-named task did not match this installation and was left untouched." + suffix;
  case "schedule-invalid": return "The saved day or time could not be interpreted safely." + suffix;
  case "renderer-missing": return "The packaged newsletter renderer is unavailable, so the schedule was not enabled." + suffix;
  case "postcondition-failed": return (isServiceRuntime() ? "The requested embedded scheduler state could not be verified." : "The helper returned, but the expected Task Scheduler state could not be verified.") + suffix;
  case "schedule-configuration-read-failed": return "Windows approval succeeded, but the helper could not validate the saved schedule configuration." + suffix;
  case "task-definition-failed": return "Windows approval succeeded, but Task Scheduler rejected the requested schedule definition." + suffix;
  case "task-mutation-failed": return "Windows approval succeeded, but Task Scheduler could not apply the requested change." + suffix;
  case "task-verification-failed": return "Task Scheduler accepted the request, but the helper could not verify the resulting owned task state." + suffix;
  case "task-read-access-failed": return "Task Scheduler accepted the request, but Windows could not grant this signed-in user read-only status access to the task." + suffix;
  case "container-schedule-update-failed": return "The persistent embedded scheduler setting could not be updated. Existing configuration remains available for recovery." + suffix;
  case "container-schedule-verification-failed": return "The Manager saved a scheduler change but could not verify the resulting persistent state. Review configuration and backups before retrying." + suffix;
  case "manager-restarted": return (isServiceRuntime() ? "The Manager restarted while a schedule change was active, so the final result is unknown. Refresh the embedded scheduler status." : "The Manager restarted while elevation was pending, so the final result is unknown. Refresh Task Scheduler status.") + suffix;
  default: return "The schedule helper did not complete successfully. No raw PowerShell output was retained." + suffix;
  }
}

function rendererFailureCopy(category, supportCode) {
  const suffix = supportCode ? ` Support code: ${supportCode}.` : "";
  switch (category) {
  case "operation-busy": return "Another newsletter, update, or scheduled-delivery operation owns the package renderer. Wait for it to finish, then retry." + suffix;
  case "configuration-invalid": return "The renderer could not load the saved configuration snapshot. Review Config, then retry." + suffix;
  case "tautulli-unavailable": return "The renderer could not complete the required Tautulli data stage. Run Verify, then retry." + suffix;
  case "plex-unavailable": return "Direct Plex verification could not be completed. Review the sanitized evidence under Verify, then retry." + suffix;
  case "asset-unavailable": return "The renderer could not prepare a required local media asset. Review private data-directory access and free space, then retry." + suffix;
  case "render-failed": return "Newsletter HTML construction failed before the operation completed. Review Config and Verify, then retry." + suffix;
  case "output-failed": return "Newsletter HTML was built, but the private preview files could not be written. Review private data-directory access and free space, then retry." + suffix;
  case "smtp-failed": return "The renderer failed during SMTP handoff. Review Verify and the controlled TestEmail workflow before retrying." + suffix;
  case "smtp-auth-failed": return "SMTP authentication was rejected, so the batch stopped after one attempt. Stop retries, confirm the provider account and credentials, then retry only after the provider permits access." + suffix;
  case "smtp-rate-limited": return "The SMTP provider returned a temporary service or rate-limit response, so the batch stopped before another recipient attempt. Stop retries and follow the provider's recovery guidance before trying again." + suffix;
  case "smtp-recipient-rejected": return "The SMTP provider returned an address/mailbox-specific permanent rejection for one recipient; later attempts remained individually isolated and spaced." + suffix;
  case "smtp-provider-rejected": return "The SMTP provider rejected a batch-wide protocol stage, so delivery stopped before another recipient attempt. Review the provider account or SMTP policy before retrying." + suffix;
  case "smtp-transport-failed": return "The SMTP connection ended before message acceptance could begin, so the batch stopped before another recipient attempt. Verify the provider endpoint, then retry cautiously." + suffix;
  case "smtp-acceptance-unknown": return "The SMTP connection ended after message data was submitted but before acceptance could be confirmed. The message was not retried, and the batch stopped to prevent duplicates." + suffix;
  case "user-roster-refresh-failed": return "Tautulli could not confirm a fresh Plex user roster, so production delivery stopped before SMTP. Confirm Tautulli can reach Plex, then retry." + suffix;
  case "platform-unsupported": return "This package does not expose the requested renderer operation." + suffix;
  case "manager-restarted": return "The Manager restarted before it could reconcile the renderer result. Refresh status, then retry." + suffix;
  default: return "The package renderer did not complete successfully. Raw process output was not retained." + suffix;
  }
}

function smtpFailureEvidenceCopy(evidence) {
  if (!evidence || !evidence.stage) return "";
  const response = Number(evidence.responseCode) > 0 ? `; SMTP response ${Number(evidence.responseCode)}` : "; no SMTP response was available";
  const acceptance = evidence.acceptance === "unknown" ? "; acceptance is unknown and was not retried" : "";
  return ` Sanitized stage: ${titleCase(String(evidence.stage).replaceAll("-", " "))}${response}${acceptance}.`;
}

function renderConfig() {
  const config = state.config;
  const grid = byId("config-grid");
  grid.replaceChildren();
  setChip("config-chip", titleCase(config.state), config.valid ? "good" : config.exists ? "bad" : "neutral");
  if (!config.fields.length) {
    const empty = document.createElement("div");
    empty.className = "config-empty";
    empty.textContent = config.exists ? "The configuration could not be displayed safely." : "No private config.json exists yet. Complete guided setup to create it.";
    grid.append(empty);
    return;
  }
  for (const field of config.fields) {
    if (isServiceRuntime() && field.name === "ScheduledTaskName") continue;
    const card = document.createElement("article");
    card.className = `config-field${field.secret ? " secret" : ""}`;
    const label = document.createElement("small");
    label.textContent = `${field.name} · ${field.type}`;
    const value = document.createElement("strong");
    value.textContent = field.secret ? (field.secret.configured ? "Configured · value withheld" : "Not configured") : displayValue(field.value);
    card.append(label, value);
    grid.append(card);
  }
}

function renderConfigEditor() {
  const editor = state.editor;
  const form = byId("config-form");
  const blocked = byId("config-blocked");
  const sections = byId("config-sections");
  clearConfigErrors();
  clearAllRevealedSecrets();
  sections.replaceChildren();
  setChip("config-chip", titleCase(editor.state), editor.state === "ready" ? "good" : editor.valid ? "neutral" : "bad");
  form.hidden = !editor.valid;
  blocked.hidden = editor.valid;
  if (!editor.valid) {
    renderDirectPlexNotice();
    renderDiscovery();
    return;
  }

  const fieldsByGroup = new Map(editor.groups.map((group) => [group, []]));
  for (const field of editor.fields) {
    if (configFieldIsHidden(field)) continue;
    if (!fieldsByGroup.has(field.group)) fieldsByGroup.set(field.group, []);
    fieldsByGroup.get(field.group).push(field);
  }
  for (const [group, fields] of fieldsByGroup) {
    if (!fields.length) continue;
    const section = document.createElement("section");
    section.className = "config-section";
    if (group === "Custom text card") section.classList.add("config-section-custom-text-card");
    const heading = document.createElement("div");
    heading.className = "config-section-heading";
    const title = document.createElement("h2");
    title.textContent = group;
    const count = document.createElement("small");
    count.textContent = `${fields.length} ${fields.length === 1 ? "setting" : "settings"}`;
    heading.append(title, count);
    const grid = document.createElement("div");
    grid.className = "config-editor-grid";
    for (const field of fields) grid.append(createConfigControl(field));
    section.append(heading, grid);
    sections.append(section);
  }
  for (const field of editor.fields.filter(configFieldIsHidden)) {
    if (byId(`config-${field.name}`)) continue;
    const input = document.createElement("input");
    input.type = "hidden";
    input.id = `config-${field.name}`;
    input.name = field.name;
    input.value = field.type === "user-email-map"
      ? JSON.stringify(field.value && typeof field.value === "object" && !Array.isArray(field.value) ? field.value : {})
      : Array.isArray(field.value) ? field.value.join(", ") : field.value ?? "";
    sections.append(input);
  }
  byId("config-save-copy").textContent = editor.exists
    ? "A private timestamped backup is created before config.json is replaced. Only affected discovery, connection checks, SMTP preflight, or local previews rerun; unrelated valid results remain connected."
    : "A new private config.json is created only after validation, then the required discovery, connection checks, SMTP preflight, and six non-sending local previews run.";
  if (Object.keys(editor.issues || {}).length) {
    showConfigErrors("Complete the required setup fields before saving.", editor.issues, false);
  }
  renderDirectPlexNotice();
  renderDiscovery();
  byId("config-CustomTextCardEnabled")?.addEventListener("change", updateConfigSaveAvailability);
  byId("config-CustomTextCardBody")?.addEventListener("input", updateConfigSaveAvailability);
  updateConfigSaveAvailability();
}

function renderDirectPlexNotice() {
  const notice = byId("direct-plex-notice");
  const status = state.editor?.directPlex;
  const visible = Boolean(state.editor?.exists && status && (!status.urlConfigured || (!status.tokenConfigured && !status.runtimeTokenAvailable)));
  notice.hidden = !visible;
  if (!visible) return;
  const legacy = Boolean(status.legacyFieldsMissing);
  setText("direct-plex-notice-heading", legacy ? "Legacy config needs one direct Plex review" : "Complete optional direct Plex access");
  let copy = legacy
    ? "This older config.json never contained one or both direct Plex fields; the updater preserved it instead of guessing. "
    : "Direct Plex is optional, but one part of the connection is not available. ";
  if (!status.urlConfigured) copy += "For Plex on this computer, use http://127.0.0.1:32400; otherwise enter the Plex URL reachable from this runtime. ";
  if (!status.tokenConfigured && status.runtimeTokenAvailable) copy += "A trusted runtime Plex token is available and will be used without copying it into config.json. ";
  else if (!status.tokenConfigured) copy += "Paste the Plex administrator token to enable authenticated direct-Plex checks. ";
  copy += "Validate, save, and verify to normalize the legacy fields and re-run the safe checks.";
  setText("direct-plex-notice-copy", copy);
}

function reviewDirectPlexFields() {
  const input = byId("config-PlexServerUrl") || byId("config-PlexToken");
  input?.scrollIntoView({ behavior: "smooth", block: "center" });
  setTimeout(() => input?.focus({ preventScroll: true }), 250);
}

function renderDiscovery() {
  if (state.discovery && state.discovery.configRevision !== state.editor?.revision) state.discovery = null;
  const confirm = byId("discovery-confirm");
  const button = byId("discovery-run-button");
  const ready = state.editor?.state === "ready";
  const networkBusy = state.discoveryRunning || state.verificationRunning || state.smtpVerificationRunning;
  button.disabled = networkBusy || !ready || !confirm.checked;
  setSwappingButtonText("discovery-run-button", state.discoveryRunning ? "Loading choices..." : "Refresh Tautulli choices");
  if (!state.discovery) {
    byId("discovery-results").hidden = true;
    byId("discovery-message").textContent = state.discoveryError || (ready
      ? "The first valid save or a saved Tautulli connection change loads these choices automatically. Confirm above to repeat the saved service lookup now."
      : "Save a complete configuration before loading choices.");
    renderManagedUserDeliveryAddresses();
    renderUserComboboxes();
    return;
  }
  byId("discovery-results").hidden = false;
  byId("discovery-message").textContent = state.discoveryError || (state.discovery.retained
    ? `Cached choices from ${formatDate(state.discovery.completedAtUtc)} are retained locally for this saved configuration.`
    : `Fresh choices loaded ${formatDate(state.discovery.completedAtUtc)} and retained locally for this saved configuration.`);
  renderDiscoveredLibraries();
  renderDiscoveredUsers();
  renderManagedUserDeliveryAddresses();
  renderUserComboboxes();
}

function discoveryFailureMessage(message) {
  const retained = state.discovery?.configRevision === state.editor?.revision ? state.discovery : null;
  if (!retained) return message;
  return `Live refresh failed. Cached choices from ${formatDate(retained.completedAtUtc)} remain visible and usable. ${message}`;
}

function currentListField(name) {
  const input = byId(`config-${name}`);
  if (!input) return [];
  return input.value.split(/[\n,]/).map((value) => value.trim()).filter(Boolean);
}

function setListField(name, values) {
  const input = byId(`config-${name}`);
  if (input) input.value = [...new Set(values)].join(", ");
}

function savedListField(name) {
  const field = (state.editor?.fields || []).find((candidate) => candidate.name === name);
  return Array.isArray(field?.value) ? field.value.map((value) => String(value).trim()).filter(Boolean) : [];
}

function currentUserEmailOverrides() {
  const input = byId("config-UserEmailOverrides");
  if (!input || !input.value) return {};
  try {
    const parsed = JSON.parse(input.value);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    return Object.fromEntries(Object.entries(parsed).map(([id, address]) => [String(id), String(address ?? "")]));
  } catch (_) {
    return {};
  }
}

function setUserEmailOverride(userID, address) {
  if (!validPreviewUserID(userID)) return;
  const input = byId("config-UserEmailOverrides");
  if (!input) return;
  const assignments = currentUserEmailOverrides();
  if (address === "") delete assignments[userID];
  else assignments[userID] = address;
  input.value = JSON.stringify(assignments);
}

function managedUserAddressState(input, status) {
  const assigned = input.value.trim() !== "";
  const valid = !assigned || input.validity.valid;
  status.textContent = assigned && valid ? "Assigned" : assigned ? "Check address" : "Address needed";
  status.className = `state-chip ${assigned && valid ? "good" : assigned ? "bad" : "warning"}`;
  input.setAttribute("aria-invalid", String(!valid));
}

function discoveredNewsletterUsers() {
  return (state.discovery?.users || []).filter((user) => validPreviewUserID(String(user.id)));
}

function renderManagedUserDeliveryAddresses() {
  const card = byId("managed-user-delivery-addresses");
  const container = byId("managed-user-delivery-list");
  const users = discoveredNewsletterUsers()
    .filter((user) => user.needsDeliveryAddress === true)
    .sort((left, right) => left.name.localeCompare(right.name, undefined, { sensitivity: "base" }));
  card.hidden = !state.discovery || users.length === 0;
  container.replaceChildren();
  if (card.hidden) {
    setText("managed-user-delivery-count", "");
    return;
  }
  const assignments = currentUserEmailOverrides();
  const assignedCount = users.filter((user) => String(assignments[user.id] || "").trim() !== "").length;
  setText("managed-user-delivery-count", `${assignedCount} assigned · ${users.length - assignedCount} needed`);
  for (const user of users) {
    const row = document.createElement("div");
    row.className = "managed-user-delivery-row";
    row.setAttribute("role", "listitem");
    const identity = document.createElement("div");
    const label = document.createElement("label");
    const inputID = `managed-user-address-${user.id}`;
    label.htmlFor = inputID;
    label.textContent = user.name;
    const detail = document.createElement("small");
    detail.textContent = `Tautulli user ${user.id}`;
    identity.append(label, detail);
    const input = document.createElement("input");
    input.id = inputID;
    input.type = "email";
    input.maxLength = 254;
    input.autocomplete = "off";
    input.spellcheck = false;
    input.placeholder = "name@example.com";
    input.value = String(assignments[user.id] || "");
    const status = document.createElement("span");
    status.id = `${inputID}-status`;
    input.setAttribute("aria-describedby", status.id);
    managedUserAddressState(input, status);
    input.addEventListener("input", () => {
      setUserEmailOverride(user.id, input.value);
      managedUserAddressState(input, status);
      const current = currentUserEmailOverrides();
      const count = users.filter((candidate) => String(current[candidate.id] || "").trim() !== "").length;
      setText("managed-user-delivery-count", `${count} assigned · ${users.length - count} needed`);
      updateConfigSaveAvailability();
    });
    row.append(identity, input, status);
    container.append(row);
  }
}

function renderDiscoveredLibraries() {
  const container = byId("discovery-libraries");
  container.replaceChildren();
  const libraries = state.discovery?.libraries || [];
  setText("discovery-library-count", `${libraries.length} active`);
  const configured = new Set(currentListField("IncludedLibraryIds"));
  const selected = configured.size ? configured : new Set(libraries.map((item) => item.id));
  for (const item of libraries) {
    const label = document.createElement("label");
    label.className = "choice-row";
    const input = document.createElement("input");
    input.type = "checkbox";
    input.checked = selected.has(item.id);
    input.dataset.choiceId = item.id;
    const copy = document.createElement("span");
    const name = document.createElement("strong");
    name.textContent = item.name;
    const detail = document.createElement("small");
    detail.textContent = `${titleCase(item.mediaType)} · section ${item.id}${item.itemCount ? ` · ${item.itemCount} items` : ""}`;
    copy.append(name, detail);
    input.addEventListener("change", () => {
      const unknown = currentListField("IncludedLibraryIds").filter((id) => !libraries.some((library) => library.id === id));
      const known = [...container.querySelectorAll("input:checked")].map((choice) => choice.dataset.choiceId);
      setListField("IncludedLibraryIds", [...unknown, ...known]);
    });
    label.append(input, copy);
    container.append(label);
  }
}

function renderDiscoveredUsers() {
  const container = byId("discovery-users");
  container.replaceChildren();
  const users = discoveredNewsletterUsers();
  const configured = new Set(currentListField("ExcludedUserIds"));
  renderDiscoveryUserCount(users);
  const orderedUsers = [...users].sort((left, right) => {
    const leftExcluded = configured.has(left.id) || left.legacyRuleExcluded === true;
    const rightExcluded = configured.has(right.id) || right.legacyRuleExcluded === true;
    if (leftExcluded !== rightExcluded) return leftExcluded ? -1 : 1;
    return left.name.localeCompare(right.name, undefined, { sensitivity: "base" });
  });
  for (const item of orderedUsers) {
    const label = document.createElement("label");
    label.className = "choice-row";
    const input = document.createElement("input");
    input.type = "checkbox";
    const configuredByID = configured.has(item.id);
    const legacyRuleExcluded = item.legacyRuleExcluded === true;
    input.checked = configuredByID || legacyRuleExcluded;
    input.disabled = legacyRuleExcluded;
    input.dataset.choiceId = item.id;
    input.dataset.configuredId = String(configuredByID);
    label.classList.toggle("legacy-exclusion", legacyRuleExcluded);
    const copy = document.createElement("span");
    const name = document.createElement("strong");
    name.textContent = item.name;
    const detail = document.createElement("small");
    detail.textContent = `User ${item.id} · ${titleCase(item.eligibility)}${item.role ? ` · ${titleCase(item.role)}` : ""}${legacyRuleExcluded ? " · Excluded by existing config" : ""}`;
    copy.append(name, detail);
    input.addEventListener("change", () => {
      const unknown = currentListField("ExcludedUserIds").filter((id) => !users.some((user) => user.id === id));
      const known = [...container.querySelectorAll("input:checked")]
        .filter((choice) => !choice.disabled || choice.dataset.configuredId === "true")
        .map((choice) => choice.dataset.choiceId);
      setListField("ExcludedUserIds", [...unknown, ...known]);
      renderDiscoveryUserCount(users);
    });
    label.append(input, copy);
    container.append(label);
  }
}

function renderDiscoveryUserCount(users = discoveredNewsletterUsers()) {
  const current = new Set(currentListField("ExcludedUserIds"));
  const saved = new Set(savedListField("ExcludedUserIds"));
  const changed = users.some((item) => current.has(item.id) !== saved.has(item.id));
  const effective = users.filter((item) => current.has(item.id) || item.legacyRuleExcluded === true).length;
  const count = byId("discovery-user-count");
  count.replaceChildren(document.createTextNode(`${users.length} found`));
  if (effective === 0) return;
  count.append(document.createTextNode(" ● "));
  const status = document.createElement("span");
  status.className = changed ? "discovery-selected-count" : "discovery-excluded-count";
  status.textContent = `${effective} excluded${changed ? " (unsaved)" : ""}`;
  count.append(status);
}

function renderUserDatalist() {
  const list = byId("tautulli-user-choices");
  list.replaceChildren();
  for (const item of discoveredNewsletterUsers()) {
    const option = document.createElement("option");
    option.value = item.id;
    option.label = `${item.name} · ${titleCase(item.eligibility)}${item.role ? ` · ${titleCase(item.role)}` : ""}`;
    list.append(option);
  }
}

function renderUserComboboxes() {
  document.querySelectorAll("[data-user-combobox]").forEach((container) => renderUserComboboxOptions(container));
}

function renderUserComboboxOptions(container) {
  const input = container.querySelector("input");
  const list = container.querySelector(".user-combobox-options");
  const query = container.dataset.filter === "true" ? input.value.trim().toLowerCase() : "";
  const users = discoveredNewsletterUsers().filter((item) => !query || item.id.includes(query) || item.name.toLowerCase().includes(query));
  list.replaceChildren();
  if (!users.length) {
    const empty = document.createElement("p");
    empty.className = "user-combobox-empty";
    empty.textContent = state.discovery ? "No matching Tautulli user." : "Load Tautulli choices from Config to browse users.";
    list.append(empty);
    return;
  }
  for (const item of users) {
    const option = document.createElement("button");
    option.type = "button";
    option.className = "user-combobox-option";
    option.setAttribute("role", "option");
    option.setAttribute("aria-selected", String(input.value === item.id));
    option.tabIndex = -1;
    const name = document.createElement("strong");
    name.textContent = item.name;
    const detail = document.createElement("small");
    detail.textContent = `User ${item.id} - ${titleCase(item.eligibility)}${item.role ? ` - ${titleCase(item.role)}` : ""}`;
    option.append(name, detail);
    option.addEventListener("click", () => selectUserComboboxOption(container, item.id));
    option.addEventListener("keydown", (event) => navigateUserComboboxOptions(event, container, option));
    list.append(option);
  }
}

function setUserComboboxOpen(container, open) {
  const input = container.querySelector("input");
  const toggle = container.querySelector(".user-combobox-toggle");
  const list = container.querySelector(".user-combobox-options");
  if (open) renderUserComboboxOptions(container);
  list.hidden = !open;
  container.classList.toggle("open", open);
  input.setAttribute("aria-expanded", String(open));
  toggle.setAttribute("aria-expanded", String(open));
}

function selectUserComboboxOption(container, id) {
  const input = container.querySelector("input");
  input.value = id;
  container.dataset.filter = "false";
  input.dispatchEvent(new Event("input", { bubbles: true }));
  setUserComboboxOpen(container, false);
  input.focus();
}

function navigateUserComboboxOptions(event, container, option) {
  const options = [...container.querySelectorAll(".user-combobox-option")];
  const index = options.indexOf(option);
  if (event.key === "Enter" || event.key === " ") {
    event.preventDefault();
    option.click();
  } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault();
    const offset = event.key === "ArrowDown" ? 1 : -1;
    options[(index + offset + options.length) % options.length]?.focus();
  } else if (event.key === "Escape") {
    event.preventDefault();
    setUserComboboxOpen(container, false);
    container.querySelector("input").focus();
  }
}

function initializeUserCombobox(container) {
  const input = container.querySelector("input");
  const toggle = container.querySelector(".user-combobox-toggle");
  input.addEventListener("click", () => {
    if (!container.classList.contains("open")) {
      container.dataset.filter = "false";
      setUserComboboxOpen(container, true);
    }
  });
  input.addEventListener("input", () => {
    container.dataset.filter = "true";
    setUserComboboxOpen(container, true);
  });
  input.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setUserComboboxOpen(container, true);
      container.querySelector(".user-combobox-option")?.focus();
    } else if (event.key === "Escape") {
      setUserComboboxOpen(container, false);
    }
  });
  toggle.addEventListener("click", () => {
    const open = !container.classList.contains("open");
    container.dataset.filter = "false";
    setUserComboboxOpen(container, open);
    if (open) input.focus();
  });
}

async function runTautulliDiscovery(options = {}) {
  const requireConfirmation = options.requireConfirmation !== false;
  const announceGlobalStatus = options.announceGlobalStatus !== false;
  const recoverPendingPreviews = options.recoverPendingPreviews !== false;
  const discoveryAuthenticationEpoch = authenticationEpoch;
  if (state.discoveryRunning || state.verificationRunning || state.smtpVerificationRunning || state.editor?.state !== "ready" || (requireConfirmation && !byId("discovery-confirm").checked)) return false;
  let refreshed = false;
  state.discoveryError = "";
  state.discoveryRunning = true;
  renderDiscovery();
  renderVerification();
  if (announceGlobalStatus) setGlobalStatus("Loading private Tautulli choices...");
  try {
    const discovery = await request("/api/v1/discovery/tautulli", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision, confirmRealNetwork: true }),
    });
    if (discoveryAuthenticationEpoch !== authenticationEpoch || byId("app-shell").hidden) return false;
    state.discovery = discovery;
    refreshed = true;
    state.discoveryError = "";
    if (state.status) renderDashboardGreeting(state.status.observedAtUtc);
    byId("discovery-confirm").checked = false;
    if (announceGlobalStatus) setGlobalStatus("Tautulli choices loaded and retained locally.", true);
  } catch (error) {
    if (discoveryAuthenticationEpoch !== authenticationEpoch || byId("app-shell").hidden) return false;
    state.discoveryError = discoveryFailureMessage(error.message);
    if (announceGlobalStatus) setGlobalStatus(state.discoveryError, true);
  } finally {
    if (discoveryAuthenticationEpoch === authenticationEpoch && !byId("app-shell").hidden) {
      try {
        await refreshConfigurationStatus();
      } catch (_) {
        // The manual result remains visible even if the durable summary cannot be refreshed.
      }
      if (discoveryAuthenticationEpoch === authenticationEpoch && !byId("app-shell").hidden) {
        state.discoveryRunning = false;
        renderDiscovery();
        renderVerification();
        if (refreshed && recoverPendingPreviews) await recoverPendingPreviewsFromChoices(discoveryAuthenticationEpoch);
      }
    }
  }
  return refreshed;
}

function createConfigControl(field) {
  const control = document.createElement("div");
  control.className = `config-control config-control-${field.type}`;
  control.dataset.configField = field.name;
  const heading = document.createElement("span");
  heading.className = "config-control-heading";
  const label = document.createElement("strong");
  label.textContent = field.label;
  label.id = `config-label-${field.name}`;
  const key = document.createElement("small");
  key.textContent = field.required ? `${field.name} · required` : field.name;
  heading.append(label, key);
  control.append(heading);

  const id = `config-${field.name}`;
  let input;
  if (field.type === "boolean") {
    input = document.createElement("input");
    input.type = "checkbox";
    input.checked = Boolean(field.value);
    const toggle = document.createElement("label");
    toggle.className = "config-toggle";
    toggle.htmlFor = id;
    toggle.append(input, document.createElement("span"));
    const stateLabel = document.createElement("em");
    stateLabel.textContent = input.checked ? "Enabled" : "Disabled";
    input.addEventListener("change", () => { stateLabel.textContent = input.checked ? "Enabled" : "Disabled"; });
    toggle.append(stateLabel);
    control.append(toggle);
  } else if (field.type === "select") {
    input = document.createElement("select");
    for (const optionValue of field.options || []) {
      const option = document.createElement("option");
      option.value = optionValue;
      option.textContent = optionValue;
      option.selected = String(field.value) === optionValue;
      input.append(option);
    }
    control.append(input);
  } else if (field.type === "textarea") {
    input = document.createElement("textarea");
    input.rows = 6;
    input.value = field.value ?? "";
    if (field.max !== undefined) input.maxLength = Number(field.max);
    control.append(input);
  } else if (field.type === "range") {
    input = document.createElement("input");
    input.type = "range";
    input.min = String(field.min ?? 0);
    input.max = String(field.max ?? 100);
    input.step = "1";
    input.value = field.value ?? "0";
    const shell = document.createElement("span");
    shell.className = "config-range";
    const output = document.createElement("output");
    output.value = `${input.value}%`;
    output.textContent = output.value;
    input.addEventListener("input", () => {
      output.value = `${input.value}%`;
      output.textContent = output.value;
    });
    shell.append(input, output);
    control.append(shell);
  } else if (field.type === "color") {
    input = document.createElement("input");
    input.type = "color";
    input.value = field.value || "#72aef7";
    const shell = document.createElement("span");
    shell.className = "config-color";
    const output = document.createElement("output");
    output.value = input.value.toUpperCase();
    output.textContent = output.value;
    input.addEventListener("input", () => {
      output.value = input.value.toUpperCase();
      output.textContent = output.value;
    });
    shell.append(input, output);
    control.append(shell);
  } else {
    input = document.createElement("input");
    input.type = configInputType(field.type);
    input.placeholder = field.type === "secret" && field.secret?.configured
      ? "Stored value will be preserved"
      : field.type === "secret" && field.secret?.availableFromRuntime
        ? "Runtime value available · paste only to store a copy"
        : field.placeholder || "";
    if (field.type === "integer") {
      if (field.min !== undefined) input.min = String(field.min);
      if (field.max !== undefined) input.max = String(field.max);
      input.step = "1";
      input.value = field.value ?? "";
    } else if (field.type === "string-list" || field.type === "email-list") {
      input.value = Array.isArray(field.value) ? field.value.join(", ") : "";
    } else if (field.type !== "secret") {
      if (field.max !== undefined) input.maxLength = Number(field.max);
      input.value = field.value ?? "";
    }
    if (field.type === "secret") {
      input.autocomplete = "new-password";
      const shell = document.createElement("span");
      shell.className = "secret-input-shell";
      const toggle = document.createElement("button");
      toggle.type = "button";
      toggle.className = "secret-toggle-button";
      toggle.disabled = !field.secret?.configured;
      toggle.append(createMaterialIcon("visibility"));
      shell.append(input, toggle);
      control.append(shell);
      input.addEventListener("input", () => {
        const active = activeSecretReveals.get(field.name);
        if (active && input.value !== active.value) forgetSecretReveal(field.name, false);
        if (!input.value && !field.secret?.configured) input.type = "password";
        toggle.disabled = !input.value && !field.secret?.configured;
        updateSecretToggle(field, input, toggle);
      });
      toggle.addEventListener("click", () => toggleSecretVisibility(field, input, toggle));
      updateSecretToggle(field, input, toggle);
    } else {
      control.append(input);
    }
  }
  input.id = id;
  input.name = field.name;
  input.setAttribute("aria-labelledby", label.id);
  if (field.name === "CustomTextCardTitle") attachTitleGifPicker(control, input);

  if (field.type === "secret") {
    const secretLine = document.createElement("span");
    secretLine.className = "secret-state";
    const stateText = document.createElement("span");
    stateText.textContent = field.secret?.configured
      ? "Configured - hidden by default"
      : field.secret?.availableFromRuntime
        ? "Available from this runtime - not copied"
        : "Not configured";
    stateText.id = `config-secret-state-${field.name}`;
    secretLine.append(stateText);
    if (field.secret?.configured) {
      const clearLabel = document.createElement("label");
      clearLabel.className = "secret-clear";
      const clear = document.createElement("input");
      clear.type = "checkbox";
      clear.id = `config-clear-${field.name}`;
      clearLabel.append(clear, " Clear stored value");
      secretLine.append(clearLabel);
      input.addEventListener("input", () => { if (input.value) clear.checked = false; });
      clear.addEventListener("change", () => {
        if (clear.checked) {
          forgetSecretReveal(field.name, true);
          input.value = "";
          input.type = "password";
          const toggle = control.querySelector(".secret-toggle-button");
          if (toggle) updateSecretToggle(field, input, toggle);
        }
      });
    }
    control.append(secretLine);
  }
  if (field.help) {
    const help = document.createElement("span");
    help.className = "config-help";
    help.textContent = field.help;
    control.append(help);
  }
  const error = document.createElement("span");
  error.className = "config-field-error";
  error.id = `config-error-${field.name}`;
  control.append(error);
  return control;
}

function attachTitleGifPicker(control, titleInput) {
  const configured = String(configEditorValue("CustomTextCardTitleGif") || "none");
  const selectedID = titleGifChoices.some((choice) => choice.id === configured) ? configured : "none";
  const assetInput = document.createElement("input");
  assetInput.type = "hidden";
  assetInput.id = "config-CustomTextCardTitleGif";
  assetInput.name = "CustomTextCardTitleGif";
  assetInput.value = selectedID;

  const shell = document.createElement("div");
  shell.className = "title-gif-field";
  titleInput.replaceWith(shell);
  shell.append(titleInput);

  const trigger = document.createElement("button");
  trigger.type = "button";
  trigger.className = "title-gif-trigger";
  trigger.dataset.materialSymbol = "add_reaction";
  trigger.dataset.fill = "0";
  trigger.dataset.weight = "400";
  trigger.dataset.grade = "0";
  trigger.dataset.opticalSize = "24";
  trigger.setAttribute("aria-haspopup", "listbox");
  trigger.setAttribute("aria-expanded", "false");
  trigger.setAttribute("aria-controls", "custom-title-gif-picker");
  const reactionIcon = createMaterialIcon("add-reaction");
  trigger.append(reactionIcon);

  const picker = document.createElement("div");
  picker.className = "title-gif-picker";
  picker.id = "custom-title-gif-picker";
  picker.dataset.titleGifPicker = "";
  picker.setAttribute("role", "listbox");
  picker.setAttribute("aria-label", "Optional title GIF");
  picker.hidden = true;

  const heading = document.createElement("div");
  heading.className = "title-gif-picker-heading";
  const headingText = document.createElement("strong");
  headingText.textContent = "Title GIF";
  const headingHint = document.createElement("small");
  headingHint.textContent = "18 x 18 px · select again to remove";
  heading.append(headingText, headingHint);
  picker.append(heading);

  const grid = document.createElement("div");
  grid.className = "title-gif-options";
  const optionButtons = [];
  const selectChoice = (choice, focus = false) => {
    assetInput.value = choice.id;
    trigger.classList.toggle("selected", choice.id !== "none");
    trigger.setAttribute("aria-label", choice.id === "none" ? "Choose an optional title GIF; none selected" : `Change optional title GIF; ${choice.label} selected`);
    trigger.replaceChildren();
    if (choice.file) {
      const selectedImage = document.createElement("img");
      selectedImage.className = "title-gif-trigger-image";
      selectedImage.src = `/media/${choice.file}`;
      selectedImage.alt = "";
      selectedImage.width = 24;
      selectedImage.height = 24;
      trigger.append(selectedImage);
    } else {
      trigger.append(reactionIcon);
    }
    let selectedButton = null;
    for (const button of optionButtons) {
      const selected = button.dataset.titleGifId === choice.id;
      button.classList.toggle("selected", selected);
      button.setAttribute("aria-selected", String(selected));
      button.setAttribute("aria-label", selected ? `${button.dataset.titleGifLabel} selected; activate again to remove` : button.dataset.titleGifLabel);
      button.tabIndex = selected ? 0 : -1;
      if (selected) selectedButton = button;
      if (selected && focus) button.focus();
    }
    if (!selectedButton && optionButtons[0]) optionButtons[0].tabIndex = 0;
  };
  const closePicker = (restoreFocus = false) => {
    picker.hidden = true;
    shell.classList.remove("open");
    trigger.setAttribute("aria-expanded", "false");
    if (restoreFocus) trigger.focus();
  };
  const openPicker = () => {
    document.querySelectorAll("[data-title-gif-picker]").forEach((element) => {
      if (element !== picker) element.hidden = true;
    });
    picker.hidden = false;
    shell.classList.add("open");
    trigger.setAttribute("aria-expanded", "true");
    (optionButtons.find((button) => button.getAttribute("aria-selected") === "true") || optionButtons[0])?.focus();
  };

  for (const choice of titleGifChoices) {
    const option = document.createElement("button");
    option.type = "button";
    option.className = "title-gif-option";
    option.dataset.titleGifId = choice.id;
    option.dataset.titleGifLabel = choice.label;
    option.setAttribute("role", "option");
    const thumbnail = document.createElement("span");
    thumbnail.className = "title-gif-thumbnail";
    const image = document.createElement("img");
    image.src = `/media/${choice.file}`;
    image.alt = "";
    image.width = 42;
    image.height = 42;
    thumbnail.append(image);
    const optionLabel = document.createElement("span");
    optionLabel.textContent = choice.label;
    option.append(thumbnail, optionLabel);
    option.addEventListener("click", () => {
      selectChoice(assetInput.value === choice.id ? noTitleGifChoice : choice);
      closePicker(true);
    });
    option.addEventListener("keydown", (event) => {
      const index = optionButtons.indexOf(option);
      let target = -1;
      if (["Enter", " "].includes(event.key)) {
        event.preventDefault();
        selectChoice(assetInput.value === choice.id ? noTitleGifChoice : choice);
        closePicker(true);
        return;
      }
      if (["ArrowRight", "ArrowDown"].includes(event.key)) target = (index + 1) % optionButtons.length;
      if (["ArrowLeft", "ArrowUp"].includes(event.key)) target = (index - 1 + optionButtons.length) % optionButtons.length;
      if (event.key === "Home") target = 0;
      if (event.key === "End") target = optionButtons.length - 1;
      if (event.key === "Escape") {
        event.preventDefault();
        closePicker(true);
        return;
      }
      if (target >= 0) {
        event.preventDefault();
        optionButtons[target].focus();
      }
    });
    optionButtons.push(option);
    grid.append(option);
  }
  picker.append(grid);
  trigger.addEventListener("click", () => picker.hidden ? openPicker() : closePicker());
  trigger.addEventListener("keydown", (event) => {
    if (["Delete", "Backspace"].includes(event.key) && assetInput.value !== "none") {
      event.preventDefault();
      selectChoice(noTitleGifChoice);
      closePicker();
      return;
    }
    if (["Enter", " "].includes(event.key)) {
      event.preventDefault();
      picker.hidden ? openPicker() : closePicker(true);
      return;
    }
    if (["ArrowDown", "ArrowUp"].includes(event.key)) {
      event.preventDefault();
      openPicker();
    }
  });
  shell.append(trigger, picker, assetInput);
  selectChoice(titleGifChoices.find((choice) => choice.id === selectedID) || noTitleGifChoice);
}

function updateSecretToggle(field, input, button) {
  const hasValue = input.value !== "";
  const visible = hasValue && input.type === "text";
  button.classList.toggle("visible", visible);
  button.setAttribute("aria-pressed", String(visible));
  if (visible) button.setAttribute("aria-label", `Hide ${field.label}`);
  else if (hasValue) button.setAttribute("aria-label", `Show ${field.label}`);
  else button.setAttribute("aria-label", `Reveal saved ${field.label}`);
}

function toggleSecretVisibility(field, input, button) {
  if (input.value) {
    input.type = input.type === "password" ? "text" : "password";
    updateSecretToggle(field, input, button);
    return;
  }
  if (field.secret?.configured) openSecretReveal(field, input, button);
}

function openSecretReveal(field, input, button) {
  pendingSecretReveal = { field, input, button };
  const passwordRequired = Boolean(state.authAccess?.authenticationRequired);
  byId("secret-reveal-title").textContent = `Reveal ${field.label}`;
  byId("secret-reveal-eyebrow").textContent = passwordRequired ? "Administrator confirmation" : "Explicit local reveal";
  byId("secret-reveal-copy").textContent = passwordRequired
    ? "Re-enter your Manager administrator password. Only this value will be returned, and it will clear automatically after 30 seconds."
    : "Confirm this one local reveal. Only the selected value will be returned, and it will clear automatically after 30 seconds.";
  byId("secret-reveal-message").textContent = "";
  const passwordInput = byId("secret-reveal-password");
  passwordInput.value = "";
  concealMaskedInputs(byId("secret-reveal-form"));
  passwordInput.hidden = !passwordRequired;
  passwordInput.closest(".masked-input-shell").hidden = !passwordRequired;
  passwordInput.required = passwordRequired;
  byId("secret-reveal-password-label").hidden = !passwordRequired;
  byId("secret-reveal-dialog").showModal();
  (passwordRequired ? passwordInput : byId("secret-reveal-submit")).focus();
}

async function submitSecretReveal(event) {
  event.preventDefault();
  const target = pendingSecretReveal;
  if (!target) return;
  const submit = byId("secret-reveal-submit");
  const passwordInput = byId("secret-reveal-password");
  submit.disabled = true;
  const passwordRequired = Boolean(state.authAccess?.authenticationRequired);
  setSwappingButtonText("secret-reveal-submit", passwordRequired ? "Verifying..." : "Revealing...");
  byId("secret-reveal-message").textContent = "";
  try {
    const result = await request(`/api/v1/config/secrets/${encodeURIComponent(target.field.name)}/reveal`, {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision, password: passwordInput.value }),
    });
    passwordInput.value = "";
    clearAllRevealedSecrets();
    target.input.value = result.value;
    target.input.type = "text";
    const timer = setTimeout(() => forgetSecretReveal(target.field.name, true), 30000);
    activeSecretReveals.set(target.field.name, { value: result.value, input: target.input, button: target.button, timer });
    const stateText = byId(`config-secret-state-${target.field.name}`);
    if (stateText) stateText.textContent = "Revealed temporarily - clears in 30 seconds";
    updateSecretToggle(target.field, target.input, target.button);
    byId("secret-reveal-dialog").close();
    target.input.focus();
    setGlobalStatus(`${target.field.label} revealed temporarily.`, true);
  } catch (error) {
    passwordInput.value = "";
    byId("secret-reveal-message").textContent = error.message;
    (passwordRequired ? passwordInput : submit).focus();
  } finally {
    submit.disabled = false;
    setSwappingButtonText("secret-reveal-submit", "Reveal for 30 seconds");
  }
}

function forgetSecretReveal(name, clearValue) {
  const active = activeSecretReveals.get(name);
  if (!active) return;
  clearTimeout(active.timer);
  activeSecretReveals.delete(name);
  if (clearValue && active.input.value === active.value) active.input.value = "";
  active.input.type = "password";
  const field = state.editor?.fields.find((candidate) => candidate.name === name);
  const stateText = byId(`config-secret-state-${name}`);
  if (stateText) stateText.textContent = "Configured - hidden by default";
  if (field) updateSecretToggle(field, active.input, active.button);
}

function clearAllRevealedSecrets() {
  for (const name of [...activeSecretReveals.keys()]) forgetSecretReveal(name, true);
}

function closeSecretRevealDialog() {
  byId("secret-reveal-password").value = "";
  concealMaskedInputs(byId("secret-reveal-form"));
  byId("secret-reveal-message").textContent = "";
  pendingSecretReveal = null;
  if (byId("secret-reveal-dialog").open) byId("secret-reveal-dialog").close();
}

function configInputType(type) {
  if (["url", "email", "time", "password", "color"].includes(type)) return type;
  if (type === "integer") return "number";
  if (type === "secret") return "password";
  return "text";
}

function collectConfigSaveRequest() {
  const values = {};
  const secrets = {};
  for (const field of state.editor.fields) {
    const input = byId(`config-${field.name}`);
    if (field.type === "secret") {
      const clear = byId(`config-clear-${field.name}`);
      if (clear?.checked) secrets[field.name] = { action: "clear" };
      else if (activeSecretReveals.get(field.name)?.value === input.value) secrets[field.name] = { action: "preserve" };
      else if (input.value !== "") secrets[field.name] = { action: "replace", value: input.value };
      else secrets[field.name] = { action: "preserve" };
    } else if (field.type === "boolean") {
      values[field.name] = input.checked;
    } else if (field.type === "integer" || field.type === "range") {
      values[field.name] = input.value === "" ? null : Number(input.value);
    } else if (field.type === "string-list" || field.type === "email-list") {
      values[field.name] = input.value.split(/[\n,]/).map((value) => value.trim()).filter(Boolean);
    } else if (field.type === "user-email-map") {
      values[field.name] = currentUserEmailOverrides();
    } else {
      values[field.name] = input.value;
    }
  }
  return { expectedRevision: state.editor.revision, values, secrets };
}

const setupWorkflowSteps = ["choices", "lan", "smtp", "previews", "cache"];

function beginSetupWorkflow(plan) {
  state.setupWorkflowRunning = Boolean(plan?.runDiscovery || plan?.runIntegration || plan?.runSmtp || plan?.generatePreviews || plan?.warmCache || plan?.verifyCache);
  renderSetupWorkflow();
}

function updateSetupWorkflowStep(name, stepState, summary) {
  if (!state.setupWorkflow?.steps?.[name]) return;
  state.setupWorkflow.steps[name] = { state: stepState, summary };
  renderSetupWorkflow();
}

function renderSetupWorkflow() {
  const panel = byId("setup-workflow");
  if (!panel) return;
  if (!state.setupWorkflow) {
    panel.hidden = true;
    return;
  }
  panel.hidden = false;
  const presentation = setupWorkflowPresentation();
  setChip("setup-workflow-chip", presentation.label, presentation.tone);
  setText("setup-workflow-summary", presentation.summary);
  for (const name of setupWorkflowSteps) {
    const step = state.setupWorkflow.steps[name] || { state: "not-run", summary: "This check has not been recorded for the saved configuration." };
    setSwappingText(`setup-${name}-summary`, step.summary);
    const tone = step.state === "passed" ? "good" : step.state === "failed" ? "bad"
      : step.state === "waiting" ? "waiting" : step.state === "running" ? "pending"
        : step.state === "warning" ? "warning" : "neutral";
    const label = name === "cache" && state.cache?.enabled === false ? "Disabled" : titleCase(step.state);
    setChip(`setup-${name}-chip`, label, tone);
    const row = byId(`setup-${name}-step`);
    row.classList.toggle("active", step.state === "running");
  }
  renderDashboardConfigStatus();
}

async function refreshConfigurationStatus() {
  const configurationStatus = await request("/api/v1/config/status");
  state.setupWorkflow = configurationStatus?.available ? configurationStatus : null;
  state.cache = configurationStatus?.cache || null;
  renderSetupWorkflow();
}

async function retainSkippedPreviewStatus(revision, reason) {
  try {
    const configurationStatus = await request("/api/v1/config/status/previews/skipped", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: revision, reason }),
    });
    state.setupWorkflow = configurationStatus?.available ? configurationStatus : state.setupWorkflow;
    state.cache = configurationStatus?.cache || state.cache;
  } catch (_) {
    // The local result remains visible; a later refresh will load the durable server record.
  }
  renderSetupWorkflow();
}

async function startCacheWarmOperation(revision) {
  if (!revision || state.editor?.state !== "ready" || operationIsActive(state.operation) || scheduleOperationIsActive(state.scheduleOperation)) return false;
  state.operationStarting = true;
  state.operationStartingType = "cache-warm";
  updateSetupWorkflowStep("cache", "running", "Refreshing cache coverage for every included user's selected-library newsletter items...");
  renderOperations();
  renderVerification();
  try {
    state.operation = await request("/api/v1/operations", {
      method: "POST",
      body: JSON.stringify({ type: "cache-warm", expectedRevision: revision }),
    });
    manageOperationPolling();
    return true;
  } catch (error) {
    updateSetupWorkflowStep("cache", "failed", error.message);
    return false;
  } finally {
    state.operationStarting = false;
    state.operationStartingType = "";
    renderOperations();
    renderVerification();
  }
}

async function recoverPendingCacheWarm(expectedAuthenticationEpoch = authenticationEpoch) {
  if (expectedAuthenticationEpoch !== authenticationEpoch || byId("app-shell").hidden) return;
  const cacheState = state.setupWorkflow?.steps?.cache?.state || "";
  if (!["waiting", "running"].includes(cacheState) || state.cache?.enabled === false || state.editor?.state !== "ready"
      || operationIsActive(state.operation) || scheduleOperationIsActive(state.scheduleOperation)) return;
  await startCacheWarmOperation(state.editor.revision);
}

async function runPostSaveSetup(revision, plan) {
  let previewStarted = false;
  let cacheStarted = false;
  let discovered = state.discovery?.configRevision === revision ? state.discovery : null;
  let discoveryFailed = false;
  if (plan.runDiscovery) {
    state.discoveryError = "";
    state.discoveryRunning = true;
    updateSetupWorkflowStep("choices", "running", "Loading active libraries, users, and any explicit owner or administrator role...");
    renderDiscovery();
    renderVerification();
    try {
      discovered = await request("/api/v1/discovery/tautulli", {
        method: "POST",
        body: JSON.stringify({ expectedRevision: revision, confirmRealNetwork: true }),
      });
      state.discovery = discovered;
      state.discoveryError = "";
      if (state.status) renderDashboardGreeting(state.status.observedAtUtc);
      updateSetupWorkflowStep("choices", "passed", `${discovered.libraries?.length || 0} active libraries and ${discovered.users?.length || 0} users loaded and retained locally.`);
    } catch (error) {
      discoveryFailed = true;
      state.discoveryError = discoveryFailureMessage(error.message);
      updateSetupWorkflowStep("choices", "failed", state.discoveryError);
    } finally {
      state.discoveryRunning = false;
      renderDiscovery();
      renderVerification();
    }
  }

  if (plan.runIntegration) {
    state.verificationRunning = true;
    updateSetupWorkflowStep("lan", "running", "Testing the saved Tautulli and direct Plex endpoints...");
    renderDiscovery();
    renderVerification();
    try {
      const result = await request("/api/v1/checks/integrations", {
        method: "POST",
        body: JSON.stringify({ expectedRevision: revision, confirmRealNetwork: true }),
      });
      state.verification = { ...state.verification, last: result };
      updateSetupWorkflowStep("lan", result.overall, result.overall === "passed"
        ? "Tautulli and direct Plex verification passed. Detailed evidence is available under Verify."
        : "The connection checks completed with a result that needs review under Verify.");
    } catch (error) {
      updateSetupWorkflowStep("lan", "failed", error.message);
    } finally {
      state.verificationRunning = false;
      renderDiscovery();
      renderVerification();
    }
  }

  if (plan.runSmtp) {
    state.smtpVerificationRunning = true;
    updateSetupWorkflowStep("smtp", "running", "Checking SMTP reachability and STARTTLS without authenticating or sending...");
    renderDiscovery();
    renderVerification();
    try {
      const result = await request("/api/v1/checks/smtp-network", {
        method: "POST",
        body: JSON.stringify({ expectedRevision: revision, confirmRealNetwork: true }),
      });
      state.verification = { ...state.verification, smtp: result };
      updateSetupWorkflowStep("smtp", result.overall, result.summary);
    } catch (error) {
      updateSetupWorkflowStep("smtp", "failed", error.message);
    } finally {
      state.smtpVerificationRunning = false;
      renderDiscovery();
      renderVerification();
    }
  }

  if (plan.warmCache) {
    if (discoveryFailed) {
      updateSetupWorkflowStep("cache", "failed", "Deleted-item cache refresh could not start because the included user and library choices were unavailable.");
    } else if (operationIsActive(state.operation) || scheduleOperationIsActive(state.scheduleOperation)) {
      updateSetupWorkflowStep("cache", "failed", "Deleted-item cache refresh could not start while another local operation was active.");
    } else {
      cacheStarted = await startCacheWarmOperation(revision);
    }
  } else if (plan.verifyCache) {
    await runCacheVerification({ automatic: true, expectedRevision: revision });
  }

  const suggestedUserID = discovered?.suggestedPreviewUserId || "";
  if (plan.generatePreviews && !cacheStarted && discoveryFailed) {
    updateSetupWorkflowStep("previews", "skipped", "Preview generation was skipped because Tautulli choices could not be refreshed. Resolve the discovery result, then use Refresh Tautulli choices to continue without another save.");
    await retainSkippedPreviewStatus(revision, "discovery-failed");
  } else if (plan.generatePreviews && !cacheStarted && !discovered) {
    updateSetupWorkflowStep("previews", "skipped", "Preview generation was skipped because no retained Tautulli choices are available. Refresh Tautulli choices to continue without another save.");
    await retainSkippedPreviewStatus(revision, "choices-unavailable");
  } else if (plan.generatePreviews && !cacheStarted && !validPreviewUserID(suggestedUserID)) {
    updateSetupWorkflowStep("previews", "skipped", "Tautulli did not expose one unambiguous owner or administrator ID. Choose a user under Previews to generate the six local states manually.");
    await retainSkippedPreviewStatus(revision, "owner-not-found");
  } else if (plan.generatePreviews && !cacheStarted && (operationIsActive(state.operation) || scheduleOperationIsActive(state.scheduleOperation))) {
    updateSetupWorkflowStep("previews", "skipped", "Another Manager or schedule operation is active. Generate previews manually after it finishes.");
    await retainSkippedPreviewStatus(revision, "operation-active");
  } else if (plan.generatePreviews && !cacheStarted) {
    state.operationStarting = true;
    state.operationStartingType = "preview-all";
    updateSetupWorkflowStep("previews", "running", "Starting six local newsletter previews for the verified owner or administrator...");
    renderOperations();
    try {
      state.operation = await request("/api/v1/operations", {
        method: "POST",
        body: JSON.stringify({ type: "preview-all", expectedRevision: revision, userId: suggestedUserID, confirmNoSend: true }),
      });
      previewStarted = true;
      updateSetupWorkflowStep("previews", "running", "Six-state local preview generation started. No email will be sent; progress is available under Previews.");
      manageOperationPolling();
    } catch (error) {
      updateSetupWorkflowStep("previews", error.code === "operation-busy" || error.code === "schedule-busy" ? "skipped" : "failed", error.message);
    } finally {
      state.operationStarting = false;
      state.operationStartingType = "";
      renderOperations();
    }
  }

  if (state.setupWorkflow) state.setupWorkflow.running = false;
  state.setupWorkflowRunning = false;
  try {
    await refreshConfigurationStatus();
  } catch (_) {
    renderSetupWorkflow();
  }
  try {
    const [status, verification] = await Promise.all([
      request("/api/v1/status"),
      request("/api/v1/checks/integrations"),
    ]);
    state.status = status;
    state.verification = verification || { last: null, smtp: null };
    renderStatus();
    renderVerification();
  } catch (_) {
    renderDashboardConfigStatus();
    renderIntegrationStatus();
  }
  try {
    const diagnostics = await request("/api/v1/diagnostics");
    const diagnosticMaximum = Number(diagnostics.maximumEntries) || 20;
    state.diagnostics = { ...diagnostics, maximumEntries: diagnosticMaximum, events: (diagnostics.events || []).slice(0, diagnosticMaximum) };
    renderAbout();
  } catch (_) {
    // Diagnostics are supplementary; the individual setup results remain visible.
  }
  return { cachePending: cacheStarted, previewPending: previewStarted };
}

async function recoverPendingPreviewsFromChoices(expectedAuthenticationEpoch = authenticationEpoch) {
  if (expectedAuthenticationEpoch !== authenticationEpoch || byId("app-shell").hidden) return;
  const revision = state.editor?.revision || "";
  const previewState = state.setupWorkflow?.steps?.previews?.state || "not-run";
  const suggestedUserID = state.discovery?.configRevision === revision ? state.discovery.suggestedPreviewUserId || "" : "";
  if (!["not-run", "waiting", "failed", "skipped"].includes(previewState)
      || !validPreviewUserID(suggestedUserID)
      || operationIsActive(state.operation)
      || scheduleOperationIsActive(state.scheduleOperation)) return;

  state.operationStarting = true;
  state.operationStartingType = "preview-all";
  updateSetupWorkflowStep("previews", "running", "Starting six local newsletter previews from the refreshed choices...");
  renderOperations();
  try {
    const operation = await request("/api/v1/operations", {
      method: "POST",
      body: JSON.stringify({ type: "preview-all", expectedRevision: revision, userId: suggestedUserID, confirmNoSend: true }),
    });
    if (expectedAuthenticationEpoch !== authenticationEpoch || byId("app-shell").hidden) return;
    state.operation = operation;
    updateSetupWorkflowStep("previews", "running", "Six-state local preview generation started. No email will be sent; progress is available under Previews.");
    manageOperationPolling();
    setGlobalStatus("Preview generation resumed without another configuration save.", true);
  } catch (error) {
    if (expectedAuthenticationEpoch !== authenticationEpoch || byId("app-shell").hidden) return;
    updateSetupWorkflowStep("previews", error.code === "operation-busy" || error.code === "schedule-busy" ? "skipped" : "failed", error.message);
  } finally {
    if (expectedAuthenticationEpoch === authenticationEpoch && !byId("app-shell").hidden) {
      state.operationStarting = false;
      state.operationStartingType = "";
      renderOperations();
    }
  }
}

function customTextCardBodyMissing() {
  return Boolean(byId("config-CustomTextCardEnabled")?.checked && !byId("config-CustomTextCardBody")?.value.trim());
}

function updateConfigSaveAvailability() {
  const button = byId("config-save-button");
  if (!button) return;
  const missing = customTextCardBodyMissing();
  const enabled = Boolean(byId("config-CustomTextCardEnabled")?.checked);
  const input = byId("config-CustomTextCardBody");
  const control = document.querySelector('[data-config-field="CustomTextCardBody"]');
  const error = byId("config-error-CustomTextCardBody");
  button.disabled = button.dataset.busy === "true" || missing;
  if (input) {
    input.required = enabled;
    input.setAttribute("aria-required", String(enabled));
  }
  if (missing && error) {
    error.textContent = "Card body text is required when the custom text card is enabled.";
    error.dataset.liveValidation = "true";
    input?.setAttribute("aria-invalid", "true");
    if (input) input.dataset.liveValidation = "true";
    control?.classList.add("invalid");
  } else if (error?.dataset.liveValidation === "true") {
    error.textContent = "";
    delete error.dataset.liveValidation;
    if (input?.dataset.liveValidation === "true") {
      input.removeAttribute("aria-invalid");
      delete input.dataset.liveValidation;
      control?.classList.remove("invalid");
    }
  }
}

function savedWithoutVerificationMessage(plan) {
  switch (plan?.confirmationCode) {
  case "cache-enabled": return "Cache enabled.";
  case "cache-disabled": return "Cache disabled.";
  case "cache-updated": return "Cache settings saved.";
  default: {
    const categories = plan?.changedCategories || [];
    if (categories.length === 1 && categories[0] === "email") return "Email settings saved.";
    if (categories.length === 1 && categories[0] === "schedule") return "Schedule settings saved.";
    if (categories.length === 1 && categories[0] === "newsletter") return "Newsletter delivery settings saved.";
    return "Configuration saved. Existing checks and previews remain valid.";
  }
  }
}

async function submitConfig(event) {
  event.preventDefault();
  if (customTextCardBodyMissing()) {
    updateConfigSaveAvailability();
    return;
  }
  clearConfigErrors();
  const saveButton = byId("config-save-button");
  saveButton.dataset.busy = "true";
  updateConfigSaveAvailability();
  byId("config-reset-button").disabled = true;
  setSwappingButtonText("config-save-button", "Saving...");
  setGlobalStatus("Validating local configuration...");
  try {
    const result = await request("/api/v1/config", { method: "PUT", body: JSON.stringify(collectConfigSaveRequest()) });
    state.editor = result.editor;
    if (!result.saved) {
      if (!result.postSave?.verifyCache) {
        setGlobalStatus("No material configuration changes were found. No checks or preview work ran.", true);
        return;
      }
      beginSetupWorkflow(result.postSave);
      setGlobalStatus("Configuration is unchanged. Running the full local cache verification...");
      await runCacheVerification({ automatic: true, expectedRevision: result.editor.revision });
      state.setupWorkflowRunning = false;
      setGlobalStatus("Configuration is unchanged and the full local cache verification finished.", true);
      return;
    }
    await loadAll();
    selectView("configuration");
    beginSetupWorkflow(result.postSave);
    if (!result.postSave?.materialChange) {
      setGlobalStatus(result.backup ? "Configuration normalized and backed up. No checks or preview work were needed." : "Configuration normalized. No checks or preview work were needed.", true);
      return;
    }
    const hasPostSaveWork = Boolean(result.postSave.runDiscovery || result.postSave.runIntegration || result.postSave.runSmtp || result.postSave.generatePreviews || result.postSave.warmCache || result.postSave.verifyCache);
    if (!hasPostSaveWork) {
      setGlobalStatus(savedWithoutVerificationMessage(result.postSave), true);
      return;
    }
    setGlobalStatus(result.backup ? "Configuration saved and backed up. Running only affected checks..." : "Configuration saved. Running only affected checks...");
    const setup = await runPostSaveSetup(result.editor.revision, result.postSave);
    setGlobalStatus(setup.cachePending
      ? "Deleted-item cache refresh is running. Full local cache verification will follow automatically."
      : setup.previewPending
        ? "Preview generation is running. Review it under Previews when complete."
        : "Affected save verification finished. Review the results above.", true);
  } catch (error) {
    showConfigErrors(error.message, error.fields);
    setGlobalStatus(error.message, true);
  } finally {
    delete saveButton.dataset.busy;
    updateConfigSaveAvailability();
    byId("config-reset-button").disabled = false;
    setSwappingButtonText("config-save-button", "Validate, save, and verify");
  }
}

function showConfigErrors(message, fields = {}, scroll = true) {
  const alert = byId("config-errors");
  const list = byId("config-error-list");
  list.replaceChildren();
  const names = Object.keys(fields).sort();
  if (!names.length) {
    const item = document.createElement("li");
    item.textContent = message;
    list.append(item);
  }
  for (const name of names) {
    const item = document.createElement("li");
    const field = state.editor.fields.find((candidate) => candidate.name === name);
    item.textContent = `${field?.label || name}: ${fields[name]}`;
    list.append(item);
    const controlName = name === "CustomTextCardTitleGif" ? "CustomTextCardTitle" : name;
    const control = document.querySelector(`[data-config-field="${CSS.escape(controlName)}"]`);
    control?.classList.add("invalid");
    const input = byId(`config-${name}`);
    input?.setAttribute("aria-invalid", "true");
    const error = byId(`config-error-${controlName}`);
    if (error) error.textContent = fields[name];
  }
  alert.hidden = false;
  if (scroll) alert.scrollIntoView({ block: "start" });
}

function clearConfigErrors() {
  byId("config-errors").hidden = true;
  byId("config-error-list").replaceChildren();
  document.querySelectorAll("[data-config-field]").forEach((control) => control.classList.remove("invalid"));
  document.querySelectorAll("[data-config-field] input, [data-config-field] select, [data-config-field] textarea").forEach((input) => input.removeAttribute("aria-invalid"));
  document.querySelectorAll(".config-field-error").forEach((error) => { error.textContent = ""; });
}

function renderBackups() {
  const list = byId("backup-list");
  list.replaceChildren();
  setText("backup-count", state.backups.length ? `${state.backups.length} / ${state.backupMaximum} · newest first` : `0 / ${state.backupMaximum}`);
  if (!state.backups.length) {
    const empty = document.createElement("div");
    empty.className = "config-empty";
    empty.textContent = "No backup exists yet. The first update to an existing config.json creates one automatically.";
    list.append(empty);
    return;
  }
  for (const backup of state.backups) {
    const row = document.createElement("article");
    row.className = "backup-row";
    const copy = document.createElement("div");
    const title = document.createElement("strong");
    title.textContent = formatDate(backup.createdAtUtc);
    const detail = document.createElement("small");
    detail.textContent = `${formatBytes(backup.sizeBytes)} · revision ${String(backup.revision || "").slice(0, 10)}`;
    copy.append(title, detail);
    const restoreButton = document.createElement("button");
    restoreButton.type = "button";
    restoreButton.className = "button button-secondary";
    restoreButton.textContent = "Restore";
    restoreButton.setAttribute("aria-label", `Restore configuration backup from ${formatDate(backup.createdAtUtc)}`);
    const deleteButton = document.createElement("button");
    deleteButton.type = "button";
    deleteButton.className = "button button-danger";
    deleteButton.textContent = "Delete";
    deleteButton.setAttribute("aria-label", `Delete configuration backup from ${formatDate(backup.createdAtUtc)}`);
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "button button-secondary";
    cancel.textContent = "Cancel";
    cancel.hidden = true;
    const actions = document.createElement("div");
    actions.className = "backup-actions";
    const resetConfirmation = () => {
      delete row.dataset.backupAction;
      row.classList.remove("armed");
      restoreButton.hidden = false;
      restoreButton.className = "button button-secondary";
      setSwappingButtonElementText(restoreButton, "Restore");
      restoreButton.setAttribute("aria-label", `Restore configuration backup from ${formatDate(backup.createdAtUtc)}`);
      deleteButton.hidden = false;
      deleteButton.className = "button button-danger";
      setSwappingButtonElementText(deleteButton, "Delete");
      deleteButton.setAttribute("aria-label", `Delete configuration backup from ${formatDate(backup.createdAtUtc)}`);
      cancel.hidden = true;
    };
    restoreButton.addEventListener("click", () => {
      if (row.dataset.backupAction === "restore") {
        restoreBackup(backup, restoreButton, cancel);
        return;
      }
      row.dataset.backupAction = "restore";
      row.classList.add("armed");
      deleteButton.hidden = true;
      restoreButton.className = "button button-danger";
      setSwappingButtonElementText(restoreButton, "Confirm restore");
      restoreButton.setAttribute("aria-label", `Confirm restore of configuration backup from ${formatDate(backup.createdAtUtc)}`);
      cancel.hidden = false;
    });
    deleteButton.addEventListener("click", () => {
      if (row.dataset.backupAction === "delete") {
        deleteBackup(backup, deleteButton, cancel);
        return;
      }
      row.dataset.backupAction = "delete";
      row.classList.add("armed");
      restoreButton.hidden = true;
      setSwappingButtonElementText(deleteButton, "Confirm delete");
      deleteButton.setAttribute("aria-label", `Permanently delete configuration backup from ${formatDate(backup.createdAtUtc)}`);
      cancel.hidden = false;
    });
    cancel.addEventListener("click", resetConfirmation);
    actions.append(cancel, restoreButton, deleteButton);
    row.append(copy, actions);
    list.append(row);
  }
}

async function deleteBackup(backup, button, cancel) {
  button.disabled = true;
  cancel.disabled = true;
  setSwappingButtonElementText(button, "Deleting...");
  setGlobalStatus("Deleting the selected local configuration backup...");
  try {
    await request(`/api/v1/config/backups/${encodeURIComponent(backup.id)}`, { method: "DELETE" });
    const result = await request("/api/v1/config/backups");
    state.backupMaximum = Number(result.maximumEntries) || 10;
    state.backups = (result.backups || []).slice(0, state.backupMaximum);
    renderBackups();
    setGlobalStatus("Configuration backup deleted permanently.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
    button.disabled = false;
    cancel.disabled = false;
    setSwappingButtonElementText(button, "Confirm delete");
  }
}

async function restoreBackup(backup, button, cancel) {
  button.disabled = true;
  cancel.disabled = true;
  setSwappingButtonElementText(button, "Restoring...");
  setGlobalStatus("Validating and restoring the selected backup...");
  try {
    const result = await request(`/api/v1/config/backups/${encodeURIComponent(backup.id)}/restore`, {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision }),
    });
    await loadAll();
    selectView("configuration");
    setGlobalStatus(result.safetyBackup ? "Backup restored. The replaced configuration was saved as a new safety backup." : "Backup restored.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    button.disabled = false;
    cancel.disabled = false;
    setSwappingButtonElementText(button, "Restore");
  }
}

function verificationResultTone(checkState) {
  if (checkState === "passed") return "good";
  if (checkState === "failed") return "bad";
  if (checkState === "waiting") return "waiting";
  if (checkState === "running") return "pending";
  if (checkState === "warning") return "warning";
  return "neutral";
}

function prepareVerificationResults(container) {
  Array.from(container.children).forEach((child) => { child.dataset.verificationCurrent = "false"; });
}

function finishVerificationResults(container) {
  Array.from(container.children).forEach((child) => {
    if (child.dataset.verificationCurrent !== "true") child.remove();
  });
}

function appendVerificationResult(container, heading, checkState, summaryText) {
  const key = `result:${heading}`;
  let card = Array.from(container.children).find((child) => child.dataset.verificationKey === key);
  if (!card) {
    card = document.createElement("article");
    card.dataset.verificationKey = key;
    const top = document.createElement("div");
    top.className = "card-topline";
    const title = document.createElement("h2");
    const chip = document.createElement("span");
    const label = document.createElement("span");
    label.className = "state-chip-label";
    chip.append(label);
    top.append(title, chip);
    const summary = document.createElement("p");
    card.append(top, summary);
    container.append(card);
  }
  card.dataset.verificationCurrent = "true";
  const tone = verificationResultTone(checkState);
  card.className = `verification-result ${checkState} state-card-${tone}`;
  const title = card.querySelector("h2");
  const chip = card.querySelector("span");
  const label = chip.querySelector(".state-chip-label");
  const summary = card.querySelector("p");
  setSwappingElementText(title, heading);
  setSwappingElementText(label, titleCase(checkState));
  chip.className = `state-chip ${tone}`;
  setSwappingElementText(summary, summaryText);
}

function appendVerificationEmpty(container, text) {
  const key = "empty";
  let empty = Array.from(container.children).find((child) => child.dataset.verificationKey === key);
  if (!empty) {
    empty = document.createElement("div");
    empty.className = "config-empty";
    empty.dataset.verificationKey = key;
    container.append(empty);
  }
  empty.dataset.verificationCurrent = "true";
  setSwappingElementText(empty, text);
}

function renderVerification() {
  const last = state.verification?.last || null;
  const smtp = state.verification?.smtp || null;
  const cache = state.cache;
  const ready = state.editor?.state === "ready";
  const networkBusy = state.verificationRunning || state.smtpVerificationRunning || state.discoveryRunning || state.cacheVerificationRunning;
  const operationBusy = operationIsActive(state.operation) || scheduleOperationIsActive(state.scheduleOperation);
  const cacheDisabled = cache?.enabled === false;
  const cacheWorkflowState = state.setupWorkflow?.steps?.cache?.state || "";
  const results = byId("verification-results");
  const smtpResults = byId("smtp-verification-results");
  const cacheResults = byId("cache-verification-results");
  const confirm = byId("verification-confirm");
  const smtpConfirm = byId("smtp-verification-confirm");
  const runButton = byId("verification-run-button");
  const smtpRunButton = byId("smtp-verification-run-button");
  const cacheRunButton = byId("cache-verification-run-button");
  prepareVerificationResults(results);
  prepareVerificationResults(smtpResults);
  prepareVerificationResults(cacheResults);
  runButton.disabled = networkBusy || !confirm.checked || !ready;
  smtpRunButton.disabled = networkBusy || !smtpConfirm.checked || !ready;
  cacheRunButton.disabled = cacheDisabled ? !ready : networkBusy || operationBusy || !ready;
  setSwappingButtonText("verification-run-button", state.verificationRunning ? "Testing saved services..." : "Run connection test");
  setSwappingButtonText("smtp-verification-run-button", state.smtpVerificationRunning ? "Testing SMTP..." : "Run SMTP preflight");
  setSwappingButtonText("cache-verification-run-button", cacheDisabled
    ? "Enable Cache Storage"
    : state.cacheVerificationRunning ? "Checking cache..." : "Check deleted-item cache");

  if (!ready) {
    byId("verification-message").textContent = "Complete and save configuration before running a connection test.";
    byId("smtp-verification-message").textContent = "Complete and save configuration before running SMTP preflight.";
    byId("cache-verification-message").textContent = "Complete and save configuration before checking local cache storage.";
  } else {
    byId("verification-message").textContent = state.verificationRunning
      ? "Contacting the saved Tautulli and direct Plex services. This may take up to 45 seconds."
      : "No service request occurs until the confirmation is checked and the button is pressed.";
    byId("smtp-verification-message").textContent = state.smtpVerificationRunning
      ? "Contacting the saved SMTP endpoint without authenticating or sending. This may take up to 45 seconds."
      : "No SMTP request occurs until the confirmation is checked and the button is pressed.";
    byId("cache-verification-message").textContent = cacheDisabled
      ? "Open Config to review the deleted-item cache settings. This action does not toggle or save anything."
      : state.cacheVerificationRunning
        ? "Checking the bounded manifest, local write access, and cached artwork without contacting any service."
        : operationBusy
          ? "Wait for the active local operation; an active cache refresh will finish its verification automatically."
          : cache?.verification === "full"
            ? "The latest full result is retained. Use this optional recheck after later filesystem or configuration changes."
            : "A successful save runs this full local check automatically; use the button for an optional recheck.";
  }

  const retainedLANState = retainedSetupCheckState("lan");
  const retainedSMTPState = retainedSetupCheckState("smtp");
  if (last) {
    setText("verification-observed", `Completed ${formatDate(last.completedAtUtc)} · ${titleCase(last.networkBoundary)}.${state.discoveryError ? " Separate retained evidence from the failed live choices refresh." : ""}`);
    for (const step of last.steps || []) {
      appendVerificationResult(results, step.service === "plex" ? "Direct Plex" : titleCase(step.service), step.state, step.summary);
    }
  } else if (retainedLANState) {
    setText("verification-observed", "Retained from the latest safe setup validation for this configuration.");
    appendVerificationResult(results, "Tautulli and direct Plex", retainedLANState, state.setupWorkflow.steps.lan.summary);
  } else {
    setText("verification-observed", "No integration result is retained for this saved configuration.");
    appendVerificationEmpty(results, "Validate and save to run every safe setup check, or repeat this targeted connection test.");
  }

  if (smtp) {
    setText("smtp-verification-observed", `Completed ${formatDate(smtp.completedAtUtc)} · ${titleCase(smtp.security)}.`);
    appendVerificationResult(smtpResults, "SMTP preflight", smtp.state, smtp.summary);
  } else if (retainedSMTPState) {
    setText("smtp-verification-observed", "Retained from the latest safe setup validation for this configuration.");
    appendVerificationResult(smtpResults, "SMTP preflight", retainedSMTPState, state.setupWorkflow.steps.smtp.summary);
  } else {
    setText("smtp-verification-observed", "No SMTP preflight is retained for this saved configuration.");
    appendVerificationEmpty(smtpResults, "Validate and save to run every safe setup check, or repeat this targeted SMTP preflight.");
  }

  if (["waiting", "running"].includes(cacheWorkflowState) && !cacheDisabled) {
    const workflowSummary = state.setupWorkflow?.steps?.cache?.summary
      || (cacheWorkflowState === "waiting"
        ? "Waiting for the local cache refresh to start."
        : "Checking deleted-item cache storage and artwork locally.");
    setText("cache-verification-observed", cacheWorkflowState === "waiting" ? "Waiting for the local cache refresh to start." : "Cache refresh and verification are running locally.");
    appendVerificationResult(cacheResults, "Deleted-item cache", cacheWorkflowState, workflowSummary);
    appendVerificationResult(cacheResults, "Storage and bounds", cacheWorkflowState,
      cacheWorkflowState === "waiting" ? "Waiting for cache initialization before checking storage and bounds." : "Checking writable storage, retention, and configured bounds.");
    appendVerificationResult(cacheResults, "Manifest and artwork", cacheWorkflowState,
      cacheWorkflowState === "waiting" ? "Waiting for cache initialization before checking the manifest and artwork." : "Checking the manifest, backup, and cached artwork integrity.");
  } else if (cache) {
    if (cache.enabled === false) {
      setText("cache-verification-observed", `Saved setting checked ${formatDate(cache.checkedAtUtc)} · cache storage was not inspected.`);
      appendVerificationResult(cacheResults, "Deleted-item cache", "disabled", cache.summary);
    } else {
      const mode = cache.verification === "full" ? "full local verification" : "read-only status";
      setText("cache-verification-observed", `Checked ${formatDate(cache.checkedAtUtc)} · ${mode}.`);
      appendVerificationResult(cacheResults, "Deleted-item cache", cache.state, cache.summary);
      const cleanupPending = cache.expiredEntryCount > 0 || cache.orphanArtworkCount > 0
        || cache.entryCount > cache.maxItems || cache.artworkBytes > cache.maxBytesMb * 1024 * 1024;
      const storageState = cache.writability === "failed" ? "failed"
        : ["passed", "previously-evidenced"].includes(cache.writability) && !cleanupPending ? "passed" : cache.state === "skipped" ? "skipped" : "warning";
      appendVerificationResult(cacheResults, "Storage and bounds", storageState,
        `${titleCase(cache.writability)} · ${cache.entryCount} of ${cache.maxItems} entries · ${formatBytes(cache.artworkBytes)} of ${cache.maxBytesMb} MB cache ceiling · ${cache.retentionDays}-day retention.`);
      const integrityState = cache.integrityState === "failed" ? "failed"
        : ["verified", "structural"].includes(cache.integrityState) ? "passed" : cache.integrityState === "skipped" ? "skipped" : "warning";
      appendVerificationResult(cacheResults, "Manifest and artwork", integrityState,
        `${titleCase(cache.manifestState)} · backup ${titleCase(cache.backupState)} · ${cache.artworkCount} artwork files · ${cache.missingArtworkCount} missing · ${cache.orphanArtworkCount} orphaned · ${cache.hashMismatchCount} hash mismatches · ${cache.expiredEntryCount} expired.`);
    }
  } else {
    setText("cache-verification-observed", "No deleted-item cache status is available for this saved configuration.");
    appendVerificationEmpty(cacheResults, "Validate and save to run the full local cache verification automatically.");
  }
  finishVerificationResults(results);
  finishVerificationResults(smtpResults);
  finishVerificationResults(cacheResults);

  const integration = renderIntegrationStatus();
  let overallLabel = integration.overallLabel;
  let overallTone = integration.overallTone;
  if (cacheWorkflowState === "waiting") {
    overallLabel = "Waiting";
    overallTone = "waiting";
  } else if (state.cacheVerificationRunning || cacheWorkflowState === "running") {
    overallLabel = "Running";
    overallTone = "pending";
  } else if (cache?.state === "failed") {
    overallLabel = "Needs review";
    overallTone = "bad";
  } else if (cache?.state === "warning" && overallTone !== "bad") {
    overallLabel = "Completed with notes";
    overallTone = "warning";
  } else if (["passed", "skipped"].includes(cache?.state) && integration.overallLabel === "Passed") {
    overallLabel = "Passed";
    overallTone = "good";
  }
  setChip("verification-chip", overallLabel, overallTone);
}

async function runCacheVerification(options = {}) {
  if (state.verificationRunning || state.smtpVerificationRunning || state.discoveryRunning || state.cacheVerificationRunning || state.editor?.state !== "ready" || state.cache?.enabled === false) return null;
  const automatic = Boolean(options.automatic);
  const expectedRevision = options.expectedRevision || state.editor.revision;
  state.cacheVerificationRunning = true;
  updateSetupWorkflowStep("cache", "running", "Checking deleted-item cache storage, bounds, manifest, backup, writability, and artwork integrity...");
  renderVerification();
  setGlobalStatus(automatic ? "Running the automatic full local cache verification..." : "Rechecking deleted-item cache storage and artwork locally...");
  try {
    const result = await request("/api/v1/checks/deleted-item-cache", {
      method: "POST",
      body: JSON.stringify({ expectedRevision }),
    });
    state.cache = result;
    if (state.setupWorkflow?.steps) {
      state.setupWorkflow.steps.cache = { state: result.state, summary: result.summary, updatedAtUtc: result.checkedAtUtc };
    }
    renderSetupWorkflow();
    const completedMessage = automatic ? "Automatic deleted-item cache verification completed" : "Deleted-item cache recheck completed";
    setGlobalStatus(result.state === "failed" ? `${completedMessage} with a problem.` : `${completedMessage}.`, true);
    return result;
  } catch (error) {
    updateSetupWorkflowStep("cache", "failed", "Full deleted-item cache verification could not complete. Review the local Manager diagnostics and retry.");
    setGlobalStatus(error.message, true);
    return null;
  } finally {
    state.cacheVerificationRunning = false;
    renderVerification();
  }
}

function handleCacheVerificationAction() {
  if (state.cache?.enabled === false) {
    selectView("configuration", { section: "cache" });
    return;
  }
  void runCacheVerification();
}

async function runVerification() {
  if (state.verificationRunning || state.smtpVerificationRunning || state.discoveryRunning || !byId("verification-confirm").checked || state.editor?.state !== "ready") return;

  let completed = false;
  state.verificationRunning = true;
  const button = byId("verification-run-button");
  setSwappingButtonText("verification-run-button", "Testing saved services...");
  renderVerification();
  renderDiscovery();
  setGlobalStatus("Running Tautulli and direct Plex connection checks...");
  try {
    const result = await request("/api/v1/checks/integrations", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision, confirmRealNetwork: true }),
    });
    completed = true;
    state.verification = { ...state.verification, last: result };
    byId("verification-confirm").checked = false;
    setGlobalStatus(result.overall === "failed" ? "Connection test completed with failures." : "Connection test completed.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    state.verificationRunning = false;
    setSwappingButtonText("verification-run-button", "Run connection test");
    try {
      await refreshConfigurationStatus();
    } catch (_) {
      // The detailed result is already visible; a later refresh will load its durable server record.
    }
    renderVerification();
    renderDiscovery();
    if (completed) await recoverPendingPreviewsFromChoices();
  }
}

async function runSMTPVerification() {
  if (state.verificationRunning || state.smtpVerificationRunning || state.discoveryRunning || !byId("smtp-verification-confirm").checked || state.editor?.state !== "ready") return;
  state.smtpVerificationRunning = true;
  renderVerification();
  renderDiscovery();
  setGlobalStatus("Running the non-sending SMTP reachability and STARTTLS preflight...");
  try {
    const result = await request("/api/v1/checks/smtp-network", {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision, confirmRealNetwork: true }),
    });
    state.verification = { ...state.verification, smtp: result };
    byId("smtp-verification-confirm").checked = false;
    const message = result.overall === "failed"
      ? "SMTP preflight completed with a failure. No credentials or message data were sent."
      : result.overall === "warning"
        ? "SMTP is reachable, but the saved configuration has STARTTLS disabled."
        : "SMTP reachability and certificate-validated STARTTLS passed. Authentication still requires TestEmail.";
    setGlobalStatus(message, true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    state.smtpVerificationRunning = false;
    try {
      await refreshConfigurationStatus();
    } catch (_) {
      // The detailed result is already visible; a later refresh will load its durable server record.
    }
    renderVerification();
    renderDiscovery();
  }
}

function previewScenarioIndex(preview) {
  const match = String(preview?.name || "").match(/^preview-all-(\d{2})-/i);
  return match ? Number(match[1]) : Number.MAX_SAFE_INTEGER;
}

function previewDisplayName(preview) {
  const name = String(preview?.name || "");
  const scenarios = [
    [/-00-index(?:\.html)?$/i, "Index"],
    [/-01-manual-welcome(?:\.html)?$/i, "Manual Welcome"],
    [/-02-new-user-no-history(?:\.html)?$/i, "New User - No History"],
    [/-03-new-user-with-history(?:\.html)?$/i, "New User - With History"],
    [/-04-normal-newsletter(?:\.html)?$/i, "Normal Newsletter"],
    [/-05-established-quiet(?:\.html)?$/i, "Established Quiet"],
    [/-06-established-warmup(?:\.html)?$/i, "Established Warnings"],
  ];
  return scenarios.find(([pattern]) => pattern.test(name))?.[1] || name;
}

function orderedPreviews() {
  return [...state.previews].sort((left, right) => {
    const scenarioDifference = previewScenarioIndex(left) - previewScenarioIndex(right);
    if (scenarioDifference) return scenarioDifference;
    return String(right.modifiedUtc || "").localeCompare(String(left.modifiedUtc || ""));
  });
}

function preferredPreviewForInventory(previews, selectedID, preferredScenario, generatedPreviewIDs) {
  const generated = new Set(generatedPreviewIDs || []);
  const selected = previews.find((preview) => preview.id === selectedID);
  const scenarioAvailable = Number.isInteger(preferredScenario) && preferredScenario >= 0 && preferredScenario < Number.MAX_SAFE_INTEGER;
  const sameScenario = scenarioAvailable
    ? previews.find((preview) => previewScenarioIndex(preview) === preferredScenario)
    : null;
  return (selected && generated.has(selected.id) ? selected : null)
    || (sameScenario && generated.has(sameScenario.id) ? sameScenario : null)
    || selected
    || sameScenario
    || previews.find((preview) => generated.has(preview.id) && /-00-index(?:\.html)?$/i.test(preview.name))
    || previews.find((preview) => generated.has(preview.id))
    || previews[0]
    || null;
}

function renderPreviews(options = {}) {
  const list = byId("preview-list");
  list.replaceChildren();
  const previews = orderedPreviews();
  setChip("preview-chip", state.previews.length ? `${state.previews.length} available` : "None generated", state.previews.length ? "good" : "neutral");
  if (!state.previews.length) {
    state.selectedPreviewID = "";
    byId("preview-placeholder").hidden = false;
    const frame = byId("preview-frame");
    frame.hidden = true;
    frame.removeAttribute("data-preview-id");
    frame.removeAttribute("data-preview-reload-key");
    frame.src = "about:blank";
    const empty = document.createElement("div");
    empty.className = "config-empty";
    empty.textContent = "No generated HTML previews were found in the package output folder.";
    list.append(empty);
    return;
  }
  for (const preview of previews) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "preview-button";
    button.dataset.previewId = preview.id;
    const name = document.createElement("strong");
    name.textContent = previewDisplayName(preview);
    const meta = document.createElement("small");
    meta.textContent = `${formatDate(preview.modifiedUtc)} · ${formatBytes(preview.sizeBytes)}`;
    button.append(name, meta);
    button.addEventListener("click", () => openPreview(preview.id, button));
    list.append(button);
  }
  const latestRun = state.history.find((operation) => operation.type === "preview-all" && operation.state === "succeeded" && operation.generatedPreviewIds?.length);
  const preferred = preferredPreviewForInventory(
    previews,
    state.selectedPreviewID,
    options.preferredScenario,
    options.generatedPreviewIDs || latestRun?.generatedPreviewIds,
  );
  if (!preferred) return;
  const button = list.querySelector(`[data-preview-id="${CSS.escape(preferred.id)}"]`);
  if (button) openPreview(preferred.id, button, { reloadKey: options.reloadKey });
}

function renderOperations() {
  const operation = state.operation;
  const active = operationIsActive(operation);
  const scheduleActive = scheduleOperationIsActive(state.scheduleOperation);
  const manualSendType = byId("manual-send-mode").value === "send-welcome" ? "send-welcome" : "send-all";
  const manualWelcome = manualSendType === "send-welcome";
  const manualSendUserID = byId("manual-send-user-id").value.trim();
  const manualSendUserValid = !manualWelcome || validPreviewUserID(manualSendUserID);
  renderManualSendChoice(manualSendType);
  const userID = byId("preview-user-id").value.trim();
  const userIDValid = validPreviewUserID(userID);
  const confirmed = byId("preview-confirm").checked;
  const testUserID = byId("test-send-user-id").value.trim();
  const testUserIDValid = validPreviewUserID(testUserID);
  const testConfirmed = byId("test-send-confirm").checked;
  const manualSendConfirmed = byId("manual-send-confirm").checked;
  const ready = state.editor?.state === "ready";
  const startButton = byId("preview-run-button");
  startButton.disabled = state.operationStarting || state.operationCancelling || active || scheduleActive || !ready || !userIDValid || !confirmed;
  setSwappingButtonText("preview-run-button", state.operationStarting && state.operationStartingType === "preview-all" ? "Starting preview generation..." : active || scheduleActive ? "Another operation is active" : "Generate all previews");

  let message = "Enter a numeric Tautulli user ID, then confirm this preview-only run.";
  if (!ready) message = "Complete and save configuration before generating previews.";
  else if (active) message = operation.type === "preview-all" ? (operation.state === "cancelling" ? "Stopping the local preview process safely..." : "Generating previews. You can leave this page while the Manager tracks the operation.") : operation.type === "cache-warm" ? "Refreshing deleted-item cache coverage locally. No email is sent." : "An email delivery is active. Wait for its aggregate SMTP result before starting another operation.";
  else if (scheduleActive) message = "Wait for the active schedule change before generating previews.";
  else if (state.operationStarting) message = "Starting a fixed Manager operation...";
  else if (!userIDValid && userID) message = "Enter a numeric Tautulli user ID using no more than 20 digits.";
  else if (userIDValid && confirmed) message = "Ready to generate six local previews without sending email.";
  setText("preview-operation-message", message);

  const testButton = byId("test-send-run-button");
  testButton.disabled = state.operationStarting || active || scheduleActive || !ready || !testUserIDValid || !testConfirmed;
  setSwappingButtonText("test-send-run-button", state.operationStarting && state.operationStartingType === "send-test-all" ? "Starting test delivery..." : active || scheduleActive ? "Another operation is active" : "Send six test messages");
  let testMessage = "Enter a numeric Tautulli user ID, then confirm the six-message test delivery.";
  if (!ready) testMessage = "Complete and save configuration before sending a test delivery.";
  else if (active) testMessage = operation.type === "send-test-all" ? "Sending to the configured TestEmail. Cancellation is disabled because some messages may already be accepted by SMTP." : "Another Manager operation is active. Wait for it to finish before starting a test delivery.";
  else if (scheduleActive) testMessage = "Wait for the active schedule change before starting a test delivery.";
  else if (state.operationStarting) testMessage = "Starting a fixed Manager operation...";
  else if (!testUserIDValid && testUserID) testMessage = "Enter a numeric Tautulli user ID using no more than 20 digits.";
  else if (testUserIDValid && testConfirmed) testMessage = "Ready to send six real messages only to the configured TestEmail.";
  setText("test-send-operation-message", testMessage);

  const manualSendButton = byId("manual-send-run-button");
  manualSendButton.disabled = state.operationStarting || active || scheduleActive || !ready || !manualSendConfirmed || !manualSendUserValid;
  const manualSendButtonLabel = manualWelcome ? "Send Manual Welcome" : "Send newsletter to all";
  setSwappingButtonText("manual-send-run-button", state.operationStarting && state.operationStartingType === manualSendType ? "Starting manual delivery..." : active || scheduleActive ? "Another operation is active" : manualSendButtonLabel);
  let manualSendMessage = manualWelcome ? "Choose a Tautulli user, then explicitly confirm the one-message Manual Welcome delivery." : "Explicitly confirm the all-recipient production delivery to enable this action.";
  if (!ready) manualSendMessage = "Complete and save configuration before sending a production newsletter.";
  else if (active) manualSendMessage = ["send-welcome", "send-all"].includes(operation.type) ? "A production delivery is running. Cancellation is disabled because a message may already be accepted by SMTP." : "Another Manager operation is active. Wait for it to finish before sending a production newsletter.";
  else if (scheduleActive) manualSendMessage = "Wait for the active schedule change before sending a production newsletter.";
  else if (state.operationStarting) manualSendMessage = "Starting a fixed Manager operation...";
  else if (manualWelcome && manualSendUserID && !manualSendUserValid) manualSendMessage = "Enter a numeric Tautulli user ID using no more than 20 digits.";
  else if (manualSendConfirmed && manualSendUserValid) manualSendMessage = manualWelcome ? "Ready to send one real Manual Welcome message to the selected user." : "Ready to send real email to every currently eligible recipient.";
  setText("manual-send-operation-message", manualSendMessage);

  renderCurrentOperation(operation);
  renderManualSendStatus(operation);
  renderOperationHistory();
  renderDashboardOperation(operation);
  if (state.status && state.editor) renderSchedule();
}

function renderManualSendChoice(type) {
  const manualWelcome = type === "send-welcome";
  byId("manual-send-user-field").hidden = !manualWelcome;
  setSwappingText("manual-send-runner-heading", manualWelcome ? "Send one Manual Welcome" : "Send this week's newsletter now");
  setText("manual-send-runner-copy", manualWelcome
    ? "Sends the renderer's Manual Welcome state to one selected Tautulli user, then updates that recipient's welcome and history state. It does not contact other Plex users."
    : "Runs the same fixed production delivery used by the schedule, applies saved library and user exclusions, and updates recipient welcome and history state for every eligible recipient.");
  setText("manual-send-confirm-heading", manualWelcome ? "Send one Manual Welcome newsletter" : "Send the production newsletter to all eligible recipients");
  setText("manual-send-confirm-copy", manualWelcome
    ? "I understand this sends one real email to the selected Plex user and updates that user's welcome state. The operation cannot be cancelled after it starts."
    : "I understand this may send real email to every eligible recipient and updates recipient state. The operation cannot be cancelled after it starts.");
}

function renderManualSendStatus(operation) {
  const manualTypes = new Set(["send-welcome", "send-all"]);
  const manualSend = manualTypes.has(operation?.type)
    ? operation
    : state.history.find((candidate) => manualTypes.has(candidate.type));
  const card = byId("manual-send-status");
  card.hidden = !manualSend;
  if (!manualSend) return;
  const summary = operationSummary(manualSend);
  setText("manual-send-status-heading", summary.heading);
  setText("manual-send-status-copy", summary.copy);
  const duration = manualSend.durationMs ? ` · ${formatDuration(manualSend.durationMs)}` : "";
  setText("manual-send-status-time", manualSend.finishedAtUtc ? `Finished ${formatDate(manualSend.finishedAtUtc)}${duration}` : `Started ${formatDate(manualSend.startedAtUtc)}`);
  setChip("manual-send-status-chip", titleCase(manualSend.outcome || manualSend.state), operationTone(manualSend));
}

function renderCurrentOperation(operation) {
  const card = byId("current-operation");
  const cancel = byId("preview-cancel-button");
  const manualSend = ["send-welcome", "send-all"].includes(operation?.type);
  card.hidden = manualSend;
  if (manualSend) {
    cancel.hidden = true;
    return;
  }
  cancel.hidden = !operation?.cancellable || !operationIsActive(operation);
  cancel.disabled = state.operationCancelling;
  setSwappingButtonText("preview-cancel-button", state.operationCancelling ? "Cancelling..." : operation?.type === "cache-warm" ? "Cancel cache refresh" : "Cancel preview generation");
  if (!operation) {
    setText("current-operation-heading", "No Manager operation recorded");
    setText("current-operation-copy", "The Manager keeps sanitized operation state locally.");
    setText("current-operation-time", "Not recorded");
    setChip("current-operation-chip", "Idle", "neutral");
    return;
  }
  const summary = operationSummary(operation);
  setText("current-operation-heading", summary.heading);
  setText("current-operation-copy", summary.copy);
  const duration = operation.durationMs ? ` · ${formatDuration(operation.durationMs)}` : "";
  setText("current-operation-time", operation.finishedAtUtc ? `Finished ${formatDate(operation.finishedAtUtc)}${duration}` : `Started ${formatDate(operation.startedAtUtc)}`);
  setChip("current-operation-chip", titleCase(operation.state), operationTone(operation));
}

function renderDashboardOperation(operation) {
  if (!operation) {
    setText("dashboard-operation-heading", "No Manager operation recorded");
    setText("dashboard-operation-copy", "Generate local previews, send a guarded six-message test, or start a confirmed production delivery from the Preview center.");
    setChip("dashboard-operation-chip", "Idle", "neutral");
    return;
  }
  const summary = operationSummary(operation);
  setText("dashboard-operation-heading", summary.heading);
  setText("dashboard-operation-copy", `${summary.copy} ${operation.finishedAtUtc ? formatDate(operation.finishedAtUtc) : formatDate(operation.startedAtUtc)}.`);
  setChip("dashboard-operation-chip", titleCase(operation.state), operationTone(operation));
}

function renderOperationHistory() {
  const container = byId("operation-history");
  container.replaceChildren();
  setText("operation-history-count", `${state.history.length} / ${state.historyMaximum} completed items shown`);
  if (!state.history.length) {
    const empty = document.createElement("div");
    empty.className = "config-empty";
    empty.textContent = "No completed Manager operation has been recorded yet.";
    container.append(empty);
    return;
  }
  for (const operation of state.history) {
    const row = document.createElement("article");
    row.className = "operation-history-row";
    const copy = document.createElement("div");
    const heading = document.createElement("h3");
    heading.textContent = operationSummary(operation).heading;
    const detail = document.createElement("p");
    const version = operation.packageVersion ? `Package ${operation.packageVersion}` : "Package version unavailable";
    detail.textContent = `${formatDate(operation.startedAtUtc)} · ${version}${operation.durationMs ? ` · ${formatDuration(operation.durationMs)}` : ""}${operation.supportCode ? ` · Support ${operation.supportCode}` : ""}`;
    copy.append(heading, detail);
    if (operation.generatedPreviewIds?.length) {
      const links = document.createElement("div");
      links.className = "operation-history-links";
      for (const id of operation.generatedPreviewIds) {
        const preview = state.previews.find((candidate) => candidate.id === id);
        if (!preview) continue;
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = previewDisplayName(preview);
        button.addEventListener("click", () => {
          const previewButton = document.querySelector(`[data-preview-id="${CSS.escape(id)}"]`);
          if (previewButton) openPreview(id, previewButton);
        });
        links.append(button);
      }
      if (links.childElementCount) copy.append(links);
    }
    const meta = document.createElement("div");
    meta.className = "operation-history-meta";
    const chip = document.createElement("span");
    chip.className = `state-chip ${operationTone(operation)}`;
    chip.textContent = titleCase(operation.outcome || operation.state);
    const count = document.createElement("small");
    count.textContent = operation.type === "send-test-all" || operation.type === "send-welcome"
      ? `${operation.smtpAcceptedCount || 0} accepted by SMTP`
      : operation.type === "send-all"
        ? `${operation.smtpAcceptedCount || 0} accepted · ${operation.skippedCount || 0} skipped · ${operation.failedCount || 0} failed`
        : operation.type === "cache-warm"
          ? "All included users and selected libraries"
        : `${operation.generatedPreviewIds?.length || 0} preview${operation.generatedPreviewIds?.length === 1 ? "" : "s"}`;
    meta.append(chip, count);
    row.append(copy, meta);
    container.append(row);
  }
}

function operationSummary(operation) {
  const count = operation.generatedPreviewIds?.length || 0;
  if (operation.type === "cache-warm") {
    switch (operation.state) {
    case "queued": return { heading: "Deleted-item cache refresh queued", copy: "The local all-included-user cache refresh is waiting to start." };
    case "running": return { heading: "Refreshing deleted-item cache", copy: "Included users and selected-library newsletter items are being inspected locally; no email is sent." };
    case "cancelling": return { heading: "Cancelling cache refresh", copy: "The Manager is stopping the local cache refresh and retaining a sanitized result." };
    case "succeeded": return { heading: "Deleted-item cache refresh completed", copy: "Every eligible included user was checked and the full local cache verification completed." };
    case "cancelled": return { heading: "Deleted-item cache refresh cancelled", copy: "The local refresh stopped before complete coverage could be verified." };
    case "failed": return { heading: "Deleted-item cache refresh failed", copy: rendererFailureCopy(operation.errorCategory, operation.supportCode) };
    default: return { heading: "Deleted-item cache refresh recorded", copy: "Review the sanitized cache result under Verify." };
    }
  }
  if (operation.type === "send-welcome") {
    switch (operation.state) {
    case "queued": return { heading: "Manual Welcome queued", copy: "One selected-user welcome newsletter is waiting to start." };
    case "running": return { heading: "Sending one Manual Welcome", copy: "One selected Plex user is being processed. Cancellation is disabled once delivery begins." };
    case "succeeded": return { heading: "Manual Welcome accepted by SMTP", copy: "One welcome message was accepted by SMTP. The selected user's welcome state was updated; inbox delivery is not asserted." };
    case "failed": return { heading: "Manual Welcome delivery failed", copy: `${rendererFailureCopy(operation.errorCategory, operation.supportCode)}${smtpFailureEvidenceCopy(operation.smtpFailure)}` };
    default: return { heading: "Manual Welcome delivery recorded", copy: "Review aggregate SMTP acceptance without exposing the selected recipient." };
    }
  }
  if (operation.type === "send-all") {
    const accepted = operation.smtpAcceptedCount || 0;
    const skipped = operation.skippedCount || 0;
    const failed = operation.failedCount || 0;
    const reasonCopy = skipReasonCopy(operation.skipReasonCounts);
    switch (operation.state) {
    case "queued": return { heading: "Manual newsletter delivery queued", copy: "The fixed production delivery is waiting to start." };
    case "running": return { heading: "Sending the production newsletter", copy: "Eligible recipients are being processed. Cancellation is disabled once delivery begins." };
    case "succeeded": return { heading: "Manual newsletter accepted by SMTP", copy: `${accepted} message${accepted === 1 ? " was" : "s were"} accepted by SMTP and ${skipped} recipient${skipped === 1 ? " was" : "s were"} skipped.${reasonCopy} Inbox delivery is not asserted.` };
    case "partial": return { heading: "Manual newsletter stopped after a partial delivery", copy: `${accepted} accepted by SMTP, ${skipped} skipped, and ${failed} failed.${reasonCopy} ${operation.errorCategory ? rendererFailureCopy(operation.errorCategory, operation.supportCode) : "One or more recipient attempts failed."}${smtpFailureEvidenceCopy(operation.smtpFailure)} Inbox delivery is not asserted.` };
    case "failed": return operation.errorCategory === "no-eligible-recipients"
      ? { heading: "No eligible production recipients", copy: `No message was accepted by SMTP.${reasonCopy} Checked exclusion boxes mean excluded.${operation.supportCode ? ` Support code: ${operation.supportCode}.` : ""}` }
      : { heading: "Manual newsletter delivery failed", copy: `${accepted} message${accepted === 1 ? " was" : "s were"} accepted before failure. ${rendererFailureCopy(operation.errorCategory, operation.supportCode)}${smtpFailureEvidenceCopy(operation.smtpFailure)}` };
    default: return { heading: "Manual newsletter delivery recorded", copy: `${accepted} accepted by SMTP, ${skipped} skipped, and ${failed} failed.${reasonCopy} Inbox delivery is not asserted.` };
    }
  }
  if (operation.type === "send-test-all") {
    switch (operation.state) {
    case "queued": return { heading: "Test delivery queued", copy: "The fixed six-message TestEmail operation is waiting to start." };
    case "running": return { heading: "Sending six test messages", copy: "Messages go only to the configured TestEmail; cancellation is disabled once sending begins." };
    case "succeeded": return { heading: "Test delivery accepted by SMTP", copy: `${operation.smtpAcceptedCount || 0} test messages were accepted by SMTP. Inbox delivery is not asserted.` };
    case "failed": return { heading: "Test delivery failed", copy: `${operation.smtpAcceptedCount || 0} test message${operation.smtpAcceptedCount === 1 ? " was" : "s were"} accepted before failure. ${rendererFailureCopy(operation.errorCategory, operation.supportCode)}${smtpFailureEvidenceCopy(operation.smtpFailure)}` };
    default: return { heading: "Test delivery recorded", copy: "Review aggregate SMTP acceptance and failure counts." };
    }
  }
  switch (operation.state) {
  case "queued": return { heading: "Preview generation queued", copy: "The fixed package preview operation is waiting to start." };
  case "running": return { heading: "Generating newsletter previews", copy: "The package renderer is creating local HTML; no email is sent." };
  case "cancelling": return { heading: "Cancelling preview generation", copy: "The Manager is stopping the local renderer and retaining a sanitized result." };
  case "succeeded": return { heading: "Preview generation completed", copy: `${count} generated preview${count === 1 ? " is" : "s are"} available for authenticated review.` };
  case "cancelled": return { heading: "Preview generation cancelled", copy: "The local renderer was stopped before normal completion; no email was sent." };
  case "failed": return { heading: "Preview generation failed", copy: rendererFailureCopy(operation.errorCategory, operation.supportCode) };
  default: return { heading: "Preview operation recorded", copy: "Review the sanitized state and generated preview list." };
  }
}

function skipReasonCopy(counts) {
  if (!counts) return "";
  const reasons = [
    [counts.inactiveOrDeleted, "inactive or deleted"],
    [counts.missingEmail, "missing email"],
    [counts.excludedUserId, "excluded by user selection"],
    [counts.excludedEmail, "excluded by legacy email rule"],
  ].filter(([count]) => Number.isInteger(count) && count > 0);
  if (!reasons.length) return "";
  return ` Skip reasons: ${reasons.map(([count, label]) => `${count} ${label}`).join("; ")}.`;
}

function operationTone(operation) {
  if (operation?.state === "succeeded") return "good";
  if (operation?.state === "failed") return "bad";
  if (operation?.state === "partial") return "neutral";
  if (operationIsActive(operation)) return "pending";
  return "neutral";
}

function operationIsActive(operation) {
  return ["queued", "running", "cancelling"].includes(operation?.state);
}

function validPreviewUserID(value) {
  if (!/^[0-9]{1,20}$/.test(value)) return false;
  const parsed = BigInt(value);
  return parsed > 0n && parsed <= 18446744073709551615n;
}

async function startPreviewOperation() {
  const userID = byId("preview-user-id").value.trim();
  if (state.editor?.state !== "ready" || !byId("preview-confirm").checked || !validPreviewUserID(userID)) return;
  state.operationStarting = true;
  state.operationStartingType = "preview-all";
  renderOperations();
  setGlobalStatus("Starting the fixed local preview operation...");
  try {
    state.operation = await request("/api/v1/operations", {
      method: "POST",
      body: JSON.stringify({ type: "preview-all", expectedRevision: state.editor.revision, userId: userID, confirmNoSend: true }),
    });
    byId("preview-user-id").value = "";
    byId("preview-confirm").checked = false;
    setGlobalStatus("Preview generation started. No email will be sent.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    state.operationStarting = false;
    state.operationStartingType = "";
    try {
      await refreshConfigurationStatus();
    } catch (_) {
      // Operation polling will refresh the retained setup result at completion.
    }
    renderOperations();
    manageOperationPolling();
  }
}

async function startTestSendOperation() {
  const userID = byId("test-send-user-id").value.trim();
  if (state.editor?.state !== "ready" || !byId("test-send-confirm").checked || !validPreviewUserID(userID)) return;
  state.operationStarting = true;
  state.operationStartingType = "send-test-all";
  renderOperations();
  setGlobalStatus("Starting the guarded six-message test delivery...");
  try {
    state.operation = await request("/api/v1/operations", {
      method: "POST",
      body: JSON.stringify({ type: "send-test-all", expectedRevision: state.editor.revision, userId: userID, confirmTestSend: true }),
    });
    byId("test-send-user-id").value = "";
    byId("test-send-confirm").checked = false;
    setGlobalStatus("Test delivery started. Messages go only to the configured TestEmail.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    state.operationStarting = false;
    state.operationStartingType = "";
    renderOperations();
    manageOperationPolling();
  }
}

async function startManualSendOperation() {
  const type = byId("manual-send-mode").value === "send-welcome" ? "send-welcome" : "send-all";
  const userID = byId("manual-send-user-id").value.trim();
  if (state.editor?.state !== "ready" || !byId("manual-send-confirm").checked || (type === "send-welcome" && !validPreviewUserID(userID))) return;
  state.operationStarting = true;
  state.operationStartingType = type;
  renderOperations();
  setGlobalStatus(type === "send-welcome" ? "Starting the confirmed Manual Welcome delivery..." : "Starting the confirmed all-recipient newsletter delivery...");
  try {
    state.operation = await request("/api/v1/operations", {
      method: "POST",
      body: JSON.stringify({ type, expectedRevision: state.editor.revision, userId: type === "send-welcome" ? userID : "", confirmProductionSend: true }),
    });
    if (type === "send-welcome") byId("manual-send-user-id").value = "";
    byId("manual-send-confirm").checked = false;
    setGlobalStatus(type === "send-welcome" ? "Manual Welcome delivery started. The selected user is not retained in Manager history." : "All-recipient production delivery started. Aggregate SMTP evidence will be retained locally.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    state.operationStarting = false;
    state.operationStartingType = "";
    renderOperations();
    renderStatus();
    manageOperationPolling();
  }
}

async function cancelPreviewOperation() {
  if (!operationIsActive(state.operation) || !state.operation?.cancellable) return;
  state.operationCancelling = true;
  renderOperations();
  setGlobalStatus("Cancelling local preview generation...");
  try {
    state.operation = await request(`/api/v1/operations/${encodeURIComponent(state.operation.id)}/cancel`, { method: "POST" });
    setGlobalStatus("Cancellation requested.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    state.operationCancelling = false;
    renderOperations();
    manageOperationPolling();
  }
}

let operationPollTimer;
let operationPollSequence = 0;
let operationCompletionProcessedID = "";

function manageDeliveryStatusPolling() {
  clearTimeout(deliveryStatusPollTimer);
  if (document.hidden || byId("app-shell").hidden || !state.status) return;
  deliveryStatusPollTimer = setTimeout(pollDeliveryStatus, productionDeliveryIsRunning() ? 1500 : 5000);
}

async function pollDeliveryStatus() {
  clearTimeout(deliveryStatusPollTimer);
  if (deliveryStatusPollInFlight || document.hidden || byId("app-shell").hidden || !state.status) return;
  deliveryStatusPollInFlight = true;
  try {
    state.status = await request("/api/v1/status");
    renderStatus();
    if (state.editor) renderSchedule();
  } catch (error) {
    if (error.status === 401) showAuthentication();
    else deliveryStatusPollTimer = setTimeout(pollDeliveryStatus, 5000);
  } finally {
    deliveryStatusPollInFlight = false;
  }
}

function manageOperationPolling() {
  clearTimeout(operationPollTimer);
  operationPollSequence += 1;
  if (!operationIsActive(state.operation)) return;
  const expectedOperationID = state.operation?.id || "";
  const expectedSequence = operationPollSequence;
  operationPollTimer = setTimeout(() => pollOperation(expectedOperationID, expectedSequence), 1000);
}

function operationPollIsCurrent(expectedOperationID, expectedSequence) {
  return expectedSequence === operationPollSequence && state.operation?.id === expectedOperationID;
}

function successfulPreviewGeneration(operation) {
  return operation?.type === "preview-all" && operation.state === "succeeded";
}

async function pollOperation(expectedOperationID = state.operation?.id || "", expectedSequence = operationPollSequence) {
  if (!operationPollIsCurrent(expectedOperationID, expectedSequence)) return;
  if (!operationIsActive(state.operation) && operationCompletionProcessedID === expectedOperationID) return;
  const priorState = state.operation?.state;
  try {
    const response = await request("/api/v1/operations/current");
    if (!operationPollIsCurrent(expectedOperationID, expectedSequence)) return;
    if (!response.current || response.current.id !== expectedOperationID) return;
    state.operation = response.current;
    if (operationIsActive(state.operation)) {
      renderOperations();
      renderStatus();
      manageOperationPolling();
      return;
    }
    if (operationCompletionProcessedID === state.operation.id) return;
    const completedOperation = state.operation;
    const refreshPreviews = successfulPreviewGeneration(completedOperation);
    const selectedPreview = refreshPreviews
      ? state.previews.find((preview) => preview.id === state.selectedPreviewID)
      : null;
    const requests = [
      request("/api/v1/history"),
      request("/api/v1/status"),
      request("/api/v1/config/status"),
    ];
    if (refreshPreviews) requests.push(request("/api/v1/previews"));
    const [history, status, configurationStatus, previews] = await Promise.all(requests);
    if (!operationPollIsCurrent(expectedOperationID, expectedSequence)) return;
    if (refreshPreviews) state.previews = previews?.previews || [];
    state.historyMaximum = Number(history.maximumEntries) || 20;
    state.history = (history.operations || []).slice(0, state.historyMaximum);
    state.status = status;
    state.setupWorkflow = configurationStatus?.available ? configurationStatus : null;
    state.cache = configurationStatus?.cache || null;
    operationCompletionProcessedID = completedOperation.id;
    if (refreshPreviews) {
      renderPreviews({
        preferredScenario: previewScenarioIndex(selectedPreview),
        generatedPreviewIDs: completedOperation.generatedPreviewIds,
        reloadKey: completedOperation.id,
      });
    }
    renderOperations();
    renderStatus();
    renderSetupWorkflow();
    if (["queued", "running", "cancelling"].includes(priorState)) {
      const summary = state.operation ? operationSummary(state.operation) : { heading: "Manager operation ended" };
      setGlobalStatus(summary.heading + ".", true);
    }
    if (completedOperation.type === "cache-warm") await recoverPendingPreviewsFromChoices();
  } catch (error) {
    if (!operationPollIsCurrent(expectedOperationID, expectedSequence)) return;
    if (error.status === 401) showAuthentication();
    else {
      setGlobalStatus(error.message, true);
      operationPollTimer = setTimeout(() => pollOperation(expectedOperationID, expectedSequence), 2500);
    }
  }
}

function chooseScheduleAction(action) {
  if (!validScheduleAction(action)) return;
  const button = document.querySelector(`[data-schedule-action="${action}"]`);
  if (!button || button.disabled) return;
  state.schedulePendingAction = action;
  byId("schedule-confirm").checked = false;
  renderSchedule();
  byId("schedule-confirmation").scrollIntoView({ behavior: "smooth", block: "center" });
  byId("schedule-confirm").focus({ preventScroll: true });
}

function cancelScheduleConfirmation() {
  state.schedulePendingAction = "";
  byId("schedule-confirm").checked = false;
  renderSchedule();
}

async function startScheduleOperation() {
  const action = state.schedulePendingAction;
  if (!validScheduleAction(action) || !byId("schedule-confirm").checked || state.editor?.state !== "ready") return;
  state.scheduleStarting = true;
  renderSchedule();
  setGlobalStatus(isServiceRuntime() ? "Applying the embedded schedule change..." : "Starting the fixed Windows schedule helper...");
  try {
    state.scheduleOperation = await request(`/api/v1/schedule/${encodeURIComponent(action)}`, {
      method: "POST",
      body: JSON.stringify({ expectedRevision: state.editor.revision, confirm: true }),
    });
    state.schedulePendingAction = "";
    byId("schedule-confirm").checked = false;
    setGlobalStatus(isServiceRuntime() ? "Schedule operation started." : "Schedule operation started. Review the Windows UAC prompt.", true);
  } catch (error) {
    setGlobalStatus(error.message, true);
  } finally {
    state.scheduleStarting = false;
    renderSchedule();
    renderOperations();
    manageSchedulePolling();
  }
}

function validScheduleAction(action) {
  return (state.capabilities?.scheduleActions || ["install", "enable", "disable", "remove"]).includes(action);
}

let schedulePollTimer;
function manageSchedulePolling() {
  clearTimeout(schedulePollTimer);
  if (!scheduleOperationIsActive(state.scheduleOperation)) return;
  schedulePollTimer = setTimeout(pollScheduleOperation, 1000);
}

async function pollScheduleOperation() {
  const priorState = state.scheduleOperation?.state;
  try {
    const response = await request("/api/v1/schedule/operation");
    state.scheduleOperation = response.current || null;
    if (scheduleOperationIsActive(state.scheduleOperation)) {
      renderSchedule();
      renderOperations();
      manageSchedulePolling();
      return;
    }
    state.status = await request("/api/v1/status");
    renderStatus();
    renderSchedule();
    renderOperations();
    if (["queued", "running"].includes(priorState)) {
      const action = titleCase(state.scheduleOperation?.action || "Schedule");
      const outcome = state.scheduleOperation?.state === "succeeded" ? "completed" : "was not completed";
      setGlobalStatus(`${action} schedule ${outcome}.`, true);
    }
  } catch (error) {
    if (error.status === 401) showAuthentication();
    else {
      setGlobalStatus(error.message, true);
      schedulePollTimer = setTimeout(pollScheduleOperation, 2500);
    }
  }
}

function renderStartupSettings() {
  const startup = state.startup || { supported: false, state: "unsupported" };
  const panel = byId("startup-settings-panel");
  panel.hidden = !startup.supported || !state.capabilities?.supportsStartup;
  if (panel.hidden) return;
  const managerToggle = byId("startup-manager");
  const dashboardToggle = byId("startup-dashboard");
  const unavailable = ["conflict", "unavailable"].includes(startup.state);
  const selection = state.startupDraft || startup;
  managerToggle.checked = Boolean(selection.startManager);
  dashboardToggle.checked = Boolean(selection.openDashboard && selection.startManager);
  if (!managerToggle.checked) dashboardToggle.checked = false;
  managerToggle.disabled = state.startupSaving || unavailable;
  dashboardToggle.disabled = state.startupSaving || unavailable || !managerToggle.checked;
  panel.setAttribute("aria-busy", String(state.startupSaving));
  managerToggle.closest(".config-toggle").querySelector("em").textContent = managerToggle.checked ? "On" : "Off";
  dashboardToggle.closest(".config-toggle").querySelector("em").textContent = dashboardToggle.checked ? "On" : "Off";
  const dependent = dashboardToggle.closest(".startup-setting");
  dependent.classList.toggle("disabled", unavailable || !managerToggle.checked);
  const savedManagerEnabled = Boolean(startup.startManager);
  const label = startup.state === "conflict" ? "Needs review" : startup.state === "unavailable" ? "Unavailable" : savedManagerEnabled ? "Enabled" : "Disabled";
  const tone = startup.state === "conflict" || startup.state === "unavailable" ? "bad" : savedManagerEnabled ? "good" : "neutral";
  setChip("startup-settings-chip", label, tone);
  const message = byId("startup-settings-message");
  if (state.startupError) message.textContent = state.startupError;
  else if (startup.state === "conflict") message.textContent = "A same-named Windows sign-in entry does not match this installation. It was left unchanged.";
  else if (startup.state === "unavailable") message.textContent = "Windows sign-in startup status could not be read safely.";
  else if (startup.startManager && startup.openDashboard) message.textContent = "The Manager starts silently at sign-in, then opens the Dashboard once it is ready.";
  else if (startup.startManager) message.textContent = "The Manager starts silently in the notification area at sign-in.";
  else message.textContent = "The Manager starts only when you open it.";
}

async function startupSettingsChanged() {
  if (state.startupSaving) return;
  const managerToggle = byId("startup-manager");
  const dashboardToggle = byId("startup-dashboard");
  if (!managerToggle.checked) dashboardToggle.checked = false;
  const requested = {
    startManager: managerToggle.checked,
    openDashboard: dashboardToggle.checked,
  };
  state.startupDraft = requested;
  state.startupSaving = true;
  state.startupError = "";
  renderStartupSettings();
  try {
    state.startup = await request("/api/v1/startup", {
      method: "PUT",
      body: JSON.stringify(requested),
    });
    setGlobalStatus("Windows sign-in settings saved.", true);
  } catch (error) {
    state.startupError = error.message;
  } finally {
    state.startupDraft = null;
    state.startupSaving = false;
    renderStartupSettings();
  }
}

function renderAccessSettings() {
  const access = state.authAccess || {};
  const locked = Boolean(access.authenticationRequired);
  const localLock = Boolean(access.passwordLockEnabled);
  const runtimeRequired = Boolean(access.runtimeRequired);
  const passwordLockActive = localLock || runtimeRequired;
  setChip("access-settings-chip", locked ? "Locked" : "Unlocked", locked ? "good" : "neutral", locked ? "lock" : "lock-open");
  const accessChip = byId("access-settings-chip");
  accessChip.classList.add("access-lock-chip", locked ? "locked" : "unlocked");
  const accessButton = byId("access-status-button");
  const accessLabel = `${accessSurfaceLabel()} ${locked ? "locked" : "unlocked"}`;
  accessButton.className = `access-status-button ${locked ? "locked" : "unlocked"}`;
  accessButton.dataset.tooltip = accessLabel;
  accessButton.setAttribute("aria-label", `${accessLabel}. Open password settings.`);
  accessButton.replaceChildren(createMaterialIcon(locked ? "lock" : "lock-open"));
  setText("access-settings-copy", runtimeRequired
    ? "This Manager mode requires authentication. A password can be changed here, but the lock cannot be disabled while this mode is active."
    : localLock
      ? "The optional password lock is enabled. Existing sessions remain active; a password is required after sign-out or restart."
      : `${accessSurfaceLabel()} is currently trusted without a password. Enable the optional lock when other people can reach this Manager.`);
  setText("access-password-label", passwordLockActive ? "New password" : "Create password");
  setSwappingButtonText("access-password-submit", passwordLockActive ? "Change password" : "Enable password lock");
  byId("access-disable-button").hidden = !localLock || !access.canDisable;
  byId("logout-button").hidden = !locked;
  const policy = byId("config-secret-policy");
  if (policy) policy.textContent = locked
    ? "Secrets stay hidden by default. Saving preserves stored credentials unless you replace or clear them. Revealing one value requires your Manager password, returns only that field, and clears it from the page after 30 seconds. Existing configurations receive a private timestamped backup."
    : "Secrets stay hidden by default. Saving preserves stored credentials unless you replace or clear them. An explicit reveal returns only the selected field and clears it from the page after 30 seconds. Existing configurations receive a private timestamped backup.";
  renderTailscaleSettings();
}

function tailscaleStatePresentation(remote) {
  const windows = state.runtimeMode === "windows";
  const nativeLinux = state.runtimeMode === "linux";
  switch (remote.state) {
    case "active": return { label: "Active", tone: "good", status: "Public HTTPS Funnel is active and points only to the loopback Manager." };
    case "inactive": return { label: "Inactive", tone: "neutral", status: "Public Funnel is off." };
    case "starting": return { label: "Publication pending", tone: "publication-pending", status: "The exact loopback Funnel is configured, but independent public DNS and certificate-validated TLS have not both passed. Local Funnel on is not proof of publication. Wait up to 10 minutes, confirm MagicDNS, HTTPS certificates, and the matching Funnel policy target, then Verify." };
    case "stopping": return { label: "Stopping", tone: "pending", status: "The host adapter is stopping and verifying the exact TautWeekly Funnel." };
    case "manager-password-required": return { label: "Password required", tone: "pending", status: "Create and enable a unique Manager password before Funnel can be turned on." };
    case "approval-required": return remote.enabled
      ? { label: "Approval required", tone: "pending", status: "Funnel is saved. Approve Verify with Windows to confirm the current public route." }
      : { label: "Approval required", tone: "pending", status: "Windows approval is required only for an explicit Enable, Disable, or Verify action." };
    case "ready": return { label: "Ready", tone: "neutral", status: "The fixed host adapter is ready. Enable creates only the loopback Funnel after the Manager password lock is active." };
    case "authorization-required": return { label: "Host approval required", tone: "pending", status: "Run the displayed fixed package authorization command, then retry. Manager remains unprivileged and receives no Tailscale credential." };
    case "tailscale-required": return { label: "Tailscale required", tone: "neutral", status: windows ? "Install the official Tailscale Windows client, start it, and sign in before enabling Funnel." : nativeLinux ? "Install the official Tailscale Linux package, start it, and sign in before enabling Funnel." : "Enable the package's isolated Tailscale Funnel adapter, then sign in interactively with its fixed console command." };
    case "sign-in-required": return { label: "Sign in required", tone: "pending", status: windows ? "Sign in through the official Tailscale Windows app, then verify again." : nativeLinux ? "Sign in through the official Tailscale Linux CLI outside Manager, then verify again." : "Use the fixed package console command to sign in to the isolated official Tailscale runtime, then verify again." };
    case "not-running": return { label: "Tailscale stopped", tone: "bad", status: windows || nativeLinux ? `Start the official Tailscale ${windows ? "Windows" : "Linux"} service, then verify again.` : "Start the package's optional Funnel adapter, then verify again." };
    case "funnel-unsupported": return { label: "Update required", tone: "bad", status: windows || nativeLinux ? `Update the official Tailscale ${windows ? "Windows client" : "Linux package"} to a Funnel-capable release.` : "Update the TautWeekly package to a release with the current pinned official Tailscale runtime." };
    case "migration-required": return { label: "Migration required", tone: "pending", status: "The older private Serve route is blocked. With the password lock active, Enable converts only that exact route to Funnel; Disable removes it." };
    case "needs-attention": return { label: "Needs attention", tone: "bad", status: "The saved Funnel could not be matched to the exact TautWeekly route. The password boundary remains active." };
    case "unavailable": return { label: "Unavailable", tone: "bad", status: "Funnel state could not be verified safely." };
    default: return { label: "Unavailable", tone: "neutral", status: "Public Funnel is unavailable in this package." };
  }
}

function validTailscaleURL(value) {
  try {
    const parsed = new URL(value);
    return parsed.protocol === "https:" && parsed.username === "" && parsed.password === "" && parsed.port === "" &&
      parsed.pathname === "/" && parsed.search === "" && parsed.hash === "" && parsed.hostname.endsWith(".ts.net");
  } catch (_) {
    return false;
  }
}

function validTailscaleSetupURL(value) {
  try {
    const parsed = new URL(value);
    return parsed.protocol === "https:" && parsed.username === "" && parsed.password === "" && parsed.port === "" && parsed.hostname === "login.tailscale.com" && parsed.hash === "";
  } catch (_) {
    return false;
  }
}

function renderTailscaleSettings() {
  const panel = byId("tailscale-settings-panel");
  if (!panel) return;
  const remote = state.tailscale || {};
  renderTailscaleStatusButton(state.tailscale);
  panel.hidden = !remote.supported;
  if (!remote.supported) return;
  const windows = state.runtimeMode === "windows";
  const publicFunnel = true;
  panel.classList.toggle("enabled-glow", Boolean(remote.enabled && remote.active));
  panel.classList.toggle("publication-pending-glow", Boolean(publicFunnel && remote.enabled && remote.state === "starting"));
  const displayRemote = publicFunnel && state.tailscaleSaving
    ? { ...remote, state: state.tailscaleRequestedOperation === "enable" ? "starting" : "stopping" }
    : remote;
  renderTailscaleStatusButton(displayRemote);
  const presentation = tailscaleStatePresentation(displayRemote);
  const passwordLocked = Boolean(state.authAccess?.passwordLockEnabled);
  setText("tailscale-settings-eyebrow", "Optional public remote access");
  setText("tailscale-settings-heading", "Tailscale Funnel");
  setText("tailscale-settings-copy", "Open the Manager from an ordinary remote browser through a stable public HTTPS address. The Manager remains local to its package boundary; Funnel proxies only the fixed Manager target.");
  setText("tailscale-toggle-label", "Make the Manager remotely available");
  setText("tailscale-status-label", "Funnel status");
  setText("tailscale-address-label", "Public HTTPS address");
  panel.setAttribute("aria-busy", String(state.tailscaleSaving));
  const transitionLabel = state.tailscaleVerifying ? "Checking" : state.tailscaleRequestedOperation === "enable" ? "Starting" : "Stopping";
  setChip("tailscale-settings-chip", state.tailscaleSaving ? transitionLabel : presentation.label, state.tailscaleSaving ? "pending" : presentation.tone);
  setText("tailscale-funnel-status", presentation.status);

  const toggle = byId("tailscale-enabled");
  toggle.checked = Boolean(remote.enabled);
  const blockedState = ["conflict", "unavailable", "sign-in-required", "authorization-required", "tailscale-required", "not-running", "funnel-unsupported", "needs-attention"].includes(remote.state);
  toggle.disabled = state.tailscaleSaving || (!remote.enabled && (!remote.installed || blockedState || (publicFunnel && !passwordLocked)));
  toggle.closest(".tailscale-setting").classList.toggle("disabled", toggle.disabled);
  toggle.closest(".config-toggle").querySelector("em").textContent = remote.enabled ? "On" : "Off";
  setText("tailscale-toggle-help", windows
    ? "Tailscale must already be installed, running, and signed in. Windows asks for administrator approval only for an explicit Enable, Disable, or Verify operation."
    : state.runtimeMode === "linux"
      ? "Tailscale must already be installed, running, and signed in. A Linux host administrator authorizes the fixed Inspect/Enable/Disable adapter once; Manager remains unprivileged."
      : "The package's isolated official Tailscale userspace runtime must be explicitly enabled and signed in from its console. Manager remains non-root and receives no credential or provider CLI.");

  const allowedAuthorizationCommands = new Set([
    "sudo tautweekly remote-access-authorize",
    "./tautweekly.sh remote-access-login",
    "/opt/tautweekly/bin/tautweekly-funnel login",
  ]);
  const authorizationCommand = allowedAuthorizationCommands.has(remote.hostAuthorizationCommand)
    ? remote.hostAuthorizationCommand : "";
  byId("tailscale-host-authorization").hidden = !remote.hostAuthorizationRequired || authorizationCommand === "";
  setText("tailscale-host-authorization-command", authorizationCommand || "sudo tautweekly remote-access-authorize");
  byId("tailscale-copy-authorization").disabled = state.tailscaleSaving || authorizationCommand === "";

  const hasURL = validTailscaleURL(remote.url || "") && (!publicFunnel || Boolean(remote.enabled));
  const link = byId("tailscale-url");
  link.hidden = !hasURL;
  byId("tailscale-url-empty").hidden = hasURL;
  byId("tailscale-copy-button").hidden = !hasURL;
  if (hasURL) {
    link.href = remote.url;
    link.textContent = remote.url;
  } else {
    link.removeAttribute("href");
    link.textContent = "";
  }

  setText("tailscale-password-status", passwordLocked ? "Required lock enabled" : "Required before enable");
  const passwordSetup = byId("tailscale-password-setup-button");
  passwordSetup.hidden = !publicFunnel || passwordLocked;
  passwordSetup.disabled = state.tailscaleSaving;
  const boundary = byId("tailscale-security-boundary");
  boundary.innerHTML = "<strong>Funnel makes the Manager login page publicly reachable over HTTPS.</strong> Remote viewers do not need Tailscale or a VPN, so the Manager password lock is mandatory. Use a unique password; Internet login attempts remain a brute-force risk.";

  byId("tailscale-refresh-button").hidden = false;
  byId("tailscale-refresh-button").textContent = windows ? "Verify with Windows" : "Verify publication";
  byId("tailscale-refresh-button").disabled = state.tailscaleSaving || !remote.installed || remote.hostAuthorizationRequired;
  byId("tailscale-copy-button").disabled = state.tailscaleSaving;
  const setupLink = byId("tailscale-setup-link");
  const hasSetupURL = validTailscaleSetupURL(state.tailscaleSetupURL);
  setupLink.hidden = !hasSetupURL;
  setupLink.textContent = "Approve Funnel in Tailscale";
  byId("tailscale-provider-warning").hidden = !hasSetupURL;
  if (hasSetupURL) setupLink.href = state.tailscaleSetupURL;
  else setupLink.removeAttribute("href");
  const message = byId("tailscale-settings-message");
  if (state.tailscaleError) message.textContent = state.tailscaleError;
  else if (state.tailscaleSaving) message.textContent = state.tailscaleVerifying
    ? `${windows ? "Waiting for Windows approval, then v" : "V"}erifying the exact Tailscale Funnel route...`
    : state.tailscaleRequestedOperation === "disable"
      ? "Stopping and verifying the exact TautWeekly Funnel..."
      : "Starting and verifying the exact TautWeekly Funnel...";
  else message.textContent = remote.enabled && remote.active
    ? "The public address opens the password-protected Manager; remote viewers do not need Tailscale."
    : presentation.status;
  byId("tailscale-recovery-copy").innerHTML = "<strong>Local access remains the recovery path.</strong> Password-lock disable, local access reset, explicit stop, recovery, adapter revocation, and uninstall first turn off and verify only the exact TautWeekly Funnel. If verification fails, the password and application stay in place. Ordinary update and rollback preserve the retained Funnel preference and fixed route.";
}

async function updateTailscaleAccess() {
  const requested = byId("tailscale-enabled").checked;
  state.tailscaleSaving = true;
  state.tailscaleRequestedOperation = requested ? "enable" : "disable";
  state.tailscaleError = "";
  state.tailscaleSetupURL = "";
  renderTailscaleSettings();
  try {
    state.tailscale = await request("/api/v1/remote-access/tailscale", {
      method: "PUT",
      body: JSON.stringify({ operation: state.tailscaleRequestedOperation }),
    });
    setGlobalStatus(requested ? (state.tailscale.active ? "Public Tailscale Funnel verified active." : "Funnel configured locally; public publication is pending.") : "Public Tailscale Funnel disabled.", true);
  } catch (error) {
    state.tailscaleError = error.message;
    if (error.code === "tailscale-provider-approval-required" && validTailscaleSetupURL(error.fields?.setupUrl || "")) state.tailscaleSetupURL = error.fields.setupUrl;
    setGlobalStatus(error.message, true);
    try { state.tailscale = await request("/api/v1/remote-access/tailscale"); }
    catch (_) { /* Preserve the actionable update error. */ }
  } finally {
    state.tailscaleSaving = false;
    state.tailscaleRequestedOperation = "";
    renderTailscaleSettings();
    renderIntegrationStatus();
  }
}

async function copyTailscaleAuthorizationCommand() {
  const command = state.tailscale?.hostAuthorizationCommand;
  if (!["sudo tautweekly remote-access-authorize", "./tautweekly.sh remote-access-login", "/opt/tautweekly/bin/tautweekly-funnel login"].includes(command)) return;
  try {
    await navigator.clipboard.writeText(command);
    setGlobalStatus("Package authorization command copied.", true);
  } catch (_) {
    state.tailscaleError = "The browser could not copy the command. Select it manually instead.";
    renderTailscaleSettings();
  }
}

async function refreshTailscaleAccess() {
  state.tailscaleSaving = true;
  state.tailscaleVerifying = true;
  state.tailscaleRequestedOperation = "verify";
  state.tailscaleError = "";
  state.tailscaleSetupURL = "";
  renderTailscaleSettings();
  try {
    state.tailscale = await request("/api/v1/remote-access/tailscale/verify", { method: "POST" });
    setGlobalStatus(state.tailscale.active
      ? "Public Tailscale Funnel verified active."
      : "Funnel remains configured locally; public publication is pending.", true);
  } catch (error) {
    state.tailscaleError = error.message;
    if (error.code === "tailscale-provider-approval-required" && validTailscaleSetupURL(error.fields?.setupUrl || "")) state.tailscaleSetupURL = error.fields.setupUrl;
    setGlobalStatus(error.message, true);
  } finally {
    state.tailscaleSaving = false;
    state.tailscaleVerifying = false;
    state.tailscaleRequestedOperation = "";
    renderTailscaleSettings();
    renderIntegrationStatus();
  }
}

async function loadTailscaleAccess() {
  try {
    state.tailscale = await request("/api/v1/remote-access/tailscale");
  } catch (error) {
    state.tailscaleError = error.message;
  }
  renderTailscaleSettings();
  renderIntegrationStatus();
  const route = window.TautWeeklyUpdateUI.routeFromHash(window.location.hash);
  if (route.view === "about" && route.section === "tailscale") {
    selectView(route.view, { section: route.section, updateHistory: false });
  }
}

async function copyTailscaleURL() {
  if (!validTailscaleURL(state.tailscale?.url || "")) return;
  try {
    await navigator.clipboard.writeText(state.tailscale.url);
    setGlobalStatus("Public Funnel address copied.", true);
  } catch (_) {
    state.tailscaleError = "The browser could not copy the public address. Select it manually instead.";
    renderTailscaleSettings();
  }
}

function accessSurfaceLabel() {
  if (state.capabilities?.accessLabel) return state.capabilities.accessLabel;
  const platform = String(state.status?.platform || "").toLowerCase();
  if (platform === "windows") return "Browser access";
  if (platform === "linux") return "Linux service access";
  if (platform === "freebsd") return "Container access";
  return "Manager access";
}

function openAccessSettings() {
  selectView("about");
  requestAnimationFrame(() => {
    byId("access-settings-panel").scrollIntoView({ block: "center", behavior: "smooth" });
    byId("access-password").focus({ preventScroll: true });
  });
}

function openTailscaleSettings() {
  if (state.tailscale?.supported !== true) return;
  selectView("about", { section: "tailscale" });
}

async function submitAccessPassword(event) {
  event.preventDefault();
  const password = byId("access-password").value;
  const confirmation = byId("access-password-confirm").value;
  const message = byId("access-settings-message");
  if (password !== confirmation) {
    message.textContent = "The password confirmation does not match.";
    byId("access-password-confirm").focus();
    return;
  }
  const button = byId("access-password-submit");
  button.disabled = true;
  setSwappingButtonText("access-password-submit", state.authAccess?.passwordLockEnabled ? "Changing password..." : "Enabling lock...");
  message.textContent = state.authAccess?.passwordLockEnabled ? "Changing the local Manager password..." : "Enabling the local Manager password lock...";
  try {
    state.authAccess = await request("/api/v1/auth/access/password", { method: "POST", body: JSON.stringify({ password }) });
    byId("access-password").value = "";
    byId("access-password-confirm").value = "";
    concealMaskedInputs(byId("access-password-form"));
    renderAccessSettings();
    message.textContent = "Manager access settings saved. This browser remains signed in.";
    setGlobalStatus("Manager password lock updated.", true);
    await loadTailscaleAccess();
  } catch (error) {
    message.textContent = error.message;
  } finally {
    button.disabled = false;
    renderAccessSettings();
  }
}

async function disableAccessPassword() {
  const button = byId("access-disable-button");
  const message = byId("access-settings-message");
  button.disabled = true;
  setSwappingButtonText("access-disable-button", "Disabling lock...");
  const publicFunnelConfigured = state.tailscale?.networkKind === "public-funnel" && Boolean(state.tailscale?.cleanupRequired || state.tailscale?.enabled);
  message.textContent = publicFunnelConfigured
    ? "Turning off and verifying the public Funnel before disabling the password lock. Host approval may be required..."
    : "Disabling the optional Manager password lock...";
  try {
    state.authAccess = await request("/api/v1/auth/access/disable", { method: "POST", body: "{}" });
    renderAccessSettings();
    message.textContent = "Password lock disabled. The Manager remains limited to this computer.";
    setGlobalStatus("Manager returned to trusted-local access.", true);
    await loadTailscaleAccess();
  } catch (error) {
    message.textContent = error.message;
  } finally {
    button.disabled = false;
    setSwappingButtonText("access-disable-button", "Disable password lock");
  }
}

function clearUpdateCheckAvailabilityTimer() {
  clearTimeout(updateCheckAvailabilityTimer);
  updateCheckAvailabilityTimer = undefined;
}

function scheduleUpdateCheckAvailabilityRefresh(cooldown) {
  clearUpdateCheckAvailabilityTimer();
  if (!cooldown.active || byId("app-shell").hidden) return;
  const delayMilliseconds = Math.min(cooldown.delayMilliseconds + 1000, 60 * 60 * 1000);
  updateCheckAvailabilityTimer = setTimeout(() => {
    updateCheckAvailabilityTimer = undefined;
    if (byId("app-shell").hidden) return;
    renderUpdates();
  }, delayMilliseconds);
}

function updateStatePresentation(update = state.updates || {}) {
  switch (update.state) {
  case "current": return { label: "Current", tone: "good", summary: "The running application and every reported package layer match the latest stable release." };
  case "update-available": return { label: "Update available", tone: "update-available", summary: "A newer verified stable release is available. Follow the update owner and package-specific steps below." };
  case "legacy": return { label: "Legacy wrapper", tone: "bad", summary: "The running image reports an older or missing host-adapter contract. Update the host package or saved platform template through its owner." };
  case "mismatched": return { label: "Version mismatch", tone: "bad", summary: "The reported application/image and host package versions do not match. Use the platform recovery/update path to advance them together." };
  case "newer": return { label: "Newer than stable", tone: "neutral", summary: "This application is newer than the latest stable release. The Manager will not offer a rollback or downgrade." };
  default: return { label: "Unknown", tone: "neutral", summary: "No verified stable comparison is available yet. Normal Manager and newsletter health remain local and independent." };
  }
}

function displayUpdateVersion(value, unavailable = "Not reported") {
  return value ? `v${value}` : unavailable;
}

function readableList(values) {
  if (values.length < 2) return values[0] || "";
  if (values.length === 2) return `${values[0]} and ${values[1]}`;
  return `${values.slice(0, -1).join(", ")}, and ${values.at(-1)}`;
}

function releaseAlignmentSummary(update) {
  const managerVersion = update.managerVersion || state.about?.version || "";
  const layers = [
    ["Application", update.applicationVersion],
    ...(update.imageVersion ? [["Container image", update.imageVersion]] : []),
    [update.packageLabel || "Host package", update.packageVersion],
  ];
  const matching = layers.filter(([, version]) => managerVersion && version === managerVersion).map(([label]) => label);
  const different = layers.filter(([, version]) => version && version !== managerVersion).map(([label, version]) => `${label} ${displayUpdateVersion(version)}`);
  const missing = layers.filter(([, version]) => !version).map(([label]) => `${label} not reported`);
  const parts = [];
  if (matching.length) parts.push(`${readableList(matching)} ${matching.length === 1 ? "matches" : "match"} Manager build`);
  parts.push(...different, ...missing);
  return parts.join(" · ") || "Release alignment unavailable";
}

function renderUpdates() {
  const update = state.updates || {};
  renderUpdateStatusButton(update);
  byId("update-settings-panel").classList.toggle("update-attention-glow", update.state !== "current");
  const presentation = updateStatePresentation(update);
  setChip("update-settings-chip", state.updateChecking || update.checkInProgress ? "Checking" : presentation.label, state.updateChecking || update.checkInProgress ? "pending" : presentation.tone);
  setText("update-settings-summary", presentation.summary);
  setText("update-manager-version", displayUpdateVersion(update.managerVersion || state.about?.version));
  setText("update-latest-version", displayUpdateVersion(update.latestStableVersion, "Not checked"));
  setText("update-platform", titleCase(state.status?.platform));
  setText("update-runtime-profile", titleCase(update.runtimeProfile || state.capabilities?.runtimeProfile));
  setText("update-image-repository", update.imageRepository || "Not applicable");
  setText("update-image-reference", update.recommendedImageReference || "Not applicable");
  setText("update-migration-state", titleCase(update.migrationState || "not-applicable"));
  setText("update-release-alignment", releaseAlignmentSummary(update));
  const hostAdapterApplicable = Boolean(update.hostAdapterState) && update.hostAdapterState !== "not-applicable";
  const hostAdapterRow = byId("update-host-adapter-row");
  hostAdapterRow.hidden = !hostAdapterApplicable;
  hostAdapterRow.parentElement.classList.toggle("host-adapter-hidden", !hostAdapterApplicable);
  if (hostAdapterApplicable) {
    setText("update-host-adapter", `${update.hostAdapterVersion ? `API ${update.hostAdapterVersion}` : "Not reported"} · ${titleCase(update.hostAdapterState)}`);
  }
  setText("update-channel", titleCase(update.updateChannel || "stable"));
  setText("update-last-success", formatDate(update.lastSuccessfulCheckUtc));

  const failure = byId("update-failure");
  failure.hidden = !update.lastFailure;
  if (update.lastFailure) {
    setText("update-failure-message", update.lastFailure.message);
    setText("update-failure-time", `${titleCase(update.lastFailure.action)} · ${formatDate(update.lastFailure.occurredAtUtc)}`);
  }

  const guidance = update.guidance || {};
  setText("update-owner", guidance.owner || "Host administrator");
  setText("update-guidance-summary", guidance.summary || "Use the platform-owned update path for this package.");
  const steps = byId("update-guidance-steps");
  steps.replaceChildren();
  for (const value of guidance.steps || []) {
    const item = document.createElement("li");
    item.textContent = value;
    steps.append(item);
  }
  const commandPanel = byId("update-command-panel");
  commandPanel.hidden = !guidance.command;
  setText("update-command", guidance.command || "No universal host command");
  const docsLink = byId("update-docs-link");
  if (guidance.docsUrl) docsLink.href = guidance.docsUrl;

  const notes = byId("update-release-notes");
  notes.hidden = !update.releaseNotesUrl;
  if (update.releaseNotesUrl) notes.href = update.releaseNotesUrl;

  const cooldown = window.TautWeeklyUpdateUI.updateCheckCooldown(update);
  scheduleUpdateCheckAvailabilityRefresh(cooldown);
  const backoffActive = cooldown.active;
  const checkButton = byId("update-check-button");
  checkButton.disabled = state.updateChecking || Boolean(update.checkInProgress) || Boolean(backoffActive);
  setSwappingButtonText("update-check-button", state.updateChecking || update.checkInProgress ? "Checking..." : backoffActive ? "Check available shortly" : "Check now");

  const installAvailable = Boolean(update.installSupported);
  const installRow = byId("update-install-confirm-row");
  const installButton = byId("update-install-button");
  if (!installAvailable) byId("update-install-confirm").checked = false;
  installRow.hidden = !installAvailable;
  installButton.hidden = !installAvailable;
  installButton.disabled = !installAvailable || !byId("update-install-confirm").checked || state.updateInstalling || ["starting", "running"].includes(update.installState);
  setSwappingButtonText("update-install-button", state.updateInstalling ? "Starting verified updater..." : ["starting", "running"].includes(update.installState) ? "Verified updater running..." : "Install update");

  const message = byId("update-settings-message");
  if (state.updateChecking) message.textContent = state.updateCheckBackground
    ? "Refreshing stale stable-release status in the background with an eight-second deadline. Dashboard rendering and local health remain independent."
    : "Contacting the fixed stable-release endpoint with an eight-second deadline. No application or package file is being changed.";
  else if (state.updateInstalling) message.textContent = "Starting the existing verified Windows updater. Approve the Windows administrator prompt if it appears.";
  else if (["starting", "running"].includes(update.installState)) message.textContent = "The verified Windows updater is running. This page will reconnect and refresh automatically after the Manager restarts.";
  else if (update.installState === "failed") message.textContent = "The verified Windows updater stopped before completing. Review the sanitized failure above, then check again before retrying.";
  else if (update.installState === "completed") message.textContent = "The verified Windows updater completed. Refreshing local package status.";
  else if (backoffActive) message.textContent = `The next manual check is available after ${formatDate(update.nextCheckAllowedAtUtc)}. This bounded delay prevents repeated upstream requests.`;
  else if (update.lastFailure?.action === "check") message.textContent = "The last check failed safely. Cached local status remains available, and newsletter delivery is unaffected.";
  else message.textContent = "Normal Manager and dashboard health never depend on Internet availability. Header Refresh reloads local status, repeats the saved Tautulli choices lookup when configuration is ready, and performs an eligible stable-release check; Check now remains update-only.";
}

function renderUpdateStatusButton(update) {
  const indicator = window.TautWeeklyUpdateUI.updateIndicator(update);
  const button = byId("update-status-button");
  button.hidden = !indicator.visible;
  if (!indicator.visible) return;
  button.setAttribute("aria-label", indicator.label);
  button.dataset.tooltip = indicator.label;
}

async function waitForActiveUpdateCheck(expectedAuthenticationEpoch = authenticationEpoch) {
  for (let attempt = 0; attempt < 36; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 250));
    if (expectedAuthenticationEpoch !== authenticationEpoch || byId("app-shell").hidden) return;
    const updates = await request("/api/v1/updates");
    if (expectedAuthenticationEpoch !== authenticationEpoch || byId("app-shell").hidden) return;
    state.updates = updates;
    renderUpdates();
    if (!state.updates.checkInProgress) return;
  }
}

async function runUpdateCheck(background = false) {
  if (state.updateChecking) return;
  const updateAuthenticationEpoch = authenticationEpoch;
  state.updateChecking = true;
  state.updateCheckBackground = background;
  renderUpdates();
  try {
    const updates = await request("/api/v1/updates/check", { method: "POST", body: "{}" });
    if (updateAuthenticationEpoch !== authenticationEpoch || byId("app-shell").hidden) return;
    state.updates = updates;
    if (!background) setGlobalStatus(state.updates.state === "update-available" ? "Stable update found." : "Stable update check completed.", true);
  } catch (error) {
    if (updateAuthenticationEpoch !== authenticationEpoch || byId("app-shell").hidden) return;
    if (background && error.code === "check-in-progress") {
      try { await waitForActiveUpdateCheck(updateAuthenticationEpoch); } catch (_) { /* A later authenticated refresh can recover local status. */ }
    } else if (background && error.code === "check-backoff") {
      try {
        const updates = await request("/api/v1/updates");
        if (updateAuthenticationEpoch === authenticationEpoch && !byId("app-shell").hidden) state.updates = updates;
      } catch (_) {
        // Keep the already rendered cached state.
      }
    } else {
      byId("update-settings-message").textContent = error.message;
      if (!background) setGlobalStatus(error.message, true);
    }
  } finally {
    if (updateAuthenticationEpoch === authenticationEpoch && !byId("app-shell").hidden) {
      state.updateChecking = false;
      state.updateCheckBackground = false;
      renderUpdates();
    }
  }
}

function checkForUpdates() {
  return runUpdateCheck(false);
}

function checkForUpdatesInBackground() {
  if (state.updateChecking || !state.updates?.backgroundCheckRecommended) return;
  void runUpdateCheck(true);
}

async function installUpdate() {
  if (state.updateInstalling || !byId("update-install-confirm").checked) return;
  state.updateInstalling = true;
  renderUpdates();
  try {
    state.updates = await request("/api/v1/updates/install", { method: "POST", body: "{}" });
    setGlobalStatus("Verified Windows updater started.", true);
    beginUpdateInstallPolling(state.updates.latestStableVersion);
  } catch (error) {
    byId("update-settings-message").textContent = error.message;
    setGlobalStatus(error.message, true);
  } finally {
    state.updateInstalling = false;
    renderUpdates();
  }
}

function stopUpdateInstallPolling() {
  clearTimeout(updateInstallPollTimer);
  updateInstallPollTimer = undefined;
  updateInstallExpectedVersion = "";
  updateInstallSawDisconnect = false;
  updateInstallPollDeadline = 0;
}

function beginUpdateInstallPolling(expectedVersion) {
  stopUpdateInstallPolling();
  updateInstallExpectedVersion = expectedVersion || "";
  updateInstallPollDeadline = Date.now() + 15 * 60 * 1000;
  updateInstallPollTimer = setTimeout(pollUpdateInstall, 1000);
}

async function pollUpdateInstall() {
  if (!updateInstallExpectedVersion) return;
  try {
    const update = await request("/api/v1/updates");
    state.updates = update;
    const active = ["starting", "running"].includes(update.installState);
    if (update.managerVersion === updateInstallExpectedVersion || (updateInstallSawDisconnect && !active)) {
      stopUpdateInstallPolling();
      setGlobalStatus("Manager update finished. Loading the updated application...");
      window.location.reload();
      return;
    }
    renderUpdates();
    if (!active) {
      stopUpdateInstallPolling();
      setGlobalStatus(update.installState === "failed" ? "Verified updater did not complete." : "Verified updater finished without a Manager restart.", true);
      return;
    }
  } catch (error) {
    if (error.status === 401) {
      stopUpdateInstallPolling();
      window.location.reload();
      return;
    }
    updateInstallSawDisconnect = true;
    byId("update-settings-message").textContent = "The Manager is restarting for the verified update. Reconnecting automatically...";
    setGlobalStatus("Reconnecting to the updated Manager...");
  }
  if (Date.now() >= updateInstallPollDeadline) {
    stopUpdateInstallPolling();
    byId("update-settings-message").textContent = "Automatic reconnection timed out. The updater may still be awaiting Windows approval; review the prompt, then use Refresh if needed.";
    return;
  }
  updateInstallPollTimer = setTimeout(pollUpdateInstall, 1500);
}

async function copyUpdateCommand() {
  const command = state.updates?.guidance?.command || "";
  if (!command) return;
  try {
    if (!navigator.clipboard?.writeText) throw new Error("Clipboard API unavailable");
    await navigator.clipboard.writeText(command);
  } catch (_) {
    const fallback = document.createElement("textarea");
    fallback.value = command;
    fallback.setAttribute("readonly", "");
    fallback.style.position = "fixed";
    fallback.style.opacity = "0";
    document.body.append(fallback);
    fallback.select();
    const copied = document.execCommand("copy");
    fallback.remove();
    if (!copied) {
      byId("update-settings-message").textContent = "The browser could not copy the command. Select the displayed command manually.";
      return;
    }
  }
  setSwappingButtonText("update-copy-command", "Copied");
  setTimeout(() => setSwappingButtonText("update-copy-command", "Copy command"), 1600);
}

function renderAbout() {
  const events = state.diagnostics?.events || [];
  setText("diagnostics-count", events.length ? `${events.length} retained` : "No events");
  setText("diagnostics-retention", `Count-only FIFO keeps the newest ${state.diagnostics?.maximumEntries || 20} events; each new overflow event removes the oldest.`);
  const container = byId("diagnostics-list");
  container.replaceChildren();
  if (!events.length) {
    const empty = document.createElement("p");
    empty.className = "diagnostics-empty";
    empty.textContent = "No setup or verification events have been recorded.";
    container.append(empty);
    return;
  }
  for (const event of events) {
    const row = document.createElement("article");
    row.className = "diagnostic-row";
    const copy = document.createElement("div");
    const heading = document.createElement("h3");
    heading.textContent = event.summary;
    const metadata = document.createElement("p");
    metadata.textContent = `${diagnosticAreaLabel(event.area)} · Support code ${event.code}`;
    copy.append(heading, metadata);
    const evidence = document.createElement("div");
    evidence.className = "diagnostic-evidence";
    const chip = document.createElement("span");
    chip.className = `state-chip ${event.outcome === "passed" ? "good" : event.outcome === "failed" ? "bad" : "neutral"}`;
    chip.textContent = titleCase(event.outcome);
    const timestamp = document.createElement("small");
    timestamp.textContent = formatDate(event.recordedAtUtc);
    evidence.append(chip, timestamp);
    row.append(copy, evidence);
    container.append(row);
  }
}

function diagnosticAreaLabel(area) {
  return area === "lan-verification" ? "Connection Verification" : titleCase(area);
}

function openPreview(id, button, options = {}) {
  state.selectedPreviewID = id;
  document.querySelectorAll(".preview-button").forEach((element) => element.classList.remove("active"));
  button.classList.add("active");
  byId("preview-placeholder").hidden = true;
  const frame = byId("preview-frame");
  const reloadKey = String(options.reloadKey || "");
  const reloadRequested = reloadKey && frame.dataset.previewReloadKey !== reloadKey;
  if (frame.dataset.previewId !== id || reloadRequested) {
    const query = reloadKey ? `?refresh=${encodeURIComponent(reloadKey)}` : "";
    frame.src = `/preview/${encodeURIComponent(id)}${query}`;
    frame.dataset.previewId = id;
    if (reloadKey) frame.dataset.previewReloadKey = reloadKey;
    else frame.removeAttribute("data-preview-reload-key");
  }
  frame.hidden = false;
}

function initializePreviewIndexNavigation() {
  const frame = byId("preview-frame");
  const documentRoot = frame.contentDocument;
  const selected = state.previews.find((preview) => preview.id === state.selectedPreviewID);
  if (!documentRoot || !/-00-index(?:\.html)?$/i.test(selected?.name || "")) return;
  documentRoot.querySelectorAll("a[href]").forEach((link) => {
    let fileName = "";
    try {
      const target = new URL(link.getAttribute("href"), documentRoot.baseURI);
      fileName = decodeURIComponent(target.pathname.split("/").pop() || "").toLowerCase();
    } catch (_) {
      return;
    }
    const preview = state.previews.find((candidate) => `${candidate.name}.html`.toLowerCase() === fileName);
    if (!preview) return;
    link.addEventListener("click", (event) => {
      event.preventDefault();
      const button = byId("preview-list").querySelector(`[data-preview-id="${CSS.escape(preview.id)}"]`);
      if (button) openPreview(preview.id, button);
    });
  });
}

function selectView(name, options = {}) {
  const section = options.section || "";
  if (options.updateHistory !== false) {
    const hash = window.TautWeeklyUpdateUI.hashForRoute(name, section);
    if (window.location.hash !== hash) {
      history.pushState({ managerView: name, managerSection: section }, "", `${window.location.pathname}${window.location.search}${hash}`);
      lastRoutedURL = window.location.href;
    }
  }
  if (name !== "configuration") clearAllRevealedSecrets();
  document.querySelectorAll("[data-user-combobox].open").forEach((container) => setUserComboboxOpen(container, false));
  document.querySelectorAll("[data-panel]").forEach((panel) => { panel.hidden = panel.dataset.panel !== name; });
  document.querySelectorAll("[data-view]").forEach((button) => {
    const active = button.dataset.view === name;
    button.classList.toggle("active", active);
    if (active) button.setAttribute("aria-current", "page");
    else button.removeAttribute("aria-current");
  });
  window.scrollTo({ top: 0, behavior: "auto" });
  if (section === "updates" && name === "about") {
    requestAnimationFrame(() => {
      byId("update-settings-panel").scrollIntoView({ block: "start", behavior: "smooth" });
      byId("update-settings-heading").focus({ preventScroll: true });
    });
  } else if (section === "tailscale" && name === "about" && !byId("tailscale-settings-panel").hidden) {
    requestAnimationFrame(() => {
      byId("tailscale-settings-panel").scrollIntoView({ block: "start", behavior: "smooth" });
      byId("tailscale-settings-heading").focus({ preventScroll: true });
    });
  } else if (section === "cache" && name === "configuration") {
    requestAnimationFrame(() => {
      const cacheToggle = byId("config-DeletedItemCacheEnabled");
      cacheToggle.scrollIntoView({ block: "center", behavior: "smooth" });
      cacheToggle.focus({ preventScroll: true });
    });
  } else {
    byId("main-content").focus({ preventScroll: true });
  }
}

function applyLocationRoute() {
  if (byId("app-shell").hidden || lastRoutedURL === window.location.href) return;
  lastRoutedURL = window.location.href;
  const route = window.TautWeeklyUpdateUI.routeFromHash(window.location.hash);
  selectView(route.view, { section: route.section, updateHistory: false });
}

function openUpdateSettings() {
  selectView("about", { section: "updates" });
}

async function submitPair(event) {
  event.preventDefault();
  const password = byId("pair-password").value;
  if (password !== byId("pair-password-confirm").value) {
    setAuthMessage("The password confirmation does not match.");
    return;
  }
  setAuthMessage("Pairing this browser…", false);
  try {
    const session = await request("/api/v1/auth/pair", { method: "POST", body: JSON.stringify({ token: byId("pair-token").value, password }) });
    state.csrfToken = session.csrfToken;
    concealMaskedInputs(byId("pair-form"));
    await enterApplication();
  } catch (error) {
    setAuthMessage(error.message);
  }
}

async function submitLogin(event) {
  event.preventDefault();
  setAuthMessage("Signing in…", false);
  try {
    const session = await request("/api/v1/auth/login", { method: "POST", body: JSON.stringify({ password: byId("login-password").value }) });
    state.csrfToken = session.csrfToken;
    byId("login-password").value = "";
    concealMaskedInputs(byId("login-form"));
    await enterApplication();
  } catch (error) {
    setAuthMessage(error.message);
  }
}

async function logout() {
  clearAllRevealedSecrets();
  try { await request("/api/v1/auth/logout", { method: "POST" }); }
  finally { state.csrfToken = ""; showAuthentication(); }
}

function showAuthentication() {
  authenticationEpoch += 1;
  applicationRefreshPromise = null;
  byId("refresh-button").disabled = false;
  stopUpdateInstallPolling();
  clearUpdateCheckAvailabilityTimer();
  clearAllRevealedSecrets();
  closeSecretRevealDialog();
  concealMaskedInputs(byId("auth-shell"));
  state.discovery = null;
  state.discoveryError = "";
  state.discoveryRunning = false;
  state.updateChecking = false;
  state.updateCheckBackground = false;
  state.operationStarting = false;
  state.operationStartingType = "";
  byId("discovery-libraries").replaceChildren();
  byId("discovery-users").replaceChildren();
  byId("managed-user-delivery-list").replaceChildren();
  byId("managed-user-delivery-addresses").hidden = true;
  renderUserComboboxes();
  clearTimeout(operationPollTimer);
  clearTimeout(schedulePollTimer);
  clearTimeout(deliveryStatusPollTimer);
  byId("app-shell").hidden = true;
  byId("auth-shell").hidden = false;
  byId("pair-form").hidden = true;
  byId("login-form").hidden = false;
  byId("login-password").focus();
}

function createMaterialIcon(name) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.classList.add("ui-icon");
  svg.setAttribute("viewBox", "0 -960 960 960");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
  use.setAttribute("href", `#icon-${name}`);
  svg.append(use);
  return materializeMaterialIcon(svg);
}

function setChip(id, text, tone, iconName = "") {
  const chip = byId(id);
  const resolvedTone = tone || "neutral";
  let label = chip.querySelector(".state-chip-label");
  if (!label) {
    label = document.createElement("span");
    label.className = "state-chip-label";
    label.textContent = chip.textContent;
    chip.replaceChildren(label);
  }
  const currentIcon = chip.querySelector(":scope > .ui-icon");
  if (iconName && (!currentIcon || chip.dataset.iconName !== iconName)) {
    const nextIcon = createMaterialIcon(iconName);
    if (currentIcon) currentIcon.replaceWith(nextIcon);
    else chip.insertBefore(nextIcon, label);
  } else if (!iconName && currentIcon) {
    currentIcon.remove();
  }
  chip.dataset.iconName = iconName;
  setSwappingElementText(label, text);
  chip.className = `state-chip ${resolvedTone}`;
  const card = chip.closest(".health-card,.operation-strip,.current-operation,.setup-workflow-steps article,.setup-workflow");
  if (card) {
    card.classList.remove("state-card-good", "state-card-bad", "state-card-pending", "state-card-neutral", "state-card-waiting", "state-card-warning");
    card.classList.add(`state-card-${resolvedTone}`);
  }
}
function setText(id, value) { byId(id).textContent = value || "Not recorded"; }
function setSwappingText(id, value) {
  setSwappingElementText(byId(id), value);
}
function setSwappingButtonText(id, value) {
  setSwappingButtonElementText(byId(id), value);
}
function setSwappingButtonElementText(button, value) {
  let label = button.querySelector(".button-state-label");
  if (!label) {
    label = document.createElement("span");
    label.className = "button-state-label";
    label.textContent = button.textContent;
    button.replaceChildren(label);
  }
  setSwappingElementText(label, value);
}
function setSwappingElementText(element, value) {
  const next = value || "Not recorded";
  if (element.textContent === next) return;
  element.classList.remove("schedule-state-swap");
  element.textContent = next;
  void element.offsetWidth;
  element.classList.add("schedule-state-swap");
}
function setAuthMessage(message, isError = true) { const element = byId("auth-message"); element.textContent = message; element.classList.toggle("error", isError); }

let statusTimer;
function setGlobalStatus(message, dismiss = false) {
  const element = byId("global-status");
  clearTimeout(statusTimer);
  element.textContent = message;
  element.classList.add("visible");
  if (dismiss) statusTimer = setTimeout(() => element.classList.remove("visible"), 2600);
}

function overallHeading(overall) {
  switch (overall) {
  case "healthy": return "The local management surface is responding.";
  case "unconfigured": return "TautWeekly is ready for guided setup.";
  case "blocked": return "Configuration needs attention before delivery.";
  default: return "The manager is online with a degraded signal.";
  }
}
function overallCopy(overall) {
  switch (overall) {
  case "healthy": return "Status is read from this host. No settings were changed and no external connection tests were run.";
  case "unconfigured": return "No private configuration was found. Automatic delivery remains unavailable until setup is completed.";
  case "blocked": return "A configuration file exists but cannot be interpreted safely. The manager will not guess or coerce its values.";
  default: return "One or more optional status probes could not be completed. Review the health cards below.";
  }
}
function formatDate(value) {
  if (!value) return "Not recorded";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Not recorded";
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(date);
}
function formatBytes(value) {
  if (!Number.isFinite(value) || value < 1024) return `${value || 0} B`;
  if (value < 1024 * 1024) return `${Math.round(value / 1024)} KB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MB`;
}
function formatDuration(value) {
  if (!Number.isFinite(value) || value < 0) return "Duration unavailable";
  if (value < 1000) return `${Math.round(value)} ms`;
  if (value < 60000) return `${(value / 1000).toFixed(value < 10000 ? 1 : 0)} s`;
  return `${Math.floor(value / 60000)}m ${Math.round((value % 60000) / 1000)}s`;
}
function yesNo(value) { return value ? "Yes" : "No"; }
function displayValue(value) {
  if (value === null || value === undefined || value === "") return "Not set";
  if (Array.isArray(value)) return value.length ? value.join(", ") : "None selected";
  if (typeof value === "object") return JSON.stringify(value);
  if (typeof value === "boolean") return value ? "Enabled" : "Disabled";
  return String(value);
}

byId("pair-form").addEventListener("submit", submitPair);
byId("login-form").addEventListener("submit", submitLogin);
byId("access-password-form").addEventListener("submit", submitAccessPassword);
byId("access-disable-button").addEventListener("click", disableAccessPassword);
byId("secret-reveal-form").addEventListener("submit", submitSecretReveal);
byId("secret-reveal-cancel").addEventListener("click", closeSecretRevealDialog);
byId("secret-reveal-dialog").addEventListener("close", () => {
  byId("secret-reveal-password").value = "";
  concealMaskedInputs(byId("secret-reveal-form"));
  byId("secret-reveal-message").textContent = "";
  pendingSecretReveal = null;
});
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    clearAllRevealedSecrets();
    clearTimeout(deliveryStatusPollTimer);
    return;
  }
  if (!byId("app-shell").hidden && state.status) void pollDeliveryStatus();
});
materializeMaterialIcons();
initializeMaskedInputToggles();
document.querySelectorAll("[data-user-combobox]").forEach(initializeUserCombobox);
byId("preview-frame").addEventListener("load", initializePreviewIndexNavigation);
document.addEventListener("pointerdown", (event) => {
  document.querySelectorAll("[data-user-combobox].open").forEach((container) => {
    if (!container.contains(event.target)) setUserComboboxOpen(container, false);
  });
  document.querySelectorAll(".title-gif-field.open").forEach((container) => {
    if (!container.contains(event.target)) {
      container.classList.remove("open");
      const picker = container.querySelector("[data-title-gif-picker]");
      const trigger = container.querySelector(".title-gif-trigger");
      if (picker) picker.hidden = true;
      trigger?.setAttribute("aria-expanded", "false");
    }
  });
});
byId("config-form").addEventListener("submit", submitConfig);
byId("config-reset-button").addEventListener("click", renderConfigEditor);
byId("direct-plex-review-button").addEventListener("click", reviewDirectPlexFields);
byId("discovery-confirm").addEventListener("change", renderDiscovery);
byId("discovery-run-button").addEventListener("click", runTautulliDiscovery);
byId("verification-confirm").addEventListener("change", renderVerification);
byId("verification-run-button").addEventListener("click", runVerification);
byId("smtp-verification-confirm").addEventListener("change", renderVerification);
byId("smtp-verification-run-button").addEventListener("click", runSMTPVerification);
byId("cache-verification-run-button").addEventListener("click", handleCacheVerificationAction);
byId("preview-user-id").addEventListener("input", renderOperations);
byId("preview-confirm").addEventListener("change", renderOperations);
byId("preview-run-button").addEventListener("click", startPreviewOperation);
byId("preview-cancel-button").addEventListener("click", cancelPreviewOperation);
byId("test-send-user-id").addEventListener("input", renderOperations);
byId("test-send-confirm").addEventListener("change", renderOperations);
byId("test-send-run-button").addEventListener("click", startTestSendOperation);
byId("manual-send-mode").addEventListener("change", () => {
  byId("manual-send-confirm").checked = false;
  renderOperations();
});
byId("manual-send-user-id").addEventListener("input", renderOperations);
byId("manual-send-confirm").addEventListener("change", renderOperations);
byId("manual-send-run-button").addEventListener("click", startManualSendOperation);
byId("schedule-confirm").addEventListener("change", renderSchedule);
byId("schedule-confirm-cancel").addEventListener("click", cancelScheduleConfirmation);
byId("schedule-confirm-run").addEventListener("click", startScheduleOperation);
document.querySelectorAll("[data-schedule-action]").forEach((button) => button.addEventListener("click", () => chooseScheduleAction(button.dataset.scheduleAction)));
byId("startup-manager").addEventListener("change", startupSettingsChanged);
byId("startup-dashboard").addEventListener("change", startupSettingsChanged);
byId("tailscale-enabled").addEventListener("change", updateTailscaleAccess);
byId("tailscale-password-setup-button").addEventListener("click", openAccessSettings);
byId("tailscale-refresh-button").addEventListener("click", refreshTailscaleAccess);
byId("tailscale-copy-button").addEventListener("click", copyTailscaleURL);
byId("tailscale-copy-authorization").addEventListener("click", copyTailscaleAuthorizationCommand);
byId("funnel-settings-link").addEventListener("click", openTailscaleSettings);
byId("tailscale-status-button").addEventListener("click", openTailscaleSettings);
byId("update-check-button").addEventListener("click", checkForUpdates);
byId("update-install-confirm").addEventListener("change", renderUpdates);
byId("update-install-button").addEventListener("click", installUpdate);
byId("update-copy-command").addEventListener("click", copyUpdateCommand);
byId("logout-button").addEventListener("click", logout);
byId("refresh-button").addEventListener("click", refreshApplicationStatus);
byId("access-status-button").addEventListener("click", openAccessSettings);
byId("update-status-button").addEventListener("click", openUpdateSettings);
document.querySelectorAll("[data-view]").forEach((button) => button.addEventListener("click", () => selectView(button.dataset.view)));
document.querySelectorAll("[data-open-view]").forEach((button) => button.addEventListener("click", () => selectView(button.dataset.openView)));
window.addEventListener("popstate", applyLocationRoute);
window.addEventListener("hashchange", applyLocationRoute);
initialize().catch((error) => setAuthMessage(`Manager initialization failed: ${error.message}`));
