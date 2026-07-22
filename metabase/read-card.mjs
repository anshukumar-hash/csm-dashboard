#!/usr/bin/env node
// Ad-hoc Metabase reader — query ANY card by id (or a Metabase question URL)
// using a personal API KEY held in .env.local. This is a LOCAL developer tool;
// it is NOT part of the deployed dashboard or any workflow, and the key must
// never be committed (this repo is public — .env.local is gitignored).
//
// .env.local (repo root):
//   METABASE_API_KEY=mb_...        (required) Metabase → Admin → API Keys
//   METABASE_BASE_URL=https://metabase.spyne.ai
//   METABASE_CARD_ID=12755         (optional default when no arg is passed)
//
// Usage:
//   node metabase/read-card.mjs                          # uses METABASE_CARD_ID
//   node metabase/read-card.mjs 12755                    # explicit card id
//   node metabase/read-card.mjs https://metabase.spyne.ai/question/12755-slug
//   node metabase/read-card.mjs 12755 --limit 25         # preview N rows (default 10)
//   node metabase/read-card.mjs 12755 --json out.json    # write ALL rows to a file

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// ---- load .env.local from repo root ----
const here = path.dirname(fileURLToPath(import.meta.url));
const envPath = path.resolve(here, '..', '.env.local');
const env = {};
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (m && !line.trim().startsWith('#')) env[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
}
const get = k => process.env[k] || env[k] || '';
const KEY  = get('METABASE_API_KEY');
const BASE = (get('METABASE_BASE_URL') || 'https://metabase.spyne.ai').replace(/\/+$/, '');
if (!KEY) { console.error('ERROR: METABASE_API_KEY not set in .env.local'); process.exit(1); }

// ---- parse args: [cardIdOrUrl] [--limit N] [--json file] ----
const argv = process.argv.slice(2);
const flags = { limit: 10, json: null };
const positional = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--limit') flags.limit = Number(argv[++i]) || 10;
  else if (argv[i] === '--json') flags.json = argv[++i];
  else positional.push(argv[i]);
}
const cardArg = positional[0] || get('METABASE_CARD_ID');
const urlM = String(cardArg).match(/\/(?:question|card)\/(\d+)/);
const cardId = urlM ? urlM[1] : String(cardArg).replace(/\D/g, '');
if (!cardId) {
  console.error('ERROR: no card id — pass one, a /question/<id> URL, or set METABASE_CARD_ID.');
  process.exit(1);
}

// ---- query the card (API-key auth via x-api-key header) ----
console.error(`Querying ${BASE}/api/card/${cardId} …`);
const res = await fetch(`${BASE}/api/card/${cardId}/query/json`, {
  method: 'POST',
  headers: { 'x-api-key': KEY, 'Content-Type': 'application/json' },
  body: '{}',
});
if (!res.ok) {
  const body = await res.text().catch(() => '');
  console.error(`ERROR: ${res.status} ${res.statusText} — ${body.slice(0, 400)}`);
  if (res.status === 401 || res.status === 403) {
    console.error('Hint: check METABASE_API_KEY, and that its group can view this card.');
  }
  process.exit(1);
}
const rows = await res.json();
if (!Array.isArray(rows)) {
  console.error('Unexpected (non-array) response:', JSON.stringify(rows).slice(0, 400));
  process.exit(1);
}
console.error(`✓ card ${cardId}: ${rows.length} rows` +
  (rows.length ? ` | columns: ${Object.keys(rows[0]).join(', ')}` : ''));
if (flags.json) { fs.writeFileSync(flags.json, JSON.stringify(rows)); console.error(`wrote ${flags.json} (${rows.length} rows)`); }
console.log(JSON.stringify(rows.slice(0, flags.limit), null, 2));
