#!/bin/sh
set -e

chmod 600 /ssh/${SSH_KEY:-id_ed25519}

HOSTS=${SSH_HOSTS:-${SSH_HOST}}
[ -z "$HOSTS" ] && { echo "SSH_HOSTS (or SSH_HOST) required"; exit 1; }

# SSH-туннель с фолбэком в фоне
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
      ssh -N -D 127.0.0.1:${SOCKS_PORT:-1080} \
        -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes -o TCPKeepAlive=yes \
        -o ConnectTimeout=10 \
        -i /ssh/${SSH_KEY:-id_ed25519} \
        -p ${PORT} \
        ${SSH_USER:-root}@${HOST} || true
      echo "$(date) SSH ${HOST}:${PORT} exited, trying next..."
      IFS=','
    done
    IFS=$OLDIFS
    echo "$(date) All SSH hosts failed, sleep ${RETRY_DELAY:-5}s..."
    sleep ${RETRY_DELAY:-5}
  done
) &

# Ждём, пока SSH-туннель начнёт слушать
i=0; while [ $i -lt 30 ]; do i=$((i+1))
  busybox nc -z 127.0.0.1 ${SOCKS_PORT:-1080} 2>/dev/null && break
  sleep 1
done

# Конфиг hev-socks5-tunnel — он сам создаёт и поднимает tun-устройство
TUN_IP=${TUN_ADDR:-198.18.0.1/30}
TUN_IP=${TUN_IP%/*}
cat > /tmp/hev.yaml <<EOF
tunnel:
  name: ${TUN_NAME:-tun0}
  mtu: 8500
  ipv4: ${TUN_IP}
socks5:
  port: ${SOCKS_PORT:-1080}
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

# Policy routing: forwarded трафик → таблица 100 → tun0
# Делаем после старта hev, чтобы наш маршрут не вычистился при инициализации устройства.
# Priority 300 — после local (200), чтобы локальные доставки (SSH-ответы на наш IP)
# резолвились через local table раньше, чем попадут в наш default dev tun0.
INPUT_IF=$(ip route show default | awk '/^default/ {print $5; exit}')
echo "$(date) input interface detected: ${INPUT_IF}"
ip rule add iif ${INPUT_IF} lookup 100 priority 300
ip route add default dev ${TUN_NAME:-tun0} table 100

echo "$(date) policy routing ready, waiting on hev-socks5-tunnel..."
wait ${HEV_PID}
