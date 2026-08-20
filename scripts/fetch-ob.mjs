#!/usr/bin/env node
// Fetch the Studio Onboarding (OB) tracker Google Sheet and normalize both
// regional tabs (AMER + APAC/EMEA) into one unified schema -> ob_data.json.
//
// The two tabs have DIFFERENT column orders, so everything is mapped by header
// NAME (row 3 of each tab), never by position. Rows 1-2 are a totals row and an
// "owner" tag row; real data starts at row 4 (index 3).
//
// Usage: node scripts/fetch-ob.mjs
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

const SHEET_ID = '1ioRrooOvDSBxc7gjC2XUGjqHH_YBze_2HryOF8JWqL0';
// productLine is the Studio-vs-Vini split. NOTE the sheet's own "Product" column
// is the Studio FEATURE mix (Images / 360 Spin / Video) — not the product line.
// goCol = the UNLABELLED go-live date column, read by position. These indexes are
// taken from the Executive Report's own TABS config (api/metrics.js) so "new live
// MTD" here matches executive-report.spyne.ai exactly.
// obCallCol = the unlabelled "OB Call Date" column, also taken from the Executive
// Report's TABS config, used for the "sales handed to OB this month" metric.
// liveTatCol = the sheet's own "Live TAT" column (days from OB call to go-live),
// given by the user: Studio AMER = AI(34), Studio APAC/EMEA = W(22), Vini = AJ(35).
const TABS = [
  { region: 'AMER',      gid: '1134407178', productLine: 'Studio', goCol: 15, obCallCol: 14, liveTatCol: 34 },
  { region: 'APAC/EMEA', gid: '764039413',  productLine: 'Studio', goCol: 21, obCallCol: 15, liveTatCol: 22 },
  { region: 'AMER',      gid: '2053683245', productLine: 'Vini',   goCol: 16, obCallCol: 14, liveTatCol: 35 },
];

// ---- tiny CSV parser (RFC-4180-ish, handles quotes + embedded newlines) ----
function parseCSV(t) {
  const rows = [];
  let f = '', row = [], q = false;
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (q) {
      if (c === '"') { if (t[i + 1] === '"') { f += '"'; i++; } else q = false; }
      else f += c;
    } else {
      if (c === '"') q = true;
      else if (c === ',') { row.push(f); f = ''; }
      else if (c === '\n') { row.push(f); rows.push(row); row = []; f = ''; }
      else if (c === '\r') { /* skip */ }
      else f += c;
    }
  }
  if (f !== '' || row.length) { row.push(f); rows.push(row); }
  return rows;
}

// Use the PUBLISHED csv endpoint, not gviz: gviz silently returns garbage for the
// Vini tab (10 duplicated rows instead of ~396). pub returns all three tabs intact.
async function fetchCSV(gid) {
  const url = `https://docs.google.com/spreadsheets/d/${SHEET_ID}/pub?gid=${gid}&single=true&output=csv`;
  let lastErr;
  for (let attempt = 1; attempt <= 4; attempt++) {
    try {
      const res = await fetch(url, { redirect: 'follow' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const text = await res.text();
      if (text.includes('<!DOCTYPE html') || text.includes('<html'))
        throw new Error('got HTML (sheet not public / gid wrong)');
      return text;
    } catch (e) {
      lastErr = e;
      await new Promise(r => setTimeout(r, 1500 * attempt));
    }
  }
  throw new Error(`fetch gid ${gid} failed: ${lastErr?.message}`);
}

// ---- helpers ----
const num = (v) => {
  if (v == null) return null;
  const s = String(v).replace(/[$,\s]/g, '').trim();
  if (s === '' || s === '-' || /^na$/i.test(s)) return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
};
const str = (v) => (v == null ? '' : String(v).trim());

// Canonical stage buckets across both tabs' vocabularies.
function canonStage(raw) {
  const s = str(raw).toLowerCase();
  if (!s) return '';
  if (s === 'live') return 'Live';
  if (s.includes('cs churn') || s === 'churned') return 'CS Churn';   // Vini tab says "Churned"
  if (s.includes('ob drop')) return 'OB Drop';
  if (s.includes('sales drop')) return 'Sales Drop';
  if (s.includes('ob initiated') || s.includes('implementation') || s.includes('in-ob') || s.includes('in ob')) return 'In-OB';
  if (s === 'pws') return 'PWS';
  return str(raw); // keep unknowns verbatim so nothing is silently dropped
}

// header name -> normalized field. Only names present in a tab are used.
const FIELD_MAP = {
  'Ent Name': 'ent',
  'Account Name': 'ent',            // Vini tab's name for the same column
  'ARR ($)': 'arrNamed',            // Vini tab labels its ARR column
  'New CS Owner': 'handoverCS',     // Vini tab's name for Handover CS
  'Team ID': 'teamId',
  'Agent Opted': 'agentOpted',
  'OEM': 'oem',
  'Go-Live Date': 'goLiveDate',
  'Rooftop Name': 'rn',
  'OB POC': 'obPoc',
  'Stage': 'stageRaw',
  'Sub Stage': 'subStage',
  'Enterprise ID': 'eid',
  'Segment': 'seg',
  'Franchise / Independent': 'franchise',
  'Group / Single': 'grp',
  'Product': 'product',
  'Flow': 'flow',
  'Current Month Confirmations': 'curMonthConf',
  'Projected Live Date': 'projLiveDate',
  'OB Ageing': 'obAgeing',
  'OB Running TAT': 'obTat',
  'Churn / Drop-off Date': 'churnDate',
  'Blocked Owner': 'blockedOwner',
  'Blocked Remarks': 'blockedRemarks',
  'Who is currently working to unblock? (Add person name)': 'unblockOwner',
  'Unblocking ETA': 'unblockEta',
  'Probability': 'probability',
  'Handover CS': 'handoverCS',
  'Handover Status': 'handoverStatus',
  'Sentiment Score': 'sentiment',
  'Health Score': 'healthScore',
  'RAG Mapping': 'rag',
  'Invoice Start Date - Manual': 'invoiceStart',
  'Invoice Number': 'invoiceNo',
  'Website URL': 'ws',
  'Contract Month': 'contractMonth',
  'OB Month': 'obMonth',
  'Live Month': 'liveMonth',
  'Invoice Live Month': 'invoiceLiveMonth',
  'Live Email Month': 'liveEmailMonth',
  'Projection Week': 'projWeek',
  'Projection Month': 'projMonth',
  'In-Ob from': 'inObFrom',
  'Live From': 'liveFrom',
  'Country': 'country',
  'Region': 'subRegion',
  'DB CSM Name': 'dbCsm',
};

// The unlabeled ARR column: it is the 3rd column (index 2) in both tabs, sitting
// between "Rooftop Name" and "OB POC", holding "$4,012,214"-style values.
const ARR_COL_INDEX = 2;

function normalizeTab(csv, region, productLine, goCol, obCallCol, liveTatCol) {
  const rows = parseCSV(csv);
  const header = rows[2] || [];
  const idxByField = {};
  header.forEach((h, i) => {
    const key = FIELD_MAP[str(h)];
    if (key && idxByField[key] === undefined) idxByField[key] = i;
  });

  const out = [];
  for (let r = 3; r < rows.length; r++) {
    const row = rows[r];
    if (!row) continue;
    const get = (field) => (idxByField[field] !== undefined ? row[idxByField[field]] : '');
    const ent = str(get('ent'));
    const rn = str(get('rn'));
    if (!ent && !rn) continue; // skip blank spacer rows

    const stage = canonStage(get('stageRaw'));
    out.push({
      productLine,
      region,
      subRegion: str(get('subRegion')) || (region === 'AMER' ? 'AMER' : ''),
      country: str(get('country')),
      ent, rn,
      eid: str(get('eid')),
      teamId: str(get('teamId')),
      goLive: goCol != null ? str(row[goCol]) : str(get('goLiveDate')),
      obCall: obCallCol != null ? str(row[obCallCol]) : '',
      // "NA", blanks and junk (the AMER tab holds values like -46104) are dropped;
      // a plausible onboarding TAT is 0-365 days.
      liveTat: (() => {
        if (liveTatCol == null) return null;
        const n = num(row[liveTatCol]);
        return n != null && n >= 0 && n <= 365 ? n : null;
      })(),
      agentOpted: str(get('agentOpted')),
      oem: str(get('oem')),
      // Vini labels its ARR column; the Studio tabs leave it unlabeled at index 2.
      arr: idxByField.arrNamed !== undefined ? num(row[idxByField.arrNamed]) : num(row[ARR_COL_INDEX]),
      obPoc: str(get('obPoc')),
      stage,
      stageRaw: str(get('stageRaw')),
      subStage: str(get('subStage')),
      seg: str(get('seg')),
      franchise: str(get('franchise')),
      grp: str(get('grp')),
      product: str(get('product')),
      flow: str(get('flow')),
      curMonthConf: str(get('curMonthConf')),
      projLiveDate: str(get('projLiveDate')),
      obAgeing: str(get('obAgeing')),
      obTat: str(get('obTat')),
      churnDate: str(get('churnDate')),
      blockedOwner: str(get('blockedOwner')),
      blockedRemarks: str(get('blockedRemarks')),
      unblockOwner: str(get('unblockOwner')),
      unblockEta: str(get('unblockEta')),
      probability: str(get('probability')),
      handoverCS: str(get('handoverCS')),
      handoverStatus: str(get('handoverStatus')),
      sentiment: num(get('sentiment')),
      healthScore: num(get('healthScore')),
      rag: str(get('rag')),
      contractMonth: str(get('contractMonth')),
      obMonth: str(get('obMonth')),
      liveMonth: str(get('liveMonth')),
      inObFrom: str(get('inObFrom')),
      liveFrom: str(get('liveFrom')),
      dbCsm: str(get('dbCsm')),
      ws: str(get('ws')),
      invoiceNo: str(get('invoiceNo')),
    });
  }
  return out;
}

async function main() {
  const all = [];
  const perTab = {};
  for (const { region, gid, productLine, goCol, obCallCol, liveTatCol } of TABS) {
    process.stderr.write(`Fetching ${productLine} / ${region} (gid ${gid})...\n`);
    const csv = await fetchCSV(gid);
    const rows = normalizeTab(csv, region, productLine, goCol, obCallCol, liveTatCol);
    perTab[`${productLine} · ${region}`] = rows.length;
    all.push(...rows);
    process.stderr.write(`  ${rows.length} rows\n`);
  }

  // stage tallies for a quick sanity readout
  const stageCounts = {};
  for (const r of all) stageCounts[r.stage] = (stageCounts[r.stage] || 0) + 1;
  const productCounts = {};
  for (const r of all) productCounts[r.productLine] = (productCounts[r.productLine] || 0) + 1;

  const payload = {
    generated_at: new Date().toISOString(),
    source: `Google Sheet ${SHEET_ID} (Studio AMER + Studio APAC/EMEA + Vini tabs, published CSV)`,
    perTab,
    stageCounts,
    productCounts,
    count: all.length,
    rows: all,
  };
  const outPath = join(ROOT, 'ob_data.json');
  writeFileSync(outPath, JSON.stringify(payload));
  process.stderr.write(`\nWrote ${all.length} rows -> ${outPath}\n`);
  process.stderr.write(`Product: ${JSON.stringify(productCounts)}\n`);
  process.stderr.write(`Stage counts: ${JSON.stringify(stageCounts)}\n`);
}

main().catch((e) => { console.error(e); process.exit(1); });
