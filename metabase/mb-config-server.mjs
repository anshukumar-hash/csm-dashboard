#!/usr/bin/env node
// Tiny LOCAL config form for Metabase credentials. Open the printed localhost
// URL in your browser, paste the API key + card id, Save (or Save & Test).
// It writes .env.local (gitignored — never committed; this repo is public).
// Bound to 127.0.0.1 only, so it is not reachable off this machine.
//
// Run:  node metabase/mb-config-server.mjs      (Ctrl-C to stop)

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const ENV_PATH = path.resolve(here, '..', '.env.local');
const PORT = 8799;

function readEnv() {
  const env = {};
  if (fs.existsSync(ENV_PATH)) {
    for (const line of fs.readFileSync(ENV_PATH, 'utf8').split(/\r?\n/)) {
      if (line.trim().startsWith('#')) continue;
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
      if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  }
  return env;
}
function writeEnv(env) {
  fs.writeFileSync(ENV_PATH, [
    '# Local-only Metabase credentials. GITIGNORED — never commit (this repo is public).',
    '# Saved via the local config form (metabase/mb-config-server.mjs).',
    'METABASE_API_KEY=' + (env.METABASE_API_KEY || ''),
    'METABASE_BASE_URL=' + (env.METABASE_BASE_URL || 'https://metabase.spyne.ai'),
    'METABASE_CARD_ID=' + (env.METABASE_CARD_ID || ''),
    '',
  ].join('\n'));
}
const body = req => new Promise(r => { let d = ''; req.on('data', c => d += c); req.on('end', () => r(d)); });
const mask = k => !k ? '(empty)' : k.slice(0, 4) + '…' + k.slice(-3) + ` (${k.length} chars)`;

const page = () => {
  const e = readEnv();
  return `<!doctype html><html><head><meta charset=utf-8><title>Metabase config</title>
<style>
 body{font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;max-width:560px;margin:40px auto;padding:0 20px;color:#1e293b}
 h1{font-size:19px} label{display:block;margin:16px 0 4px;font-weight:600;font-size:13px}
 input{width:100%;box-sizing:border-box;padding:9px 11px;border:1px solid #cbd5e1;border-radius:7px;font-size:14px}
 .row{display:flex;gap:10px;margin-top:20px} button{flex:1;padding:10px;border:0;border-radius:7px;font-weight:600;cursor:pointer;font-size:14px}
 #save{background:#e2e8f0} #test{background:#2563eb;color:#fff}
 #out{margin-top:18px;padding:12px;border-radius:7px;background:#f8fafc;border:1px solid #e2e8f0;white-space:pre-wrap;font:12px ui-monospace,Menlo,monospace;display:none}
 .hint{color:#64748b;font-size:12px;margin-top:4px} .ok{color:#047857} .err{color:#b91c1c}
 code{background:#f1f5f9;padding:1px 5px;border-radius:4px}
</style></head><body>
<h1>🔑 Metabase credentials (local only)</h1>
<p class=hint>Saves to <code>.env.local</code> — gitignored, never committed. Current key: <b>${mask(e.METABASE_API_KEY)}</b></p>
<label>API Key</label>
<input id=key type=password placeholder="mb_… (Admin → Authentication → API Keys)" value="${(e.METABASE_API_KEY||'').replace(/"/g,'&quot;')}">
<div class=hint><label style="display:inline;font-weight:400"><input type=checkbox id=show style="width:auto" onchange="key.type=this.checked?'text':'password'"> show</label></div>
<label>Base URL</label>
<input id=base value="${e.METABASE_BASE_URL||'https://metabase.spyne.ai'}">
<label>Card ID</label>
<input id=card value="${e.METABASE_CARD_ID||'12755'}" placeholder="12755">
<div class=row><button id=save onclick="go(false)">Save</button><button id=test onclick="go(true)">Save &amp; Test</button></div>
<div id=out></div>
<script>
async function go(test){
  var out=document.getElementById('out'); out.style.display='block'; out.textContent='Working…'; out.className='';
  var payload={METABASE_API_KEY:key.value.trim(),METABASE_BASE_URL:base.value.trim(),METABASE_CARD_ID:card.value.trim(),test:test};
  try{
    var r=await fetch('/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
    var j=await r.json();
    if(j.saved && !test){ out.className='ok'; out.textContent='✓ Saved to .env.local. Now tell Claude to run the query.'; return; }
    if(j.query){
      if(j.query.ok){ out.className='ok'; out.textContent='✓ Saved. Card '+payload.METABASE_CARD_ID+' returned '+j.query.rows+' rows.\\nColumns: '+j.query.cols.join(', ')+'\\n\\nTell Claude to run the query for full data.'; }
      else { out.className='err'; out.textContent='Saved, but test query failed:\\nHTTP '+j.query.status+' — '+j.query.error; }
    }
  }catch(err){ out.className='err'; out.textContent='Error: '+err.message; }
}
</script></body></html>`;
};

http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(page());
  }
  if (req.method === 'POST' && req.url === '/save') {
    let d; try { d = JSON.parse(await body(req)); } catch { d = {}; }
    writeEnv(d);
    let query = null;
    if (d.test) {
      const base = (d.METABASE_BASE_URL || 'https://metabase.spyne.ai').replace(/\/+$/, '');
      const id = String(d.METABASE_CARD_ID || '').replace(/\D/g, '');
      try {
        const r = await fetch(`${base}/api/card/${id}/query/json`, {
          method: 'POST', headers: { 'x-api-key': d.METABASE_API_KEY || '', 'Content-Type': 'application/json' }, body: '{}',
        });
        if (r.ok) { const rows = await r.json(); query = { ok: true, rows: Array.isArray(rows) ? rows.length : 0, cols: Array.isArray(rows) && rows.length ? Object.keys(rows[0]) : [] }; }
        else { query = { ok: false, status: r.status, error: (await r.text().catch(() => '')).slice(0, 200) }; }
      } catch (e) { query = { ok: false, status: 0, error: e.message }; }
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ saved: true, query }));
  }
  res.writeHead(404); res.end('not found');
}).listen(PORT, '127.0.0.1', () => {
  console.log(`Metabase config form → http://localhost:${PORT}`);
});
