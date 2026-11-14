#!/bin/bash
# NAM HAI AI – máy chủ trung gian Zalo tại Việt Nam (Ubuntu/Debian, chạy bằng root)
# Chỉ chuyển tiếp lệnh từ Apps Script tới Zalo, có mật khẩu riêng. Không lưu tin nhắn.
set -e
IP=$(curl -4 -s https://api.ipify.org)
QG=$(curl -4 -s https://ipinfo.io/country || true)
TEN="$(echo "$IP" | tr . -).sslip.io"
KEY_FILE=/etc/caddy/namhai.key
apt-get update -y
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg openssl
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y && apt-get install -y caddy
fi
[ -s "$KEY_FILE" ] || openssl rand -hex 20 > "$KEY_FILE"
KEY=$(cat "$KEY_FILE")
cat > /etc/caddy/Caddyfile <<EOF
$TEN {
	route {
		@sai not header X-NamHai-Key $KEY
		respond @sai "cam" 403
		request_header -X-NamHai-Key
		handle_path /openapi/* {
			reverse_proxy https://openapi.zalo.me {
				header_up Host {upstream_hostport}
			}
		}
		handle_path /oauth/* {
			reverse_proxy https://oauth.zaloapp.com {
				header_up Host {upstream_hostport}
			}
		}
		respond "khong co" 404
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
echo "=================================================="
echo "Kiem tra nhanh (phai hien chu: cam):"
curl -s --max-time 30 "https://$TEN/openapi/" || echo "(chua co chung chi HTTPS, doi 1-2 phut roi thu lai)"
echo
