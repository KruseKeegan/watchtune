// Node harness for watch/watchtune.js: mocks the Ollee API (4 timer slots,
// active flag, BLE) and runs it through scenarios.
// Usage: node tests/test_watchface.js watch/watchtune.js
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');

const E = { E_A_SHORT: 1, E_A_LONG: 2, E_L_SHORT: 4, E_L_LONG: 8, E_TILT: 16, E_BUTTONS: 32, E_TAP: 64,
  E_BLE_RX: 128, E_CLOCK_MINUTE: 256, E_CLOCK_HOUR: 512, E_BLE_CONNECT: 1024, E_BLE_DISCONNECT: 2048, E_CLOCK_SECOND: 4096,
  B_A: 0, B_L: 1, E_DOWN: 0, E_UP: 1 };

let fails = 0;
function check(name, cond, extra) { if (!cond) { fails++; console.log('FAIL', name, extra || ''); } else console.log('ok  ', name); }

function makeWatch() {
  const st = { active: false, connected: true, main: '', day: '', lap: false, sent: [], beeps: 0, bg: 0, slots: [null, null, null, null] };
  const Ollee = {
    active: () => st.active,
    connected: () => st.connected,
    drawMain: (t) => { if (st.active) st.main = String(t).slice(0, 6).padStart(6, ' '); },
    drawDay: (t) => { if (st.active) st.day = String(t).slice(0, 2).padStart(2, ' '); },
    drawLap: (v) => { if (st.active) st.lap = !!v; },
    drawColon() {}, drawPM() {}, drawHR() {},
    clear: () => { if (st.active) { st.main = ''; st.day = ''; st.lap = false; } },
    beep: () => st.beeps++, beepShort: () => st.beeps++,
    send: (d) => { if (!st.connected || !d.length || d.length > 256) return false; st.sent.push(d); return true; },
    subscribe: (b) => { st.bg |= b; return true; },
    unsubscribe: (b) => { st.bg &= ~b; return true; },
    setTimeout(fn, ms) { const i = st.slots.indexOf(null); if (i < 0) return -1; st.slots[i] = { t: setTimeout(() => { st.slots[i] = null; fn(); }, ms) }; return i; },
    setInterval(fn, ms) { const i = st.slots.indexOf(null); if (i < 0) return -1; st.slots[i] = { t: setInterval(fn, ms), iv: 1 }; return i; },
    clearTimeout(i) { if (i == null) { st.slots.forEach((s, j) => Ollee.clearTimeout(j)); return; } const s = st.slots[i]; if (s) { clearTimeout(s.t); clearInterval(s.t); st.slots[i] = null; } },
  };
  Ollee.clearInterval = Ollee.clearTimeout;
  const names = Object.keys(E);
  const hooks = ['init', 'enter', 'exit', 'ble_rx', 'ble_connect', 'ble_disconnect', 'a_long', 'l_long', 'tilt', 'button', 'a_short', 'l_short'];
  const f = new Function('Ollee', 'log', ...names, src + '\nreturn {' + hooks.map((h) => `${h}: typeof ${h}==='function'?${h}:undefined`).join(',') + ', subscribe: subscribe};');
  const h = f(Ollee, console.log, ...names.map((n) => E[n]));
  const used = () => st.slots.filter(Boolean).length;
  const enter = () => { st.active = true; h.enter && h.enter(); };
  const exit = () => { h.exit && h.exit(); st.active = false; Ollee.clearTimeout(); };
  const sendSong = (text) => {
    const chunks = [];
    for (let i = 0; i < text.length; i += 19) chunks.push(text.slice(i, i + 19));
    if (!chunks.length) chunks.push('');
    chunks.forEach((c, i) => h.ble_rx((i ? 'C' : 'S') + c));
    h.ble_rx('E');
  };
  const press = (btn, long) => { h.button(btn, E.E_DOWN); if (long) (btn === E.B_A ? h.a_long : h.l_long)(); h.button(btn, E.E_UP); };
  return { st, h, used, enter, exit, sendSong, press, E };
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const w = makeWatch();
  const { st, h } = w;
  check('subscribe has BUTTONS+BLE_RX', (h.subscribe & 32) && (h.subscribe & 128));
  h.init();
  check('init subscribes BLE_RX in background', st.bg & 128);
  // song arrives while off screen
  w.sendSong('Bohemian Rhapsody - Queen');
  h.ble_rx('P1');
  check('no draw while inactive', st.main === '');
  check('no timer while inactive', w.used() === 0);
  w.enter();
  check('enter asks phone to resend', st.sent.includes('?'));
  check('enter shows start of song', st.main === 'Bohemi', JSON.stringify(st.main));
  check('playing shows " P"', st.day === ' P');
  check('LAP = connected', st.lap === true);
  check('scroll timer running', w.used() === 1);
  await sleep(320);
  check('scrolled one char', st.main === 'ohemia', JSON.stringify(st.main));
  // full pass: len 25 + 3 = 28 steps * 300ms
  await sleep(28 * 300 + 200);
  check('scroll stopped after one pass', w.used() === 0);
  check('rests at start', st.main === 'Bohemi', JSON.stringify(st.main));
  // pause
  h.ble_rx('P0');
  check('paused shows 11', st.day === '11');
  // buttons
  st.sent = [];
  w.press(w.E.B_A, false);
  check('A tap sends PP', st.sent.join() === 'PP');
  st.sent = [];
  w.press(w.E.B_A, true);
  check('A hold sends nothing', st.sent.length === 0, st.sent.join());
  check('A hold restarts scroll', w.used() === 1);
  st.sent = [];
  w.press(w.E.B_L, false);
  check('L tap sends NX', st.sent.join() === 'NX');
  st.sent = [];
  w.press(w.E.B_L, true);
  check('L hold sends PV only', st.sent.join() === 'PV', st.sent.join());
  st.sent = [];
  check('no tilt hook', typeof h.tilt === 'undefined');
  if (h.tilt) h.tilt();
  check('tilt does nothing', st.sent.length === 0);
  // short song
  w.sendSong('Hey');
  check('short song left-aligned', st.main === 'Hey   ', JSON.stringify(st.main));
  check('short song no timer', w.used() === 0);
  // same song resent does not restart scroll
  w.sendSong('Bohemian Rhapsody - Queen');
  const u1 = w.used();
  w.sendSong('Bohemian Rhapsody - Queen');
  check('resend same song keeps one timer', w.used() === u1 && u1 === 1);
  // disconnect -> send fails -> flash
  st.connected = false;
  h.ble_disconnect();
  check('LAP off on disconnect', st.lap === false);
  w.press(w.E.B_L, false);
  check('send fails shows no bLE', st.main === 'no bLE', JSON.stringify(st.main));
  check('timers within 4', w.used() <= 4);
  h.ble_rx('P1');
  check('ble during flash keeps message', st.main === 'no bLE');
  await sleep(1100);
  check('flash ends, song back', st.main === 'Bohemi', JSON.stringify(st.main));
  // spam buttons while disconnected: never exceed slots, never throw
  for (let i = 0; i < 10; i++) w.press(w.E.B_L, false);
  check('spam keeps slots <= 4', w.used() <= 4);
  st.connected = true;
  await sleep(1100);
  // nothing playing
  h.ble_rx('X');
  check('X shows no Sng', st.main === 'no Sng' && st.day === '  ');
  // long text cap
  w.sendSong('x'.repeat(300));
  check('text capped (no crash)', true);
  // exit mid-scroll then re-enter
  w.sendSong('Another One Bites The Dust - Queen');
  w.exit();
  check('exit clears timers', w.used() === 0);
  w.enter();
  check('re-enter scrolls again', w.used() === 1 && st.main === 'Anothe');
  // exit during flash then re-enter: flash state reset
  st.connected = false;
  w.press(w.E.B_A, false);
  w.exit();
  st.connected = true;
  w.enter();
  check('re-enter after flash shows song', st.main === 'Anothe', JSON.stringify(st.main));
  w.exit();
  console.log(fails ? `${fails} FAILED` : 'ALL PASS');
  process.exit(fails ? 1 : 0);
})();
