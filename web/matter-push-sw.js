const appBase = new URL('../', self.registration.scope);
const accountUrl = (id) => new URL(`.matter-push/accounts/${encodeURIComponent(id)}`, appBase).href;
const roomsUrl = (id) => new URL(`.matter-push/rooms/${encodeURIComponent(id)}`, appBase).href;
const conversationsUrl = (id) =>
  new URL(`.matter-push/conversations/${encodeURIComponent(id)}`, appBase).href;
const cacheName = `matter-push:${appBase.href}`;

/** How many messages one room's notification shows. */
const maxMessagesPerConversation = 5;

const GENERIC_BODY = '你有一条新消息';
const ENCRYPTED_BODY = '已加密的消息';
const GENERIC_TITLE = 'Matter';

const TYPE_HINTS = {
  'm.image': '发送了一张图片',
  'm.video': '发送了视频',
  'm.audio': '发送了音频',
  'm.file': '发送了文件',
  'm.location': '发送了位置',
};

async function accepts(target) {
  if (!target || typeof target.user_id !== 'string' || !target.user_id.startsWith('@') ||
      typeof target.room_id !== 'string' || !target.room_id.startsWith('!') ||
      typeof target.event_id !== 'string' || !target.event_id.startsWith('$') ||
      typeof target.registration_id !== 'string' || !target.registration_id) return false;
  const cache = await caches.open(cacheName);
  const saved = await cache.match(accountUrl(target.user_id));
  if (!saved) return false;
  const state = await saved.json();
  return state.enabled && state.registrationId === target.registration_id;
}

function nonEmpty(value) {
  return typeof value === 'string' && value.trim() ? value.trim() : null;
}

function senderName(target) {
  const display = nonEmpty(target.sender_display_name);
  if (display) return display;
  const sender = nonEmpty(target.sender);
  if (!sender) return null;
  const localpart = sender.startsWith('@') ? sender.slice(1).split(':')[0] : sender;
  return localpart || null;
}

function isMessageEvent(target) {
  return target.type === 'm.room.message' || target.type === 'm.sticker';
}

/** The message text alone, with no sender prefix. */
function messageText(target) {
  if (target.type === 'm.room.encrypted') return ENCRYPTED_BODY;
  if (!isMessageEvent(target)) return GENERIC_BODY;
  let content = target.content;
  if (typeof content === 'string') {
    try { content = JSON.parse(content); } catch { content = null; }
  }
  const body = nonEmpty(content && content.body) ?? nonEmpty(target.content_body);
  if (body) return body;
  const msgtype = nonEmpty(content && content.msgtype) ?? nonEmpty(target.content_msgtype);
  return TYPE_HINTS[msgtype] ?? GENERIC_BODY;
}

async function readJson(url, fallback) {
  const cache = await caches.open(cacheName);
  const saved = await cache.match(url);
  if (!saved) return fallback;
  try { return await saved.json(); } catch { return fallback; }
}

async function writeJson(url, value) {
  const cache = await caches.open(cacheName);
  await cache.put(url, new Response(JSON.stringify(value)));
}

/**
 * Build the notification for one push.
 *
 * The gateway carries no direct/group flag, so the page publishes room
 * metadata for the worker to read.
 */
async function buildNotification(target) {
  const rooms = await readJson(roomsUrl(target.user_id), {});
  const room = rooms?.[target.room_id] ?? null;
  const roomName = nonEmpty(room && room.name) ?? nonEmpty(target.room_name);
  const sender = senderName(target);
  const isDirect = (room && room.is_direct) === true;
  const title = roomName ?? sender ?? GENERIC_TITLE;

  // Accumulate the room's messages into one notification. Web notifications
  // have no messaging style, so the conversation is rendered as lines.
  const conversations = await readJson(conversationsUrl(target.user_id), {});
  const existing = conversations?.[target.room_id];
  const entries = Array.isArray(existing?.entries) ? existing.entries : [];
  entries.push({ sender_name: sender ?? '', text: messageText(target), event_id: target.event_id });
  const trimmed = entries.slice(-maxMessagesPerConversation);
  conversations[target.room_id] = { entries: trimmed, latest_event_id: target.event_id };
  await writeJson(conversationsUrl(target.user_id), conversations);

  const lines = trimmed.map((entry) => {
    // A direct chat shows the message alone: the title already names the peer.
    if (isDirect || !entry.sender_name) return entry.text;
    return `${entry.sender_name}：${entry.text}`;
  });

  return {
    title,
    body: lines.join('\n'),
    // Stable per room, so a new message updates the conversation instead of
    // stacking a separate notification.
    tag: `matter:${target.user_id}:${target.room_id}`,
    data: target,
  };
}

self.addEventListener('install', (event) => event.waitUntil(self.skipWaiting()));
self.addEventListener('push', (event) => {
  event.waitUntil((async () => {
    let payload;
    try { payload = event.data?.json(); } catch { return; }
    // Gateways must preserve the Matrix default_payload account routing.
    const target = payload?.notification || payload;
    if (!await accepts(target)) return;
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (windows.some((client) => client.url.startsWith(appBase.href) &&
        client.focused && client.visibilityState === 'visible')) return;
    const built = await buildNotification(target);
    await self.registration.showNotification(built.title, {
      body: built.body,
      icon: new URL('icons/Icon-192.png', appBase).href,
      tag: built.tag,
      renotify: true,
      data: built.data,
    });
  })());
});
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    const target = event.notification.data;
    if (!await accepts(target)) return;
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const client = windows.find((candidate) => candidate.url.startsWith(appBase.href));
    if (client) {
      client.postMessage({ type: 'matter-push-open', target });
      await client.focus();
    } else {
      await self.clients.openWindow(`${appBase.href}?matter_push=${encodeURIComponent(JSON.stringify(target))}`);
    }
  })());
});
