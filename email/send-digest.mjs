#!/usr/bin/env node
// Sends email/daily-digest.html via the SendGrid v3 API.
// Required env (GitHub Actions secrets):
//   SENDGRID_API_KEY   — SendGrid API key with "Mail Send" permission
//   DIGEST_FROM        — verified sender address (e.g. anshu.kumar@spyne.ai)
//   DIGEST_RECIPIENTS  — To: addresses, with an OPTIONAL " | " separating CC:
//                        addresses, e.g.
//                          reports@spyne.ai | saurabh.shah@spyne.ai, rupesh.rawat@spyne.ai
//                        (the "| CC" form avoids needing a separate workflow env
//                         var; addresses within each side are comma/semicolon-sep)
//   DIGEST_CC          — optional extra CC: addresses (merged with the above)
import fs from 'fs';

const html = fs.readFileSync(new URL('./daily-digest.html', import.meta.url), 'utf8');
const key = process.env.SENDGRID_API_KEY;
const from = process.env.DIGEST_FROM;
const splitList = (v) => (v || '').split(/[,;]/).map((s) => s.trim()).filter(Boolean);
// DIGEST_RECIPIENTS = "To… | CC…"; everything after the first '|' is CC.
const [toRaw, ccRaw = ''] = (process.env.DIGEST_RECIPIENTS || '').split('|');
const recipients = splitList(toRaw);
// CC = the "| CC" part + any DIGEST_CC, de-duped and never overlapping To:
// (SendGrid rejects an address that appears in both).
const cc = [...splitList(ccRaw), ...splitList(process.env.DIGEST_CC)]
  .filter((e, i, a) => a.indexOf(e) === i && !recipients.includes(e));

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
