#!/usr/bin/env node
// ============================================================
// Daily CSM Digest — generator
// ------------------------------------------------------------
// Loads the REAL dashboard (index.html) in headless Chrome, lets its own
// JavaScript compute every RAG bucket (Usage / Final / Payment / Tickets /
// Communication), then scrapes the already-rendered CSM-level and
// Enterprise-level tables + the KPI scorecards for both Studio and Vini.
//
// We deliberately do NOT re-implement any RAG logic here: only Payment RAG is
// stored in the snapshot; the other four buckets are derived in-browser from
// the active period filter. Driving the page is the only way to stay byte-for-
// byte faithful to what a human sees on the dashboard.
//
// Output: writes email/daily-digest.html (the email body, inline-styled,
// email-client safe). The workflow then POSTs that body to SendGrid.
// ============================================================
import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(__dirname, '..');
const INDEX = 'file://' + path.join(REPO, 'index.html');
const OUT = path.join(__dirname, 'daily-digest.html');

// ---- in-page scrapers (run inside the dashboard's own context) -------------
const SCRAPE_TABLE = (sel) => {
  const table = document.querySelector(sel);
  if (!table) return [];
  const badgeMap = (td) => {
    if (!td) return null;
    const out = {};
    td.querySelectorAll('.badge').forEach((b) => {
      const k = b.classList.contains('g') ? 'G'
        : b.classList.contains('a') ? 'A'
        : b.classList.contains('o') ? 'O'
        : b.classList.contains('r') ? 'R' : 'NA';
      const t = (b.textContent || '').trim();
      const n = /^\d+$/.test(t) ? parseInt(t, 10) : 1;
      out[k] = (out[k] || 0) + n;
    });
    return Object.keys(out).length ? out : null;
  };
  const lastCell = (tr, cls) => {
    const els = tr.querySelectorAll('td.' + cls);
    return els.length ? els[els.length - 1] : null;
  };
  const rows = [];
  table.querySelectorAll('tbody tr').forEach((tr) => {
    if (tr.classList.contains('total-row')) return;
    const tds = Array.from(tr.querySelectorAll('td'));
    if (!tds.length) return;
    const drill = tr.querySelector('.drill, a');
    let name = drill ? drill.textContent.trim() : (tds[1] ? tds[1].textContent.trim() : tds[0].textContent.trim());
    const isBucket = (c) => /cell-(final|usage|quality|roi|rs|payment|tickets|comm|leader)/.test(c);
    const idCells = tds.filter((td) => !isBucket(td.className));
    let arr = '';
    idCells.forEach((td) => { const t = td.textContent.trim(); if (/^\$/.test(t)) arr = t; });
    const rfEl = tr.querySelector('td.frozen-3');
    const rooftops = rfEl ? rfEl.textContent.trim() : '';
    const usageEl = lastCell(tr, 'cell-usage');
    // Usage Factor cell can carry extra text; keep only the % token.
    const usageTxt = usageEl ? usageEl.textContent.trim() : '';
    const usagePct = (usageTxt.match(/[\d.]+%/g) || []).pop();
    rows.push({
      name,
      arr,
      rooftops,
      usage: usagePct || (usageTxt && !/\d{4,}/.test(usageTxt) ? usageTxt : ''),
      final: badgeMap(lastCell(tr, 'cell-final')),
      payment: badgeMap(lastCell(tr, 'cell-payment')),
      tickets: badgeMap(lastCell(tr, 'cell-tickets')),
      comm: badgeMap(lastCell(tr, 'cell-comm')),
    });
  });
  return rows;
};

const SCRAPE_KPI = (sel) =>
  Array.from(document.querySelectorAll(sel + ' .kpi')).map((k) => ({
    label: (k.querySelector('.kpi-label') || {}).textContent?.trim() || '',
    value: (k.querySelector('.kpi-value') || {}).textContent?.trim() || '',
    sub: (k.querySelector('.kpi-sub') || {}).textContent?.trim() || '',
  }));

async function setView(page, product, view) {
  await page.click(`.top-tab[data-product="${product}"]`);
  await page.waitForTimeout(400);
  await page.click(`.sub-tab[data-view="${view}"]`);
  await page.waitForTimeout(1200);
}

async function main() {
  // Locally we reuse the installed Google Chrome (PW_CHANNEL=chrome); in CI we
  // let Playwright use its own bundled Chromium (no channel set).
  const channel = process.env.PW_CHANNEL;
  const browser = await chromium.launch({ headless: true, ...(channel ? { channel } : {}) });
  const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
  await page.goto(INDEX, { waitUntil: 'networkidle', timeout: 60000 });
  await page.waitForSelector('#csm-table-wrap table', { timeout: 30000 });

  // STUDIO ----------------------------------------------------------------
  await setView(page, 'studio', 'overview');
  const studioKpi = await page.evaluate(SCRAPE_KPI, '#kpi-strip');
  const studioCsm = await page.evaluate(SCRAPE_TABLE, '#csm-table-wrap table');
  await setView(page, 'studio', 'rooftop');
  const studioEnt = await page.evaluate(SCRAPE_TABLE, '#enterprise-list-wrap table');

  // VINI ------------------------------------------------------------------
  await setView(page, 'vini', 'overview');
  const viniKpi = await page.evaluate(SCRAPE_KPI, '#kpi-strip');
  const viniCsm = await page.evaluate(SCRAPE_TABLE, '#csm-table-wrap table');
  await setView(page, 'vini', 'rooftop');
  const viniEnt = await page.evaluate(SCRAPE_TABLE, '#enterprise-list-wrap table');

  await browser.close();

  const html = renderEmail({ studioKpi, studioCsm, studioEnt, viniKpi, viniCsm, viniEnt });
  fs.writeFileSync(OUT, html);
  console.log(`Wrote ${OUT}`);
  console.log(`  studio: ${studioCsm.length} CSMs · ${studioEnt.length} enterprises`);
  console.log(`  vini:   ${viniCsm.length} CSMs · ${viniEnt.length} enterprises`);
}

// ---- email rendering -------------------------------------------------------
const COL = { G: '#16A34A', A: '#D97706', R: '#DC2626', O: '#EA580C', NA: '#64748B' };
const BG = { G: '#DCFCE7', A: '#FEF3C7', R: '#FEE2E2', O: '#FFEDD5', NA: '#F1F5F9' };

function pill(c) {
  if (!c) return '<span style="color:#94A3B8">—</span>';
  const order = ['R', 'O', 'A', 'G', 'NA'];
  const dom = order.find((k) => c[k]);
  if (!dom) return '<span style="color:#94A3B8">—</span>';
  const txt = { G: 'Green', A: 'Amber', R: 'Red', O: 'Orange', NA: 'NA' }[dom];
  return `<span style="display:inline-block;font:700 10px Arial;color:${COL[dom]};background:${BG[dom]};border-radius:4px;padding:3px 7px">${txt}</span>`;
}
function counts(c) {
  if (!c) return '';
  return ['G', 'A', 'O', 'R'].filter((k) => c[k]).map((k) =>
    `<span style="font:600 9px Arial;color:${COL[k]};margin-right:3px">${k}${c[k]}</span>`).join('');
}
function ragCell(c) {
  return `<td style="padding:7px 8px;border-bottom:1px solid #EEF2F6;text-align:center">${pill(c)}<div style="margin-top:2px">${counts(c)}</div></td>`;
}
function usageCell(v) {
  const num = parseFloat((v || '').replace('%', ''));
  let col = '#475569';
  if (!isNaN(num)) col = num >= 70 ? COL.G : num >= 30 ? COL.A : COL.R;
  return `<td style="padding:7px 8px;border-bottom:1px solid #EEF2F6;text-align:center;font:600 11px Arial;color:${col}">${v || '—'}</td>`;
}
const esc = (s) => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function tableBlock(title, rows, showRooftops) {
  const head = `<tr style="background:#F8FAFC">
    <th style="padding:8px;text-align:left;font:600 10px Arial;color:#64748B;border-bottom:1px solid #E2E8F0">Name</th>
    ${showRooftops ? '<th style="padding:8px;text-align:center;font:600 10px Arial;color:#64748B;border-bottom:1px solid #E2E8F0">Rftps</th>' : ''}
    <th style="padding:8px;text-align:right;font:600 10px Arial;color:#64748B;border-bottom:1px solid #E2E8F0">ARR</th>
    <th style="padding:8px;text-align:center;font:600 10px Arial;color:#64748B;border-bottom:1px solid #E2E8F0">Usage</th>
    <th style="padding:8px;text-align:center;font:600 10px Arial;color:#64748B;border-bottom:1px solid #E2E8F0">Final</th>
    <th style="padding:8px;text-align:center;font:600 10px Arial;color:#64748B;border-bottom:1px solid #E2E8F0">Payment</th>
    <th style="padding:8px;text-align:center;font:600 10px Arial;color:#64748B;border-bottom:1px solid #E2E8F0">Tickets</th>
    <th style="padding:8px;text-align:center;font:600 10px Arial;color:#64748B;border-bottom:1px solid #E2E8F0">Comm</th>
  </tr>`;
  const body = rows.map((r) => `<tr>
    <td style="padding:7px 8px;border-bottom:1px solid #EEF2F6;font:600 11px Arial;color:#0F172A">${esc(r.name).replace('@spyne.ai', '')}</td>
    ${showRooftops ? `<td style="padding:7px 8px;border-bottom:1px solid #EEF2F6;text-align:center;font:400 11px Arial;color:#475569">${esc(r.rooftops)}</td>` : ''}
    <td style="padding:7px 8px;border-bottom:1px solid #EEF2F6;text-align:right;font:600 11px Arial;color:#0F172A">${esc(r.arr) || '—'}</td>
    ${usageCell(r.usage)}
    ${ragCell(r.final)}${ragCell(r.payment)}${ragCell(r.tickets)}${ragCell(r.comm)}
  </tr>`).join('');
  return `<tr><td style="padding:18px 24px 6px"><div style="font:700 12px Arial;color:#0F172A">${title} <span style="font-weight:400;color:#94A3B8">· ${rows.length} rows</span></div></td></tr>
  <tr><td style="padding:0 24px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border:1px solid #E2E8F0;border-radius:8px">${head}${body}</table></td></tr>`;
}

function kpiBlock(title, kpis) {
  const tile = (k) => `<td style="width:160px;padding:9px;background:#fff;border:1px solid #E2E8F0;border-radius:8px;vertical-align:top">
    <div style="font:500 10px Arial;color:#64748B;margin-bottom:5px;min-height:24px">${esc(k.label)}</div>
    <div style="font:700 16px Arial;color:#0F172A;line-height:1.1">${esc(k.value)}</div>
    <div style="font:400 10px Arial;color:#94A3B8;margin-top:4px">${esc(k.sub)}</div></td>`;
  // chunk into rows of 4 tiles
  let cells = '';
  kpis.forEach((k, i) => {
    cells += tile(k);
    if (i % 4 === 3) cells += '</tr><tr>';
    else cells += '<td style="width:8px"></td>';
  });
  return `<tr><td style="padding:18px 24px 4px"><div style="font:700 13px Arial;color:#0F172A;letter-spacing:.02em">${title}</div></td></tr>
  <tr><td style="padding:6px 24px"><table role="presentation" cellpadding="0" cellspacing="0"><tr>${cells}</tr></table></td></tr>`;
}

function renderEmail(d) {
  const today = new Date().toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"></head>
<body style="margin:0;background:#F1F5F9;padding:18px 0">
<table role="presentation" width="760" align="center" cellpadding="0" cellspacing="0" style="margin:0 auto;background:#F8FAFC;border-radius:12px;overflow:hidden;border:1px solid #E2E8F0">
  <tr><td style="background:#0F172A;padding:20px 24px">
    <div style="font:700 18px Arial;color:#fff">Spyne CSM · Daily Digest</div>
    <div style="font:400 12px Arial;color:#94A3B8;margin-top:4px">${today} · Studio + Vini · All Regions / All Segments</div>
  </td></tr>

  <tr><td style="padding:8px 24px 0"><div style="font:700 14px Arial;color:#1D4ED8;border-bottom:2px solid #DBEAFE;padding-bottom:6px">STUDIO</div></td></tr>
  ${kpiBlock('Scorecards', d.studioKpi)}
  ${tableBlock('CSM-Level Overview', d.studioCsm, true)}
  ${tableBlock('Enterprise-Level Overview', d.studioEnt, false)}

  <tr><td style="padding:24px 24px 0"><div style="font:700 14px Arial;color:#7C3AED;border-bottom:2px solid #EDE9FE;padding-bottom:6px">VINI</div></td></tr>
  ${kpiBlock('Scorecards', d.viniKpi)}
  ${tableBlock('CSM-Level Overview', d.viniCsm, true)}
  ${tableBlock('Enterprise-Level Overview', d.viniEnt, false)}

  <tr><td style="padding:20px 24px 24px">
    <a href="https://csm-dashboard-navy.vercel.app" style="display:inline-block;background:#2563EB;color:#fff;font:600 12px Arial;text-decoration:none;padding:10px 18px;border-radius:8px">Open full dashboard →</a>
    <div style="font:400 11px Arial;color:#94A3B8;margin-top:14px">Auto-generated from the CSM dashboard snapshot · refreshes every 15 min.</div>
  </td></tr>
</table>
</body></html>`;
}

main().catch((e) => { console.error(e); process.exit(1); });
