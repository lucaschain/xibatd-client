// Real IndexedDB regression in a disposable persistent Chromium profile.
// --source injects local Lua/shell sources. --transport-shim is only for testing
// against an older published WASM without the new native sync signal; it replaces
// that signal transport, not FS.syncfs or IndexedDB. No account login is performed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '..');
const sourceMode = process.argv.includes('--source');
const shimMode = process.argv.includes('--transport-shim');
const url = process.argv.slice(2).find(arg => !arg.startsWith('--')) || 'https://play.xibatd.online/';
const base = '/user/.otclient/data/things/1098/';
const startup = `
if TEST_SHIM and not g_resources.requestWritableStorageSync then
  local nextId, received = 0, 0
  g_resources.requestWritableStorageSync = function()
    nextId = nextId + 1
    local file = assert(io.open('/xiba-storage-test/request', 'wb'))
    file:write(tostring(nextId)) file:close()
    return nextId
  end
  local function poll()
    local file = io.open('/xiba-storage-test/result', 'rb')
    if file then
      local result = json.decode(file:read('*a')) file:close()
      if result.id > received then
        received = result.id
        signalcall(g_resources.onWritableStorageSync, result.id, result.error)
      end
    end
    scheduleEvent(poll, 10)
  end
  scheduleEvent(poll, 10)
end
local download = HTTP.download
HTTP.download = function(...) print('PERSIST_ZIP') return download(...) end
scheduleEvent(function()
  modules.client_assets.ensureClientVersion(1098, function(ok, err)
    assert(ok, err)
    g_game.setClientVersion(0)
    g_game.setClientVersion(1098)
    g_game.setProtocolVersion(1098)
    assert(modules.game_things.isLoaded())
    modules.client_assets.ensureClientVersion(1098, function(current, error, changed)
      assert(current, error) assert(changed == false)
      print('PERSIST_READY')
    end)
  end)
end, 1000)
`;

(async () => {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'xiba-asset-persistence-'));
  let context;
  const errors = [];
  let downloads = 0;
  let ready = 0;
  async function openBrowser() {
    context = await chromium.launchPersistentContext(profile, { headless: true,
      args: ['--enable-unsafe-swiftshader', '--use-angle=swiftshader', '--disable-dev-shm-usage'] });
    await context.route(url, async route => {
      try {
      const response = await route.fetch();
      const served = await response.text();
      let html = served;
      if (sourceMode) {
        const tag = served.match(/<meta[^>]*xibat-browser-revision[^>]*>/)[0];
        const revision = tag.match(/content=["']?([0-9a-f]{40})/)[1];
        const loader = served.match(/<script[^>]*\bsrc=[^>]*otclient\.js[^>]*>\s*<\/script>/)[0];
        html = fs.readFileSync(path.join(root, 'browser/shell.html'), 'utf8')
          .replace('__XIBAT_BROWSER_REVISION__', revision).replace('{{{ SCRIPT }}}', loader);
      }
      const patch = sourceMode ? ['asset_revision', 'client_assets'].map(name =>
        `FS.writeFile('/modules/client_assets/${name}.lua',${JSON.stringify(
          fs.readFileSync(path.join(root, 'modules/client_assets', name + '.lua'), 'utf8'))});`).join('') : '';
      const shim = shimMode ? `
        FS.mkdirTree('/xiba-storage-test');
        let last = 0;
        setInterval(() => {
          if (!FS.analyzePath('/xiba-storage-test/request').exists) return;
          const id = Number(FS.readFile('/xiba-storage-test/request', {encoding:'utf8'}));
          if (!id || id === last) return;
          last = id;
          Module.requestPersistentStorageSync(error => FS.writeFile('/xiba-storage-test/result',
            JSON.stringify({id, error: error ? String(error.message || error) : ''})));
        }, 10);
      ` : '';
      const lua = 'local TEST_SHIM = ' + (shimMode ? 'true' : 'false') + '\n' + startup;
      html = html.replace(/onRuntimeInitialized:\s*startGame/, () =>
        `onRuntimeInitialized:function(){${patch}${shim}FS.writeFile('/otclientrc.lua',${JSON.stringify(lua)});startGame()}`);
      await route.fulfill({ response, body: html });
      } catch (error) {
        errors.push(error.message);
        await route.abort();
      }
    });
  }
  function observe(page) {
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => {
      const text = message.text();
      if (text.includes('PERSIST_ZIP')) downloads++;
      if (text.includes('PERSIST_READY')) ready++;
      if (text.includes('Aborted(') || text.includes('window.onerror:')) errors.push(text);
    });
  }
  async function run(page, label, navigate, expectedDownloads) {
    const previousReady = ready;
    const previousDownloads = downloads;
    await navigate();
    const deadline = Date.now() + 180000;
    while (ready === previousReady && !errors.length && Date.now() < deadline) await page.waitForTimeout(250);
    assert.deepEqual(errors, []);
    assert(ready > previousReady, label + ': asset check did not finish');
    assert.equal(downloads - previousDownloads, expectedDownloads, label + ': unexpected ZIP download');
    // Inspect IndexedDB immediately after the success callback, without waiting
    // for autoPersist or forcing an extra sync that could hide a durability bug.
    const saved = await page.evaluate(async base => new Promise((resolve, reject) => {
      const open = indexedDB.open('/user');
      open.onerror = () => reject(open.error);
      open.onsuccess = () => {
        const db = open.result;
        const tx = db.transaction('FILE_DATA', 'readonly');
        const store = tx.objectStore('FILE_DATA');
        const values = {};
        for (const name of ['Tibia.dat', 'Tibia.spr', '.asset-revision.json', '.asset-update/pending.json', '.asset-update/backup/Tibia.spr']) {
          const request = store.get(base + name);
          request.onsuccess = () => { values[name] = request.result?.contents?.byteLength ?? null; };
        }
        tx.oncomplete = () => { db.close(); resolve(values); };
        tx.onerror = () => { db.close(); reject(tx.error); };
      };
    }), base);
    assert(saved['Tibia.dat'] > 0 && saved['Tibia.spr'] > 0 && saved['.asset-revision.json'] > 0);
    assert.equal(saved['.asset-update/pending.json'], null, label + ': stale journal persisted');
    assert.equal(saved['.asset-update/backup/Tibia.spr'], null, label + ': backup was not durably cleaned up');
    console.log(`${label}: ${downloads - previousDownloads} ZIP downloads; durable files and marker verified`);
  }
  async function mutateCache(page, mode) {
    await page.evaluate(async ({base, mode}) => {
      if (mode === 'journal') FS.writeFile(base + '.asset-update/pending.json', '{"previous":[]}');
      if (mode === 'marker') FS.unlink(base + '.asset-revision.json');
      if (mode === 'cleanup') {
        FS.mkdirTree(base + '.asset-update/backup');
        FS.writeFile(base + '.asset-update/backup/Tibia.spr', 'synthetic orphan');
      }
      if (mode === 'corrupt') FS.writeFile(base + 'Tibia.dat', 'synthetic corruption');
      await new Promise((resolve, reject) => Module.requestPersistentStorageSync(error => error ? reject(error) : resolve()));
    }, {base, mode});
  }
  try {
    await openBrowser();
    let page = await context.newPage(); observe(page);
    const goto = () => page.goto(url, {waitUntil:'domcontentloaded', timeout:90000});
    await run(page, 'fresh install', goto, 1);
    await run(page, 'page refresh', () => page.reload({waitUntil:'domcontentloaded'}), 0);
    await page.close();
    page = await context.newPage(); observe(page);
    await run(page, 'tab reopen', goto, 0);
    await context.close(); context = null;
    await openBrowser();
    page = await context.newPage(); observe(page);
    await run(page, 'browser process restart', goto, 0);
    for (const mode of ['journal', 'marker', 'cleanup', 'corrupt']) {
      await mutateCache(page, mode);
      await run(page, mode + ' recovery', () => page.reload({waitUntil:'domcontentloaded'}), mode === 'corrupt' ? 1 : 0);
    }
    console.log('Persistent browser asset cache regression passed');
  } finally {
    if (context) await context.close();
    fs.rmSync(profile, {recursive:true, force:true});
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
