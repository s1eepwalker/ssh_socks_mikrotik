#!/bin/sh
set -e

# DNS для 3proxy: нужен для резолва hostnames из CONNECT/SOCKS5-запросов
# (hev получает чистые IP-пакеты, ему DNS не нужен)
echo "nameserver 1.1.1.1" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf

# === 1. Валидация env ===
chmod 600 /ssh/${SSH_KEY:-id_ed25519}

HOSTS=${SSH_HOSTS:-${SSH_HOST}}
[ -z "$HOSTS" ] && { echo "SSH_HOSTS (or SSH_HOST) required"; exit 1; }
[ -n "$HTTP_PORT" ] && [ -z "$SOCKS_PORT" ] && \
  { echo "HTTP_PORT requires SOCKS_PORT"; exit 1; }
[ -n "$SOCKS_PASS" ] && [ -z "$SOCKS_USER" ] && \
  { echo "SOCKS_PASS requires SOCKS_USER"; exit 1; }

BACKEND_PORT=${SOCKS_BACKEND_PORT:-10800}

# === 2. SSH-туннель с фолбэком (фон) ===
(
  while true; do
    OLDIFS=$IFS; IFS=','
    for entry in $HOSTS; do
      IFS=$OLDIFS
      case "$entry" in
        *:*) HOST=${entry%:*}; PORT=${entry##*:} ;;
        *)   HOST=$entry;       PORT=${SSH_PORT:-22} ;;
      esac
      echo "$(date) SSH: trying ${HOST}:${PORT}..."
      ssh -N -D 127.0.0.1:${BACKEND_PORT} \
        -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes -o TCPKeepAlive=yes \
        -o ConnectTimeout=10 \
        -i /ssh/${SSH_KEY:-id_ed25519} \
        -p ${PORT} ${SSH_USER:-root}@${HOST} || true
      echo "$(date) SSH ${HOST}:${PORT} exited, trying next..."
      IFS=','
    done
    IFS=$OLDIFS
    echo "$(date) All SSH hosts failed, sleep ${RETRY_DELAY:-5}s..."
    sleep ${RETRY_DELAY:-5}
  done
) &

# === 3. Ждём, пока SSH-туннель начнёт слушать ===
i=0; while [ $i -lt 30 ]; do i=$((i+1))
  busybox nc -z 127.0.0.1 ${BACKEND_PORT} 2>/dev/null && break
  sleep 1
done

# === 4. L3-роль: hev-socks5-tunnel + policy routing ===
TUN_IP=${TUN_ADDR:-198.18.0.1/30}; TUN_IP=${TUN_IP%/*}
cat > /tmp/hev.yaml <<EOF
tunnel:
  name: ${TUN_NAME:-tun0}
  mtu: 8500
  ipv4: ${TUN_IP}
socks5:
  port: ${BACKEND_PORT}
  address: '127.0.0.1'
  udp: 'tcp'
misc:
  log-level: info
EOF

echo "$(date) Starting hev-socks5-tunnel..."
hev-socks5-tunnel /tmp/hev.yaml &
HEV_PID=$!

# Ждём, пока hev поднимет tun-устройство
i=0; while [ $i -lt 30 ]; do i=$((i+1))
  ip link show ${TUN_NAME:-tun0} 2>/dev/null | grep -q "state UP\|UNKNOWN" && break
  sleep 1
done
echo "$(date) ${TUN_NAME:-tun0} is up"

# Policy routing: priority 300 (после local=200)
INPUT_IF=$(ip route show default | awk '/^default/ {print $5; exit}')
echo "$(date) input interface detected: ${INPUT_IF}"
ip rule add iif ${INPUT_IF} lookup 100 priority 300
ip route add default dev ${TUN_NAME:-tun0} table 100

# sysctl
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
for d in /proc/sys/net/ipv4/conf/*/; do
  if [ -w "${d}rp_filter" ]; then
    echo 0 > "${d}rp_filter"
  fi
done

# === 5. App-listener: 3proxy (опционально, по SOCKS_PORT). Свой retry-loop. ===
if [ -n "$SOCKS_PORT" ]; then
  CFG=/tmp/3proxy.cfg
  {
    echo "nscache 65536"
    echo "timeouts 1 5 30 60 180 1800 15 60"
    echo "log /dev/stderr"
    if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
      echo "users ${SOCKS_USER}:CL:${SOCKS_PASS}"
      echo "auth strong"
      echo "allow ${SOCKS_USER}"
    else
      echo "auth none"
    fi
    echo "parent 1000 socks5 127.0.0.1 ${BACKEND_PORT}"
    echo "socks -p${SOCKS_PORT} -i0.0.0.0"

    if [ -n "$HTTP_PORT" ]; then
      echo "flush"
      if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
        echo "auth strong"
        echo "allow ${SOCKS_USER}"
      else
        echo "auth none"
      fi
      echo "parent 1000 socks5 127.0.0.1 ${BACKEND_PORT}"
      echo "proxy -n -p${HTTP_PORT} -i0.0.0.0"
    fi
  } > $CFG

  (
    while true; do
      3proxy $CFG || true
      echo "$(date) 3proxy exited, restart in 2s..."
      sleep 2
    done
  ) &
  echo "$(date) 3proxy listening: SOCKS=${SOCKS_PORT}${HTTP_PORT:+, HTTP=${HTTP_PORT}}, auth=${SOCKS_USER:-none}"
fi

# === 6. Wait — hev падает → exit → RouterOS перезапустит контейнер целиком ===
echo "$(date) sshgate ready (route=on, listener=${SOCKS_PORT:-off})"
wait $HEV_PID
exit 1
