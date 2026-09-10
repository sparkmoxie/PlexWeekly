#!/usr/bin/env node
"use strict";

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (...parts) => fs.readFileSync(path.join(root, ...parts), "utf8");
const javascript = read("manager", "internal", "manager", "web", "app.js");
const html = read("manager", "internal", "manager", "web", "index.html");
const css = read("manager", "internal", "manager", "web", "app.css");
const configSource = read("manager", "internal", "manager", "config.go");
const integrationSource = read("manager", "internal", "manager", "integration.go");
const previewMock = read("docs", "gui-preview", "mock-api.js");

function functionSource(name) {
  const marker = `function ${name}(`;
  const start = javascript.indexOf(marker);
  assert.notEqual(start, -1, `missing ${name}`);
  const bodyStart = javascript.indexOf(") {", start) + 2;
  let depth = 0;
  let quote = "";
  let escaped = false;
  for (let index = bodyStart; index < javascript.length; index += 1) {
    const character = javascript[index];
    if (quote) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === quote) quote = "";
      continue;
    }
    if (["\"", "'", "`"].includes(character)) {
      quote = character;
      continue;
    }
    if (character === "{") depth += 1;
    if (character === "}" && --depth === 0) return javascript.slice(start, index + 1);
  }
  assert.fail(`unterminated ${name}`);
}

const hidden = { value: JSON.stringify({ 3: "family@example.org", 999: "orphan@example.org" }) };
const testRecipient = { value: "operator@example.org" };
const currentExcludedIDs = { value: "3" };
const currentExcludedEmails = { value: "" };
const operationControls = Object.fromEntries([
  ["preview-user-id", { value: "4" }],
  ["preview-confirm", { checked: true }],
  ["test-send-user-id", { value: "5" }],
  ["test-send-confirm", { checked: true }],
  ["manual-send-user-id", { value: "6" }],
  ["manual-send-confirm", { checked: true }],
]);
const state = {
  editor: {
    revision: "a".repeat(64),
    fields: [
      { name: "UserEmailOverrides", type: "user-email-map", value: { 3: "family@example.org", 7: "legacy@example.org" } },
      { name: "ExcludedUserIds", type: "string-list", value: ["4"] },
      { name: "ExcludedEmails", type: "email-list", value: ["LEGACY@example.org"] },
      { name: "TestEmail", type: "email" },
    ],
  },
  discovery: {
    configRevision: "a".repeat(64),
    completedAtUtc: "2031-04-18T16:31:00Z",
    users: [{ id: "3", name: "Managed Viewer", eligibility: "address-needed", needsDeliveryAddress: true }],
  },
};
const context = {
  state,
  activeSecretReveals: new Map(),
  byId(id) {
    if (id === "config-UserEmailOverrides") return hidden;
    if (id === "config-ExcludedUserIds") return currentExcludedIDs;
    if (id === "config-ExcludedEmails") return currentExcludedEmails;
    if (id === "config-TestEmail") return testRecipient;
    if (operationControls[id]) return operationControls[id];
    throw new Error(`unexpected element ${id}`);
  },
  formatDate(value) { return value; },
};
vm.createContext(context);
vm.runInContext(`
  ${functionSource("validPreviewUserID")}
  ${functionSource("savedListField")}
  ${functionSource("discoveredNewsletterUsers")}
  ${functionSource("savedUserEmailOverrides")}
  ${functionSource("userExcludedBySavedPolicy")}
  ${functionSource("selectableNewsletterUsers")}
  ${functionSource("validOperationUserID")}
  ${functionSource("suggestedSelectablePreviewUserID")}
  ${functionSource("reconcileOperationUserSelections")}
  ${functionSource("currentUserEmailOverrides")}
  ${functionSource("setUserEmailOverride")}
  ${functionSource("managedUserAddressState")}
  ${functionSource("collectConfigSaveRequest")}
  ${functionSource("discoveryFailureMessage")}
  globalThis.currentAssignments = currentUserEmailOverrides;
  globalThis.setAssignment = setUserEmailOverride;
  globalThis.addressState = managedUserAddressState;
  globalThis.collect = collectConfigSaveRequest;
  globalThis.discoveryFailure = discoveryFailureMessage;
  globalThis.newsletterUsers = discoveredNewsletterUsers;
  globalThis.selectableUsers = selectableNewsletterUsers;
  globalThis.validOperationUser = validOperationUserID;
  globalThis.suggestedUser = suggestedSelectablePreviewUserID;
  globalThis.reconcileSelections = reconcileOperationUserSelections;
  globalThis.validUserID = validPreviewUserID;
`, context);

assert.deepEqual(structuredClone(context.currentAssignments()), { 3: "family@example.org", 999: "orphan@example.org" });
context.setAssignment("3", "");
assert.deepEqual(structuredClone(context.currentAssignments()), { 999: "orphan@example.org" }, "clearing an active assignment removed an orphaned saved mapping");
context.setAssignment("3", "shared@example.org");
context.setAssignment("4", "shared@example.org");
assert.deepEqual(structuredClone(context.collect().values), {
  UserEmailOverrides: { 3: "shared@example.org", 4: "shared@example.org", 999: "orphan@example.org" },
  ExcludedUserIds: ["3"],
  ExcludedEmails: [],
  TestEmail: "operator@example.org",
}, "configuration save did not preserve duplicate inboxes, orphan mappings, and TestEmail isolation");
assert.match(context.discoveryFailure("fixture refresh unavailable"), /Cached choices.*remain visible and usable/, "a failed discovery refresh no longer retains usable assignments");
assert.equal(context.currentAssignments()["3"], "shared@example.org", "a failed discovery refresh erased an assignment");

state.discovery.users.push(
  { id: "0", name: "Local", eligibility: "address-needed", needsDeliveryAddress: true },
  { id: "000", name: "Anonymous", eligibility: "eligible", needsDeliveryAddress: true },
  { id: "42", name: "Local", eligibility: "address-needed", needsDeliveryAddress: true },
  { id: "4", name: "Saved excluded", eligibility: "eligible", role: "owner" },
  { id: "5", name: "Legacy excluded", eligibility: "eligible", role: "administrator", legacyRuleExcluded: true },
  { id: "6", name: "Missing production address", eligibility: "address-needed", needsDeliveryAddress: true, role: "administrator" },
  { id: "7", name: "Fallback excluded", eligibility: "address-needed", needsDeliveryAddress: true },
);
assert.deepEqual(Array.from(context.newsletterUsers(), (user) => user.id), ["3", "42", "4", "5", "6", "7"], "exclusion editor roster must retain saved-excluded users while filtering reserved Local by ID");
assert.deepEqual(Array.from(context.selectableUsers(), (user) => user.id), ["3", "42", "6"], "operation choices did not apply saved stable and effective-email exclusions");
assert.equal(context.validOperationUser("3"), true, "an unsaved new exclusion changed the saved operation policy");
assert.equal(context.validOperationUser("4"), false, "an unsaved uncheck re-enabled a saved stable-ID exclusion");
assert.equal(context.validOperationUser("5"), false, "a saved legacy-email exclusion remained selectable");
assert.equal(context.validOperationUser("6"), true, "preview sampling incorrectly required a production delivery address");
assert.equal(context.suggestedUser(), "6", "automatic previews did not skip excluded owner and administrator candidates");
context.reconcileSelections();
assert.equal(operationControls["preview-user-id"].value, "", "saved-excluded preview selection was retained");
assert.equal(operationControls["preview-confirm"].checked, false, "preview confirmation survived an invalid saved selection");
assert.equal(operationControls["test-send-user-id"].value, "", "legacy-excluded TestEmail selection was retained");
assert.equal(operationControls["test-send-confirm"].checked, false, "TestEmail confirmation survived an invalid saved selection");
assert.equal(operationControls["manual-send-user-id"].value, "6", "permitted Manual Welcome selection was cleared");
assert.equal(operationControls["manual-send-confirm"].checked, true, "permitted Manual Welcome confirmation was cleared");
for (const id of ["0", "00", "00000000000000000000"]) {
  assert.equal(context.validUserID(id), false, `reserved user ${id} remained selectable for a newsletter`);
  context.setAssignment(id, "anonymous@example.org");
  assert.equal(context.currentAssignments()[id], undefined, `reserved user ${id} gained a delivery assignment`);
}
hidden.value = JSON.stringify({ ...context.currentAssignments(), 0: "legacy@example.org" });
context.setAssignment("0", "replacement@example.org");
assert.equal(context.currentAssignments()["0"], "legacy@example.org", "an upgrade should retain existing inert Local config without modifying it");
for (const name of ["renderManagedUserDeliveryAddresses", "renderDiscoveredUsers", "renderDiscoveryUserCount"]) {
  assert.match(functionSource(name), /discoveredNewsletterUsers\(\)/, `${name} bypassed the shared recipient identity filter`);
}
for (const name of ["renderUserDatalist", "renderUserComboboxOptions"]) {
  assert.match(functionSource(name), /selectableNewsletterUsers\(\)/, `${name} exposed saved-excluded operation choices`);
}
for (const name of ["startPreviewOperation", "startTestSendOperation", "startManualSendOperation"]) {
  assert.match(functionSource(name), /validOperationUserID\(/, `${name} accepted typed IDs without saved-policy validation`);
}
for (const name of ["runPostSaveSetup", "recoverPendingPreviewsFromChoices"]) {
  assert.match(functionSource(name), /suggestedSelectablePreviewUserID\(\)[\s\S]+validOperationUserID\(/, `${name} trusted an excluded automatic preview suggestion`);
}

function checkAddress(value, valid) {
  const input = { value, validity: { valid }, attributes: {}, setAttribute(name, next) { this.attributes[name] = next; } };
  const status = {};
  context.addressState(input, status);
  return { status, input };
}
assert.equal(checkAddress("", true).status.textContent, "Address needed");
assert.equal(checkAddress("shared@example.org", true).status.textContent, "Assigned");
assert.equal(checkAddress("not-an-address", false).status.textContent, "Check address");
assert.equal(checkAddress("not-an-address", false).input.attributes["aria-invalid"], "true");

assert.match(html, /User exclusions — checked means excluded everywhere[\s\S]+id="managed-user-delivery-addresses"[\s\S]+Managed-user delivery addresses/, "the fallback-address UI is not a separate card after the existing exclusions card");
assert.match(html, /Native Tautulli email always wins, exclusions still apply, and multiple profiles may use the same inbox/, "the separate card does not explain recipient precedence and shared inboxes");
assert.match(functionSource("renderManagedUserDeliveryAddresses"), /needsDeliveryAddress === true[\s\S]+input\.type = "email"[\s\S]+input\.maxLength = 254[\s\S]+aria-describedby/, "the conditional card lost its validated accessible email controls");
assert.match(css, /\.managed-user-delivery-row[\s\S]+@media\(max-width:800px\)/, "managed-user address controls lack responsive layout");
assert.match(configSource, /privateConfigKeys[\s\S]+"useremailoverrides"/, "redacted configuration does not classify the address map as private");
assert.match(integrationSource, /NeedsDeliveryAddress\s+bool\s+`json:"needsDeliveryAddress,omitempty"`/, "sanitized discovery lacks the address-needed signal");
assert.doesNotMatch(integrationSource.match(/type DiscoveredUser struct \{[\s\S]+?\n\}/)?.[0] || "", /Email/, "sanitized discovery exposes an email field");
assert.match(previewMock, /\["secret", "user-email-map"\]\.includes\(item\.type\)[\s\S]+type: "secret"/, "the public preview's redacted config response exposes its synthetic address map");
assert.doesNotMatch(functionSource("renderManagedUserDeliveryAddresses"), /TestEmail/, "managed-user assignments became coupled to TestEmail");

const [playwrightModule, browserExecutable, previewURL] = process.argv.slice(2);
if (playwrightModule || browserExecutable || previewURL) {
  assert(playwrightModule && browserExecutable && previewURL, "browser QA requires PLAYWRIGHT_MODULE, BROWSER_EXE, and PREVIEW_URL");
  const { chromium } = await import(pathToFileURL(path.resolve(playwrightModule)).href);
  const browser = await chromium.launch({ executablePath: path.resolve(browserExecutable), headless: true });
  try {
    for (const viewport of [{ width: 1280, height: 900 }, { width: 390, height: 844 }]) {
      const page = await browser.newPage({ viewport });
      try {
        await page.goto(previewURL, { waitUntil: "networkidle" });
        await page.locator('[data-view="configuration"]').click();
        const card = page.locator("#managed-user-delivery-addresses");
        await card.waitFor({ state: "visible" });
        const exclusionHeading = page.getByRole("heading", { name: "User exclusions — checked means excluded everywhere" });
        assert(await exclusionHeading.isVisible(), `${viewport.width}px browser view lost the existing exclusions card`);
        const input = page.locator("#managed-user-address-41003");
        assert(await input.isVisible(), `${viewport.width}px browser view hid the managed-user email control`);
        assert.equal(await input.getAttribute("type"), "email");
        assert.equal(await input.getAttribute("maxlength"), "254");
        assert.equal(await input.inputValue(), "family-inbox@example.org");
        assert.equal(await page.locator("#managed-user-delivery-count").textContent(), "1 assigned · 0 needed");
        await input.fill("");
        assert.equal(await page.locator("#managed-user-address-41003-status").textContent(), "Address needed");
        await input.fill("not-an-address");
        assert.equal(await page.locator("#managed-user-address-41003-status").textContent(), "Check address");
        assert.equal(await input.getAttribute("aria-invalid"), "true");
        await input.fill("shared@example.org");
        assert.equal(await page.locator("#managed-user-address-41003-status").textContent(), "Assigned");
        const metrics = await page.evaluate(() => ({ documentWidth: document.documentElement.scrollWidth, viewportWidth: window.innerWidth }));
        assert(metrics.documentWidth <= metrics.viewportWidth, `${viewport.width}px browser view has horizontal overflow: ${JSON.stringify(metrics)}`);
      } finally {
        await page.close();
      }
    }
  } finally {
    await browser.close();
  }
  console.log("[PASS] Managed-user delivery card rendered and interacted correctly in desktop and mobile Chromium views.");
}

console.log("[PASS] Managed-user fallback address state, conditional accessible UI, retained mappings, TestEmail isolation, and redaction contracts.");
