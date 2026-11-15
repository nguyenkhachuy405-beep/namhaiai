#!/bin/bash
# NAM HAI AI - cai may ve anh bao cao lai lo (Node + canvas) tren may chu Zalo VN
# Chay lai nhieu lan van an toan. Phai cai may chu Zalo (cai-dat-may-chu-zalo.sh) truoc.
set -e
export DEBIAN_FRONTEND=noninteractive
KEY_FILE=/etc/caddy/namhai.key
[ -s "$KEY_FILE" ] || { echo "Chua cai may chu Zalo (thieu $KEY_FILE)"; exit 1; }
KEY=$(cat "$KEY_FILE")
IP=$(curl -4 -s https://api.ipify.org)
TEN="$(echo "$IP" | tr . -).sslip.io"
for i in $(seq 1 60); do fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break; echo "Dang doi apt ranh... ($i)"; sleep 5; done
NODEV=$(node -v 2>/dev/null | sed 's/v\([0-9]*\).*/\1/')
if [ "${NODEV:-0}" -lt 18 ] 2>/dev/null || [ -z "$NODEV" ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
apt-get install -y fontconfig curl psmisc
D=/opt/namhai/ve
mkdir -p $D/fonts
cd $D
cat > package.json <<'PKEOF'
{ "name": "namhai-ve", "private": true, "dependencies": { "canvas": "^3.2.3", "jsdom": "^26.1.0" } }
PKEOF
npm install --omit=dev --no-audit --no-fund
lay() { [ -s "fonts/$1" ] || curl -fsSL -o "fonts/$1" "$2" || rm -f "fonts/$1"; }
lay BeVietnamPro-Medium.ttf   https://github.com/google/fonts/raw/main/ofl/bevietnampro/BeVietnamPro-Medium.ttf
lay BeVietnamPro-SemiBold.ttf https://github.com/google/fonts/raw/main/ofl/bevietnampro/BeVietnamPro-SemiBold.ttf
lay BeVietnamPro-Bold.ttf     https://github.com/google/fonts/raw/main/ofl/bevietnampro/BeVietnamPro-Bold.ttf
lay Lexend-Bold.ttf           https://github.com/googlefonts/lexend/raw/main/fonts/lexend/ttf/Lexend-Bold.ttf
cat > ve.js <<'VEEOF'
// NAM HAI AI - ve anh bao cao lai lo (dung CHINH code ve cua trang "Lai lo tung xe")
// Apps Script gui du lieu -> may nay ve anh -> tra ve JPEG. Khong luu du lieu.
const http = require('http'), fs = require('fs'), path = require('path');
const { registerFont, createCanvas, loadImage } = require('canvas');
const DIR = __dirname;
[['BeVietnamPro-Medium.ttf', 'Be Vietnam Pro', '500'], ['BeVietnamPro-SemiBold.ttf', 'Be Vietnam Pro', '600'],
 ['BeVietnamPro-Bold.ttf', 'Be Vietnam Pro', '700'], ['Lexend-Bold.ttf', 'Lexend', '700']].forEach(([f, family, weight]) => {
  const p = path.join(DIR, 'fonts', f); if (fs.existsSync(p)) registerFont(p, { family, weight });
});
const { JSDOM, ResourceLoader } = require('jsdom');
// chi nap anh nhung san (logo data:), khong tai gi tu mang
class ChiNoiBo extends ResourceLoader { fetch(url, o) { return /^data:/.test(url) ? super.fetch(url, o) : null; } }
const CONG = Number(process.env.NH_CONG || 9200);

// Nap trang Lai lo, bo thu vien ngoai, mo "cua" de goi duoc reportDays / buildReport
function napTrang() {
  let html = fs.readFileSync(path.join(DIR, 'Index.html'), 'utf8');
  html = html.replace(/<script[^>]+src=[^>]*><\/script>/g, '');
  const cuoi = html.lastIndexOf('})();');
  if (cuoi < 0) throw new Error('Index.html khong dung dang');
  html = html.slice(0, cuoi) + '  window.__NH={S:S,reportDays:reportDays,buildReport:buildReport};\n' + html.slice(cuoi);
  const dom = new JSDOM(html, {
    runScripts: 'dangerously', resources: new ChiNoiBo(), pretendToBeVisual: true,
    beforeParse(w) {
      const chay = {}; ['withSuccessHandler', 'withFailureHandler'].forEach(k => chay[k] = () => chay);
      w.google = { script: { run: new Proxy(chay, { get: (o, k) => o[k] || (() => {}) }) } };
    }
  });
  return new Promise((ok, loi) => {
    const t = setTimeout(() => loi(new Error('Trang khong nap xong')), 20000);
    dom.window.addEventListener('load', () => { clearTimeout(t); ok(dom.window); });
  });
}
let W = null;
async function trang() { if (!W || !W.__NH) W = await napTrang(); return W; }

async function veAnh(d) {
  const w = await trang(), NH = w.__NH;
  NH.S.from = d.from; NH.S.to = d.to;
  ['trips', 'tolls', 'extras', 'revenue', 'overhead'].forEach(k => NH.S.data[k] = (d.data && d.data[k]) || []);
  NH.S.imports = d.imports || [];
  NH.S.allDays = false;
  const RD = NH.reportDays();
  if (!RD.nFull) { const e = new Error('Khong co ngay nao du 4 bao cao'); e.ma = 422; throw e; }
  const cv = NH.buildReport(RD);
  const goc = await loadImage(Buffer.from(cv.toDataURL('image/png').split(',')[1], 'base64'));
  // Zalo nhan anh toi da 1MB -> thu nho + nen JPEG cho vua
  const rong = [1500, 1300, 1100], cl = [0.86, 0.8, 0.72];
  let buf = null, info = '';
  for (const r of rong) {
    const h = Math.round(goc.height * r / goc.width), c = createCanvas(r, h), x = c.getContext('2d');
    x.fillStyle = '#fff'; x.fillRect(0, 0, r, h); x.drawImage(goc, 0, 0, r, h);
    for (const q of cl) { buf = c.toBuffer('image/jpeg', { quality: q }); info = r + 'x' + h + ' q' + q; if (buf.length < 950000) return { buf, info }; }
  }
  return { buf, info };
}

http.createServer((req, res) => {
  const tra = (code, body, ct) => { res.writeHead(code, { 'Content-Type': ct || 'text/plain; charset=utf-8' }); res.end(body); };
  const url = req.url.replace(/^\/ve/, '') || '/';
  if (req.method === 'GET' && url.startsWith('/ping')) return tra(200, 've-anh ok');
  if (req.method !== 'POST' || !url.startsWith('/lai-lo')) return tra(404, 'khong co');
  const parts = [];
  req.on('data', c => parts.push(c));
  req.on('end', async () => {
    try {
      const d = JSON.parse(Buffer.concat(parts).toString('utf8'));
      const { buf, info } = await veAnh(d);
      res.writeHead(200, { 'Content-Type': 'image/jpeg', 'X-Anh': info, 'Content-Length': buf.length }); res.end(buf);
    } catch (e) { tra(e.ma || 500, 'loi ve anh: ' + (e.message || e)); }
  });
}).listen(CONG, '127.0.0.1', () => console.log('ve-anh chay cong ' + CONG));
VEEOF
cat > Index.html <<'IDXEOF'
<!DOCTYPE html>
<html lang="vi">
<head>
<base target="_top">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Lãi Lỗ Từng Xe</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Be+Vietnam+Pro:wght@400;500;600;700&family=Lexend:wght@500;600;700&display=swap">
<style>
/* Bố cục: một cột kiểu sổ điều hành; ô tra 5 số đuôi biển số là trung tâm, chi tiết xe hiện ngay dưới; màu hồng sen – xanh dương theo logo */
:root{
  --pink:#e4177e; --pink-d:#b30f60; --pink-soft:#fde7f2;
  --blue:#1d6db6; --blue-d:#164f86; --blue-soft:#e7f0fa;
  --bg:#f5f4f8; --surface:#ffffff; --ink:#172033; --muted:#5f6678; --line:#e5e1ea; --field:#fbfafc;
  --gain:#16834a; --gain-soft:#e2f4ea; --loss:#c8283a; --loss-soft:#fde9ec; --warn:#94650b; --warn-soft:#fff3d8;
  --plate:#ffd21f; --c-fuel:#1d6db6; --c-pay:#e4177e; --c-toll:#f0a020; --c-other:#7b8496;
  --f-display:"Lexend","Be Vietnam Pro",system-ui,sans-serif;
  --f-body:"Be Vietnam Pro",system-ui,-apple-system,"Segoe UI",sans-serif;
  --f-mono:ui-monospace,"SF Mono",Menlo,Consolas,monospace;
}
*{box-sizing:border-box}
body{background:var(--bg);color:var(--ink);font-family:var(--f-body);font-size:15px;line-height:1.5}
.wrap{max-width:1040px;margin:0 auto;padding:18px 16px 56px;display:flex;flex-direction:column;gap:18px}
header.top{background:var(--surface);border-radius:20px;padding:16px 22px;display:flex;align-items:center;gap:18px;flex-wrap:wrap;position:relative;overflow:hidden;border:1px solid var(--line)}
header.top::after{content:"";position:absolute;inset:auto 0 0 0;height:5px;background:linear-gradient(90deg,var(--blue),var(--pink))}
header .logo{height:64px;width:auto;flex:none}
header .ttl{flex:1;min-width:200px}
header small{display:block;text-transform:uppercase;letter-spacing:.14em;font-size:11px;color:var(--muted);font-weight:600}
header h1{font-family:var(--f-display);font-size:26px;margin:0;line-height:1.15;color:var(--blue-d);text-wrap:balance}
header h1 span{color:var(--pink)}
.range{display:flex;gap:8px;align-items:flex-end;flex-wrap:wrap}
.range label{display:flex;flex-direction:column;font-size:11px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;gap:3px}
.range input{width:140px}
.quick{display:flex;gap:6px;flex-wrap:wrap}
.quick button{font-size:12.5px;padding:6px 10px;border-radius:999px;background:var(--blue-soft);color:var(--blue-d);border:0}
section.card{background:var(--surface);border:1px solid var(--line);border-radius:18px;padding:20px;min-width:0}
h2{font-family:var(--f-display);font-size:18px;margin:0 0 14px;display:flex;align-items:center;gap:10px;flex-wrap:wrap}
h2 .note{font-family:var(--f-body);font-weight:400;font-size:13px;color:var(--muted)}
h3{font-size:12px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);margin:18px 0 8px;display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap}
input,select{font:inherit;padding:9px 12px;border-radius:11px;border:1.5px solid var(--line);background:var(--field);color:var(--ink);min-width:0}
input:focus,select:focus{border-color:var(--blue);outline:none;background:var(--surface)}
button{font:inherit;cursor:pointer;border-radius:11px;border:1.5px solid transparent;padding:9px 16px;font-weight:600}
button:focus-visible{outline:3px solid var(--pink-soft);outline-offset:2px}
button:disabled{opacity:.5;cursor:not-allowed}
.btn-pink{background:var(--pink);color:#fff}
.btn-blue{background:var(--blue);color:#fff}
.btn-ghost{background:var(--surface);border-color:var(--line);color:var(--ink)}
.btn-del{background:none;border:0;color:var(--loss);font-size:12.5px;padding:4px 6px;text-decoration:underline;font-weight:500}
.btn-del.armed{background:var(--loss);color:#fff;text-decoration:none;border-radius:8px}
.notice{padding:12px 14px;border-radius:12px;font-size:14px;background:var(--warn-soft);color:var(--warn)}
.notice.err{background:var(--loss-soft);color:var(--loss)}
.notice.ok{background:var(--gain-soft);color:var(--gain)}
/* Tra cứu */
.search{display:flex;gap:10px;align-items:stretch;flex-wrap:wrap}
.search .box{flex:1;min-width:220px;position:relative}
.search input{width:100%;font-family:var(--f-display);font-size:28px;letter-spacing:.3em;padding:14px 18px 14px 120px;border-radius:16px;border-width:2px;font-variant-numeric:tabular-nums}
.search .pre{position:absolute;left:18px;top:50%;transform:translateY(-50%);font-family:var(--f-display);font-size:13px;color:var(--muted);letter-spacing:.04em;pointer-events:none;line-height:1.2}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:12px}
/* Biển số vàng (xe kinh doanh vận tải) */
.chip{border:2px solid #1b1b1b;background:var(--plate);border-radius:7px;padding:4px 10px;font-family:var(--f-display);font-size:14px;font-weight:700;letter-spacing:.03em;color:#111;display:inline-flex;align-items:center;font-variant-numeric:tabular-nums}
.chip:hover{background:#ffe04d}
.chip[aria-pressed="true"]{outline:3px solid var(--blue);outline-offset:2px;box-shadow:0 2px 0 #1b1b1b}
.chip .pl{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:7px;border:1.5px solid #1b1b1b}
.ptag{display:inline-block;background:var(--plate);border:1.5px solid #1b1b1b;border-radius:5px;padding:1px 7px;color:#111;font-family:var(--f-display);font-weight:700;letter-spacing:.02em}
/* Chi tiết xe */
.plate{display:inline-flex;align-items:center;border:3px solid #1b1b1b;border-radius:8px;padding:4px 14px;font-family:var(--f-display);font-size:26px;font-weight:700;letter-spacing:.04em;background:var(--plate);color:#111}
.vhead{display:flex;gap:16px;align-items:center;flex-wrap:wrap;margin-bottom:6px}
.vhead .sub{color:var(--muted);font-size:13.5px;min-width:0;flex:1}
.kpis{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px;margin-top:14px}
@media (max-width:720px){.kpis{grid-template-columns:repeat(2,minmax(0,1fr))}}
.kpi{border:1px solid var(--line);border-radius:14px;padding:12px 14px;min-width:0}
.kpi .l{font-size:11.5px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);font-weight:600}
.kpi .v{font-family:var(--f-display);font-size:22px;font-variant-numeric:tabular-nums;overflow-wrap:anywhere;line-height:1.25;margin-top:2px}
.kpi .s{font-size:12px;color:var(--muted)}
.kpi.pl{border:0;color:#fff;background:linear-gradient(130deg,var(--gain),#23a35f)}
.kpi.pl.neg{background:linear-gradient(130deg,var(--loss),#e2475a)}
.kpi.pl .l,.kpi.pl .s{color:rgba(255,255,255,.85)}
.bar{display:flex;height:14px;border-radius:999px;overflow:hidden;background:var(--line);margin-top:14px}
.bar span{display:block;height:100%}
.legend{display:flex;flex-wrap:wrap;gap:6px 16px;margin-top:8px;font-size:13px;color:var(--muted)}
.legend b{color:var(--ink);font-variant-numeric:tabular-nums;font-weight:600}
.legend i{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:6px;vertical-align:middle}
.tbl{overflow-x:auto;border:1px solid var(--line);border-radius:12px}
table{width:100%;border-collapse:collapse;font-size:13.5px;font-variant-numeric:tabular-nums}
th{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);text-align:left;padding:9px 10px;background:var(--field);white-space:nowrap;font-weight:600}
td{padding:8px 10px;border-top:1px solid var(--line);white-space:nowrap}
td.wl{white-space:normal;min-width:200px}
.r{text-align:right}
tfoot td{font-weight:700;background:var(--field)}
tr.click{cursor:pointer}
tr.click:hover td{background:var(--blue-soft)}
.pos{color:var(--gain);font-weight:700} .neg{color:var(--loss);font-weight:700}
.mono{font-family:var(--f-mono);font-weight:600}
.empty{color:var(--muted);font-size:14px;padding:10px 0}
.revform{display:flex;gap:8px;flex-wrap:wrap;align-items:flex-end;margin-top:10px}
.revform label{display:flex;flex-direction:column;gap:3px;font-size:12px;font-weight:600;color:var(--muted)}
.revform input{width:150px}
.revform input.wide{width:220px}
/* Tải file */
.drop{border:2px dashed #d6cde0;border-radius:16px;padding:22px;text-align:center;color:var(--muted);cursor:pointer;display:flex;flex-direction:column;align-items:center;gap:6px;background:var(--field)}
.drop:hover,.drop.over{border-color:var(--pink);background:var(--pink-soft)}
.drop strong{color:var(--ink)}
.drop input{display:none}
.drop svg{width:34px;height:34px;color:var(--pink)}
.preview{margin-top:14px;display:flex;flex-direction:column;gap:10px}
.pv{border:1px solid var(--line);border-radius:12px;padding:12px 14px;display:flex;gap:10px;flex-wrap:wrap;align-items:center;justify-content:space-between}
.pv .t{font-weight:600;min-width:0;overflow-wrap:anywhere}
.pv .c{font-size:13px;color:var(--muted)}
.progress{height:6px;background:var(--line);border-radius:999px;overflow:hidden;margin-top:8px}
.progress span{display:block;height:100%;background:var(--pink);width:0;transition:width .2s}
.imports li{display:flex;justify-content:space-between;gap:8px;padding:8px 0;border-top:1px solid var(--line);font-size:13.5px;flex-wrap:wrap}
.imports{list-style:none;margin:0;padding:0}
.imports .m{color:var(--muted);font-size:12.5px}
.fold{margin:6px 0}
.fold>summary{list-style:none;cursor:pointer;border-radius:10px;padding:0 6px;margin:0 -6px}
.fold>summary::-webkit-details-marker{display:none}
.fold>summary:hover{background:var(--blue-soft)}
.fold>summary:focus-visible{outline:2px solid var(--blue-d);outline-offset:2px}
.fold>summary h3{margin:10px 0;align-items:center}
.fold .car{display:inline-block;margin-right:8px;transition:transform .15s}
.fold[open] .car{transform:rotate(90deg)}
.fold-b{padding-bottom:6px}
@media (prefers-reduced-motion:reduce){.fold .car{transition:none}}
.rp-btn{margin-left:auto;font-family:var(--f-body);font-size:14px;padding:8px 14px}
.rp-ov{position:fixed;inset:0;z-index:50;background:#0f1423;display:flex;flex-direction:column;gap:8px;padding:max(10px,env(safe-area-inset-top,0px)) max(10px,env(safe-area-inset-right,0px)) max(10px,env(safe-area-inset-bottom,0px)) max(10px,env(safe-area-inset-left,0px));overscroll-behavior:contain}
.rp-top{display:flex;gap:8px;flex-wrap:wrap;align-items:center;justify-content:space-between}
.rp-acts,.rp-zoom{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.rp-zoom button{min-width:44px;padding:8px 12px}
.rp-pct{color:#fff;font-size:13px;font-weight:600;min-width:44px;text-align:center;font-variant-numeric:tabular-nums}
.rp-stage{flex:1;min-height:0;position:relative;overflow:hidden;touch-action:none;background:#1b2234;border-radius:12px;cursor:grab;-webkit-user-select:none;user-select:none}
.rp-stage:active{cursor:grabbing}
.rp-stage img{position:absolute;left:0;top:0;transform-origin:0 0;max-width:none;display:block;-webkit-user-drag:none;pointer-events:none}
.rp-msg{font-size:13.5px;color:#7fe0ad;font-weight:600}
.rp-msg:empty{display:none}
.rp-hint{font-size:12.5px;color:#aab2c5;text-align:center}
.ovnote{display:flex;flex-direction:column;gap:8px;margin:4px 0 14px}
.ovseg{display:flex;gap:6px;flex-wrap:wrap}
.ovseg button{font-size:13.5px;padding:7px 12px}
.ovmsg{font-size:13.5px;line-height:1.55;color:var(--muted)}
.ovmsg.warn{color:#8a5a00;background:#fff6e0;border:1px solid #f1dca6;border-radius:10px;padding:8px 12px}
.ovmsg .hd{white-space:nowrap}
.tag{display:inline-block;font-size:11px;font-weight:600;padding:2px 8px;border-radius:999px;background:var(--blue-soft);color:var(--blue-d)}
.tag.p{background:var(--pink-soft);color:var(--pink-d)}
footer{text-align:center;color:var(--muted);font-size:12px}
/* Doanh thu theo kênh */
.chgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:8px;margin-top:10px}
.ch{border:1px solid var(--line);border-radius:12px;padding:10px 12px;min-width:0;border-left:5px solid var(--c)}
.ch .n{font-size:12.5px;color:var(--muted);font-weight:600}
.ch .p{font-family:var(--f-display);font-size:22px;line-height:1.2;font-variant-numeric:tabular-nums}
.ch .a{font-size:13px;font-variant-numeric:tabular-nums}
.ch.zero{opacity:.5}
.ch .k{font-size:12px;color:var(--muted);font-variant-numeric:tabular-nums}
.ch .k b{color:var(--ink);font-weight:600}
.kpi .kq{font-size:12px;font-weight:600;color:var(--pink-d);margin-top:3px;line-height:1.35}
.chnote{font-size:12.5px;color:var(--muted);margin-top:6px}
/* Tải file gọn */
.drop.sm{flex-direction:row;padding:12px 16px;text-align:left;gap:12px}
.drop.sm svg{width:26px;height:26px;flex:none}
.drop.sm span{font-size:12.5px}
.fbar{display:flex;gap:6px;flex-wrap:wrap;margin:6px 0 10px}
.fbar button{font-size:12.5px;padding:6px 12px;border-radius:999px;background:var(--surface);border:1.5px solid var(--line);color:var(--ink)}
.fbar button[aria-pressed="true"]{background:var(--ink);border-color:var(--ink);color:#fff}
.fbar b{font-variant-numeric:tabular-nums;margin-left:4px}
table.cov td{vertical-align:top;white-space:normal}
table.cov td.dt{white-space:nowrap;font-weight:600}
table.cov td.dt small{display:block;font-weight:400;color:var(--muted);font-size:11.5px}
.fc{display:flex;align-items:center;gap:4px;font-size:12.5px;max-width:230px}
.fc .nm{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.fc .ok{color:var(--gain);font-weight:700}
.fc+.fc{margin-top:3px}
.fc .x{background:none;border:0;color:var(--loss);padding:0 4px;font-size:14px;line-height:1;font-weight:700}
.fc .x.armed{background:var(--loss);color:#fff;border-radius:5px;font-size:11px;padding:2px 5px}
td.miss .lbl{color:var(--loss);font-size:12.5px;font-weight:600}
td.dup{background:var(--warn-soft)}
.st{display:inline-block;font-size:11px;font-weight:700;padding:2px 8px;border-radius:999px;margin:0 4px 3px 0;white-space:nowrap}
.st.ok{background:var(--gain-soft);color:var(--gain)} .st.miss{background:var(--loss-soft);color:var(--loss)} .st.dup{background:var(--warn-soft);color:var(--warn)} .st.none{background:var(--line);color:var(--muted)}
.ffilter{display:flex;gap:12px;flex-wrap:wrap;align-items:flex-end;margin-bottom:10px}
.ffilter label{display:flex;flex-direction:column;gap:4px;font-size:13px;font-weight:600;color:var(--muted)}
.ffilter select{min-width:170px;font-weight:600}
.ffilter input{width:220px}
.msum{font-size:14px;color:var(--muted);margin:2px 0 10px}
.msum b{color:var(--ink)}
.days{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:12px}
.day{width:44px;height:38px;padding:0;border-radius:9px;border:2px solid transparent;font-family:var(--f-display);font-size:15px;font-weight:600;font-variant-numeric:tabular-nums}
.day.ok{background:var(--gain-soft);color:var(--gain)}
.day.part{background:var(--warn-soft);color:var(--warn)}
.day.dup{background:var(--warn-soft);color:var(--warn);border-color:#e7b54a}
.day.none{background:var(--loss-soft);color:var(--loss)}
.day.fut{background:#e9e7ef;color:var(--muted)}
.day[aria-pressed="true"]{border-color:var(--blue);box-shadow:0 0 0 2px var(--blue-soft)}
.day.dim{opacity:.28}
.mleg{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:12.5px;color:var(--muted);margin:-4px 0 12px}
.mleg i{display:inline-block;width:11px;height:11px;border-radius:3px;margin-right:5px;vertical-align:middle}
details.all{margin-top:14px} details.all summary{cursor:pointer;font-size:13px;font-weight:600;color:var(--blue-d)}
@media (max-width:560px){header .logo{height:50px} header h1{font-size:22px} .search input{font-size:22px;padding-left:18px;padding-top:34px} .search .pre{top:10px;transform:none} .search .pre br{display:none} .kpi .v{font-size:18px} .vhead .sub{flex-basis:100%} .plate{font-size:22px}}
@media (prefers-reduced-motion:reduce){.progress span{transition:none}}
html,body{margin:0}
</style>
</head>
<body>
<div class="wrap">
  <header class="top">
    <img class="logo" src="data:image/png;base64,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" alt="Nam Hải Travel">
    <div class="ttl">
      <small>Nam Hải Travel · Sổ điều hành</small>
      <h1>Lãi lỗ <span>từng xe</span></h1>
    </div>
    <div class="range">
      <label for="dFrom">Từ ngày<input type="date" id="dFrom"></label>
      <label for="dTo">Đến ngày<input type="date" id="dTo"></label>
      <div class="quick">
        <button type="button" data-q="month">Tháng này</button>
        <button type="button" data-q="prev">Tháng trước</button>
        <button type="button" data-q="7">7 ngày</button>
      </div>
    </div>
  </header>

  <div id="status" class="notice" hidden></div>

  <section class="card" id="loginCard">
    <h2>Đăng nhập <span class="note">Dành cho quản lý và kế toán</span></h2>
    <form class="revform" id="fLogin" novalidate style="margin-top:0">
      <label for="pin">Mã PIN<input id="pin" type="password" inputmode="numeric" autocomplete="off"></label>
      <button class="btn-blue" type="submit">Vào xem số liệu</button>
    </form>
  </section>

  <div id="app" hidden style="display:flex;flex-direction:column;gap:18px">

  <section class="card">
    <h2>Tra cứu xe <span class="note" id="rangeNote"></span></h2>
    <form class="search" id="fSearch" novalidate>
      <div class="box">
        <span class="pre">5 số đuôi<br> biển số</span>
        <input id="q" inputmode="numeric" maxlength="5" autocomplete="off" placeholder="62876" aria-label="5 số đuôi biển số">
      </div>
      <button class="btn-blue" type="submit">Xem xe</button>
    </form>
    <div class="chips" id="plateChips" aria-label="Các xe có dữ liệu"></div>
    <div id="detail"></div>
  </section>

  <section class="card">
    <h2>Tổng hợp các xe <span class="note">Bấm vào một xe để xem chi tiết</span><button class="btn-pink rp-btn" id="btnReport" type="button">Ảnh báo cáo gửi Zalo</button></h2>
    <div id="ovNote" class="ovnote"></div>
    <div id="ovCh" style="margin-bottom:14px"></div>
    <div class="tbl"><table>
      <thead><tr><th>Biển số</th><th class="r">Chuyến</th><th class="r">Doanh thu</th><th class="r">Dầu</th><th class="r">Tiền tài</th><th class="r">Cầu đường</th><th class="r">Khác</th><th class="r">Tổng chi</th><th class="r">Lãi / lỗ</th></tr></thead>
      <tbody id="ovBody"></tbody><tfoot id="ovFoot"></tfoot>
    </table></div>
    <div class="empty" id="ovEmpty" hidden>Chưa có dữ liệu trong khoảng ngày này. Tải file bảng kê ở mục bên dưới.</div>
    <div id="ohBox"></div>
  </section>

  <section class="card">
    <h2>Tải file bảng kê <span class="note">Bảng kê chi phí và báo cáo doanh thu hằng ngày</span></h2>
    <label class="drop sm" id="drop" for="fFile">
      <input type="file" id="fFile" accept=".xlsx,.xls" multiple>
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 16V4M7 9l5-5 5 5"/><path d="M4 16v3a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-3"/></svg>
      <div><strong>Chọn hoặc kéo thả file Excel</strong><br><span>Bảng kê dầu + tài · phí cầu đường · báo cáo doanh thu. Tải lại cùng file sẽ ghi đè, không cộng trùng.</span></div>
    </label>
    <div class="preview" id="preview"></div>
    <h3><span>Kiểm tra file theo ngày</span><span class="tag" id="covRange"></span></h3>
    <div class="ffilter">
      <label for="fMonth">Tháng<select id="fMonth"></select></label>
      <label for="fName">Tìm theo tên file<input id="fName" autocomplete="off" placeholder="VD: 12-10"></label>
    </div>
    <div class="msum" id="mSum"></div>
    <div class="days" id="mDays" aria-label="Các ngày trong tháng"></div>
    <div class="mleg"><span><i style="background:var(--gain-soft);border:1px solid var(--gain)"></i>Đủ 3 loại file</span><span><i style="background:var(--warn-soft);border:1px solid var(--warn)"></i>Thiếu một phần / trùng</span><span><i style="background:var(--loss-soft);border:1px solid var(--loss)"></i>Chưa có file</span><span><i style="background:#e9e7ef"></i>Chưa tới ngày</span></div>
    <div class="fbar" id="fbar"></div>
    <div class="tbl"><table class="cov"><thead><tr><th>Ngày</th><th>Dầu + tài</th><th>Cầu đường</th><th>Doanh thu</th><th>Thu chi</th><th>Tình trạng</th></tr></thead><tbody id="covBody"></tbody></table></div>
    <div class="empty" id="covEmpty" hidden></div>
    <details class="all"><summary id="allSum">Tất cả file đã tải</summary>
      <ul class="imports" id="imports"><li class="m">Chưa có file nào.</li></ul>
    </details>
  </section>

  </div>
  <footer>Nam Hải Travel · Lãi lỗ từng xe · <button class="btn-del" type="button" id="logout">Đăng xuất</button></footer>
</div>

<script src="https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js"></script>
</body>
</html>
<script>
(function(){
  var $=function(s){return document.querySelector(s);};
  var COLS=['trips','tolls','extras','revenue','overhead'];
  var S={pin:'', from:'', to:'', data:{trips:[],tolls:[],extras:[],revenue:[],overhead:[]}, imports:[], unsub:[], sel:'', pending:[], ff:'all', fq:'', fday:''};

  /* ---------- gọi máy chủ ---------- */
  function call1(fn,a){ return new Promise(function(res,rej){ var r=google.script.run.withSuccessHandler(res).withFailureHandler(rej); r[fn].apply(r,a); }); }
  function isNet(e){ return /NetworkError|HTTP 0|Failed to fetch/i.test(String((e&&e.message)||e)); }
  function call(fn){ var a=[].slice.call(arguments,1);
    return call1(fn,a).catch(function(e){ if(!isNet(e)) throw e; return new Promise(function(r){ setTimeout(r,1500); }).then(function(){ return call1(fn,a); }); }); }
  function errText(e){ if(isNet(e)) return 'Mất kết nối tới máy chủ Google. Kiểm tra mạng, tải lại trang (F5) rồi thử lại.'; return String((e&&e.message)||e||'Lỗi').replace(/^(Exception|Error):\s*/,''); }
  function fail(e){ if(/PIN/.test(errText(e))){ logout(); } status(errText(e),'err'); }

  /* ---------- tiện ích ---------- */
  function el(tag,attrs){var e=document.createElement(tag);attrs=attrs||{};
    Object.keys(attrs).forEach(function(k){var v=attrs[k]; if(v==null) return; if(k==='class') e.className=v; else if(k==='text') e.textContent=v; else if(k.indexOf('on')===0) e.addEventListener(k.slice(2),v); else e.setAttribute(k,v);});
    for(var i=2;i<arguments.length;i++){var c=arguments[i]; if(c==null) continue; [].concat(c).forEach(function(x){ if(x!=null&&x!==false) e.append(x.nodeType?x:document.createTextNode(String(x))); });}
    return e;}
  function money(n){ return Math.round(Number(n)||0).toLocaleString('vi-VN'); }
  function vnd(n){ return money(n)+'đ'; }
  function pad(n){ return String(n).padStart(2,'0'); }
  function iso(d){ return d.getFullYear()+'-'+pad(d.getMonth()+1)+'-'+pad(d.getDate()); }
  function dmy(s){ var p=String(s).split('-'); return p.length===3?p[2]+'/'+p[1]+'/'+p[0]:s; }
  function status(t,kind){ var s=$('#status'); if(!t){ s.hidden=true; return; } s.textContent=t; s.className='notice'+(kind?' '+kind:''); s.hidden=false; }
  function normPlate(p){ var s=String(p||'').toUpperCase().replace(/[^A-Z0-9]/g,''); var m=s.match(/^(\d{2}[A-Z]{1,2}\d{4,5})[A-Z]$/); return m?m[1]:s; }
  function fmtPlate(p){ var m=String(p).match(/^(\d{2}[A-Z]{1,2})(\d{3})(\d{2})$/); if(m) return m[1]+'-'+m[2]+'.'+m[3]; m=String(p).match(/^(\d{2}[A-Z]{1,2})(\d{4})$/); return m?m[1]+'-'+m[2]:p; }
  function last5(p){ return String(p).slice(-5); }
  function safeId(s){ return String(s).replace(/[^A-Za-z0-9_\-.~:@+]/g,'_').slice(0,190); }
  function strip(s){ return String(s==null?'':s).normalize('NFD').replace(/[̀-ͯ]/g,'').replace(/đ/g,'d').replace(/Đ/g,'D').toUpperCase().replace(/\s+/g,' ').trim(); }

  /* ---------- loại file & kênh bán ---------- */
  var KIND=[['cost','Dầu + tài'],['toll','Cầu đường'],['rev','Doanh thu'],['vp','Thu chi']];
  function kindsOf(c){ var k=[]; if((c.trips||0)+(c.extras||0)) k.push('cost'); if(c.tolls) k.push('toll'); if(c.revenue) k.push('rev'); if(c.office) k.push('vp'); return k; }
  function kindName(k){ return KIND.filter(function(x){ return x[0]===k; })[0][1]; }
  function impIdOf(p){ return p.impId || safeId('I_'+(p.date||iso(new Date()))+'_'+p.fileName); }
  function impById(id){ return S.imports.filter(function(x){ return x.id===id; })[0] || {id:id, fileName:String(id).replace(/^I_\d{4}-\d{2}-\d{2}_/,'')}; }
  /* tên trong ghi chú báo cáo → tên hiển thị, màu */
  var CHN=[['VXR','Vexere','#f26a21'],['Văn phòng','Văn phòng','#1d6db6'],['Đại lý','Đại lý offline','#7b5bd6'],['12GO','12GO','#13a89e'],['NN Travel','NN Travel','#e4177e'],['RedBus','RedBus','#c8283a'],['Web','Website','#94650b']];
  function channelSplit(revs){
    var s={}, q={}, pt=0, tay=0, hasQ=false;
    revs.forEach(function(r){
      if(r.src==='tay'){ tay+=r.amount||0; return; }
      String(r.note||'').split(' · ').forEach(function(part){ var m=part.trim().match(/^(.+?)\s+([\d.]+)(?:\s*\((\d+)\s*(?:khách|vé)\))?$/); if(!m) return;
        var v=Number(m[2].replace(/\./g,''))||0; if(m[1]==='Phụ thu') pt+=v; else { s[m[1]]=(s[m[1]]||0)+v; if(m[3]){ q[m[1]]=(q[m[1]]||0)+Number(m[3]); hasQ=true; } } });
    });
    return {s:s, q:q, hasQ:hasQ, pt:pt, tay:tay};
  }
  var SHORT={'VXR':'VXR','Văn phòng':'VP','Đại lý':'ĐL','12GO':'12GO','NN Travel':'NN','RedBus':'RB','Web':'Web'};
  function guestLine(revs){
    var c=channelSplit(revs);
    if(!c.hasQ) return revs.some(function(r){ return r.src!=='tay'; })?'Chưa có khách theo kênh · tải lại báo cáo doanh thu':'';
    return CHN.filter(function(x){ return c.q[x[0]]; }).sort(function(a,b){ return c.q[b[0]]-c.q[a[0]]; })
      .map(function(x){ return SHORT[x[0]]+' '+c.q[x[0]]; }).join(' · ');
  }
  function renderChannels(revs,total,title){
    var wrap=el('div');
    if(!total){ return wrap; }
    var c=channelSplit(revs), known=0;
    var items=CHN.map(function(x){ var v=c.s[x[0]]||0; known+=v; return {name:x[1], v:v, k:c.q[x[0]]||0, color:x[2], opt:x[0]==='Web'}; })
      .filter(function(it){ return !it.opt||it.v||it.k; });
    if(c.tay){ items.push({name:'Nhập tay',v:c.tay,color:'#5f6678'}); known+=c.tay; }
    var rest=total-known; if(rest>1000) items.push({name:'Chưa rõ kênh',v:rest,color:'#b9bfcc'});
    items.sort(function(a,b){ return b.v-a.v; });
    var base=Math.max(total,known);
    var tk=revs.reduce(function(a,r){ return a+(r.tickets||0); },0), qk=items.reduce(function(a,it){ return a+(it.k||0); },0);
    wrap.append(el('h3',null,el('span',null,title||'Doanh thu theo kênh bán'),el('span',{class:'tag p'},'Tổng '+vnd(total)+(tk?' · '+tk+' khách':''))));
    var bar=el('div',{class:'bar',role:'img','aria-label':'Cơ cấu doanh thu theo kênh',style:'margin-top:4px'});
    items.forEach(function(it){ if(it.v>0) bar.append(el('span',{style:'width:'+(it.v/base*100)+'%;background:'+it.color,title:it.name+': '+vnd(it.v)})); });
    wrap.append(bar);
    var g=el('div',{class:'chgrid'});
    items.forEach(function(it){ var pc=total?it.v/total*100:0;
      g.append(el('div',{class:'ch'+(it.v?'':' zero'),style:'--c:'+it.color},
        el('div',{class:'n'},it.name), el('div',{class:'p'},(pc>0&&pc<1?pc.toFixed(1):Math.round(pc))+'%'), el('div',{class:'a'},vnd(it.v)),
        el('div',{class:'k'}, c.hasQ&&it.k!=null&&('k' in it) ? [el('b',null,it.k+' khách'), it.k?' · '+(tk?Math.round(it.k/tk*100)+'% khách':''):''] : ''),
        c.hasQ&&it.k ? el('div',{class:'k'},'TB '+vnd(it.v/it.k)+'/khách') : null)); });
    wrap.append(g);
    var notes=[]; if(c.pt) notes.push('Phụ thu '+vnd(c.pt)+' ('+Math.round(c.pt/total*100)+'%)');
    notes.push('% tính trên tổng doanh thu '+vnd(total));
    if(c.hasQ && tk && qk!==tk) notes.push('Số khách theo kênh: '+qk+' / '+tk+' khách');
    if(!c.hasQ && revs.some(function(r){ return r.src!=='tay'; })) notes.push('Chưa có số khách theo kênh: tải lại báo cáo doanh thu để cập nhật (ghi đè, không cộng trùng)');
    wrap.append(el('div',{class:'chnote'},notes.join(' · ')));
    return wrap;
  }

  /* ---------- khoảng ngày ---------- */
  function setRange(a,b){ S.from=a; S.to=b; $('#dFrom').value=a; $('#dTo').value=b; try{ localStorage.setItem('ll_range',JSON.stringify([a,b])); }catch(e){} subscribe(); }
  function quick(q){ var d=new Date();
    if(q==='month') setRange(iso(new Date(d.getFullYear(),d.getMonth(),1)), iso(new Date(d.getFullYear(),d.getMonth()+1,0)));
    if(q==='prev') setRange(iso(new Date(d.getFullYear(),d.getMonth()-1,1)), iso(new Date(d.getFullYear(),d.getMonth(),0)));
    if(q==='7') setRange(iso(new Date(d.getFullYear(),d.getMonth(),d.getDate()-6)), iso(d)); }
  document.querySelectorAll('.quick button').forEach(function(b){ b.addEventListener('click',function(){ quick(b.dataset.q); }); });
  ['#dFrom','#dTo'].forEach(function(s){ $(s).addEventListener('change',function(){ var a=$('#dFrom').value, b=$('#dTo').value; if(a&&b){ if(a>b){ var t=a; a=b; b=t; } setRange(a,b); } }); });

  /* ---------- đọc file Excel ---------- */
  function dateParts(v){ if(typeof v==='number'){ var p=XLSX.SSF.parse_date_code(v); if(p&&p.y>1990) return {date:p.y+'-'+pad(p.m)+'-'+pad(p.d), time:(p.H||p.M)?pad(p.H)+':'+pad(p.M):''}; }
    if(typeof v==='string'){ var m=v.match(/(\d{1,2})\/(\d{1,2})\/(\d{4})/); if(m) return {date:m[3]+'-'+pad(m[2])+'-'+pad(m[1]), time:''}; } return null; }
  function timeStr(v){ if(typeof v==='number'){ var f=v%1; var mins=Math.round(f*1440); return pad(Math.floor(mins/60)%24)+':'+pad(mins%60); } var m=String(v||'').match(/(\d{1,2})[:h](\d{2})/); return m?pad(m[1])+':'+m[2]:''; }
  function num(v){ if(typeof v==='number') return v; var s=String(v||'').replace(/[^\d\-]/g,''); return s?Number(s):0; }
  function findHeader(rows, need){ for(var i=0;i<Math.min(rows.length,30);i++){ var r=(rows[i]||[]).map(strip); if(need.every(function(n){ return r.some(function(c){ return c.indexOf(n)>=0; }); })) return {i:i, cols:r}; } return null; }
  function col(h,name){ for(var j=0;j<h.cols.length;j++) if(h.cols[j].indexOf(name)>=0) return j; return -1; }
  function reportDate(rows){ for(var i=0;i<6;i++){ var s=strip((rows[i]||[]).join(' ')); var m=s.match(/NGAY\s*(\d{1,2})\s*THANG\s*(\d{1,2})\s*NAM\s*(\d{4})/); if(m) return m[3]+'-'+pad(m[2])+'-'+pad(m[1]); } return ''; }
  /* Ngày ghi trong tên file (VD: "DOANH THU ... 11-10-2026.xlsx", "11.10_DẦU ...xlsx") */
  function fileDate(name, fallbackYear){ var s=String(name).replace(/\.xlsx?$/i,'');
    var m=s.match(/(?:^|[^\d])(\d{1,2})[-_.](\d{1,2})[-_.](\d{4})(?!\d)/) || s.match(/^\s*(\d{1,2})[._-](\d{1,2})(?![\d])/);
    if(!m) return ''; var d=+m[1], mo=+m[2], y=m[3]||fallbackYear; if(!y||d<1||d>31||mo<1||mo>12) return ''; return y+'-'+pad(mo)+'-'+pad(d); }
  function checkDate(out, titleDate, kind){ var fd=fileDate(out.fileName, titleDate?titleDate.slice(0,4):'');
    if(fd&&titleDate&&fd!==titleDate){ out.warn.unshift('⚠ '+kind+': tiêu đề trong file ghi ngày '+dmy(titleDate)+' nhưng tên file là '+dmy(fd)+'. Trang đã lấy theo tên file ('+dmy(fd)+'). Nếu ngày này sai, bấm Bỏ và sửa lại file.'); out.dateFixed=1; return fd; }
    return titleDate||fd; }
  function routes(row,a,b){ var out=[]; for(var j=a;j<b;j++){ var m=String(row[j]==null?'':row[j]).match(/\(\s*([A-Z]{1,4})\s*-\s*([A-Z]{1,4})\s*\)/i); if(m) out.push(m[1].toUpperCase()+'-'+m[2].toUpperCase()); } return out.join(' → '); }
  var PLATE_RE=/(\d{2}[A-Z]{1,2})\s*-?\s*(\d{3})\.?(\d{2})/i;

  function parseWorkbook(wb, fileName){
    var out={fileName:fileName, date:'', trips:[], tolls:[], extras:[], revenue:[], overhead:[], warn:[]};
    var hasFuel=false, sheets={};
    wb.SheetNames.forEach(function(n){ sheets[n]=XLSX.utils.sheet_to_json(wb.Sheets[n],{header:1,raw:true,defval:null}); });
    // 1) Dầu + tài
    wb.SheetNames.forEach(function(n){ var rows=sheets[n]; var h=findHeader(rows,['SO XE','TIEN DAU','TIEN TAI']); if(!h) return; hasFuel=true;
      var rd=reportDate(rows); if(rd&&!out.dateChecked){ out.dateChecked=1; var fx=checkDate(out,rd,'Bảng kê chi phí'); if(fx!==rd){ out.shift=[rd,fx]; } } if(out.shift&&rd===out.shift[0]) rd=out.shift[1]; if(rd&&!out.date) out.date=rd;
      var cP=col(h,'SO XE'), cD=col(h,'TAI XE'), cL=col(h,'LIT'), cR=col(h,'LICH TRINH'), cG=col(h,'GIA DAU'), cF=col(h,'TIEN DAU'), cT=col(h,'TIEN TAI');
      var lastPlate='', lastDriver='', seen={};
      for(var i=h.i+1;i<rows.length;i++){ var r=rows[i]||[]; var flat=strip(r.join(' '));
        if(/TONG/.test(strip(r[cP]))||/^TONG/.test(strip(r[cD]))) break;
        if(/PHI CAU DUONG/.test(flat)) continue;
        var fuel=num(r[cF]), pay=num(r[cT]); if(!fuel&&!pay) continue;
        var plate=normPlate(r[cP]); var driver=String(r[cD]||'').trim();
        if(!plate){ plate=lastPlate; if(!driver) driver=lastDriver; } else { lastPlate=plate; lastDriver=driver; }
        if(!plate){ out.warn.push('Dòng '+(i+1)+' trang "'+n.trim()+'" không có biển số, đã bỏ qua.'); continue; }
        var dp=dateParts(r[0]); var date=(dp&&dp.date)||rd; var t=timeStr(r[1])||timeStr(r[cR]);
        var rt=routes(r,cR,cG>0?cG:r.length);
        var key=date+'_'+plate+'_'+t.replace(':','')+'_'+rt.replace(/[^A-Z]/g,''); seen[key]=(seen[key]||0)+1; if(seen[key]>1) key+='_'+seen[key];
        out.trips.push({id:safeId(key), date:date, plate:plate, last5:last5(plate), time:t, driver:driver, route:rt, liters:num(r[cL]), price:num(r[cG]), fuel:fuel, pay:pay});
      } });
    // 2) Trang TÀI: lấy trung chuyển; nếu file không có trang dầu thì lấy cả tiền tài
    wb.SheetNames.forEach(function(n){ var rows=sheets[n]; var h=findHeader(rows,['SO XE','TIEN TAI']); if(!h||col(h,'TIEN DAU')>=0) return;
      var rd=reportDate(rows); if(rd&&!out.date) out.date=rd;
      var cP=col(h,'SO XE'), cD=col(h,'TAI XE'), cR=col(h,'LICH TRINH'), cT=col(h,'TIEN TAI'), cN=col(h,'GHI CHU');
      var lastPlate='', lastDriver='', seen={};
      for(var i=h.i+1;i<rows.length;i++){ var r=rows[i]||[]; if(/TONG/.test(strip(r[cP]))) break;
        var amt=num(r[cT]); if(!amt) continue; var dtext=strip(r[cD]); var note=strip(r[cN]);
        var date=rd||((dateParts(r[0])||{}).date||'');
        if(/TRUNG CHUYEN/.test(dtext)||/TRUNG CHUYEN/.test(note)){ var m=String(r[cD]||'').match(PLATE_RE); if(!m) continue; var p=normPlate(m[1]+m[2]+m[3]);
          var trip=String(r[cR+2]||'').trim(); var k='TC_'+date+'_'+p+'_'+timeStr(r[cR]).replace(':',''); seen[k]=(seen[k]||0)+1; if(seen[k]>1) k+='_'+seen[k];
          out.extras.push({id:safeId(k), date:date, plate:p, last5:last5(p), kind:'Trung chuyển', amount:amt, note:'Chuyến '+(routes(r,cR,cT)||'')+(trip?' ngày '+trip:'')});
          continue; }
        if(/THE CHAN/.test(dtext)||/THE CHAN/.test(note)) continue;
        if(hasFuel) continue;
        var plate=normPlate(r[cP]); var driver=String(r[cD]||'').trim(); if(!plate){ plate=lastPlate; if(!driver) driver=lastDriver; } else { lastPlate=plate; lastDriver=driver; }
        if(!plate) continue; var t=timeStr(r[1])||timeStr(r[cR]); var rt=routes(r,cR,cT);
        var key=date+'_'+plate+'_'+t.replace(':','')+'_'+rt.replace(/[^A-Z]/g,''); seen[key]=(seen[key]||0)+1; if(seen[key]>1) key+='_'+seen[key];
        out.trips.push({id:safeId(key), date:date, plate:plate, last5:last5(plate), time:t, driver:driver, route:rt, liters:0, price:0, fuel:0, pay:amt});
      } });
    // 3) Phí cầu đường (bảng kê hoá đơn điện tử)
    wb.SheetNames.forEach(function(n){ var rows=sheets[n]; var h=findHeader(rows,['BIEN SO','SAU THUE']); if(!h) return;
      var cG=col(h,'MA GIAO DICH'), cD=col(h,'NGAY PHAT SINH HOA DON'), cP=col(h,'BIEN SO'), cA=col(h,'SAU THUE'), cS=col(h,'TRAM'), cN=col(h,'SO HOA DON');
      for(var i=h.i+1;i<rows.length;i++){ var r=rows[i]||[]; if(typeof r[0]!=='number') { if(/TONG/.test(strip(r.join(' ')))) break; continue; }
        var p=normPlate(r[cP]); var amt=num(r[cA]); if(!p||!amt) continue; var dp=dateParts(r[cD])||{date:out.date,time:''};
        var gid=String(r[cG]||r[cN]||(dp.date+p+i));
        out.tolls.push({id:safeId('T'+gid), date:dp.date, time:dp.time, plate:p, last5:last5(p), amount:amt, station:String(r[cS]||'').trim()});
        if(!out.date) out.date=dp.date;
      } });
    // 3b) Phí cầu đường dạng "LỊCH SỬ THAY ĐỔI TÀI KHOẢN" (ePass/VETC): chỉ lấy dòng Trừ tiền, biển số đọc từ cột Mô tả
    var tollSeen={}; out.tolls.forEach(function(t){ tollSeen[t.id]=1; });
    wb.SheetNames.forEach(function(n){ var rows=sheets[n]; var h=findHeader(rows,['MA GIAO DICH','SO TIEN','MO TA']); if(!h||col(h,'SAU THUE')>=0) return;
      var cG=col(h,'MA GIAO DICH'), cD=col(h,'NGAY GIAO DICH'), cA=col(h,'SO TIEN'), cK=col(h,'LOAI GIAO DICH'), cO=col(h,'TRANG THAI'), cM=col(h,'MO TA'), cS=col(h,'TRAM'), cP=col(h,'BIEN SO');
      for(var i=h.i+1;i<rows.length;i++){ var r=rows[i]||[]; if(typeof r[0]!=='number'){ if(/TONG/.test(strip(r[0]))) break; continue; }
        if(cK>=0&&!/TRU TIEN/.test(strip(r[cK]))) continue;            /* bỏ Nạp tiền, hoàn tiền */
        if(cO>=0&&r[cO]&&!/THANH CONG/.test(strip(r[cO]))) continue;
        var amt=num(r[cA]); if(!amt) continue;
        var desc=String(r[cM]||'').replace(/\s+/g,' ').trim();
        var pm=desc.match(/Xe\s+([0-9]{2}[A-Za-z]{1,2}[-.\s]?[0-9.]{4,7}[A-Za-z]?)\s+qua/i);
        var p=normPlate(cP>=0&&r[cP]?r[cP]:(pm?pm[1]:'')); if(!p) continue;
        var st=cS>=0&&r[cS]?String(r[cS]).trim():((desc.match(/qua\s+(?:đoạn|doan|trạm|tram)\s+(.+?)(?:,\s*l[uú]c\b.*)?$/i)||[])[1]||'');
        var dp=dateParts(r[cD])||{date:out.date,time:''}, lt=desc.match(/l[uú]c\s+\d{1,2}\/\d{1,2}\/\d{4}\s+(\d{1,2}:\d{2})/i);
        if(lt) dp={date:dp.date,time:(lt[1].length<5?'0':'')+lt[1]}; else if(!dp.time){ var de=dateParts(r[col(h,'HOAN THANH')]); if(de&&de.time) dp.time=de.time; }
        var id=safeId('T'+String(r[cG]||(dp.date+p+i))); if(tollSeen[id]) continue; tollSeen[id]=1;   /* 2 sheet giống nhau (PHÍ CẦU ĐƯỜNG, HD) chỉ tính 1 lần */
        out.tolls.push({id:id, date:dp.date, time:dp.time, plate:p, last5:last5(p), amount:amt, station:st});
        if(!out.date) out.date=dp.date;
      } });
    // 4a) Báo cáo doanh thu xe theo ngày khởi hành (BS XE | GIỜ ĐI | TUYẾN | kênh bán ... | TỔNG DOANH THU)
    var revDone={};
    wb.SheetNames.forEach(function(n){ var rows=sheets[n]; var h=findHeader(rows,['BS XE','TONG DOANH THU']); if(!h) return; revDone[n]=1;
      var sub=(rows[h.i+1]||[]).map(strip);
      function sc(name){ for(var j=0;j<sub.length;j++) if(sub[j]===name||sub[j].indexOf(name)===0) return j; return -1; }
      var cP=col(h,'BS XE'), cT=col(h,'GIO DI'), cR=col(h,'TUYEN'), cV=col(h,'TONG VE'), cPT=col(h,'PHU THU'), cTot=h.cols.indexOf('TONG DOANH THU'); if(cTot<0) cTot=col(h,'TONG DOANH THU');
      var CH=[['VXR','TONG THU VXR'],['Web','TONG THU WEB'],['Đại lý','TONG THU DLY'],['RedBus','TONG THU REDBUS'],['12GO','TONG THU 12GO'],['NN Travel','TONG THU NN TRAVEL'],['Văn phòng','VP THU']]
        .map(function(c){ return {name:c[0], col:sc(c[1])}; });
      var cDlyQty=sc('DLY OFFLINE');
      /* cột số khách của từng kênh: tên kênh đứng riêng (VXR, VP, DLY OFFLINE…) hoặc cột SL / SỐ VÉ nằm ngay trước cột tiền */
      var QN={'VXR':['VXR','SL VXR','VE VXR'],'Web':['WEB','SL WEB'],'Đại lý':['DLY OFFLINE','DLY','SL DLY'],'RedBus':['REDBUS','SL REDBUS'],'12GO':['12GO','SL 12GO'],'NN Travel':['NN TRAVEL','NN','SL NN TRAVEL'],'Văn phòng':['VP','VAN PHONG','SL VP','VP BAN']};
      function isQtyHead(x){ return x && !/THU|TIEN|DOANH|GIA/.test(x) && /^(SL|SO VE|SO LUONG|VE|KHACH|SO KHACH)\b/.test(x); }
      var moneyCols=CH.map(function(c){ return c.col; }).filter(function(j){ return j>=0; });
      CH.forEach(function(c){ c.q=-1;
        (QN[c.name]||[]).some(function(nm){ for(var j=0;j<sub.length;j++){ if(sub[j]===nm && moneyCols.indexOf(j)<0){ c.q=j; return true; } } return false; });
        if(c.q<0 && c.col>0){ for(var j=c.col-1;j>=Math.max(0,c.col-3);j--){ if(moneyCols.indexOf(j)>=0) break; if(isQtyHead(sub[j])){ c.q=j; break; } } }
        if(c.q<0 && c.name==='Đại lý' && cDlyQty>=0) c.q=cDlyQty; });
      if(CH.every(function(c){ return c.q<0; })) out.warn.push('Không tìm thấy cột số khách theo kênh trong báo cáo này (tiêu đề phụ: '+sub.filter(function(x){ return x; }).slice(0,14).join(' | ')+'). Gửi file này để chỉnh lại.');
      var date=''; for(var i0=0;i0<h.i;i0++){ var m=strip((rows[i0]||[]).join(' ')).match(/(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{4})/); if(m){ date=m[3]+'-'+pad(m[2])+'-'+pad(m[1]); break; } }
      date=checkDate(out,date,'Báo cáo doanh thu');
      if(!date){ out.warn.push('Không thấy ngày trong tiêu đề hoặc tên file báo cáo doanh thu (VD: BÁO CÁO DOANH THU 09-10-2026).'); return; }
      // gom dòng theo xe → giờ đi
      var trips=[], cur=null, plate='', veh=null, tm='', rt='', maxTot=0;
      for(var i=h.i+2;i<rows.length;i++){ var r=rows[i]||[]; var a0=String(r[cP]==null?'':r[cP]);
        if(/^\s*TONG/.test(strip(a0))) break;
        var pm=a0.match(/(\d{2}[A-Z]{1,2})\s*-?\s*(\d{3})\.?\s*(\d{2})/i);
        if(pm){ plate=normPlate(pm[1]+pm[2]+pm[3]); veh={plate:plate, info:a0.replace(pm[0],'').replace(/\s+/g,' ').trim(), nt:false}; tm=''; rt=''; cur=null; }
        if(!plate) continue;
        if(r[cR]!=null&&String(r[cR]).trim()){ rt=String(r[cR]).replace(/\s+/g,'').toUpperCase(); if(/NT/.test(rt)) veh.nt=true; }
        if(r[cV]==null) continue;               // dòng cộng của từng xe
        var t=timeStr(r[cT]); if(t&&t!==tm){ tm=t; cur=null; }
        var tot=num(r[cTot]); if(tot>maxTot) maxTot=tot; if(!tot&&!num(r[cV])) continue;
        if(!cur){ cur={veh:veh, plate:plate, time:tm, routes:[], tickets:0, gross:0, pt:0, ch:{}, q:{}, dlyQty:0}; trips.push(cur); }
        if(rt&&cur.routes.indexOf(rt)<0) cur.routes.push(rt);
        cur.tickets+=num(r[cV]); cur.gross+=tot; cur.pt+=num(r[cPT]); if(cDlyQty>=0) cur.dlyQty+=num(r[cDlyQty]);
        CH.forEach(function(c){ if(c.col>=0) cur.ch[c.name]=(cur.ch[c.name]||0)+num(r[c.col]); if(c.q>=0) cur.q[c.name]=(cur.q[c.name]||0)+num(r[c.q]); });
      }
      var unit=maxTot&&maxTot<100000?1000:1;      // báo cáo ghi đơn vị nghìn đồng
      var seen={};
      trips.forEach(function(tr){
        var c=tr.ch;
        var parts=Object.keys(c).filter(function(k){ return c[k]||tr.q[k]; }).map(function(k){ return k+' '+money(c[k]*unit)+(tr.q[k]?' ('+tr.q[k]+' khách)':''); }); if(tr.pt) parts.push('Phụ thu '+money(tr.pt*unit));
        var k='RV_'+date+'_'+tr.plate+'_'+(tr.time||'x').replace(':',''); seen[k]=(seen[k]||0)+1; if(seen[k]>1) k+='_'+seen[k];
        out.revenue.push({id:safeId(k), date:date, plate:tr.plate, last5:last5(tr.plate), time:tr.time, route:tr.routes.join(' + '), tickets:tr.tickets,
          gross:Math.round(tr.gross*unit), amount:Math.round(tr.gross*unit), note:parts.join(' · '), src:'bc'});
      });
      if(!out.date) out.date=date;
      out.kind='Báo cáo doanh thu';
    });
    // 4b) Doanh thu file mẫu đơn giản (Ngày | Số xe | Doanh thu | Ghi chú)
    wb.SheetNames.forEach(function(n){ if(revDone[n]) return; var rows=sheets[n]; var h=findHeader(rows,['DOANH THU']); if(!h) return;
      var cP=col(h,'SO XE'); if(cP<0) cP=col(h,'BIEN SO'); var cA=col(h,'DOANH THU'), cDt=col(h,'NGAY'), cN=col(h,'GHI CHU'); if(cP<0||cA<0) return;
      var rd=reportDate(rows), seen={};
      for(var i=h.i+1;i<rows.length;i++){ var r=rows[i]||[]; var p=normPlate(r[cP]); var amt=num(r[cA]); if(!p||!amt||/TONG/.test(strip(r[cP]))) continue;
        var date=(cDt>=0&&dateParts(r[cDt])||{}).date||rd; if(!date){ out.warn.push('Dòng doanh thu '+(i+1)+' không có ngày, đã bỏ qua.'); continue; }
        var k='R_'+date+'_'+p; seen[k]=(seen[k]||0)+1; if(seen[k]>1) k+='_'+seen[k];
        out.revenue.push({id:safeId(k), date:date, plate:p, last5:last5(p), amount:amt, gross:amt, note:cN>=0?String(r[cN]||'').trim():'', src:'file'});
        if(!out.date) out.date=date;
      } });
    // 5) Báo cáo thu chi trong ngày: lấy chi của từng văn phòng (VPSG, VPPT, VPMN, VPNT…), bỏ dòng chi công an
    wb.SheetNames.forEach(function(n){ var rows=sheets[n], hi=-1, tot={};
      for(var i=0;i<Math.min(rows.length,80);i++){ var r=(rows[i]||[]).map(strip);
        r.forEach(function(c,j){ var m=c.match(/^TONG CHI (VP[A-Z]+)$/); if(m){ hi=i; tot[m[1]]={j:j}; } }); if(hi>=0) break; }
      if(hi<0) return;
      Object.keys(tot).forEach(function(o){ tot[o].v=num((rows[hi+1]||[])[tot[o].j]); });
      var title=''; for(var i0=0;i0<4;i0++){ title=strip((rows[i0]||[]).join(' ')); if(/THU CHI/.test(title)) break; }
      var fy=(fileDate(fileName,'')||'').slice(0,4)||String(new Date().getFullYear());
      var tm=title.match(/(\d{1,2})[\/.-](\d{1,2})(?:[\/.-](\d{4}))?/), td=tm?(tm[3]||fy)+'-'+pad(tm[2])+'-'+pad(tm[1]):'';
      var date=checkDate(out,td,'Báo cáo thu chi');
      if(!date){ out.warn.push('Không thấy ngày trong tiêu đề hoặc tên file báo cáo thu chi (VD: BÁO CÁO THU CHI TRONG NGÀY 31-10-2026).'); return; }
      /* chi tiết từng văn phòng: dòng "VPSG CHI", dòng "NỘI DUNG CHI", rồi các khoản */
      var det={}, cur='', dropCA={};
      for(var i=hi+2;i<rows.length;i++){ var r=rows[i]||[], cells=r.map(strip), head='';
        cells.forEach(function(c){ var m=c.match(/^(VP[A-Z]+)\s*CHI$/); if(m) head=m[1]; });
        if(head){ cur=head; det[cur]=det[cur]||{sum:0,n:0}; continue; }
        if(!cur||cells.some(function(c){ return c==='NOI DUNG CHI'; })) continue;
        var desc='', amt=0; r.forEach(function(v){ if(typeof v==='number'){ amt=v; } else if(v!=null&&String(v).trim()&&!desc) desc=String(v).trim(); });
        if(!amt) continue;
        if(/CONG AN|TRAT TU/.test(strip(desc))){ dropCA[cur]=(dropCA[cur]||0)+amt; continue; }
        det[cur].sum+=amt; det[cur].n++; }
      Object.keys(tot).forEach(function(o){ var d=det[o], v=d&&d.n?d.sum:(tot[o].v-(dropCA[o]||0));
        if(d&&d.n&&Math.abs(d.sum+(dropCA[o]||0)-tot[o].v)>1) out.warn.push('Chi '+o+': ô TỔNG CHI ghi '+vnd(tot[o].v)+' nhưng các khoản cộng lại '+vnd(d.sum+(dropCA[o]||0))+'. Trang lấy theo các khoản.');
        out.overhead.push({id:safeId('VP_'+date+'_'+o), date:date, kind:'vp', office:o, amount:Math.max(0,v),
          note:(d&&d.n?d.n+' khoản':'theo ô tổng')+(dropCA[o]?' · bỏ '+vnd(dropCA[o])+' chi công an (lấy từ sổ quỹ)':'')}); });
      if(!out.date) out.date=date; out.kind='Báo cáo thu chi';
    });
    // 6) Sổ quỹ: sheet CHI CÔNG AN, bảng bên trái (Ngày chi | Diễn giải | Số tiền), tính theo ngày chi
    wb.SheetNames.forEach(function(n){ var rows=sheets[n]; var h=findHeader(rows,['NGAY CHI','DIEN GIAI','SO TIEN']); if(!h) return;
      if(!/CONG AN/.test(strip(n))&&!/CONG AN/.test(strip((rows[0]||[]).join(' ')))) return;
      var cD=col(h,'NGAY CHI'), cG=col(h,'DIEN GIAI'), cA=col(h,'SO TIEN'), cN=col(h,'NGUOI NHAN'), seen={}, months={};
      for(var i=h.i+1;i<rows.length;i++){ var r=rows[i]||[]; if(/TONG/.test(strip(r[cG]))) break;
        var dp=dateParts(r[cD]), amt=num(r[cA]); if(!dp||!amt) continue;
        var desc=String(r[cG]||'').replace(/\s+/g,' ').trim(), om=strip(desc).match(/^(VP[A-Z]+)/);
        var k='CA_'+dp.date+'_'+amt+'_'+strip(desc).replace(/[^A-Z0-9]/g,'').slice(0,40); seen[k]=(seen[k]||0)+1; if(seen[k]>1) k+='_'+seen[k];
        months[dp.date.slice(0,7)]=1;
        out.overhead.push({id:safeId(k), date:dp.date, kind:'ca', office:om?om[1]:'', amount:amt, note:(desc+(cN>=0&&r[cN]?' · nhận: '+String(r[cN]).trim():'')).slice(0,190)}); }
      var fm=String(fileName).match(/T\s*(\d{1,2})[._\-\s]*(\d{4})/i), mo=fm?fm[2]+'-'+pad(fm[1]):Object.keys(months).sort().pop();
      if(mo){ out.month=mo; out.impId=safeId('I_SQ_'+mo); out.replace=true; if(!out.date) out.date=mo+'-01'; }
      out.kind='Sổ quỹ';
    });
    // 7) Bảng thanh toán lương văn phòng (tháng): lấy cột Tổng thu nhập, tính trọn tháng
    wb.SheetNames.forEach(function(n){ var rows=sheets[n]; var h=findHeader(rows,['TEN NHAN VIEN','TONG THU NHAP']); if(!h) return;
      var top=''; for(var i0=0;i0<h.i;i0++) top+=' '+strip((rows[i0]||[]).join(' '));
      var om=top.match(/LUONG\s+(VP[A-Z]+)/)||strip(fileName).match(/\b(VP[A-Z]+)\b/), office=om?om[1]:'';
      if(!office){ var FN={'SAI GON':'VPSG','PHAN THIET':'VPPT','MUI NE':'VPMN','NHA TRANG':'VPNT'}; Object.keys(FN).forEach(function(k){ if(!office&&(top+' '+strip(fileName)).indexOf(k)>=0) office=FN[k]; }); }
      var mm=top.match(/THANG\s*(\d{1,2})\s*[\/.\-]\s*(\d{4})/), month=mm?mm[2]+'-'+pad(mm[1]):'';
      if(!month){ var fm=strip(fileName).match(/THANG\s*(\d{1,2})/), fy=strip(fileName).match(/(20\d{2})/); if(fm) month=(fy?fy[1]:String(new Date().getFullYear()))+'-'+pad(fm[1]); }
      if(!office||!month){ out.warn.push('Bảng lương "'+fileName+'": không thấy '+(!office?'tên văn phòng (VPSG, VPPT, VPMN, VPNT)':'tháng (VD: THÁNG 10/2026)')+' trong tiêu đề.'); return; }
      var cN=col(h,'TEN NHAN VIEN'), cT=col(h,'TONG THU NHAP'), sum=0, cnt=0, total=null;
      for(var i=h.i+1;i<rows.length;i++){ var r=rows[i]||[], flat=strip(r.join(' '));
        if(/TONG CONG/.test(flat)){ if(typeof r[cT]==='number') total=r[cT]; break; }
        var nm=String(r[cN]==null?'':r[cN]).trim(); if(!nm||typeof r[cT]!=='number') continue; sum+=r[cT]; cnt++; }
      var amt=Math.round(total!=null?total:sum);
      if(total!=null&&Math.abs(total-sum)>2) out.warn.push('Lương '+office+': dòng TỔNG CỘNG ghi '+vnd(total)+' nhưng cộng từng người ra '+vnd(sum)+'. Trang lấy theo dòng TỔNG CỘNG.');
      out.overhead.push({id:safeId('LG_'+office+'_'+month), date:month+'-01', kind:'lg', office:office, amount:amt, note:cnt+' nhân viên · lương tháng '+month.slice(5)+'/'+month.slice(0,4)});
      out.month=month; out.impId=safeId('I_LG_'+office+'_'+month); out.replace=true; out.date=month+'-01'; out.kind='Bảng lương '+office;
    });
    return out;
  }

  /* ---------- tải file ---------- */
  var drop=$('#drop');
  ['dragenter','dragover'].forEach(function(t){ drop.addEventListener(t,function(e){ e.preventDefault(); drop.classList.add('over'); }); });
  ['dragleave','drop'].forEach(function(t){ drop.addEventListener(t,function(e){ e.preventDefault(); drop.classList.remove('over'); }); });
  drop.addEventListener('drop',function(e){ handleFiles(e.dataTransfer.files); });
  $('#fFile').addEventListener('change',function(e){ handleFiles(e.target.files); e.target.value=''; });

  function handleFiles(files){
    if(!window.XLSX){ status('Chưa tải được bộ đọc Excel. Kiểm tra mạng rồi tải lại trang.','err'); return; }
    [].forEach.call(files,function(f){
      var rd=new FileReader();
      rd.onload=function(){ try{ var wb=XLSX.read(new Uint8Array(rd.result),{type:'array'}); var p=parseWorkbook(wb,f.name); S.pending.push(p); renderPreview(); }
        catch(err){ status('Không đọc được file '+f.name+': '+err.message,'err'); } };
      rd.onerror=function(){ status('Không mở được file '+f.name+'. Đóng file trong Excel rồi chọn lại.','err'); };
      rd.readAsArrayBuffer(f);
    });
  }
  function renderPreview(){
    var box=$('#preview'); box.innerHTML='';
    S.pending.forEach(function(p,ix){
      var n=p.trips.length+p.tolls.length+p.extras.length+p.revenue.length+p.overhead.length;
      var sum=function(a,k){ return a.reduce(function(s,x){ return s+(x[k]||0); },0); };
      var parts=[];
      if(p.trips.length) parts.push(p.trips.length+' chuyến (dầu '+vnd(sum(p.trips,'fuel'))+', tiền tài '+vnd(sum(p.trips,'pay'))+')');
      if(p.tolls.length) parts.push(p.tolls.length+' lượt cầu đường ('+vnd(sum(p.tolls,'amount'))+')');
      if(p.extras.length) parts.push(p.extras.length+' trung chuyển ('+vnd(sum(p.extras,'amount'))+')');
      if(p.revenue.length) parts.push(p.revenue.length+' chuyến có doanh thu: '+vnd(sum(p.revenue,'amount'))+(sum(p.revenue,'tickets')?' · '+sum(p.revenue,'tickets')+' vé':''));
      var ohV=p.overhead.filter(function(o){ return o.kind==='vp'; }), ohC=p.overhead.filter(function(o){ return o.kind==='ca'; });
      if(ohV.length) parts.push('chi văn phòng '+ohV.map(function(o){ return o.office+' '+vnd(o.amount); }).join(', ')+' · tổng '+vnd(sum(ohV,'amount')));
      var ohL=p.overhead.filter(function(o){ return o.kind==='lg'; });
      if(ohL.length) parts.push(ohL.map(function(o){ return 'lương '+o.office+' '+vnd(o.amount)+' ('+o.note+')'; }).join(', ')+' · tính trọn tháng, tải lại sẽ thay số cũ');
      if(ohC.length) parts.push(ohC.length+' lần chi công an: '+vnd(sum(ohC,'amount'))+' (tải lại sẽ thay hết dòng cũ của tháng này)');
      var dupMsg=[]; var pid=impIdOf(p); var pk=kindsOf({trips:p.trips.length,extras:p.extras.length,tolls:p.tolls.length,revenue:p.revenue.length,office:ohV.length});
      var same=S.imports.filter(function(im){ return im.id===pid||im.fileName===p.fileName; })[0];
      if(same) dupMsg.push('File này đã tải lúc '+same.at+'. Lưu lại sẽ ghi đè, không cộng trùng.');
      else S.imports.forEach(function(im){ if(!p.date||p.month||im.date!==p.date) return; var ov=kindsOf(im).filter(function(k){ return pk.indexOf(k)>=0; });
        if(ov.length) dupMsg.push('⚠ Ngày '+dmy(p.date)+' đã có file "'+im.fileName+'" ('+ov.map(kindName).join(', ')+'). Kiểm tra kẻo trùng.'); });
      var bar=el('div',{class:'progress',hidden:''},el('span'));
      var btnSave=el('button',{class:'btn-pink',type:'button',disabled:n?null:'',onclick:function(){ saveImport(p,btnSave,bar,ix); }},'Lưu vào hệ thống');
      box.append(el('div',{class:'pv'},
        el('div',{style:'min-width:0;flex:1'}, el('div',{class:'t'},p.fileName), el('div',{class:'c'},(p.month?(p.kind&&/^Bảng lương/.test(p.kind)?p.kind:'Sổ quỹ')+' tháng '+p.month.slice(5)+'/'+p.month.slice(0,4)+' · ':p.date?'Ngày '+dmy(p.date)+' · ':'')+(parts.join(' · ')||'Không tìm thấy dữ liệu nào trong file này.')),
          dupMsg.length?el('div',{class:'notice',style:'margin-top:8px;font-size:13px'},dupMsg.slice(0,3).join(' ')):null,
          p.warn.length?el('div',{class:'notice'+(p.dateFixed?' err':''),style:'margin-top:8px;font-size:13px'},p.warn.slice(0,3).join(' ')):null, bar),
        el('div',{style:'display:flex;gap:8px'}, el('button',{class:'btn-ghost',type:'button',onclick:function(){ S.pending.splice(ix,1); renderPreview(); }},'Bỏ'), btnSave)));
    });
  }
  function runPool(tasks,limit,onStep){ var i=0, done=0; return new Promise(function(res,rej){ var active=0, failed=false;
    function next(){ if(failed) return; if(done===tasks.length) return res(); while(active<limit&&i<tasks.length){ (function(t){ active++; t().then(function(){ active--; done++; onStep(done); next(); }).catch(function(e){ failed=true; rej(e); }); })(tasks[i++]); } }
    next(); }); }
  function saveImport(p,btn,bar,ix){
    btn.disabled=true; bar.hidden=false; bar.firstChild.style.width='35%';
    var clean=function(a){ return a.map(function(x){ var d=Object.assign({},x); delete d.last5; return d; }); };
    var payload={impId:impIdOf(p), fileName:p.fileName, date:p.date||'',
      trips:clean(p.trips), tolls:clean(p.tolls), extras:clean(p.extras), revenue:clean(p.revenue), overhead:clean(p.overhead), replace:!!p.replace};
    call('saveImport',S.pin,payload).then(function(){ bar.firstChild.style.width='100%';
        status('Đã lưu '+p.fileName+'.','ok'); setTimeout(function(){ status(''); },4000); S.pending.splice(S.pending.indexOf(p),1); renderPreview(); loadImports();
        if(p.date && (p.date<S.from||p.date>S.to)){ var d=new Date(p.date+'T00:00:00'); setRange(iso(new Date(d.getFullYear(),d.getMonth(),1)), iso(new Date(d.getFullYear(),d.getMonth()+1,0))); } else load(); })
      .catch(function(e){ btn.disabled=false; bar.hidden=true; fail(e); });
  }

  /* ---------- dữ liệu ---------- */
  function subscribe(){ load(); }
  function load(){
    $('#rangeNote').textContent='Từ '+dmy(S.from)+' đến '+dmy(S.to);
    if(!S.pin){ render(); return Promise.resolve(); }
    return call('getRange',S.pin,S.from,S.to).then(function(d){ COLS.forEach(function(c){ S.data[c]=d[c]||[]; }); render(); }).catch(fail);
  }
  function aggregate(D){
    D=D||S.data; var by={};
    function g(p){ return by[p]||(by[p]={plate:p, trips:0, liters:0, fuel:0, pay:0, toll:0, other:0, rev:0, gross:0, tickets:0, drivers:{}}); }
    D.trips.forEach(function(t){ var a=g(t.plate); a.trips++; a.liters+=t.liters||0; a.fuel+=t.fuel||0; a.pay+=t.pay||0; if(t.driver) a.drivers[t.driver]=1; });
    D.tolls.forEach(function(t){ g(t.plate).toll+=t.amount||0; });
    D.extras.forEach(function(t){ g(t.plate).other+=t.amount||0; });
    D.revenue.forEach(function(t){ var a=g(t.plate); a.rev+=t.amount||0; a.gross+=(t.gross||t.amount||0); a.tickets+=(t.tickets||0); });
    return Object.keys(by).map(function(k){ var a=by[k]; a.cost=a.fuel+a.pay+a.toll+a.other; a.profit=a.rev-a.cost; return a; })
      .sort(function(a,b){ return a.plate.localeCompare(b.plate); });
  }

  /* ---------- hiển thị ---------- */
  function render(){ var agg=aggregate(), RD=reportDays();
    /* Tổng hợp, chi phí chung, ô chọn xe và chi tiết từng xe chỉ tính ngày đủ 4 báo cáo (trừ khi bấm Tất cả ngày) */
    var DD=S.allDays?S.data:RD.D, aggO=S.allDays?agg:aggregate(RD.D);
    renderChips(aggO); renderOvNote(RD); renderOverview(aggO, DD.revenue); renderOverhead(aggO, DD.overhead); renderDetail(aggO,RD,DD,agg); renderCoverage(); }
  function renderOvNote(RD){
    var box=$('#ovNote'); if(!box) return; box.innerHTML='';
    var seg=el('div',{class:'ovseg',role:'group','aria-label':'Ngày tính vào tổng hợp'},
      el('button',{type:'button',class:S.allDays?'btn-ghost':'btn-blue','aria-pressed':String(!S.allDays),onclick:function(){ S.allDays=false; render(); }},'Chỉ ngày đủ báo cáo'),
      el('button',{type:'button',class:S.allDays?'btn-blue':'btn-ghost','aria-pressed':String(!!S.allDays),onclick:function(){ S.allDays=true; render(); }},'Tất cả ngày'));
    var txt;
    if(S.allDays) txt=el('div',{class:'ovmsg warn'},'Đang xem tất cả ngày, gồm '+RD.nHide+' ngày chưa đủ báo cáo. Lãi lỗ có thể sai vì thiếu doanh thu hoặc chi phí. Ảnh gửi Zalo vẫn chỉ tính ngày đủ.');
    else if(!RD.nHide) txt=el('div',{class:'ovmsg'},'Đang tính '+RD.nFull+' ngày, tất cả đều đủ 4 báo cáo (chi phí, cầu đường, doanh thu, thu chi).');
    else txt=el('div',{class:'ovmsg warn'},'Đang tính '+RD.nFull+' ngày đủ 4 báo cáo. Không tính '+RD.nHide+' ngày chưa đủ: ',
      RD.hide.reduce(function(acc,h,i){ if(i) acc.push(' · '); acc.push(el('span',{class:'hd'},dmy(h.d).slice(0,5)+' (thiếu '+h.miss.join(', ').toLowerCase()+')')); return acc; },[]));
    box.append(seg,txt);
  }
  /* ---------- chi phí chung nhà xe: chi văn phòng (file thu chi) + chi công an (sổ quỹ) ---------- */
  var OFN={VPSG:'Văn phòng Sài Gòn',VPPT:'Văn phòng Phan Thiết',VPMN:'Văn phòng Mũi Né',VPNT:'Văn phòng Nha Trang'};
  var OFC={VPSG:'#164f86',VPPT:'#1d6db6',VPMN:'#5b9bd5',VPNT:'#13a89e'};
  function ohSummary(list){
    var vp={}, days={}, ca=0, nca=0, lg={}, lgN={};
    list.forEach(function(o){
      if(o.kind==='lg'){ if(!(o.date.slice(0,7)>=S.from.slice(0,7)&&o.date.slice(0,7)<=S.to.slice(0,7))) return; lg[o.office]=(lg[o.office]||0)+(o.amount||0); (lgN[o.office]=lgN[o.office]||[]).push(o.note); return; }
      if(o.date<S.from||o.date>S.to) return;
      if(o.kind==='ca'){ ca+=o.amount||0; nca++; } else { vp[o.office]=(vp[o.office]||0)+(o.amount||0); days[o.date]=1; } });
    var order=['VPSG','VPPT','VPMN','VPNT'].concat(Object.keys(vp).filter(function(k){ return !OFN[k]; }).sort());
    var rows=order.filter(function(k){ return k in vp; }).map(function(k){ return {name:OFN[k]||k, code:k, v:vp[k], color:OFC[k]||'#7b8496'}; });
    var vpT=rows.reduce(function(a,r){ return a+r.v; },0);
    rows.forEach(function(r){ r.sub=r.code+' · '+Object.keys(days).length+' ngày có file thu chi'; });
    var LC={VPSG:'#b30f60',VPPT:'#e4177e',VPMN:'#f06aa8',VPNT:'#c2185b'}, lgT=0;
    ['VPSG','VPPT','VPMN','VPNT'].concat(Object.keys(lg).filter(function(k){ return !OFN[k]; }).sort()).forEach(function(k){ if(!(k in lg)) return; lgT+=lg[k];
      rows.push({name:'Lương '+(OFN[k]?OFN[k].replace('Văn phòng','VP'):k), code:'LG', v:lg[k], color:LC[k]||'#e4177e', sub:lgN[k].join(' · ')}); });
    rows.push({name:'Chi công an', code:'CA', v:ca, color:'#7b5bd6', n:nca, sub:nca?nca+' lần chi, theo ngày chi trong sổ quỹ':'Chưa có trong sổ quỹ'});
    return {rows:rows, vp:vpT, ca:ca, lg:lgT, nca:nca, vpDays:Object.keys(days).length, total:vpT+ca+lgT};
  }
  function renderOverhead(agg,list){
    var box=$('#ohBox'); if(!box) return; box.innerHTML='';
    var O=ohSummary(list||S.data.overhead), carP=agg.reduce(function(a,x){ return a+x.profit; },0), net=carP-O.total;
    box.append(el('h3',{style:'margin-top:22px'},el('span',null,'Chi phí chung nhà xe'),el('span',{class:'tag'},vnd(O.total))));
    if(!O.vpDays&&!O.nca&&!O.lg){ box.append(el('div',{class:'empty'},'Chưa có chi văn phòng, lương hoặc chi công an trong khoảng ngày này. Tải file BÁO CÁO THU CHI hằng ngày, BẢNG LƯƠNG và SỔ QUỸ của tháng ở mục Tải file bên dưới.')); return; }
    box.append(el('div',{class:'tbl'},el('table',null,
      el('thead',null,el('tr',null,el('th',null,'Khoản'),el('th',null,'Ghi chú'),el('th',{class:'r'},'Số tiền'))),
      el('tbody',null,O.rows.map(function(r){ return el('tr',null,
        el('td',null,el('span',{style:'display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:8px;background:'+r.color}),r.name),
        el('td',{class:'wl',style:'color:var(--muted)'},r.sub||''),
        el('td',{class:'r'},money(r.v))); })),
      el('tfoot',null,
        el('tr',null,el('td',{colspan:'2'},'Lãi các xe'),el('td',{class:'r '+(carP>=0?'pos':'neg')},(carP>0?'+':'')+money(carP))),
        el('tr',null,el('td',{colspan:'2'},'Trừ chi phí chung'),el('td',{class:'r neg'},'−'+money(O.total))),
        el('tr',null,el('td',{colspan:'2'},'Lãi sau chi phí chung'),el('td',{class:'r '+(net>=0?'pos':'neg')},(net>0?'+':'')+money(net)))))));
  }
  function renderChips(agg){
    var box=$('#plateChips'); box.innerHTML='';
    agg.forEach(function(a){ box.append(el('button',{class:'chip',type:'button','aria-pressed':String(a.plate===S.sel),title:a.rev?(a.profit>=0?'Lãi ':'Lỗ ')+vnd(a.profit):'Chưa có doanh thu',onclick:function(){ select(a.plate); }},
      el('span',{class:'pl',style:'background:'+(a.rev?(a.profit>=0?'var(--gain)':'var(--loss)'):'#fff')}), fmtPlate(a.plate))); });
  }
  function renderOverview(agg,revList){
    var tb=$('#ovBody'), tf=$('#ovFoot'); tb.innerHTML=''; tf.innerHTML='';
    var T={trips:0,rev:0,fuel:0,pay:0,toll:0,other:0,cost:0,profit:0};
    agg.forEach(function(a){ Object.keys(T).forEach(function(k){ T[k]+=a[k]; });
      tb.append(el('tr',{class:'click',onclick:function(){ select(a.plate); window.scrollTo({top:0,behavior:'smooth'}); }},
        el('td',null,el('span',{class:'ptag'},fmtPlate(a.plate))), el('td',{class:'r'},a.trips), el('td',{class:'r'},a.rev?money(a.rev):'—'),
        el('td',{class:'r'},money(a.fuel)), el('td',{class:'r'},money(a.pay)), el('td',{class:'r'},money(a.toll)), el('td',{class:'r'},money(a.other)),
        el('td',{class:'r'},money(a.cost)), el('td',{class:'r '+(a.profit>=0?'pos':'neg')},(a.profit>0?'+':'')+money(a.profit)))); });
    if(agg.length) tf.append(el('tr',null, el('td',null,'Tổng '+agg.length+' xe'), el('td',{class:'r'},T.trips), el('td',{class:'r'},money(T.rev)), el('td',{class:'r'},money(T.fuel)), el('td',{class:'r'},money(T.pay)), el('td',{class:'r'},money(T.toll)), el('td',{class:'r'},money(T.other)), el('td',{class:'r'},money(T.cost)), el('td',{class:'r '+(T.profit>=0?'pos':'neg')},(T.profit>0?'+':'')+money(T.profit))));
    $('#ovEmpty').hidden=agg.length>0;
    $('#ovEmpty').textContent=S.allDays||!S.data.trips.length&&!S.data.revenue.length?'Chưa có dữ liệu trong khoảng ngày này. Tải file bảng kê ở mục bên dưới.':'Chưa có ngày nào đủ 4 báo cáo trong khoảng ngày này. Bấm Tất cả ngày để xem tạm, hoặc tải thêm file còn thiếu.';
    var ch=$('#ovCh'); ch.innerHTML=''; ch.append(renderChannels(revList||S.data.revenue,T.rev,'Doanh thu toàn bộ xe theo kênh bán'));
  }
  function select(p){ S.sel=p; $('#q').value=last5(p); render(); }
  $('#fSearch').addEventListener('submit',function(e){ e.preventDefault(); var q=$('#q').value.replace(/\D/g,''); if(!q){ return; }
    var agg=aggregate(); var m=agg.filter(function(a){ return last5(a.plate)===q; }); if(!m.length) m=agg.filter(function(a){ return a.plate.indexOf(q)>=0; });
    if(m.length===1){ select(m[0].plate); return; }
    S.sel=''; render();
    $('#detail').innerHTML=''; $('#detail').append(el('div',{class:'notice',style:'margin-top:14px'}, m.length? 'Có '+m.length+' xe khớp, chọn một xe ở hàng biển số phía trên.' : 'Không có xe nào đuôi '+q+' trong khoảng '+dmy(S.from)+' – '+dmy(S.to)+'. Thử chọn khoảng ngày khác hoặc tải file của ngày đó.'));
  });
  $('#q').addEventListener('input',function(e){ var v=e.target.value.replace(/\D/g,'').slice(0,5); e.target.value=v; if(v.length===5) $('#fSearch').requestSubmit(); });

  function renderDetail(agg,RD,DD,aggAll){ DD=DD||S.data;
    var box=$('#detail'); if(!S.sel){ if(!box.querySelector('.notice')) box.innerHTML=''; return; }
    box.innerHTML='';
    var a=agg.filter(function(x){ return x.plate===S.sel; })[0];
    var hd={}; if(RD&&!S.allDays) ['trips','tolls','extras','revenue'].forEach(function(k){ S.data[k].forEach(function(t){ if(t.plate===S.sel&&t.date>=S.from&&t.date<=S.to&&!RD.full[t.date]) hd[t.date]=1; }); });
    var hds=Object.keys(hd).sort(), hdTxt=hds.map(function(d){ return dmy(d).slice(0,5); }).join(', ');
    if(!a){ box.append(el('div',{class:'notice',style:'margin-top:14px'}, hds.length?'Xe '+fmtPlate(S.sel)+' chỉ có dữ liệu ở '+hds.length+' ngày chưa đủ báo cáo ('+hdTxt+'). Bấm Tất cả ngày ở mục Tổng hợp để xem tạm.':'Xe '+fmtPlate(S.sel)+' không có dữ liệu trong khoảng ngày này.')); return; }
    if(hds.length) box.append(el('div',{class:'notice',style:'margin-top:14px'},'Không tính '+hds.length+' ngày chưa đủ báo cáo của xe này ('+hdTxt+'). Bấm Tất cả ngày ở mục Tổng hợp để xem cả những ngày đó.'));
    var trips=DD.trips.filter(function(t){ return t.plate===a.plate; }).sort(function(x,y){ return (x.date+x.time).localeCompare(y.date+y.time); });
    var tolls=DD.tolls.filter(function(t){ return t.plate===a.plate; }).sort(function(x,y){ return (x.date+x.time).localeCompare(y.date+y.time); });
    var extras=DD.extras.filter(function(t){ return t.plate===a.plate; });
    var revs=DD.revenue.filter(function(t){ return t.plate===a.plate; }).sort(function(x,y){ return (x.date+(x.time||'')).localeCompare(y.date+(y.time||'')); });
    var routesSet={}; trips.forEach(function(t){ if(t.route) routesSet[t.route]=1; });
    var days={}; trips.forEach(function(t){ days[t.date]=1; });
    box.append(el('div',{style:'margin-top:18px'},
      el('div',{class:'vhead'}, el('span',{class:'plate'},fmtPlate(a.plate)),
        el('div',{class:'sub'}, el('div',null,'Tài xế: ',el('b',null,Object.keys(a.drivers).join(', ')||'—')), el('div',null,'Lịch trình: '+(Object.keys(routesSet).join(' · ')||'—'))))));
    var pct=a.rev?Math.round(a.profit/a.rev*100):null;
    box.append(el('div',{class:'kpis'},
      el('div',{class:'kpi'},el('div',{class:'l'},'Doanh thu'),el('div',{class:'v'},a.rev?vnd(a.rev):'Chưa có'),el('div',{class:'s'},a.rev?(a.tickets?a.tickets+' khách':revs.length+' khoản'):'Tải báo cáo doanh thu'),
        a.rev?el('div',{class:'kq'},guestLine(revs)):null),
      el('div',{class:'kpi'},el('div',{class:'l'},'Tổng chi phí'),el('div',{class:'v'},vnd(a.cost)),el('div',{class:'s'},a.trips+' chuyến · '+Object.keys(days).length+' ngày')),
      el('div',{class:'kpi pl'+(a.profit<0?' neg':'')},el('div',{class:'l'},a.profit<0?'Lỗ':'Lãi'),el('div',{class:'v'},(a.profit>0?'+':'')+vnd(a.profit)),el('div',{class:'s'},pct==null?'Chưa nhập doanh thu':'Biên lãi '+pct+'%')),
      el('div',{class:'kpi'},el('div',{class:'l'},'Dầu đã đổ'),el('div',{class:'v'},money(a.liters)+' lít'),el('div',{class:'s'},a.trips?'TB '+money(a.liters/a.trips)+' lít/chuyến':''))));
    var parts=[['Dầu',a.fuel,'var(--c-fuel)'],['Tiền tài',a.pay,'var(--c-pay)'],['Cầu đường',a.toll,'var(--c-toll)'],['Trung chuyển / khác',a.other,'var(--c-other)']];
    var bar=el('div',{class:'bar',role:'img','aria-label':'Cơ cấu chi phí'}); var lg=el('div',{class:'legend'});
    parts.forEach(function(p){ if(!p[1]) return; bar.append(el('span',{style:'width:'+(p[1]/a.cost*100)+'%;background:'+p[2],title:p[0]+': '+vnd(p[1])})); lg.append(el('span',null,el('i',{style:'background:'+p[2]}),p[0]+' ',el('b',null,vnd(p[1])),' ('+Math.round(p[1]/a.cost*100)+'%)')); });
    if(a.cost) box.append(bar,lg);
    box.append(renderChannels(revs,a.rev));
    // Doanh thu
    var rf=el('form',{class:'revform',novalidate:''},
      el('label',{for:'rvDate'},'Ngày',el('input',{type:'date',id:'rvDate',value:trips.length?trips[trips.length-1].date:(S.to<=iso(new Date())?S.to:iso(new Date()))})),
      el('label',{for:'rvAmt'},'Doanh thu (đồng)',el('input',{id:'rvAmt',inputmode:'numeric',placeholder:'VD: 4500000'})),
      el('label',{for:'rvNote'},'Ghi chú',el('input',{id:'rvNote',class:'wide',placeholder:'VD: 18 khách chuyến 8h'})),
      el('button',{class:'btn-pink',type:'submit'},'Thêm doanh thu'));
    rf.addEventListener('submit',function(e){ e.preventDefault(); var amt=num($('#rvAmt').value), d=$('#rvDate').value; if(!amt||!d){ status('Nhập ngày và số tiền doanh thu.','err'); return; }
      var bt=rf.querySelector('button'); bt.disabled=true;
      call('addRevenue',S.pin,{date:d, plate:a.plate, amount:amt, note:$('#rvNote').value.trim().slice(0,120)})
        .then(function(){ status('Đã thêm doanh thu '+vnd(amt)+' cho xe '+fmtPlate(a.plate)+'.','ok'); setTimeout(function(){ status(''); },3000); return load(); })
        .catch(function(e){ bt.disabled=false; fail(e); }); });
    box.append(fold('rev','Doanh thu · '+revs.length+' khoản'+(a.tickets?' · '+a.tickets+' khách':''),'tag p',vnd(a.rev),
      revs.length?el('div',{class:'tbl'},el('table',null,el('thead',null,el('tr',null,el('th',null,'Ngày'),el('th',null,'Giờ'),el('th',null,'Tuyến'),el('th',{class:'r'},'Vé'),el('th',{class:'r'},'Doanh thu'),el('th',null,'Theo kênh / ghi chú'),el('th'))),
      el('tbody',null,revs.map(function(r){ return el('tr',null,el('td',null,dmy(r.date)),el('td',null,r.time||''),el('td',null,r.route||(r.src==='tay'?'Nhập tay':'')),el('td',{class:'r'},r.tickets||''),el('td',{class:'r'},money(r.amount)),el('td',{class:'wl'},r.note||''),
        el('td',{class:'r'},el('button',{class:'btn-del',type:'button',onclick:function(e){ arm(e.currentTarget,function(){ return call('deleteRevenue',S.pin,r.id).then(load); }); }},'Xoá'))); }))))
      :el('div',{class:'empty'},'Chưa có doanh thu cho xe này trong khoảng ngày đã chọn. Nhập ở ô dưới, hoặc tải file doanh thu (cột Ngày · Số xe · Doanh thu).'),
      rf));
    // Chuyến · cầu đường · khác: thu gọn được, nhớ trạng thái trên máy này
    box.append(fold('trips','Các chuyến · dầu và tiền tài · '+trips.length+' chuyến','tag',vnd(a.fuel+a.pay),
      el('div',{class:'tbl'},el('table',null,el('thead',null,el('tr',null,['Ngày','Giờ','Tài xế','Lịch trình'].map(function(h){ return el('th',null,h); }),['Lít','Giá dầu','Tiền dầu','Tiền tài'].map(function(h){ return el('th',{class:'r'},h); }))),
      el('tbody',null,trips.map(function(t){ return el('tr',null,el('td',null,dmy(t.date)),el('td',null,t.time||''),el('td',null,t.driver||''),el('td',null,t.route||''),el('td',{class:'r'},t.liters||''),el('td',{class:'r'},t.price?money(t.price):''),el('td',{class:'r'},money(t.fuel)),el('td',{class:'r'},money(t.pay))); })),
      el('tfoot',null,el('tr',null,el('td',{colspan:'4'},trips.length+' chuyến'),el('td',{class:'r'},money(a.liters)),el('td'),el('td',{class:'r'},money(a.fuel)),el('td',{class:'r'},money(a.pay))))))));
    box.append(fold('tolls','Phí cầu đường · '+tolls.length+' lượt','tag',vnd(a.toll),
      tolls.length?el('div',{class:'tbl'},el('table',null,el('thead',null,el('tr',null,el('th',null,'Ngày'),el('th',null,'Giờ'),el('th',null,'Đoạn đường'),el('th',{class:'r'},'Số tiền'))),
      el('tbody',null,tolls.map(function(t){ return el('tr',null,el('td',null,dmy(t.date)),el('td',null,t.time||''),el('td',{class:'wl'},t.station),el('td',{class:'r'},money(t.amount))); }))))
      :el('div',{class:'empty'},'Không có lượt cầu đường.')));
    if(extras.length) box.append(fold('extras','Trung chuyển / chi phí khác · '+extras.length+' khoản','tag',vnd(a.other),
      el('div',{class:'tbl'},el('table',null,el('thead',null,el('tr',null,el('th',null,'Ngày'),el('th',null,'Loại'),el('th',null,'Ghi chú'),el('th',{class:'r'},'Số tiền'))),
        el('tbody',null,extras.map(function(t){ return el('tr',null,el('td',null,dmy(t.date)),el('td',null,t.kind),el('td',{class:'wl'},t.note||''),el('td',{class:'r'},money(t.amount))); }))))));
  }
  /* khung thu gọn: mặc định đóng, nhớ mở/đóng theo từng phần trên máy này */
  function foldOpen(k){ try{ return localStorage.getItem('ll_fold_'+k)==='1'; }catch(e){ return false; } }
  function fold(k,title,tagCls,tagText,body){
    var d=el('details',{class:'fold',open:foldOpen(k)?'':null,ontoggle:function(){ try{ localStorage.setItem('ll_fold_'+k,d.open?'1':'0'); }catch(e){} }},
      el('summary',null,el('h3',null,el('span',null,el('span',{class:'car','aria-hidden':'true'},'▸'),title),el('span',{class:tagCls},tagText))),
      el('div',{class:'fold-b'},[].slice.call(arguments,4)));
    return d;
  }
  /* ---------- ẢNH BÁO CÁO TỔNG (gửi Zalo) ---------- */
  function rpChannels(revs,total){
    var c=channelSplit(revs), known=0;
    var items=CHN.map(function(x){ var v=c.s[x[0]]||0; known+=v; return {name:x[1], v:v, k:c.q[x[0]]||0, color:x[2]}; }).filter(function(it){ return it.v>0; });
    if(c.tay){ items.push({name:'Nhập tay',v:c.tay,k:0,color:'#5f6678'}); known+=c.tay; }
    var rest=total-known; if(rest>1000) items.push({name:'Chưa rõ kênh',v:rest,k:0,color:'#b9bfcc'});
    items.sort(function(a,b){ return b.v-a.v; });
    return {items:items, base:Math.max(total,known), hasQ:c.hasQ};
  }
  function rpRR(x,ctx,l,t,w,h,r){ ctx.beginPath(); ctx.moveTo(l+r,t); ctx.arcTo(l+w,t,l+w,t+h,r); ctx.arcTo(l+w,t+h,l,t+h,r); ctx.arcTo(l,t+h,l,t,r); ctx.arcTo(l,t,l+w,t,r); ctx.closePath(); }
  function rpSigned(n){ return (n>0?'+':'')+money(n)+'đ'; }
  /* ngày đủ báo cáo = có đủ 4 loại file: chi phí (dầu+tài), cầu đường, doanh thu, thu chi văn phòng */
  function reportDays(){
    var cov={};
    function add(d,k,id){ if(!d||!id||d<S.from||d>S.to) return; var c=cov[d]||(cov[d]={cost:{},toll:{},rev:{},vp:{}}); c[k][id]=1; }
    S.data.trips.forEach(function(t){ add(t.date,'cost',t.imp); });
    S.data.extras.forEach(function(t){ add(t.date,'cost',t.imp); });
    S.data.tolls.forEach(function(t){ add(t.date,'toll',t.imp); });
    S.data.revenue.forEach(function(t){ if(t.src!=='tay') add(t.date,'rev',t.imp); });
    S.data.overhead.forEach(function(t){ if(t.kind==='vp') add(t.date,'vp',t.imp); });
    S.imports.forEach(function(im){ kindsOf(im).forEach(function(k){ add(im.date,k,im.id); }); });
    var full={}, nFull=0, nHide=0, hide=[];
    Object.keys(cov).forEach(function(d){ var c=cov[d], miss=KIND.filter(function(k){ return !Object.keys(c[k[0]]).length; }).map(function(k){ return k[1]; });
      if(!miss.length){ full[d]=1; nFull++; } else { nHide++; hide.push({d:d, miss:miss}); } });
    COLS.forEach(function(k){ S.data[k].forEach(function(t){ if(t.kind==='ca'||t.kind==='lg') return; if(t.date>=S.from&&t.date<=S.to&&!cov[t.date]&&!full[t.date]){ cov[t.date]={cost:{},toll:{},rev:{},vp:{}}; nHide++; hide.push({d:t.date, miss:KIND.map(function(k){ return k[1]; })}); } }); });
    hide.sort(function(a,b){ return a.d.localeCompare(b.d); });
    /* chi công an lấy hết trong khoảng ngày chọn; lương lấy trọn tháng chạm khoảng ngày; các khoản khác chỉ lấy ngày đủ */
    var D={}; COLS.forEach(function(k){ D[k]=S.data[k].filter(function(t){ return t.kind==='lg' ? (t.date.slice(0,7)>=S.from.slice(0,7)&&t.date.slice(0,7)<=S.to.slice(0,7)) : t.kind==='ca' ? (t.date>=S.from&&t.date<=S.to) : full[t.date]; }); });
    return {D:D, nFull:nFull, nHide:nHide, hide:hide, full:full};
  }
  function buildReport(RD){
    var agg=aggregate(RD.D), T={trips:0,rev:0,fuel:0,pay:0,toll:0,other:0,cost:0,profit:0,tickets:0};
    agg.forEach(function(a){ Object.keys(T).forEach(function(k){ T[k]+=a[k]||0; }); });
    var run=agg.filter(function(a){ return a.trips>0; }), idle=agg.filter(function(a){ return !a.trips; });   /* xe 0 chuyến không đưa vào bảng */
    var ch=rpChannels(RD.D.revenue,T.rev);
    var OH=ohSummary(RD.D.overhead), NET=T.profit-OH.total;

    var W=1100, SC=2, P=40, cv=document.createElement('canvas'); cv.width=W*SC; cv.height=4200*SC;
    var x=cv.getContext('2d'); x.scale(SC,SC);
    var C={ink:'#172033',mut:'#5f6678',line:'#e5e1ea',soft:'#f5f4f8',blue:'#1d6db6',blueD:'#164f86',pink:'#e4177e',gain:'#16834a',gainS:'#e2f4ea',loss:'#c8283a',lossS:'#fde9ec',plate:'#ffd21f'};
    var FD='"Lexend","Be Vietnam Pro",sans-serif', FB='"Be Vietnam Pro",sans-serif';
    function f(w,s,fam){ x.font=w+' '+s+'px '+(fam||FB); }
    function tx(t,l,y,col,al){ x.fillStyle=col||C.ink; x.textAlign=al||'left'; x.fillText(t,l,y); }
    function plate(p,l,y,sz){ sz=sz||20; var t=fmtPlate(p); f(700,sz); var w=x.measureText(t).width+sz*1.1;
      rpRR(0,x,l,y-sz*1.2,w,sz*1.7,6); x.fillStyle=C.plate; x.fill(); x.lineWidth=2; x.strokeStyle=C.ink; x.stroke(); tx(t,l+sz*.55,y,C.ink); return w; }
    function head(t,y){ f(700,15); x.save(); x.fillStyle=C.mut; x.letterSpacing='1.5px'; tx(t.toUpperCase(),P,y,C.mut); x.restore(); return y+18; }

    x.fillStyle='#fff'; x.fillRect(0,0,W,4200);
    var g=x.createLinearGradient(0,0,W,0); g.addColorStop(0,C.blue); g.addColorStop(1,C.pink); x.fillStyle=g; x.fillRect(0,0,W,8);
    var y=36, logo=$('header .logo');
    if(logo&&logo.complete&&logo.naturalWidth){ var lh=70, lw=logo.naturalWidth/logo.naturalHeight*lh; x.drawImage(logo,P,y,lw,lh); }
    f(600,13); x.save(); x.letterSpacing='2px'; tx('BÁO CÁO LÃI LỖ TOÀN BỘ XE',W-P,y+22,C.mut,'right'); x.restore();
    f(700,26,FD); tx(S.from===S.to?dmy(S.from):dmy(S.from)+' – '+dmy(S.to),W-P,y+56,C.blueD,'right');
    f(500,14); tx('Gồm '+RD.nFull+' ngày đủ 4 báo cáo (chi phí, cầu đường, doanh thu, thu chi)'+(RD.nHide?' · ẩn '+RD.nHide+' ngày chưa đủ':''),W-P,y+84,RD.nHide?'#94650b':C.mut,'right');
    y+=104; x.fillStyle=C.line; x.fillRect(P,y,W-2*P,1); y+=26;

    /* khối lãi lỗ */
    var pos=NET>=0, bh=150; rpRR(0,x,P,y,W-2*P,bh,18); x.fillStyle=pos?C.gainS:C.lossS; x.fill();
    f(600,15); tx(pos?'LÃI SAU CHI PHÍ CHUNG':'LỖ SAU CHI PHÍ CHUNG',P+28,y+38,pos?C.gain:C.loss);
    f(700,52,FD); tx(rpSigned(NET),P+28,y+100,pos?C.gain:C.loss);
    f(500,16); tx('Lãi các xe '+rpSigned(T.profit)+'  −  chi phí chung '+vnd(OH.total)+(T.rev?'  ·  tỷ suất '+(NET/T.rev*100).toFixed(1).replace('.',',')+'% doanh thu':''),P+28,y+130,C.mut);
    y+=bh+20;

    /* 4 ô số */
    var kp=[['Doanh thu',vnd(T.rev),C.pink],['Chi phí xe',vnd(T.cost),C.blueD],['Chi phí chung',vnd(OH.total),'#7b5bd6'],['Số chuyến'+(T.tickets?' · khách':''),T.trips+(T.tickets?' · '+T.tickets.toLocaleString('vi-VN'):''),C.ink]];
    var kw=(W-2*P-48)/4, kh=86;
    kp.forEach(function(k,i){ var l=P+i*(kw+16), t=y;
      rpRR(0,x,l,t,kw,kh,14); x.fillStyle=C.soft; x.fill(); f(500,15); tx(k[0],l+20,t+30,C.mut); f(700,26,FD); tx(k[1],l+20,t+66,k[2]); });
    y+=kh+34;

    /* chi phí */
    y=head('Chi phí xe · '+vnd(T.cost),y)+10;
    [['Dầu',T.fuel,'#1d6db6'],['Tiền tài',T.pay,'#e4177e'],['Cầu đường',T.toll,'#f0a020'],['Trung chuyển / khác',T.other,'#7b8496']].forEach(function(r){
      var pc=T.cost?r[1]/T.cost:0; f(500,17); tx(r[0],P,y+18,C.ink); f(700,17); tx(vnd(r[1]),W-P,y+18,C.ink,'right');
      f(500,15); tx(Math.round(pc*100)+'%',W-P-190,y+18,C.mut,'right');
      rpRR(0,x,P,y+28,W-2*P,8,4); x.fillStyle=C.soft; x.fill(); if(pc>0){ rpRR(0,x,P,y+28,Math.max(8,(W-2*P)*pc),8,4); x.fillStyle=r[2]; x.fill(); }
      y+=54; });
    y+=20;

    /* chi phí chung nhà xe */
    y=head('Chi phí chung nhà xe · '+vnd(OH.total),y)+10;
    OH.rows.forEach(function(r){
      var pc=OH.total?r.v/OH.total:0; f(500,17); tx(r.name,P,y+18,C.ink);
      if(r.code==='CA'||r.code==='LG'){ var nw=x.measureText(r.name).width; f(500,14); tx('  '+(r.code==='CA'?(r.n?r.n+' lần chi, theo ngày chi':'chưa có trong sổ quỹ'):r.sub+', trọn tháng'),P+nw+4,y+18,C.mut); }
      f(700,17); tx(vnd(r.v),W-P,y+18,C.ink,'right');
      f(500,15); tx(Math.round(pc*100)+'%',W-P-190,y+18,C.mut,'right');
      rpRR(0,x,P,y+28,W-2*P,8,4); x.fillStyle=C.soft; x.fill(); if(pc>0){ rpRR(0,x,P,y+28,Math.max(8,(W-2*P)*pc),8,4); x.fillStyle=r.color; x.fill(); }
      y+=54; });
    y+=20;

    /* kênh bán */
    if(T.rev&&ch.items.length){
      y=head('Doanh thu theo kênh bán',y)+10;
      var bx=P, bw=W-2*P; x.save(); rpRR(0,x,P,y,bw,16,8); x.clip();
      ch.items.forEach(function(it){ var w=bw*it.v/ch.base; x.fillStyle=it.color; x.fillRect(bx,y,w,16); bx+=w; }); x.restore();
      y+=48;
      ch.items.forEach(function(it){ var pc=it.v/T.rev*100;
        x.fillStyle=it.color; rpRR(0,x,P,y-13,14,14,4); x.fill();
        f(600,17); tx(it.name,P+24,y,C.ink);
        f(500,15); tx(ch.hasQ&&it.k?it.k.toLocaleString('vi-VN')+' khách':'',W-P-300,y,C.mut,'right');
        f(500,15); tx((pc>0&&pc<1?pc.toFixed(1).replace('.',','):Math.round(pc))+'%',W-P-200,y,C.mut,'right');
        f(700,17); tx(vnd(it.v),W-P,y,C.ink,'right');
        y+=36; });
      y+=14;
    }

    /* bảng các xe */
    y=head('Chi tiết từng xe · '+run.length+' xe',y)+12;
    var cols=[['Biển số',140,'l'],['Chuyến',65,'r'],['Doanh thu',130,'r'],['Dầu',125,'r'],['Tiền tài',110,'r'],['Cầu đường',110,'r'],['Khác',80,'r'],['Tổng chi',125,'r'],['Lãi / lỗ',135,'r']];
    var tw=W-2*P, sum=cols.reduce(function(a,c){ return a+c[1]; },0); cols.forEach(function(c){ c[1]=c[1]*tw/sum; });
    function row(vals,t,h,bold,colors){ var l=P; vals.forEach(function(v,j){ var c=cols[j];
      if(j===0&&v&&v.plate){ plate(v.plate,l+10,t+h/2+6,15); }
      else { f(bold||j===8?700:500,16); tx(String(v),c[2]==='r'?l+c[1]-12:l+12,t+h/2+6,(colors&&colors[j])||C.ink,c[2]==='r'?'right':'left'); }
      l+=c[1]; }); }
    var th=40, rh=46, top=y;
    rpRR(0,x,P,y,tw,th,10); x.fillStyle=C.soft; x.fill();
    f(700,12); x.save(); x.letterSpacing='1px'; var lx=P; cols.forEach(function(c){ tx(c[0].toUpperCase(),c[2]==='r'?lx+c[1]-12:lx+12,y+25,C.mut,c[2]==='r'?'right':'left'); lx+=c[1]; }); x.restore();
    y+=th;
    var R={trips:0,rev:0,fuel:0,pay:0,toll:0,other:0,cost:0,profit:0};
    run.forEach(function(a,i){ Object.keys(R).forEach(function(k){ R[k]+=a[k]||0; });
      if(i%2){ x.fillStyle='#faf9fc'; x.fillRect(P,y,tw,rh); }
      x.fillStyle=C.line; x.fillRect(P,y,tw,1);
      row([{plate:a.plate},a.trips,a.rev?money(a.rev):'—',money(a.fuel),money(a.pay),money(a.toll),money(a.other),money(a.cost),(a.profit>0?'+':'')+money(a.profit)],y,rh,false,{8:a.profit>=0?C.gain:C.loss});
      y+=rh; });
    if(!run.length){ f(500,16); tx('Chưa có xe chạy trong khoảng ngày này.',P+12,y+30,C.mut); y+=rh; }
    else { x.fillStyle=C.ink; x.fillRect(P,y,tw,1.5);
      row(['Tổng',R.trips,money(R.rev),money(R.fuel),money(R.pay),money(R.toll),money(R.other),money(R.cost),(R.profit>0?'+':'')+money(R.profit)],y,rh+4,true,{8:R.profit>=0?C.gain:C.loss}); y+=rh+4; }
    x.strokeStyle=C.line; x.lineWidth=1; rpRR(0,x,P+.5,top+.5,tw-1,y-top-1,10); x.stroke();
    y+=22;
    if(idle.length){ var it=idle.reduce(function(a,b){ return a+b.cost; },0);
      f(500,14); tx('Không ghi '+idle.length+' xe không chạy chuyến ('+idle.map(function(a){ return fmtPlate(a.plate); }).join(', ')+'), chỉ có chi phí '+vnd(it)+', đã tính vào Tổng chi ở trên.',P,y,C.mut); y+=26; }
    y+=12;

    /* bảng chi phí chung nhà xe (giống trên web) và lãi sau chi phí chung */
    y=head('Bảng chi phí chung nhà xe',y)+12;
    var oc=[['Khoản',300,'l'],['Ghi chú',500,'l'],['Số tiền',220,'r']], otw=W-2*P, osum=oc.reduce(function(a,c){ return a+c[1]; },0);
    oc.forEach(function(c){ c[1]=c[1]*otw/osum; });
    function ocell(vals,t,h,o){ o=o||{}; var l=P; vals.forEach(function(v,j){ var c=oc[j]; if(v==null||v===''){ l+=c[1]; return; }
      var tx0=l+12;
      if(j===0&&o.dot){ x.fillStyle=o.dot; rpRR(0,x,l+12,t+h/2-6,12,12,3); x.fill(); tx0=l+32; }
      f(o.bold?700:(j===1?500:500),j===1?14:16); tx(String(v),c[2]==='r'?l+c[1]-12:tx0,t+h/2+6,j===1?C.mut:(j===2&&o.col)||C.ink,c[2]==='r'?'right':'left');
      l+=c[1]; }); }
    var ot=y, orh=44;
    rpRR(0,x,P,y,otw,40,10); x.fillStyle=C.soft; x.fill();
    f(700,12); x.save(); x.letterSpacing='1px'; var olx=P; oc.forEach(function(c){ tx(c[0].toUpperCase(),c[2]==='r'?olx+c[1]-12:olx+12,y+25,C.mut,c[2]==='r'?'right':'left'); olx+=c[1]; }); x.restore();
    y+=40;
    OH.rows.forEach(function(r,i){ if(i%2){ x.fillStyle='#faf9fc'; x.fillRect(P,y,otw,orh); } x.fillStyle=C.line; x.fillRect(P,y,otw,1);
      var sub=r.sub||''; f(500,14); while(sub&&x.measureText(sub).width>oc[1][1]-24) sub=sub.slice(0,-2);
      if(sub!==(r.sub||'')) sub=sub.replace(/\s*\S?$/,'')+'…';
      ocell([r.name,sub,money(r.v)],y,orh,{dot:r.color}); y+=orh; });
    x.fillStyle=C.ink; x.fillRect(P,y,otw,1.5);
    ocell(['Tổng chi phí chung','',money(OH.total)],y,orh,{bold:true}); y+=orh;
    x.fillStyle=C.line; x.fillRect(P,y,otw,1);
    ocell(['Lãi các xe','',(T.profit>0?'+':'')+money(T.profit)],y,orh,{col:T.profit>=0?C.gain:C.loss}); y+=orh;
    ocell(['Trừ chi phí chung','','−'+money(OH.total)],y,orh,{col:C.loss}); y+=orh;
    x.fillStyle=NET>=0?C.gainS:C.lossS; x.fillRect(P+1,y,otw-2,orh+6);
    ocell(['Lãi sau chi phí chung','',(NET>0?'+':'')+money(NET)],y,orh+6,{bold:true,col:NET>=0?C.gain:C.loss}); y+=orh+6;
    x.strokeStyle=C.line; x.lineWidth=1; rpRR(0,x,P+.5,ot+.5,otw-1,y-ot-1,10); x.stroke();
    y+=34;

    /* chân */
    x.fillStyle=C.line; x.fillRect(P,y,W-2*P,1); y+=30;
    var now=new Date(); f(500,13); tx('Nam Hải Travel · Lãi lỗ từng xe',P,y,C.mut);
    tx('Xuất lúc '+pad(now.getHours())+':'+pad(now.getMinutes())+' '+dmy(iso(now)),W-P,y,C.mut,'right');
    y+=28;

    var out=document.createElement('canvas'); out.width=W*SC; out.height=Math.ceil(y*SC);
    out.getContext('2d').drawImage(cv,0,0); return out;
  }
  /* khoá cuộn trang phía sau khi đang xem ảnh; trả về hàm mở khoá và đưa trang về đúng chỗ cũ */
  function lockPage(){
    var y=window.pageYOffset||document.documentElement.scrollTop||0, h=document.documentElement, b=document.body;
    var old=[h.style.overflow,b.style.overflow,b.style.position,b.style.top,b.style.width];
    h.style.overflow='hidden'; b.style.overflow='hidden'; b.style.position='fixed'; b.style.top=(-y)+'px'; b.style.width='100%';
    return function(){ h.style.overflow=old[0]; b.style.overflow=old[1]; b.style.position=old[2]; b.style.top=old[3]; b.style.width=old[4]; window.scrollTo(0,y); };
  }
  /* khung xem ảnh tự phóng to: chụm 2 ngón, kéo, chạm 2 lần, lăn chuột; không để trình duyệt phóng cả trang */
  function zoomView(stage,img,nw,nh,onScale){
    var s=1, tx=0, ty=0, bw=1, bh=1, MAX=5, pts={}, st=null, lastTap=0, lastX=0, lastY=0, moved=false;
    function size(){ return {w:stage.clientWidth, h:stage.clientHeight}; }
    function clamp(){ var z=size(), w=bw*s, h=bh*s;
      tx= w<=z.w ? (z.w-w)/2 : Math.min(0,Math.max(z.w-w,tx));
      ty= h<=z.h ? (z.h-h)/2 : Math.min(0,Math.max(z.h-h,ty)); }
    function apply(){ clamp(); img.style.transform='translate('+tx+'px,'+ty+'px) scale('+s+')'; onScale(s); }
    function zoomAt(px,py,ns){ ns=Math.max(1,Math.min(MAX,ns)); tx=px-(px-tx)*ns/s; ty=py-(py-ty)*ns/s; s=ns; apply(); }
    function local(e){ var r=stage.getBoundingClientRect(); return {x:e.clientX-r.left, y:e.clientY-r.top}; }
    function begin(){ var k=Object.keys(pts);
      if(k.length>=2){ var a=pts[k[0]], b=pts[k[1]]; st={two:true, d:Math.hypot(a.x-b.x,a.y-b.y)||1, mx:(a.x+b.x)/2, my:(a.y+b.y)/2, s:s, tx:tx, ty:ty}; }
      else if(k.length===1){ var p=pts[k[0]]; st={two:false, x:p.x, y:p.y, tx:tx, ty:ty}; }
      else st=null; }
    stage.addEventListener('pointerdown',function(e){ stage.setPointerCapture&&stage.setPointerCapture(e.pointerId); pts[e.pointerId]=local(e); moved=false; begin(); e.preventDefault(); });
    stage.addEventListener('pointermove',function(e){ if(!pts[e.pointerId]||!st) return; pts[e.pointerId]=local(e); var k=Object.keys(pts);
      if(st.two&&k.length>=2){ var a=pts[k[0]], b=pts[k[1]], d=Math.hypot(a.x-b.x,a.y-b.y), mx=(a.x+b.x)/2, my=(a.y+b.y)/2;
        var ns=Math.max(1,Math.min(MAX,st.s*d/st.d)); s=ns; tx=mx-(st.mx-st.tx)*ns/st.s; ty=my-(st.my-st.ty)*ns/st.s; moved=true; apply(); }
      else if(!st.two){ var p=pts[e.pointerId]; if(Math.abs(p.x-st.x)+Math.abs(p.y-st.y)>6) moved=true; tx=st.tx+p.x-st.x; ty=st.ty+p.y-st.y; apply(); }
      e.preventDefault(); });
    function up(e){ if(!pts[e.pointerId]) return; var p=pts[e.pointerId]; delete pts[e.pointerId];
      if(!Object.keys(pts).length&&!moved&&e.type==='pointerup'){ var now=Date.now();
        if(now-lastTap<320&&Math.abs(p.x-lastX)<30&&Math.abs(p.y-lastY)<30){ if(s>1.05){ s=1; apply(); } else zoomAt(p.x,p.y,2.5); lastTap=0; }
        else { lastTap=now; lastX=p.x; lastY=p.y; } }
      begin(); }
    stage.addEventListener('pointerup',up); stage.addEventListener('pointercancel',up);
    stage.addEventListener('wheel',function(e){ e.preventDefault(); var p=local(e);
      if(e.ctrlKey||e.metaKey){ zoomAt(p.x,p.y,s*Math.exp(-e.deltaY*0.01)); }
      else { tx-=e.deltaX; ty-=e.deltaY; apply(); } },{passive:false});
    /* iPhone: chặn cử chỉ phóng cả trang */
    ['gesturestart','gesturechange','gestureend'].forEach(function(n){ stage.addEventListener(n,function(e){ e.preventDefault(); }); });
    stage.addEventListener('touchmove',function(e){ e.preventDefault(); },{passive:false});
    return {
      fit:function(){ var z=size(); bw=z.w; bh=bw*nh/nw; img.style.width=bw+'px'; img.style.height=bh+'px'; s=1; tx=0; ty=0; apply(); },
      step:function(f){ var z=size(); zoomAt(z.w/2,z.h/2,s*f); }
    };
  }
  function showReport(){
    var btn=$('#btnReport'); btn.disabled=true;
    var fonts=['700 20px Lexend','500 15px "Be Vietnam Pro"','600 15px "Be Vietnam Pro"','700 15px "Be Vietnam Pro"'];
    Promise.all(fonts.map(function(s){ return document.fonts?document.fonts.load(s,'Lãi lỗ Đ'):null; })).catch(function(){}).then(function(){
      var RD=reportDays();
      if(!RD.nFull){ status('Chưa có ngày nào đủ cả 3 báo cáo (chi phí, cầu đường, doanh thu) trong khoảng ngày này, nên chưa tạo được ảnh.','err'); return; }
      var cv=buildReport(RD), url=cv.toDataURL('image/png');
      var name='Lai-lo-'+(S.from===S.to?S.from:S.from+'_'+S.to)+'.png', msg=el('div',{class:'rp-msg'});
      var lock=lockPage();
      var close=function(){ ov.remove(); document.removeEventListener('keydown',esc); window.removeEventListener('resize',zv.fit); lock(); };
      var esc=function(e){ if(e.key==='Escape') close(); };
      var acts=el('div',{class:'rp-acts'},
        el('button',{class:'btn-pink',type:'button',onclick:function(){ var a=el('a',{href:url,download:name}); document.body.append(a); a.click(); a.remove(); msg.textContent='Đã tải ảnh. Mở Zalo và gửi ảnh vừa tải.'; }},'Tải ảnh'),
        el('button',{class:'btn-blue',type:'button',onclick:function(){
          cv.toBlob(function(b){
            var f=new File([b],name,{type:'image/png'});
            if(navigator.canShare&&navigator.canShare({files:[f]})){ navigator.share({files:[f],title:'Báo cáo lãi lỗ'}).catch(function(){}); return; }
            if(navigator.clipboard&&window.ClipboardItem){ navigator.clipboard.write([new ClipboardItem({'image/png':b})]).then(function(){ msg.textContent='Đã sao chép ảnh. Mở Zalo, bấm vào ô chat rồi nhấn Ctrl+V.'; },function(){ msg.textContent='Máy này không cho sao chép ảnh. Bấm Tải ảnh, hoặc nhấn giữ vào ảnh để lưu.'; }); return; }
            msg.textContent='Máy này không cho chia sẻ trực tiếp. Bấm Tải ảnh, hoặc nhấn giữ vào ảnh để lưu.';
          },'image/png'); }},'Chia sẻ / sao chép'),
        el('button',{class:'btn-ghost rp-close',type:'button',onclick:close,'aria-label':'Đóng'},'Đóng'));
      var img=el('img',{src:url,alt:'Ảnh báo cáo lãi lỗ toàn bộ xe',draggable:'false'});
      var stage=el('div',{class:'rp-stage'},img);
      var pct=el('span',{class:'rp-pct'},'100%');
      var zv=zoomView(stage,img,cv.width,cv.height,function(sc){ pct.textContent=Math.round(sc*100)+'%'; });
      var zbar=el('div',{class:'rp-zoom'},
        el('button',{class:'btn-ghost',type:'button','aria-label':'Thu nhỏ',onclick:function(){ zv.step(1/1.5); }},'−'), pct,
        el('button',{class:'btn-ghost',type:'button','aria-label':'Phóng to',onclick:function(){ zv.step(1.5); }},'+'),
        el('button',{class:'btn-ghost',type:'button',onclick:function(){ zv.fit(); }},'Vừa khung'));
      var ov=el('div',{class:'rp-ov',role:'dialog','aria-modal':'true','aria-label':'Ảnh báo cáo lãi lỗ'},
        el('div',{class:'rp-top'}, acts, zbar), msg, stage,
        el('div',{class:'rp-hint'},'Dùng 2 ngón để phóng to, kéo để xem, chạm 2 lần để phóng to hoặc thu về.'));
      document.body.append(ov); document.addEventListener('keydown',esc); window.addEventListener('resize',zv.fit);
      zv.fit(); acts.firstChild.focus({preventScroll:true});
    }).then(function(){ btn.disabled=false; },function(e){ btn.disabled=false; status('Không tạo được ảnh: '+errText(e),'err'); });
  }
  /* ---------- danh sách file đã tải ---------- */
  function renderImports(){
    var ul=$('#imports'); ul.innerHTML=''; $('#allSum').textContent='Tất cả file đã tải ('+S.imports.length+')'; renderCoverage();
    if(!S.imports.length){ ul.append(el('li',{class:'m'},'Chưa có file nào.')); return; }
    S.imports.sort(function(a,b){ return (b.at||'').localeCompare(a.at||''); }).filter(function(im){ return nameHit(im.fileName); }).slice(0,60).forEach(function(im){
      var c=im;
      ul.append(el('li',null, el('div',{style:'min-width:0'}, el('b',null,im.fileName), el('div',{class:'m'},(im.date?'Ngày '+dmy(im.date)+' · ':'')+(c.trips||0)+' chuyến · '+(c.tolls||0)+' cầu đường · '+(c.extras||0)+' trung chuyển · '+(c.revenue||0)+' doanh thu · tải lúc '+im.at)),
        el('button',{class:'btn-del',type:'button',onclick:function(e){ arm(e.currentTarget,function(){ return deleteImport(im); }); }},'Xoá file này')));
    });
  }
  /* ---------- kiểm tra file theo ngày: đủ / thiếu / trùng / chưa tải ---------- */
  function nameKey(s){ return strip(s).replace(/[._\/\\]/g,'-').replace(/\s+/g,' '); }
  function nameHit(name){ return !S.fq || nameKey(name).indexOf(nameKey(S.fq))>=0; }
  function lastDay(ym){ var y=+ym.slice(0,4), m=+ym.slice(5,7); return new Date(y,m,0).getDate(); }
  function renderMonthSelect(){
    var sel=$('#fMonth'); if(!sel) return; var cur=S.from.slice(0,7), set={}, d=new Date();
    for(var i=0;i<12;i++){ var x=new Date(d.getFullYear(),d.getMonth()-i,1); set[iso(x).slice(0,7)]=1; }
    S.imports.forEach(function(im){ if(/^\d{4}-\d{2}/.test(im.date||'')) set[im.date.slice(0,7)]=1; });
    set[cur]=1;
    var custom=!(S.from===cur+'-01' && S.to===cur+'-'+pad(lastDay(cur)));
    sel.innerHTML='';
    if(custom) sel.append(el('option',{value:''},'Khoảng ngày tự chọn'));
    Object.keys(set).sort().reverse().forEach(function(ym){ sel.append(el('option',{value:ym},'Tháng '+ym.slice(5,7)+'/'+ym.slice(0,4))); });
    sel.value=custom?'':cur;
  }
  function renderCoverage(){
    var body=$('#covBody'); if(!body) return; body.innerHTML='';
    var cov={};
    function add(d,k,id){ if(!d||!id||d<S.from||d>S.to) return; var c=cov[d]||(cov[d]={cost:{},toll:{},rev:{},vp:{}}); c[k][id]=1; }
    S.data.trips.forEach(function(t){ add(t.date,'cost',t.imp); });
    S.data.extras.forEach(function(t){ add(t.date,'cost',t.imp); });
    S.data.tolls.forEach(function(t){ add(t.date,'toll',t.imp); });
    S.data.revenue.forEach(function(t){ if(t.src!=='tay') add(t.date,'rev',t.imp); });
    S.data.overhead.forEach(function(t){ if(t.kind==='vp') add(t.date,'vp',t.imp); });
    S.imports.forEach(function(im){ kindsOf(im).forEach(function(k){ add(im.date,k,im.id); }); });
    var today=iso(new Date()), end=S.to<today?S.to:today, days=[];
    for(var d=new Date(S.from+'T00:00:00'); iso(d)<=end; d.setDate(d.getDate()+1)) days.push(iso(d));
    Object.keys(cov).forEach(function(x){ if(days.indexOf(x)<0) days.push(x); });
    days.sort().reverse();
    var WD=['CN','T2','T3','T4','T5','T6','T7'];
    var rows=days.map(function(day){ var c=cov[day]||{cost:{},toll:{},rev:{},vp:{}};
      var n={}, miss=[], dup=[]; KIND.forEach(function(k){ n[k[0]]=Object.keys(c[k[0]]).length; if(!n[k[0]]) miss.push(k[1]); if(n[k[0]]>1) dup.push(k[1]); });
      var st= miss.length===KIND.length?'none':(dup.length?'dup':(miss.length?'miss':'ok'));
      return {day:day, c:c, n:n, miss:miss, dup:dup, st:st}; });
    var cnt={all:rows.length, miss:0, dup:0, none:0, ok:0};
    rows.forEach(function(r){ if(r.st==='ok') cnt.ok++; if(r.st==='none') cnt.none++; if(r.miss.length&&r.st!=='none') cnt.miss++; if(r.dup.length) cnt.dup++; });
    function rowNames(r){ var out=[]; KIND.forEach(function(k){ Object.keys(r.c[k[0]]).forEach(function(id){ out.push(impById(id).fileName); }); }); return out; }
    rows.forEach(function(r){ r.hit=!S.fq || rowNames(r).some(nameHit); });
    var byDay={}; rows.forEach(function(r){ byDay[r.day]=r; });
    renderMonthSelect();
    /* lịch ô ngày của tháng */
    var ym=S.from.slice(0,7), nd=lastDay(ym), grid=$('#mDays'); grid.innerHTML='';
    var mc={ok:0,part:0,none:0,fut:0};
    for(var di=1;di<=nd;di++){ (function(day){
      var r=byDay[day], cls;
      if(day>today && !(r&&r.st!=='none')) cls='fut';
      else if(!r||r.st==='none') cls='none';
      else if(r.st==='ok') cls='ok';
      else cls=r.dup.length?'dup':'part';
      mc[cls==='dup'?'part':cls]++;
      var tip=dmy(day)+': '+(cls==='fut'?'chưa tới ngày':cls==='none'?'chưa có file':cls==='ok'?'đủ file':((r.miss.length?'thiếu '+r.miss.join(', '):'')+(r.dup.length?(r.miss.length?' · ':'')+'trùng '+r.dup.join(', '):'')));
      var dim=S.fq && !(r&&r.hit);
      grid.append(el('button',{type:'button',class:'day '+cls+(dim?' dim':''),title:tip,'aria-pressed':String(S.fday===day),
        onclick:function(){ S.fday=S.fday===day?'':day; renderCoverage(); }}, String(+day.slice(8)))); })(ym+'-'+pad(di)); }
    var inRange=S.from.slice(0,7)===S.to.slice(0,7);
    $('#mSum').innerHTML='';
    $('#mSum').append('Tháng '+ym.slice(5,7)+'/'+ym.slice(0,4)+(inRange?'':' (từ '+dmy(S.from)+')')+': ',
      el('b',null,mc.ok+' ngày đủ file'),', ',el('b',null,mc.part+' ngày thiếu / trùng'),' (ô vàng), ',el('b',null,mc.none+' ngày chưa có'),' (ô đỏ).',
      S.fq?' Đang tìm "'+S.fq+'": '+rows.filter(function(r){ return r.hit&&r.st!=='none'; }).length+' ngày khớp.':'',
      S.fday?el('button',{class:'btn-del',type:'button',style:'margin-left:6px',onclick:function(){ S.fday=''; renderCoverage(); }},'Bỏ chọn ngày '+dmy(S.fday)):'');
    var fb=$('#fbar'); fb.innerHTML='';
    [['all','Tất cả'],['miss','Thiếu file'],['dup','Trùng'],['none','Chưa tải'],['ok','Đủ']].forEach(function(f){
      fb.append(el('button',{type:'button','aria-pressed':String(S.ff===f[0]),onclick:function(){ S.ff=f[0]; renderCoverage(); }},f[1],el('b',null,cnt[f[0]]))); });
    $('#covRange').textContent=dmy(S.from)+' – '+dmy(end<S.from?S.from:end);
    var show=rows.filter(function(r){ if(S.fday) return r.day===S.fday; if(S.fq&&(!r.hit||r.st==='none')) return false; return S.ff==='all'||(S.ff==='miss'?(r.miss.length&&r.st!=='none'):S.ff==='dup'?r.dup.length:r.st===S.ff); });
    show.forEach(function(r){ var dd=new Date(r.day+'T00:00:00');
      var tds=KIND.map(function(k){ var ids=Object.keys(r.c[k[0]]);
        if(!ids.length) return el('td',{class:'miss'},el('span',{class:'lbl'},'✕ Thiếu'));
        return el('td',{class:ids.length>1?'dup':null}, ids.map(function(id){ var im=impById(id);
          return el('div',{class:'fc',title:im.fileName+(im.at?' · tải lúc '+im.at:'')}, el('span',{class:'ok'},'✓'), el('span',{class:'nm'},im.fileName),
            el('button',{class:'x',type:'button','aria-label':'Xoá file '+im.fileName,onclick:function(e){ armX(e.currentTarget,function(){ return deleteImport(im); }); }},'×')); })); });
      var tags=[]; if(r.st==='ok') tags.push(el('span',{class:'st ok'},'Đủ'));
      if(r.st==='none') tags.push(el('span',{class:'st none'},'Chưa tải'));
      else { if(r.miss.length) tags.push(el('span',{class:'st miss'},'Thiếu: '+r.miss.join(', '))); if(r.dup.length) tags.push(el('span',{class:'st dup'},'Trùng: '+r.dup.join(', '))); }
      body.append(el('tr',null, el('td',{class:'dt'},dmy(r.day),el('small',null,WD[dd.getDay()])), tds, el('td',null,tags)));
    });
    var em=$('#covEmpty'); em.hidden=show.length>0; em.textContent=rows.length?'Không có ngày nào ở mục này.':'Chưa có ngày nào trong khoảng đã chọn.';
  }
  function armX(btn,fn){
    if(!btn.dataset.armed){ btn.dataset.armed='1'; btn.classList.add('armed'); btn.textContent='Xoá?';
      setTimeout(function(){ if(btn.isConnected){ delete btn.dataset.armed; btn.classList.remove('armed'); btn.textContent='×'; } },4000); return; }
    btn.disabled=true; fn().catch(function(e){ btn.disabled=false; fail(e); });
  }
  function loadImports(){ return call('listImports',S.pin).then(function(r){ S.imports=r; renderImports(); }).catch(fail); }
  function deleteImport(im){
    return call('deleteImport',S.pin,im.id).then(function(){ status('Đã xoá dữ liệu của file '+im.fileName+'.','ok'); setTimeout(function(){ status(''); },3000); loadImports(); return load(); });
  }
  function arm(btn,fn){
    if(!btn.dataset.armed){ btn.dataset.armed='1'; btn.classList.add('armed'); var old=btn.textContent; btn.textContent='Bấm lần nữa để xoá';
      setTimeout(function(){ if(btn.isConnected){ delete btn.dataset.armed; btn.classList.remove('armed'); btn.textContent=old; } },4000); return; }
    btn.disabled=true; fn().catch(function(e){ btn.disabled=false; fail(e); });
  }

  $('#fMonth').addEventListener('change',function(e){ var ym=e.target.value; if(!ym) return; S.fday=''; setRange(ym+'-01', ym+'-'+pad(lastDay(ym))); });
  $('#fName').addEventListener('input',function(e){ S.fq=e.target.value.trim(); S.fday=''; renderImports(); });

  /* ---------- khởi động ---------- */
  var saved=null; try{ saved=JSON.parse(localStorage.getItem('ll_range')||'null'); }catch(e){}
  S.from=saved&&saved[0]||''; S.to=saved&&saved[1]||'';
  if(!S.from){ var d=new Date(); S.from=iso(new Date(d.getFullYear(),d.getMonth(),1)); S.to=iso(new Date(d.getFullYear(),d.getMonth()+1,0)); }
  $('#dFrom').value=S.from; $('#dTo').value=S.to; $('#rangeNote').textContent='Từ '+dmy(S.from)+' đến '+dmy(S.to);
  render();
  function showApp(on){ $('#loginCard').hidden=on; $('#app').hidden=!on; $('#app').style.display=on?'flex':'none'; }
  function logout(){ S.pin=''; try{ sessionStorage.removeItem('ll_pin'); }catch(e){} showApp(false); }
  function enter(p){ return call('login',p).then(function(){ S.pin=p; try{ sessionStorage.setItem('ll_pin',p); }catch(e){} showApp(true); status(''); load(); loadImports(); }); }
  $('#fLogin').addEventListener('submit',function(e){ e.preventDefault(); var p=$('#pin').value.trim(); if(!p){ status('Nhập mã PIN.','err'); return; } enter(p).then(function(){ $('#pin').value=''; }).catch(function(e){ status(errText(e),'err'); }); });
  $('#logout').addEventListener('click',logout);
  $('#btnReport').addEventListener('click',showReport);
  showApp(false);
  var sp=''; try{ sp=sessionStorage.getItem('ll_pin')||''; }catch(e){}
  if(sp) enter(sp).catch(function(){ logout(); });
})();
</script>
</body>
</html>
IDXEOF
cat > /etc/systemd/system/namhai-ve.service <<'SVEOF'
[Unit]
Description=NAM HAI AI - ve anh bao cao
After=network-online.target
[Service]
WorkingDirectory=/opt/namhai/ve
ExecStart=/usr/bin/node /opt/namhai/ve/ve.js
Environment=TZ=Asia/Ho_Chi_Minh
Environment=NH_CONG=9200
Restart=always
RestartSec=3
DynamicUser=yes
[Install]
WantedBy=multi-user.target
SVEOF
systemctl daemon-reload
systemctl enable namhai-ve.service >/dev/null 2>&1 || true
systemctl restart namhai-ve.service
cat > /etc/caddy/Caddyfile <<CADEOF
$TEN {
	route {
		@sai not header X-NamHai-Key $KEY
		respond @sai "cam" 403
		request_header -X-NamHai-Key
		@ve path /ve /ve/*
		reverse_proxy @ve 127.0.0.1:9200
		reverse_proxy 127.0.0.1:9100
	}
}
CADEOF
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy || systemctl restart caddy
sleep 5
echo
echo "=================================================="
echo " May ve anh: $(systemctl is-active namhai-ve.service)  (phai la active)"
echo " Phong chu: $(ls fonts | wc -l)/4"
echo " Thu: $(curl -s --max-time 15 http://127.0.0.1:9200/ve/ping)  (phai la: ve-anh ok)"
echo " Phien ban ve anh: 1"
echo "=================================================="
