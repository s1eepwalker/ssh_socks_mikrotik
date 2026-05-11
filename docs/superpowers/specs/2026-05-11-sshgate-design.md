# `sshgate/` — объединённый контейнер: L3-gateway + SOCKS/HTTP-листенер

**Дата:** 2026-05-11
**Статус:** дизайн утверждён, к реализации

## Задача

Объединить функции существующих `socks/` (application-level SOCKS5/HTTP-прокси) и `route/` (transparent L3-gateway для маркированного MikroTik-трафика) в один контейнер, использующий общий SSH-туннель с фолбэком. Обе роли работают одновременно поверх одного `ssh -N -D`. Старые контейнеры остаются в репо помеченными deprecated.

## Мотивация

`socks/` и `route/` отличаются только способом *входа* трафика — application-level (клиент явно указывает прокси) против transparent L3 (MikroTik роутит маркированный трафик). Способ *выхода* идентичен: оба используют `ssh -N -D` как SOCKS5-upstream. Держать два отдельных контейнера для пользователя, которому нужны обе роли, означает дублирование SSH-туннеля, ключа, контейнера и env — без выгоды.

Дополнительно `sshgate/` приносит из `route/` поддержку **списка SSH-серверов с фолбэком** (`SSH_HOSTS="host1:port1,host2"`), которой нет в текущем `socks/`. Это улучшает доступность для пользователей, у кого был только `socks/`.

`mtg/` остаётся отдельным — он MTProto-сервер с TLS-камуфляжем, его роль фундаментально отличается, и lifecycle/firewall-сетап лучше изолировать.

## Объём изменений

- Новый каталог `sshgate/` с `Dockerfile`, `entrypoint.sh`, `build.ps1`.
- `README.md`:
  - Добавить таблица-строку для `sshgate/`.
  - В шапку секций `socks/` и `route/` — пометка deprecated и ссылка на `sshgate/`.
  - Новая секция `sshgate/` (полная инструкция, env-таблица, миграция, troubleshooting).
- `CLAUDE.md` — обзор расширяется (четыре каталога, `socks/`/`route/` deprecated).

`socks/`, `route/`, `mtg/` — код не трогаем. Их образы остаются собираемыми.

## Архитектура

```
                ┌─── ssh -N -D 127.0.0.1:BACKEND_PORT ───┐
                │ Фоновый loop с фолбэком SSH_HOSTS      │
                └────────────┬──────────────┬────────────┘
                             │              │
                  как SOCKS5-upstream  как SOCKS5-upstream
                             │              │
            ┌────────────────▼─────┐  ┌─────▼──────────────────┐
            │ L3-роль (всегда)     │  │ App-listener (opt-in)  │
            │                      │  │                        │
            │ hev-socks5-tunnel    │  │ 3proxy                 │
            │ tun0 (198.18.0.1/30) │  │   SOCKS  -p$SOCKS_PORT │
            │ policy routing iif → │  │   HTTP   -p$HTTP_PORT  │
            │                      │  │ (только если SOCKS_PORT)│
            └──────────────────────┘  └────────────────────────┘
```

**Свойства:**

- **Общий SSH-туннель** — один `ssh -N -D 127.0.0.1:$SOCKS_BACKEND_PORT`, обе роли открывают независимые SOCKS5-сессии локально, SSH мультиплексирует.
- **L3-роль активна всегда** — overhead минимален (без трафика hev спит ~5 МБ RAM, idle CPU). Маркировка трафика на стороне MikroTik включается отдельно через routing-rule с gateway = IP контейнера + `%Bridge-Docker`.
- **App-listener активируется через env `SOCKS_PORT`** — без него внешних портов нет. Опционально HTTP через `HTTP_PORT`, auth через `SOCKS_USER`+`SOCKS_PASS`. Без auth — 3proxy с `auth none` (Telegram-совместимо).
- **TCP-only** — SSH `-D` UDP не поддерживает.
- **SSH-фолбэк** — `SSH_HOSTS` принимает список через запятую (формат `host[:port]`). При падении ssh entrypoint перебирает по очереди.
- **Fail-closed** — пока SSH-туннель не поднят, hev возвращает RST на forwarded TCP, 3proxy отвечает `connection refused` на explicit-клиентов. Утечки через WAN с РФ-IP нет.
- **Crash → restart** — при падении любого фонового компонента entrypoint завершается, RouterOS перезапускает контейнер (`start-on-boot=yes`). `wait -n` сторожит и hev, и 3proxy.

## Состав образа

Multi-stage build, scratch финал. Паттерн репо.

| Стадия | Назначение | Пакеты Alpine |
|---|---|---|
| `build-hev` | Сборка `hev-socks5-tunnel` из git | `build-base git linux-headers` |
| `build-3proxy` | Сборка `3proxy` из git | `build-base git` |
| `build` | Сбор бинарей + `ldd`-зависимостей | `openssh-client iproute2-minimal` |
| Финал (scratch) | Минимальный runtime + busybox-симлинки | — |

**Бинари в финальном образе:**

| Бинарь | Размер | Источник |
|---|---|---|
| `ssh` (OpenSSH client) | ~700 КБ | alpine `openssh-client` + `ldd` |
| `hev-socks5-tunnel` | ~330 КБ | сборка из `github.com/heiher/hev-socks5-tunnel`, stripped |
| `3proxy` | ~130 КБ | сборка из `github.com/3proxy/3proxy`, stripped |
| `busybox` | ~700 КБ | alpine |
| `ip` (iproute2-minimal) | ~250 КБ | alpine |
| musl libc + библиотеки | ~800 КБ | по `ldd` |
| **Итого образ** | **~4.5 МБ tar.gz** | |

**Busybox-симлинки** в финальном образе: `sh`, `sleep`, `echo`, `date`, `chmod`, `cat`, `nc`, `grep`, `head`, `awk` (последний на `/usr/bin/awk`).

## Переменные окружения

| Переменная | По умолчанию | Описание |
|---|---|---|
| **SSH-туннель** | | |
| `SSH_HOSTS` | — (обязательная) | Список серверов через запятую. Формат каждой записи: `host[:port]`. Без `:port` → используется `SSH_PORT`. Пример: `ams.example.com:2222,bishkek.example.com`. |
| `SSH_HOST` | — | Совместимость со старым `socks/`. Если задан, а `SSH_HOSTS` нет — трактуется как `SSH_HOSTS=$SSH_HOST`. |
| `SSH_USER` | `root` | SSH-пользователь, общий для всех серверов из `SSH_HOSTS`. |
| `SSH_PORT` | `22` | Дефолтный SSH-порт, если в записи `SSH_HOSTS` порт не указан. |
| `SSH_KEY` | `id_ed25519` | Имя файла ключа в `/ssh`. |
| `RETRY_DELAY` | `5` | Пауза в секундах после полного перебора всех `SSH_HOSTS` до следующей попытки. |
| `SOCKS_BACKEND_PORT` | `10800` | Локальный 127.0.0.1 порт SSH `-D` (внутренний; используется hev как `socks5.port` и 3proxy как `parent`). |
| **L3-роль (активна всегда)** | | |
| `TUN_NAME` | `tun0` | Имя TUN-устройства внутри namespace. |
| `TUN_ADDR` | `198.18.0.1/30` | Адрес на tun0. CGNAT-диапазон (RFC 6815), не пересекается с домашней сетью. |
| **App-listener (opt-in)** | | |
| `SOCKS_PORT` | — | Внешний порт SOCKS5. Если задан → 3proxy слушает `0.0.0.0:$SOCKS_PORT`. Без — внешний листенер не запускается. |
| `HTTP_PORT` | — | Внешний порт HTTP. Требует `SOCKS_PORT` (общий 3proxy-инстанс). |
| `SOCKS_USER` | — | Логин для auth (общий для SOCKS и HTTP). Без — `auth none` в 3proxy (Telegram-совместимо). |
| `SOCKS_PASS` | — | Пароль (требует `SOCKS_USER`). |

**Валидация на старте:**
- `SSH_HOSTS` (или `SSH_HOST`) обязательна — иначе exit 1.
- `HTTP_PORT` без `SOCKS_PORT` — exit 1 с понятным сообщением.
- `SOCKS_PASS` без `SOCKS_USER` — exit 1.

## Поведение entrypoint.sh

```sh
#!/bin/sh
set -e

# 1. Валидация
chmod 600 /ssh/${SSH_KEY:-id_ed25519}
HOSTS=${SSH_HOSTS:-${SSH_HOST}}
[ -z "$HOSTS" ] && { echo "SSH_HOSTS (or SSH_HOST) required"; exit 1; }
[ -n "$HTTP_PORT" ] && [ -z "$SOCKS_PORT" ] && \
  { echo "HTTP_PORT requires SOCKS_PORT"; exit 1; }
[ -n "$SOCKS_PASS" ] && [ -z "$SOCKS_USER" ] && \
  { echo "SOCKS_PASS requires SOCKS_USER"; exit 1; }
BACKEND_PORT=${SOCKS_BACKEND_PORT:-10800}

# 2. SSH-туннель с фолбэком (фон) — формат host[:port] в SSH_HOSTS
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
    sleep ${RETRY_DELAY:-5}
  done
) &

# 3. Wait for tunnel listening
i=0; while [ $i -lt 30 ]; do i=$((i+1))
  busybox nc -z 127.0.0.1 ${BACKEND_PORT} 2>/dev/null && break
  sleep 1
done

# 4. L3-роль: hev-socks5-tunnel + policy routing
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

hev-socks5-tunnel /tmp/hev.yaml &
HEV_PID=$!

# Ждём tun0 UP
i=0; while [ $i -lt 30 ]; do i=$((i+1))
  ip link show ${TUN_NAME:-tun0} 2>/dev/null | grep -q "state UP\|UNKNOWN" && break
  sleep 1
done

INPUT_IF=$(ip route show default | awk '/^default/ {print $5; exit}')
ip rule add iif ${INPUT_IF} lookup 100 priority 300
ip route add default dev ${TUN_NAME:-tun0} table 100

# Sysctl
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
for d in /proc/sys/net/ipv4/conf/*/; do
  [ -w "${d}rp_filter" ] && echo 0 > "${d}rp_filter"
done

# 5. App-listener: 3proxy (опционально, по SOCKS_PORT). Свой retry-loop в фоне.
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

# 6. Wait — hev падает → exit → RouterOS перезапустит контейнер целиком.
# 3proxy и ssh-loop — самовосстанавливающиеся в своих фоновых циклах.
echo "$(date) sshgate ready (route=on, listener=${SOCKS_PORT:-off})"
wait $HEV_PID
exit 1
```

**Существенные моменты:**
- `INPUT_IF` определяется runtime через `ip route show default` — имя veth-интерфейса внутри namespace на RouterOS не фиксировано.
- `ip rule` приоритет **300** — после `local`-таблицы (200). Без этого SSH-ответы контейнера на свой собственный IP уходили бы через `tun0` (kernel ловит `iif veth-X` рулом до `local`-доставки) → туннель умирает по keepalive.
- rp_filter=0 на все интерфейсы — иначе forwarding пакетов с `src=192.168.88.X` через veth не проходит (k ernel считает спуфингом, т.к. LAN не достижим напрямую из namespace контейнера).
- 3proxy запускается ПОСЛЕ настройки L3-роли (синхронно, быстро) — сразу принимает соединения с уже готовым SSH-туннелем.

## Конфигурация на MikroTik

```routeros
# 1. SSH-ключ — переиспользуем существующий mount (создан ранее):
# /container mounts add name=ssh-key src=/ssh dst=/ssh

# 2. veth
/interface veth add name=veth-sshgate address=192.168.254.11/24 gateway=192.168.254.1
/interface bridge port add bridge=Bridge-Docker interface=veth-sshgate

# 3. Env-переменные — минимум для L3-роли
/container envs add name=sshgate-env key=SSH_HOSTS value="ams.example.com:2222,bishkek.example.com"
/container envs add name=sshgate-env key=SSH_USER  value="user1"
/container envs add name=sshgate-env key=SSH_KEY   value="id_ed25519"

# 4. Env — добавить листенер (опционально)
# /container envs add name=sshgate-env key=SOCKS_PORT value="1080"
# /container envs add name=sshgate-env key=SOCKS_USER value="myuser"   # опц., с auth
# /container envs add name=sshgate-env key=SOCKS_PASS value="mypass"
# /container envs add name=sshgate-env key=HTTP_PORT  value="3128"     # требует SOCKS_PORT

# 5. Контейнер — БЕЗ /dev/net/tun mount, RouterOS создаёт сам
/container add file=sshgate.tar.gz interface=veth-sshgate envlist=sshgate-env mounts=ssh-key logging=yes start-on-boot=yes
/container print
/container start number=<N>

# 6. L3-роль: routing-rule (формат gateway КРИТИЧНО — IP%Bridge-Docker)
/ip route add dst-address=0.0.0.0/0 gateway=192.168.254.11%Bridge-Docker routing-table=<твоя-таблица>

# 7. App-listener: dst-nat для внешнего доступа (если SOCKS_PORT задан)
# /ip firewall nat add chain=dstnat dst-port=1080 protocol=tcp src-address=192.168.88.0/24 action=dst-nat to-addresses=192.168.254.11 to-ports=1080
# /ip firewall nat add chain=dstnat dst-port=1080 protocol=tcp in-interface=ether1 action=dst-nat to-addresses=192.168.254.11 to-ports=1080
```

## Backward compatibility и миграция

Старые контейнеры (`socks/`, `route/`) остаются в репо без изменений кода. В `README.md`/`CLAUDE.md` они помечены **deprecated** с указанием sshgate как нового рекомендованного варианта.

Если пользователь хочет переехать, заменяет `*.tar.gz` и **корректирует env**:

| С чего мигрируешь | Что менять |
|---|---|
| `socks/` без auth | `SSH_HOST` → `SSH_HOSTS` (одно значение OK); `SOCKS_PORT` оставить — получишь 3proxy без auth (функционально совместимо). |
| `socks/` с SOCKS-auth | `SSH_HOST` → `SSH_HOSTS`. Остальное (`SOCKS_USER`, `SOCKS_PASS`) без изменений. |
| `socks/` с HTTP-auth | то же + `HTTP_PORT` без изменений. |
| `route/` (только L3) | **Убрать `SOCKS_PORT` env**, иначе sshgate откроет внешний листенер 3proxy (новая семантика). Старая семантика `SOCKS_PORT` как «внутренний порт hev» в sshgate заменена на `SOCKS_BACKEND_PORT`. |

`MikroTik`-сторона (`gateway=...%Bridge-Docker` в `/ip route`, dst-nat правила) — без изменений, только IP/имя veth заменить если деплоится в новый namespace.

## Жизненный цикл и обработка ошибок

| Сценарий | Поведение |
|---|---|
| Все SSH-серверы недоступны при старте | Фоновый ssh-loop крутится, главный поток ждёт `nc -z 127.0.0.1:BACKEND_PORT` до 30 сек. Если не дождался — hev/3proxy всё равно запускаются, отвечают RST/refused. Контейнер не уходит в crashloop. |
| Активный SSH-сервер падает | ssh exit → loop идёт к следующему. Существующие TCP-соединения рвутся, новые открываются через новый сервер. |
| `hev-socks5-tunnel` упал | `wait $HEV_PID` возвращается → exit → RouterOS перезапускает контейнер целиком (включая 3proxy и ssh-loop). |
| `3proxy` упал | Самовосстанавливается через свой retry-loop (`while true; 3proxy; sleep 2; done`). L3-роль не затрагивается. |
| Маркированный TCP пришёл, туннель ещё не готов | hev → SOCKS connect → fail → RST клиенту. App-listener: `connection refused`. Утечки в обход нет. |
| L3-роль «бесполезна» (на MikroTik не настроен routing-rule) | hev слушает пустой tun0, idle. Без оверхеда CPU/сети. 3proxy работает независимо. |

## Валидация (ручная)

CI нет. После деплоя на роутер:

1. **Контейнер стартанул:** `/container print` → status=running. В `/log print where topics~"container"` цепочка:
   - `SSH: trying ...`
   - `Warning: Permanently added ...`
   - `Starting hev-socks5-tunnel...` (если такая строка есть; либо просто hev запустился без шума)
   - `tun0 is up`
   - `input interface detected: <veth>`
   - `policy routing ready` (часть `sshgate ready (route=on, listener=...)`)
   - `3proxy listening: ...` (если `SOCKS_PORT`)
   - `sshgate ready (route=on, listener=<port|off>)`

2. **L3-роль работает:** С LAN-клиента под mangle-маркировкой:
   ```bash
   curl https://ifconfig.me   # → IP активного SSH-сервера, не РФ
   ```
   Не-маркированный домен → РФ-IP (регресс).

3. **App-listener работает (если `SOCKS_PORT` задан):**
   ```bash
   curl -x socks5://<router-ip>:1080 https://ifconfig.me        # без auth
   curl -x socks5://u:p@<router-ip>:1080 https://ifconfig.me    # с auth
   curl -x http://u:p@<router-ip>:3128 https://ifconfig.me       # HTTP
   ```
   Без правильных credentials при включённом auth → `407 Proxy Authentication Required`.

4. **SSH-фолбэк:** временно подменить первый хост на мёртвый — через `ConnectTimeout=10` SSH идёт ко второму, обе роли продолжают работать.

5. **Crash-restart:** `/container exec number=<N> sh -c "kill 1"` — контейнер сам перезапустится за ~5–10 с.

6. **Fail-closed:** все SSH-серверы недоступны → `curl` через любую роль таймаутит, не возвращает РФ-IP.

## Вне скоупа (YAGNI)

- UDP-канал (SSH `-D` TCP-only, как и в `route/`).
- Отдельные SSH-серверы для L3-роли vs listener'а — один общий туннель.
- Per-host `SSH_USER` / `SSH_KEY` в `SSH_HOSTS` — общие для всех записей.
- Health-check / latency-based выбор сервера (round-robin при падении достаточен).
- Раздельные креды для SOCKS и HTTP (общие).
- TPROXY/REDIRECT-based архитектура (byedpi-style) — `gateway=IP%Bridge-Docker` + policy routing работает.
- Supervisor (runit/s6) для рестарта отдельных компонентов — контейнерный restart достаточен.
- IPv6.
- Метрики/мониторинг.
- Удаление старых каталогов `socks/`/`route/` (deprecated, но не удалены — пользователю, кому важен размер образа под одну роль, остаются доступны).
