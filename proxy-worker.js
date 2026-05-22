// CSM Dashboard — Metabase CORS proxy.
// Deployed as a Cloudflare Worker. The dashboard (running on GitHub Pages /
// Netlify / file://) hits this Worker, which fetches Metabase server-side and
// returns the JSON with permissive CORS headers — the browser never talks to
// metabase.spyne.ai directly so CORS rules don't apply.
//
// DEPLOY (3 min, free):
//   1. dash.cloudflare.com → Workers & Pages → Create application → Create Worker
//   2. Name it: csm-dashboard-proxy
//   3. "Edit code" → delete the sample → paste THIS file → Save and Deploy
//   4. Copy the *.workers.dev URL it gives you
//   5. Open the dashboard with ?proxy=<that URL> appended, OR open the file
//      and change PROXY_URL on line 6 to that URL.
//
// Free tier limit: 100,000 requests/day. The dashboard refreshes every 5 min
// (~288 requests/day per open tab) so you're nowhere near the cap.

const METABASE_URL = "https://metabase.spyne.ai/public/question/d2bf20f4-a0c0-409f-b715-84dfb57c891d.json";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Max-Age": "86400",
};

export default {
  async fetch(request) {
    // Pre-flight (browser asks "can I call you?")
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }
    if (request.method !== "GET") {
      return new Response("Method not allowed", { status: 405, headers: CORS_HEADERS });
    }
    try {
      const upstream = await fetch(METABASE_URL, {
        headers: { "Accept": "application/json", "User-Agent": "csm-dashboard-proxy/1.0" },
        cf: { cacheTtl: 60, cacheEverything: true },  // 60-sec edge cache; be polite to Metabase
      });
      const body = await upstream.text();
      return new Response(body, {
        status: upstream.status,
        headers: {
          ...CORS_HEADERS,
          "Content-Type": "application/json; charset=utf-8",
          "Cache-Control": "public, max-age=60",
          "X-Proxy-Source": "csm-dashboard-proxy",
        },
      });
    } catch (err) {
      return new Response(JSON.stringify({ error: "Upstream fetch failed", detail: String(err) }), {
        status: 502,
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      });
    }
  },
};
