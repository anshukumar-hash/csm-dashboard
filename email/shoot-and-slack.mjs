#!/usr/bin/env node
// Screenshots the dashboard's Email View (CS Report card) and posts the PNG to a
// Slack channel via the Slack Web API (files upload v2 flow — getUploadURLExternal
// → upload → completeUploadExternal). Self-contained; does not touch the
// protected SendGrid digest.
//
// Env (GitHub Actions secrets, mapped in .github/workflows/slack-digest.yml):
//   SLACK_BOT_TOKEN   — Slack bot token (xoxb-…) with scopes files:write + chat:write
//   SLACK_CHANNEL     — target channel ID (e.g. C0123ABCD). Bot must be in the channel.
//   SLACK_COMMENT     — optional message text above the image
import http from 'http';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { chromium } from 'playwright';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const TYPES = { '.html':'text/html', '.json':'application/json', '.js':'text/javascript', '.css':'text/css', '.png':'image/png', '.svg':'image/svg+xml' };

const token = process.env.SLACK_BOT_TOKEN;
const channel = process.env.SLACK_CHANNEL;
if (!token || !channel) { console.log('SLACK_BOT_TOKEN / SLACK_CHANNEL not set — skipping (no-op).'); process.exit(0); }

// 1) Serve the repo root so the dashboard + churn_data.json load over http.
const server = http.createServer((req, res) => {
  let p = decodeURIComponent((req.url || '/').split('?')[0]);
  if (p === '/') p = '/index.html';
  const f = path.join(ROOT, p);
  if (!f.startsWith(ROOT) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); res.end('not found'); return; }
  res.writeHead(200, { 'Content-Type': TYPES[path.extname(f)] || 'application/octet-stream' });
  fs.createReadStream(f).pipe(res);
});
await new Promise((r) => server.listen(0, r));
const port = server.address().port;

// 2) Screenshot the CS Report card.
const browser = await chromium.launch({ args: ['--no-sandbox'] });
let png;
try {
  const page = await browser.newPage({ viewport: { width: 860, height: 1500 }, deviceScaleFactor: 2 });
  await page.goto(`http://localhost:${port}/index.html`, { waitUntil: 'networkidle', timeout: 60000 });
  // Email View is now nested under the "Views" tab group — open the group first,
  // then pick the Email sub-tab. Falls back to the old top-level tab if present.
  if (await page.$('.top-tab[data-view="viewgroup"]')) {
    await page.click('.top-tab[data-view="viewgroup"]');
    await page.waitForTimeout(400);
    await page.click('.view-subtab[data-view="email"]');
  } else {
    await page.click('.top-tab[data-view="email"]');
  }
  await page.waitForSelector('#email-snapshot', { timeout: 30000 });
  await page.waitForTimeout(3500);
  const el = (await page.$('#email-snapshot > div')) || (await page.$('#email-snapshot'));
  png = await el.screenshot({ type: 'png' });
} finally {
  await browser.close();
  server.close();
}

// 3) Upload to Slack (files upload v2 flow).
const today = new Date().toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' });
const filename = `cs-report-${today.replace(/ /g, '-')}.png`;
const comment = process.env.SLACK_COMMENT || `:bar_chart: *CS Report — ${today}*`;

// 3a — reserve an upload URL
const r1 = await fetch('https://slack.com/api/files.getUploadURLExternal', {
  method: 'POST',
  headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({ filename, length: String(png.length) }),
});
const j1 = await r1.json();
if (!j1.ok) throw new Error('getUploadURLExternal failed: ' + j1.error);

// 3b — PUT the bytes to the reserved URL
const fd = new FormData();
fd.append('file', new Blob([png], { type: 'image/png' }), filename);
const r2 = await fetch(j1.upload_url, { method: 'POST', body: fd });
if (!r2.ok) throw new Error('file upload POST failed: HTTP ' + r2.status);

// 3c — complete + share to the channel
const r3 = await fetch('https://slack.com/api/files.completeUploadExternal', {
  method: 'POST',
  headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json; charset=utf-8' },
  body: JSON.stringify({
    files: [{ id: j1.file_id, title: `CS Report — ${today}` }],
    channel_id: channel,
    initial_comment: comment,
  }),
});
const j3 = await r3.json();
if (!j3.ok) throw new Error('completeUploadExternal failed: ' + j3.error);
console.log(`Posted CS Report screenshot to Slack channel ${channel}.`);
process.exit(0);
