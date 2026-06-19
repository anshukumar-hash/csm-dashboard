// Vision chat — server-side proxy to the Google Gemini API (free tier).
//
// WHY THIS EXISTS
// The dashboard is a static, public HTML page. An API key must NEVER be embedded
// in it (anyone could read it via View Source). This serverless function keeps
// the key on the server: the browser POSTs the question + a compact snapshot of
// the dashboard data here, and this function adds the key and forwards it to
// Gemini. The key is read from the GEMINI_API_KEY env var.
//
// SETUP (the dashboard owner does this once — I cannot enter credentials):
//   1. Get a FREE key at https://aistudio.google.com/apikey  (no credit card).
//   2. In the Vercel project → Settings → Environment Variables, add:
//        Name:  GEMINI_API_KEY     Value: <your key>     (Production + Preview)
//      Optionally:
//        Name:  VISION_MODEL       Value: gemini-2.0-flash   (override)
//   3. Redeploy. The "Vision" bubble then works on the Vercel URL.
//
// NOTE: GitHub Pages has no serverless runtime, so Vision only works on the
// Vercel deployment. On other hosts the bubble shows a friendly setup notice.

const DEFAULT_MODEL = 'gemini-2.0-flash';
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

  const key = process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY;
  if (!key) {
    return send(res, 503, {
      error: 'Vision is not configured yet. Add a GEMINI_API_KEY environment ' +
             'variable to the Vercel project (Settings → Environment Variables) and redeploy. ' +
             'Get a free key at https://aistudio.google.com/apikey',
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

  // Map our {role:'user'|'assistant'} history to Gemini's {role:'user'|'model'} turns.
  const contents = messages
    .filter((m) => m && (m.role === 'user' || m.role === 'assistant') && typeof m.content === 'string')
    .slice(-20)
    .map((m) => ({ role: m.role === 'assistant' ? 'model' : 'user', parts: [{ text: m.content }] }));

  if (!contents.length || contents[contents.length - 1].role !== 'user') {
    return send(res, 400, { error: 'Last message must be from the user.' });
  }

  const model = process.env.VISION_MODEL || DEFAULT_MODEL;
  const url = 'https://generativelanguage.googleapis.com/v1beta/models/' +
    encodeURIComponent(model) + ':generateContent';

  try {
    const upstream = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-goog-api-key': key },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: system }] },
        contents,
        generationConfig: { maxOutputTokens: 1024, temperature: 0.4 },
      }),
    });

    const data = await upstream.json().catch(() => ({}));
    if (!upstream.ok) {
      const detail = (data && data.error && data.error.message) || `HTTP ${upstream.status}`;
      return send(res, 502, { error: 'Gemini API error: ' + detail });
    }
    const cand = data && Array.isArray(data.candidates) ? data.candidates[0] : null;
    const reply = cand && cand.content && Array.isArray(cand.content.parts)
      ? cand.content.parts.map((p) => p.text || '').join('').trim()
      : '';
    if (!reply) {
      const why = (cand && cand.finishReason) ? (' (' + cand.finishReason + ')') : '';
      return send(res, 200, { reply: 'I could not generate a response for that' + why + '. Try rephrasing.' });
    }
    return send(res, 200, { reply });
  } catch (err) {
    return send(res, 500, { error: 'Upstream fetch failed: ' + String(err && err.message || err) });
  }
}
