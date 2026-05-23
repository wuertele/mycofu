# Cluster Dashboard

Static cluster dashboard bundle co-hosted with InfluxDB.

- Runtime: vanilla HTML/CSS/JS, no build step
- Charts: `static/vendor/uPlot.min.js` and `static/vendor/uPlot.min.css`
- Runtime config: `/run/secrets/dashboard/config.json`
- Runtime secrets: `/run/secrets/proxmox-api-token`,
  `/run/secrets/dashboard-influxdb-token`

## Vendor Note

The dashboard expects `uPlot` assets at:

- `static/vendor/uPlot.min.js`
- `static/vendor/uPlot.min.css`

This sprint vendors an in-repo pinned compatibility bundle so the
dashboard ships entirely inside the Nix closure with no CDN dependency.
