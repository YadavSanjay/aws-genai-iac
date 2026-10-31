#!/bin/bash
# NAT configuration for Amazon Linux 2023.
#
# Applied via a systemd unit rather than one-shot cloud-init commands, because
# cloud-init runs only on FIRST boot. This instance is designed to be stopped
# and started on a schedule, so anything configured one-shot would silently
# vanish on the second start and present as "the internet stopped working".
set -euxo pipefail

# --- iptables is NOT preinstalled on AL2023 ----------------------------------
# The minimal AL2023 image ships without it — it normally arrives as a docker
# dependency, which is why this is easy to miss on a host that also runs
# containers. Without this line configure-nat.service fails on first boot, the
# instance comes up healthy, and every private subnet silently loses egress.
dnf install -y iptables-nft

# --- Kernel: forward packets between interfaces ------------------------------
cat >/etc/sysctl.d/99-nat.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
# Do not accept ICMP redirects: on a forwarding host they can be used to
# reroute traffic through an attacker-chosen next hop.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
SYSCTL
sysctl --system

# --- NAT rules, reapplied on every boot --------------------------------------
cat >/usr/local/sbin/configure-nat.sh <<'NATSCRIPT'
#!/bin/bash
set -euo pipefail

# Resolve the primary interface at runtime rather than hardcoding eth0/ens5 —
# the name differs across instance families and AL2023 releases.
IFACE="$(ip -o -4 route show to default | awk '{print $5; exit}')"

# Fail loudly and specifically. A bare "iptables: command not found" inside a
# systemd unit is easy to miss; the instance stays healthy and private-subnet
# egress simply never works.
command -v iptables >/dev/null || {
  echo "FATAL: iptables missing — NAT cannot function. Install iptables-nft." >&2
  exit 1
}

# Idempotent: the unit runs on every boot, and a stop/start must not stack
# duplicate rules.
iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE

# Forward established return traffic and anything originating in the VPC.
iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
NATSCRIPT
chmod 0755 /usr/local/sbin/configure-nat.sh

cat >/etc/systemd/system/configure-nat.service <<'UNIT'
[Unit]
Description=Configure NAT masquerading
# network-online, not just network: the default route must exist before the
# script can resolve the primary interface.
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/configure-nat.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now configure-nat.service
