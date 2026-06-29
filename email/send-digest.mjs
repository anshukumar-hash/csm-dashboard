#!/usr/bin/env node
// Sends email/daily-digest.html via the SendGrid v3 API.
// Required env (GitHub Actions secrets):
//   SENDGRID_API_KEY   — SendGrid API key with "Mail Send" permission
//   DIGEST_FROM        — verified sender address (e.g. anshu.kumar@spyne.ai)
//   DIGEST_RECIPIENTS  — comma-separated To: addresses (e.g. reports@spyne.ai)
//   DIGEST_CC          — optional comma-separated CC: addresses
import fs from 'fs';

const html = fs.readFileSync(new URL('./daily-digest.html', import.meta.url), 'utf8');
const key = process.env.SENDGRID_API_KEY;
const from = process.env.DIGEST_FROM;
const splitList = (v) => (v || '').split(',').map((s) => s.trim()).filter(Boolean);
const recipients = splitList(process.env.DIGEST_RECIPIENTS);
// CC, de-duped against the To: list (SendGrid rejects an address in both).
const cc = splitList(process.env.DIGEST_CC).filter((e) => !recipients.includes(e));

if (!key || !from || !recipients.length) {
  console.error('Missing one of SENDGRID_API_KEY / DIGEST_FROM / DIGEST_RECIPIENTS');
  process.exit(1);
}

const today = new Date().toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
const personalization = { to: recipients.map((email) => ({ email })) };
if (cc.length) personalization.cc = cc.map((email) => ({ email }));
const payload = {
  personalizations: [personalization],
  from: { email: from, name: 'Spyne CSM Digest' },
  subject: `Spyne CSM Daily Digest — ${today}`,
  content: [{ type: 'text/html', value: html }],
};

const res = await fetch('https://api.sendgrid.com/v3/mail/send', {
  method: 'POST',
  headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
  body: JSON.stringify(payload),
});

if (res.status >= 200 && res.status < 300) {
  console.log(`Digest sent to ${recipients.length} recipient(s)` + (cc.length ? ` + ${cc.length} CC.` : '.'));
} else {
  console.error(`SendGrid error ${res.status}:`, await res.text());
  process.exit(1);
}
