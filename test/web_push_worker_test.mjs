import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

function environment() {
  const entries = new Map();
  const handlers = {};
  const shown = [];
  const opened = [];
  const active = [];
  const cache = {
    async put(url, value) { entries.set(url, await value.text()); },
    async match(url) { return entries.has(url) ? new Response(entries.get(url)) : undefined; },
  };
  const context = vm.createContext({ URL, Response, Uint8Array, atob, console,
    caches: { async open() { return cache; } },
    self: {
      registration: { scope: 'https://example.org/matter/.matter-push/',
        async showNotification(title, options) { shown.push({ title, options }); },
        async getNotifications() { return active; } },
      addEventListener(type, handler) { handlers[type] = handler; },
      clients: { async matchAll() { return []; }, async openWindow(url) { opened.push(url); } },
      async skipWaiting() {},
    },
  });
  vm.runInContext(readFileSync(new URL('../web/matter-push-sw.js', import.meta.url), 'utf8'), context);
  return { cache, context, shown, opened, active,
    async dispatch(type, event) {
      let pending;
      handlers[type]({ ...event, waitUntil(promise) { pending = promise; } });
      await pending;
    },
  };
}
const target = { user_id: '@alice:example.org', room_id: '!room:example.org',
  event_id: '$event', registration_id: 'current' };
async function account(env, id, enabled = true, registrationId = 'current') {
  await env.cache.put(`https://example.org/matter/.matter-push/accounts/${encodeURIComponent(id)}`,
    new Response(JSON.stringify({ enabled, registrationId })));
}

test('worker suppresses notifications only for a focused visible Matter window', async () => {
  const env = environment();
  await account(env, target.user_id);
  for (const [url, focused, visibilityState, expected] of [
    ['https://example.org/matter/', true, 'visible', 0],
    ['https://example.org/matter/', false, 'visible', 1],
    ['https://example.org/matter/', true, 'hidden', 2],
    ['https://example.org/elsewhere/', true, 'visible', 3],
  ]) {
    env.context.self.clients.matchAll = async () => [{ url, focused, visibilityState }];
    await env.dispatch('push', { data: { json: () => target } });
    assert.equal(env.shown.length, expected);
  }
});

test('worker shows plain message content and keeps encrypted messages generic', async () => {
  const env = environment();
  await account(env, target.user_id);
  for (const [type, expected] of [
    ['m.room.message', '正文'],
    ['m.room.encrypted', '已加密的消息'],
    [undefined, '你有一条新消息'],
  ]) {
    // A fresh account per case keeps the accumulated conversation separate.
    await account(env, target.user_id, false);
    await env.cache.put('https://example.org/matter/.matter-push/conversations/' +
      encodeURIComponent(target.user_id), new Response('{}'));
    await account(env, target.user_id);
    await env.dispatch('push', { data: { json: () => ({ ...target, type, content: { body: '正文' } }) } });
    assert.equal(env.shown.at(-1).options.body, expected);
  }
});

test('worker titles with the room, prefixes the sender in a group and accumulates', async () => {
  const env = environment();
  await account(env, target.user_id);
  const rooms = { [target.room_id]: { name: '项目组', is_direct: false } };
  await env.cache.put('https://example.org/matter/.matter-push/rooms/' +
    encodeURIComponent(target.user_id), new Response(JSON.stringify(rooms)));
  const message = (eventId, sender, display, body) => ({ ...target, event_id: eventId,
    type: 'm.room.message', sender, sender_display_name: display, content: { body } });
  await env.dispatch('push', { data: { json: () => message('$one', '@alice:example.org', 'Alice', '第一条') } });
  assert.equal(env.shown.at(-1).title, '项目组');
  assert.equal(env.shown.at(-1).options.body, 'Alice：第一条');
  await env.dispatch('push', { data: { json: () => message('$two', '@bob:example.org', 'Bob', '第二条') } });
  // The same tag updates one notification rather than stacking a new one.
  assert.equal(env.shown.at(-1).options.tag, `matter:${target.user_id}:${target.room_id}`);
  assert.equal(env.shown.at(-1).options.body, 'Alice：第一条\nBob：第二条');
});

test('a direct chat drops the sender prefix and read clears accumulated lines', async () => {
  const env = environment();
  await account(env, target.user_id);
  await env.cache.put('https://example.org/matter/.matter-push/rooms/' +
    encodeURIComponent(target.user_id),
    new Response(JSON.stringify({ [target.room_id]: { name: 'Alice', is_direct: true } })));
  await env.dispatch('push', { data: { json: () => ({ ...target, type: 'm.room.message',
    sender: '@alice:example.org', sender_display_name: 'Alice', content: { body: '在吗' } }) } });
  assert.equal(env.shown.at(-1).title, 'Alice');
  assert.equal(env.shown.at(-1).options.body, '在吗');

  env.active.push({ data: target, close() {} });
  const bridge = await browserBridge(env);
  await bridge.cancelRoomNotifications(target.user_id, target.room_id, [target.event_id]);
  // Otherwise the next message would resurface text the user already read.
  const saved = await env.cache.match('https://example.org/matter/.matter-push/conversations/' +
    encodeURIComponent(target.user_id));
  assert.deepEqual(await saved.json(), {});
});

/** Load the browser bridge into the same context as the worker. */
async function browserBridge(env) {
  Object.assign(env.context, {
    document: { baseURI: 'https://example.org/matter/' },
    location: { href: 'https://example.org/matter/' },
    history: { replaceState() {} },
    isSecureContext: true,
    Notification: { permission: 'granted', async requestPermission() { return 'granted'; } },
    navigator: { serviceWorker: { addEventListener() {}, async register() { return {}; },
      async getRegistration() { return { async getNotifications() { return env.active; } }; } } },
    window: { PushManager: {}, Notification: {} },
  });
  vm.runInContext(readFileSync(new URL('../web/matter-push.js', import.meta.url), 'utf8'), env.context);
  return env.context.window.matterPush;
}

test('worker displays generic content and routes notification clicks from a closed app', async () => {
  const env = environment();
  await account(env, target.user_id);
  await env.dispatch('push', { data: { json: () => ({ ...target, content: { body: 'secret text' } }) } });
  assert.equal(env.shown.length, 1);
  assert.equal(env.shown[0].options.body, '你有一条新消息');
  assert.equal(env.shown[0].options.icon, 'https://example.org/matter/icons/Icon-192.png');
  await env.dispatch('notificationclick', { notification: { data: target, close() {} } });
  const launch = new URL(env.opened[0]);
  assert.equal(launch.pathname, '/matter/');
  assert.deepEqual(JSON.parse(launch.searchParams.get('matter_push')), target);
});

test('worker rejects disabled, stale, removed-account, malformed and count-only pushes', async () => {
  const env = environment();
  await account(env, target.user_id, false);
  await env.dispatch('push', { data: { json: () => target } });
  await account(env, target.user_id, true, 'new');
  await env.dispatch('push', { data: { json: () => target } });
  await env.dispatch('push', { data: { json: () => ({ ...target, user_id: '@removed:example.org' }) } });
  await env.dispatch('push', { data: { json: () => ({ unread: 1 }) } });
  await env.dispatch('push', { data: { json() { throw new SyntaxError('bad payload'); } } });
  await env.dispatch('notificationclick', { notification: { data: target, close() {} } });
  assert.equal(env.shown.length, 0);
  assert.equal(env.opened.length, 0);
});

test('worker delivers to an existing tab and preserves each account', async () => {
  const env = environment();
  let received;
  let focused = false;
  env.context.self.clients.matchAll = async () => [{ url: 'https://example.org/matter/',
    postMessage(message) { received = message; }, async focus() { focused = true; } }];
  await account(env, target.user_id, false);
  const bob = { ...target, user_id: '@bob:example.org' };
  await account(env, bob.user_id);
  await env.dispatch('push', { data: { json: () => bob } });
  assert.equal(env.shown.length, 1);
  await env.dispatch('notificationclick', { notification: { data: bob, close() {} } });
  assert.equal(received.type, 'matter-push-open');
  assert.deepEqual(received.target, bob);
  assert.equal(focused, true);
  assert.equal(env.opened.length, 0);
});

test('browser bridge requests permission only explicitly and reuses subscriptions without replacing a different VAPID key', async () => {
  const env = environment();
  let permissionRequests = 0;
  let subscriptions = 0;
  const key = Buffer.from([4, ...Array(64).fill(1)]);
  const subscription = { options: { applicationServerKey: key },
    toJSON() { return { endpoint: 'https://push.example.org/sub', keys: { p256dh: 'key', auth: 'auth' } }; } };
  const registration = { active: {}, async getNotifications() { return env.active; }, pushManager: {
    async getSubscription() { return subscription; },
    async subscribe() { subscriptions++; return subscription; },
  } };
  Object.assign(env.context, {
    document: { baseURI: 'https://example.org/matter/' },
    location: { href: 'https://example.org/matter/' },
    history: { replaceState() {} }, isSecureContext: true,
    Notification: { permission: 'granted', async requestPermission() { permissionRequests++; return 'granted'; } },
    navigator: { serviceWorker: { addEventListener() {}, async register(url, options) {
      assert.equal(url.href, 'https://example.org/matter/matter-push-sw.js');
      assert.equal(options.scope, '/matter/.matter-push/');
      return registration;
    } } }, window: { PushManager: {}, Notification: {} },
  });
  vm.runInContext(readFileSync(new URL('../web/matter-push.js', import.meta.url), 'utf8'), env.context);
  const bridge = env.context.window.matterPush;
  await bridge.initialize();
  assert.equal(permissionRequests, 0);
  const result = JSON.parse(await bridge.subscribe(key.toString('base64url')));
  assert.equal(result.keys.p256dh, 'key');
  assert.equal(subscriptions, 0);
  await assert.rejects(bridge.subscribe(Buffer.from([4, ...Array(64).fill(2)]).toString('base64url')), /VAPID/);
  assert.equal(subscriptions, 0);
  await bridge.requestPermission();
  assert.equal(permissionRequests, 1);
  await bridge.updateAccount(target.user_id, 'current', true);
  await env.dispatch('push', { data: { json: () => target } });
  assert.equal(env.shown.length, 1);
  await bridge.updateAccount(target.user_id, '', false);
  await env.dispatch('push', { data: { json: () => target } });
  assert.equal(env.shown.length, 1);
  const closed = [];
  for (const data of [target, { ...target, user_id: '@bob:example.org' },
    { ...target, room_id: '!other:example.org' }]) {
    env.active.push({ data, close() { closed.push(data); } });
  }
  const events = JSON.parse(await bridge.roomNotificationEvents(target.user_id, target.room_id));
  assert.deepEqual(events, [target.event_id]);
  env.active.push({ data: { ...target, event_id: '$arriving' }, close() { closed.push(this.data); } });
  await bridge.cancelRoomNotifications(target.user_id, target.room_id, events);
  assert.deepEqual(closed, [target]);
  assert.equal(permissionRequests, 1);
});
