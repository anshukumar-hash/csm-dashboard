#!/usr/bin/env node
// Screenshots the dashboard's Email View (the CS Report card) and emails the PNG
// via Google Workspace SMTP. Self-contained — does NOT touch the protected
// SendGrid digest (generate-digest.mjs / daily-digest.yml).
//
// Env (GitHub Actions secrets, mapped in .github/workflows/email-digest.yml):
//   DIGEST_FROM          — sender + SMTP username (e.g. anshu.kumar@spyne.ai)
//   GMAIL_APP_PASSWORD   — 16-char Google Workspace App Password for that account
//   DIGEST_RECIPIENTS    — "To… | CC…"  (e.g. "reports@spyne.ai | a@x, b@x")
//   SMTP_HOST (optional) — default smtp.gmail.com
//   SMTP_PORT (optional) — default 465
import http from 'http';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { chromium } from 'playwright';
import nodemailer from 'nodemailer';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const TYPES = { '.html':'text/html', '.json':'application/json', '.js':'text/javascript', '.css':'text/css', '.png':'image/png', '.svg':'image/svg+xml' };

const user = process.env.DIGEST_FROM;
const pass = process.env.GMAIL_APP_PASSWORD;
const splitList = (v) => (v || '').split(/[,;]/).map((s) => s.trim()).filter(Boolean);
const [toRaw, ccRaw = ''] = (process.env.DIGEST_RECIPIENTS || '').split('|');
const to = splitList(toRaw);
const cc = splitList(ccRaw).filter((e, i, a) => a.indexOf(e) === i && !to.includes(e));

if (!pass) { console.log('GMAIL_APP_PASSWORD not set — skipping send (no-op).'); process.exit(0); }
if (!user || !to.length) { console.error('Missing DIGEST_FROM or DIGEST_RECIPIENTS To: address.'); process.exit(1); }

// 1) Serve the repo root over http so the dashboard + churn_data.json load.
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

// 2) Render the Email View and screenshot the CS Report card.
const browser = await chromium.launch({ args: ['--no-sandbox'] });
let png;
try {
  const page = await browser.newPage({ viewport: { width: 860, height: 1500 }, deviceScaleFactor: 2 });
  await page.goto(`http://localhost:${port}/index.html`, { waitUntil: 'networkidle', timeout: 60000 });
  await page.click('.top-tab[data-view="email"]');
  await page.waitForSelector('#email-snapshot', { timeout: 30000 });
  await page.waitForTimeout(3500); // let the snapshot render + Arali Signals load
  const el = (await page.$('#email-snapshot > div')) || (await page.$('#email-snapshot'));
  png = await el.screenshot({ type: 'png' });
} finally {
  await browser.close();
  server.close();
}

// 3) Email the screenshot (inline + attached) via Workspace SMTP.
const today = new Date().toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' });
const tx = nodemailer.createTransport({
  host: process.env.SMTP_HOST || 'smtp.gmail.com',
  port: Number(process.env.SMTP_PORT) || 465,
  secure: true,
  auth: { user, pass },
});
const info = await tx.sendMail({
  from: user,
  to,
  cc: cc.length ? cc : undefined,
  subject: `CS Report — ${today}`,
  text: `Customer Success daily report for ${today} is attached as an image.`,
  html: `<p style="font-family:Arial,sans-serif;color:#0F172A">Customer Success daily report — <b>${today}</b>.</p>`
      + `<img src="cid:csreport" alt="CS Report" style="max-width:760px;width:100%;border:1px solid #E2E8F0;border-radius:10px"/>`,
  attachments: [{ filename: `cs-report-${today.replace(/ /g, '-')}.png`, content: png, cid: 'csreport' }],
});
console.log(`Sent CS Report screenshot to ${to.join(', ')}${cc.length ? ' (cc ' + cc.join(', ') + ')' : ''} — id ${info.messageId}`);
process.exit(0);
