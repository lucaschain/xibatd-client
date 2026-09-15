// Opt-in Chromium/WASM regression against the published bundle and asset channel.
// Requires Playwright. Only a fresh browser context is modified; no account login
// or production writes occur. Source Lua is injected before the WASM main starts.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '..');
const url = process.argv[2] || 'https://play.xibatd.online/';
const lua = `
local function check(round)
  print('ASSET_MEMORY_CHECK ' .. round)
  modules.client_assets.ensureClientVersion(1098, function(ok, err, changed)
    assert(ok, err)
    if round == 1 then
      assert(changed == true)
      g_game.setClientVersion(0)
      g_game.setClientVersion(1098)
      g_game.setProtocolVersion(1098)
      assert(modules.game_things.isLoaded())
      scheduleEvent(function() check(2) end, 1000)
    else
      assert(changed == false)
      if TEST_RELOAD then
        -- Simulate a newly required installation with the old SPR still cached.
        assert(g_resources.writeFileContents('/data/things/1098/Tibia.dat', 'synthetic corruption'))
        modules.client_assets.ensureClientVersion(1098, function()
          error('A stale login resumed instead of reloading for installation')
        end)
      else
        print('ASSET_MEMORY_PASS')
      end
    end
  end)
end
scheduleEvent(function() check(1) end, 1000)
`;

(async () => {
  const browser = await chromium.launch({ headless: true,
    args: ['--enable-unsafe-swiftshader', '--use-angle=swiftshader', '--disable-dev-shm-usage'] });
  try {
    const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    const page = await context.newPage();
    const errors = [];
    let navigations = 0;
    let passed = false;
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => {
      const text = message.text();
      if (text.includes('ASSET_MEMORY_')) console.log(text);
      if (text.includes('ASSET_MEMORY_PASS')) passed = true;
      if (text.includes('Aborted(') || text.includes('window.onerror:')) errors.push(text);
    });
    await page.route(url, async route => {
      const response = await route.fetch();
      const html = await response.text();
      assert.match(html, /onRuntimeInitialized:\s*startGame/);
      navigations++;
      const scripts = ['asset_revision', 'client_assets'].map(name =>
        `FS.writeFile('/modules/client_assets/${name}.lua',${JSON.stringify(
          fs.readFileSync(path.join(root, 'modules/client_assets', name + '.lua'), 'utf8'))});`
      ).join('');
      const startup = 'local TEST_RELOAD = ' + (navigations === 1 ? 'true' : 'false') + '\n' + lua;
      const body = html.replace(/onRuntimeInitialized:\s*startGame/, () =>
        `onRuntimeInitialized:function(){${scripts}FS.writeFile('/otclientrc.lua',${JSON.stringify(startup)});startGame()}`);
      await route.fulfill({ response, body });
    });
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 90000 });
    const deadline = Date.now() + 240000;
    while (!passed && !errors.length && Date.now() < deadline) await page.waitForTimeout(1000);
    assert.deepEqual(errors, [], 'Browser worker/runtime errors');
    assert(passed, 'Timed out verifying download, cached-sprite recheck and reload/install recovery');
    assert.equal(navigations, 2, 'Expected one automatic browser reload for the required reinstallation');
    assert.equal(await page.locator('#title-text').innerText(), '');
    console.log('Browser asset memory regression passed: download, world-login recheck, reload and reinstall.');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
