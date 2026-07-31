#!/usr/bin/env bash
# Network enforcement: local filtering DNS (dnsmasq), filtering proxy (Squid),
# and an nftables egress firewall that forces ALL of the child's traffic
# through them. Non-browser apps and bypass attempts are dropped.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SELF_DIR}/lib.sh"
require_root

CHILD_UID="$(id -u "${CHILD_USER}")"

# --- 1. Squid: explicit proxy, allow only allowlisted domains, log all -----
log "Writing Squid config..."
cat > /etc/squid/squid.conf <<EOF
http_port ${PROXY_PORT}

acl SSL_ports port 443
acl CONNECT method CONNECT

# Re-resolve DNS every minute so a stale/unreachable cached IP self-heals
# quickly (avoids sustained TCP_TUNNEL/503 on busy hosts like google/youtube).
positive_dns_ttl 1 minutes
negative_dns_ttl 10 seconds

# Block YouTube's embed-only domain: inline/"fenced-frame" players (e.g. Google
# Search's video preview) load the player from it to bypass the youtube.com
# channel allowlist. The child never needs it for normal (allowed) viewing.
acl yt_nocookie dstdomain .youtube-nocookie.com
http_access deny yt_nocookie

# Allow the health monitor to reach Telegram in every mode (this is the ONLY
# host allowed out besides the regenerated allowlist; the child has no way to
# invoke it — it needs the bot token in root-only /etc/parental/telegram.env).
acl telegram_api dstdomain api.telegram.org
http_access allow telegram_api

# The actual allow/deny decision is regenerated from ${ALLOWLIST} (and the
# open-mode flag) by regenerate.sh into this include. Closed mode = allowlist
# only; open mode = allow all. Either way, every request is still logged below.
include /etc/squid/parental-access.conf

# Logging — the tamper-proof, browser-independent record of every request.
access_log /var/log/squid/access.log squid
logfile_rotate 14
cache deny all
forwarded_for delete
via off
EOF
# Seed an ACL + a default-deny access include so Squid can start safely before
# regenerate.sh runs (regenerate overwrites the include per current mode).
[[ -f /etc/squid/allowlist.acl ]] || echo "# regenerated" > /etc/squid/allowlist.acl
if [[ ! -f /etc/squid/parental-access.conf ]]; then
  cat > /etc/squid/parental-access.conf <<'EOF'
# Seeded default-deny; regenerate.sh overwrites this.
acl allowed_domains dstdomain "/etc/squid/allowlist.acl"
http_access deny CONNECT !SSL_ports
http_access allow allowed_domains
http_access deny all
EOF
fi
systemctl enable squid 2>/dev/null || true
systemctl restart squid || warn "Squid failed to start; check 'journalctl -u squid'."
ok "Squid configured on ${PROXY_LISTEN}:${PROXY_PORT}."

# --- 2. dnsmasq: local resolver (allow zone is written by regenerate) -----
log "Configuring dnsmasq + system resolver..."
# Free up port 53 from systemd-resolved.
if systemctl is-active --quiet systemd-resolved; then
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/parental.conf <<'EOF'
[Resolve]
DNSStubListener=no
EOF
  systemctl restart systemd-resolved 2>/dev/null || true
fi
cat > /etc/dnsmasq.d/00-base.conf <<EOF
listen-address=127.0.0.1
bind-interfaces
cache-size=1000
# Drop AAAA (IPv6) answers. Many networks (incl. this deployment) have no
# working IPv6 egress; without this, dual-stack sites like YouTube resolve to
# an IPv6 address that Squid then fails to reach (TCP_TUNNEL/503 HIER_NONE),
# intermittently breaking access. Forcing IPv4-only makes it reliable.
filter-AAAA
# Hold DNS answers in cache at least 5 min so a brief upstream hiccup doesn't
# surface as a failed lookup.
min-cache-ttl=300
# Pin the YouTube Restricted-Mode endpoints to Google's stable IPs. The youtube
# hostnames are CNAMEd to these (see regenerate.sh); giving the CNAME *target* a
# permanent LOCAL record means the chain always resolves instantly and never
# has to be re-fetched upstream — this closes the transient gap where
# www.youtube.com returned a CNAME with no A on cache expiry (Squid 503).
# IPs verified 2026-07-03; if YouTube ever stops loading, re-check them with
#   dig +short A restrict.youtube.com @8.8.8.8
host-record=restrict.youtube.com,216.239.38.120
host-record=restrictmoderate.youtube.com,216.239.38.119
# Resolve Telegram's API in BOTH modes so the health monitor can send alerts
# (its only egress is via Squid; the child never reaches it — dstdomain allow
# in squid.conf is scoped to api.telegram.org only).
server=/api.telegram.org/8.8.8.8
# Sinkhole YouTube's embed-only domain. It is used by INLINE/EMBEDDED players
# (e.g. Google search's video preview, which runs in an isolated/fenced frame
# our content script cannot enter) to bypass the youtube.com channel allowlist.
# The child never needs it for normal allowed viewing (that happens on
# youtube.com), so blocking it outright closes that hole in ALL browsing modes.
address=/youtube-nocookie.com/0.0.0.0
EOF
# Raise dnsmasq's systemd start-rate ceiling. regenerate.sh restarts dnsmasq on
# every allowlist change, so adding a batch of channels (each `allow-youtube`
# call regenerates) can restart it a dozen-plus times within seconds. systemd's
# default limit of 5 starts per 10s then trips, and it refuses to start the
# service at all — leaving the box with NO resolver, which presents as "this
# site can't be reached" on every site. Keep a limit so a genuine crash-loop is
# still caught; just make it roomy enough for a batch of edits.
install -d -m 755 /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/parental-startlimit.conf <<'EOF'
[Unit]
StartLimitIntervalSec=30
StartLimitBurst=25
EOF
systemctl daemon-reload

# Point the system at dnsmasq.
rm -f /etc/resolv.conf
printf 'nameserver 127.0.0.1\noptions edns0\n' > /etc/resolv.conf
systemctl enable dnsmasq 2>/dev/null || true
systemctl restart dnsmasq || warn "dnsmasq failed; another resolver may hold port 53."
ok "dnsmasq configured (allow zone comes from regenerate.sh)."

# --- 3. nftables: child uid may only reach loopback (proxy + resolver) ----
log "Installing nftables egress firewall..."
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet parental {
  chain output {
    type filter hook output priority 0; policy accept;

    # Always allow loopback (this is where Squid + dnsmasq live).
    oifname "lo" accept

    # The child account may ONLY use loopback. Everything else is dropped,
    # so the only way out is via Squid/dnsmasq (which run as other users).
    meta skuid ${CHILD_UID} ip  daddr != 127.0.0.1 drop
    meta skuid ${CHILD_UID} ip6 daddr != ::1       drop
  }
}
EOF
systemctl enable nftables 2>/dev/null || true
systemctl restart nftables
ok "nftables egress firewall active (child uid ${CHILD_UID} confined to loopback)."

warn "Note: the child's browser is pointed at the proxy via Chrome policy."
ok "Network enforcement complete."
