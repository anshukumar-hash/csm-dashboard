# CSM Leadership Dashboard

Single-file interactive dashboard for daily / MTD leadership reviews across two products: **Studio** and **Vini**.

## Files

- `CSM_Dashboard.html` — self-contained dashboard. Open in any modern browser. No build step.
- `proxy-worker.js` — optional Cloudflare Worker to proxy the Vini Google Sheet without CORS issues (deploy steps inside the file).

## What it does

**Two product tabs**

- **Studio** — VIN-based metrics (Active VINs, Pendency, Payment T1/T2/T3, Tickets, MBR)
- **Vini** — call-funnel metrics (Touched / Qualified / Appointments, Conv Rate, RoI Factor) sourced from the `CS_Vini_Stage` rollup and the daily Vini sheet

**Two sub-views per tab**

- **Overview** — KPI scorecards, then Segment-level / Agent-level / CSM-level aggregate tables
- **Rooftop View** — per-rooftop drill-down with the same column bucketing

**Filters**

- Region (AMER default)
- Customer Segment (Ent / Mid / SMB / Resellers)
- CSM Manager → CSM
- MTD / Last Month preset toggle + custom date range picker

**Live data**

- Vini CSM and aggregate values are baked from a recent snapshot of the source workbook.
- A gviz fetch every 5 minutes will overlay newer values **once the source sheet is shared as "Anyone with the link – Viewer"** (currently private, so fetch falls back to the embedded snapshot).

## Hosting

The HTML is fully self-contained (~1.6 MB). Drop it on any static host:

- GitHub Pages (rename to `index.html`, enable Pages on the repo)
- Netlify Drop / Vercel / Cloudflare Pages — drag-and-drop the file
- Or open `file://` locally
