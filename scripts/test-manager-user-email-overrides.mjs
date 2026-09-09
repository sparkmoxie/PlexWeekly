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
const state = {
  editor: {
    revision: "a".repeat(64),
    fields: [
      { name: "UserEmailOverrides", type: "user-email-map" },
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
    if (id === "config-TestEmail") return testRecipient;
    throw new Error(`unexpected element ${id}`);
  },
  formatDate(value) { return value; },
};
vm.createContext(context);
vm.runInContext(`
  ${functionSource("validPreviewUserID")}
  ${functionSource("discoveredNewsletterUsers")}
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
  globalThis.validUserID = validPreviewUserID;
`, context);

assert.deepEqual(structuredClone(context.currentAssignments()), { 3: "family@example.org", 999: "orphan@example.org" });
context.setAssignment("3", "");
assert.deepEqual(structuredClone(context.currentAssignments()), { 999: "orphan@example.org" }, "clearing an active assignment removed an orphaned saved mapping");
context.setAssignment("3", "shared@example.org");
context.setAssignment("4", "shared@example.org");
assert.deepEqual(structuredClone(context.collect().values), {
  UserEmailOverrides: { 3: "shared@example.org", 4: "shared@example.org", 999: "orphan@example.org" },
  TestEmail: "operator@example.org",
}, "configuration save did not preserve duplicate inboxes, orphan mappings, and TestEmail isolation");
assert.match(context.discoveryFailure("fixture refresh unavailable"), /Cached choices.*remain visible and usable/, "a failed discovery refresh no longer retains usable assignments");
assert.equal(context.currentAssignments()["3"], "shared@example.org", "a failed discovery refresh erased an assignment");

state.discovery.users.push(
  { id: "0", name: "Local", eligibility: "address-needed", needsDeliveryAddress: true },
  { id: "000", name: "Anonymous", eligibility: "eligible", needsDeliveryAddress: true },
  { id: "42", name: "Local", eligibility: "address-needed", needsDeliveryAddress: true },
);
assert.deepEqual(Array.from(context.newsletterUsers(), (user) => user.id), ["3", "42"], "Local filtering must use numeric identity, not display name");
for (const id of ["0", "00", "00000000000000000000"]) {
  assert.equal(context.validUserID(id), false, `reserved user ${id} remained selectable for a newsletter`);
  context.setAssignment(id, "anonymous@example.org");
  assert.equal(context.currentAssignments()[id], undefined, `reserved user ${id} gained a delivery assignment`);
}
hidden.value = JSON.stringify({ ...context.currentAssignments(), 0: "legacy@example.org" });
context.setAssignment("0", "replacement@example.org");
assert.equal(context.currentAssignments()["0"], "legacy@example.org", "an upgrade should retain existing inert Local config without modifying it");
for (const name of ["renderManagedUserDeliveryAddresses", "renderDiscoveredUsers", "renderDiscoveryUserCount", "renderUserDatalist", "renderUserComboboxOptions"]) {
  assert.match(functionSource(name), /discoveredNewsletterUsers\(\)/, `${name} bypassed the shared recipient identity filter`);
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

assert.match(html, /Delivery exclusions — checked means excluded[\s\S]+id="managed-user-delivery-addresses"[\s\S]+Managed-user delivery addresses/, "the fallback-address UI is not a separate card after the existing exclusions card");
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
        const exclusionHeading = page.getByRole("heading", { name: "Delivery exclusions — checked means excluded" });
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
