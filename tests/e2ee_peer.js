#!/usr/bin/env node
// tests/e2ee_peer.js: the other side of tests/e2ee.sh's encrypted conversation, played by TX.WTF's
// own web client crypto (txwtf/static/js/e2ee.js and messaging-e2ee.js, as the page loads them)
// against an instance's REST API: the stub here, or a real txwtf.
//
//   node tests/e2ee_peer.js --base URL --token-file FILE --js DIR --state FILE send CONV PEER TEXT
//   node tests/e2ee_peer.js --base URL --token-file FILE --js DIR --state FILE recv CONV
//
//   send  publishes this account's keys the first time (POST /e2ee/keys), seals TEXT for user id
//         PEER (fetching its bundle from GET /e2ee/keys/{username} for a new session) and POSTs
//         it to /e2ee/dm/conversations/CONV/messages
//   recv  lists the conversation (GET .../messages) and opens what it can, oldest first, one line
//         each: "<id> <sender id> <status> <text>"
//
// The account's keys and sessions live in --state (messaging-e2ee.js's key-store layout), so a
// later run carries on the session. The token is read from a file, never from the command line.
// Needs node 18+ (fetch) and libsodium-wrappers-sumo 0.7.15 where node finds it (NODE_PATH).
'use strict';

const fs = require('fs');
const path = require('path');

function args() {
  const a = process.argv.slice(2);
  const o = { rest: [] };
  while (a.length) {
    const k = a.shift();
    if (k.startsWith('--')) o[k.slice(2)] = a.shift();
    else o.rest.push(k);
  }
  for (const k of ['base', 'token-file', 'js', 'state'])
    if (!o[k]) throw new Error(`--${k} is needed`);
  return o;
}

async function main() {
  const o = args();
  const sodium = require('libsodium-wrappers-sumo');
  await sodium.ready;
  const lib = require(path.resolve(o.js, 'e2ee.js'));
  const { TxwtfMessagingE2EE } = require(path.resolve(o.js, 'messaging-e2ee.js'));
  const token = fs.readFileSync(o['token-file'], 'utf8').trim();
  const base = o.base.replace(/\/+$/, '');
  const call = async (method, p, body) => {
    const r = await fetch(base + p, {
      method,
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/json',
                 ...(body ? { 'Content-Type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await r.text();
    if (!r.ok) throw new Error(`${method} ${p}: HTTP ${r.status} ${text}`);
    return text ? JSON.parse(text) : null;
  };
  const api = {
    publishE2EEKeys: (p) => call('POST', '/e2ee/keys', p),
    getPreKeyBundle: (u) => call('GET', `/e2ee/keys/${encodeURIComponent(u)}`),
    sendEncryptedMessage: (c, b) => call('POST', `/e2ee/dm/conversations/${c}/messages`, b),
  };

  const store = new lib.TxwtfE2EEMemoryStore();
  if (fs.existsSync(o.state))
    for (const [k, v] of Object.entries(JSON.parse(fs.readFileSync(o.state, 'utf8'))))
      await store.set(k, v);
  const save = async () => {
    const out = {};
    for (const k of await store.keys()) out[k] = await store.get(k);
    fs.writeFileSync(o.state, JSON.stringify(out), { mode: 0o600 });
  };
  const me = new TxwtfMessagingE2EE({ e2ee: new lib.TxwtfE2EE(sodium), api, store });
  await me.ensureIdentity(5);

  const [cmd, conv, ...more] = o.rest;
  if (cmd === 'send') {
    const [peerId, text] = more;
    const profile = await call('GET', `/user/profile/${peerId}`);
    const r = await me.encryptAndSend(Number(conv), { userId: Number(peerId), username: profile.username }, text);
    console.log(`sent ${r.id}`);
  } else if (cmd === 'recv') {
    const list = await call('GET', `/e2ee/dm/conversations/${conv}/messages`);
    for (const m of list.messages.slice().reverse()) {
      try {
        const p = await me.decryptIncoming(Number(conv), m);
        console.log(`${m.id} ${m.sender_id} ${p ? 'ok' : 'none'} ${p ? p.text : ''}`);
      } catch (e) {
        console.log(`${m.id} ${m.sender_id} failed ${e.message}`);
      }
    }
  } else {
    throw new Error('send CONV PEER TEXT, or recv CONV');
  }
  await save();
}

main().catch((e) => {
  console.error(`e2ee_peer: ${e.message}`);
  process.exit(1);
});
