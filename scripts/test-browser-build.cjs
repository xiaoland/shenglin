// Check the generated extension's shipping contract, including the Native host identity.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.join(__dirname, '..');
const output = path.join(root, 'BrowserExtension', '.output', 'chrome-mv3');
const manifest = JSON.parse(fs.readFileSync(path.join(output, 'manifest.json'), 'utf8'));
const digest = crypto.createHash('sha256').update(Buffer.from(manifest.key, 'base64')).digest('hex').slice(0, 32);
const identity = [...digest].map(value => String.fromCharCode(97 + parseInt(value, 16))).join('');
assert.ok(fs.readFileSync(path.join(root, 'Mac', 'BrowserAdapter.swift'), 'utf8').includes(`extensionID = "${identity}"`));
assert.equal(manifest.manifest_version, 3);
assert.deepEqual(manifest.permissions.slice().sort(), ['activeTab', 'nativeMessaging', 'offscreen', 'scripting', 'tabCapture']);
assert.equal(manifest.host_permissions, undefined);
assert.equal(manifest.content_scripts, undefined); // Injection still requires explicit per-tab authorization.
assert.equal(manifest.web_accessible_resources, undefined);
assert.equal(manifest.background.service_worker, 'background.js');
assert.equal(manifest.action.default_popup, 'popup.html');
for (const file of [manifest.background.service_worker, manifest.action.default_popup,
  ...Object.values(manifest.icons), ...Object.values(manifest.action.default_icon), 'offscreen.html', 'input-main.js', 'input-bridge.js']) {
  assert.ok(fs.statSync(path.join(output, file)).isFile(), file);
}
for (const html of ['popup.html', 'offscreen.html']) {
  const content = fs.readFileSync(path.join(output, html), 'utf8');
  for (const match of content.matchAll(/(?:src|href)="([^"]+)"/g)) {
    assert.ok(!/^https?:/.test(match[1]), 'Production pages must only load bundled assets.');
    assert.ok(fs.statSync(path.join(output, match[1].replace(/^\//, ''))).isFile(), match[1]);
  }
}
function checkFiles(directory) {
  for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
    assert.ok(!['node_modules', 'entrypoints', '.wxt', 'tests', 'package.json', 'wxt.config.ts'].includes(entry.name), entry.name);
    if (entry.isDirectory()) checkFiles(path.join(directory, entry.name));
  }
}
checkFiles(output);
console.log('通过：生产扩展身份、最小权限、手动注入、入口和本地资源。');
