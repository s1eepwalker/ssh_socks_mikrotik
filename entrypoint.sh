#!/bin/sh
chmod 600 /ssh/${SSH_KEY:-id_ed25519}

SSH_TUNNEL_PORT=10800
PROXY_PORT=${SOCKS_PORT:-1080}

# Запускаем SSH-туннель в фоне
start_ssh() {
  while true; do
    echo "$(date) Connecting to ${SSH_HOST}:${SSH_PORT:-22}..."
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
  done
}

start_ssh &

# Ждём пока SSH-туннель поднимется
sleep 3

# Генерируем конфиг 3proxy
CFG=/tmp/3proxy.cfg

cat > ${CFG} <<EOF
nscache 65536
nserver 8.8.8.8
nserver 1.1.1.1
timeouts 1 5 30 60 180 1800 15 60
log /dev/stderr
EOF

if [ -n "${SOCKS_USER}" ] && [ -n "${SOCKS_PASS}" ]; then
  cat >> ${CFG} <<EOF
users ${SOCKS_USER}:CL:${SOCKS_PASS}
auth strong
allow ${SOCKS_USER}
EOF
else
  cat >> ${CFG} <<EOF
auth none
allow *
EOF
fi

cat >> ${CFG} <<EOF
parent 1000 socks5 127.0.0.1 ${SSH_TUNNEL_PORT}
socks -p${PROXY_PORT} -i0.0.0.0
EOF

echo "$(date) Config:"
cat ${CFG}
echo "$(date) Starting 3proxy on port ${PROXY_PORT}..."
exec 3proxy ${CFG}
