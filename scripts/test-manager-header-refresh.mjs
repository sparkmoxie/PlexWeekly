#!/usr/bin/env node
"use strict";

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const productionPath = path.join(repositoryRoot, "manager", "internal", "manager", "web", "app.js");
const previewPath = path.join(repositoryRoot, "docs", "gui-preview", "app.js");
const productionJS = fs.readFileSync(productionPath, "utf8");
const previewJS = fs.readFileSync(previewPath, "utf8");

function functionSource(source, name) {
  const marker = `function ${name}(`;
  let start = source.indexOf(marker);
  assert.notEqual(start, -1, `missing ${name}`);
  if (source.slice(Math.max(0, start - 6), start) === "async ") start -= 6;
  const bodyStart = source.indexOf(") {", start) + 2;
  let depth = 0;
  let quote = "";
  let escaped = false;
  for (let index = bodyStart; index < source.length; index += 1) {
    const character = source[index];
    if (quote) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === quote) quote = "";
      continue;
    }
    if (character === '"' || character === "'" || character === "`") {
      quote = character;
      continue;
    }
    if (character === "{") depth += 1;
    if (character === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(start, index + 1);
    }
  }
  assert.fail(`unterminated ${name}`);
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

const functions = [
  "enterApplication",
  "updateCheckIsAvailable",
  "renderDiscovery",
  "discoveryFailureMessage",
  "refreshApplicationStatus",
  "runTautulliDiscovery",
  "runUpdateCheck",
  "checkForUpdates",
  "checkForUpdatesInBackground",
  "clearUpdateCheckAvailabilityTimer",
  "showAuthentication",
].map((name) => functionSource(productionJS, name)).join("\n\n");

const staleStatus = Object.freeze({
  state: "current",
  updateChannel: "stable",
  packageKind: "linux-native",
  backgroundCheckRecommended: true,
  checkInProgress: false,
  lastSuccessfulCheckUtc: "2031-04-17T16:30:00Z",
});
const freshStatus = Object.freeze({
  ...staleStatus,
  backgroundCheckRecommended: false,
  lastSuccessfulCheckUtc: "2031-04-18T16:30:00Z",
  nextCheckAllowedAtUtc: "2031-04-18T16:35:00Z",
});

const harnessNow = Date.parse("2031-04-18T16:31:00Z");
const configuredRevision = "a".repeat(64);
const discoveredChoices = Object.freeze({
  mode: "real-lan-discovery",
  networkBoundary: "private-and-loopback-only",
  completedAtUtc: "2031-04-18T16:31:00Z",
  configRevision: configuredRevision,
  libraries: [{ id: "10", name: "Fixture Movies", mediaType: "movie" }],
  users: [{ id: "1", name: "Fixture Admin", eligibility: "eligible", role: "administrator" }],
});

function createHarness({
  localStatuses = [staleStatus],
  localGate,
  localSuccess = true,
  localShellHidden = false,
  editorState = "ready",
  checkResults = [freshStatus],
  discoveryResults = [discoveredChoices],
  initialDiscovery = null,
  nowMilliseconds = harnessNow,
} = {}) {
  const events = [];
  const requests = [];
  const globalStatuses = [];
  const updateMessage = { textContent: "cached status remains usable" };
  const discoveryMessage = { textContent: "cached choices remain usable" };
  const discoveryConfirm = { checked: false };
  const appShell = { hidden: false };
  const refreshButton = { disabled: false };
  const discoveryRunButton = { disabled: false };
  const discoveryResultsPanel = { hidden: true };
  const authShell = { hidden: true };
  const pairForm = { hidden: true };
  const loginForm = { hidden: true };
  const loginPassword = { focus() { events.push("auth:focus"); } };
  const discoveryLibraries = { replaceChildren() { events.push("auth:libraries-clear"); } };
  const discoveryUsers = { replaceChildren() { events.push("auth:users-clear"); } };
  const managedUserDeliveryList = { replaceChildren() { events.push("auth:managed-users-clear"); } };
  const managedUserDeliveryCard = { hidden: true };
  let localIndex = 0;
  let checkIndex = 0;
  let discoveryIndex = 0;
  const state = {
    updates: null,
    updateChecking: false,
    updateCheckBackground: false,
    editor: { state: editorState, revision: configuredRevision },
    status: { observedAtUtc: "2031-04-18T16:31:00Z" },
    discovery: initialDiscovery,
    discoveryError: "",
    discoveryRunning: false,
    verificationRunning: false,
    smtpVerificationRunning: false,
  };
  const context = {
    state,
    appShell,
    authShell,
    async loadAll() {
      events.push("local:start");
      if (localGate) await localGate.promise;
      state.updates = localStatuses[Math.min(localIndex, localStatuses.length - 1)];
      state.editor = { state: editorState, revision: configuredRevision };
      localIndex += 1;
      events.push("local:complete");
      appShell.hidden = localShellHidden;
      context.setGlobalStatus("Local status refreshed.", true);
      return localSuccess;
    },
    async request(target, options = {}) {
      if (target === "/api/v1/updates/check") {
        assert.equal(options.method, "POST", "update check method changed");
        assert.equal(options.body, "{}", "update check body changed");
        const background = state.updateCheckBackground;
        events.push(background ? "check:background" : "check:manual");
        requests.push({ type: "update", target, options, background });
        const result = checkResults[Math.min(checkIndex, checkResults.length - 1)];
        checkIndex += 1;
        return await Promise.resolve(result);
      }
      if (target === "/api/v1/discovery/tautulli") {
        assert.equal(options.method, "POST", "Tautulli discovery method changed");
        const payload = JSON.parse(options.body);
        events.push("discovery:manual");
        requests.push({ type: "discovery", target, options, payload });
        const result = discoveryResults[Math.min(discoveryIndex, discoveryResults.length - 1)];
        discoveryIndex += 1;
        return await Promise.resolve(result);
      }
      throw new Error(`unexpected request ${target}`);
    },
    renderUpdates() { events.push("updates:render"); },
    renderVerification() { events.push("verification:render"); },
    renderDashboardGreeting() { events.push("dashboard:greeting"); },
    async refreshConfigurationStatus() { events.push("configuration:refresh"); },
    async recoverPendingPreviewsFromChoices() { events.push("previews:recover"); },
    setSwappingButtonText() { events.push("discovery:button"); },
    stopUpdateInstallPolling() { events.push("install-poll:stop"); },
    clearAllRevealedSecrets() { events.push("secrets:clear"); },
    closeSecretRevealDialog() { events.push("secret-dialog:close"); },
    concealMaskedInputs() { events.push("secrets:conceal"); },
    renderUserComboboxes() { events.push("users:render"); },
    renderDiscoveredLibraries() { events.push("libraries:render"); },
    renderDiscoveredUsers() { events.push("discovered-users:render"); },
    renderManagedUserDeliveryAddresses() { events.push("managed-users:render"); },
    setGlobalStatus(message, persistent) { globalStatuses.push({ message, persistent }); },
    byId(id) {
      if (id === "update-settings-message") return updateMessage;
      if (id === "discovery-message") return discoveryMessage;
      if (id === "discovery-confirm") return discoveryConfirm;
      if (id === "discovery-run-button") return discoveryRunButton;
      if (id === "discovery-results") return discoveryResultsPanel;
      if (id === "refresh-button") return refreshButton;
      if (id === "auth-shell") return authShell;
      if (id === "pair-form") return pairForm;
      if (id === "login-form") return loginForm;
      if (id === "login-password") return loginPassword;
      if (id === "discovery-libraries") return discoveryLibraries;
      if (id === "discovery-users") return discoveryUsers;
      if (id === "managed-user-delivery-list") return managedUserDeliveryList;
      if (id === "managed-user-delivery-addresses") return managedUserDeliveryCard;
      if (id === "app-shell") return appShell;
      throw new Error(`unexpected element ${id}`);
    },
    async waitForActiveUpdateCheck() {},
    clearTimeout() { events.push("timer:clear"); },
    formatDate(value) { return value; },
    window: {
      location: { hash: "", href: "http://127.0.0.1:8788/" },
      TautWeeklyUpdateUI: {
        routeFromHash() { return { view: "dashboard", section: "" }; },
        updateCheckCooldown(update) {
          const retryAt = Date.parse(String(update?.nextCheckAllowedAtUtc || ""));
          if (!Number.isFinite(retryAt)) return { active: false, delayMilliseconds: 0 };
          const delayMilliseconds = Math.max(0, retryAt - nowMilliseconds);
          return { active: delayMilliseconds > 0, delayMilliseconds };
        },
      },
    },
    selectView(view) { events.push(`view:${view}`); },
    console,
  };
  vm.createContext(context);
  vm.runInContext(`
    let lastRoutedURL = "";
    let applicationRefreshPromise = null;
    let authenticationEpoch = 0;
    let updateCheckAvailabilityTimer;
    let operationPollTimer;
    let schedulePollTimer;
    let deliveryStatusPollTimer;
    ${functions}
    globalThis.testAPI = {
      enterApplication, refreshApplicationStatus, runTautulliDiscovery, checkForUpdates, checkForUpdatesInBackground,
      expireAuthentication() { showAuthentication(); },
      resumeAuthentication() { appShell.hidden = false; authShell.hidden = true; },
    };
  `, context);
  return { context, events, requests, globalStatuses, state, updateMessage, discoveryMessage, discoveryConfirm, refreshButton };
}

async function flushAsyncWork() {
  await new Promise((resolve) => setImmediate(resolve));
}

{
  const gate = deferred();
  const check = deferred();
  const discovery = deferred();
  const harness = createHarness({ localGate: gate, checkResults: [check.promise], discoveryResults: [discovery.promise] });
  const refresh = harness.context.testAPI.refreshApplicationStatus();
  assert.equal(harness.requests.length, 0, "header Refresh contacted a service before local status completed");
  gate.resolve();
  await flushAsyncWork();
  assert.equal(harness.requests.length, 2, "header Refresh did not start one update and one Tautulli request");
  const updateRequest = harness.requests.find((request) => request.type === "update");
  const discoveryRequest = harness.requests.find((request) => request.type === "discovery");
  assert.equal(updateRequest.background, false, "header update request became a background check");
  assert.deepEqual(discoveryRequest.payload, { expectedRevision: configuredRevision, confirmRealNetwork: true });
  assert.ok(harness.events.indexOf("check:manual") > harness.events.indexOf("local:complete"), "manual update check preceded local completion");
  assert.ok(harness.events.indexOf("discovery:manual") > harness.events.indexOf("local:complete"), "Tautulli discovery preceded local completion");
  assert.equal(harness.state.updateChecking, true, "header Refresh did not share Check now's in-flight state");
  assert.equal(harness.state.discoveryRunning, true, "header Refresh did not expose discovery's in-flight state");
  discovery.resolve(discoveredChoices);
  check.resolve(freshStatus);
  await refresh;
  assert.equal(harness.state.updateChecking, false);
  assert.equal(harness.state.discoveryRunning, false);
  assert.equal(harness.state.discovery, discoveredChoices);
  assert.equal(harness.globalStatuses.at(-1).message, "Stable update check completed.");
  assert.equal(harness.events.includes("previews:recover"), false, "header Refresh inherited setup-preview recovery");
}

{
  const harness = createHarness({ localStatuses: [freshStatus] });
  await harness.context.testAPI.refreshApplicationStatus();
  assert.deepEqual(harness.requests.map((request) => request.type), ["discovery"], "active update cooldown did not isolate the Tautulli refresh");
  assert.equal(harness.globalStatuses.at(-1).message, "Local status refreshed.", "suppressed discovery status replaced local refresh success");
}

{
  const harness = createHarness({ editorState: "unconfigured" });
  await harness.context.testAPI.refreshApplicationStatus();
  assert.deepEqual(harness.requests.map((request) => request.type), ["update"], "incomplete configuration initiated Tautulli discovery or suppressed update checking");
}

{
  const harness = createHarness({ localSuccess: false });
  await harness.context.testAPI.refreshApplicationStatus();
  assert.deepEqual(harness.requests.map((request) => request.type).sort(), ["discovery", "update"], "a failed local refresh suppressed an independent saved-revision discovery or eligible update check");
}

{
  const harness = createHarness({ localSuccess: false, localShellHidden: true });
  await harness.context.testAPI.refreshApplicationStatus();
  assert.equal(harness.requests.length, 0, "an expired Manager session initiated an unauthenticated service request");
}

{
  const harness = createHarness();
  assert.equal(await harness.context.testAPI.runTautulliDiscovery(), false, "dedicated discovery ran without confirmation");
  assert.equal(harness.requests.length, 0, "dedicated discovery contacted Tautulli without confirmation");
  harness.discoveryConfirm.checked = true;
  assert.equal(await harness.context.testAPI.runTautulliDiscovery(), true, "confirmed dedicated discovery did not complete");
  assert.deepEqual(harness.requests.map((request) => request.type), ["discovery"], "dedicated discovery inherited update checking");
  assert.deepEqual(harness.requests[0].payload, { expectedRevision: configuredRevision, confirmRealNetwork: true });
  assert.equal(harness.discoveryConfirm.checked, false, "successful dedicated discovery retained stale confirmation");
  assert.equal(harness.globalStatuses.at(-1).message, "Tautulli choices loaded and retained locally.");
  assert.equal(harness.events.includes("previews:recover"), true, "dedicated discovery lost setup-preview recovery");
}

{
  const lateDiscovery = deferred();
  const harness = createHarness({ discoveryResults: [lateDiscovery.promise], initialDiscovery: discoveredChoices });
  harness.discoveryConfirm.checked = true;
  const inFlight = harness.context.testAPI.runTautulliDiscovery();
  await flushAsyncWork();
  harness.context.testAPI.expireAuthentication();
  const discoveryRenderCount = harness.events.filter((event) => event === "discovered-users:render").length;
  const verificationRenderCount = harness.events.filter((event) => event === "verification:render").length;
  lateDiscovery.resolve({ ...discoveredChoices, completedAtUtc: "2031-04-18T16:32:00Z" });
  assert.equal(await inFlight, false, "post-logout discovery completion reported authenticated success");
  assert.equal(harness.state.discovery, null, "post-logout discovery completion repopulated private choices");
  assert.equal(harness.state.discoveryRunning, false, "post-logout discovery completion retained the in-flight flag");
  assert.equal(harness.events.filter((event) => event === "discovered-users:render").length, discoveryRenderCount, "post-logout discovery completion rerendered hidden choices");
  assert.equal(harness.events.filter((event) => event === "verification:render").length, verificationRenderCount, "post-logout discovery completion rerendered hidden verification");
  assert.equal(harness.events.includes("previews:recover"), false, "post-logout dedicated discovery started setup-preview recovery");
  assert.equal(harness.events.includes("configuration:refresh"), false, "post-logout discovery completion refreshed hidden configuration state");
}

{
  const firstCheck = deferred();
  const localGate = deferred();
  const firstDiscovery = deferred();
  const harness = createHarness({
    localStatuses: [staleStatus, staleStatus, staleStatus],
    localGate,
    checkResults: [firstCheck.promise, freshStatus],
    discoveryResults: [firstDiscovery.promise, discoveredChoices],
  });
  const firstRefresh = harness.context.testAPI.refreshApplicationStatus();
  const repeatedRefresh = harness.context.testAPI.refreshApplicationStatus();
  assert.equal(harness.events.filter((event) => event === "local:start").length, 1, "repeated header click started a second local refresh");
  localGate.resolve();
  await flushAsyncWork();
  assert.equal(harness.requests.length, 2, "repeated header clicks created concurrent update or discovery requests");
  firstDiscovery.resolve(discoveredChoices);
  firstCheck.resolve(freshStatus);
  await Promise.all([firstRefresh, repeatedRefresh]);
  await harness.context.testAPI.refreshApplicationStatus();
  assert.equal(harness.requests.filter((request) => request.type === "update").length, 2, "a later eligible update refresh was permanently suppressed");
  assert.equal(harness.requests.filter((request) => request.type === "discovery").length, 2, "a later Tautulli refresh was permanently suppressed");
}

{
  const localGate = deferred();
  const harness = createHarness({ localGate });
  const staleRefresh = harness.context.testAPI.refreshApplicationStatus();
  assert.equal(harness.refreshButton.disabled, true, "active header refresh did not disable its control");
  harness.state.discoveryRunning = true;
  harness.state.updateChecking = true;
  harness.context.testAPI.expireAuthentication();
  assert.equal(harness.refreshButton.disabled, false, "authentication transition left Header Refresh disabled");
  assert.equal(harness.state.discoveryRunning, false, "authentication transition retained stale discovery state");
  assert.equal(harness.state.updateChecking, false, "authentication transition retained stale update state");
  harness.context.testAPI.resumeAuthentication();
  const currentRefresh = harness.context.testAPI.refreshApplicationStatus();
  assert.equal(harness.events.filter((event) => event === "local:start").length, 2, "new authenticated Header Refresh reused the stale session promise");
  localGate.resolve();
  await Promise.all([staleRefresh, currentRefresh]);
  assert.deepEqual(harness.requests.map((request) => request.type).sort(), ["discovery", "update"], "stale refresh completion suppressed the new session's work");
  assert.equal(harness.refreshButton.disabled, false, "new authenticated Header Refresh did not restore its control");
}

{
  const failure = new Error("The stable release service could not be reached.");
  failure.code = "offline";
  const harness = createHarness({ checkResults: [Promise.reject(failure)] });
  await harness.context.testAPI.refreshApplicationStatus();
  assert.equal(harness.globalStatuses.at(-1).message, failure.message, "header Refresh did not expose Check now's failure result");
  assert.equal(harness.state.updates, staleStatus, "manual failure discarded cached local update status");
  assert.equal(harness.updateMessage.textContent, failure.message, "manual failure was not retained in update presentation");
  assert.equal(harness.state.discovery, discoveredChoices, "update failure suppressed Tautulli discovery");
}

{
  const failure = new Error("Fixture Tautulli lookup failed safely.");
  const checked = { ...freshStatus, state: "update-available", updateAvailable: true };
  const harness = createHarness({ checkResults: [checked], discoveryResults: [Promise.reject(failure)], initialDiscovery: discoveredChoices });
  await harness.context.testAPI.refreshApplicationStatus();
  assert.equal(harness.state.updates, checked, "Tautulli failure suppressed the update result");
  assert.ok(harness.discoveryMessage.textContent.includes("Live refresh failed. Cached choices from 2031-04-18T16:31:00Z remain visible and usable."),
    "Tautulli failure did not distinguish retained choices from the failed live refresh");
  assert.ok(harness.discoveryMessage.textContent.endsWith(failure.message), "sanitized live failure detail was lost");
  assert.equal(harness.state.discovery, discoveredChoices, "Tautulli failure discarded the retained choices");
  assert.equal(harness.globalStatuses.at(-1).message, "Stable update found.", "suppressed Tautulli failure replaced the update result");
}

{
  const harness = createHarness();
  await harness.context.testAPI.enterApplication();
  assert.equal(harness.requests.length, 1, "authenticated entry no longer performs the applicable background check");
  assert.equal(harness.requests[0].type, "update", "authenticated entry unexpectedly repeated Tautulli discovery");
  assert.ok(harness.events.indexOf("check:background") > harness.events.indexOf("local:complete"));
  await flushAsyncWork();
}

{
  const harness = createHarness({ checkResults: [{ ...freshStatus, state: "update-available" }] });
  harness.state.updates = staleStatus;
  await harness.context.testAPI.checkForUpdates();
  assert.equal(harness.requests.length, 1, "explicit Check now no longer starts a check");
  assert.equal(harness.requests[0].type, "update", "explicit Check now inherited Tautulli discovery");
  assert.equal(harness.requests[0].background, false, "explicit Check now became a background action");
  assert.equal(harness.globalStatuses.at(-1).message, "Stable update found.");
}

{
  const staleCheck = deferred();
  const currentCheck = deferred();
  const currentStatus = { ...freshStatus, state: "update-available", updateAvailable: true };
  const harness = createHarness({ checkResults: [staleCheck.promise, currentCheck.promise] });
  harness.state.updates = staleStatus;
  const staleInFlight = harness.context.testAPI.checkForUpdates();
  await flushAsyncWork();
  harness.context.testAPI.expireAuthentication();
  harness.context.testAPI.resumeAuthentication();
  const currentInFlight = harness.context.testAPI.checkForUpdates();
  await flushAsyncWork();
  assert.equal(harness.state.updateChecking, true, "new authenticated update check did not start");
  currentCheck.resolve(currentStatus);
  await currentInFlight;
  assert.equal(harness.state.updates, currentStatus, "new authenticated update completion was discarded");
  assert.equal(harness.state.updateChecking, false, "new authenticated update completion retained the in-flight flag");
  assert.equal(harness.globalStatuses.at(-1).message, "Stable update found.");
  const currentRenderCount = harness.events.filter((event) => event === "updates:render").length;
  const currentTimerClearCount = harness.events.filter((event) => event === "timer:clear").length;
  staleCheck.resolve(freshStatus);
  await staleInFlight;
  assert.equal(harness.state.updates, currentStatus, "post-logout update completion replaced current authenticated state");
  assert.equal(harness.state.updateChecking, false, "post-logout update completion restored a stale in-flight flag");
  assert.equal(harness.events.filter((event) => event === "updates:render").length, currentRenderCount, "post-logout update completion rerendered the new session");
  assert.equal(harness.events.filter((event) => event === "timer:clear").length, currentTimerClearCount, "post-logout update completion cleared the current session's cooldown timer");
  assert.equal(harness.globalStatuses.length, 1, "post-logout update completion announced a stale result");
}
const timerFunctions = ["clearUpdateCheckAvailabilityTimer", "scheduleUpdateCheckAvailabilityRefresh"]
  .map((name) => functionSource(productionJS, name)).join("\n\n");
{
  const scheduled = [];
  const cleared = [];
  let renders = 0;
  const appShell = { hidden: false };
  const context = {
    setTimeout(callback, delay) { scheduled.push({ callback, delay }); return scheduled.length; },
    clearTimeout(timer) { cleared.push(timer); },
    renderUpdates() { renders += 1; },
    byId(id) { assert.equal(id, "app-shell"); return appShell; },
  };
  vm.createContext(context);
  vm.runInContext(`
    let updateCheckAvailabilityTimer;
    ${timerFunctions}
    globalThis.timerAPI = { clearUpdateCheckAvailabilityTimer, scheduleUpdateCheckAvailabilityRefresh };
  `, context);
  context.timerAPI.scheduleUpdateCheckAvailabilityRefresh({ active: true, delayMilliseconds: 975 });
  assert.equal(scheduled.length, 1, "active cooldown did not schedule its expiry render");
  assert.equal(scheduled[0].delay, 1975, "cooldown expiry render omitted its one-second safety buffer");
  scheduled[0].callback();
  assert.equal(renders, 1, "cooldown expiry did not rerender update availability");
  context.timerAPI.scheduleUpdateCheckAvailabilityRefresh({ active: false, delayMilliseconds: 0 });
  appShell.hidden = true;
  context.timerAPI.scheduleUpdateCheckAvailabilityRefresh({ active: true, delayMilliseconds: 975 });
  assert.equal(scheduled.length, 1, "hidden authentication state rearmed the cooldown timer");
  assert.ok(cleared.length >= 2, "inactive cooldown did not clear the previous timer");
  context.timerAPI.clearUpdateCheckAvailabilityTimer();
}

for (const [name, source] of [["production", productionJS], ["preview", previewJS]]) {
  assert.doesNotMatch(source, /backgroundUpdateCheckAttempted/, `${name} retains a session-wide suppression flag`);
  assert.match(source, /byId\("refresh-button"\)\.addEventListener\("click", refreshApplicationStatus\)/, `${name} header Refresh is not scoped to the new handler`);
  assert.match(source, /if \(applicationRefreshPromise\) return applicationRefreshPromise;[\s\S]+recoverPendingPreviews: false,[\s\S]+updateCheckIsAvailable\(\)[\s\S]+Promise\.allSettled\(refreshes\)/, `${name} header Refresh does not serialize and isolate local, Tautulli, and update work`);
  assert.match(source, /JSON\.stringify\(\{ expectedRevision: state\.editor\.revision, confirmRealNetwork: true \}\)/, `${name} header Tautulli refresh changed the safe saved-revision request`);
  assert.match(source, /requireConfirmation && !byId\("discovery-confirm"\)\.checked/, `${name} dedicated Tautulli refresh lost confirmation`);
  assert.match(source, /state\.discoveryError = discoveryFailureMessage\(error\.message\);[\s\S]+renderDiscovery\(\)/, `${name} discovery failures do not distinguish retained choices from the failed live refresh`);
  assert.match(source, /scheduleUpdateCheckAvailabilityRefresh\(cooldown\)/, `${name} cooldown does not schedule an expiry render`);
  assert.match(source, /function showAuthentication\(\) \{[\s\S]+clearUpdateCheckAvailabilityTimer\(\)/, `${name} authentication boundary retains the cooldown timer`);
  assert.match(source, /function showAuthentication\(\) \{\s+authenticationEpoch \+= 1;/, `${name} authentication boundary does not invalidate in-flight completions`);
  const refreshSource = functionSource(source, "refreshApplicationStatus");
  const loadSource = functionSource(source, "loadAll");
  const discoverySource = functionSource(source, "runTautulliDiscovery");
  const updateSource = functionSource(source, "runUpdateCheck");
  const authenticationSource = functionSource(source, "showAuthentication");
  assert.doesNotMatch(refreshSource, /localStatusLoaded/, `${name} header Refresh still suppresses saved-revision discovery after a local-status failure`);
  assert.match(loadSource, /const loadAuthenticationEpoch = authenticationEpoch;[\s\S]+loadAuthenticationEpoch !== authenticationEpoch \|\| byId\("app-shell"\)\.hidden/, `${name} stale local-status completion can overwrite a newly authenticated session`);
  assert.match(discoverySource, /const discoveryAuthenticationEpoch = authenticationEpoch;[\s\S]+discoveryAuthenticationEpoch !== authenticationEpoch \|\| byId\("app-shell"\)\.hidden[\s\S]+discoveryAuthenticationEpoch === authenticationEpoch && !byId\("app-shell"\)\.hidden/, `${name} discovery completion can cross the authentication boundary`);
  assert.match(updateSource, /finally \{\s+if \(updateAuthenticationEpoch === authenticationEpoch && !byId\("app-shell"\)\.hidden\) \{\s+state\.updateChecking = false;/, `${name} stale update completion can clear a new session's in-flight state`);
  assert.doesNotMatch(updateSource, /else\s*\{\s*clearUpdateCheckAvailabilityTimer\(\);?\s*\}/, `${name} stale update completion can clear a new session's cooldown timer`);
  assert.match(authenticationSource, /applicationRefreshPromise = null;[\s\S]+byId\("refresh-button"\)\.disabled = false;[\s\S]+state\.discoveryRunning = false;[\s\S]+state\.updateChecking = false;/, `${name} authentication transition does not reset all refresh/discovery/update state`);
  assert.equal((source.match(/refreshApplicationStatus/g) || []).length, 2, `${name} invokes the header-only handler from another path`);
  assert.equal((source.match(/addEventListener\("click", refreshApplicationStatus\)/g) || []).length, 1, `${name} attached the behavior to another control`);
  assert.match(source, /byId\("update-check-button"\)\.addEventListener\("click", checkForUpdates\)/, `${name} explicit Check now semantics changed`);
  assert.doesNotMatch(source, /byId\("tailscale-refresh-button"\)\.addEventListener\("click", refreshApplicationStatus\)/, `${name} Tailscale verification gained an update check`);
}
assert.match(productionJS, /if \(refreshed && recoverPendingPreviews\) await recoverPendingPreviewsFromChoices\(discoveryAuthenticationEpoch\);/, "dedicated production discovery lost gated setup-preview recovery");
assert.match(functionSource(productionJS, "recoverPendingPreviewsFromChoices"), /expectedAuthenticationEpoch !== authenticationEpoch \|\| byId\("app-shell"\)\.hidden[\s\S]+expectedAuthenticationEpoch === authenticationEpoch && !byId\("app-shell"\)\.hidden/, "setup-preview recovery completion can cross logout");
assert.doesNotMatch(functionSource(productionJS, "refreshApplicationStatus"), /recoverPendingPreviewsFromChoices/, "header Refresh directly inherited setup-preview recovery");

console.log("[PASS] Header Refresh local-first Tautulli/update parity, cooldown expiry, confirmation, concurrency, failure isolation, entry, and manual contracts.");
