# CSM Dashboard

Static HTML dashboard for Studio & Vini CSM views.

## Data sources (browser-side gviz fetch, every 4h)

- `gid=1616842841` — Vini daily metrics
- `gid=674556270`  — Payment master (CS_Vini_Stage)
- `gid=701797891`  — CSAT readings

The source sheet must be shared as **Anyone with the link → Viewer** for the
browser fetch to work. Otherwise the dashboard falls back to the embedded
snapshot baked into `index.html`.
