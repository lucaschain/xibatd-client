const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const shell = fs.readFileSync(path.join(root, 'browser/shell.html'), 'utf8');
const script = shell.match(/<script type="text\/javascript">([\s\S]*?)<\/script>/)[1];

function fixture() {
  const syncs = [];
  const timers = [];
  const automatic = [];
  const mount = { mountpoint: '/user', idbPersistState: 0 };
  const element = { focus() {}, addEventListener() {}, classList: { add() {} } };
  const context = vm.createContext({
    console: { log() {}, error() {}, warn() {} },
    document: { getElementById: () => element, addEventListener() {}, visibilityState: 'visible' },
    window: { setInterval() {}, addEventListener() {}, location: { replace() {} } },
    navigator: {}, XIBAT_BROWSER_REVISION: 'fixture',
    setTimeout: fn => { timers.push(fn); return timers.length; }, clearTimeout() {},
    addRunDependency() {}, removeRunDependency() {}, callMain() {},
    IDBFS: { queuePersist: value => automatic.push(value) },
    FS: {
      lookupPath: () => ({ node: { mount } }),
      analyzePath: () => ({ exists: true }), mount() {},
      syncfs: (populate, callback) => syncs.push({ populate, callback }),
    },
  });
  vm.runInContext(script, context);
  return { context, syncs, timers, mount, automatic };
}

// A failed/partial hydration cannot be flushed over the saved profile.
{
  const { context, syncs, mount, automatic } = fixture();
  context.Module.preRun[0]();
  assert.equal(syncs[0].populate, true);
  context.IDBFS.queuePersist(mount);
  assert.equal(automatic.length, 0);
  syncs[0].callback(new Error('IndexedDB unavailable'));
  let error;
  context.requestPersistentStorageSync(value => { error = value; });
  assert.match(error.message, /unavailable/);
  assert.equal(syncs.length, 1, 'Failed hydration started a write transaction');
}

// New writes arriving during a flush must be included before any waiter succeeds.
{
  const { context, syncs, mount, automatic } = fixture();
  context.Module.preRun[0]();
  syncs.shift().callback();
  context.IDBFS.queuePersist(mount);
  assert.equal(automatic.length, 1);
  const completed = [];
  context.requestPersistentStorageSync(error => completed.push(['first', error]));
  context.requestPersistentStorageSync(error => completed.push(['second', error]));
  assert.equal(syncs.length, 1);
  syncs.shift().callback();
  assert.equal(completed.length, 0);
  assert.equal(syncs.length, 1);
  syncs.shift().callback();
  assert.deepEqual(completed.map(value => value[0]), ['first', 'second']);
  assert(completed.every(value => !value[1]));
}

// Quota failures reach every waiter, and a subsequent retry can succeed.
{
  const { context, syncs } = fixture();
  vm.runInContext('persistentStorageReady = true', context);
  const completed = [];
  context.requestPersistentStorageSync(error => completed.push(error));
  context.requestPersistentStorageSync(error => completed.push(error));
  const quota = new Error('QuotaExceededError');
  syncs.shift().callback(quota);
  assert.deepEqual(completed, [quota, quota]);
  context.requestPersistentStorageSync(error => completed.push(error));
  syncs.shift().callback();
  assert.equal(completed.length, 3);
  assert.equal(completed[2], undefined);
}

// Explicit synchronization serializes with upstream autoPersist.
{
  const { context, syncs, timers, mount } = fixture();
  vm.runInContext('persistentStorageReady = true', context);
  mount.idbPersistState = 'idb';
  context.requestPersistentStorageSync(() => {});
  assert.equal(syncs.length, 0);
  assert.equal(timers.length, 1);
  mount.idbPersistState = 0;
  timers.shift()();
  assert.equal(syncs.length, 1);
}

// Execute the production EM_ASM bridge body; the native export then posts this
// ID/error to the dispatcher rather than touching Lua on the browser thread.
{
  const source = fs.readFileSync(path.join(root, 'src/framework/core/resourcemanager.cpp'), 'utf8');
  const body = source.match(/MAIN_THREAD_ASYNC_EM_ASM\(\{([\s\S]*?)\}, requestId\);/)[1];
  const results = [];
  let pending;
  const context = vm.createContext({ Module: {
    requestPersistentStorageSync: callback => { pending = callback; },
    ccall: (name, result, types, args) => results.push({ name, args: Array.from(args) }),
  } });
  const request = vm.runInContext('(function($0) {' + body + '})', context);
  request(41);
  assert.equal(results.length, 0);
  pending(new Error('QuotaExceededError'));
  assert.deepEqual(results[0], { name: 'xibaWritableStorageSyncDone', args: [41, 'QuotaExceededError'] });
  request(42);
  pending();
  assert.deepEqual(results[1].args, [42, '']);
}
console.log('Browser hydration, durability acknowledgments and native bridge tests passed');
