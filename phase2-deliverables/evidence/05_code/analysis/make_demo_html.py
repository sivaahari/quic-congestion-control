#!/usr/bin/env python3
"""make_demo_html.py -- build a self-contained animated HTML demo.

Replaces the terminal dashboard, which flickered and buried its takeaway.
This renders on canvas with requestAnimationFrame (no flicker), narrates each
beat in plain language, and is a single file with no external dependencies --
open it in a browser and screen-record.

Real cwnd time series are read from captured qlogs and embedded as JSON.

Output: paper/demo.html
"""
import glob
import json
import os

BASE = "/home/sivaa/pvseed"
OUT = f"{BASE}/paper/demo.html"
os.makedirs(f"{BASE}/paper", exist_ok=True)


def load_series(qlog):
    with open(qlog) as f:
        d = json.load(f)
    tr = d["traces"][0]
    fl = tr["event_fields"]
    ti, ci, ei, di = (fl.index(x) for x in ("relative_time", "category", "event", "data"))
    metrics, resp = [], []
    for ev in tr["events"]:
        t, cat, name, data = ev[ti], ev[ci], ev[ei], ev[di]
        if not isinstance(data, dict):
            continue
        if name == "metrics_updated" and "cwnd" in data:
            metrics.append((t, data["cwnd"]))
        elif name == "packet_received":
            for fr in data.get("frames") or []:
                if fr.get("frame_type") == "path_response":
                    resp.append(t)
    if not metrics or not resp:
        return []
    # Anchor on the FIRST path_response: that is when the new path is first
    # validated, i.e. the migration instant. Anchoring on the last one (a
    # repeat challenge) pushes t=0 to the end of the trace and leaves no
    # post-migration samples to animate.
    t0 = min(resp)
    out = []
    for t, c in metrics:
        rel = (t - t0) / 1e6
        if -3.0 <= rel <= 8.0 and c:
            out.append([round(rel, 4), round(c / 1024, 2)])
    return out


def pick(p):
    g = glob.glob(p)
    return max(g, key=os.path.getsize) if g else None


src = f"{BASE}/results/raw/_task2_verify"
code = load_series(pick(f"{src}/naive/qlog_server/*.qlog"))
spec = load_series(pick(f"{src}/reset/qlog_server/*.qlog"))
if not code or not spec:
    raise SystemExit("missing qlog data")

payload = json.dumps({"code": code, "spec": spec})

HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>What QUIC does when your phone changes network</title>
<style>
  :root{--bg:#0E1116;--panel:#161B22;--ink:#E8EDF3;--mute:#8B949E;
        --code:#F0736F;--spec:#6E9BE0;--good:#63C088;--line:#262C36}
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--bg);color:var(--ink);
       font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,sans-serif;
       display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}
  .wrap{width:min(1160px,100%)}
  .kicker{color:var(--spec);font-size:13px;font-weight:700;letter-spacing:.14em;
          text-transform:uppercase;margin-bottom:10px;height:18px}
  h1{font-size:31px;font-weight:700;line-height:1.24;margin-bottom:22px;min-height:78px}
  .stage{background:var(--panel);border:1px solid var(--line);border-radius:14px;
         padding:20px 22px 14px}
  canvas{width:100%;height:400px;display:block}
  .legend{display:flex;gap:26px;margin:10px 2px 0;font-size:14px;flex-wrap:wrap}
  .legend span{display:flex;align-items:center;gap:8px;color:var(--mute)}
  .sw{width:26px;height:3px;border-radius:2px}
  .caption{margin-top:20px;min-height:76px;font-size:19px;line-height:1.48}
  .caption b{color:var(--ink)}
  .num{font-variant-numeric:tabular-nums;font-weight:700}
  .bar{display:flex;gap:10px;margin-top:20px;align-items:center}
  button{background:var(--spec);color:#06111F;border:0;border-radius:8px;
         padding:10px 20px;font-size:14px;font-weight:700;cursor:pointer}
  button.ghost{background:transparent;color:var(--mute);border:1px solid var(--line)}
  .prog{flex:1;height:4px;background:var(--line);border-radius:2px;overflow:hidden}
  .prog i{display:block;height:100%;width:0;background:var(--spec)}
</style></head><body><div class="wrap">
  <div class="kicker" id="kicker"></div>
  <h1 id="title">Your phone is downloading a file.</h1>
  <div class="stage">
    <canvas id="c" width="1100" height="400"></canvas>
    <div class="legend">
      <span><i class="sw" style="background:var(--code)"></i> what picoquic actually does</span>
      <span><i class="sw" style="background:var(--spec)"></i> what the rulebook says must happen</span>
      <span><i class="sw" style="background:var(--mute)"></i> the network switch</span>
    </div>
  </div>
  <div class="caption" id="cap"></div>
  <div class="bar">
    <button id="play">Replay</button>
    <button class="ghost" id="slow">Slower</button>
    <div class="prog"><i id="pi"></i></div>
  </div>
</div>
<script>
const DATA = __PAYLOAD__;
const cv = document.getElementById('c'), cx = cv.getContext('2d');
const T = document.getElementById('title'), K = document.getElementById('kicker');
const CAP = document.getElementById('cap'), PI = document.getElementById('pi');
const DPR = Math.min(devicePixelRatio||1, 2);
let _w = 1100;
function fit(){
  // clientWidth is 0 if the page lays out while hidden (background tab,
  // preview pane). Falling back keeps the chart drawable instead of silently
  // rendering a zero-width canvas.
  _w = cv.clientWidth || _w || 1100;
  cv.width = _w*DPR; cv.height = 400*DPR;
  cx.setTransform(DPR,0,0,DPR,0,0);
}
addEventListener('resize', fit);
if (window.ResizeObserver) new ResizeObserver(()=>{ if(cv.clientWidth && cv.clientWidth!==_w){ fit(); } }).observe(cv);
fit();

// Window deliberately tight around the switch. Beyond ~+3s the unmodified
// trace shows an ordinary loss-driven collapse that has nothing to do with
// migration; including it would invite exactly the wrong reading.
const X0=-2.0, X1=1.0, Y0=0, Y1=300;
const PAD={l:74,r:22,t:18,b:44};
function W(){return _w} function H(){return 400}
const sx = x => PAD.l + (x-X0)/(X1-X0)*(W()-PAD.l-PAD.r);
const sy = y => H()-PAD.b - (y-Y0)/(Y1-Y0)*(H()-PAD.t-PAD.b);

function grid(){
  cx.clearRect(0,0,W(),H());
  cx.strokeStyle='#262C36'; cx.fillStyle='#8B949E'; cx.lineWidth=1;
  cx.font='12px system-ui'; cx.textAlign='right';
  for(let y=0;y<=300;y+=50){
    cx.beginPath(); cx.moveTo(PAD.l,sy(y)); cx.lineTo(W()-PAD.r,sy(y)); cx.stroke();
    cx.fillText(y+' KB', PAD.l-10, sy(y)+4);
  }
  cx.textAlign='center';
  for(let x=-2;x<=2;x+=1){
    cx.fillText(x+'s', sx(x), H()-PAD.b+22);
  }
  cx.fillText('time relative to the network switch', W()/2, H()-8);
}
function vline(t){
  if(t<0) return;
  cx.strokeStyle='#8B949E'; cx.setLineDash([6,5]); cx.lineWidth=1.5;
  cx.beginPath(); cx.moveTo(sx(0),PAD.t); cx.lineTo(sx(0),H()-PAD.b); cx.stroke();
  cx.setLineDash([]);
}
function line(series, upto, color){
  const pts = series.filter(p=>p[0]<=upto && p[0]<=X1);
  if(pts.length<2) return;
  cx.strokeStyle=color; cx.lineWidth=3; cx.lineJoin='round';
  cx.beginPath();
  pts.forEach((p,i)=> i?cx.lineTo(sx(p[0]),sy(p[1])):cx.moveTo(sx(p[0]),sy(p[1])));
  // Step-hold to the current time. The stack logs a sample only when the value
  // CHANGES, so the absence of a sample means the window did not move --
  // carrying the last value forward is the correct reading, not an invention.
  const tail=pts[pts.length-1];
  if(upto>tail[0]) cx.lineTo(sx(Math.min(upto,X1)), sy(tail[1]));
  cx.stroke();
  // Every real sample the connection logged. Shown so the viewer can see this
  // is measured data, not a drawn curve -- the stack only records a sample when
  // the value materially changes, so they are naturally sparse.
  cx.fillStyle=color; cx.globalAlpha=.55;
  pts.forEach(p=>{ cx.beginPath(); cx.arc(sx(p[0]),sy(p[1]),3,0,7); cx.fill(); });
  cx.globalAlpha=1;
  const last=pts[pts.length-1];
  cx.beginPath(); cx.arc(sx(last[0]),sy(last[1]),6,0,7); cx.fill();
  cx.strokeStyle='#0E1116'; cx.lineWidth=2; cx.stroke();
}
function draw(t, showSpec){
  grid(); vline(t);
  if(showSpec) line(DATA.spec, t, '#6E9BE0');
  line(DATA.code, t, '#F0736F');
}

const BEATS=[
 {at:-2.00,k:'THE SETTING',   t:'Your phone is downloading a file.',
  c:'The line shows how fast the connection is willing to send. It has settled at a healthy rate on the current network.'},
 {at:-0.55,k:'THE SETTING',   t:'Then you walk outside.',
  c:'The phone is about to hand over from Wi-Fi to mobile data. The connection survives — QUIC identifies you by an ID, not an address.'},
 {at: 0.02,k:'THE MOMENT',    t:'The network changes here.',
  c:'The new network could be faster or slower. Whatever the connection learned about the old one is now worthless — possibly dangerous.'},
 {at: 0.12,k:'THE RULE',      t:'The rulebook is explicit about what must happen next.',
  c:'<b>“…an endpoint MUST immediately reset the congestion controller … to initial values.”</b> &nbsp;In plain terms: forget the old speed, start over.'},
 {at: 0.30,k:'WHAT WE FOUND', t:'The blue line is a version we built that follows that rule.',
  c:'It drops straight back to the starting speed of 15 KB, exactly as required.'},
 {at: 0.50,k:'WHAT WE FOUND', t:'The red line is picoquic, unmodified.',
  c:'It carries the old network\\'s speed straight across — the stack never even records a change. <b>A widely-used implementation ignoring a MUST.</b>'},
 {at: 0.72,k:'THE GAP',       t:'Nobody has measured which implementations get this right.',
  c:'We found one that does not, and we found that following the rule only <i>partly</i> is worse than ignoring it. <b>That is the paper.</b>'},
];

let raf=null, speed=1;
function run(){
  cancelAnimationFrame(raf);
  const t0=performance.now(), DUR=26000/speed;
  let bi=-1;
  (function frame(now){
    const e=Math.min((now-t0)/DUR,1);
    const t=X0+e*(X1-X0);
    draw(t, t>0.55);
    PI.style.width=(e*100)+'%';
    let nb=-1;
    for(let i=0;i<BEATS.length;i++) if(t>=BEATS[i].at) nb=i;
    if(nb!==bi && nb>=0){ bi=nb; K.textContent=BEATS[nb].k; T.textContent=BEATS[nb].t; CAP.innerHTML=BEATS[nb].c; }
    if(e<1) raf=requestAnimationFrame(frame);
  })(t0);
}
document.getElementById('play').onclick=run;
document.getElementById('slow').onclick=()=>{speed=speed===1?0.55:1;
  document.getElementById('slow').textContent=speed===1?'Slower':'Normal speed';};
run();
</script></body></html>
"""

with open(OUT, "w", encoding="utf-8") as f:
    f.write(HTML.replace("__PAYLOAD__", payload))

print(f"wrote {OUT}  (code={len(code)} pts, spec={len(spec)} pts)")
