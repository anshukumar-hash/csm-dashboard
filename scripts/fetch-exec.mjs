#!/usr/bin/env node
// Pull the Executive Report's computed metrics -> exec_metrics.json
//
//   /api/metrics  — CARR / LARR walk, New Live MTD, ARR in OB, projected new
//                   live, new sales, PWS, GRR/NRR (Studio + Vini splits)
//   /api/health   — CSM dashboard RAG buckets (Studio green/amber/red + ARR)
//
// Both endpoints are public and need no key (see Executive-Report CLAUDE.md:
// REQUIRED_KEYS = []). Vercel mirror is used as a fallback host.
//
// Usage: node scripts/fetch-exec.mjs
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

const HOSTS = [
  'https://executive-report.spyne.ai',
  'https://exec-report-repo.vercel.app',
];

async function get(path) {
  let lastErr;
  for (const host of HOSTS) {
    for (let a = 1; a <= 2; a++) {
      try {
        const res = await fetch(host + path, { signal: AbortSignal.timeout(45000) });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        return await res.json();
      } catch (e) { lastErr = e; }
    }
    process.stderr.write(`  ! ${host}${path} failed (${lastErr?.message}) — trying next host\n`);
  }
  throw new Error(`${path} failed on all hosts: ${lastErr?.message}`);
}

const [metrics, health] = await Promise.all([get('/api/metrics'), get('/api/health')]);

const payload = { generated_at: new Date().toISOString(),
  source: 'Executive-Report /api/metrics + /api/health', metrics, health };
writeFileSync(join(ROOT, 'exec_metrics.json'), JSON.stringify(payload));

const m = metrics, f = n => '$' + Math.round(n || 0).toLocaleString();
process.stderr.write(`Wrote exec_metrics.json (month ${m.month})\n`);
process.stderr.write(`  CARR  total ${f(m.carr?.total)} · studio ${f(m.carr?.studio)} · vini ${f(m.carr?.vini)}\n`);
process.stderr.write(`  LARR  total ${f(m.larr?.total)} · studio ${f(m.larr?.studio)} · vini ${f(m.larr?.vini)}\n`);
process.stderr.write(`  New live MTD ${f(m.newLive?.total)} · ARR in OB ${f(m.arrInOb?.total)}\n`);
process.stderr.write(`  Studio RAG red ${health.studio?.red} (${f(health.studio?.arr?.red)})\n`);
