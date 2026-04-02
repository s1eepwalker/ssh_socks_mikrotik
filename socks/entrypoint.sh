#!/bin/sh
chmod 600 /ssh/${SSH_KEY:-id_ed25519}

# Режим работы: если заданы SOCKS_USER и SOCKS_PASS — запускаем 3proxy с auth
# Иначе — простой SSH -D без авторизации
if [ -n "${SOCKS_USER}" ] && [ -n "${SOCKS_PASS}" ]; then
  # --- Режим 3proxy (с авторизацией) ---
  SSH_TUNNEL_PORT=10800
  PROXY_PORT=${SOCKS_PORT:-1080}

  # SSH-туннель в фоне
  while true; do
    echo "$(date) SSH: Connecting to ${SSH_HOST}:${SSH_PORT:-22}..."
    ssh -N -D 127.0.0.1:${SSH_TUNNEL_PORT} \
      -o StrictHostKeyChecking=accept-new \
      -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=3 \
      -o ExitOnForwardFailure=yes \
      -o TCPKeepAlive=yes \
      -o ConnectTimeout=10 \
      -i /ssh/${SSH_KEY:-id_ed25519} \
      -p ${SSH_PORT:-22} \
      ${SSH_USER:-root}@${SSH_HOST:?SSH_HOST required}
    echo "$(date) SSH exited ($?), reconnecting in 5s..."
    sleep 5
  done &

  sleep 5

  # resolv.conf для DNS
  echo "nameserver 1.1.1.1" > /etc/resolv.conf
  echo "nameserver 8.8.8.8" >> /etc/resolv.conf

  # Конфиг 3proxy
  CFG=/tmp/3proxy.cfg
  cat > ${CFG} <<EOF
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /dev/stderr
users ${SOCKS_USER}:CL:${SOCKS_PASS}
auth strong
allow ${SOCKS_USER}
parent 1000 socks5 127.0.0.1 ${SSH_TUNNEL_PORT}
socks -p${PROXY_PORT} -i0.0.0.0
EOF

  echo "$(date) Starting 3proxy on port ${PROXY_PORT} (auth: ${SOCKS_USER})..."
  exec 3proxy ${CFG}

else
  # --- Режим SSH -D (без авторизации) ---
  while true; do
    echo "$(date) Connecting to ${SSH_HOST}:${SSH_PORT:-22}..."
    ssh -N -D 0.0.0.0:${SOCKS_PORT:-1080} \
      -o StrictHostKeyChecking=accept-new \
      -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=3 \
      -o ExitOnForwardFailure=yes \
      -o TCPKeepAlive=yes \
      -o ConnectTimeout=10 \
      -i /ssh/${SSH_KEY:-id_ed25519} \
      -p ${SSH_PORT:-22} \
      ${SSH_USER:-root}@${SSH_HOST:?SSH_HOST required}
    echo "$(date) SSH exited ($?), reconnecting in 5s..."
    sleep 5
  done
fi
