#!/bin/bash
# NAM HAI AI - may chu trung gian Zalo tai Viet Nam (Ubuntu/Debian, chay bang root)
# Chi chuyen tiep lenh tu Apps Script toi Zalo, co mat khau rieng. Khong luu tin nhan.
# Chay lai nhieu lan van an toan: giu nguyen mat khau cu.
set -e
export DEBIAN_FRONTEND=noninteractive
IP=$(curl -4 -s https://api.ipify.org)
QG=$(curl -4 -s https://ipinfo.io/country || true)
TEN="$(echo "$IP" | tr . -).sslip.io"
KEY_FILE=/etc/caddy/namhai.key
apt-get update -y
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg openssl python3
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y && apt-get install -y caddy
fi
mkdir -p /etc/caddy
[ -s "$KEY_FILE" ] || openssl rand -hex 20 > "$KEY_FILE"
KEY=$(cat "$KEY_FILE")

mkdir -p /opt/namhai
cat > /opt/namhai/proxy.py <<'PYEOF'
# NAM HAI AI - chuyen tiep Zalo, giu nguyen ten header viet thuong (secret_key, access_token)
import http.server, http.client, socketserver, os
UP = {'/openapi/': 'openapi.zalo.me', '/oauth/': 'oauth.zaloapp.com'}
BO = {'host', 'connection', 'content-length', 'accept-encoding', 'x-forwarded-for', 'x-forwarded-host',
      'x-forwarded-proto', 'via', 'transfer-encoding', 'x-namhai-key', 'keep-alive'}
TEST = os.environ.get('NH_TEST')  # chi dung khi kiem thu

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def _tra(self, code, data, ct='text/plain'):
        self.send_response(code); self.send_header('Content-Type', ct)
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def _di(self):
        goc = next((p for p in UP if self.path.startswith(p)), None)
        if not goc: return self._tra(404, b'khong co')
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n) if n else None
        try:
            c = http.client.HTTPConnection('127.0.0.1', int(TEST), timeout=30) if TEST else http.client.HTTPSConnection(UP[goc], timeout=30)
            c.putrequest(self.command, '/' + self.path[len(goc):], skip_host=True, skip_accept_encoding=True)
            c.putheader('host', UP[goc])
            for k, v in self.headers.items():
                if k.lower() not in BO: c.putheader(k.lower(), v)
            if body is not None: c.putheader('content-length', str(len(body)))
            c.endheaders(body)
            r = c.getresponse(); data = r.read()
            self._tra(r.status, data, r.getheader('Content-Type') or 'application/json')
        except Exception as e:
            self._tra(502, ('loi chuyen tiep: %s' % e).encode())
    do_GET = do_POST = _di
    def log_message(self, *a): pass

class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

S(('127.0.0.1', 9100), H).serve_forever()
PYEOF
cat > /etc/systemd/system/namhai-zalo.service <<'SVEOF'
[Unit]
Description=NAM HAI AI - chuyen tiep Zalo
After=network-online.target
[Service]
ExecStart=/usr/bin/python3 /opt/namhai/proxy.py
Restart=always
RestartSec=3
DynamicUser=yes
[Install]
WantedBy=multi-user.target
SVEOF
systemctl daemon-reload
systemctl enable namhai-zalo.service >/dev/null 2>&1 || true
systemctl restart namhai-zalo.service

cat > /etc/caddy/Caddyfile <<EOF
$TEN {
	route {
		@sai not header X-NamHai-Key $KEY
		respond @sai "cam" 403
		request_header -X-NamHai-Key
		reverse_proxy 127.0.0.1:9100
	}
}
EOF
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
if command -v ufw >/dev/null && ufw status | grep -q active; then ufw allow 80/tcp; ufw allow 443/tcp; fi
systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy
sleep 8
echo
echo "=================================================="
echo " Quoc gia cua may chu: $QG  (phai la VN)"
echo " LINK     : https://$TEN"
echo " MAT KHAU : $KEY"
echo " Bo chuyen tiep: $(systemctl is-active namhai-zalo.service)  (phai la active)"
echo "=================================================="
echo "Kiem tra nhanh (phai hien chu: cam):"
curl -s --max-time 30 "https://$TEN/openapi/" || echo "(chua co chung chi HTTPS, doi 1-2 phut roi thu lai)"
echo
