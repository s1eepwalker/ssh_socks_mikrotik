# route/ Container Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third container `route/` that acts as a transparent L3 gateway, wrapping marked TCP traffic from MikroTik into SOCKS5 over an SSH tunnel with multi-server fallback.

**Architecture:** Multi-stage Alpine → scratch image (~3 MB). Entrypoint runs `ssh -N -D` in a background failover loop, brings up a TUN device, sets up policy routing so that traffic forwarded from the veth interface goes through `tun0`, then runs `hev-socks5-tunnel` in the foreground to bridge `tun0` ↔ local SOCKS5 listener.

**Tech Stack:** Alpine 3.20 build stages, scratch runtime, busybox + openssh-client + iproute2-minimal, hev-socks5-tunnel (built from source).

**Spec:** `docs/superpowers/specs/2026-05-11-route-tun2socks-design.md`

**Validation environment:** hAP ax^3 / RouterOS 7.20.6 (arm64). Feasibility of TUN device, CAP_NET_ADMIN, policy routing already confirmed via `tun-check/`.

---

## File Structure

**New files:**
- `route/Dockerfile` — multi-stage build (hev-socks5-tunnel compile + binary assembly + scratch final).
- `route/entrypoint.sh` — runtime: SSH fallback loop, TUN setup, policy routing, hev launch.
- `route/build.ps1` — Windows-side build/convert/gzip pipeline (mirrors `tun-check/build.ps1`).

**Modified files:**
- `README.md` — new `route/` section + table row in container summary.
- `CLAUDE.md` — overview paragraph updated to mention three containers.

**Removed files (final task):**
- `tun-check/` directory — feasibility probe, no longer needed.

---

## Task 1: Create route/Dockerfile

**Files:**
- Create: `route/Dockerfile`

- [ ] **Step 1: Write the Dockerfile**

Create `route/Dockerfile` with the following content:

```dockerfile
FROM alpine:3.20 AS build-hev
RUN apk add --no-cache build-base git
RUN git clone --recursive --depth 1 https://github.com/heiher/hev-socks5-tunnel.git /hev && \
    cd /hev && make && strip bin/hev-socks5-tunnel

FROM alpine:3.20 AS build
RUN apk add --no-cache openssh-client iproute2-minimal
RUN mkdir /out && \
    cp /usr/bin/ssh /out/ && \
    cp /bin/busybox /out/ && \
    cp /sbin/ip /out/ && \
    ldd /usr/bin/ssh | awk '/=>/{print $3}' | xargs -I{} cp {} /out/ && \
    ldd /bin/busybox | awk '/=>/{print $3}' | xargs -I{} cp -n {} /out/ && \
    ldd /sbin/ip | awk '/=>/{print $3}' | xargs -I{} cp -n {} /out/ && \
    cp /lib/ld-musl-*.so.1 /out/

FROM scratch
COPY --from=build /out/ld-musl-*.so.1 /lib/
COPY --from=build /out/lib*.so* /lib/
COPY --from=build /out/ssh /usr/bin/ssh
COPY --from=build /out/ip /sbin/ip
COPY --from=build /out/busybox /bin/busybox
COPY --from=build-hev /hev/bin/hev-socks5-tunnel /usr/bin/hev-socks5-tunnel
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/sh"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/sleep"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/echo"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/date"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/chmod"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/cat"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/nc"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/usr/bin/awk"]
RUN ["/bin/busybox", "mkdir", "-p", "/etc/ssh", "/root/.ssh", "/tmp"]
RUN ["/bin/busybox", "sh", "-c", "echo 'root:x:0:0:root:/root:/bin/sh' > /etc/passwd && echo 'root:x:0:' > /etc/group"]
COPY entrypoint.sh /entrypoint.sh
RUN ["/bin/busybox", "chmod", "+x", "/entrypoint.sh"]
ENTRYPOINT ["/entrypoint.sh"]
```

- [ ] **Step 2: Create entrypoint.sh stub so Dockerfile can build**

Create `route/entrypoint.sh` with placeholder:

```sh
#!/bin/sh
echo "route entrypoint stub — replaced in Task 2"
exit 1
```

- [ ] **Step 3: Commit scaffolding**

```bash
git add route/Dockerfile route/entrypoint.sh
git commit -m "Add route/ container Dockerfile and entrypoint stub"
```

---

## Task 2: Implement route/entrypoint.sh

**Files:**
- Modify: `route/entrypoint.sh` (replace stub)

- [ ] **Step 1: Write the full entrypoint**

Replace `route/entrypoint.sh` content with:

```sh
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

# TUN
ip tuntap add dev ${TUN_NAME:-tun0} mode tun
ip addr add ${TUN_ADDR:-198.18.0.1/30} dev ${TUN_NAME:-tun0}
ip link set ${TUN_NAME:-tun0} up

# Policy routing: forwarded трафик → таблица 100 → tun0
INPUT_IF=$(ip route show default | awk '/^default/ {print $5; exit}')
echo "$(date) input interface detected: ${INPUT_IF}"
ip rule add iif ${INPUT_IF} lookup 100 priority 100
ip route add default dev ${TUN_NAME:-tun0} table 100

# Конфиг hev-socks5-tunnel
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
exec hev-socks5-tunnel /tmp/hev.yaml
```

**Why `|| true` after `ssh ...`:** with `set -e`, a non-zero ssh exit would kill the subshell and stop the failover loop. `|| true` keeps the loop iterating.

- [ ] **Step 2: Commit**

```bash
git add route/entrypoint.sh
git commit -m "Implement route/ entrypoint with SSH-fallback, TUN, policy routing"
```

---

## Task 3: Create route/build.ps1 and verify image builds locally

**Files:**
- Create: `route/build.ps1`

- [ ] **Step 1: Write build script** (mirror of `tun-check/build.ps1`)

Create `route/build.ps1`:

```powershell
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

docker buildx build --platform linux/arm64 --provenance=false --sbom=false -t route:latest --load .

# Чистим возможный остаток от прошлых запусков (иначе skopeo упадёт «can't modify existing image»)
docker volume rm imgvol 2>$null | Out-Null
docker volume create imgvol | Out-Null

docker run --rm `
  -v imgvol:/out `
  -v /var/run/docker.sock:/var/run/docker.sock `
  quay.io/skopeo/stable:latest copy `
  docker-daemon:route:latest `
  docker-archive:/out/image.tar:route:latest

docker run --rm `
  -v imgvol:/data `
  -v "${PWD}:/host" `
  --entrypoint sh `
  quay.io/skopeo/stable:latest `
  -c "gzip -c /data/image.tar > /host/route.tar.gz"

docker volume rm imgvol | Out-Null

Write-Host "Done: $PWD\route.tar.gz"
```

- [ ] **Step 2: Run the build**

```powershell
powershell -ExecutionPolicy Bypass -File route\build.ps1
```

Expected: completes without errors. Last line shows `Done: ...\route\route.tar.gz`.

- [ ] **Step 3: Verify image size**

```powershell
ls route\route.tar.gz
```

Expected: file exists, size **< 8 MB** (target ~3 МБ; if substantially larger, hev-socks5-tunnel build may have included debug symbols — verify `strip` ran).

- [ ] **Step 4: Sanity-check binaries are present**

```bash
docker run --rm --entrypoint /bin/busybox route:latest ls -la /usr/bin/ssh /usr/bin/hev-socks5-tunnel /sbin/ip /bin/busybox
```

Expected: all four files listed with sizes > 0. ssh ~700KB, hev-socks5-tunnel ~200KB, ip ~250KB, busybox ~700KB.

- [ ] **Step 5: Commit build script**

```bash
git add route/build.ps1
git commit -m "Add Windows build pipeline for route/ container"
```

---

## Task 4: Document route/ in README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add row to container summary table**

In README.md, find the table starting `| Контейнер | Описание | Размер |` and add a new row after `mtg/`:

```markdown
| [route/](route/) | Прозрачный L3-gateway: маркированный TCP MikroTik → SOCKS5 → SSH-туннель с фолбэком | ~3 МБ |
```

- [ ] **Step 2: Add full `route/` section to README**

Append the following at the end of the file (after the `mtg/` section):

```markdown
---

## route/ — Прозрачный L3-роутинг через SSH-туннель

L3-gateway для MikroTik. Маркированный по `dst-address-list` TCP-трафик заворачивается в SOCKS5 поверх SSH-туннеля на удалённый сервер. Поддерживает список SSH-серверов с автоматическим фолбэком при падении активного.

Внутри:
- `ssh -N -D 127.0.0.1:1080` (в фоне, с реконнектом и перебором серверов из `SSH_HOSTS`)
- `hev-socks5-tunnel` (~200KB) — терминирует TCP с TUN-устройства и форвардит через локальный SOCKS5
- Policy routing внутри namespace: forwarded трафик → `tun0`; собственный SSH-исходящий → main table

**Только TCP.** SSH `-D` не поддерживает UDP. Для UDP-сценариев (QUIC, игры) нужен отдельный канал.

### Настройка на MikroTik

```routeros
# veth (адрес не должен пересекаться с другими контейнерами)
/interface veth add name=veth-route address=192.168.254.10/24 gateway=192.168.254.1
/interface bridge port add bridge=Bridge-Docker interface=veth-route

# Переменные окружения
/container envs add list=route-env key=SSH_HOSTS value="ams.example.com:2222,bishkek.example.com"
/container envs add list=route-env key=SSH_USER value="user1"
/container envs add list=route-env key=SSH_KEY value="id_ed25519"
# опционально: SSH_PORT, SOCKS_PORT, TUN_ADDR, RETRY_DELAY

# Контейнер — ВАЖНО: /dev/net/tun mount НЕ нужен, RouterOS создаёт его сам
/container add file=route.tar.gz interface=veth-route envlist=route-env mounts=ssh-key logging=yes start-on-boot=yes

# Routing: точка переключения с SSTP (или любого старого шлюза) на наш контейнер
# Если у тебя уже есть routing-table для маркированного трафика — поменяй gateway:
/routing rule set [find routing-mark=YOUR_MARK] gateway=192.168.254.10
```

### Переменные окружения

| Переменная   | По умолчанию      | Описание                                                       |
|--------------|-------------------|----------------------------------------------------------------|
| `SSH_HOSTS`  | —                 | Список серверов через запятую, формат `host[:port]`            |
| `SSH_HOST`   | —                 | Совместимость с `socks/`. Если задан, а `SSH_HOSTS` нет — используется как единственный сервер |
| `SSH_USER`   | `root`            | SSH-пользователь (общий для всех серверов)                     |
| `SSH_PORT`   | `22`              | Дефолтный SSH-порт, если в `SSH_HOSTS` порт не указан          |
| `SSH_KEY`    | `id_ed25519`      | Имя файла ключа в `/ssh`                                       |
| `TUN_NAME`   | `tun0`            | Имя TUN-устройства внутри namespace                             |
| `TUN_ADDR`   | `198.18.0.1/30`   | Адрес на tun0 (CGNAT RFC 6815)                                  |
| `SOCKS_PORT` | `1080`            | Локальный порт SSH `-D` и upstream для hev-socks5-tunnel        |
| `RETRY_DELAY`| `5`               | Пауза в секундах после полного перебора серверов                |

### Проверка

```bash
# С клиента в LAN, попадающего под mangle-маркировку
curl https://ifconfig.me
# Должен вернуть IP активного сервера из SSH_HOSTS, не РФ

# Регресс: не-маркированный домен идёт мимо
curl https://ip-api.com/json
# Должен вернуть РФ-IP (если домен не в address-list)
```

Внутри контейнера (`/container shell number=<N>`):

```sh
ip link show tun0      # state UP
ip rule show           # содержит '100: from all iif <if> lookup 100'
ip route show table 100  # default dev tun0
```

### Фолбэк

Если в `SSH_HOSTS` несколько серверов через запятую — entrypoint крутит их по очереди при падении ssh. Существующие TCP-соединения через активный сервер рвутся при переключении (нечего поделать), новые открываются через следующий доступный.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Document route/ container deployment in README"
```

---

## Task 5: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the overview paragraph**

In `CLAUDE.md`, find the «Обзор» section starting with «Репозиторий содержит два минимальных Docker-образа» and replace its body:

**Find:**
```
Репозиторий содержит два минимальных Docker-образа, предназначенных для запуска на MikroTik RouterOS 7.4+ (контейнеры):

- `socks/` — SOCKS5/HTTP-прокси через SSH `-D` туннель. Три режима в одном образе: чистый `ssh -D` (SOCKS без auth), `3proxy` поверх SSH-туннеля (SOCKS с логином/паролем) и тот же `3proxy` с дополнительным HTTP-листенером при заданной `HTTP_PORT` (общие креды для обоих протоколов). Режим выбирается по наличию `SOCKS_USER`/`SOCKS_PASS` и `HTTP_PORT` в `entrypoint.sh`.
- `mtg/` — MTProto Proxy (`mtg`) с маскировкой под TLS. Если задан `SSH_HOST`, `mtg` запускается с `--socks5-proxy` указывающим на локальный SSH `-D` туннель; иначе работает напрямую.
```

**Replace with:**
```
Репозиторий содержит три минимальных Docker-образа, предназначенных для запуска на MikroTik RouterOS 7.4+ (контейнеры):

- `socks/` — SOCKS5/HTTP-прокси через SSH `-D` туннель. Три режима в одном образе: чистый `ssh -D` (SOCKS без auth), `3proxy` поверх SSH-туннеля (SOCKS с логином/паролем) и тот же `3proxy` с дополнительным HTTP-листенером при заданной `HTTP_PORT` (общие креды для обоих протоколов). Режим выбирается по наличию `SOCKS_USER`/`SOCKS_PASS` и `HTTP_PORT` в `entrypoint.sh`.
- `mtg/` — MTProto Proxy (`mtg`) с маскировкой под TLS. Если задан `SSH_HOST`, `mtg` запускается с `--socks5-proxy` указывающим на локальный SSH `-D` туннель; иначе работает напрямую.
- `route/` — прозрачный L3-gateway. MikroTik роутит маркированный TCP-трафик (по `dst-address-list`) на veth-адрес контейнера; внутри `hev-socks5-tunnel` читает пакеты с TUN-устройства и форвардит их через локальный `ssh -D` SOCKS5. Поддерживает список SSH-серверов с фолбэком (`SSH_HOSTS="host1:port1,host2"`). Только TCP. `/dev/net/tun` создаётся RouterOS автоматически — mount не нужен.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Document route/ container in CLAUDE.md"
```

---

## Task 6: Manual deployment and validation on MikroTik

This task does not produce a commit unless fixes are needed. It validates the implementation end-to-end on real hardware.

- [ ] **Step 1: Upload route.tar.gz to MikroTik**

Use WinBox Files panel, SFTP, or `scp` to copy `route\route.tar.gz` to the router's file area.

- [ ] **Step 2: Deploy on MikroTik**

Run on RouterOS terminal (replace placeholder values with real ones):

```routeros
/interface veth add name=veth-route address=192.168.254.10/24 gateway=192.168.254.1
/interface bridge port add bridge=Bridge-Docker interface=veth-route

/container envs add list=route-env key=SSH_HOSTS value="<real-host-1>:<port>,<real-host-2>"
/container envs add list=route-env key=SSH_USER value="<real-user>"
/container envs add list=route-env key=SSH_KEY value="id_rsa-VSCODE"

/container add file=route.tar.gz interface=veth-route envlist=route-env mounts=ssh-key logging=yes start-on-boot=no
/container print
/container start number=<N>
```

- [ ] **Step 3: Verify container started cleanly**

```routeros
/container print
```

Expected: `status=running` for the route container.

```routeros
/log print where topics~"container"
```

Expected log lines (chronologically):
- `SSH: trying <host>:<port>...`
- `input interface detected: <some-veth-name>`
- `Starting hev-socks5-tunnel...`

No `*** start` / `*** stop` loop — that indicates a crash.

- [ ] **Step 4: Verify internal state**

```routeros
/container shell number=<N>
```

Inside:
```sh
ip link show tun0       # expect: state UP, mtu 8500
ip rule show            # expect line like: 100: from all iif <if> lookup 100
ip route show table 100 # expect: default dev tun0 scope link
```

- [ ] **Step 5: Test the routing — temporarily mark a single host**

To validate without disturbing existing setup, add a one-off mangle rule for a test client:

```routeros
/ip firewall address-list add list=route-test address=ifconfig.me
/ip firewall mangle add chain=prerouting src-address=<your-test-client-ip>/32 dst-address-list=route-test \
    action=mark-routing new-routing-mark=route-test-mark passthrough=no
/routing table add name=route-test-table fib
/ip route add dst-address=0.0.0.0/0 gateway=192.168.254.10 routing-table=route-test-table
```

From the test client:
```bash
curl https://ifconfig.me
```

Expected: returns the IP of one of the SSH servers in `SSH_HOSTS` (not the router's WAN IP / РФ-IP).

- [ ] **Step 6: Test fallback**

Temporarily make the first SSH host unreachable (e.g., block via firewall on the SSH server, or set a wrong host in `SSH_HOSTS` and restart container). RouterOS `/container envs` doesn't support `set` on existing values — remove + add:

```routeros
/container stop number=<N>
/container envs remove [find list=route-env key=SSH_HOSTS]
/container envs add list=route-env key=SSH_HOSTS value="bad.example.com:22,<real-host-2>"
/container start number=<N>
```

Watch `/log print where topics~"container"`. Expected:
- `SSH: trying bad.example.com:22...`
- After `ConnectTimeout=10` seconds: `SSH bad.example.com:22 exited, trying next...`
- `SSH: trying <real-host-2>...`

`curl https://ifconfig.me` from the test client should still work.

Restore `SSH_HOSTS` after the test:

```routeros
/container stop number=<N>
/container envs remove [find list=route-env key=SSH_HOSTS]
/container envs add list=route-env key=SSH_HOSTS value="<real-host-1>:<port>,<real-host-2>"
/container start number=<N>
```

- [ ] **Step 7: Switch the real production routing rule**

Once steps 3-6 all pass, repoint the existing routing rule for the production address-list from SSTP to the new gateway:

```routeros
# verify which rule and current gateway
/routing rule print where routing-mark=<your-existing-mark>

# switch
/routing rule set [find routing-mark=<your-existing-mark>] gateway=192.168.254.10
```

Keep the SSTP interface configured but unused — rollback is one command: `gateway=sstp-out`.

- [ ] **Step 8: Cleanup test artifacts**

```routeros
/ip route remove [find routing-table=route-test-table]
/routing table remove route-test-table
/ip firewall mangle remove [find new-routing-mark=route-test-mark]
/ip firewall address-list remove [find list=route-test]
```

Set the container to auto-start on boot:

```routeros
/container set number=<N> start-on-boot=yes
```

No code commit for this task unless any of the steps revealed a bug requiring a fix in `route/entrypoint.sh` or `route/Dockerfile`. If a fix is needed, commit it with a clear message describing what failed and how it was fixed, then re-run from Step 1.

---

## Task 7: Remove tun-check/ feasibility probe

The `tun-check/` directory was a one-off probe to verify TUN/policy-routing feasibility on RouterOS. It's no longer needed once `route/` is validated.

**Files:**
- Remove: `tun-check/` (entire directory)

- [ ] **Step 1: Delete directory**

```bash
git rm -r tun-check/
```

- [ ] **Step 2: Verify clean state**

```bash
git status
```

Expected: deleted entries for `tun-check/Dockerfile`, `tun-check/entrypoint.sh`, `tun-check/build.ps1`, possibly `tun-check/tun-check.tar.gz` if it was committed (it shouldn't have been; check).

- [ ] **Step 3: Commit**

```bash
git commit -m "Remove tun-check/ feasibility probe — superseded by route/"
```
