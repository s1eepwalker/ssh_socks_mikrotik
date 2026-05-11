# Прозрачный L3-роутинг через SSH-туннель: контейнер `route/`

**Дата:** 2026-05-11
**Статус:** дизайн утверждён, к реализации

## Задача

Добавить третий контейнер `route/` рядом с существующими `socks/` и `mtg/`. Он работает как прозрачный L3-gateway: MikroTik роутит маркированный трафик (по `dst-address-list`) на его veth-адрес, контейнер заворачивает TCP в SOCKS5 поверх SSH-туннеля на удалённый сервер. Цель — заменить нестабильное SSTP-соединение для тех же доменов, что сейчас идут через SSTP.

## Мотивация

РКН агрессивно рвёт SSTP-соединения с MikroTik, что ломает текущую схему обхода для домен-листа. Альтернативные варианты:

- **`ssh -w` (TUN-over-SSH)** — требует правок на сервере (`PermitTunnel yes`, root) и более сложного reverse-сетапа.
- **redsocks + dst-nat** — TCP-only через NAT-перенаправление, не прозрачно по dst-IP.
- **tun2socks поверх существующего SSH `-D`** — выбран. Сервер не меняем, переиспользуем тот же SSH-эндпоинт.

В качестве tun2socks выбран `hev-socks5-tunnel` (C, ~200KB):
- Активно поддерживается.
- Уже эксплуатируется пользователем в соседнем byedpi-контейнере на этой же RouterOS, паттерн отработан.
- В разы меньше Go-альтернатив (xjasonlyu/tun2socks ~7MB), при ограниченной flash-памяти на роутере это важно.

Feasibility подтверждена на hAP ax^3 / RouterOS 7.20.6 (arm64) пробным контейнером `tun-check/`:
- `/dev/net/tun` создаётся RouterOS автоматически как char-device внутри namespace (mount не нужен и даже вреден — затирает реальное устройство).
- Ядро содержит `tun` модуль (`/proc/modules`, `/sys/class/misc/tun`).
- `CapPrm: 0x3fffffffff` — все 38 capabilities, включая `CAP_NET_ADMIN`.
- `ip tuntap add`, `ip rule add iif`, `ip route add ... table N`, sysctl `ip_forward` — всё работает.
- RouterOS дефолтно ставит `from all masquerade` для исходящих из контейнера → MASQUERADE настраивать не надо.

## Объём изменений

- Новый каталог `route/` с `Dockerfile`, `entrypoint.sh`.
- `README.md` — секция `route/` (env, RouterOS-команды, валидация).
- `CLAUDE.md` — упомянуть третий контейнер и его назначение.

Существующие `socks/` и `mtg/` — не трогаем.

## Архитектура

```
Клиент LAN 192.168.88.10
  │ dst=BLOCKED_IP
  ▼
MikroTik:
  /ip firewall mangle (mark-routing на dst-address-list)
  /routing rule  → gateway = veth-route IP контейнера
  │
  ▼ veth (bridge)
Container ns:
  eth*   192.168.254.10, default GW 192.168.254.1
  tun0   198.18.0.1/30           ← создан вручную (ip tuntap)
  policy routing:
    ip rule add iif <input-if> lookup 100
    ip route add default dev tun0 table 100
  │
  ▼ (forwarded TCP пакеты)
hev-socks5-tunnel — терминирует TCP с tun0, открывает CONNECT через SOCKS5
  │
  ▼
127.0.0.1:1080  ←  ssh -N -D 127.0.0.1:1080 user@<active-host>
  │
  ▼
Remote SSH server → интернет → BLOCKED_IP
```

**Свойства:**

- Policy routing разделяет трафик: forwarded (iif=входящий veth-интерфейс) → таблица 100 → `default dev tun0`; собственный исходящий контейнера (SSH, DNS) → main table → `default dev eth* via 192.168.254.1`. Без этого SSH-loop сам себя бы зациклил через tun0.
- **MASQUERADE не настраиваем** — RouterOS-контейнер уже имеет `from all masquerade` rule по умолчанию.
- **TCP-only.** SSH `-D` не поддерживает UDP ASSOCIATE. Для конкретного use case (HTTPS-сайты, заблокированные по GeoIP РФ) этого достаточно; YouTube/QUIC у пользователя идёт через отдельный byedpi-контейнер.
- **Fail-closed.** Если ни один SSH-сервер недоступен — tun2socks отвечает RST на CONNECT, клиентский запрос валится. Трафик **не уходит в обход** через WAN с РФ-IP.

## Состав образа

| Бинарь | Размер | Источник |
|---|---|---|
| `ssh` (OpenSSH client) | ~700KB | alpine `openssh-client`, `ldd`-зависимости |
| `hev-socks5-tunnel` | ~200KB | собираем в Dockerfile из `github.com/heiher/hev-socks5-tunnel` |
| `busybox` | ~700KB | alpine |
| `ip` (iproute2) | ~250KB | alpine `iproute2-minimal` — busybox-вариант не поддерживает `ip rule` + `ip route table` полноценно |
| musl libc + .so | ~800KB | копируется по `ldd` |

**Итого:** scratch-образ, ~3 МБ tar.gz.

Multi-stage Dockerfile повторяет паттерн `socks/`:
1. Stage `build-hev`: alpine + `build-base cmake git`, клон `heiher/hev-socks5-tunnel`, `cmake && make`, strip бинаря.
2. Stage `build`: alpine + `openssh-client iproute2 busybox`, копирование бинарей и `ldd`-зависимостей в `/out`.
3. Stage `scratch`: финальный образ с симлинками busybox-апплетов (`sh`, `sleep`, `echo`, `date`, `chmod`, `cat`, `nc`).

## Переменные окружения

| Переменная | По умолчанию | Описание |
|---|---|---|
| `SSH_HOSTS` | — (обязательная) | Список SSH-серверов через запятую. Формат каждой записи: `host[:port]`. Без `:port` → используется `SSH_PORT`. Пример: `ams.example.com:2222,bishkek.example.com,fr.example.com:443`. |
| `SSH_HOST` | — | Совместимость с `socks/`. Если задан, а `SSH_HOSTS` — нет, трактуется как `SSH_HOSTS=$SSH_HOST`. |
| `SSH_USER` | `root` | SSH-пользователь, общий для всех серверов из `SSH_HOSTS`. |
| `SSH_PORT` | `22` | Дефолтный SSH-порт, если в записи `SSH_HOSTS` порт не указан. |
| `SSH_KEY` | `id_ed25519` | Имя файла ключа в `/ssh` (тот же mount, что в `socks/`/`mtg/`). |
| `TUN_NAME` | `tun0` | Имя TUN-устройства внутри namespace. |
| `TUN_ADDR` | `198.18.0.1/30` | Адрес на tun0. CGNAT-диапазон (RFC 6815), не пересекается с домашней сетью. |
| `SOCKS_PORT` | `1080` | Локальный порт SSH `-D` и upstream для hev-socks5-tunnel. |
| `RETRY_DELAY` | `5` | Пауза в секундах после полного перебора всех SSH-серверов до следующей попытки. |

## Поведение entrypoint.sh

```sh
#!/bin/sh
set -e

chmod 600 /ssh/${SSH_KEY:-id_ed25519}

HOSTS=${SSH_HOSTS:-${SSH_HOST}}
[ -z "$HOSTS" ] && { echo "SSH_HOSTS required"; exit 1; }

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
        ${SSH_USER:-root}@${HOST}
      echo "$(date) SSH ${HOST}:${PORT} exited ($?), trying next..."
      IFS=','
    done
    IFS=$OLDIFS
    echo "$(date) All SSH hosts failed, sleep ${RETRY_DELAY:-5}s..."
    sleep ${RETRY_DELAY:-5}
  done
) &

# Ждём, пока SSH-туннель слушает
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
ip rule add iif ${INPUT_IF} lookup 100 priority 100
ip route add default dev ${TUN_NAME:-tun0} table 100

# Конфиг hev-socks5-tunnel
TUN_IP=${TUN_ADDR%/*}
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

exec hev-socks5-tunnel /tmp/hev.yaml
```

**Существенные моменты:**

- `INPUT_IF` определяется runtime через `ip route show default` — имя veth-интерфейса внутри namespace на RouterOS не фиксировано (`eth0` не гарантирован).
- `udp: 'tcp'` в hev — попытка завернуть UDP-пакеты в TCP. SSH `-D` всё равно UDP не передаст, и UDP-соединения провалятся; альтернатива `udp: 'udp'` (UDP ASSOCIATE) с OpenSSH не сработает. Для use case (HTTPS) UDP не нужен.
- `set -e` действует только на главный поток. SSH-loop в фоне самовосстанавливающийся, его падение никого не валит.

## Конфигурация на MikroTik

```routeros
# 1. Mount для SSH-ключа — переиспользуем существующий ssh-key
# (создан ранее: /container mounts add name=ssh-key src=/ssh dst=/ssh)

# 2. veth
/interface veth add name=veth-route address=192.168.254.10/24 gateway=192.168.254.1
/interface bridge port add bridge=Bridge-Docker interface=veth-route

# 3. Env-переменные
/container envs add list=route-env key=SSH_HOSTS value="ams.example.com:2222,bishkek.example.com"
/container envs add list=route-env key=SSH_USER value="user1"
/container envs add list=route-env key=SSH_KEY value="id_rsa-VSCODE"
# опционально: SSH_PORT (дефолт 22), SOCKS_PORT (дефолт 1080), TUN_ADDR, RETRY_DELAY

# 4. Контейнер — БЕЗ /dev/net/tun mount
/container add file=route.tar.gz interface=veth-route envlist=route-env mounts=ssh-key logging=yes start-on-boot=yes

# 5. Маршрутизация маркированного трафика
# Если у тебя уже есть mangle+routing-table для SSTP, поменяй только gateway:
/routing rule set [find routing-mark=YOUR_MARK] gateway=192.168.254.10
# Откат: gateway=sstp-out
```

Конкретный mangle-rule и address-list — не входят в скоуп этого спека (у пользователя уже настроены).

## Обработка ошибок и жизненный цикл

| Сценарий | Поведение |
|---|---|
| Все SSH-серверы недоступны при старте | Фоновый ssh-loop крутится. Главный поток через 30 сек по `nc -z` стартует hev-socks5-tunnel — он будет отвечать клиентам RST на CONNECT, пока ssh не поднимется. Контейнер не уходит в crashloop. |
| Активный SSH-сервер падает | `ssh` exit → цикл идёт к следующему. Существующие TCP-соединения рвутся, новые — через новый сервер. |
| `hev-socks5-tunnel` крашнулся | `exec` → завершается контейнер → RouterOS перезапускает (`start-on-boot=yes`). |
| `ip tuntap add` или `ip rule` упали | `set -e` → exit → RouterOS перезапускает. Если ошибка устойчивая — видно в `/log print`. |
| Маркированный трафик пришёл, туннель не готов | Пакет → таблица 100 → tun0 → hev → SOCKS connect → fail → RST клиенту. **Fail-closed**: нет утечки на WAN. |
| `SSH_HOSTS` пуст, `SSH_HOST` задан | Эквивалент `SSH_HOSTS=$SSH_HOST` — поведение как у `socks/` с одним сервером. |

## Валидация

Ручная, на роутере:

1. **Контейнер запустился:** `/container print` → status=running. В `/log print where topics~"container"` видны строки «SSH: trying ...», «Starting hev-socks5-tunnel».
2. **TUN поднят:** `/container shell number=<N>` → внутри `ip link show tun0` → state UP; `ip rule show` содержит правило `iif <if> lookup 100`; `ip route show table 100` показывает `default dev tun0`.
3. **TCP идёт через туннель:** На клиенте в LAN, попадающем под маркировку, `curl https://ifconfig.me` → IP сервера Amsterdam/Бишкек, не РФ.
4. **Не-маркированный трафик мимо:** `curl https://ip-api.com/json` (если не в address-list) → РФ-IP. Подтверждает, что mangle работает избирательно.
5. **Фолбэк:** Положить первый сервер (или временно убрать его из `SSH_HOSTS` и перезапустить контейнер). Через `ConnectTimeout=10` переход на второй; `curl` продолжает работать, в логах виден переход.
6. **Fail-closed:** Все SSH недоступны → маркированный `curl` таймаутит, не возвращает РФ-IP.

## Вне скоупа (YAGNI)

- UDP-поддержка (SSH `-D` не умеет; в use case не нужно).
- Per-host разные `SSH_USER` / `SSH_KEY` / привилегированный набор опций. При надобности позже добавится в формат записи `user@host:port`.
- Health-check / latency-based выбор сервера. Простой round-robin при падении достаточен.
- Метрики/мониторинг состояния туннеля наружу.
- IPv6.
- Очистка артефактов `tun-check/` (этот каталог удаляется отдельным коммитом после успешной валидации `route/`).
