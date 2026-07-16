#!/usr/bin/env node
/**
 * clash-refresh-node
 *
 * Triggers a Clash/mihomo "Delay check" on a proxy group, then automatically
 * selects the lowest-latency node matching a filter (default: Japan nodes).
 *
 * It talks to the Clash external-controller REST API — the same API the web
 * dashboard uses — so it is far more robust than simulating browser clicks.
 *
 * Endpoints used:
 *   GET  /proxies                              list all proxies / groups
 *   GET  /group/:name/delay?url=&timeout=      "Delay check" the whole group (mihomo)
 *   GET  /proxies/:name/delay?url=&timeout=    fallback: test one node
 *   PUT  /proxies/:name   {"name": "<node>"}   select a node in a Selector group
 *
 * Usage:
 *   node index.js                              run once with config.json
 *   node index.js --watch                      keep refreshing on an interval
 *   node index.js --group Proxy --filter 日本   override settings via flags
 *   node index.js --dry-run                    test + report, but don't switch
 */

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Config loading: config.json  <  environment variables  <  CLI flags
// ---------------------------------------------------------------------------

const DEFAULTS = {
  controller: "http://127.0.0.1:9090",
  secret: "",
  group: "Proxy",
  filter: "日本|JP|Japan",
  exclude: "",
  testUrl: "http://www.gstatic.com/generate_204",
  timeout: 5000,
  maxDelay: 0, // 0 = no cap; otherwise ignore nodes slower than this (ms)
  watchInterval: 300, // seconds, used with --watch
  allowInsecureRemote: false,
};

function parseArgs(argv) {
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const key = a.slice(2);
    if (key === "watch" || key === "dry-run" || key === "help" || key === "h") {
      flags[key] = true;
    } else {
      const val = argv[i + 1];
      flags[key] = val;
      i++;
    }
  }
  return flags;
}

function compilePattern(value, label) {
  if (!value) return null;
  try {
    return new RegExp(value, "i");
  } catch (error) {
    throw new Error(`Invalid ${label} regular expression "${value}": ${error.message}`);
  }
}

export function filterNodes(nodes, filter, exclude = "") {
  const includePattern = compilePattern(filter, "filter");
  const excludePattern = compilePattern(exclude, "exclude");
  return nodes.filter((name) => {
    if (includePattern && !includePattern.test(name)) return false;
    if (excludePattern && excludePattern.test(name)) return false;
    return true;
  });
}

export function rankNodes(candidates, delays, maxDelay = 0) {
  return candidates
    .filter((name) => typeof delays[name] === "number" && delays[name] > 0)
    .map((name) => ({ name, delay: delays[name] }))
    .filter(({ delay }) => maxDelay <= 0 || delay <= maxDelay)
    .sort((a, b) => a.delay - b.delay || a.name.localeCompare(b.name));
}

export function validateController(controller, allowInsecureRemote = false) {
  let url;
  try {
    url = new URL(controller);
  } catch {
    throw new Error(`Invalid controller URL: ${controller}`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("controller must use http:// or https://");
  }
  const localHosts = new Set(["127.0.0.1", "localhost", "[::1]"]);
  if (url.protocol === "http:" && !localHosts.has(url.hostname) && !allowInsecureRemote) {
    throw new Error("Remote controllers must use HTTPS (or explicitly set allowInsecureRemote to true)");
  }
  return url.toString().replace(/\/+$/, "");
}

async function loadConfig(flags) {
  let fileCfg = {};
  try {
    const raw = await readFile(join(__dirname, "config.json"), "utf8");
    fileCfg = JSON.parse(raw);
  } catch {
    // config.json is optional
  }

  const env = {
    controller: process.env.CLASH_CONTROLLER,
    secret: process.env.CLASH_SECRET,
    group: process.env.CLASH_GROUP,
    filter: process.env.CLASH_FILTER,
  };

  const cfg = { ...DEFAULTS, ...fileCfg };
  for (const [k, v] of Object.entries(env)) if (v != null) cfg[k] = v;
  const cliAliases = {
    "test-url": "testUrl",
    "max-delay": "maxDelay",
    "watch-interval": "watchInterval",
  };
  for (const [rawKey, v] of Object.entries(flags)) {
    const k = cliAliases[rawKey] || rawKey;
    if (k === "watch" || k === "dry-run") continue;
    if (k === "keyword") {
      cfg.filter = String(v).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      continue;
    }
    cfg[k] = v;
  }

  // normalize numeric values that may arrive as strings from CLI/env
  cfg.timeout = Number(cfg.timeout);
  cfg.maxDelay = Number(cfg.maxDelay);
  cfg.watchInterval = Number(cfg.watchInterval);
  cfg.dryRun = !!flags["dry-run"];
  cfg.watch = !!flags.watch;
  if (!Number.isFinite(cfg.timeout) || cfg.timeout <= 0) throw new Error("timeout must be a positive number");
  if (!Number.isFinite(cfg.maxDelay) || cfg.maxDelay < 0) throw new Error("maxDelay must be zero or positive");
  if (!Number.isFinite(cfg.watchInterval) || cfg.watchInterval <= 0) throw new Error("watchInterval must be positive");
  cfg.controller = validateController(cfg.controller, cfg.allowInsecureRemote === true);
  return cfg;
}

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------

function authHeaders(cfg) {
  return cfg.secret ? { Authorization: `Bearer ${cfg.secret}` } : {};
}

async function api(cfg, path, options = {}) {
  const url = `${cfg.controller}${path}`;
  const res = await fetch(url, {
    ...options,
    headers: { ...authHeaders(cfg), ...(options.headers || {}) },
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`${options.method || "GET"} ${path} -> ${res.status} ${res.statusText} ${body}`);
  }
  const text = await res.text();
  return text ? JSON.parse(text) : {};
}

async function getProxies(cfg) {
  const data = await api(cfg, "/proxies");
  return data.proxies || {};
}

/** Trigger the "Delay check" for an entire group (mihomo). Returns { node: delayMs }. */
async function groupDelayCheck(cfg) {
  const q = new URLSearchParams({
    url: cfg.testUrl,
    timeout: String(cfg.timeout),
  });
  const path = `/group/${encodeURIComponent(cfg.group)}/delay?${q}`;
  return api(cfg, path); // { "<node>": 123, ... }  (failed nodes omitted)
}

/** Fallback for plain Clash: test each node one by one. */
async function perNodeDelayCheck(cfg, nodes) {
  const results = {};
  await Promise.all(
    nodes.map(async (node) => {
      const q = new URLSearchParams({ url: cfg.testUrl, timeout: String(cfg.timeout) });
      try {
        const r = await api(cfg, `/proxies/${encodeURIComponent(node)}/delay?${q}`);
        if (typeof r.delay === "number" && r.delay > 0) results[node] = r.delay;
      } catch {
        // unreachable node -> skip
      }
    }),
  );
  return results;
}

async function selectNode(cfg, node) {
  await api(cfg, `/proxies/${encodeURIComponent(cfg.group)}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: node }),
  });
}

// ---------------------------------------------------------------------------
// Core run
// ---------------------------------------------------------------------------

function ts() {
  return new Date().toLocaleTimeString();
}

async function runOnce(cfg) {
  const proxies = await getProxies(cfg);
  const group = proxies[cfg.group];
  if (!group) {
    throw new Error(`Group "${cfg.group}" not found. Available: ${Object.keys(proxies).join(", ")}`);
  }
  if (!Array.isArray(group.all) || group.all.length === 0) {
    throw new Error(`"${cfg.group}" is not a selectable group (no members).`);
  }

  // Determine candidate nodes within the group matching the filter.
  const candidates = filterNodes(group.all, cfg.filter, cfg.exclude);

  if (candidates.length === 0) {
    throw new Error(`No nodes in "${cfg.group}" match filter /${cfg.filter}/.`);
  }

  console.log(`[${ts()}] Delay check on "${cfg.group}" (${candidates.length} candidate node(s) match /${cfg.filter}/)...`);

  // Trigger the delay check. Prefer the group endpoint (mihomo); fall back to per-node.
  let delays = {};
  try {
    delays = await groupDelayCheck(cfg);
  } catch (e) {
    console.log(`[${ts()}] Group delay endpoint unavailable (${e.message.split("->")[0].trim()}); testing nodes individually...`);
    delays = await perNodeDelayCheck(cfg, candidates);
  }

  // Keep only matching candidates that returned a usable delay.
  const ranked = rankNodes(candidates, delays, cfg.maxDelay);

  if (ranked.length === 0) {
    console.warn(`[${ts()}] No reachable node matched the filter — leaving current selection unchanged.`);
    return null;
  }

  // Show the top few results.
  const top = ranked.slice(0, 5);
  for (const { name, delay } of top) {
    console.log(`           ${String(delay).padStart(5)} ms  ${name}`);
  }
  if (ranked.length > top.length) console.log(`           ... (${ranked.length - top.length} more)`);

  const best = ranked[0];
  if (group.now === best.name) {
    console.log(`[${ts()}] Already on the fastest node: ${best.name} (${best.delay} ms).`);
    return best;
  }

  if (cfg.dryRun) {
    console.log(`[${ts()}] [dry-run] Would switch ${group.now} -> ${best.name} (${best.delay} ms).`);
    return best;
  }

  await selectNode(cfg, best.name);
  console.log(`[${ts()}] ✓ Selected ${best.name} (${best.delay} ms)  [was: ${group.now}]`);
  return best;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const flags = parseArgs(process.argv.slice(2));
  if (flags.help || flags.h) {
    console.log(`clash-refresh-node — auto-select the fastest matching node

  node index.js                 run once (uses config.json)
  node index.js --watch         keep refreshing every <watchInterval> seconds
  node index.js --dry-run       report results without switching
  CLASH_SECRET=<token> node index.js --group Proxy --keyword "日本"
  node index.js --group Proxy --filter "日本|JP" --exclude "TEST|过期"

Store secrets in the ignored config.json when possible; command-line secrets can leak into shell history.
--keyword is a literal name match; --filter and --exclude accept regular expressions.
Config precedence: config.json < env (CLASH_CONTROLLER/SECRET/GROUP/FILTER) < CLI flags`);
    return;
  }

  const cfg = await loadConfig(flags);
  console.log(`Controller: ${cfg.controller}  Group: ${cfg.group}  Filter: /${cfg.filter}/`);

  if (!cfg.watch) {
    await runOnce(cfg);
    return;
  }

  console.log(`Watch mode: refreshing every ${cfg.watchInterval}s. Ctrl+C to stop.\n`);
  for (;;) {
    try {
      await runOnce(cfg);
    } catch (e) {
      console.error(`[${ts()}] Error: ${e.message}`);
    }
    console.log(`[${ts()}] Sleeping ${cfg.watchInterval}s...\n`);
    await sleep(cfg.watchInterval * 1000);
  }
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  main().catch((e) => {
    console.error(`Fatal: ${e.message}`);
    process.exit(1);
  });
}
