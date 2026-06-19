// Vision chat — server-side proxy to the Groq API (free, OpenAI-compatible).
//
// WHY THIS EXISTS
// The dashboard is a static, public HTML page. An API key must NEVER be embedded
// in it (anyone could read it via View Source). This serverless function keeps
// the key on the server: the browser POSTs the question + a compact snapshot of
// the dashboard data here, and this function adds the key and forwards it to
// Groq. The key is read from the GROQ_API_KEY env var.
//
// SETUP (the dashboard owner does this once — I cannot enter credentials):
//   1. Get a FREE key at https://console.groq.com/keys  (no credit card).
//   2. In the Vercel project → Settings → Environment Variables, add:
//        Name:  GROQ_API_KEY     Value: <your key>     (Production + Preview)
//      Optionally:
//        Name:  VISION_MODEL     Value: llama-3.3-70b-versatile   (override)
//   3. Redeploy. The "Vision" bubble then works on the Vercel URL.
//
// NOTE: GitHub Pages has no serverless runtime, so Vision only works on the
// Vercel deployment. On other hosts the bubble shows a friendly setup notice.

const GROQ_URL = 'https://api.groq.com/openai/v1/chat/completions';
const DEFAULT_MODEL = 'llama-3.3-70b-versatile';
const MAX_CONTEXT_CHARS = 180000; // guard against oversized payloads

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

function send(res, status, obj) {
  res.writeHead(status, { 'Content-Type': 'application/json', ...CORS });
  res.end(JSON.stringify(obj));
}

async function readBody(req) {
  if (req.body) {
    return typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
  }
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const raw = Buffer.concat(chunks).toString('utf8');
  return raw ? JSON.parse(raw) : {};
}

export default async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.writeHead(204, CORS); res.end(); return; }
  if (req.method !== 'POST') return send(res, 405, { error: 'Use POST.' });

  const key = process.env.GROQ_API_KEY;
  if (!key) {
    return send(res, 503, {
      error: 'Vision is not configured yet. Add a GROQ_API_KEY environment ' +
             'variable to the Vercel project (Settings → Environment Variables) and redeploy. ' +
             'Get a free key at https://console.groq.com/keys',
    });
  }

  let payload;
  try { payload = await readBody(req); }
  catch { return send(res, 400, { error: 'Invalid JSON body.' }); }

  const messages = Array.isArray(payload.messages) ? payload.messages : null;
  if (!messages || !messages.length) return send(res, 400, { error: 'messages[] required.' });

  let contextStr = '';
  if (payload.context != null) {
    contextStr = typeof payload.context === 'string'
      ? payload.context
      : JSON.stringify(payload.context);
    if (contextStr.length > MAX_CONTEXT_CHARS) contextStr = contextStr.slice(0, MAX_CONTEXT_CHARS);
  }

  const system =
    'You are "Vision", a sharp, concise analytics assistant embedded in a Customer Success ' +
    'Management (CSM) dashboard for Spyne. Spyne sells two products: "Studio" (AI photo/imaging ' +
    'for auto dealers) and "Vini" (an AI voice/agent product). Customers are car dealerships ' +
    '("rooftops") grouped into enterprises. CSMs (Customer Success Managers) own accounts.\n\n' +
    'You answer questions about account health, churn, revenue at risk, and where a CSM should ' +
    'focus, using ONLY the JSON snapshot provided below. Rules:\n' +
    '- Be direct and specific. Lead with the answer, then a short "why".\n' +
    '- When listing accounts, use a compact bulleted/numbered list with the key numbers ' +
    '(ARR, CSM, status/reason). Round currency to whole dollars with a $ sign.\n' +
    '- "Red" = highest risk. Payment signals: t1/t2/t3 and *Rag fields where "overdue"/"Red" is bad. ' +
    '"churn"/"Churned" means the account left. The churn section is realized lost revenue.\n' +
    '- If the snapshot does not contain the answer, say so plainly — do not invent numbers.\n' +
    '- Keep answers under ~200 words unless the user asks for a deep dive.\n\n' +
    'DASHBOARD SNAPSHOT (JSON):\n' + (contextStr || '(none provided)');

  // Groq is OpenAI-compatible: a system message + our user/assistant history.
  const history = messages
    .filter((m) => m && (m.role === 'user' || m.role === 'assistant') && typeof m.content === 'string')
    .map((m) => ({ role: m.role, content: m.content }))
    .slice(-20);

  if (!history.length || history[history.length - 1].role !== 'user') {
    return send(res, 400, { error: 'Last message must be from the user.' });
  }

  try {
    const upstream = await fetch(GROQ_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: 'Bearer ' + key },
      body: JSON.stringify({
        model: process.env.VISION_MODEL || DEFAULT_MODEL,
        max_tokens: 1024,
        temperature: 0.4,
        messages: [{ role: 'system', content: system }, ...history],
      }),
    });

    const data = await upstream.json().catch(() => ({}));
    if (!upstream.ok) {
      const detail = (data && data.error && data.error.message) || `HTTP ${upstream.status}`;
      return send(res, 502, { error: 'Groq API error: ' + detail });
    }
    const choice = data && Array.isArray(data.choices) ? data.choices[0] : null;
    const reply = choice && choice.message && typeof choice.message.content === 'string'
      ? choice.message.content.trim()
      : '';
    return send(res, 200, { reply: reply || '(no response)' });
  } catch (err) {
    return send(res, 500, { error: 'Upstream fetch failed: ' + String(err && err.message || err) });
  }
}
