// Cluster Dashboard — UI Requirements
//
// R1.  Two series per chart: CPU (% of full) and memory (used/allocated ratio)
// R2.  Chart height proportional to VM's allocated RAM
// R3.  Node header chart height proportional to node's total RAM
// R4.  VM card: single-line header — no pool, node, or "running" text
// R5.  VM ID shown as "id NNN", right-justified
// R6.  Running state indicated by VM name color, not text
// R7.  Non-running VMs: name in light gray
// R8.  Chart extends to top of bounding box, overlapping under label text
// R9.  Vertical grid lines at :00, :15, :30, :45 past the hour
// R10. :00 line slightly bolder than :15/:30/:45
// R11. Uniform line thickness across all charts (no scaling artifacts)
// R12. Thin chart lines (width 1)
// R13. Node header: single-line format matching VM cards
// R14. Node header shows memory use/capacity rounded to GB (e.g. "25/30GB")
// R15. VM card shows memory use/capacity (e.g. "23/24GB" or "181/256MB")
// R16. VM card CPU shown as "<cores>x<usage%>" (e.g. "12x0%")
// R17. Node header CPU shown as "<allocated>/<total> NN%"
// R18. Time window slider: log scale 1min–1day, +/− buttons step by 50%
// R19. All controls in the status bar alongside status text
// R20. No title text — removed "Live Floorplan" and "CLUSTER DASHBOARD"
// R21. Status bar shows "<domain> Mycofu Status" on the left
// R22. Domain in accent color, "Mycofu Status" in muted color
// R23. Domain text ~2x taller than other status bar text
// R24. Grid fills full browser width (no max-width cap)
// R25. Grid fills remaining vertical space below status bar
// R26. VM cards expand to fill cell width
// R27. Card width proportional to allocated CPU cores (min 20%)
// R28. VMs sorted within cell by cpu*maxcpu descending (busiest at top)
// R29. VM name color: light blue (lowest cpu*maxcpu) → green → yellow → red (highest)
// R30. Node name color: same gradient based on absolute CPU load
// R31. Default chart window: 60 minutes

(function () {
  const DOM = {
    root: document.getElementById("dashboard-root"),
    status: document.getElementById("status-banner"),
    statusTitle: document.getElementById("status-title"),
    toolbar: document.getElementById("toolbar"),
    toolbarButtons: null,
  };

  const CARD_CHART_HEIGHT = 200;
  const AXIS_CHART_HEIGHT = 120;
  const COMPACT_CHART_HEIGHT = 200;
  const TABLET_BREAKPOINT = 800;
  const LAYOUT_STORAGE_KEY = "cluster-dashboard-layout";
  const DEFAULT_LAYOUT = {
    mode: "grid",
    orientation: "pool-x",
  };
  const CHART_COLORS = {
    cpu: "#ff6a3d",
    memory: "#4da3ff",
  };

  const TIME_WINDOW_STORAGE_KEY = "cluster-dashboard-window";
  const TIME_WINDOW_MIN = 1;      // 1 minute
  const TIME_WINDOW_MAX = 1440;   // 1 day

  const state = {
    config: null,
    vms: [],
    nodeStates: new Map(),
    vmMetrics: new Map(),
    nodeMetrics: new Map(),
    layout: loadLayoutPreference(),
    windowMinutes: loadWindowPreference(),
    timer: null,
    paused: document.visibilityState === "hidden",
  };

  async function init() {
    if (!DOM.root || !DOM.status) {
      return;
    }

    if (DOM.toolbar) {
      DOM.toolbar.hidden = true;
    }

    setStatus("Loading dashboard config...", "info");

    try {
      state.config = await fetchJson("/api/config");
    } catch (error) {
      renderError("Unable to load dashboard config.");
      setStatus(error.message, "error");
      return;
    }

    // Set title from domain in Grafana base URL (e.g. https://grafana.dev.wuertele.com → wuertele.com)
    if (DOM.statusTitle) {
      let domain = "";
      try {
        const url = state.config.grafanaBaseUrl || "";
        const host = new URL(url).hostname; // grafana.dev.wuertele.com
        const parts = host.split(".");
        if (parts.length >= 2) {
          domain = parts.slice(-2).join(".");
        }
      } catch (_e) { /* ignore */ }
      DOM.statusTitle.innerHTML = "";
      const domainSpan = document.createElement("span");
      domainSpan.className = "status-bar-domain";
      domainSpan.textContent = domain || "cluster";
      const suffixSpan = document.createElement("span");
      suffixSpan.className = "status-bar-suffix";
      suffixSpan.textContent = " Mycofu Status";
      DOM.statusTitle.append(domainSpan, suffixSpan);
    }

    bindToolbar();
    bindVisibilityHandling();
    bindResizeHandling();

    await poll(true);
    schedulePolling();
  }

  function bindVisibilityHandling() {
    document.addEventListener("visibilitychange", async () => {
      state.paused = document.visibilityState === "hidden";
      if (state.paused) {
        clearPolling();
        setStatus("Polling paused while the tab is hidden.", "info");
        return;
      }

      setStatus("Resuming polling...", "info");
      await poll(true);
      schedulePolling();
    });
  }

  function bindResizeHandling() {
    let resizeTimer = null;

    window.addEventListener("resize", () => {
      if (resizeTimer !== null) {
        window.clearTimeout(resizeTimer);
      }
      resizeTimer = window.setTimeout(() => {
        renderDashboard();
      }, 120);
    });
  }

  function bindToolbar() {
    if (!DOM.toolbar) {
      return;
    }

    DOM.toolbar.hidden = false;
    DOM.toolbar.replaceChildren();

    const swapButton = makeToolbarButton("Swap Axes", () => {
      state.layout.orientation = state.layout.orientation === "pool-x" ? "pool-y" : "pool-x";
      persistLayoutPreference();
      renderDashboard();
    });

    const gridButton = makeToolbarButton("Grid", () => {
      state.layout.mode = "grid";
      persistLayoutPreference();
      renderDashboard();
    });

    const flatButton = makeToolbarButton("Flat", () => {
      state.layout.mode = "flat";
      persistLayoutPreference();
      renderDashboard();
    });

    // Time window control
    const windowControl = document.createElement("div");
    windowControl.className = "toolbar-window-control";

    const minusBtn = document.createElement("button");
    minusBtn.type = "button";
    minusBtn.className = "toolbar-button toolbar-window-btn";
    minusBtn.textContent = "\u2212"; // minus sign

    const slider = document.createElement("input");
    slider.type = "range";
    slider.className = "toolbar-window-slider";
    slider.min = "0";
    slider.max = "1000";
    slider.step = "1";

    const windowLabel = document.createElement("span");
    windowLabel.className = "toolbar-window-label";

    const plusBtn = document.createElement("button");
    plusBtn.type = "button";
    plusBtn.className = "toolbar-button toolbar-window-btn";
    plusBtn.textContent = "+";

    function setWindow(minutes) {
      state.windowMinutes = Math.max(TIME_WINDOW_MIN, Math.min(TIME_WINDOW_MAX, Math.round(minutes)));
      slider.value = String(Math.round(minutesToSlider(state.windowMinutes) * 1000));
      windowLabel.textContent = formatWindowLabel(state.windowMinutes);
      persistWindowPreference();
      void poll(false);
    }

    slider.value = String(Math.round(minutesToSlider(chartWindowMinutes()) * 1000));
    windowLabel.textContent = formatWindowLabel(chartWindowMinutes());

    slider.addEventListener("input", function () {
      const mins = sliderToMinutes(Number(slider.value) / 1000);
      setWindow(mins);
    });

    minusBtn.addEventListener("click", function () {
      setWindow(chartWindowMinutes() / 1.5);
    });

    plusBtn.addEventListener("click", function () {
      setWindow(chartWindowMinutes() * 1.5);
    });

    windowControl.append(minusBtn, slider, windowLabel, plusBtn);

    DOM.toolbar.append(swapButton, gridButton, flatButton, windowControl);
    DOM.toolbarButtons = { swapButton, gridButton, flatButton };
    updateToolbarState();
  }

  function makeToolbarButton(label, onClick) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "toolbar-button";
    button.textContent = label;
    button.addEventListener("click", onClick);
    return button;
  }

  function updateToolbarState() {
    if (!DOM.toolbarButtons) {
      return;
    }

    const { swapButton, gridButton, flatButton } = DOM.toolbarButtons;
    swapButton.disabled = state.layout.mode === "flat";
    swapButton.title = state.layout.orientation === "pool-y" ? "Nodes on X, pools on Y" : "Pools on X, nodes on Y";
    gridButton.classList.toggle("is-active", state.layout.mode === "grid");
    flatButton.classList.toggle("is-active", state.layout.mode === "flat");
  }

  function loadLayoutPreference() {
    const fallback = {
      mode: DEFAULT_LAYOUT.mode,
      orientation: DEFAULT_LAYOUT.orientation,
    };

    if (!window.localStorage) {
      return fallback;
    }

    try {
      const raw = window.localStorage.getItem(LAYOUT_STORAGE_KEY);
      if (!raw) {
        return fallback;
      }

      const parsed = JSON.parse(raw);
      return {
        mode: parsed && parsed.mode === "flat" ? "flat" : "grid",
        orientation: parsed && parsed.orientation === "pool-y" ? "pool-y" : "pool-x",
      };
    } catch (_error) {
      return fallback;
    }
  }

  function persistLayoutPreference() {
    if (!window.localStorage) {
      return;
    }

    try {
      window.localStorage.setItem(LAYOUT_STORAGE_KEY, JSON.stringify(state.layout));
    } catch (_error) {
      // Ignore storage failures; layout still applies for the current session.
    }
  }

  function loadWindowPreference() {
    try {
      const v = Number(window.localStorage && window.localStorage.getItem(TIME_WINDOW_STORAGE_KEY));
      return (v >= TIME_WINDOW_MIN && v <= TIME_WINDOW_MAX) ? v : 0;
    } catch (_e) { return 0; }
  }

  function persistWindowPreference() {
    try {
      if (window.localStorage) {
        window.localStorage.setItem(TIME_WINDOW_STORAGE_KEY, String(state.windowMinutes || ""));
      }
    } catch (_e) { /* ignore */ }
  }

  function formatWindowLabel(minutes) {
    if (minutes >= 1440) return Math.round(minutes / 1440) + "d";
    if (minutes >= 60) {
      const h = minutes / 60;
      return (h === Math.floor(h)) ? h + "h" : h.toFixed(1) + "h";
    }
    return Math.round(minutes) + "m";
  }

  // Log-scale conversion: slider position (0-1) ↔ minutes
  function sliderToMinutes(pos) {
    const logMin = Math.log(TIME_WINDOW_MIN);
    const logMax = Math.log(TIME_WINDOW_MAX);
    return Math.round(Math.exp(logMin + pos * (logMax - logMin)));
  }

  function minutesToSlider(minutes) {
    const logMin = Math.log(TIME_WINDOW_MIN);
    const logMax = Math.log(TIME_WINDOW_MAX);
    return (Math.log(minutes) - logMin) / (logMax - logMin);
  }

  function schedulePolling() {
    clearPolling();
    if (state.paused || !state.config) {
      return;
    }

    state.timer = window.setInterval(() => {
      void poll(false);
    }, pollIntervalSeconds() * 1000);
  }

  function clearPolling() {
    if (state.timer !== null) {
      window.clearInterval(state.timer);
      state.timer = null;
    }
  }

  function pollIntervalSeconds() {
    return Number(state.config && state.config.pollSeconds) || 15;
  }

  function chartWindowMinutes() {
    if (state.windowMinutes) return state.windowMinutes;
    return Number(state.config && state.config.chartWindowMinutes) || 60;
  }

  function metricsBucket() {
    return String((state.config && state.config.metricsBucket) || "default");
  }

  async function poll(forceStatus) {
    try {
      const vms = await fetchState();
      const nodeStates = await fetchNodeState();
      const nodeNames = configuredNodeNames(vms);
      const vmMetrics = await fetchVmMetrics(vms.map((vm) => String(vm.vmid)));
      let nodeMetrics = new Map();

      try {
        nodeMetrics = await fetchNodeMetrics(nodeNames);
      } catch (_error) {
        nodeMetrics = new Map();
      }

      if (!nodeMetrics.size) {
        nodeMetrics = aggregateNodeMetrics(vms, vmMetrics, nodeNames);
      }

      state.vms = vms;
      state.nodeStates = nodeStates;
      state.vmMetrics = vmMetrics;
      state.nodeMetrics = nodeMetrics;

      renderDashboard();
      if (forceStatus) {
        setStatus(
          `Loaded ${vms.length} VMs across ${nodeNames.length} nodes. Polling every ${pollIntervalSeconds()}s.`,
          "success"
        );
      } else {
        setStatus(
          `Updated ${new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })}.`,
          "success"
        );
      }
    } catch (error) {
      if (!state.vms.length) {
        renderError("Cluster state is unavailable.");
      }
      setStatus(error.message, "error");
    }
  }

  async function fetchState() {
    const payload = await fetchJson("/api/proxmox/cluster/resources?type=vm");
    const rows = Array.isArray(payload.data) ? payload.data : [];

    return rows
      .filter((row) => row && row.vmid != null)
      .map((row) => ({
        vmid: row.vmid,
        name: row.name || `vm-${row.vmid}`,
        node: row.node || "unknown",
        status: row.status || "unknown",
        tags: parseTags(row.tags),
        maxmem: Number(row.maxmem) || 0,
        mem: Number(row.mem) || 0,
        cpu: Number(row.cpu) || 0,
        maxcpu: Number(row.maxcpu) || 1,
      }))
      .sort((left, right) => {
        if (left.node === right.node) {
          return left.name.localeCompare(right.name);
        }
        return left.node.localeCompare(right.node);
      });
  }

  async function fetchNodeState() {
    const payload = await fetchJson("/api/proxmox/cluster/resources?type=node");
    const rows = Array.isArray(payload.data) ? payload.data : [];
    const nodeStates = new Map();

    rows.forEach((row) => {
      const node = row.node || row.name;
      if (!node) {
        return;
      }
      nodeStates.set(node, {
        status: row.status || "unknown",
        maxmem: Number(row.maxmem) || 0,
        mem: Number(row.mem) || 0,
        cpu: Number(row.cpu) || 0,
        maxcpu: Number(row.maxcpu) || 1,
      });
    });

    return nodeStates;
  }

  function configuredNodeNames(vms) {
    const configured = Array.isArray(state.config && state.config.nodes) ? state.config.nodes : [];
    const discovered = Array.from(new Set(vms.map((vm) => vm.node).filter(Boolean)));
    if (!configured.length) {
      return discovered;
    }

    const merged = [...configured];
    discovered.forEach((node) => {
      if (!merged.includes(node)) {
        merged.push(node);
      }
    });
    return merged;
  }

  function parseTags(rawTags) {
    if (!rawTags) {
      return [];
    }
    if (Array.isArray(rawTags)) {
      return rawTags;
    }

    return String(rawTags)
      .split(/[;,]/)
      .map((tag) => tag.trim())
      .filter(Boolean);
  }

  async function fetchVmMetrics(vmids) {
    if (!vmids.length) {
      return new Map();
    }

    const rows = await queryInflux(buildVmMetricsQuery(vmids));
    return indexMetrics(rows);
  }

  async function fetchNodeMetrics(nodeNames) {
    if (!nodeNames.length) {
      return new Map();
    }

    const rows = await queryInflux(buildNodeMetricsQuery(nodeNames));
    return indexMetrics(rows);
  }

  function indexMetrics(rows) {
    const byEntity = new Map();

    rows.forEach((row) => {
      const entityId = row.entityId;
      const seriesName = row.series;
      const value = Number(row._value);
      const timestamp = Date.parse(row._time) / 1000; // uPlot expects seconds

      if (!entityId || !seriesName || Number.isNaN(value) || Number.isNaN(timestamp)) {
        return;
      }

      if (!byEntity.has(entityId)) {
        byEntity.set(entityId, new Map());
      }

      const seriesMap = byEntity.get(entityId);
      if (!seriesMap.has(seriesName)) {
        seriesMap.set(seriesName, []);
      }
      seriesMap.get(seriesName).push([timestamp, value]);
    });

    const metrics = new Map();
    byEntity.forEach((seriesMap, entityId) => {
      metrics.set(entityId, normalizeSeriesMap(seriesMap));
    });
    return metrics;
  }

  function buildVmMetricsQuery(vmids) {
    const vmidList = vmids.map((vmid) => JSON.stringify(String(vmid))).join(", ");
    const bucket = JSON.stringify(metricsBucket());

    // Proxmox writes VM metrics to the "system" measurement with object="qemu",
    // not "cpustat". CPU is a 0-1 float in the "cpu" field. Memory is in "mem"
    // (used bytes) and "maxmem" (total bytes) fields.
    return `
vmids = [${vmidList}]

cpu = from(bucket: ${bucket})
  |> range(start: -${chartWindowMinutes()}m)
  |> filter(fn: (r) => r._measurement == "system" and r.object == "qemu" and r._field == "cpu")
  |> filter(fn: (r) => contains(value: string(v: r.vmid), set: vmids))
  |> map(fn: (r) => ({ r with entityId: string(v: r.vmid), series: "cpu", _value: float(v: r._value) * 100.0 }))

memory = from(bucket: ${bucket})
  |> range(start: -${chartWindowMinutes()}m)
  |> filter(fn: (r) => r._measurement == "system" and r.object == "qemu")
  |> filter(fn: (r) => contains(value: string(v: r.vmid), set: vmids))
  |> filter(fn: (r) => r._field == "mem" or r._field == "maxmem")
  |> pivot(rowKey: ["_time", "host", "vmid", "nodename"], columnKey: ["_field"], valueColumn: "_value")
  |> filter(fn: (r) => exists r.maxmem and float(v: r.maxmem) > 0.0)
  |> map(fn: (r) => ({ r with entityId: string(v: r.vmid), series: "memory", _value: float(v: r.mem) / float(v: r.maxmem) * 100.0 }))

union(tables: [cpu, memory])
  |> keep(columns: ["_time", "entityId", "series", "_value"])
  |> sort(columns: ["_time"])
`;
  }

  function buildNodeMetricsQuery(nodeNames) {
    const nodeList = nodeNames.map((node) => JSON.stringify(String(node))).join(", ");
    const bucket = JSON.stringify(metricsBucket());

    // Node CPU is in "cpustat" with object="nodes", field "cpu" (0-1 float).
    // Node memory is in "memory" with object="nodes", fields "memused" and
    // "memtotal" (bytes).
    return `
nodes = [${nodeList}]

cpu = from(bucket: ${bucket})
  |> range(start: -${chartWindowMinutes()}m)
  |> filter(fn: (r) => r._measurement == "cpustat" and r._field == "cpu")
  |> filter(fn: (r) => contains(value: string(v: r.host), set: nodes))
  |> filter(fn: (r) => r.object == "nodes")
  |> map(fn: (r) => ({ r with entityId: string(v: r.host), series: "cpu", _value: float(v: r._value) * 100.0 }))

memory = from(bucket: ${bucket})
  |> range(start: -${chartWindowMinutes()}m)
  |> filter(fn: (r) => r._measurement == "memory" and r.object == "nodes")
  |> filter(fn: (r) => contains(value: string(v: r.host), set: nodes))
  |> filter(fn: (r) => r._field == "memused" or r._field == "memtotal")
  |> pivot(rowKey: ["_time", "host"], columnKey: ["_field"], valueColumn: "_value")
  |> filter(fn: (r) => exists r.memtotal and float(v: r.memtotal) > 0.0)
  |> map(fn: (r) => ({ r with entityId: string(v: r.host), series: "memory", _value: float(v: r.memused) / float(v: r.memtotal) * 100.0 }))

union(tables: [cpu, memory])
  |> keep(columns: ["_time", "entityId", "series", "_value"])
  |> sort(columns: ["_time"])
`;
  }

  async function queryInflux(flux) {
    const response = await fetch(`/api/influxdb/api/v2/query?org=${encodeURIComponent(state.config.metricsOrg)}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        query: flux,
        dialect: {
          annotations: [],
          delimiter: ",",
          header: true,
        },
      }),
    });

    if (!response.ok) {
      throw new Error(`InfluxDB query failed with HTTP ${response.status}.`);
    }

    return parseCsv(await response.text());
  }

  function parseCsv(rawCsv) {
    const lines = rawCsv
      .split(/\r?\n/)
      .filter((line) => line.length > 0 && !line.startsWith("#"));

    if (!lines.length) {
      return [];
    }

    const header = splitCsvLine(lines[0]);
    return lines.slice(1).map((line) => {
      const values = splitCsvLine(line);
      const row = {};
      header.forEach((column, index) => {
        row[column] = values[index] != null ? values[index] : "";
      });
      return row;
    });
  }

  function splitCsvLine(line) {
    const result = [];
    let current = "";
    let inQuotes = false;

    for (let index = 0; index < line.length; index += 1) {
      const char = line[index];
      if (char === '"') {
        if (inQuotes && line[index + 1] === '"') {
          current += '"';
          index += 1;
        } else {
          inQuotes = !inQuotes;
        }
        continue;
      }

      if (char === "," && !inQuotes) {
        result.push(current);
        current = "";
        continue;
      }

      current += char;
    }

    result.push(current);
    return result;
  }

  function normalizeSeriesMap(seriesMap) {
    const timestamps = new Set();

    seriesMap.forEach((points) => {
      points.forEach(([timestamp]) => {
        timestamps.add(timestamp);
      });
    });

    const sortedTimes = Array.from(timestamps).sort((left, right) => left - right);
    const timeIndex = new Map(sortedTimes.map((time, index) => [time, index]));
    const normalized = {
      timestamps: sortedTimes,
      series: {
        cpu: new Array(sortedTimes.length).fill(null),
        memory: new Array(sortedTimes.length).fill(null),
      },
    };

    seriesMap.forEach((points, seriesName) => {
      if (!(seriesName in normalized.series)) {
        return;
      }

      points.forEach(([timestamp, value]) => {
        const index = timeIndex.get(timestamp);
        normalized.series[seriesName][index] = value;
      });
    });

    return normalized;
  }

  function aggregateNodeMetrics(vms, vmMetrics, nodeNames) {
    const aggregateByNode = new Map();
    nodeNames.forEach((node) => {
      aggregateByNode.set(node, new Map());
    });

    vms.forEach((vm) => {
      const series = vmMetrics.get(String(vm.vmid));
      if (!series) {
        return;
      }

      if (!aggregateByNode.has(vm.node)) {
        aggregateByNode.set(vm.node, new Map());
      }

      const samples = aggregateByNode.get(vm.node);
      series.timestamps.forEach((timestamp, index) => {
        if (!samples.has(timestamp)) {
          samples.set(timestamp, { cpu: 0, memory: 0, count: 0 });
        }

        const sample = samples.get(timestamp);
        sample.cpu += Number(series.series.cpu[index] || 0);
        sample.memory += Number(series.series.memory[index] || 0);
        sample.count += 1;
      });
    });

    const result = new Map();
    aggregateByNode.forEach((samples, node) => {
      if (!samples.size) {
        return;
      }

      const timestamps = Array.from(samples.keys()).sort((left, right) => left - right);
      result.set(node, {
        timestamps,
        series: {
          cpu: timestamps.map((timestamp) => Math.min(100, samples.get(timestamp).cpu)),
          memory: timestamps.map((timestamp) => {
            const sample = samples.get(timestamp);
            return sample.count ? sample.memory / sample.count : null;
          }),
        },
      });
    });

    return result;
  }

  function renderDashboard() {
    updateToolbarState();

    if (!DOM.root) {
      return;
    }

    if (!state.vms.length) {
      renderError("No VMs returned by the Proxmox API.");
      return;
    }

    if (state.layout.mode === "flat") {
      renderFlatByPool();
      return;
    }

    if (window.innerWidth < TABLET_BREAKPOINT) {
      renderStackedPoolBands();
      return;
    }

    renderGridLayout(state.layout.orientation);
  }

  function renderGridLayout(orientation) {
    const pools = orderedPools();
    const nodes = configuredNodeNames(state.vms);
    const grouped = groupByPoolNode(state.vms, pools, nodes);
    const poolOnX = orientation !== "pool-y";

    const grid = document.createElement("div");
    grid.className = "dashboard-grid";
    grid.style.gridTemplateColumns = poolOnX
      ? `220px repeat(${pools.length}, minmax(0, 1fr))`
      : `220px repeat(${nodes.length}, minmax(0, 1fr))`;
    grid.style.gridTemplateRows = poolOnX
      ? `200px repeat(${nodes.length}, minmax(220px, auto))`
      : `200px repeat(${pools.length}, minmax(220px, auto))`;

    const totalCols = (poolOnX ? pools : nodes).length + 1; // +1 for header col
    const totalRows = (poolOnX ? nodes : pools).length + 1; // +1 for header row

    // Row-spanning outlines (one per side-axis item, extends across all columns)
    const sideAxis = poolOnX ? nodes : pools;
    sideAxis.forEach((item, rowIndex) => {
      const band = document.createElement("div");
      band.className = "grid-band grid-band-row";
      band.style.gridColumn = `1 / ${totalCols + 1}`;
      band.style.gridRow = String(rowIndex + 2);
      grid.appendChild(band);
    });

    // Column-spanning outlines (one per top-axis item, extends across all rows)
    const topAxis = poolOnX ? pools : nodes;
    topAxis.forEach((item, colIndex) => {
      const band = document.createElement("div");
      band.className = "grid-band grid-band-col";
      band.style.gridColumn = String(colIndex + 2);
      band.style.gridRow = `1 / ${totalRows + 1}`;
      grid.appendChild(band);
    });

    // Corner cell
    const corner = document.createElement("div");
    corner.className = "grid-corner";
    corner.style.gridColumn = "1";
    corner.style.gridRow = "1";
    corner.innerHTML = `<p>${poolOnX ? "Pool on X · Node on Y" : "Pool on Y · Node on X"}</p>`;
    grid.appendChild(corner);

    // Top axis headers
    topAxis.forEach((item, index) => {
      const header = poolOnX ? renderPoolHeader(item) : renderNodeHeader(item);
      header.style.gridColumn = String(index + 2);
      header.style.gridRow = "1";
      grid.appendChild(header);
    });

    // Side axis headers + cells
    sideAxis.forEach((item, rowIndex) => {
      const header = poolOnX ? renderNodeHeader(item) : renderPoolHeader(item);
      header.style.gridColumn = "1";
      header.style.gridRow = String(rowIndex + 2);
      grid.appendChild(header);

      const innerAxis = poolOnX ? pools : nodes;
      innerAxis.forEach((innerItem, columnIndex) => {
        const pool = poolOnX ? innerItem : item;
        const node = poolOnX ? item : innerItem;
        const items = grouped.get(pool) && grouped.get(pool).get(node) ? grouped.get(pool).get(node) : [];

        const cell = document.createElement("section");
        cell.className = "grid-cell";
        cell.style.gridColumn = String(columnIndex + 2);
        cell.style.gridRow = String(rowIndex + 2);

        if (!items.length) {
          cell.appendChild(document.createTextNode(""));
          grid.appendChild(cell);
          return;
        }

        const cellGrid = document.createElement("div");
        cellGrid.className = "cell-card-grid";
        const maxCores = Math.max(...items.map((vm) => vm.maxcpu), 1);
        items.forEach((vm) => {
          const card = renderVmCard(vm, true, false);
          const pct = Math.max(20, Math.round((vm.maxcpu / maxCores) * 100));
          card.style.width = pct + "%";
          cellGrid.appendChild(card);
        });
        cell.appendChild(cellGrid);
        grid.appendChild(cell);
      });
    });

    DOM.root.replaceChildren(grid);
    // Charts must be rendered after the grid is in the DOM so that
    // clientWidth is correct. Otherwise uPlot creates canvases at the
    // fallback width, and the browser CSS-scales them to fit, causing
    // line thickness to vary between cards.
    renderDeferredCharts();
  }

  function renderFlatByPool() {
    const pools = orderedPools();
    const wrapper = document.createElement("div");
    wrapper.className = "pool-band-list";

    pools.forEach((pool) => {
      const items = state.vms.filter((vm) => getPoolForVm(vm) === pool);
      const band = document.createElement("section");
      band.className = "pool-band";

      const heading = document.createElement("div");
      heading.className = "pool-band-heading";
      const title = document.createElement("h2");
      title.textContent = pool;
      title.style.color = getEntityColor("running", null);
      const meta = document.createElement("p");
      meta.textContent = `${items.length} VM${items.length === 1 ? "" : "s"}`;
      heading.append(title, meta);
      band.appendChild(heading);

      if (!items.length) {
        const empty = document.createElement("div");
        empty.className = "pool-band-empty";
        empty.textContent = "No VMs in this pool";
        band.appendChild(empty);
        wrapper.appendChild(band);
        return;
      }

      const cards = document.createElement("div");
      cards.className = "pool-band-cards";
      items.forEach((vm) => {
        cards.appendChild(renderVmCard(vm, false, true));
      });
      band.appendChild(cards);
      wrapper.appendChild(band);
    });

    DOM.root.replaceChildren(wrapper);
    renderDeferredCharts();
  }

  function renderStackedPoolBands() {
    const pools = orderedPools();
    const nodes = configuredNodeNames(state.vms);
    const grouped = groupByPoolNode(state.vms, pools, nodes);
    const wrapper = document.createElement("div");
    wrapper.className = "pool-band-list";

    pools.forEach((pool) => {
      const poolVmCount = state.vms.filter((vm) => getPoolForVm(vm) === pool).length;
      const band = document.createElement("section");
      band.className = "pool-band";

      const heading = document.createElement("div");
      heading.className = "pool-band-heading";
      const title = document.createElement("h2");
      title.textContent = pool;
      title.style.color = getEntityColor("running", null);
      const meta = document.createElement("p");
      meta.textContent = `${poolVmCount} VM${poolVmCount === 1 ? "" : "s"}`;
      heading.append(title, meta);
      band.appendChild(heading);

      nodes.forEach((node) => {
        const items = grouped.get(pool) && grouped.get(pool).get(node) ? grouped.get(pool).get(node) : [];
        if (!items.length) {
          return;
        }

        const row = document.createElement("div");
        row.className = "pool-band-row";

        const rowTitle = document.createElement("h3");
        const rowLink = makeEntityLink(node, () => openGrafanaNode(node));
        rowLink.classList.add("stacked-node-link");
        rowLink.style.color = getNodeLoadColor(node);
        rowTitle.appendChild(rowLink);

        const rowMeta = document.createElement("p");
        rowMeta.className = "pool-band-row-meta";
        rowMeta.textContent = `${nodeStatus(node)} · ${items.length} VM${items.length === 1 ? "" : "s"}`;

        const cards = document.createElement("div");
        cards.className = "pool-band-cards";
        items.forEach((vm) => {
          cards.appendChild(renderVmCard(vm, true, false));
        });

        row.append(rowTitle, rowMeta, cards);
        band.appendChild(row);
      });

      wrapper.appendChild(band);
    });

    DOM.root.replaceChildren(wrapper);
    renderDeferredCharts();
  }

  function orderedPools() {
    const configured = Array.isArray(state.config && state.config.pools) ? state.config.pools : [];
    const discovered = new Set(configured);
    const pools = [...configured];

    state.vms.forEach((vm) => {
      const pool = getPoolForVm(vm);
      if (!discovered.has(pool)) {
        discovered.add(pool);
        pools.push(pool);
      }
    });

    return pools;
  }

  function groupByPoolNode(vms, pools, nodes) {
    const grouped = new Map();

    pools.forEach((pool) => {
      const nodeMap = new Map();
      nodes.forEach((node) => {
        nodeMap.set(node, []);
      });
      grouped.set(pool, nodeMap);
    });

    vms.forEach((vm) => {
      const pool = getPoolForVm(vm);
      if (!grouped.has(pool)) {
        grouped.set(pool, new Map());
      }
      if (!grouped.get(pool).has(vm.node)) {
        grouped.get(pool).set(vm.node, []);
      }
      grouped.get(pool).get(vm.node).push(vm);
    });

    // Sort VMs within each cell by absolute CPU usage (cpu * maxcpu) descending,
    // so the busiest VMs appear at the top.
    grouped.forEach(function (nodeMap) {
      nodeMap.forEach(function (vmList) {
        vmList.sort(function (a, b) {
          return (b.cpu * b.maxcpu) - (a.cpu * a.maxcpu);
        });
      });
    });

    return grouped;
  }

  function getPoolForVm(vm) {
    const poolTag = (vm.tags || []).find((tag) => tag.startsWith("pool-"));
    return poolTag ? poolTag.replace(/^pool-/, "") : "unknown";
  }

  function nodeStatus(node) {
    const info = state.nodeStates.get(node);
    return (info && info.status) || "unknown";
  }

  function nodeMaxmem(node) {
    const info = state.nodeStates.get(node);
    return (info && info.maxmem) || 0;
  }

  // Chart height proportional to allocated RAM.
  // Minimum 60px for the smallest VMs (256MB), scales linearly.
  // maxRefBytes is the largest maxmem among siblings (VMs in the same
  // grid, or node RAM for node headers) so the tallest card gets
  // maxHeight and others scale relative to it.
  function formatMemPair(usedBytes, totalBytes) {
    const GB = 1073741824;
    const MB = 1048576;
    if (totalBytes >= GB) {
      return `${Math.round(usedBytes / GB)}/${Math.round(totalBytes / GB)}GB`;
    }
    return `${Math.round(usedBytes / MB)}/${Math.round(totalBytes / MB)}MB`;
  }

  function formatCpuPct(cpuFraction) {
    return `${Math.round(cpuFraction * 100)}%`;
  }

  function chartHeightForMem(maxmemBytes, maxRefBytes, maxHeight) {
    const MIN_HEIGHT = 40;
    if (!maxRefBytes || !maxmemBytes) {
      return MIN_HEIGHT;
    }
    const ratio = maxmemBytes / maxRefBytes;
    return Math.max(MIN_HEIGHT, Math.round(ratio * maxHeight));
  }

  function renderPoolHeader(pool) {
    const header = document.createElement("section");
    header.className = "axis-header";

    const title = document.createElement("h2");
    title.textContent = pool;
    title.style.color = getEntityColor("running", null);

    const meta = document.createElement("p");
    const count = state.vms.filter((vm) => getPoolForVm(vm) === pool).length;
    meta.textContent = `${count} VM${count === 1 ? "" : "s"} · Pool`;

    header.append(title, meta);
    return header;
  }

  function renderNodeHeader(node) {
    const header = document.createElement("section");
    header.className = "axis-header";

    // Single-line: node name (left, colored) + VM count (right, muted)
    const headerLine = document.createElement("div");
    headerLine.className = "entity-card-header";

    const title = makeEntityLink(node, () => openGrafanaNode(node));
    title.classList.add("entity-link--title");
    title.style.color = getNodeLoadColor(node);

    const nodeInfo = state.nodeStates.get(node) || {};
    const stats = document.createElement("span");
    stats.className = "entity-card-stats";
    const memStr = formatMemPair(nodeInfo.mem || 0, nodeInfo.maxmem || 0);
    const allocatedCores = state.vms
      .filter((vm) => vm.node === node)
      .reduce((sum, vm) => sum + vm.maxcpu, 0);
    const totalCores = nodeInfo.maxcpu || 1;
    const cpuStr = `${allocatedCores}/${totalCores} ${Math.round((nodeInfo.cpu || 0) * 100)}%`;
    const count = state.vms.filter((vm) => vm.node === node).length;
    stats.textContent = `${memStr} ${cpuStr} · ${count} VMs`;

    headerLine.append(title, stats);
    header.appendChild(headerLine);

    const chartMount = document.createElement("div");
    chartMount.className = "axis-chart";
    header.appendChild(chartMount);

    const maxNodeMem = Math.max(...configuredNodeNames(state.vms).map((n) => nodeMaxmem(n)), 1);
    const nodeHeight = chartHeightForMem(nodeMaxmem(node), maxNodeMem, AXIS_CHART_HEIGHT);
    chartMount.style.height = nodeHeight + "px";
    chartMount._deferredChart = { series: state.nodeMetrics.get(node), height: nodeHeight };
    return header;
  }

  // Largest maxmem across all current VMs, cached per render cycle.
  function maxVmMem() {
    let maxVal = 0;
    state.vms.forEach((vm) => {
      if (vm.maxmem > maxVal) {
        maxVal = vm.maxmem;
      }
    });
    return maxVal;
  }

  function renderVmCard(vm, compact, showNodeBadge) {
    const isRunning = String(vm.status).toLowerCase() === "running";
    const series = state.vmMetrics.get(String(vm.vmid));

    const card = document.createElement("article");
    card.className = "entity-card";
    if (compact) {
      card.classList.add("compact");
    }

    // Single-line header: name (left) + stats + id (right)
    const header = document.createElement("header");
    header.className = "entity-card-header";

    const title = makeEntityLink(vm.name, () => openGrafanaVm(vm));
    title.classList.add("entity-link--title");
    title.style.color = getVmLoadColor(vm);

    const stats = document.createElement("span");
    stats.className = "entity-card-stats";
    const memStr = formatMemPair(vm.mem, vm.maxmem);
    const cpuStr = `${vm.maxcpu}x${Math.round(vm.cpu * 100)}%`;
    stats.textContent = `${memStr} ${cpuStr}`;

    const idLabel = document.createElement("span");
    idLabel.className = "entity-card-id";
    idLabel.textContent = `id ${vm.vmid}`;

    if (showNodeBadge) {
      const badge = document.createElement("span");
      badge.className = "node-badge";
      badge.textContent = vm.node;
      header.append(title, badge, stats, idLabel);
    } else {
      header.append(title, stats, idLabel);
    }

    card.appendChild(header);

    const chartMount = document.createElement("div");
    chartMount.className = "entity-chart";
    const baseHeight = compact ? COMPACT_CHART_HEIGHT : CARD_CHART_HEIGHT;
    const height = chartHeightForMem(vm.maxmem, maxVmMem(), baseHeight);
    chartMount.style.height = height + "px";
    // Defer chart rendering until after the DOM is mounted so clientWidth
    // is correct and line thickness is uniform.
    chartMount._deferredChart = { series: series, height: height };
    card.appendChild(chartMount);

    return card;
  }

  function renderDeferredCharts() {
    // Find all chart mounts that have deferred data and render them now
    // that they're in the DOM with correct dimensions.
    const mounts = DOM.root.querySelectorAll(".entity-chart, .axis-chart");
    mounts.forEach(function (mount) {
      const deferred = mount._deferredChart;
      if (!deferred) return;
      delete mount._deferredChart;
      renderSeriesChart(mount, deferred.series, deferred.height);
    });
  }

  function drawMinuteGrid(container, timestamps) {
    if (!timestamps || timestamps.length < 2) return;

    const cw = container.clientWidth;
    const ch = container.clientHeight;
    if (!cw || !ch) return;

    const dpr = window.devicePixelRatio || 1;
    const canvas = document.createElement("canvas");
    canvas.width = cw * dpr;
    canvas.height = ch * dpr;
    canvas.style.width = cw + "px";
    canvas.style.height = ch + "px";
    canvas.style.position = "absolute";
    canvas.style.top = "0";
    canvas.style.left = "0";
    canvas.style.zIndex = "0";
    canvas.style.pointerEvents = "none";
    container.style.position = "relative";
    container.appendChild(canvas);

    const ctx = canvas.getContext("2d");
    ctx.scale(dpr, dpr);

    // uPlot padding is [0, 4, 0, 4] CSS pixels
    const padL = 4;
    const padR = 4;
    const plotLeft = padL;
    const plotRight = cw - padR;
    const plotWidth = plotRight - plotLeft;

    const xMin = timestamps[0];
    const xMax = timestamps[timestamps.length - 1];
    const xRange = xMax - xMin;
    if (xRange <= 0) return;

    const startSec = Math.ceil(xMin / 900) * 900;

    for (let t = startSec; t <= xMax; t += 900) {
      const frac = (t - xMin) / xRange;
      const x = plotLeft + frac * plotWidth;
      if (x < plotLeft || x > plotRight) continue;

      const m = new Date(t * 1000).getMinutes();
      const isHour = (m === 0);

      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, ch);
      ctx.strokeStyle = isHour ? "rgba(255,255,255,0.22)" : "rgba(255,255,255,0.11)";
      ctx.lineWidth = isHour ? 1.2 : 0.6;
      ctx.stroke();
    }
  }

  function renderSeriesChart(chartMount, series, chartHeight) {
    chartMount.replaceChildren();

    if (!series || !series.timestamps.length || !window.uPlot) {
      const empty = document.createElement("div");
      empty.className = "entity-card-empty";
      empty.textContent = "No data yet";
      chartMount.appendChild(empty);
      return;
    }

    const w = chartMount.clientWidth || 260;
    const h = chartHeight || CARD_CHART_HEIGHT;

    const chart = new window.uPlot(
      {
        width: w,
        height: h,
        legend: { show: false },
        cursor: { show: false },
        axes: [{ show: false }, { show: false }],
        padding: [0, 4, 0, 4],
        scales: {
          x: { time: true },
          y: {
            auto: false,
            range: function () {
              return [0, 100];
            },
          },
        },
        series: [
          {},
          {
            label: "CPU",
            stroke: CHART_COLORS.cpu,
            width: 1,
            points: { show: false },
          },
          {
            label: "Memory",
            stroke: CHART_COLORS.memory,
            width: 1,
            points: { show: false },
          },
        ],
      },
      [
        series.timestamps,
        series.series.cpu,
        series.series.memory,
      ],
      chartMount
    );

    // Draw vertical grid lines on a canvas behind the uPlot chart.
    // The vendored uPlot build doesn't support plugins/hooks.
    drawMinuteGrid(chartMount, series.timestamps);
  }

  function makeEntityLink(label, onClick) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "entity-link";
    button.textContent = label;
    button.addEventListener("click", onClick);
    return button;
  }

  function openGrafanaVm(vm) {
    const baseUrl = trimTrailingSlash(state.config && state.config.grafanaBaseUrl);
    const uid = state.config && state.config.grafanaVmDashboardUid;
    if (!baseUrl || !uid) {
      return;
    }

    window.open(
      `${baseUrl}/d/${encodeURIComponent(uid)}?var-vmid=${encodeURIComponent(String(vm.vmid))}`,
      "_blank",
      "noopener"
    );
  }

  function openGrafanaNode(node) {
    const baseUrl = trimTrailingSlash(state.config && state.config.grafanaBaseUrl);
    const uid = state.config && state.config.grafanaNodeDashboardUid;
    if (!baseUrl || !uid) {
      return;
    }

    window.open(
      `${baseUrl}/d/${encodeURIComponent(uid)}?var-node=${encodeURIComponent(node)}`,
      "_blank",
      "noopener"
    );
  }

  function trimTrailingSlash(value) {
    return String(value || "").replace(/\/+$/, "");
  }

  async function fetchJson(url) {
    const response = await fetch(url, {
      headers: {
        Accept: "application/json",
      },
    });

    if (!response.ok) {
      throw new Error(`${url} failed with HTTP ${response.status}.`);
    }

    return response.json();
  }

  function renderError(message) {
    if (!DOM.root) {
      return;
    }
    DOM.root.innerHTML = `<div class="empty-state">${message}</div>`;
  }

  function setStatus(message, mode) {
    if (!DOM.status) {
      return;
    }
    DOM.status.textContent = message;
    DOM.status.dataset.mode = mode;
  }

  // Color a VM name by its absolute CPU load (cpu * maxcpu) relative to
  // the highest-loaded VM in the cluster. Light blue (idle) → green →
  // yellow → red (busiest).
  function getVmLoadColor(vm) {
    if (String(vm.status).toLowerCase() !== "running") {
      return "hsl(0 0% 55%)";
    }

    const load = vm.cpu * vm.maxcpu;
    let maxLoad = 0;
    state.vms.forEach(function (v) {
      const l = v.cpu * v.maxcpu;
      if (l > maxLoad) maxLoad = l;
    });

    if (maxLoad <= 0) {
      return "hsl(200 70% 75%)"; // light blue fallback
    }

    // 0 = light blue (hue 200), 0.33 = green (120), 0.66 = yellow (60), 1.0 = red (0)
    const ratio = Math.min(load / maxLoad, 1);
    var hue;
    if (ratio <= 0.33) {
      // light blue (200) → green (120)
      hue = 200 - (ratio / 0.33) * 80;
    } else if (ratio <= 0.66) {
      // green (120) → yellow (60)
      hue = 120 - ((ratio - 0.33) / 0.33) * 60;
    } else {
      // yellow (60) → red (0)
      hue = 60 - ((ratio - 0.66) / 0.34) * 60;
    }

    return `hsl(${Math.round(hue)} 75% 65%)`;
  }

  // Color a node name by its absolute CPU load (cpu * maxcpu) relative to
  // the highest-loaded node. Same gradient as VM colors.
  function getNodeLoadColor(node) {
    const info = state.nodeStates.get(node);
    if (!info || String(info.status).toLowerCase() !== "online") {
      return "hsl(0 0% 55%)";
    }

    const load = (info.cpu || 0) * (info.maxcpu || 1);
    let maxLoad = 0;
    state.nodeStates.forEach(function (n) {
      const l = (n.cpu || 0) * (n.maxcpu || 1);
      if (l > maxLoad) maxLoad = l;
    });

    if (maxLoad <= 0) {
      return "hsl(200 70% 75%)";
    }

    const ratio = Math.min(load / maxLoad, 1);
    var hue;
    if (ratio <= 0.33) {
      hue = 200 - (ratio / 0.33) * 80;
    } else if (ratio <= 0.66) {
      hue = 120 - ((ratio - 0.33) / 0.33) * 60;
    } else {
      hue = 60 - ((ratio - 0.66) / 0.34) * 60;
    }

    return `hsl(${Math.round(hue)} 75% 65%)`;
  }

  function getEntityColor(status, series) {
    const normalized = String(status || "unknown").toLowerCase();
    if (normalized !== "running" && normalized !== "online") {
      return "hsl(0 0% 70%)";
    }

    const cpu = latestSeriesValue(series && series.series && series.series.cpu);
    const memory = latestSeriesValue(series && series.series && series.series.memory);
    const utilization = Math.max(cpu, memory, 0);

    if (!Number.isFinite(utilization)) {
      return "hsl(0 0% 70%)";
    }

    let hue;
    if (utilization <= 50) {
      hue = 120 - (utilization / 50) * 60;
    } else {
      hue = 60 - ((utilization - 50) / 50) * 60;
    }

    return `hsl(${Math.round(hue)} 82% 64%)`;
  }

  function latestSeriesValue(values) {
    if (!Array.isArray(values)) {
      return NaN;
    }

    for (let index = values.length - 1; index >= 0; index -= 1) {
      const value = Number(values[index]);
      if (Number.isFinite(value)) {
        return value;
      }
    }

    return NaN;
  }

  void init();
})();
