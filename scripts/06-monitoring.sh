#!/usr/bin/env bash
# Backend health monitoring + Telegram alerting.
# Installs a systemd timer that runs `health-check` every few minutes; it alerts
# the parent's Telegram on any component that fails ALERT_THRESHOLD consecutive
# times (and on recovery). Credentials go in /etc/parental/telegram.env (0600).
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SELF_DIR}/lib.sh"
require_root

INTERVAL="${HEALTHCHECK_INTERVAL:-5min}"

log "Installing health-check + notify-telegram helpers..."
install -m 0755 "${SELF_DIR}/../bin/health-check"   /usr/local/sbin/health-check
install -m 0755 "${SELF_DIR}/../bin/notify-telegram" /usr/local/sbin/notify-telegram

# State dir (root-only) for consecutive-failure counters.
install -d -m 0750 /var/lib/parental
# Local health log (append-only, child cannot read; consistent with other logs).
if [[ ! -f "${LOG_DIR}/health.log" ]]; then
  : > "${LOG_DIR}/health.log"; chown root:root "${LOG_DIR}/health.log"; chmod 0640 "${LOG_DIR}/health.log"
fi

# Secret credentials file (NOT world-readable, unlike config/settings.env).
if [[ ! -f /etc/parental/telegram.env ]]; then
  cat > /etc/parental/telegram.env <<'EOF'
# Telegram alerting credentials (root-only). Fill these in:
#   1. Create a bot with @BotFather -> copy the token.
#   2. Message the bot once, then get your chat id from
#      https://api.telegram.org/bot<TOKEN>/getUpdates  (result[].message.chat.id)
# TELEGRAM_BOT_TOKEN=123456789:ABCdef...
# TELEGRAM_CHAT_ID=123456789
EOF
  warn "Fill in /etc/parental/telegram.env with your bot token + chat id."
fi
chown root:root /etc/parental/telegram.env
chmod 0600 /etc/parental/telegram.env

log "Installing systemd service + timer (every ${INTERVAL})..."
cat > /etc/systemd/system/parental-healthcheck.service <<'EOF'
[Unit]
Description=Parental backend health check + Telegram alerts
After=network-online.target squid.service dnsmasq.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/health-check
# Never let a hung check wedge the timer.
TimeoutStartSec=90
Nice=10
EOF

cat > /etc/systemd/system/parental-healthcheck.timer <<EOF
[Unit]
Description=Run parental backend health check every ${INTERVAL}

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL}
# Catch up after suspend/resume (the laptop sleeps when idle).
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now parental-healthcheck.timer
ok "Health monitor enabled (timer: parental-healthcheck.timer)."

if grep -q '^TELEGRAM_BOT_TOKEN=' /etc/parental/telegram.env 2>/dev/null; then
  log "Sending a startup test message to Telegram..."
  /usr/local/sbin/health-check --test || warn "Telegram test failed — check telegram.env + egress."
else
  warn "Telegram creds not set yet — alerts are inert until /etc/parental/telegram.env is filled in."
fi
ok "Monitoring installed. Check status any time with: sudo health-check --status"
