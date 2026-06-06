// chatwoot-dify-relay
// Forwards Chatwoot conversation_status_changed webhooks to Evolution
// /dify/changeStatus/{instance} so Dify session is reset on resolve and
// paused on reopen.
//
// No external dependencies. Uses Node 20+ built-ins (http, fetch).

import http from 'node:http';

const cfg = {
  port: parseInt(process.env.PORT || '8085', 10),
  evolutionBaseUrl: (process.env.EVOLUTION_BASE_URL || '').replace(/\/+$/, ''),
  evolutionInstance: process.env.EVOLUTION_INSTANCE || '',
  evolutionApiKey: process.env.EVOLUTION_APIKEY || '',
  hookSecret: process.env.CHATWOOT_HOOK_SECRET || '',
  // Optional: comma-separated list of Chatwoot inbox ids to act on. Empty = all.
  inboxAllowList: (process.env.CHATWOOT_INBOX_IDS || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
};

function log(level, msg, extra) {
  const rec = { ts: new Date().toISOString(), level, msg, ...(extra || {}) };
  console.log(JSON.stringify(rec));
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', (c) => {
      total += c.length;
      if (total > 1024 * 1024) {
        reject(new Error('payload too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (e) {
        reject(e);
      }
    });
    req.on('error', reject);
  });
}

function checkAuth(req, url) {
  if (!cfg.hookSecret) return true; // no secret configured -> open
  const headerToken = req.headers['x-hook-token'];
  const queryToken = url.searchParams.get('t');
  return headerToken === cfg.hookSecret || queryToken === cfg.hookSecret;
}

// Normalise an arbitrary phone number string to a JID.
// Accepts forms like "+62 812-3067-2529" or "6281230672529".
function phoneToJid(raw) {
  if (!raw) return null;
  const digits = String(raw).replace(/\D/g, '');
  if (!digits) return null;
  return `${digits}@s.whatsapp.net`;
}

// Try to extract a phone number from a Chatwoot webhook payload.
// Chatwoot sends slightly different shapes for different events; we look
// at the most likely places.
function extractPhone(payload) {
  if (!payload || typeof payload !== 'object') return null;
  const candidates = [
    payload?.meta?.sender?.phone_number,
    payload?.meta?.sender?.identifier,
    payload?.contact?.phone_number,
    payload?.contact?.identifier,
    payload?.sender?.phone_number,
    payload?.sender?.identifier,
    payload?.additional_attributes?.phone_number,
    payload?.contact_inbox?.source_id,
  ];
  for (const c of candidates) {
    if (c && typeof c === 'string') return c;
  }
  return null;
}

// From the webhook payload, decide what status we should send to Evolution
// (or null if we should ignore the event).
function decideAction(payload) {
  const event = payload?.event;
  if (event !== 'conversation_status_changed') return { skip: 'event_not_status_change' };

  const status = payload?.status;
  // Chatwoot uses these values: open, resolved, pending, snoozed.
  if (status === 'resolved') return { evolutionStatus: 'closed' };
  if (status === 'open') return { evolutionStatus: 'paused' };
  return { skip: `unhandled_status_${status}` };
}

function inboxAllowed(payload) {
  if (cfg.inboxAllowList.length === 0) return true;
  const inboxId = String(payload?.inbox_id ?? payload?.conversation?.inbox_id ?? '');
  return cfg.inboxAllowList.includes(inboxId);
}

async function callEvolutionChangeStatus(jid, status) {
  const url = `${cfg.evolutionBaseUrl}/dify/changeStatus/${encodeURIComponent(cfg.evolutionInstance)}`;
  const body = JSON.stringify({ remoteJid: jid, status });
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      apikey: cfg.evolutionApiKey,
    },
    body,
  });
  const text = await res.text();
  return { ok: res.ok, statusCode: res.status, body: text };
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  if (req.method === 'GET' && url.pathname === '/healthz') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, service: 'chatwoot-dify-relay' }));
    return;
  }

  if (req.method !== 'POST' || url.pathname !== '/chatwoot-hook') {
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: false, error: 'not_found' }));
    return;
  }

  if (!checkAuth(req, url)) {
    log('warn', 'auth_failed', { ip: req.socket.remoteAddress });
    res.writeHead(401, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: false, error: 'unauthorized' }));
    return;
  }

  let payload;
  try {
    payload = await readJsonBody(req);
  } catch (e) {
    log('warn', 'bad_json', { err: String(e) });
    res.writeHead(400, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: false, error: 'bad_json' }));
    return;
  }

  const action = decideAction(payload);
  if (action.skip) {
    log('info', 'skip', { reason: action.skip, event: payload?.event, status: payload?.status });
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, skipped: action.skip }));
    return;
  }

  if (!inboxAllowed(payload)) {
    log('info', 'skip_inbox', { inbox_id: payload?.inbox_id });
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, skipped: 'inbox_not_allowed' }));
    return;
  }

  const phone = extractPhone(payload);
  const jid = phoneToJid(phone);
  if (!jid) {
    log('warn', 'no_phone', { conversation_id: payload?.id });
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, skipped: 'no_phone' }));
    return;
  }

  try {
    const result = await callEvolutionChangeStatus(jid, action.evolutionStatus);
    log(result.ok ? 'info' : 'error', 'evolution_call', {
      jid,
      chatwoot_status: payload?.status,
      evolution_status: action.evolutionStatus,
      http: result.statusCode,
      body: result.body?.slice(0, 300),
    });
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(
      JSON.stringify({
        ok: true,
        jid,
        evolution_status: action.evolutionStatus,
        evolution_http: result.statusCode,
      }),
    );
  } catch (e) {
    log('error', 'evolution_error', { err: String(e) });
    res.writeHead(502, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: false, error: 'evolution_call_failed' }));
  }
});

function validateConfig() {
  const missing = [];
  if (!cfg.evolutionBaseUrl) missing.push('EVOLUTION_BASE_URL');
  if (!cfg.evolutionInstance) missing.push('EVOLUTION_INSTANCE');
  if (!cfg.evolutionApiKey) missing.push('EVOLUTION_APIKEY');
  if (missing.length) {
    log('error', 'missing_env', { missing });
    process.exit(1);
  }
}

validateConfig();
server.listen(cfg.port, () => {
  log('info', 'listening', {
    port: cfg.port,
    base: cfg.evolutionBaseUrl,
    instance: cfg.evolutionInstance,
    auth_enabled: Boolean(cfg.hookSecret),
    inbox_allow_list: cfg.inboxAllowList,
  });
});
