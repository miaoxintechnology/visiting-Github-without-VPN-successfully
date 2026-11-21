'use strict';
/*
 * 本地 SNI 剥离代理 v4
 *  - 浏览器 URL 不变（hosts 把被 SNI 阻断的域名指向 127.0.0.1）
 *  - 转发上游时「不发 SNI」，绕过 GFW 的 SNI 阻断
 *  - IP 池 + 健康度排序 + 自动故障转移
 *  - 重定向死循环自动检测换 IP
 *  - 补齐 CORS 响应头（默认 server block 缺这些头）
 *  - 大文件上传走流式转发（不缓冲、不截断）
 *  - 启用 gzip 压缩透传（GFW 限速严重，压缩能提速 5 倍）
 *  - 支持外部配置 proxy-config.json（域名 -> IP 池、证书路径）
 */
const https = require('https');
const fs = require('fs');
const path = require('path');

const LISTEN_HOST = '127.0.0.1';
const LOG = path.join(__dirname, 'proxy.log');

// ===== 外部配置（由 fix-github 脚本生成）=====
let CONFIG = null;
try {
  const p = path.join(__dirname, 'proxy-config.json');
  if (fs.existsSync(p)) CONFIG = JSON.parse(fs.readFileSync(p, 'utf8'));
} catch (e) { /* 用默认值 */ }

const LISTEN_PORT = (CONFIG && CONFIG.listenPort) || 443;

// ===== 证书：优先 PFX（PowerShell 生成），否则 PEM =====
function buildServerOptions() {
  if (CONFIG && CONFIG.pfx && fs.existsSync(path.join(__dirname, CONFIG.pfx))) {
    return { pfx: fs.readFileSync(path.join(__dirname, CONFIG.pfx)), passphrase: CONFIG.passphrase || '' };
  }
  if (CONFIG && CONFIG.cert && CONFIG.key &&
      fs.existsSync(path.join(__dirname, CONFIG.cert)) && fs.existsSync(path.join(__dirname, CONFIG.key))) {
    return {
      cert: fs.readFileSync(path.join(__dirname, CONFIG.cert)),
      key: fs.readFileSync(path.join(__dirname, CONFIG.key)),
    };
  }
  return {
    cert: fs.readFileSync(path.join(__dirname, 'cert.pem')),
    key: fs.readFileSync(path.join(__dirname, 'key.pem')),
  };
}

const SERVER_OPTIONS = buildServerOptions();
const CERT = SERVER_OPTIONS.cert || null;
const KEY = SERVER_OPTIONS.key || null;

const MAX_BUFFER = 1024 * 1024;      // 1MB 以内才缓冲（可重试）
const BODY_TIMEOUT = 180000;         // 大请求（上传）超时 3 分钟
const SMALL_TIMEOUT = 25000;

function log(msg) {
  const line = `[${new Date().toISOString()}] ${msg}`;
  console.log(line);
  try { fs.appendFileSync(LOG, line + '\n'); } catch (e) {}
}

// ===== IP 池 =====
// 注意：这些 IP 用于「无 SNI」转发，因此要选「无 SNI 可通」的 IP，
// 与 hosts 直连方案用的 IP 不一定相同。
//   github.com     : GFW 对 github.com 这个 SNI 做了针对性阻断，只能无 SNI 转发
//   .80.241        : Gravatar 根路径与静态资源都正常
//   .73.2          : 根路径会 302 到自身，放最后
//
// 若同目录存在 proxy-config.json 的 domains 字段，则优先使用外部配置：
//   { "domains": { "github.com": ["1.2.3.4", "5.6.7.8"], "gravatar.com": [...] } }
const DEFAULT_POOL = [
  ['github.com', ['140.82.113.20', '140.82.114.4', '140.82.114.20', '140.82.113.4', '140.82.116.20']],
  ['gravatar.com', ['192.0.80.241', '192.0.80.242', '192.0.80.239', '192.0.73.2']],
  ['wordpress.com', ['192.0.78.24', '192.0.78.25', '192.0.78.12', '192.0.78.13']],
  ['wp.com', ['192.0.78.24', '192.0.78.25']],
];
const IP_POOL = (CONFIG && CONFIG.domains && Object.keys(CONFIG.domains).length)
  ? Object.entries(CONFIG.domains).filter(([k, v]) => Array.isArray(v) && v.length)
  : DEFAULT_POOL;
const ALL_KNOWN_IPS = new Set();
for (const [, ips] of IP_POOL) ips.forEach((ip) => ALL_KNOWN_IPS.add(ip));

const health = new Map();
function score(ip) { return health.get(ip) || 0; }
function markOk(ip) { health.set(ip, Math.min((health.get(ip) || 0) + 1, 20)); }
function markFail(ip) { health.set(ip, Math.max((health.get(ip) || 0) - 1, -20)); }

function candidateIPs(hostname) {
  for (const [key, ips] of IP_POOL) {
    if (hostname === key || hostname.endsWith('.' + key)) {
      return ips.slice().sort((a, b) => score(b) - score(a));
    }
  }
  return null;
}

const dnsCache = new Map();
function resolveDoH(hostname) {
  if (dnsCache.has(hostname)) return Promise.resolve([dnsCache.get(hostname)]);
  return new Promise((resolve) => {
    const url = `https://doh.pub/dns-query?name=${encodeURIComponent(hostname)}&type=A`;
    const req = https.get(url, { headers: { accept: 'application/dns-json' }, timeout: 6000 }, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => {
        try {
          const j = JSON.parse(data);
          const ips = (j.Answer || []).filter((x) => x.type === 1).map((x) => x.data);
          if (ips.length) { dnsCache.set(hostname, ips[0]); resolve(ips); } else resolve([]);
        } catch (e) { resolve([]); }
      });
    });
    req.on('error', () => resolve([]));
    req.on('timeout', () => { req.destroy(); resolve([]); });
  });
}

function fixIPUrls(text, hostname) {
  return text.replace(/https?:\/\/\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?/g, `https://${hostname}`);
}

// 「重定向到自身」死循环检测
function isSelfLoop(status, location, hostname, reqUrl) {
  if (!location) return false;
  if (![301, 302, 303, 307, 308].includes(status)) return false;
  try {
    const loc = new URL(String(location), `https://${hostname}`);
    const cur = new URL(reqUrl, `https://${hostname}`);
    const sameHost = loc.hostname === hostname || ALL_KNOWN_IPS.has(loc.hostname);
    return sameHost && loc.pathname === cur.pathname && loc.search === cur.search;
  } catch (e) { return false; }
}

// 统一的响应头处理：清理逐跳头 + 补 CORS + 修 IP 形式 Location
function prepResponseHeaders(inHeaders, hostname, reqHeaders) {
  const out = Object.assign({}, inHeaders);
  delete out['transfer-encoding'];
  delete out['connection'];
  delete out['alt-svc'];
  if (out.location) out.location = fixIPUrls(String(out.location), hostname);

  const reqOrigin = reqHeaders.origin || reqHeaders.Origin;
  if (reqOrigin && !out['access-control-allow-origin']) {
    out['access-control-allow-origin'] = reqOrigin;
    out['access-control-allow-credentials'] = 'true';
    const vary = out['vary'];
    if (vary) {
      if (!String(vary).toLowerCase().includes('origin')) out['vary'] = String(vary) + ', Origin';
    } else {
      out['vary'] = 'Origin';
    }
  }
  if (!out['cross-origin-resource-policy']) out['cross-origin-resource-policy'] = 'cross-origin';
  return out;
}

// ---------- 模式A：小请求（缓冲 + 失败可重试）----------
function tryProxy(ip, hostname, hostHeader, method, url, headers, body, res) {
  return new Promise((resolve) => {
    let settled = false;
    const proxyReq = https.request({
      host: ip, port: 443, servername: '', rejectUnauthorized: false,
      method, path: url, headers, timeout: SMALL_TIMEOUT,
    }, (proxyRes) => {
      settled = true;
      const status = proxyRes.statusCode || 502;
      if (isSelfLoop(status, proxyRes.headers.location, hostname, url)) {
        markFail(ip);
        log(`LOOP ${hostname}${url} [${ip}] -> ${proxyRes.headers.location} (retry next IP)`);
        try { proxyRes.resume(); } catch (e) {}
        resolve(false);
        return;
      }
      markOk(ip);
      const ct = String(proxyRes.headers['content-type'] || '');
      const enc = String(proxyRes.headers['content-encoding'] || '').toLowerCase();
      const compressed = enc && enc !== 'identity';
      const outHeaders = prepResponseHeaders(proxyRes.headers, hostname, headers);
      const rewritable = !compressed && (ct.includes('text/html') || ct.includes('application/json') ||
                        ct.includes('text/css') || ct.includes('javascript'));

      if (rewritable) {
        delete outHeaders['content-encoding'];
        const chunks = [];
        proxyRes.on('data', (c) => chunks.push(c));
        proxyRes.on('end', () => {
          let text = Buffer.concat(chunks).toString('utf8');
          text = fixIPUrls(text, hostname);
          const buf = Buffer.from(text, 'utf8');
          outHeaders['content-length'] = String(buf.length);
          log(`${method} ${hostname}${url} -> ${status} [${ip}] rewrote ${buf.length}B`);
          try { res.writeHead(status, outHeaders); res.end(buf); } catch (e) {}
        });
        proxyRes.on('error', () => { try { res.destroy(); } catch (e) {} });
      } else {
        delete outHeaders['content-length'];
        log(`${method} ${hostname}${url} -> ${status} [${ip}] stream`);
        try { res.writeHead(status, outHeaders); proxyRes.pipe(res); } catch (e) {}
      }
      resolve(true);
    });
    proxyReq.on('timeout', () => proxyReq.destroy(new Error('upstream timeout')));
    proxyReq.on('error', (e) => {
      if (settled) return;
      markFail(ip);
      log(`FAIL ${hostname}${url} [${ip}] ${e.message}`);
      resolve(false);
    });
    if (body && body.length) proxyReq.write(body);
    proxyReq.end();
  });
}

// ---------- 模式B：大请求（流式转发，不缓冲不截断）----------
function streamProxy(ips, req, res, headers, hostname, hostHeader) {
  const attempt = (idx) => {
    if (idx >= ips.length) {
      log(`UPLOAD ALL FAILED ${hostname}${req.url}`);
      if (!res.headersSent) res.writeHead(502);
      try { res.end('all upstreams failed'); } catch (e) {}
      return;
    }
    const ip = ips[idx];
    let settled = false;
    let bytesIn = 0;
    req.on('data', (c) => { bytesIn += c.length; });

    const proxyReq = https.request({
      host: ip, port: 443, servername: '', rejectUnauthorized: false,
      method: req.method, path: req.url, headers, timeout: BODY_TIMEOUT,
    }, (proxyRes) => {
      settled = true;
      markOk(ip);
      const status = proxyRes.statusCode || 502;
      const outHeaders = prepResponseHeaders(proxyRes.headers, hostname, headers);
      if (!proxyRes.headers['content-encoding']) { /* 保持原样 */ }
      delete outHeaders['content-length'];
      log(`STREAM ${req.method} ${hostname}${req.url} -> ${status} [${ip}] sent=${bytesIn}B`);
      try { res.writeHead(status, outHeaders); proxyRes.pipe(res); } catch (e) {}
    });

    proxyReq.on('timeout', () => {
      proxyReq.destroy(new Error('upstream timeout'));
    });
    proxyReq.on('error', (e) => {
      if (settled) return;
      markFail(ip);
      log(`STREAM FAIL ${hostname}${req.url} [${ip}] ${e.message} (sent=${bytesIn}B)`);
      // 请求体已被消费，无法安全重试下一个 IP
      if (!res.headersSent) res.writeHead(502);
      try { res.end('upstream error: ' + e.message); } catch (err) {}
    });

    req.pipe(proxyReq);
  };
  attempt(0);
}

const server = https.createServer(SERVER_OPTIONS, async (req, res) => {
  const hostHeader = String(req.headers.host || '');
  const hostname = hostHeader.split(':')[0];
  if (!hostname) { res.writeHead(400); res.end('no host'); return; }

  const headers = Object.assign({}, req.headers);
  headers.host = hostHeader;
  // ★ 不再强制 identity：保留浏览器的 Accept-Encoding，让服务器 gzip 压缩。
  //   GFW 对无 SNI 连接限速严重（实测 15~20 KB/s），572KB 的首页不压缩要 30 秒；
  //   gzip 后约 100KB，5 秒左右就能下完，这是首页能打开的关键。
  //   （压缩内容的响应会走 else 分支流式转发，不做 body 改写）
  if (!headers['accept-encoding']) {
    headers['accept-encoding'] = 'gzip, deflate, br';
  }
  delete headers['alt-svc'];
  delete headers['connection'];

  // CORS 预检直接本地应答（服务器默认 block 不带 CORS 配置）
  if (req.method === 'OPTIONS' && (req.headers.origin || req.headers.Origin)) {
    const o = req.headers.origin || req.headers.Origin;
    res.writeHead(204, {
      'access-control-allow-origin': o,
      'access-control-allow-credentials': 'true',
      'access-control-allow-methods': 'GET, POST, PUT, DELETE, OPTIONS',
      'access-control-allow-headers': req.headers['access-control-request-headers'] || '*',
      'access-control-max-age': '86400',
      'cross-origin-resource-policy': 'cross-origin',
    });
    res.end();
    log(`OPTIONS(preflight) ${hostname}${req.url} -> 204 [cors answered locally]`);
    return;
  }

  let ips = candidateIPs(hostname);
  if (!ips) ips = await resolveDoH(hostname);
  if (!ips || !ips.length) {
    log(`RESOLVE FAIL ${hostname}`);
    res.writeHead(502); res.end('resolve failed'); return;
  }

  // 大 body（头像上传等）或 chunked -> 流式转发，避免缓冲截断导致服务器等超时
  const contentLength = parseInt(req.headers['content-length'] || '0', 10) || 0;
  const isChunked = String(req.headers['transfer-encoding'] || '').toLowerCase().includes('chunked');
  if (isChunked || contentLength > MAX_BUFFER) {
    log(`LARGE ${req.method} ${hostname}${req.url} content-length=${contentLength} chunked=${isChunked} -> streaming`);
    streamProxy(ips, req, res, headers, hostname, hostHeader);
    return;
  }

  // 小请求：缓冲后可重试
  const bodyChunks = [];
  req.on('data', (c) => bodyChunks.push(c));
  await new Promise((r) => { req.on('end', r); req.on('error', r); });
  const body = Buffer.concat(bodyChunks);

  for (const ip of ips) {
    const ok = await tryProxy(ip, hostname, hostHeader, req.method, req.url, headers, body, res);
    if (ok) return;
  }
  log(`ALL FAILED ${hostname}${req.url} (tried ${ips.join(',')})`);
  if (!res.headersSent) res.writeHead(502);
  try { res.end('all upstreams failed'); } catch (e) {}
});

server.on('clientError', (err, socket) => { try { socket.destroy(); } catch (e) {} });
server.listen(LISTEN_PORT, LISTEN_HOST, () => log(`SNI-strip proxy v3 listening on https://${LISTEN_HOST}:${LISTEN_PORT}`));
process.on('uncaughtException', (e) => log('UNCAUGHT: ' + e.message));
