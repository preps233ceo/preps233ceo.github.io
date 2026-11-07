#!/usr/bin/env bash
# MathPad class server — LiveKit (open source) on a small Ubuntu server.
# Run on the server:   sudo bash install.sh your-name.duckdns.org
# It installs LiveKit + Caddy (free HTTPS), opens the firewall, starts both,
# and prints the three values for Apps Script → Script properties.
set -euo pipefail

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
  echo "Usage: sudo bash install.sh your-name.duckdns.org"; exit 1
fi
if [ "$(id -u)" != "0" ]; then echo "Run with sudo."; exit 1; fi

echo "== Installing LiveKit server"
curl -sSL https://get.livekit.io | bash

KEY="MP$(openssl rand -hex 6)"
SECRET="$(openssl rand -base64 36 | tr -d '/+=' | cut -c1-40)"

cat > /etc/livekit.yaml <<YAML
port: 7880
bind_addresses:
  - "127.0.0.1"
rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 60000
  use_external_ip: true
turn:
  enabled: true
  domain: $DOMAIN
  udp_port: 3478
keys:
  $KEY: $SECRET
room:
  empty_timeout: 600
  max_participants: 60
logging:
  level: info
YAML
chmod 600 /etc/livekit.yaml

cat > /etc/systemd/system/livekit.service <<UNIT
[Unit]
Description=LiveKit server (MathPad classes)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/livekit-server --config /etc/livekit.yaml
Restart=always
RestartSec=3
LimitNOFILE=500000

[Install]
WantedBy=multi-user.target
UNIT

echo "== Installing Caddy (HTTPS certificate for $DOMAIN)"
apt-get update -y
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy
cat > /etc/caddy/Caddyfile <<CADDY
$DOMAIN {
  reverse_proxy 127.0.0.1:7880
}
CADDY

echo "== Opening the firewall on this server"
if command -v iptables >/dev/null; then
  for p in 80 443 7881; do iptables -I INPUT -p tcp --dport $p -j ACCEPT; done
  iptables -I INPUT -p udp --dport 3478 -j ACCEPT
  iptables -I INPUT -p udp --dport 50000:60000 -j ACCEPT
  DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 || true
  netfilter-persistent save >/dev/null 2>&1 || true
fi
if command -v ufw >/dev/null && ufw status | grep -q active; then
  ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 7881/tcp; ufw allow 3478/udp; ufw allow 50000:60000/udp
fi

systemctl daemon-reload
systemctl enable --now livekit
systemctl restart caddy

sleep 3
echo
echo "==========================================================="
echo " Class server ready. Put these in Apps Script → Script properties:"
echo
echo "   LIVEKIT_URL         wss://$DOMAIN"
echo "   LIVEKIT_API_KEY     $KEY"
echo "   LIVEKIT_API_SECRET  $SECRET"
echo
echo " Keep the secret private. Check: https://$DOMAIN should answer \"OK\"."
echo "==========================================================="
