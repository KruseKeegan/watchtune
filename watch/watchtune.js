// WatchTune: shows the song playing on your phone (Spotify) and controls it.
// The WatchTune iPhone app sends the song over the Forge BLE
// service; the buttons send commands back.
//
// Buttons (act on release, so a hold never also does the short action):
//   A tap  - play / pause          A hold - scroll the song again
//   L tap  - next track            L hold - previous track
// Display:
//   Main digits - "Title - Artist", scrolled once when it changes
//   Day digits  - " P" playing, "11" paused (pause bars)
//   LAP         - phone connected
//
// Phone -> watch (each write <= 20 bytes, first char is the type):
//   S<text>  start a new song text      C<text>  continue it
//   E        end: show the text         P1 / P0  playing / paused
//   X        nothing playing
// Watch -> phone:
//   PP play/pause   NX next   PV previous   ?  resend everything

var MAXLEN = 120;        // cap on song text, protects RAM
var SCROLL_MS = 300;     // per character
var W = 6;               // clock digits
const subscribe = E_BUTTONS + E_A_LONG + E_L_LONG + E_BLE_RX + E_BLE_CONNECT + E_BLE_DISCONNECT;

var song = '';
var buf = '';
var playing = false;
var off = 0;
var scrollId = -1;
var msgId = -1;
var aUsed = false;       // A hold already acted, ignore the release
var lUsed = false;

function stopScroll() {
  if (scrollId !== -1) Ollee.clearInterval(scrollId);
  scrollId = -1;
}

function windowAt(t, o) {
  var loop = t + '   ';
  var w = '';
  for (var k = 0; k < W; k++) w += loop.charAt((o + k) % loop.length);
  return w;
}

function show() {
  if (!Ollee.active() || msgId !== -1) return;
  Ollee.drawLap(Ollee.connected());
  Ollee.drawDay(song ? (playing ? ' P' : '11') : '  ');
  if (!song) Ollee.drawMain('no Sng');
  else if (song.length <= W) Ollee.drawMain((song + '      ').slice(0, W));
  else Ollee.drawMain(windowAt(song, off));
}

function step() {
  off = (off + 1) % (song.length + 3);
  show();
  if (off === 0) stopScroll();   // one pass done, rest at the start
}

function startScroll() {
  stopScroll();
  off = 0;
  show();
  if (Ollee.active() && msgId === -1 && song.length > W) scrollId = Ollee.setInterval(step, SCROLL_MS);
}

// Shows a short message for 1 s, then the song again
function flash(t) {
  if (!Ollee.active()) return;
  if (msgId !== -1) Ollee.clearTimeout(msgId);
  msgId = -1;
  stopScroll();
  Ollee.drawMain(t);
  msgId = Ollee.setTimeout(function () { msgId = -1; off = 0; show(); }, 1000);
}

function cmd(c) {
  Ollee.beepShort();
  if (!Ollee.send(c)) flash('no bLE');
}

// Runs at upload and boot: keep receiving songs while on other faces
function init() {
  Ollee.subscribe(E_BLE_RX);
}

function enter() {
  Ollee.clear();
  msgId = -1;
  startScroll();
  if (Ollee.connected()) Ollee.send('?');
}

function exit() {
  stopScroll();
  msgId = -1;            // the firmware cancels the timer itself
  aUsed = lUsed = false;
}

function ble_rx(d) {
  var t = d.charAt(0), r = d.slice(1);
  if (t === 'S') buf = r;
  else if (t === 'C') buf = (buf + r).slice(0, MAXLEN);
  else if (t === 'E') {
    if (buf !== song) { song = buf; startScroll(); }
    buf = '';
  } else if (t === 'P') { playing = r === '1'; show(); }
  else if (t === 'X') { song = ''; buf = ''; playing = false; stopScroll(); show(); }
}

function ble_connect() { show(); }
function ble_disconnect() { show(); }

function a_long() { aUsed = true; startScroll(); }
function l_long() { lUsed = true; cmd('PV'); }

function button(btn, ev) {
  if (btn === B_A) {
    if (ev === E_DOWN) aUsed = false;
    else if (!aUsed) cmd('PP');
  } else {
    if (ev === E_DOWN) lUsed = false;
    else if (!lUsed) cmd('NX');
  }
}
