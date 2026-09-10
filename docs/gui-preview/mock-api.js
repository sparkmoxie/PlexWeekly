"use strict";

(() => {
  const now = () => new Date().toISOString();
  const DEMO_VERSION = "0.26.2";
  const PREVIOUS_VERSION = "0.26.1";
  const PROFILES = {
    windows: { runtimeMode: "windows", runtimeProfile: "native-windows", packageKind: "windows-installer", label: "Windows" },
    nas: { runtimeMode: "nas", runtimeProfile: "server", packageKind: "container-compose", label: "NAS / Docker" },
    mac: { runtimeMode: "mac", runtimeProfile: "desktop", packageKind: "container-desktop", label: "macOS Docker" },
    linux: { runtimeMode: "linux", runtimeProfile: "native-linux", packageKind: "linux-native", label: "Native Linux" },
    freebsd: { runtimeMode: "nas", runtimeProfile: "server", packageKind: "freebsd-podman", label: "FreeBSD / Podman" },
  };
  let profileName = "windows";
  const profile = () => PROFILES[profileName];
  const serviceProfile = () => profileName !== "windows";
  const revision = "demo-revision-2026";
  const BACKUP_LIMIT = 10;
  const OPERATION_HISTORY_LIMIT = 20;
  const DIAGNOSTIC_LIMIT = 20;
  const TITLE_GIF_IDS = new Set(["none", "celebrate", "construction", "rocket", "tickets", "warning", "alert"]);
  const retainNewest = (items, maximum) => items.slice(0, maximum);
  let backupSequence = 20;
  let diagnosticSequence = 30;
  let backupList = retainNewest(Array.from({ length: 12 }, (_, index) => ({
    id: `demo-backup-${12 - index}`,
    createdAtUtc: new Date(Date.now() - index * 86400000).toISOString(),
    sizeBytes: 4812 + index * 37,
    revision: `demo-backup-revision-${12 - index}`,
  })), BACKUP_LIMIT);
  const previewDefinitions = [
    ["demo-index", "preview-all-00-INDEX", 42800],
    ["demo-welcome", "preview-all-01-manual-welcome", 96400],
    ["demo-new", "preview-all-02-new-user-no-history", 112600],
    ["demo-history", "preview-all-03-new-user-with-history", 148900],
    ["demo-normal", "preview-all-04-normal-newsletter", 186200],
    ["demo-quiet", "preview-all-05-established-quiet", 108400],
    ["demo-warnings", "preview-all-06-established-warmup", 126700],
  ];
  const previewLabels = [
    "Index",
    "Manual Welcome",
    "New User - No History",
    "New User - With History",
    "Normal Newsletter",
    "Established Quiet",
    "Established Warnings",
  ];
  const userNames = [
    "Morgan Vale", "Avery Stone", "Casey Rowan", "Drew Harbor", "Emery Quinn", "Finley Park",
    "Harper Lane", "Indigo Reed", "Jordan Frost", "Kai Meadow", "Logan Wren", "Marlow Sage",
    "Nova Brooks", "Oakley Rivers", "Parker Bloom", "Quinn Lake", "Remy North", "Sasha Cove",
  ];
  const users = userNames.map((name, index) => ({
    id: String(41001 + index),
    name,
    eligibility: index === 2 ? "address-needed" : "eligible",
    ...(index === 2 ? { needsDeliveryAddress: true } : {}),
    ...(index === 0 ? { role: "administrator" } : {}),
  }));
  const libraries = [
    { id: "11", name: "Cinema", mediaType: "movie", itemCount: "642" },
    { id: "12", name: "Series", mediaType: "show", itemCount: "118" },
    { id: "13", name: "Family Matinee", mediaType: "movie", itemCount: "204" },
  ];
  const field = (name, label, group, type, value, extras = {}) => ({ name, label, group, type, value, required: false, ...extras });
  const editorFields = [
    field("TautulliUrl", "Tautulli URL", "Connections", "url", "http://tautulli.demo.invalid:8181", { required: true, help: "Fictional demonstration endpoint. No request leaves this page." }),
    field("ApiKey", "Tautulli API key", "Connections", "secret", undefined, { required: true, secret: { configured: true }, help: "A synthetic write-only value is represented here." }),
    field("PlexServerUrl", "Direct Plex server URL", "Connections", "url", "http://plex.demo.invalid:32400", { help: "Fictional demonstration endpoint." }),
    field("PlexToken", "Plex token", "Connections", "secret", undefined, { secret: { configured: true }, help: "A synthetic write-only value is represented here." }),
    field("PlexWebUrl", "Open Plex button URL", "Identity", "url", "https://plex-web.demo.invalid/", { required: true, help: "Fictional demonstration link. It is never opened by this preview." }),
    field("ServerLabel", "Header label", "Identity", "text", "STARLIGHT CINEMA", { required: true }),
    field("FooterServerName", "Server display name", "Identity", "text", "Starlight Cinema", { required: true }),
    field("FromName", "From display name", "Email", "text", "Starlight Weekly", { required: true }),
    field("FromEmail", "From email", "Email", "email", "newsletter@example.com", { required: true }),
    field("ReplyToEmail", "Reply-to email", "Email", "email", "hello@example.com"),
    field("TestEmail", "Test recipient", "Email", "email", "operator@example.com", { required: true }),
    field("SmtpHost", "SMTP host", "SMTP", "text", "smtp.starlight.invalid", { required: true }),
    field("SmtpPort", "SMTP port", "SMTP", "integer", 587, { required: true, min: 1, max: 65535 }),
    field("SmtpEnableSsl", "Use TLS / STARTTLS", "SMTP", "boolean", true),
    field("SmtpUseAuthentication", "Use SMTP authentication", "SMTP", "boolean", true),
    field("SmtpUsername", "SMTP username", "SMTP", "text", "newsletter@example.com"),
    field("SmtpPassword", "SMTP password", "SMTP", "secret", undefined, { secret: { configured: true }, help: "A synthetic write-only value is represented here." }),
    field("SmtpAuthenticationMethod", "Authentication method", "SMTP", "select", "Auto", { required: true, options: ["Auto"] }),
    field("SmtpTimeoutSeconds", "SMTP timeout (seconds)", "SMTP", "integer", 30, { required: true, min: 1, max: 300 }),
    field("ScheduleDay", "Weekly send day", "Schedule", "select", "Friday", { required: true, options: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"] }),
    field("ScheduleTime", "Weekly local send time", "Schedule", "time", "09:30", { required: true }),
    field("ScheduledTaskName", "Scheduler task name", "Schedule", "text", "TautWeekly for Plex Newsletter", { required: true }),
    field("DaysBack", "Newsletter history days", "Newsletter", "integer", 7, { required: true, min: 1, max: 3650 }),
    field("RecentAccessDays", "Recent-access days", "Newsletter", "integer", 7, { required: true, min: 1, max: 3650 }),
    field("WatchedPercent", "Watched threshold (%)", "Newsletter", "integer", 85, { required: true, min: 1, max: 100 }),
    field("MaxMovies", "Maximum movies", "Newsletter", "integer", 8, { required: true, min: 0, max: 100 }),
    field("MaxTv", "Maximum TV entries", "Newsletter", "integer", 8, { required: true, min: 0, max: 100 }),
    field("DeletedItemCacheEnabled", "Enable deleted-item cache", "Cache", "boolean", true),
    field("DeletedItemCacheRetentionDays", "Cache retention days", "Cache", "integer", 365, { required: true, min: 1, max: 3650 }),
    field("DeletedItemCacheMaxItems", "Maximum cached items", "Cache", "integer", 1000, { required: true, min: 1, max: 10000 }),
    field("DeletedItemCacheMaxBytesMB", "Maximum cache size (MB)", "Cache", "integer", 256, { required: true, min: 16, max: 2048 }),
    field("CustomTextCardEnabled", "Enable custom text card", "Custom text card", "boolean", true, { help: "When enabled, the synthetic card appears before the newsletter release-count and date block in every state." }),
    field("CustomTextCardBorderColor", "Border color", "Custom text card", "color", "#72aef7", { help: "Choose the card accent color. Border opacity controls whether it is visible." }),
    field("CustomTextCardBorderOpacity", "Border opacity", "Custom text card", "range", 34, { min: 0, max: 100, help: "Set to 0% for no border." }),
    field("CustomTextCardTitle", "Optional title", "Custom text card", "text", "CUSTOM TITLE", { max: 120, help: "Gold uppercase label using the Welcome Aboard title size." }),
    field("CustomTextCardTitleGif", "Optional title GIF", "Custom text card", "asset-id", "none", { help: "A safe local asset ID stored separately from the title text." }),
    field("CustomTextCardSubheading", "Optional subheading", "Custom text card", "text", "Custom subheading", { max: 200, help: "Large white heading using the Welcome Aboard heading size." }),
    field("CustomTextCardBody", "Card body (required when enabled)", "Custom text card", "textarea", "A synthetic announcement for local assessment.\nLine breaks remain plain text and no service is contacted.", { max: 2000, help: "Plain text only. Line breaks are preserved and HTML is always escaped." }),
    field("IncludedLibraryIds", "Included library IDs", "Advanced", "string-list", ["11", "12", "13"]),
    field("ExcludedUserIds", "Excluded user IDs", "Advanced", "string-list", ["41005", "41012"]),
    field("ExcludedEmails", "Excluded email addresses", "Advanced", "email-list", []),
    field("UserEmailOverrides", "Managed-user delivery addresses", "Advanced", "user-email-map", { "41003": "family-inbox@example.org" }, { help: "Private fallback addresses for active users whose Tautulli account has no native email." }),
  ];

  const integration = {
    mode: "synthetic-demo",
    networkBoundary: "simulated only",
    overall: "passed",
    startedAtUtc: now(),
    completedAtUtc: now(),
    configRevision: revision,
    steps: [
      { service: "tautulli", state: "passed", summary: "Synthetic Tautulli identity, library, and user checks passed." },
      { service: "plex", state: "passed", summary: "Synthetic direct Plex identity and library checks passed." },
    ],
  };
  const smtp = {
    mode: "synthetic-demo",
    overall: "passed",
    state: "passed",
    security: "STARTTLS simulated",
    completedAtUtc: now(),
    configRevision: revision,
    summary: "Synthetic SMTP greeting, EHLO, and certificate-validated STARTTLS checks passed.",
  };
  const cacheStatus = {
    schemaVersion: 1,
    enabled: true,
    state: "passed",
    summary: "Synthetic deleted-item cache has 12 restorable entries and 12 artwork files.",
    manifestState: "primary-valid",
    backupState: "valid",
    writability: "passed",
    integrityState: "verified",
    verification: "full",
    entryCount: 12,
    artworkCount: 12,
    artworkBytes: 1866240,
    missingArtworkCount: 0,
    orphanArtworkCount: 0,
    artworkSizeMismatchCount: 0,
    hashMismatchCount: 0,
    expiredEntryCount: 0,
    retentionDays: 365,
    maxItems: 1000,
    maxBytesMb: 256,
    checkedAtUtc: now(),
  };
  const setupStatus = {
    schemaVersion: 2,
    available: true,
    configRevision: revision,
    running: false,
    updatedAtUtc: now(),
    steps: {
      choices: { state: "passed", summary: "3 fictional libraries and 18 fictional users loaded in memory." },
      lan: { state: "passed", summary: "Synthetic Tautulli and direct Plex verification passed." },
      smtp: { state: "passed", summary: "Synthetic SMTP reachability and STARTTLS validation passed." },
      previews: { state: "passed", summary: "Six production-faithful newsletter states are available for review." },
      cache: { state: "passed", summary: cacheStatus.summary, updatedAtUtc: cacheStatus.checkedAtUtc },
    },
    lastVerification: integration,
    lastSmtpCheck: smtp,
    cache: cacheStatus,
  };
  const discovery = {
    mode: "synthetic-demo",
    networkBoundary: "no network",
    completedAtUtc: now(),
    configRevision: revision,
    libraries,
    users,
    suggestedPreviewUserId: "41001",
  };
  const previews = previewDefinitions.map(([id, name, sizeBytes]) => ({ id, name, sizeBytes, modifiedUtc: now() }));
  const completedPreview = {
    schemaVersion: 1,
    id: "demo-operation-initial",
    type: "preview-all",
    trigger: "gui-preview",
    packageVersion: "GUI Preview",
    state: "succeeded",
    outcome: "succeeded",
    startedAtUtc: new Date(Date.now() - 9000).toISOString(),
    finishedAtUtc: now(),
    durationMs: 9000,
    generatedPreviewIds: previews.map((item) => item.id),
    cancellable: false,
  };
  const archivedOperations = Array.from({ length: 22 }, (_, index) => {
    const type = ["send-all", "preview-all", "send-test-all", "send-welcome"][index % 4];
    const started = Date.now() - (index + 1) * 3600000;
    return {
      schemaVersion: 1,
      id: `demo-operation-archive-${22 - index}`,
      type,
      trigger: "gui-preview",
      packageVersion: "GUI Preview",
      state: "succeeded",
      outcome: "succeeded",
      startedAtUtc: new Date(started).toISOString(),
      finishedAtUtc: new Date(started + 1200).toISOString(),
      durationMs: 1200,
      generatedPreviewIds: type === "preview-all" ? previews.map((item) => item.id) : [],
      smtpAcceptedCount: type === "send-all" ? 14 : type === "send-test-all" ? 6 : type === "send-welcome" ? 1 : 0,
      skippedCount: type === "send-all" ? 2 : 0,
      failedCount: 0,
      cancellable: false,
    };
  });
  const diagnosticExamples = [
    ["configuration", "passed", "config-saved", "Synthetic configuration validation completed."],
    ["tautulli-discovery", "passed", "discovery-completed", "Fictional library and user choices were loaded in memory."],
    ["lan-verification", "passed", "verification-passed", "Synthetic Tautulli and Plex connection checks passed."],
    ["smtp-preflight", "passed", "smtp-passed", "Synthetic SMTP connectivity and STARTTLS validation passed."],
  ];
  let diagnosticEvents = retainNewest(Array.from({ length: 22 }, (_, index) => {
    const [area, outcome, code, summary] = diagnosticExamples[index % diagnosticExamples.length];
    return {
      schemaVersion: 1,
      id: `demo-diagnostic-${22 - index}`,
      recordedAtUtc: new Date(Date.now() - index * 1800000).toISOString(),
      area,
      outcome,
      code,
      summary,
    };
  }), DIAGNOSTIC_LIMIT);
  const model = {
    startup: { supported: true, state: "disabled", startManager: false, openDashboard: false },
    tailscale: { supported: true, installed: true, enabled: false, active: false,
      state: "manager-password-required", provider: "tailscale", networkKind: "public-funnel",
      management: "integrated", passwordRequired: true, cleanupRequired: false, url: "" },
    schedule: { installed: true, enabled: true, owned: true, ownership: "verified", state: "ready" },
    operation: completedPreview,
    operationStartedMS: 0,
    history: retainNewest([completedPreview, ...archivedOperations], OPERATION_HISTORY_LIMIT),
    scheduleOperation: null,
    scheduleStartedMS: 0,
    lockEnabled: false,
    updateStartedMS: 0,
    update: {
      schemaVersion: 3,
      observedAtUtc: now(),
      state: "unknown",
      managerVersion: DEMO_VERSION,
      applicationVersion: DEMO_VERSION,
      packageVersion: DEMO_VERSION,
      runtimeProfile: "native-windows",
      packageKind: "windows-installer",
      packageLabel: "Synthetic supported package",
      hostAdapterState: "not-applicable",
      updateChannel: "stable",
      latestStableVersion: "",
      updateAvailable: false,
      installSupported: false,
      installState: "idle",
      checkInProgress: false,
      backgroundCheckRecommended: true,
      lastSuccessfulCheckUtc: "",
      releaseNotesUrl: "",
      guidance: {
        owner: "TautWeekly verified updater (simulated)",
        summary: "Production can start an install only through an existing fixed, checksum- and manifest-verified updater. This preview only demonstrates that capability boundary.",
        steps: ["Review the fictional stable release notes.", "Confirm the simulated install action.", "Observe that no host process or file is changed."],
        docsUrl: "../",
      },
    },
  };

  function access() {
    const required = serviceProfile() || model.lockEnabled;
    return { mode: required ? "optional-lock" : "trusted-local", authenticationRequired: required,
      passwordConfigured: required, passwordLockEnabled: required, pairingRequired: false,
      runtimeRequired: serviceProfile(), canDisable: !serviceProfile() && model.lockEnabled };
  }

  window.TautWeeklyDemoControls = Object.freeze({
    version: DEMO_VERSION,
    setProfile(name) {
      if (!Object.hasOwn(PROFILES, name)) throw new Error("Unknown fictional package profile.");
      profileName = name;
      model.lockEnabled = serviceProfile();
      model.startup.supported = !serviceProfile();
      const authorizationCommand = name === "linux" || name === "freebsd"
        ? "sudo tautweekly remote-access-authorize"
        : name === "windows" ? "" : "./tautweekly.sh remote-access-login";
      Object.assign(model.tailscale, { supported: true, installed: true, enabled: false, active: false,
        state: name === "windows" ? "manager-password-required" : "authorization-required", url: "",
        provider: "tailscale", networkKind: "public-funnel",
        passwordRequired: name === "windows", cleanupRequired: false,
        management: "integrated",
        hostAuthorizationRequired: name !== "windows", hostAuthorizationCommand: authorizationCommand });
      Object.assign(model.update, { managerVersion: DEMO_VERSION, applicationVersion: DEMO_VERSION,
        packageVersion: DEMO_VERSION, runtimeProfile: profile().runtimeProfile, packageKind: profile().packageKind, packageLabel: profile().label + " (fictional)",
        imageVersion: ["nas", "mac", "freebsd"].includes(name) ? DEMO_VERSION : "",
        imageRepository: ["nas", "mac", "freebsd"].includes(name) ? "ghcr.io/sparkmoxie/tautweekly" : "",
        recommendedImageReference: ["nas", "mac", "freebsd"].includes(name) ? "ghcr.io/sparkmoxie/tautweekly:" + DEMO_VERSION : "",
        imagePinningPolicy: ["nas", "mac", "freebsd"].includes(name) ? "Use full semver or append the manifest digest; mutable minor, latest, and edge tags are not automation pins." : "",
        migrationState: name === "mac" ? "unified-image" : (["nas", "freebsd"].includes(name) ? "unified-image" : ""),
        state: "current", latestStableVersion: DEMO_VERSION, updateAvailable: false, installSupported: false,
        installState: "idle", nextCheckAllowedAtUtc: "", lastSuccessfulCheckUtc: now(), backgroundCheckRecommended: false });
      model.update.guidance.owner = serviceProfile() ? "Package host (simulated)" : "Verified Windows updater (simulated)";
      model.update.guidance.summary = serviceProfile()
        ? "This example keeps installation with the package host. No browser action changes a host, service, or container."
        : "The Windows example simulates the verified updater; it never launches a process or changes a file.";
    },
    setFunnelScenario(name) {
      const scenarios = {
        off: { supported: true, installed: true, enabled: false, active: false, state: "inactive", passwordRequired: false, cleanupRequired: false, url: "" },
        active: { supported: true, installed: true, enabled: true, active: true, state: "active", passwordRequired: false, cleanupRequired: true, url: "https://manager.demo.invalid" },
        pending: { supported: true, installed: true, enabled: true, active: false, state: "starting", passwordRequired: false, cleanupRequired: true, url: "https://manager.demo.invalid" },
        blocked: { supported: true, installed: true, enabled: true, active: false, state: "needs-attention", passwordRequired: false, cleanupRequired: true, url: "" },
        "not-configured": { supported: true, installed: false, enabled: false, active: false, state: "tailscale-required", passwordRequired: false, cleanupRequired: false, url: "" },
        unsupported: { supported: false, installed: false, enabled: false, active: false, state: "unsupported", passwordRequired: false, cleanupRequired: false, url: "" },
      };
      if (!Object.hasOwn(scenarios, name)) throw new Error("Unknown fictional Funnel status.");
      model.lockEnabled = serviceProfile() || ["active", "pending", "blocked"].includes(name);
      Object.assign(model.tailscale, scenarios[name], {
        provider: "tailscale", networkKind: "public-funnel", management: "integrated",
        hostAuthorizationRequired: false, hostAuthorizationCommand: "",
      });
    },
    offerUpdate() {
      Object.assign(model.update, { managerVersion: PREVIOUS_VERSION, applicationVersion: PREVIOUS_VERSION,
        packageVersion: PREVIOUS_VERSION, imageVersion: model.update.imageVersion ? PREVIOUS_VERSION : "",
        latestStableVersion: DEMO_VERSION, state: "update-available", updateAvailable: true,
        installSupported: !serviceProfile(), installState: "idle", lastSuccessfulCheckUtc: now(),
        nextCheckAllowedAtUtc: "", backgroundCheckRecommended: false });
    },
  });

  function editor() {
    return {
      schemaVersion: 1,
      exists: true,
      valid: true,
      state: "ready",
      revision,
      groups: ["Connections", "Identity", "Email", "SMTP", "Schedule", "Newsletter", "Cache", "Custom text card", "Advanced"],
      fields: editorFields,
      issues: {},
      directPlex: { legacyFieldsMissing: false, urlConfigured: true, tokenConfigured: true, runtimeTokenAvailable: false },
    };
  }

  function status() {
    const observedAtUtc = now();
    const next = new Date(Date.now() + 1000 * 60 * 60 * 38);
    return {
      schemaVersion: 1,
      observedAtUtc,
      overall: "healthy",
      platform: profile().label + " (fictional)",
      version: DEMO_VERSION,
      runtime: { manager: "healthy", preview: "ready", scheduler: model.schedule.installed ? "ready" : "not-installed" },
      readiness: { configuration: "ready", privateData: "ready" },
      schedule: {
        supported: true,
        ...model.schedule,
        nextRunUtc: model.schedule.installed ? next.toISOString() : "",
        nextRunLocal: model.schedule.installed ? next.toISOString() : "",
      },
      delivery: {
        lastAttemptUtc: new Date(Date.now() - 1000 * 60 * 60 * 18).toISOString(),
        lastSuccessUtc: new Date(Date.now() - 1000 * 60 * 60 * 18).toISOString(),
        result: "simulated-accepted",
        evidence: "renderer-result",
        smtpAcceptedCount: 14,
        skippedCount: 2,
        failedCount: 0,
      },
      integrations: { tautulli: "passed", plex: "passed", smtp: "passed" },
      previewCount: previews.length,
      previewSummary: "6 rich local states + index",
    };
  }

  function configView() {
    return {
      exists: true,
      valid: true,
      state: "ready",
      fields: editorFields.map((item) => ["secret", "user-email-map"].includes(item.type)
        ? { name: item.name, type: "secret", secret: { configured: true } }
        : { name: item.name, type: item.type, value: item.value }),
    };
  }

  function recordBackup(sourceRevision = revision) {
    backupSequence += 1;
    const backup = {
      id: `demo-backup-${backupSequence}`,
      createdAtUtc: now(),
      sizeBytes: 5000 + backupSequence * 11,
      revision: `${sourceRevision}-snapshot-${backupSequence}`,
    };
    backupList = retainNewest([backup, ...backupList.filter((item) => item.id !== backup.id)], BACKUP_LIMIT);
    return backup;
  }

  function recordDiagnostic(area, outcome, code, summary) {
    diagnosticSequence += 1;
    const event = { schemaVersion: 1, id: `demo-diagnostic-${diagnosticSequence}`, recordedAtUtc: now(), area, outcome, code, summary };
    diagnosticEvents = retainNewest([event, ...diagnosticEvents], DIAGNOSTIC_LIMIT);
    return event;
  }

  function setCacheEnabled(enabled) {
    Object.assign(cacheStatus, enabled ? {
      enabled: true, state: "passed", summary: "Synthetic full deleted-item cache verification passed.",
      manifestState: "primary-valid", backupState: "valid", writability: "passed", integrityState: "verified",
      verification: "full", checkedAtUtc: now(),
    } : {
      enabled: false, state: "skipped", summary: "Deleted-item cache is disabled in the fictional saved configuration.",
      manifestState: "disabled", backupState: "not-applicable", writability: "not-applicable", integrityState: "skipped",
      verification: "full", entryCount: 0, artworkCount: 0, artworkBytes: 0, checkedAtUtc: now(),
    });
    setupStatus.cache = cacheStatus;
    setupStatus.steps.cache = { state: cacheStatus.state, summary: cacheStatus.summary, updatedAtUtc: cacheStatus.checkedAtUtc };
    setupStatus.updatedAtUtc = now();
  }

  function completeCacheVerification() {
    if (!cacheStatus.enabled) return;
    Object.assign(cacheStatus, {
      state: "passed", summary: "Synthetic full deleted-item cache verification passed.",
      manifestState: "primary-valid", backupState: "valid", writability: "passed", integrityState: "verified",
      verification: "full", checkedAtUtc: now(),
    });
    setupStatus.cache = cacheStatus;
    setupStatus.steps.cache = { state: "passed", summary: cacheStatus.summary, updatedAtUtc: cacheStatus.checkedAtUtc };
    setupStatus.updatedAtUtc = now();
  }

  function finishOperationIfReady() {
    if (!model.operation || !["queued", "running", "cancelling"].includes(model.operation.state)) return;
    if (Date.now() - model.operationStartedMS < 900) return;
    const operation = model.operation;
    operation.state = operation.state === "cancelling" ? "cancelled" : "succeeded";
    operation.outcome = operation.state === "cancelled" ? "cancelled" : "succeeded";
    operation.finishedAtUtc = now();
    operation.durationMs = Date.now() - model.operationStartedMS;
    operation.cancellable = false;
    if (operation.type === "preview-all") {
      operation.generatedPreviewIds = operation.state === "succeeded" ? previews.map((item) => item.id) : [];
      setupStatus.steps.previews = operation.state === "succeeded"
        ? { state: "passed", summary: "Six production-faithful newsletter states are available for review.", updatedAtUtc: now() }
        : { state: "skipped", summary: "The fictional local preview operation was cancelled.", updatedAtUtc: now() };
      setupStatus.running = false;
      setupStatus.updatedAtUtc = now();
    }
    if (operation.type === "cache-warm") {
      if (operation.state === "succeeded") completeCacheVerification();
      else {
        Object.assign(cacheStatus, { state: "failed", verification: "full", summary: "Synthetic cache refresh stopped before complete coverage was verified.", checkedAtUtc: now() });
        setupStatus.steps.cache = { state: "failed", summary: cacheStatus.summary, updatedAtUtc: cacheStatus.checkedAtUtc };
      }
      setupStatus.running = false;
      setupStatus.updatedAtUtc = now();
    }
    if (operation.type === "send-test-all") operation.smtpAcceptedCount = 6;
    if (operation.type === "send-welcome") operation.smtpAcceptedCount = 1;
    if (operation.type === "send-all") operation.smtpAcceptedCount = 14;
    model.history = retainNewest([operation, ...model.history.filter((item) => item.id !== operation.id)], OPERATION_HISTORY_LIMIT);
    recordDiagnostic("manager-operation", operation.outcome, "operation-completed", "A fictional Manager operation completed in memory.");
  }

  function startOperation(body) {
    const id = `demo-operation-${Date.now()}`;
    model.operationStartedMS = Date.now();
    model.operation = {
      schemaVersion: 1,
      id,
      type: body.type,
      trigger: "gui-preview",
      packageVersion: "GUI Preview",
      state: "running",
      startedAtUtc: now(),
      deliveryScope: body.type === "send-test-all" ? "test-email" : body.type === "send-all" ? "all-eligible" : body.type === "send-welcome" ? "selected-user" : "none",
      generatedPreviewIds: [],
      cancellable: ["preview-all", "cache-warm"].includes(body.type),
    };
    if (body.type === "preview-all") {
      setupStatus.running = true;
      setupStatus.steps.previews = { state: "running", summary: "Generating six fictional local preview states without sending.", updatedAtUtc: now() };
      setupStatus.updatedAtUtc = now();
    }
    if (body.type === "cache-warm") {
      setupStatus.running = true;
      setupStatus.steps.cache = { state: "running", summary: "Refreshing fictional all-included-user cache coverage locally.", updatedAtUtc: now() };
      setupStatus.updatedAtUtc = now();
    }
    return model.operation;
  }

  function finishScheduleIfReady() {
    if (!model.scheduleOperation || !["queued", "running"].includes(model.scheduleOperation.state)) return;
    if (Date.now() - model.scheduleStartedMS < 800) return;
    const action = model.scheduleOperation.action;
    if (action === "install") Object.assign(model.schedule, { installed: true, enabled: true, owned: true, ownership: "verified", state: "ready" });
    if (action === "enable") Object.assign(model.schedule, { installed: true, enabled: true, state: "ready" });
    if (action === "disable") Object.assign(model.schedule, { enabled: false, state: "disabled" });
    if (action === "remove") Object.assign(model.schedule, { installed: false, enabled: false, owned: false, ownership: "not-installed", state: "not-installed" });
    model.scheduleOperation.state = "succeeded";
    model.scheduleOperation.finishedAtUtc = now();
  }

  function startSchedule(action) {
    model.scheduleStartedMS = Date.now();
    model.scheduleOperation = { schemaVersion: 1, id: `demo-schedule-${Date.now()}`, action, state: "running", startedAtUtc: now() };
    return model.scheduleOperation;
  }

  function finishUpdateIfReady() {
    if (!model.updateStartedMS || model.update.installState !== "running") return;
    if (Date.now() - model.updateStartedMS < 900) return;
    const version = model.update.latestStableVersion;
    Object.assign(model.update, {
      observedAtUtc: now(),
      state: "current",
      managerVersion: version,
      applicationVersion: version,
      packageVersion: version,
      imageVersion: model.update.imageVersion ? version : "",
      updateAvailable: false,
      installSupported: false,
      installState: "completed",
      backgroundCheckRecommended: false,
    });
  }

  function json(payload, statusCode = 200) {
    return Promise.resolve(new Response(JSON.stringify(payload), { status: statusCode, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } }));
  }

  function bodyOf(init) {
    if (!init?.body) return {};
    try { return JSON.parse(init.body); } catch (_) { return {}; }
  }

  function postSavePlan(changed, values) {
    const cacheEnabled = "DeletedItemCacheEnabled" in values
      ? Boolean(values.DeletedItemCacheEnabled)
      : Boolean(editorFields.find((item) => item.name === "DeletedItemCacheEnabled")?.value);
    const plan = { materialChange: changed.length > 0, changedCategories: [], runDiscovery: false, runIntegration: false, runSmtp: false, generatePreviews: false, warmCache: false,
      verifyCache: cacheEnabled, cacheEnabled, retainedDiscovery: true, retainedIntegration: true, retainedSmtp: true, retainedPreviews: true };
    const categories = new Set();
    for (const name of changed) {
      if (["TautulliUrl", "ApiKey"].includes(name)) { categories.add("tautulli"); plan.runDiscovery = true; plan.runIntegration = true; plan.generatePreviews = true; plan.warmCache = plan.cacheEnabled; }
      else if (["PlexServerUrl", "PlexToken"].includes(name)) { categories.add("plex"); plan.runIntegration = true; plan.generatePreviews = true; plan.warmCache = plan.cacheEnabled; }
      else if (name.startsWith("Smtp")) { categories.add("smtp"); plan.runSmtp = true; }
      else if (["PlexWebUrl", "PlexButtonLabel", "ServerLabel", "FooterServerName"].includes(name)) { categories.add("identity"); plan.generatePreviews = true; }
      else if (["FromName", "FromEmail", "ReplyToEmail", "TestEmail"].includes(name)) categories.add("email");
      else if (name.startsWith("Schedule") || name === "ScheduledTaskName") categories.add("schedule");
      else if (name.startsWith("DeletedItemCache")) {
        categories.add("cache");
        plan.warmCache = plan.cacheEnabled;
      }
      else if (name.startsWith("CustomTextCard")) { categories.add("custom-text-card"); plan.generatePreviews = true; }
      else if (name === "IncludedLibraryIds") { categories.add("libraries"); plan.generatePreviews = true; plan.warmCache = plan.cacheEnabled; }
      else if (["ExcludedUserIds", "ExcludedEmails", "UserEmailOverrides"].includes(name)) { categories.add("recipients"); plan.generatePreviews = true; plan.warmCache = plan.cacheEnabled; }
      else if (["DaysBack", "RecentAccessDays", "WatchedPercent", "MaxMovies", "MaxTv"].includes(name)) { categories.add("newsletter"); plan.generatePreviews = true; plan.warmCache = plan.cacheEnabled; }
      else categories.add("newsletter");
    }
    plan.changedCategories = ["tautulli", "plex", "smtp", "identity", "email", "schedule", "newsletter", "cache", "custom-text-card", "libraries", "recipients"].filter((name) => categories.has(name));
    plan.retainedDiscovery = !plan.runDiscovery;
    plan.retainedIntegration = !plan.runIntegration;
    plan.retainedSmtp = !plan.runSmtp;
    plan.retainedPreviews = !plan.generatePreviews;
    if (categories.size === 1 && categories.has("cache")) {
      plan.confirmationCode = changed.includes("DeletedItemCacheEnabled") ? (values.DeletedItemCacheEnabled ? "cache-enabled" : "cache-disabled") : "cache-updated";
    }
    return plan;
  }

  window.fetch = (input, init = {}) => {
    const raw = typeof input === "string" ? input : input.url;
    const url = new URL(raw, window.location.href);
    const path = url.pathname.replace(/^\/TautWeekly/, "");
    const method = String(init.method || (typeof input !== "string" && input.method) || "GET").toUpperCase();
    const body = bodyOf(init);
    finishOperationIfReady();
    finishScheduleIfReady();
    finishUpdateIfReady();

    if (path === "/api/v1/setup") return json({ paired: true, authenticationRequired: serviceProfile(), pairingRequired: false, runtimeMode: profile().runtimeMode });
    if (path === "/api/v1/auth/session" || path === "/api/v1/auth/login" || path === "/api/v1/auth/pair") return json({ authenticated: true, csrfToken: "synthetic-demo-token", expiresAtUtc: new Date(Date.now() + 86400000).toISOString() });
    if (path === "/api/v1/auth/logout") return json({ signedOut: true });
    if (path === "/api/v1/auth/access" && method === "GET") return json(access());
    if (path === "/api/v1/auth/access/password") {
      model.lockEnabled = true;
      if (profileName === "windows" && !model.tailscale.enabled)
        Object.assign(model.tailscale, { state: "inactive", passwordRequired: false });
      return json(access());
    }
    if (path === "/api/v1/auth/access/disable") {
      if (serviceProfile()) return json({ error: { code: "authentication-required", message: "This package example requires login." } }, 409);
      if (model.tailscale.enabled || model.tailscale.cleanupRequired)
        return json({ error: { code: "funnel-shutdown-required", message: "The synthetic password lock stayed enabled until Funnel shutdown is verified." } }, 409);
      model.lockEnabled = false;
      Object.assign(model.tailscale, { state: "manager-password-required", passwordRequired: true });
      return json(access());
    }
    if (path === "/api/v1/capabilities") return json({ ...profile(), supportsStartup: !serviceProfile(),
      accessLabel: serviceProfile() ? "Required login (fictional)" : "Optional lock (fictional)",
      scheduleActions: serviceProfile() ? ["enable", "disable"] : ["install", "enable", "disable", "remove"] });
    if (path === "/api/v1/startup") {
      if (method === "PUT" && !serviceProfile()) Object.assign(model.startup, {
        startManager: Boolean(body.startManager), openDashboard: Boolean(body.startManager && body.openDashboard),
        state: body.startManager ? "enabled" : "disabled" });
      return json(model.startup);
    }
    if (path === "/api/v1/remote-access/tailscale" || path === "/api/v1/remote-access/tailscale/verify") {
      if (method === "PUT") {
        if (!['enable', 'disable'].includes(body.operation) || Object.keys(body).some((key) => key !== 'operation'))
          return json({ error: { code: "invalid-operation", message: "Only the synthetic typed Funnel operation is accepted." } }, 400);
        if (body.operation === "enable" && !model.lockEnabled)
          return json({ error: { code: "manager-password-required", message: "Set the synthetic Manager password first." } }, 409);
        const enabled = body.operation === "enable";
        Object.assign(model.tailscale, { enabled, active: false, cleanupRequired: enabled,
          passwordRequired: !model.lockEnabled, state: enabled ? "starting" : "inactive",
          url: enabled ? "https://manager.demo.invalid" : "" });
      } else if (path === "/api/v1/remote-access/tailscale/verify" && method === "POST" && model.tailscale.enabled) {
        Object.assign(model.tailscale, { active: true, state: "active" });
      }
      return json(model.tailscale);
    }
    if (/^\/api\/v1\/config\/secrets\/[^/]+\/reveal$/.test(path) && method === "POST")
      return json({ value: "synthetic-not-a-credential" });
    if (path === "/api/v1/status") return json(status());
    if (path === "/api/v1/config") {
      if (method === "PUT") {
        const values = body.values || {};
        const currentValue = (name) => values[name] ?? editorFields.find((item) => item.name === name)?.value;
        const fields = {};
        if (currentValue("CustomTextCardEnabled") && !String(currentValue("CustomTextCardBody") || "").trim()) {
          fields.CustomTextCardBody = "Card body text is required when the custom text card is enabled.";
        }
        if (!/^#[0-9a-f]{6}$/i.test(String(currentValue("CustomTextCardBorderColor") || ""))) {
          fields.CustomTextCardBorderColor = "Choose a six-digit hexadecimal color.";
        }
        const opacity = Number(currentValue("CustomTextCardBorderOpacity"));
        if (!Number.isInteger(opacity) || opacity < 0 || opacity > 100) {
          fields.CustomTextCardBorderOpacity = "Enter a value from 0 through 100.";
        }
        if (!TITLE_GIF_IDS.has(String(currentValue("CustomTextCardTitleGif") || "none"))) {
          fields.CustomTextCardTitleGif = "Choose one of the bundled synthetic title GIFs.";
        }
        if (Object.keys(fields).length) {
          return json({ error: { code: "configuration-invalid", message: "The fictional configuration needs attention.", fields } }, 400);
        }
        const changedValues = Object.entries(values).filter(([name, value]) => {
          const target = editorFields.find((item) => item.name === name);
          return target && JSON.stringify(target.value) !== JSON.stringify(value);
        }).map(([name]) => name);
        const changedSecrets = Object.entries(body.secrets || {}).filter(([, change]) => change?.action && change.action !== "preserve").map(([name]) => name);
        const changed = [...new Set([...changedValues, ...changedSecrets])];
        const plan = postSavePlan(changed, values);
        if (plan.materialChange) {
          recordBackup(revision);
          recordDiagnostic("configuration", "passed", "config-saved", "Synthetic configuration validation completed.");
        }
        for (const [name, value] of Object.entries(body.values || {})) {
          const target = editorFields.find((item) => item.name === name);
          if (target) target.value = value;
        }
        setCacheEnabled(Boolean(editorFields.find((item) => item.name === "DeletedItemCacheEnabled")?.value));
        if (plan.warmCache) setupStatus.steps.cache = { state: "running", summary: "Preparing the independent fictional cache refresh.", updatedAtUtc: now() };
        return json({ saved: plan.materialChange, backup: plan.materialChange ? "synthetic-demo-backup" : "", editor: editor(), postSave: plan });
      }
      return json(configView());
    }
    if (path === "/api/v1/config/editor") return json(editor());
    if (path === "/api/v1/config/status" || path === "/api/v1/config/status/previews/skipped") return json(setupStatus);
    if (path === "/api/v1/config/backups") return json({ backups: retainNewest(backupList, BACKUP_LIMIT), maximumEntries: BACKUP_LIMIT, retentionPolicy: "newest-first-fifo" });
    if (/^\/api\/v1\/config\/backups\/[^/]+\/restore$/.test(path)) {
      const sourceId = decodeURIComponent(path.split("/").at(-2));
      const safetyBackup = recordBackup(revision);
      recordDiagnostic("configuration", "passed", "backup-restored", "A fictional configuration backup was restored in memory.");
      return json({ restored: true, sourceId, safetyBackup: safetyBackup.id, editor: editor() });
    }
    if (/^\/api\/v1\/config\/backups\/[^/]+$/.test(path) && method === "DELETE") {
      const id = decodeURIComponent(path.split("/").at(-1));
      backupList = backupList.filter((backup) => backup.id !== id);
      return json({ deleted: true, id });
    }
    if (/^\/api\/v1\/config\/secrets\/[^/]+\/reveal$/.test(path)) return json({ name: decodeURIComponent(path.split("/").at(-2)), value: "FICTIONAL-DEMO-VALUE" });
    if (path === "/api/v1/checks/integrations") return json(integration);
    if (path === "/api/v1/checks/smtp-network") return json(smtp);
    if (path === "/api/v1/checks/deleted-item-cache") {
      completeCacheVerification();
      setupStatus.running = false;
      return json(cacheStatus);
    }
    if (path === "/api/v1/discovery/tautulli") return json(method === "POST" ? discovery : { last: discovery });
    if (path === "/api/v1/previews") return json({ previews });
    if (path === "/api/v1/operations" && method === "POST") return json(startOperation(body), 202);
    if (path === "/api/v1/operations/current") return json({ current: model.operation });
    if (/^\/api\/v1\/operations\/[^/]+\/cancel$/.test(path)) { if (model.operation) model.operation.state = "cancelling"; return json(model.operation); }
    if (/^\/api\/v1\/operations\/[^/]+$/.test(path)) return json(model.operation);
    if (path === "/api/v1/history") return json({ operations: retainNewest(model.history, OPERATION_HISTORY_LIMIT), maximumEntries: OPERATION_HISTORY_LIMIT, retentionPolicy: "count-only-fifo" });
    if (path === "/api/v1/schedule/operation") return json({ current: model.scheduleOperation });
    if (/^\/api\/v1\/schedule\/(install|enable|disable|remove)$/.test(path) && method === "POST") return json(startSchedule(path.split("/").at(-1)), 202);
    if (path === "/api/v1/updates" && method === "GET") return json({ ...model.update, observedAtUtc: now() });
    if (path === "/api/v1/updates/check" && method === "POST") {
      const nextAllowed = model.update.nextCheckAllowedAtUtc ? new Date(model.update.nextCheckAllowedAtUtc).getTime() : 0;
      if (nextAllowed > Date.now()) return json({ error: { code: "check-backoff", message: "The synthetic result is still fresh; another check is temporarily unnecessary." } }, 429);
      model.update.checkInProgress = true;
      return new Promise((resolve) => setTimeout(() => {
        const completedAt = new Date();
        Object.assign(model.update, {
          state: model.update.applicationVersion === DEMO_VERSION ? "current" : "update-available",
          latestStableVersion: DEMO_VERSION,
          updateAvailable: model.update.applicationVersion !== DEMO_VERSION,
          installSupported: !serviceProfile() && model.update.applicationVersion !== DEMO_VERSION,
          checkInProgress: false,
          backgroundCheckRecommended: false,
          lastSuccessfulCheckUtc: completedAt.toISOString(),
          nextCheckAllowedAtUtc: new Date(completedAt.getTime() + 5 * 60 * 1000).toISOString(),
          observedAtUtc: completedAt.toISOString(),
        });
        resolve(json(model.update));
      }, 450));
    }
    if (path === "/api/v1/updates/install" && method === "POST") {
      if (serviceProfile() || !model.update.updateAvailable)
        return json({ error: { code: "install-unavailable", message: "No simulated browser-owned install is available." } }, 409);
      model.updateStartedMS = Date.now();
      model.update.installState = "running";
      model.update.observedAtUtc = now();
      return json(model.update, 202);
    }
    if (path === "/api/v1/about") return json({ version: DEMO_VERSION, packageVersion: DEMO_VERSION });
    if (path === "/api/v1/diagnostics") return json({ events: retainNewest(diagnosticEvents, DIAGNOSTIC_LIMIT), maximumEntries: DIAGNOSTIC_LIMIT, retentionPolicy: "count-only-fifo" });
    return json({ error: { code: "demo-route-unavailable", message: "This action is outside the synthetic GUI preview." } }, 404);
  };

  function newsletterFrame(title, eyebrow, accent, quiet = false) {
    return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>
      :root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#090a0a;color:#f7f4ed;font:15px/1.55 Arial,sans-serif}.mail{max-width:760px;margin:auto;padding:46px 28px 80px}.brand{color:#ffb000;font-weight:900;letter-spacing:.18em}.hero{margin:26px 0;padding:28px;border:1px solid #7a5700;border-radius:18px;background:linear-gradient(135deg,#251d09,#121313 55%)}h1{font-size:42px;line-height:1;margin:8px 0 12px}h2{font-size:26px;margin:34px 0 12px}.meta{color:#a8b1b6}.shelf{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}.poster{min-height:225px;border-radius:14px;padding:18px;display:flex;align-items:flex-end;background:linear-gradient(160deg,${accent},#181919 72%);border:1px solid #333}.poster strong{font-size:18px}.badge{display:inline-block;color:#ffb000;font-weight:800;text-transform:uppercase;letter-spacing:.12em}.quiet{padding:36px;text-align:center;border:1px solid #333;border-radius:18px;background:#131414}@media(max-width:620px){.mail{padding:28px 16px}.shelf{grid-template-columns:1fr 1fr}h1{font-size:34px}}
    </style></head><body><main class="mail"><div class="brand">STARLIGHT CINEMA</div><section class="hero"><span class="badge">${eyebrow}</span><h1>${title}</h1><p class="meta">A fictional TautWeekly email state for GUI demonstration only.</p></section>${quiet ? `<div class="quiet"><div style="font-size:42px">🍿</div><h2>A quiet week can still feel polished.</h2><p>No qualifying new releases were found in this synthetic state.</p></div>` : `<h2>Fresh this week</h2><div class="shelf"><div class="poster"><strong>Orbit House</strong></div><div class="poster" style="background:linear-gradient(160deg,#48336d,#181919 72%)"><strong>Neon Harbor</strong></div><div class="poster" style="background:linear-gradient(160deg,#194e4a,#181919 72%)"><strong>Paper Moons</strong></div></div>`}<p class="meta" style="margin-top:38px">All names, titles, counts, and events on this page are fictional.</p></main></body></html>`;
  }

  window.TautWeeklyPreviewDemo = {
    html(id) {
      if (id === "demo-index") {
        const links = previewDefinitions.slice(1).map(([, name], index) => `<article><div><strong>${previewLabels[index + 1]}</strong><small>Synthetic newsletter scenario</small></div><a href="${name}.html">Open preview</a></article>`).join("");
        return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#090a0a;color:#f7f4ed;font:15px Arial,sans-serif}.wrap{max-width:820px;margin:auto;padding:42px 26px}span{color:#ffb000;font-weight:900;letter-spacing:.15em}h1{font-size:42px;margin:10px 0}p,small{color:#9aa4aa}article{display:flex;align-items:center;justify-content:space-between;gap:18px;margin:12px 0;padding:20px;border:1px solid #303333;border-radius:14px;background:#141515}article strong,article small{display:block}a{padding:12px 16px;border-radius:10px;background:#f0a900;color:#090a0a;font-weight:900;text-decoration:none}@media(max-width:580px){article{align-items:flex-start;flex-direction:column}h1{font-size:34px}}</style></head><body><main class="wrap"><span>TAUTWEEKLY GUI PREVIEW</span><h1>Six fictional email states.</h1><p>Choose any scenario. Links stay inside this preview frame and never open a service or a new window.</p>${links}</main></body></html>`;
      }
      const index = previewDefinitions.findIndex(([previewID]) => previewID === id);
      const label = previewLabels[Math.max(1, index)] || "Newsletter Preview";
      return newsletterFrame(label, index === 1 ? "Welcome aboard" : index === 6 ? "Readiness note" : "Weekly Plex drop", index === 6 ? "#6d352f" : "#70520d", index === 5);
    },
  };
})();
