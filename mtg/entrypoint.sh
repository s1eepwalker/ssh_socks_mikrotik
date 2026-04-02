#!/bin/sh

echo "nameserver 1.1.1.1" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf

PORT=${MTG_PORT:-443}
DOMAIN=${MTG_DOMAIN:-google.com}
SSH_TUNNEL_PORT=10800

# Запускаем SSH-туннель в фоне
if [ -n "${SSH_HOST}" ]; then
  chmod 600 /ssh/${SSH_KEY:-id_ed25519}
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
      ${SSH_USER:-root}@${SSH_HOST}
    echo "$(date) SSH exited ($?), reconnecting in 5s..."
    sleep 5
  done &

  # Ждём пока SSH-туннель поднимется
  echo "$(date) Waiting for SSH tunnel..."
  i=0; while [ $i -lt 30 ]; do i=$((i+1))
    if busybox nc -z 127.0.0.1 ${SSH_TUNNEL_PORT} 2>/dev/null; then
      echo "$(date) SSH tunnel is up"
      sleep 2
      break
    fi
    sleep 2
  done
  SOCKS_ARG="--socks5-proxy=socks5://127.0.0.1:${SSH_TUNNEL_PORT}"
fi

# Если секрет не задан — генерируем
if [ -z "${MTG_SECRET}" ]; then
  MTG_SECRET=$(mtg generate-secret ${DOMAIN})
  echo "$(date) Generated secret: ${MTG_SECRET}"
fi

echo "$(date) Secret: ${MTG_SECRET}"
echo "$(date) Starting mtg on 0.0.0.0:${PORT}..."

exec mtg simple-run 0.0.0.0:${PORT} ${MTG_SECRET} --prefer-ip=only-ipv4 ${SOCKS_ARG}
