'use strict';
/*
 * GitHub 本地加速代理 v6
 * ============================================================
 * 原理（与 v5 相同）：hosts 把 github.com 指向 127.0.0.1，本代理在 127.0.0.1:443
 * 上终结 TLS，再用「不带 SNI」的 TLS 连接上游 GitHub IP，从而绕过 SNI 阻断。
 *
 * v6 的改进：
 *   1. 上游证书默认严格校验：证书链（Node 内置根）+ 主机名。无 SNI 时 GitHub
 *      返回的仍是 github.com 证书，所以校验可以通过；全部 IP 校验失败才降级，
 *      并写 SECURITY 日志。
 *   2. 幂等请求（GET/HEAD）多 IP 并发竞速：第一个成功者胜出，其余丢弃。
 *      解决「某个 IP 挂起 10 秒 → 顺序重试 5 个 IP → 客户端先超时」的问题。
 *      非幂等请求（POST/PUT/PATCH/DELETE）仍顺序尝试，避免重复提交。
 *   3. 仅服务 proxy-config.json 里声明的域名（allowlist），未知 Host 返回 403，
 *      不做 DoH 解析、不访问任何第三方 —— 不再是可以被任意程序利用的开放转发。
 *   4. 日志脱敏：URL 的 query string 一律不落盘（OAuth code / token 不进日志）。
 *   5. 上游全挂时返回 502 + JSON（v5 返回 200 + 纯文本，导致客户端解析失败）。
 *   6. IP 健康度排序 + 记住上次成功的 IP（proxy-state.json）。
 *   7. 只监听 127.0.0.1；限制并发连接；日志 2MB 轮转。
 *
 * 口令：proxy-config.json 里没有明文口令。由 run-proxy.ps1 用 DPAPI 解密后
 *       通过环境变量 GH_ACCEL_PFX_PASS 传入。
 */
const https = require('https');
const tls = require('tls');
const fs = require('fs');
const path = require('path');

const VERSION = '6.1.0';
const BASE = __dirname;
const CONFIG_FILE = path.join(BASE, 'proxy-config.json');
const LOG_FILE = path.join(BASE, 'proxy.log');
const STATE_FILE = path.join(BASE, 'proxy-state.json');

const DEFAULTS = {
  listenPort: 443,
  listenHost: '127.0.0.1',
  pfx: null,
  cert: null,
  key: null,
  upstreamVerify: 'strict',     // strict | off
  allowDegraded: true,          // strict 全部失败后是否允许降级（会记 SECURITY 警告）
  maxBufferBytes: 1024 * 1024,
  maxRewriteBytes: 4 * 1024 * 1024,
  connectTimeoutMs: 10000,      // 顺序尝试（非幂等请求）的上游超时
  raceTimeoutMs: 7000,          // 并发竞速时单个尝试的超时
  raceConcurrency: 3,           // 并发竞速的 IP 数量
  bodyTimeoutMs: 180000,
  logMaxBytes: 2 * 1024 * 1024,
  maxConnections: 1024,
  domains: {},
};

function readJson(file) {
  try {
    let text = fs.readFileSync(file, 'utf8');
    if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1); // 容忍 UTF-8 BOM
    return JSON.parse(text);
  } catch (e) { return null; }
}

const CONFIG = Object.assign({}, DEFAULTS, readJson(CONFIG_FILE) || {});
const DOMAINS = Object.keys(CONFIG.domains || {});
const HEALTH_PATH = '/__gh_accel/health';
const IDEMPOTENT = new Set(['GET', 'HEAD', 'OPTIONS']);

// ---------------- 日志（脱敏 + 轮转） ----------------
let logLines = 0;
function rotateIfNeeded() {
  try {
    if (fs.statSync(LOG_FILE).size <= CONFIG.logMaxBytes) return;
    try { fs.renameSync(LOG_FILE, LOG_FILE + '.1'); } catch (e) { /* 占用中则清空 */ }
    try { fs.writeFileSync(LOG_FILE, ''); } catch (e) {}
  } catch (e) {}
}
function log(msg) {
  const line = `[${new Date().toISOString()}] ${msg}`;
  console.log(line);
  try {
    if ((++logLines % 50) === 1) rotateIfNeeded();
    fs.appendFileSync(LOG_FILE, line + '\n');
  } catch (e) {}
}
// 日志里绝不出现 query string（可能含 OAuth code / token）
function safePath(u) {
  if (typeof u !== 'string') return '/';
  const i = u.indexOf('?');
  const p = i >= 0 ? u.slice(0, i) : u;
  return p.length > 200 ? p.slice(0, 200) + '…' : p;
}

// ---------------- 证书 ----------------
function buildServerOptions() {
  const pfxPath = CONFIG.pfx ? path.join(BASE, CONFIG.pfx) : null;
  if (pfxPath && fs.existsSync(pfxPath)) {
    const pass = process.env.GH_ACCEL_PFX_PASS || CONFIG.passphrase || '';
    if (!pass) {
      log('FATAL 缺少 PFX 口令：请用 run-proxy.ps1 启动（它会解密 proxy-pass.dat）');
      process.exit(2);
    }
    return { pfx: fs.readFileSync(pfxPath), passphrase: pass };
  }
  const certPath = CONFIG.cert ? path.join(BASE, CONFIG.cert) : path.join(BASE, 'cert.pem');
  const keyPath = CONFIG.key ? path.join(BASE, CONFIG.key) : path.join(BASE, 'key.pem');
  if (fs.existsSync(certPath) && fs.existsSync(keyPath)) {
    return { cert: fs.readFileSync(certPath), key: fs.readFileSync(keyPath) };
  }
  log('FATAL 找不到服务器证书（proxy-cert.pfx）。请先运行 fix-github.ps1');
  process.exit(2);
}

// ---------------- 域名 allowlist ----------------
function domainFor(host) {
  for (const d of DOMAINS) {
    if (host === d || host.endsWith('.' + d)) return d;
  }
  return null;
}
function candidateIPs(host) {
  const d = domainFor(host);
  if (!d) return null;
  const ips = CONFIG.domains[d];
  return Array.isArray(ips) ? ips.slice() : [];
}
function configuredIPs() {
  const set = new Set();
  for (const d of DOMAINS) for (const ip of (CONFIG.domains[d] || [])) set.add(ip);
  return set;
}

// ---------------- 健康度 / 优先 IP ----------------
const CONFIGURED = configuredIPs();
const health = new Map();
const preferred = {};
const savedPreferred = (readJson(STATE_FILE) || {}).preferred || {};
for (const [host, ip] of Object.entries(savedPreferred)) {
  if (CONFIGURED.has(ip)) { preferred[host] = ip; health.set(ip, 5); }
}

let persistTimer = null;
function schedulePersist() {
  if (persistTimer) return;
  persistTimer = setTimeout(() => {
    persistTimer = null;
    try {
      fs.writeFileSync(STATE_FILE, JSON.stringify({ version: 1, preferred, updatedAt: new Date().toISOString() }, null, 2));
    } catch (e) {}
  }, 1500);
  if (persistTimer.unref) persistTimer.unref();
}
function score(ip) { return health.get(ip) || 0; }
function markOk(host, ip) {
  health.set(ip, Math.min((health.get(ip) || 0) + 2, 20));
  if (preferred[host] !== ip) { preferred[host] = ip; schedulePersist(); }
}
function markFail(ip) { health.set(ip, Math.max((health.get(ip) || 0) - 3, -20)); }

const stats = { startedAt: Date.now(), requests: 0, blocked: 0, failures: 0, degraded: 0, byStatus: {} };

// ---------------- 头处理 ----------------
const HOP_BY_HOP = new Set([
  'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'te', 'trailer', 'transfer-encoding', 'upgrade', 'alt-svc',
  'forwarded', 'via', 'x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto',
]);

function outboundHeaders(req, host) {
  const out = {};
  for (const [k, v] of Object.entries(req.headers)) {
    if (HOP_BY_HOP.has(k)) continue;
    if (k.startsWith('proxy-')) continue;
    out[k] = v;
  }
  out.host = host;
  // 不要替客户端注入 accept-encoding：客户端没要求压缩就不该收到压缩体
  // （否则 curl / 部分 HTTP 客户端会拿到 gzip 字节而解析失败）
  return out;
}

function responseHeaders(inHeaders, host) {
  const out = {};
  for (const [k, v] of Object.entries(inHeaders)) {
    if (HOP_BY_HOP.has(k)) continue;
    out[k] = v;
  }
  if (out.location) out.location = rewriteIPUrls(String(out.location), host);
  return out;
}

// 上游可能把绝对地址写成 IP，替换回域名
const IP_URL_RE = /https?:\/\/\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?/g;
function rewriteIPUrls(text, host) {
  return String(text).replace(IP_URL_RE, `https://${host}`);
}

function sendJson(res, status, obj, extraHeaders) {
  if (res.headersSent) { try { res.end(); } catch (e) {} return; }
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  try {
    res.writeHead(status, Object.assign({
      'content-type': 'application/json; charset=utf-8',
      'content-length': String(body.length),
      'cache-control': 'no-store',
    }, extraHeaders || {}));
    res.end(body);
  } catch (e) {}
}

// ---------------- 上游请求 ----------------
function upstreamOptions(ip, host, method, url, headers, verifyMode, timeoutMs) {
  const opts = {
    host: ip,
    port: 443,
    servername: '',            // 关键：不发 SNI，绕过针对 SNI 的阻断
    method,
    path: url,
    headers,
    timeout: timeoutMs,
  };
  if (verifyMode === 'strict') {
    opts.rejectUnauthorized = true;
    // Node 会以 IP 作为 host 调用本函数；这里改用真实域名做主机名校验
    opts.checkServerIdentity = (_h, cert) => tls.checkServerIdentity(host, cert);
  } else {
    opts.rejectUnauthorized = false;
  }
  return opts;
}

function isTlsError(e) {
  return !!(e && (
    e.code === 'ERR_TLS_CERT_ALTNAME_INVALID' ||
    e.code === 'UNABLE_TO_VERIFY_LEAF_SIGNATURE' ||
    e.code === 'SELF_SIGNED_CERT_IN_CHAIN' ||
    e.code === 'DEPTH_ZERO_SELF_SIGNED_CERT' ||
    e.code === 'CERT_HAS_EXPIRED' ||
    /certificate/i.test(e.message || '')
  ));
}

function canRewrite(headers) {
  const ct = String(headers['content-type'] || '');
  const enc = String(headers['content-encoding'] || 'identity').toLowerCase();
  if (enc && enc !== 'identity') return false;
  return /text\/html|application\/json|text\/css|javascript|text\/plain/i.test(ct);
}

function deliver(res, pres, host, ip, method, url, startedAt) {
  const status = pres.statusCode || 502;
  const outHeaders = responseHeaders(pres.headers, host);
  stats.byStatus[status] = (stats.byStatus[status] || 0) + 1;

  if (canRewrite(pres.headers)) {
    const chunks = [];
    let size = 0;
    pres.on('data', (c) => { size += c.length; chunks.push(c); });
    pres.on('end', () => {
      try {
        const buf = Buffer.concat(chunks);
        let body = buf;
        if (size <= CONFIG.maxRewriteBytes && buf.indexOf(0) === -1) {
          body = Buffer.from(rewriteIPUrls(buf.toString('utf8'), host), 'utf8');
        }
        delete outHeaders['content-encoding'];
        outHeaders['content-length'] = String(body.length);
        if (!res.headersSent) res.writeHead(status, outHeaders);
        res.end(method === 'HEAD' ? undefined : body);
      } catch (e) { try { res.destroy(); } catch (err) {} }
      log(`${method} ${host}${safePath(url)} -> ${status} [${ip}] ${Date.now() - startedAt}ms`);
    });
    pres.on('error', () => { try { res.destroy(); } catch (e) {} });
    return;
  }

  delete outHeaders['content-length'];
  if (!res.headersSent) res.writeHead(status, outHeaders);
  pres.pipe(res);
  log(`${method} ${host}${safePath(url)} -> ${status} [${ip}] stream ${Date.now() - startedAt}ms`);
}

// 单次尝试：成功返回 { ok:true, pres }, 失败返回 { ok:false, tls:bool }
function fetchUpstream(ip, host, method, url, headers, body, verifyMode, timeoutMs) {
  return new Promise((resolve) => {
    let settled = false;
    let opts;
    try {
      opts = upstreamOptions(ip, host, method, url, headers, verifyMode, timeoutMs);
    } catch (e) { resolve({ ok: false, tls: false, ip }); return; }

    const proxyReq = https.request(opts, (pres) => {
      settled = true;
      resolve({ ok: true, pres, ip });
    });

    proxyReq.on('timeout', () => proxyReq.destroy(Object.assign(new Error('upstream timeout'), { code: 'ETIMEDOUT' })));
    proxyReq.on('error', (e) => {
      if (settled) return;
      markFail(ip);
      const tlsErr = isTlsError(e);
      if (tlsErr) {
        log(`SECURITY 上游证书校验失败 ${host} [${ip}] ${e.code || e.message}${verifyMode === 'strict' ? '（换下一个 IP）' : ''}`);
      } else {
        log(`FAIL ${host}${safePath(url)} [${ip}] ${e.code || ''} ${e.message}`);
      }
      resolve({ ok: false, tls: tlsErr, ip });
    });

    if (body && body.length) proxyReq.write(body);
    proxyReq.end();
  });
}

// 在 IP 列表上尝试：concurrency=1 顺序；>1 并发竞速，第一个成功者胜出
function runAttempts(ips, host, method, url, headers, body, verifyMode, concurrency, timeoutMs) {
  return new Promise((resolve) => {
    let next = 0;
    let active = 0;
    let finished = false;
    let winner = null;
    let tlsFails = 0;

    const launch = () => {
      if (finished) return;
      if (next >= ips.length) {
        if (active === 0) resolve({ winner, tlsFails });
        return;
      }
      const ip = ips[next++];
      active++;
      fetchUpstream(ip, host, method, url, headers, body, verifyMode, timeoutMs).then((r) => {
        active--;
        if (finished) {
          if (r.ok && r.pres) { try { r.pres.destroy(); } catch (e) {} }
          if (!r.ok && r.tls) tlsFails++;
          return;
        }
        if (r.ok) {
          finished = true;
          winner = r;
          resolve({ winner, tlsFails });
          return;
        }
        if (r.tls) tlsFails++;
        launch();
      });
    };

    const n = Math.max(1, Math.min(concurrency, ips.length));
    for (let i = 0; i < n; i++) launch();
    if (ips.length === 0) resolve({ winner: null, tlsFails: 0 });
  });
}

// 流式（大请求）：不做失败重试，失败返回 502 JSON
function streamOnce(ip, host, req, res, headers, verifyMode) {
  return new Promise((resolve) => {
    const startedAt = Date.now();
    let settled = false;
    const opts = upstreamOptions(ip, host, req.method, req.url, headers, verifyMode, CONFIG.bodyTimeoutMs);
    const proxyReq = https.request(opts, (pres) => {
      settled = true;
      markOk(host, ip);
      const status = pres.statusCode || 502;
      stats.byStatus[status] = (stats.byStatus[status] || 0) + 1;
      const outHeaders = responseHeaders(pres.headers, host);
      delete outHeaders['content-length'];
      try {
        if (!res.headersSent) res.writeHead(status, outHeaders);
        pres.pipe(res);
      } catch (e) {}
      log(`STREAM ${req.method} ${host}${safePath(req.url)} -> ${status} [${ip}] ${Date.now() - startedAt}ms`);
      resolve(true);
    });
    proxyReq.on('timeout', () => proxyReq.destroy(Object.assign(new Error('upstream timeout'), { code: 'ETIMEDOUT' })));
    proxyReq.on('error', (e) => {
      if (settled) return;
      markFail(ip);
      log(`STREAM FAIL ${host}${safePath(req.url)} [${ip}] ${e.code || ''} ${e.message}`);
      resolve(false);
    });
    req.pipe(proxyReq);
  });
}

// ---------------- 请求入口 ----------------
async function handle(req, res) {
  stats.requests++;
  const hostHeader = String(req.headers.host || '');
  const host = hostHeader.split(':')[0].toLowerCase();

  if (!host) return sendJson(res, 400, { error: 'missing_host' });

  // 本机健康检查（仅 127.0.0.1 访问）
  if ((host === '127.0.0.1' || host === 'localhost') && req.url === HEALTH_PATH) {
    const domainInfo = {};
    for (const d of DOMAINS) domainInfo[d] = (CONFIG.domains[d] || []).length;
    const healthInfo = {};
    for (const [ip, s] of health) if (CONFIGURED.has(ip)) healthInfo[ip] = s;
    return sendJson(res, 200, {
      ok: true,
      version: VERSION,
      pid: process.pid,
      uptimeSec: Math.round((Date.now() - stats.startedAt) / 1000),
      listening: `${CONFIG.listenHost}:${CONFIG.listenPort}`,
      upstreamVerify: CONFIG.upstreamVerify,
      domains: domainInfo,
      stats,
      health: healthInfo,
    });
  }

  const domain = domainFor(host);
  if (!domain) {
    stats.blocked++;
    log(`BLOCK 未授权域名 ${host}${safePath(req.url)}`);
    return sendJson(res, 403, { error: 'host_not_allowed', host });
  }

  const allowedMethods = ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'];
  if (!allowedMethods.includes(req.method)) {
    return sendJson(res, 405, { error: 'method_not_allowed' }, { allow: allowedMethods.join(', ') });
  }

  // CORS 预检本地应答
  const origin = req.headers.origin;
  if (req.method === 'OPTIONS' && origin) {
    try {
      res.writeHead(204, {
        'access-control-allow-origin': origin,
        'access-control-allow-credentials': 'true',
        'access-control-allow-methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
        'access-control-allow-headers': req.headers['access-control-request-headers'] || '*',
        'access-control-max-age': '86400',
      });
      res.end();
    } catch (e) {}
    return;
  }

  const ips = candidateIPs(host).slice().sort((a, b) => score(b) - score(a)).slice(0, 12);
  if (!ips.length) {
    stats.failures++;
    return sendJson(res, 502, { error: 'no_upstream_configured', host });
  }

  const headers = outboundHeaders(req, host);
  const contentLength = parseInt(req.headers['content-length'] || '0', 10) || 0;
  const isChunked = String(req.headers['transfer-encoding'] || '').toLowerCase().includes('chunked');
  const isStream = isChunked || contentLength > CONFIG.maxBufferBytes;

  // ---- 大请求：流式，单次尝试，失败 502 ----
  if (isStream) {
    const primary = CONFIG.upstreamVerify === 'strict' ? 'strict' : 'off';
    const ok = await streamOnce(ips[0], host, req, res, headers, primary);
    if (!ok) {
      stats.failures++;
      sendJson(res, 502, { error: 'upstream_unavailable', host }, { 'retry-after': '5' });
    }
    return;
  }

  // ---- 小请求：缓冲后可在多个 IP 之间竞速 / 重试 ----
  const chunks = [];
  let size = 0;
  try {
    for await (const chunk of req) {
      size += chunk.length;
      if (size > CONFIG.maxBufferBytes) throw new Error('body_too_large');
      chunks.push(chunk);
    }
  } catch (e) {
    return sendJson(res, 413, { error: 'request_too_large' });
  }
  const body = Buffer.concat(chunks);
  const startedAt = Date.now();
  const idempotent = IDEMPOTENT.has(req.method);
  const concurrency = idempotent ? Math.max(1, Number(CONFIG.raceConcurrency) || 3) : 1;
  const timeoutMs = idempotent ? Math.max(1000, Number(CONFIG.raceTimeoutMs) || 7000) : CONFIG.connectTimeoutMs;

  const strictFirst = CONFIG.upstreamVerify === 'strict';
  if (strictFirst) {
    const r = await runAttempts(ips, host, req.method, req.url, headers, body, 'strict', concurrency, timeoutMs);
    if (r.winner) {
      markOk(host, r.winner.ip);
      deliver(res, r.winner.pres, host, r.winner.ip, req.method, req.url, startedAt);
      return;
    }
    if (!r.tlsFails || !CONFIG.allowDegraded) {
      stats.failures++;
      return sendJson(res, 502, {
        error: r.tlsFails ? 'upstream_tls_verification_failed' : 'upstream_unavailable', host,
      }, { 'retry-after': '5' });
    }
    // 降级：不校验证书，保证可用性，但记录安全警告
    stats.degraded++;
    log(`SECURITY 降级：${host} 所有 IP 证书校验均失败，改用不校验模式（本次请求）`);
    const r2 = await runAttempts(ips, host, req.method, req.url, headers, body, 'off', concurrency, timeoutMs);
    if (r2.winner) {
      markOk(host, r2.winner.ip);
      deliver(res, r2.winner.pres, host, r2.winner.ip, req.method, req.url, startedAt);
      return;
    }
  } else {
    const r = await runAttempts(ips, host, req.method, req.url, headers, body, 'off', concurrency, timeoutMs);
    if (r.winner) {
      markOk(host, r.winner.ip);
      deliver(res, r.winner.pres, host, r.winner.ip, req.method, req.url, startedAt);
      return;
    }
  }

  stats.failures++;
  log(`ALL FAILED ${host}${safePath(req.url)} (tried ${ips.join(',')}) ${Date.now() - startedAt}ms`);
  sendJson(res, 502, { error: 'upstream_unavailable', host, tried: ips.length }, { 'retry-after': '5' });
}

const serverOptions = buildServerOptions();
const server = https.createServer(serverOptions, (req, res) => {
  handle(req, res).catch((e) => {
    log(`HANDLER ERROR ${e && e.message}`);
    try { sendJson(res, 500, { error: 'internal_error' }); } catch (err) {}
  });
});
server.maxConnections = CONFIG.maxConnections;
server.headersTimeout = 30000;
server.on('tlsClientError', (e) => log(`TLS 客户端握手失败：${e.message}`));
server.on('clientError', (e, socket) => { try { socket.destroy(); } catch (err) {} });

server.listen(CONFIG.listenPort, CONFIG.listenHost, () => {
  log(`GitHub 加速代理 v${VERSION} 已启动 https://${CONFIG.listenHost}:${CONFIG.listenPort}`);
  log(`  允许域名：${DOMAINS.join(', ') || '(空)'}`);
  log(`  上游校验：${CONFIG.upstreamVerify}（降级回退：${CONFIG.allowDegraded ? '开' : '关'}）`);
  log(`  幂等请求竞速：${CONFIG.raceConcurrency} 路 / 单次 ${CONFIG.raceTimeoutMs}ms`);
  for (const d of DOMAINS) log(`  ${d}: ${(CONFIG.domains[d] || []).length} 个 IP`);
});

function shutdown(sig) {
  log(`收到 ${sig}，正在关闭...`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('uncaughtException', (e) => { log('UNCAUGHT ' + (e && e.stack || e)); process.exit(1); });
process.on('unhandledRejection', (e) => { log('UNHANDLED ' + (e && e.stack || e)); });
