# Integrations Tracker (Vini)

Self-contained dashboard: **`index.html`** — open directly in any browser. No build step,
no server, no internet required (Google Fonts load if online; falls back to system fonts offline).

## Data
Records are merged from two tabs of the source Google Sheet and embedded inline in `index.html`:
- **Live accounts** (gid `1228212580`) — supplies MRR; **Churned** rows are excluded.
- **OB Initiated / master** (gid `1120490500`) — lifecycle status, agent type, ARR, and the
  DMS / IMS / Sales CRM / Service Scheduler integration mappings.

215 rooftop×agent records (129 Live, 86 OB Initiated), 84 distinct rooftops.

## Refreshing the data
```bash
cd build
# re-export both tabs as CSV (see gids above), overwriting live_accounts.csv / onb_accounts.csv:
#   https://docs.google.com/spreadsheets/d/<ID>/export?format=csv&gid=<gid>
node build.js                      # -> _records.json
# then re-inject into index.html (replaces the `const DATA = ...` line)
node -e "const fs=require('fs');let h=fs.readFileSync('../index.html','utf8').split('\n');const i=h.findIndex(l=>l.startsWith('const DATA = '));h[i]='const DATA = '+fs.readFileSync('_records.json','utf8')+';';fs.writeFileSync('../index.html',h.join('\n'));console.log('re-injected line',i+1);"
```
