#!/usr/bin/env node
import { spawn, execFile } from 'node:child_process';
import { mkdirSync, appendFileSync, readFileSync, writeFileSync, renameSync, existsSync, readdirSync, realpathSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { homedir, hostname, networkInterfaces } from 'node:os';
import { createSocket } from 'node:dgram';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);
const HERE = dirname(realpathSync(fileURLToPath(import.meta.url)));
const DATA = join(homedir(), '.wifimom');
const LOGS = process.env.WIFIMOM_LOGS || join(DATA, 'logs');
const SURVEY = join(DATA, 'survey.json');
const SURVEY_MAX = 20 * 1024 * 1024;
const DEVICES = join(DATA, 'devices.json');
const SPEED = join(DATA, 'speed.json'); // замеры скорости — между запусками
const SPEED_AUTO = [0, 3600, 3 * 3600, 6 * 3600]; // допустимые интервалы автозамера, с
const ROUTER_META = join(DATA, 'router.json'); // только логин; пароль — в связке ключей
const KC_SERVICE = 'wifimom.router';
const LAN_EVERY_MS = 60_000;
const OUI = join(DATA, 'oui.csv');
const OUI_URL = 'https://standards-oui.ieee.org/oui/oui.csv';
const OUI_MAX_AGE_MS = 90 * 24 * 3600_000;

const WINDOW = 10;
const BAD_LOSS = 2;
const BAD_RTT = { gw: 60, net: 200 };
const WIFI_EVERY_MS = 30_000;
const END_CLEAN_MS = 5_000; // сбой закрываем после 5 с без проблем — иначе один сбой мигает десятком «по 1 с»
const DOWN_RUN = 3; // столько пакетов подряд без ответа — уже не потери, а обрыв
const WEAK_SIGNAL = -72;
const KEEP_TICKS = 6 * 3600;
const PORT = 7357;

const pad = (n) => String(n).padStart(2, '0');
const clock = (d = new Date()) => `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
const stamp = (d = new Date()) =>
  `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}_${pad(d.getHours())}-${pad(d.getMinutes())}`;

function pct(sorted, p) {
  if (!sorted.length) return null;
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];
}

async function gateway() {
  const { stdout } = await run('route', ['-n', 'get', 'default']);
  return stdout.match(/gateway:\s*(\S+)/)?.[1];
}

async function wifiInfo() {
  try {
    const { stdout } = await run('system_profiler', ['SPAirPortDataType'], { timeout: 15_000 });
    const cur = stdout.split('Current Network Information:')[1]?.split('Other Local Wi-Fi Networks')[0] || '';
    const ssid = cur.match(/^\s+(.+?):\s*$/m)?.[1] ?? '?';
    const channel = cur.match(/Channel:\s*([^\n]+)/)?.[1]?.trim() ?? '?';
    const [, signal, noise] = cur.match(/Signal \/ Noise:\s*(-?\d+) dBm \/ (-?\d+) dBm/) || [];
    const rate = cur.match(/Transmit Rate:\s*(\d+)/)?.[1];
    return { ssid, channel, signal: Number(signal) || null, noise: Number(noise) || null, rate: Number(rate) || null };
  } catch {
    return null;
  }
}

// Собираем rf.swift один раз (и заново, если исходник новее). Без swiftc — живём без быстрого сигнала.
async function rfBinary() {
  const src = join(HERE, 'rf.swift');
  const bin = join(DATA, 'bin', 'rf');
  try {
    if (!existsSync(bin) || statSync(bin).mtimeMs < statSync(src).mtimeMs) {
      mkdirSync(dirname(bin), { recursive: true });
      await run('swiftc', ['-O', src, '-o', bin], { timeout: 180_000 });
    }
    return bin;
  } catch {
    return null;
  }
}

const ip2n = (ip) => ip.split('.').reduce((a, b) => a * 256 + Number(b), 0);
const n2ip = (n) => [24, 16, 8, 0].map((s) => (n >>> s) & 255).join('.');
const maskOf = (bits) => (bits ? (~0 << (32 - bits)) >>> 0 : 0);
const netOf = (ip, bits) => (ip2n(ip) & maskOf(bits)) >>> 0; // >>> 0: побитовые операции в JS знаковые
const normMac = (m) => m.toLowerCase().split(':').map((x) => x.padStart(2, '0')).join(':');
// Бит «локально назначенный» в первом байте: так телефоны и ноутбуки прячут настоящий MAC.
const isPrivateMac = (m) => (parseInt(m.slice(0, 2), 16) & 2) === 2;

function lanInterface(gw) {
  for (const [name, addrs] of Object.entries(networkInterfaces())) {
    for (const a of addrs || []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      const bits = Number(a.cidr.split('/')[1]);
      if (netOf(a.address, bits) === netOf(gw, bits)) return { name, ip: a.address, mac: normMac(a.mac), bits };
    }
  }
  return null;
}

// UDP-пакет на каждый адрес подсети заставляет Mac спросить по ARP «кто это». Отвечают все, кто в сети,
// даже с закрытым ping. Пакет уходит в порт discard (9) и никому не мешает. Записи ARP в macOS живут
// ~2 минуты, так что пропавшее устройство исчезает из таблицы само. Подсеть больше /24 сканируем только вокруг себя.
async function arpNeighbors(iface) {
  const bits = Math.max(iface.bits, 24);
  const net = netOf(iface.ip, bits);
  const hosts = 2 ** (32 - bits) - 2;
  const sock = createSocket('udp4');
  sock.on('error', () => {});
  await Promise.all(Array.from({ length: hosts }, (_, i) =>
    new Promise((r) => sock.send(Buffer.alloc(1), 9, n2ip(net + i + 1), () => r()))));
  await new Promise((r) => setTimeout(r, 2500));
  sock.close();
  const { stdout } = await run('arp', ['-an', '-i', iface.name]);
  const seen = new Map();
  for (const l of stdout.split('\n')) {
    const [, ip, mac] = l.match(/\((\d+\.\d+\.\d+\.\d+)\) at ([0-9a-f:]+) /i) || [];
    if (!mac || netOf(ip, bits) !== net || ip2n(ip) === net + hosts + 1) continue;
    const m = normMac(mac);
    if (parseInt(m.slice(0, 2), 16) & 1) continue; // широковещательные и multicast
    seen.set(m, ip);
  }
  return seen;
}

// ---------- Производитель по MAC ----------
// Первые 3 байта настоящего MAC — номер производителя в реестре IEEE. Реестр (~4 МБ) качаем один раз,
// дальше ищем локально: наружу адреса устройств не уходят. У частных (случайных) адресов производителя нет.
const vendors = new Map();

function csvFields(line, n) {
  const out = [];
  let i = 0;
  while (out.length < n && i <= line.length) {
    if (line[i] === '"') {
      let v = '', j = i + 1;
      for (;;) {
        const q = line.indexOf('"', j);
        if (q < 0) { v += line.slice(j); i = line.length + 1; break; }
        v += line.slice(j, q);
        if (line[q + 1] === '"') { v += '"'; j = q + 2; } else { i = q + 2; break; }
      }
      out.push(v);
    } else {
      const c = line.indexOf(',', i);
      const e = c < 0 ? line.length : c;
      out.push(line.slice(i, e));
      i = e + 1;
    }
  }
  return out;
}

function loadVendors() {
  vendors.clear();
  for (const line of readFileSync(OUI, 'utf8').split('\n')) {
    const [reg, hex, org] = csvFields(line, 3);
    if (reg === 'MA-L' && /^[0-9A-F]{6}$/.test(hex) && org) vendors.set(hex, org.trim());
  }
  return vendors.size;
}

async function ensureVendors() {
  const fresh = existsSync(OUI) && Date.now() - statSync(OUI).mtimeMs < OUI_MAX_AGE_MS;
  if (!fresh) {
    try {
      // Сервер IEEE медленный: ~4 МБ идут минуту-полторы. Качаем в фоне, мониторингу это не мешает.
      const r = await fetch(OUI_URL, { signal: AbortSignal.timeout(300_000) });
      if (!r.ok) throw new Error(r.status);
      const text = await r.text();
      if (!text.startsWith('Registry,')) throw new Error('format');
      mkdirSync(DATA, { recursive: true });
      writeFileSync(OUI + '.tmp', text);
      renameSync(OUI + '.tmp', OUI);
    } catch {
      if (!existsSync(OUI)) return 0; // без справочника просто не будет колонки «производитель»
    }
  }
  try { return loadVendors(); } catch { return 0; }
}

const shortVendor = (org) => {
  let s = org;
  for (let k = 0; k < 4; k++) {
    s = s.replace(/[\s,.]+(co\.?,?\s*ltd\.?|ltd\.?|inc\.?|corporation|corp\.?|limited|gmbh|llc|s\.?a\.?s?|b\.?v\.?|ag|co\.?|company|technology|technologies|electronics?|international|group)$/i, '');
  }
  return s.trim() || org;
};

// Что за устройство, по производителю. Только подсказка: один производитель делает разное.
const KINDS = [
  [/midea|gree electric|daikin|haier|\baux\b|ballu|hisense.*air|electrolux/i, 'кондиционер или бытовая техника'],
  [/espressif/i, 'умное устройство (розетка, лампа, датчик)'],
  [/tuya/i, 'умный дом (Tuya)'],
  [/xiaomi|yeelink|lumi united|roborock|dreame/i, 'Xiaomi: телефон или умный дом'],
  [/yandex/i, 'Яндекс Станция или ТВ'],
  [/sberdevices|salute/i, 'Сбер: колонка или SberBox'],
  [/apple/i, 'техника Apple'],
  [/samsung/i, 'Samsung: телефон, ТВ или техника'],
  [/lg electronics|lg innotek/i, 'LG: ТВ или техника'],
  [/sony interactive/i, 'PlayStation'],
  [/sony/i, 'Sony: ТВ или техника'],
  [/nintendo|valve/i, 'игровая приставка'],
  [/microsoft/i, 'Microsoft: Xbox или ноутбук'],
  [/amazon/i, 'Amazon: колонка Echo или Fire TV'],
  [/google/i, 'Google: колонка или Chromecast'],
  [/sonos/i, 'колонка Sonos'],
  [/roku|nvidia/i, 'ТВ-приставка'],
  [/hewlett|\bhp inc|canon|seiko epson|brother industries|kyocera|xerox|pantum/i, 'принтер'],
  [/hikvision|dahua|ezviz|imou|reolink|arlo|ring llc/i, 'камера'],
  [/signify|philips lighting/i, 'освещение Philips Hue'],
  [/raspberry/i, 'Raspberry Pi'],
  [/huawei|zte|honor device/i, 'телефон или роутер'],
  [/tp-link|zyxel|keenetic|mikrotik|routerboard|netgear|asustek|d-link|tenda|mercusys|ubiquiti|sercomm|arcadyan|sagemcom|sichuan jiuzhou|eltex|qtech|\bsnr\b|netis/i, 'роутер, ретранслятор или приставка провайдера'],
  [/intel|realtek|azurewave|liteon|lite-on|murata|qualcomm|mediatek|broadcom|universal global|hon hai|foxconn|chicony/i, 'ноутбук, ПК или ТВ (сетевой модуль)'],
];
const kindOfVendor = (org) => KINDS.find(([re]) => re.test(org))?.[1] ?? null;

function vendorOf(mac) {
  if (isPrivateMac(mac)) return null;
  const org = vendors.get(mac.replace(/:/g, '').slice(0, 6).toUpperCase());
  return org ? { vendor: shortVendor(org), vendorFull: org, kind: kindOfVendor(org) } : null;
}

function readJson(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; }
}
function writeJson(path, doc) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path + '.tmp', JSON.stringify(doc));
  renameSync(path + '.tmp', path);
}

function notify(title, text) {
  execFile('osascript', ['-e', `display notification ${JSON.stringify(text)} with title ${JSON.stringify(title)}`], () => {});
}

const KIND = { lag: 'задержка', loss: 'теряются пакеты', down: 'связь пропадала' };
const RANK = { lag: 0, loss: 1, down: 2 };

const incTitle = (inc) => `${inc.where === 'wifi' ? 'Wi-Fi' : 'провайдер'}: ${KIND[inc.kind]}`;

function incDetails(inc) {
  const k = inc.where === 'wifi' ? 'gw' : 'net';
  const out = [];
  if (inc[k + 'Peak'] != null) out.push(`задержка до ${Math.round(inc[k + 'Peak'])} мс`);
  if (inc[k + 'Lost']) out.push(`потеряно пакетов: ${inc[k + 'Lost']}`);
  if (inc.where === 'wifi' && inc.sigMin != null) out.push(`сигнал ${String(inc.sigMin).replace('-', '−')} dBm`);
  return out.join(', ');
}

// Догадка о причине — по тому, что видно с Mac. Это подсказка, а не диагноз.
function incHint(inc) {
  if (inc.where === 'isp') return 'до роутера всё было в порядке — дело у провайдера или в самом роутере';
  if (inc.roam) return 'Mac в этот момент переключался между точками доступа (роутер ↔ ретранслятор)';
  if (inc.sigMin != null && inc.sigMin < WEAK_SIGNAL) return 'слабый сигнал — далеко от точки доступа или мешают стены';
  if (inc.sigMin != null) return 'сигнал хороший, так что дело не в расстоянии: помехи или загруженный канал, перегруз роутера/ретранслятора либо фоновая активность Mac (AirDrop, Handoff)';
  return '';
}

const WHERE = {
  wifi: 'Wi-Fi (мак ↔ ретранслятор ↔ роутер)',
  isp: 'провайдер / интернет за роутером',
};

function monitor({ quiet, gw }) {
  const dir = join(LOGS, stamp());
  mkdirSync(dir, { recursive: true });
  const pingsCsv = join(dir, 'pings.csv');
  const wifiCsv = join(dir, 'wifi.csv');
  const eventsLog = join(dir, 'events.log');
  appendFileSync(pingsCsv, 'ts,target,rtt_ms\n');
  appendFileSync(wifiCsv, 'ts,ssid,channel,signal,noise,rate\n');
  const rfCsv = join(dir, 'rf.csv');
  appendFileSync(rfCsv, 'ts,signal,noise,rate,channel\n');

  const state = { gw: { win: [], fresh: false, latest: null }, net: { win: [], fresh: false, latest: null } };
  const history = { started: Date.now(), dir, ticks: [], wifi: [], events: [], incidents: [] };
  const listeners = new Set();
  let wifi = null;
  let rf = null;
  let lastRoam = 0;
  let cleanSince = null;
  const runLost = { gw: 0, net: 0 };
  // Устройства: mac → { first, last, ip, name? } — помним между запусками, чтобы подписи не терялись.
  const firstRun = !existsSync(DEVICES);
  const known = readJson(DEVICES) || {};
  const online = new Map(); // mac → с какого момента в сети (за этот запуск)
  let self = lanInterface(gw);
  let scanned = false; // до первой проверки не знаем, кто в сети, — не врём «не видно»
  let incident = null;
  let holdUntil = 0; // во время замера скорости канал забит нарочно — новые сбои не открываем

  const emit = (msg) => {
    for (const fn of listeners) fn(msg);
  };

  const event = (kind, text) => {
    const e = { t: Date.now(), kind, text };
    history.events.push(e);
    appendFileSync(eventsLog, `${clock()} ${text}\n`);
    if (!quiet) process.stdout.write(`\r\x1b[K${clock()} ${text}\n`);
    emit({ type: 'event', e });
  };

  const record = (key, rtt) => {
    appendFileSync(pingsCsv, `${Date.now()},${key},${rtt ?? ''}\n`);
    const s = state[key];
    s.win.push(rtt);
    if (s.win.length > WINDOW) s.win.shift();
    s.latest = rtt;
    s.fresh = true;
  };

  const startPing = (key, host) => {
    const p = spawn('ping', ['-i', '1', host]);
    let buf = '';
    p.stdout.on('data', (chunk) => {
      buf += chunk;
      const lines = buf.split('\n');
      buf = lines.pop();
      for (const l of lines) {
        const t = l.match(/time=([\d.]+) ms/);
        if (t) record(key, Number(t[1]));
        else if (/Request timeout|No route|Host is down/.test(l)) record(key, null);
      }
    });
    p.stderr.on('data', (chunk) => {
      if (/No route|Network is unreachable|sendto/.test(String(chunk))) record(key, null);
    });
    return p;
  };

  const startRf = (bin) => {
    const p = spawn(bin);
    let buf = '';
    p.stdout.on('data', (chunk) => {
      buf += chunk;
      const lines = buf.split('\n');
      buf = lines.pop();
      for (const l of lines) {
        const [t, sig, noise, rate, ch] = l.trim().split(/\s+/).map(Number);
        if (!t) continue;
        const prevCh = rf?.ch;
        rf = Number.isFinite(sig) ? { t, sig, noise, rate, ch } : null;
        // Канал сменился — Mac перешёл на другую точку доступа. Имя сети перечитываем только тут:
        // system_profiler сканирует эфир, и это само по себе даёт скачки задержки.
        if (rf && prevCh && ch && prevCh !== ch) {
          lastRoam = t;
          if (incident) incident.roam = true;
          sampleWifi();
        }
        if (rf) appendFileSync(rfCsv, `${t},${sig},${noise},${rate},${ch}\n`);
      }
    });
    return p;
  };

  const deviceList = () => Object.entries(known).map(([mac, k]) => ({
    mac, ...k, online: scanned ? online.has(mac) : null, since: online.get(mac) ?? null,
    self: mac === self?.mac, gw: k.ip === gw, priv: isPrivateMac(mac), ...vendorOf(mac),
  }));

  const scanLan = async () => {
    self = lanInterface(gw);
    if (!self) return;
    let seen;
    try { seen = await arpNeighbors(self); } catch { return; }
    seen.set(self.mac, self.ip);
    const now = Date.now();
    for (const [mac, ip] of seen) {
      if (!Object.hasOwn(known, mac)) {
        known[mac] = { first: now };
        if (!firstRun) event('device', `📱 новое устройство в сети: ${ip} (${mac})`);
      }
      Object.assign(known[mac], { ip, last: now });
      if (!online.has(mac)) online.set(mac, now);
    }
    for (const mac of [...online.keys()]) if (!seen.has(mac)) online.delete(mac);
    scanned = true;
    try { writeJson(DEVICES, known); } catch {}
    emit({ type: 'devices', list: deviceList() });
  };

  const nameDevice = (mac, name) => {
    // Только настоящий MAC и только уже известный: иначе "__proto__" и т. п. испортят объект.
    if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(mac) || !Object.hasOwn(known, mac)) return false;
    if (name) known[mac].name = name; else delete known[mac].name;
    writeJson(DEVICES, known);
    emit({ type: 'devices', list: deviceList() });
    return true;
  };

  const isBad = (key) => {
    const w = state[key].win;
    if (w.length < 3) return false;
    const lost = w.filter((x) => x == null).length;
    const ok = w.filter((x) => x != null).sort((a, b) => a - b);
    return lost >= BAD_LOSS || (ok.length > 0 && pct(ok, 50) > BAD_RTT[key]);
  };

  let sampling = false;
  const sampleWifi = async () => {
    if (sampling) return;
    sampling = true;
    const w = await wifiInfo().finally(() => { sampling = false; });
    if (!w) return;
    const sample = { t: Date.now(), ...w };
    appendFileSync(wifiCsv, `${sample.t},${w.ssid},"${w.channel}",${w.signal ?? ''},${w.noise ?? ''},${w.rate ?? ''}\n`);
    if (wifi && (wifi.ssid !== w.ssid || wifi.channel !== w.channel)) {
      event('roam', `↔ сеть сменилась: ${wifi.ssid} (${wifi.channel}) → ${w.ssid} (${w.channel})`);
    }
    wifi = w;
    history.wifi.push(sample);
    emit({ type: 'wifi', w: sample });
  };

  const kindNow = (inc) => {
    const k = inc.where === 'wifi' ? 'gw' : 'net';
    return inc.down ? 'down' : inc[k + 'Lost'] >= BAD_LOSS ? 'loss' : 'lag';
  };
  const refresh = (inc) => {
    const kind = kindNow(inc);
    if (!inc.kind || RANK[kind] > RANK[inc.kind]) inc.kind = kind; // тип только ухудшается
    Object.assign(inc, { title: incTitle(inc), details: incDetails(inc), hint: incHint(inc) });
  };
  const note = (inc, key, v) => {
    if (v === null) {
      inc[key + 'Lost']++;
      if (++runLost[key] >= DOWN_RUN && (key === 'gw') === (inc.where === 'wifi')) inc.down = true;
    } else {
      runLost[key] = 0;
      inc[key + 'Peak'] = Math.max(inc[key + 'Peak'] ?? 0, v);
    }
  };

  const tick = () => {
    const now = Date.now();
    const bad = { gw: isBad('gw'), net: isBad('net') };
    const anyBad = bad.gw || bad.net;
    const sigNow = rf && now - rf.t < 2500 ? rf.sig : null;

    if (anyBad && !incident && now >= holdUntil) {
      // Плохо уже до роутера — значит виноват Wi-Fi, интернет за ним страдает следом.
      incident = {
        start: now, where: bad.gw ? 'wifi' : 'isp', gwLost: 0, netLost: 0, gwPeak: null, netPeak: null,
        sigMin: sigNow, down: false, roam: now - lastRoam < 15_000,
      };
      // Сбой видно по окну последних 10 с — считаем и то, что в нём уже накопилось.
      runLost.gw = runLost.net = 0;
      for (const key of ['gw', 'net']) for (const v of state[key].win) note(incident, key, v);
      refresh(incident);
      history.incidents.push(incident);
      event('start', `⚠️  сбой начался — ${incident.title}`);
      notify('WifiMom', `Сбой: ${incident.title}`);
    } else if (incident) {
      for (const key of ['gw', 'net']) if (state[key].fresh) note(incident, key, state[key].latest);
      if (sigNow != null) incident.sigMin = Math.min(incident.sigMin ?? sigNow, sigNow);
      if (bad.gw && incident.where !== 'wifi') {
        incident.where = 'wifi';
        refresh(incident);
        event('start', `⚠️  сбой дошёл до роутера — ${incident.title}`);
      }
      cleanSince = anyBad ? null : cleanSince ?? now;
      refresh(incident);
      if (cleanSince && now - cleanSince >= END_CLEAN_MS) {
        incident.end = cleanSince;
        const sec = Math.max(1, Math.round((incident.end - incident.start) / 1000));
        const what = [incident.where === 'wifi' ? 'Wi-Fi' : 'провайдер', incident.kind === 'down' && KIND.down, incident.details]
          .filter(Boolean).join(', ');
        const hint = incident.hint ? ` ${incident.hint[0].toUpperCase()}${incident.hint.slice(1)}.` : '';
        event('end', `✅ сбой закончился через ${sec} с — ${what}.${hint}`);
        incident = null;
        cleanSince = null;
      }
    }

    const tk = { t: Date.now() };
    for (const key of ['gw', 'net']) {
      if (state[key].fresh) tk[key] = state[key].latest;
      state[key].fresh = false;
    }
    if (rf && Date.now() - rf.t < 2500) Object.assign(tk, { sig: rf.sig, noise: rf.noise, rate: rf.rate, ch: rf.ch });
    if (now < holdUntil) tk.load = 1; // на графике — полоса «замер скорости»
    history.ticks.push(tk);
    if (history.ticks.length > KEEP_TICKS) history.ticks.shift();
    emit({ type: 'tick', tk, incident });

    if (quiet) return;
    const fmt = (key) => {
      const w = state[key].win;
      const last = w[w.length - 1];
      const lost = w.filter((x) => x == null).length;
      return `${last == null ? ' —' : String(Math.round(last)).padStart(3)} мс${lost ? ` (потерь ${lost}/${w.length})` : ''}`;
    };
    const sig = rf ? `${rf.sig} dBm, ${rf.rate} Мбит/с` : wifi ? `${wifi.ssid} ${wifi.signal ?? '?'} dBm, ${wifi.rate ?? '?'} Мбит/с` : 'Wi-Fi: …';
    process.stdout.write(`\r\x1b[K${clock()}  роутер ${fmt('gw')}  интернет ${fmt('net')}  ${sig}${incident ? '  ⚠️' : ''}`);
  };

  const refreshDevices = () => emit({ type: 'devices', list: deviceList() });

  // Окно isBad — последние 10 с, поэтому держим паузу и после замера, пока пики не уйдут из окна.
  const hold = (ms) => { holdUntil = Date.now() + ms; };
  const wifiNow = () => ({
    ssid: wifi?.ssid ?? null, ch: rf?.ch ?? null, sig: rf?.sig ?? wifi?.signal ?? null, rate: rf?.rate ?? wifi?.rate ?? null,
  });

  return {
    dir, history, listeners, refreshDevices, startPing, startRf, hasRf: () => !!rf, sampleWifi, scanLan, deviceList, nameDevice, tick,
    current: () => incident, emit, event, hold, wifiNow,
  };
}

// Замер скорости встроенным networkQuality (тот же, что в macOS): скачивание/отдача в бит/с и отзывчивость
// под нагрузкой (RPM — сколько «запрос-ответ» в минуту успевает пройти, пока канал забит).
const mbit = (bps) => (bps / 1e6 >= 10 ? Math.round(bps / 1e6) : (bps / 1e6).toFixed(1));
function speedTester(m, gw) {
  const doc = readJson(SPEED) || {};
  const results = Array.isArray(doc.results) ? doc.results : [];
  let auto = SPEED_AUTO.includes(doc.auto) ? doc.auto : 0;
  let running = null;
  let lastTry = 0;
  const save = () => writeJson(SPEED, { auto, results: results.slice(-500) });
  const state = () => ({ running: running && { start: running.start }, auto, results: results.slice(-200) });
  const push = () => m.emit({ type: 'speed', ...state() });

  const run = () => {
    if (running) return false;
    running = { start: Date.now() };
    lastTry = running.start;
    const net = m.wifiNow();
    m.hold(120_000);
    m.event('speed', '⚡ замер скорости начался — задержка в это время подскочит, сбои не засчитываются');
    push();
    const iface = lanInterface(gw)?.name;
    execFile('networkQuality', ['-c', '-M', '40', ...(iface ? ['-I', iface] : [])], { timeout: 120_000, maxBuffer: 8 << 20 }, (err, stdout) => {
      let r = null;
      try {
        const j = JSON.parse(stdout);
        if (j.dl_throughput || j.ul_throughput) {
          r = {
            t: running.start, dl: Math.round(j.dl_throughput || 0), ul: Math.round(j.ul_throughput || 0),
            rpm: Math.round(j.responsiveness || 0), rtt: Math.round(j.base_rtt || 0), ...net, iface: j.interface_name || iface,
          };
        }
      } catch {}
      running = null;
      m.hold(12_000);
      if (r) {
        results.push(r);
        try { save(); } catch {}
        const lag = r.rpm ? ` · под нагрузкой ~${Math.round(60000 / r.rpm)} мс` : '';
        m.event('speed', `⚡ скорость: ↓ ${mbit(r.dl)} ↑ ${mbit(r.ul)} Мбит/с${lag}${r.ssid ? ` (${r.ssid})` : ''}`);
      } else {
        m.event('speed', `⚡ замер скорости не удался${err ? ` — ${String(err.message).split('\n')[0]}` : ''}`);
      }
      push();
    });
    return true;
  };

  const setAuto = (v) => {
    if (!SPEED_AUTO.includes(v)) return false;
    auto = v;
    save();
    push();
    return true;
  };
  // Автозамер: раз в минуту смотрим, не пора ли (считая от последнего замера или неудачной попытки).
  setInterval(() => {
    const last = Math.max(results.at(-1)?.t ?? 0, lastTry);
    if (auto && !running && Date.now() - last >= auto * 1000) run();
  }, 60_000);
  return { state, run, setAuto };
}

function speedApi(sp, req, res) {
  if (req.method === 'GET') return sendJson(res, 200, sp.state());
  if (req.method !== 'PUT') return sendJson(res, 405, { error: 'method' });
  readBody(req, res, 1024, (doc) => {
    if (doc.run) return sp.run() ? sendJson(res, 202, sp.state()) : sendJson(res, 409, { error: 'уже идёт' });
    if ('auto' in doc) return sp.setAuto(doc.auto) ? sendJson(res, 200, sp.state()) : sendJson(res, 400, { error: 'auto' });
    sendJson(res, 400, { error: 'shape' });
  });
}

const sendJson = (res, code, body) => {
  res.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(typeof body === 'string' ? body : JSON.stringify(body));
};

// Писать можно только со своей же страницы: чужой сайт не пройдёт проверку Host/Origin,
// а application/json без CORS заставит браузер сделать preflight, которого мы не одобряем.
function writeAllowed(req) {
  const host = req.headers.host || '';
  const origin = req.headers.origin;
  return /^(127\.0\.0\.1|localhost):\d+$/.test(host) && (!origin || origin === `http://${host}`) &&
    String(req.headers['content-type']).startsWith('application/json');
}

function readBody(req, res, max, cb) {
  if (!writeAllowed(req)) return sendJson(res, 403, { error: 'forbidden' });
  let size = 0;
  const chunks = [];
  req.on('data', (c) => {
    size += c.length;
    if (size > max) { sendJson(res, 413, { error: 'too big' }); req.destroy(); return; }
    chunks.push(c);
  });
  req.on('end', () => {
    if (size > max) return;
    let doc;
    try { doc = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return sendJson(res, 400, { error: 'json' }); }
    cb(doc);
  });
}

// Карта покрытия: план квартиры (data:image/…) и точки замеров. Лежит вне проекта — это план жилья.
function survey(req, res) {
  if (req.method === 'GET') return sendJson(res, 200, existsSync(SURVEY) ? readFileSync(SURVEY, 'utf8') : '{}');
  if (req.method !== 'PUT') return sendJson(res, 405, { error: 'method' });
  readBody(req, res, SURVEY_MAX, (doc) => {
    const okPlan = doc.plan == null || (typeof doc.plan === 'string' && doc.plan.startsWith('data:image/'));
    if (!okPlan || !Array.isArray(doc.points) || !(doc.aspect > 0)) return sendJson(res, 400, { error: 'shape' });
    writeJson(SURVEY, { plan: doc.plan ?? null, aspect: doc.aspect, points: doc.points });
    sendJson(res, 200, { ok: true });
  });
}

// Подпись устройства: { mac, name }. Пустое имя — убрать подпись.
function deviceName(m, req, res) {
  if (req.method !== 'PUT') return sendJson(res, 405, { error: 'method' });
  readBody(req, res, 4096, (doc) => {
    const mac = typeof doc.mac === 'string' ? doc.mac : '';
    const name = typeof doc.name === 'string' ? doc.name.trim().slice(0, 60) : '';
    if (!m.nameDevice(mac, name)) return sendJson(res, 404, { error: 'unknown device' });
    sendJson(res, 200, { ok: true });
  });
}

// ── Вход в веб-интерфейс роутера ──
// Пароль лежит в связке ключей macOS (служба wifimom.router), логин — в ~/.wifimom/router.json.
// Роутер (xPON ONU на Boa) пускает по HTTP Basic, поэтому каждый запрос несёт логин/пароль.
async function routerCred() {
  let user;
  try { user = JSON.parse(readFileSync(ROUTER_META, 'utf8')).user; } catch { return null; }
  if (typeof user !== 'string' || !user) return null;
  try {
    // -w отдаёт не-ASCII пароль в hex без пометки; -g пишет «password: 0x<hex> …» или «password: "<текст>"».
    const { stderr } = await run('security', ['find-generic-password', '-s', KC_SERVICE, '-a', user, '-g'], { timeout: 5000 });
    const line = stderr.split('\n').find((l) => l.startsWith('password: ')) || '';
    const hex = line.match(/^password: 0x([0-9A-Fa-f]+)/);
    const pass = hex ? Buffer.from(hex[1], 'hex').toString('utf8') : line.slice(line.indexOf('"') + 1, line.lastIndexOf('"'));
    return pass ? { user, pass } : null;
  } catch {
    return null;
  }
}

async function saveRouterCred(user, pass) {
  // Пароль ненадолго виден в аргументах `security` — других способов без зависимостей нет.
  await run('security', ['add-generic-password', '-U', '-s', KC_SERVICE, '-a', user, '-l', 'WifiMom: роутер', '-w', pass], { timeout: 5000 });
  writeJson(ROUTER_META, { user });
}

async function forgetRouterCred() {
  const cred = await routerCred();
  if (cred) await run('security', ['delete-generic-password', '-s', KC_SERVICE, '-a', cred.user], { timeout: 5000 }).catch(() => {});
  try { writeJson(ROUTER_META, {}); } catch {}
}

function routerFetch(gw, path, cred, opts = {}) {
  const auth = 'Basic ' + Buffer.from(`${cred.user}:${cred.pass}`).toString('base64');
  return fetch(`http://${gw}${path}`, {
    ...opts, redirect: 'manual', signal: AbortSignal.timeout(6000),
    headers: { authorization: auth, ...(opts.headers || {}) },
  });
}

// Проверка входа: стартовая страница админки отдаёт 200 только с верным паролем.
async function routerLogin(gw, cred) {
  try {
    const r = await routerFetch(gw, '/cgi-bin/index.asp', cred);
    await r.arrayBuffer().catch(() => {});
    if (r.status === 200) return { ok: true };
    if (r.status === 401) return { ok: false, error: 'Роутер не принял логин или пароль.' };
    return { ok: false, error: `Роутер ответил кодом ${r.status}.` };
  } catch (e) {
    return { ok: false, error: `Роутер не отвечает (${e.name === 'TimeoutError' ? 'таймаут' : e.message}).` };
  }
}

// Результат проверки держим минуту: каждое открытие страницы не должно стучаться в роутер
// (с неверным паролем частые попытки могут заблокировать вход).
let routerCheck = null;
async function routerStatus(gw, cred) {
  const key = `${cred.user}\0${cred.pass}`;
  if (routerCheck?.key === key && Date.now() - routerCheck.at < 60_000) return routerCheck.result;
  const result = await routerLogin(gw, cred);
  routerCheck = { key, at: Date.now(), result };
  return result;
}

function routerApi(gw, req, res) {
  if (req.method === 'GET') {
    return routerCred().then(async (cred) => {
      if (!cred) return sendJson(res, 200, { gateway: gw, saved: false });
      sendJson(res, 200, { gateway: gw, saved: true, user: cred.user, ...(await routerStatus(gw, cred)) });
    });
  }
  if (req.method !== 'PUT') return sendJson(res, 405, { error: 'method' });
  readBody(req, res, 4096, async (doc) => {
    if (doc.forget) { await forgetRouterCred(); routerCheck = null; return sendJson(res, 200, { ok: true, saved: false }); }
    const user = typeof doc.user === 'string' ? doc.user.trim().slice(0, 64) : '';
    const pass = typeof doc.pass === 'string' ? doc.pass.slice(0, 128) : '';
    if (!user || !pass) return sendJson(res, 400, { ok: false, error: 'Нужны логин и пароль.' });
    const check = await routerLogin(gw, { user, pass });
    if (!check.ok) return sendJson(res, 200, check); // неверный пароль не сохраняем
    routerCheck = { key: `${user}\0${pass}`, at: Date.now(), result: check };
    try { await saveRouterCred(user, pass); } catch { return sendJson(res, 500, { ok: false, error: 'Не удалось сохранить в связку ключей.' }); }
    sendJson(res, 200, { ok: true, saved: true, user });
  });
}

function serve(m, meta, sp) {
  const page = () => readFileSync(join(HERE, 'ui.html'));
  const server = createServer((req, res) => {
    if (req.url === '/' || req.url === '/index.html') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      return res.end(page());
    }
    if (req.url === '/api/state') {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ ...meta, ...m.history, incident: m.current(), thresholds: BAD_RTT, devices: m.deviceList() }));
    }
    if (req.url === '/api/survey') return survey(req, res);
    if (req.url === '/api/devices/name') return deviceName(m, req, res);
    if (req.url === '/api/router') return routerApi(meta.gateway, req, res);
    if (req.url === '/api/speed') return speedApi(sp, req, res);
    if (req.url === '/api/stream') {
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
      res.write(': hi\n\n');
      const send = (msg) => res.write(`data: ${JSON.stringify(msg)}\n\n`);
      m.listeners.add(send);
      req.on('close', () => m.listeners.delete(send));
      return;
    }
    res.writeHead(404).end();
  });

  return new Promise((resolve) => {
    const tryPort = (port) => {
      server.once('error', (err) => {
        if (err.code === 'EADDRINUSE' && port < PORT + 20) tryPort(port + 1);
        else throw err;
      });
      server.listen(port, '127.0.0.1', () => resolve(`http://127.0.0.1:${port}`));
    };
    tryPort(PORT);
  });
}

function summarize(dir) {
  const rows = readFileSync(join(dir, 'pings.csv'), 'utf8').trim().split('\n').slice(1).map((l) => l.split(','));
  const out = [`\nИтог: ${dir}`];
  const ts = rows.map((r) => Number(r[0]));
  if (ts.length) out.push(`Время записи: ${Math.round((Math.max(...ts) - Math.min(...ts)) / 60000)} мин`);

  for (const [key, label] of [['gw', 'до роутера'], ['net', 'до интернета']]) {
    const r = rows.filter((x) => x[1] === key);
    if (!r.length) continue;
    const ok = r.filter((x) => x[2] !== '').map((x) => Number(x[2])).sort((a, b) => a - b);
    const loss = ((r.length - ok.length) / r.length) * 100;
    const spikes = ok.filter((x) => x > BAD_RTT[key]).length;
    out.push(
      `  ${label.padEnd(13)} потери ${loss.toFixed(1)}%  обычно ${pct(ok, 50)?.toFixed(0)} мс  ` +
      `в худших 5% ${pct(ok, 95)?.toFixed(0)} мс  макс ${ok.at(-1)?.toFixed(0)} мс  всплесков >${BAD_RTT[key]} мс: ${spikes}`,
    );
  }

  const wifiPath = join(dir, 'wifi.csv');
  if (existsSync(wifiPath)) {
    const w = readFileSync(wifiPath, 'utf8').trim().split('\n').slice(1);
    const sig = w.map((l) => Number(l.split(',').at(-3))).filter(Boolean);
    const nets = [...new Set(w.map((l) => l.split(',')[1]))];
    if (sig.length) out.push(`  сигнал       от ${Math.min(...sig)} до ${Math.max(...sig)} dBm, сети: ${nets.join(', ')}`);
  }

  const evPath = join(dir, 'events.log');
  const ev = existsSync(evPath) ? readFileSync(evPath, 'utf8').trim().split('\n').filter(Boolean) : [];
  const ends = ev.filter((l) => l.includes('закончился'));
  const wifiN = ends.filter((l) => l.includes('Wi-Fi')).length;
  out.push(`  сбоев: ${ends.length} (Wi-Fi: ${wifiN}, провайдер: ${ends.length - wifiN})`);
  if (ev.length) out.push('События:', ...ev.map((l) => '  ' + l));
  console.log(out.join('\n'));
}

const args = process.argv.slice(2);
const cmd = args.find((a) => !a.startsWith('-'));
const flags = new Set(args.filter((a) => a.startsWith('-')));

if (cmd === 'report') {
  const arg = args[args.indexOf('report') + 1];
  const dir = arg || (existsSync(LOGS) && join(LOGS, readdirSync(LOGS).sort().at(-1) || ''));
  if (!dir || !existsSync(join(dir, 'pings.csv'))) {
    console.error('Нет записей. Запустите сначала: wifimom');
    process.exit(1);
  }
  summarize(dir);
} else if (cmd === 'router') {
  // Посмотреть страницу роутера с сохранённым входом (только чтение): wifimom router /cgi-bin/index.asp
  const path = args[args.indexOf('router') + 1] || '/cgi-bin/index.asp';
  const gw = await gateway();
  const cred = await routerCred();
  if (!gw || !cred) {
    console.error(gw ? 'Вход в роутер не сохранён — введите логин/пароль в разделе «Роутер».' : 'Не найден роутер — Wi-Fi подключён?');
    process.exit(1);
  }
  const r = await routerFetch(gw, path.startsWith('/') ? path : '/' + path, cred);
  const body = Buffer.from(await r.arrayBuffer());
  console.log(`HTTP ${r.status} ${r.headers.get('content-type') || ''} ${body.length} байт`);
  process.stdout.write(body.toString('latin1'));
} else if (cmd === 'help' || flags.has('-h') || flags.has('--help')) {
  console.log(
    [
      'wifimom              — мониторинг + окно в браузере, Ctrl+C — итог',
      'wifimom --no-ui      — только терминал',
      'wifimom --no-open    — окно не открывать (адрес будет в терминале)',
      'wifimom report       — итог последней записи',
      'wifimom report DIR   — итог конкретной записи',
      'wifimom router PATH  — показать страницу роутера (нужен сохранённый вход)',
      'app/install.sh       — собрать WifiMom.app в /Applications',
    ].join('\n'),
  );
} else {
  const gw = await gateway();
  if (!gw) {
    console.error('Не найден роутер — Wi-Fi подключён?');
    process.exit(1);
  }
  const m = monitor({ quiet: false, gw });
  const lines = [`Роутер ${gw}, интернет 1.1.1.1. Лог: ${m.dir}`];
  if (!flags.has('--no-ui')) {
    const url = await serve(m, { gateway: gw, internet: '1.1.1.1', host: hostname() }, speedTester(m, gw));
    lines.push(`Окно: ${url}`);
    if (!flags.has('--no-open')) execFile('open', [url], () => {});
  }
  console.log(`${lines.join('\n')}\nCtrl+C — остановить и показать итог.\n`);
  const procs = [m.startPing('gw', gw), m.startPing('net', '1.1.1.1')];
  rfBinary().then((bin) => {
    if (bin) procs.push(m.startRf(bin));
    else console.log('Быстрый замер сигнала недоступен (нет swiftc) — сигнал раз в 30 с.');
  });
  m.sampleWifi();
  // С быстрым замером (rf) сигнал и канал приходят раз в секунду, а system_profiler сканирует эфир и сам
  // даёт скачки задержки — поэтому периодически зовём его только без rf.
  const wifiTimer = setInterval(() => { if (!m.hasRf()) m.sampleWifi(); }, WIFI_EVERY_MS);
  const tickTimer = setInterval(m.tick, 1000);
  setTimeout(m.scanLan, 3000);
  ensureVendors().then((n) => { if (n) m.refreshDevices(); });
  const lanTimer = setInterval(m.scanLan, LAN_EVERY_MS);
  // Ctrl+C, выход из WifiMom.app (SIGINT), kill (SIGTERM), закрытый терминал (SIGHUP) или оборванный вывод
  // (приложение упало, EPIPE) — всегда гасим ping/rf, иначе они остаются висеть сиротами.
  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    clearInterval(wifiTimer);
    clearInterval(tickTimer);
    clearInterval(lanTimer);
    procs.forEach((p) => p.kill());
    try { summarize(m.dir); } catch {}
    process.exit(0);
  };
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, stop);
  process.stdout.on('error', stop);
}
