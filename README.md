# MikroTik Proxy Containers

Минимальные Docker-контейнеры для MikroTik RouterOS — прокси через SSH-туннель на удалённый сервер.

## Состав

| Контейнер | Описание | Размер |
|-----------|----------|--------|
| [socks/](socks/) | SOCKS5-прокси (SSH -D), опционально с авторизацией через 3proxy | ~3.5 МБ |
| [mtg/](mtg/) | MTProto Proxy для Telegram, маскировка под TLS для обхода DPI | ~8 МБ |
| [route/](route/) | Прозрачный L3-gateway: маркированный TCP MikroTik → SOCKS5 → SSH-туннель с фолбэком | ~4 МБ |

---

## Общие требования

- MikroTik RouterOS 7.4+ с поддержкой контейнеров (arm64/amd64)
- SSH-ключ для подключения к удалённому серверу
- Docker с buildx для сборки образов

### Архитектура роутера

```routeros
/system resource print
```

Смотреть поле `architecture-name` (`arm64`, `x86_64`).

### Подготовка SSH-ключа

```bash
ssh-keygen -t ed25519 -f id_ed25519 -N ""
```

Публичный ключ (`id_ed25519.pub`) добавить в `~/.ssh/authorized_keys` на удалённом сервере.
Приватный ключ (`id_ed25519`) загрузить на MikroTik в `/ssh/id_ed25519`.

### Создать bridge для контейнеров (если ещё нет)

```routeros
/interface bridge add name=Bridge-Docker
/ip address add address=192.168.254.1/24 interface=Bridge-Docker
```

### Монтирование SSH-ключа

```routeros
/container mounts add name=ssh-key src=/ssh dst=/ssh
```

### Сборка и конвертация образа

Docker Desktop сохраняет образы в OCI-формате, MikroTik ожидает Docker V2.
Конвертация через `skopeo`:

```bash
# Сборка (из папки socks/ или mtg/)
docker buildx build --platform linux/arm64 --provenance=false --sbom=false -t IMAGE_NAME:latest --load .

# Конвертация OCI → Docker V2
docker volume create imgvol
docker run --rm -v imgvol:/out -v /var/run/docker.sock:/var/run/docker.sock \
  quay.io/skopeo/stable:latest copy \
  docker-daemon:IMAGE_NAME:latest \
  docker-archive:/out/image.tar:IMAGE_NAME:latest

# Скопировать и сжать
docker run --rm -v imgvol:/data -v "$(pwd):/host" --entrypoint "" \
  quay.io/skopeo/stable:latest \
  sh -c "cat /data/image.tar | gzip > /host/image.tar.gz"

# Очистка
docker volume rm imgvol
```

---

## socks/ — SOCKS5 Proxy

SOCKS5- и HTTP-прокси через SSH-туннель. Три режима работы:

- **Без авторизации** — чистый SSH `-D`, только SOCKS5 (совместим с Telegram, curl, браузерами)
- **SOCKS с авторизацией** — 3proxy + SSH-туннель, SOCKS5 с логином/паролем (Telegram не поддерживается из-за ограничений 3proxy)
- **SOCKS + HTTP с авторизацией** — то же, плюс HTTP-прокси на отдельном порту с теми же кредами (задаётся переменной `HTTP_PORT`)

### Настройка на MikroTik

```routeros
# veth
/interface veth add name=veth-socks address=192.168.254.8/24 gateway=192.168.254.1
/interface bridge port add bridge=Bridge-Docker interface=veth-socks

# Переменные окружения
/container envs add name=socks-env key=SSH_HOST value="1.2.3.4"
/container envs add name=socks-env key=SSH_USER value="user1"
/container envs add name=socks-env key=SSH_PORT value="22"
/container envs add name=socks-env key=SOCKS_PORT value="1080"
/container envs add name=socks-env key=SSH_KEY value="id_ed25519"
# Опционально — включить авторизацию (SOCKS):
# /container envs add name=socks-env key=SOCKS_USER value="myuser"
# /container envs add name=socks-env key=SOCKS_PASS value="mypassword"
# Опционально — включить HTTP-прокси (требует SOCKS_USER/SOCKS_PASS):
# /container envs add name=socks-env key=HTTP_PORT value="3128"

# Контейнер
/container add file=socks-tunnel.tar.gz interface=veth-socks envlist=socks-env mounts=ssh-key start-on-boot=yes

# DST-NAT SOCKS (локальная сеть)
/ip firewall nat add chain=dstnat dst-port=1080 protocol=tcp src-address=192.168.88.0/24 action=dst-nat to-addresses=192.168.254.8 to-ports=1080

# DST-NAT SOCKS (внешний доступ)
/ip firewall nat add chain=dstnat dst-port=1080 protocol=tcp in-interface=ether1 action=dst-nat to-addresses=192.168.254.8 to-ports=1080

# DST-NAT HTTP (локальная сеть) — если задан HTTP_PORT
# /ip firewall nat add chain=dstnat dst-port=3128 protocol=tcp src-address=192.168.88.0/24 action=dst-nat to-addresses=192.168.254.8 to-ports=3128

# DST-NAT HTTP (внешний доступ) — если задан HTTP_PORT
# /ip firewall nat add chain=dstnat dst-port=3128 protocol=tcp in-interface=ether1 action=dst-nat to-addresses=192.168.254.8 to-ports=3128
```

### Переменные окружения

| Переменная   | По умолчанию  | Описание                                                      |
|--------------|---------------|---------------------------------------------------------------|
| `SSH_HOST`   | —             | Адрес удалённого сервера                                      |
| `SSH_USER`   | `root`        | Пользователь SSH                                              |
| `SSH_PORT`   | `22`          | Порт SSH                                                      |
| `SOCKS_PORT` | `1080`        | Порт SOCKS-прокси                                             |
| `SSH_KEY`    | `id_ed25519`  | Имя файла ключа в `/ssh`                                     |
| `SOCKS_USER` | —             | Логин (общий для SOCKS и HTTP; без — auth отключён)          |
| `SOCKS_PASS` | —             | Пароль                                                        |
| `HTTP_PORT`  | —             | Порт HTTP-прокси (без — HTTP выключен; требует `SOCKS_USER`) |

### Проверка

```bash
# SOCKS без авторизации
curl -x socks5://192.168.88.1:1080 https://ifconfig.me

# SOCKS с авторизацией
curl -x socks5://myuser:mypassword@192.168.88.1:1080 https://ifconfig.me

# HTTP с авторизацией (если задан HTTP_PORT)
curl -x http://myuser:mypassword@192.168.88.1:3128 https://ifconfig.me
```

---

## mtg/ — MTProto Proxy для Telegram

MTProto Proxy с маскировкой под TLS для обхода DPI. Трафик к Telegram DC идёт через SSH-туннель на удалённый сервер.

### Настройка на MikroTik

```routeros
# veth
/interface veth add name=veth-mtg address=192.168.254.9/24 gateway=192.168.254.1
/interface bridge port add bridge=Bridge-Docker interface=veth-mtg

# Переменные окружения
/container envs add name=mtg-env key=SSH_HOST value="1.2.3.4"
/container envs add name=mtg-env key=SSH_USER value="user1"
/container envs add name=mtg-env key=SSH_PORT value="22"
/container envs add name=mtg-env key=SSH_KEY value="id_ed25519"
/container envs add name=mtg-env key=MTG_PORT value="443"
/container envs add name=mtg-env key=MTG_DOMAIN value="google.com"
# Опционально — зафиксировать секрет (иначе генерируется при каждом запуске):
# /container envs add name=mtg-env key=MTG_SECRET value="секрет_из_лога"

# Контейнер
/container add file=mtg-proxy.tar.gz interface=veth-mtg envlist=mtg-env mounts=ssh-key start-on-boot=yes

# DST-NAT (внешний доступ)
/ip firewall nat add chain=dstnat dst-port=443 protocol=tcp in-interface=ether1 action=dst-nat to-addresses=192.168.254.9 to-ports=443
```

### Переменные окружения

| Переменная   | По умолчанию  | Описание                                         |
|--------------|---------------|--------------------------------------------------|
| `SSH_HOST`   | —             | Адрес удалённого сервера (без — mtg работает без туннеля) |
| `SSH_USER`   | `root`        | Пользователь SSH                                 |
| `SSH_PORT`   | `22`          | Порт SSH                                         |
| `SSH_KEY`    | `id_ed25519`  | Имя файла ключа в `/ssh`                        |
| `MTG_PORT`   | `443`         | Порт MTProto Proxy                               |
| `MTG_DOMAIN` | `google.com`  | Домен для маскировки под TLS                     |
| `MTG_SECRET` | —             | Секрет (без — генерируется автоматически)        |

### Получение секрета

При первом запуске секрет выводится в логах контейнера. Зафиксируйте его в переменной `MTG_SECRET`, чтобы он не менялся при перезапуске.

### Подключение Telegram

```
https://t.me/proxy?server=ВАШ_ПУБЛИЧНЫЙ_IP&port=443&secret=СЕКРЕТ_ИЗ_ЛОГА
```

---

## route/ — Прозрачный L3-роутинг через SSH-туннель

Контейнер работает как **прозрачный L3-gateway** для MikroTik. Список доменов в `dst-address-list` → mangle маркирует трафик → routing-rule отправляет на gateway этого контейнера → внутри SOCKS5 поверх SSH-туннеля на удалённый сервер.

Альтернатива SSTP/OpenVPN на роутере — то же самое для приложений в LAN, но менее заметно для DPI: на проводе только обычный SSH-трафик.

### Что внутри

```
LAN-клиент → MikroTik (mangle mark) → routing → veth-route → kernel forward → tun0
                                                                              ↓
                                              hev-socks5-tunnel читает с tun0,
                                              переоткрывает через SOCKS5
                                                                              ↓
                                              ssh -N -D 127.0.0.1:1080 → SSH-сервер
                                                                              ↓
                                                                          интернет
```

- `ssh -N -D 127.0.0.1:1080` — в фоне, c автореконнектом, перебирает список из `SSH_HOSTS` при падении
- `hev-socks5-tunnel` (~330 КБ, C) — терминирует TCP с TUN-устройства, форвардит через локальный SOCKS5
- Policy routing внутри namespace: forwarded трафик → table 100 → `tun0`; собственный SSH-исходящий контейнера остаётся в main table
- `/dev/net/tun` RouterOS создаёт автоматически в namespace — **mount не нужен и противопоказан** (затирает реальное устройство директорией-заглушкой)

**Только TCP.** SSH `-D` не поддерживает UDP ASSOCIATE. QUIC, игры, DNS-over-UDP мимо. Если нужен UDP — отдельный канал (WireGuard, отдельный VPN).

### Полная установка с нуля

#### 1. Подготовка (один раз)

Если ещё не сделал — выполни общие шаги из верхней части README:
- [Архитектура роутера](#архитектура-роутера) (`/system resource print` → `architecture-name`)
- [Подготовка SSH-ключа](#подготовка-ssh-ключа) (`ssh-keygen` локально, публичный ключ на удалённый сервер, приватный в `/ssh/` на роутер)
- [Bridge для контейнеров](#создать-bridge-для-контейнеров-если-ещё-нет)
- [Mount для ключа](#монтирование-ssh-ключа)

Проверь, что ключ читается с твоей машины:
```bash
ssh -i id_ed25519 user@your-server.com "echo ok"
# Должно ответить "ok"
```

#### 2. Сборка образа

Из папки `route/`. Архитектура — `linux/arm64` для большинства современных MikroTik (CRS, hAP ax/ac3, RB5009...). Для x86_64 (CCR2004, RB1100AHx4, x86) — `linux/amd64`.

```bash
cd route
docker buildx build --platform linux/arm64 --provenance=false --sbom=false -t route:latest --load .

# Конвертация OCI → Docker V2
docker volume create imgvol
docker run --rm -v imgvol:/out -v /var/run/docker.sock:/var/run/docker.sock \
  quay.io/skopeo/stable:latest copy \
  docker-daemon:route:latest \
  docker-archive:/out/image.tar:route:latest

# Скопировать и сжать
docker run --rm -v imgvol:/data -v "$(pwd):/host" --entrypoint "" \
  quay.io/skopeo/stable:latest \
  sh -c "cat /data/image.tar | gzip > /host/route.tar.gz"

docker volume rm imgvol
```

На Windows есть готовый PowerShell-скрипт: `route\build.ps1` — делает то же самое.

Получишь `route/route.tar.gz` (~4 МБ).

#### 3. Залить образ на роутер

WinBox → **Files** → drag-n-drop `route.tar.gz`. Или через SFTP/SCP:

```bash
scp route.tar.gz admin@<router-ip>:/
```

#### 4. Создать veth и зарегистрировать env

В терминале RouterOS:

```routeros
# veth — отдельный IP в bridge-сети, не пересекающийся с другими контейнерами
/interface veth add name=veth-route address=192.168.254.10/24 gateway=192.168.254.1
/interface bridge port add bridge=Bridge-Docker interface=veth-route

# Env-переменные
/container envs add name=route-env key=SSH_HOSTS value="ams.example.com:2222,bishkek.example.com"
/container envs add name=route-env key=SSH_USER  value="user1"
/container envs add name=route-env key=SSH_KEY   value="id_ed25519"
# опционально: SSH_PORT (если все хосты на одном нестандартном порту и не указывается в SSH_HOSTS)
# /container envs add name=route-env key=SSH_PORT value="22"
```

Формат `SSH_HOSTS`:
- Один хост: `value="ams.example.com"`
- Один хост на нестандартном порту: `value="ams.example.com:2222"`
- Несколько хостов (фолбэк): `value="ams.example.com:2222,bishkek.example.com,fr.example.com:443"` — без `:port` берётся `SSH_PORT`

#### 5. Создать контейнер

```routeros
/container add file=route.tar.gz interface=veth-route envlist=route-env mounts=ssh-key logging=yes start-on-boot=yes
/container print
# найди номер новой записи и status=stopped

/container start number=<N>
```

**Параметры обязательные:**
- `interface=veth-route` — наш veth
- `envlist=route-env` — env-переменные
- `mounts=ssh-key` — для приватного ключа в `/ssh`
- `logging=yes` — иначе stdout entrypoint'а не попадает в `/log print`

**Параметры противопоказаны:**
- ~~`mounts=tun-dev`~~ — не нужно. RouterOS сам кладёт `/dev/net/tun` в namespace; если попытаешься смонтировать его — получишь директорию-заглушку, и hev не сможет открыть TUN.

#### 6. Проверка запуска

```routeros
/log print where topics~"container"
```

Ожидаемая последовательность:

```
SSH: trying ams.example.com:2222...
Warning: Permanently added 'ams.example.com' (ED25519) to the list of known hosts.
Starting hev-socks5-tunnel...
tun0 is up
input interface detected: veth-route
policy routing ready, waiting on hev-socks5-tunnel...
```

Если `Host is unreachable` на первой попытке — это нормально, контейнерная сеть инициализируется ~3 сек, на ретрае всё встанет.

Если `*** stop` → `Killed` в цикле — что-то падает на старте, скидывай весь вывод от `*** start` до `Killed`.

Если хочешь посмотреть состояние изнутри:

```routeros
/container shell number=<N>
```

```sh
ip link show tun0
#   3: tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 8500 ...

ip rule show
#   300: from all iif veth-route lookup 100

ip route show table 100
#   default dev tun0 scope link
```

#### 7. Настройка маршрутизации на MikroTik

Это **главная часть**. Нужно сказать роутеру, какой трафик заворачивать в наш контейнер.

##### Вариант A: с нуля

Пример — список доменов в `geo-block`, весь маркированный трафик через контейнер:

```routeros
# 1. Address-list с доменами (RouterOS сам резолвит FQDN в IP)
/ip firewall address-list add list=geo-block address=service1.example.com
/ip firewall address-list add list=geo-block address=service2.example.com
# ... добавь все нужные домены

# 2. Mangle: пометить connection-mark, потом routing-mark
/ip firewall mangle add chain=prerouting action=mark-connection \
    new-connection-mark=to_route passthrough=yes \
    dst-address-list=geo-block connection-mark=no-mark in-interface-list=LAN

/ip firewall mangle add chain=prerouting action=mark-routing \
    new-routing-mark=route-mark passthrough=no \
    connection-mark=to_route routing-mark=!route-mark in-interface-list=LAN

# 3. Routing-table и route в ней — ВАЖНО: gateway = IP контейнера + %Bridge-Docker
/routing table add name=route-table fib
/ip route add dst-address=0.0.0.0/0 gateway=192.168.254.10%Bridge-Docker routing-table=route-table
```

##### Вариант B: миграция с SSTP (или OpenVPN) на наш контейнер

Если у тебя уже есть mangle + routing-table, замени только gateway существующего маршрута:

```routeros
# Сначала глянь — какой routing-mark/table используешь
/ip route print where routing-mark~"." or routing-table~"."

# Замени gateway (имя у тебя своё)
/ip route set [find routing-table=<твоя-таблица>] gateway=192.168.254.10%Bridge-Docker

# Проверь статус — должно стать As (Active static)
/ip route print where routing-table=<твоя-таблица>
```

⚠️ **КРИТИЧНО — формат gateway.** Должен быть `IP%Bridge-Docker`, не имя интерфейса (`veth-route`) и не голый IP без scope. С неправильным форматом MikroTik отдаёт пакеты так, что kernel в namespace считает их локальными, а не forwarded — и `curl` молча таймаутит. См. [Troubleshooting](#troubleshooting-routerof-route-).

##### Откат на старый шлюз

```routeros
# Вернёт всё как было — одна команда
/ip route set [find routing-table=<твоя-таблица>] gateway=<твой-старый-шлюз>
```

SSTP-интерфейс/OpenVPN можно не удалять, держать рядом для аварийного отката.

#### 8. Проверка работы

С LAN-клиента, чей трафик попадает под mangle-маркировку:

```bash
# Через туннель (должен вернуть IP активного SSH-сервера, не РФ-IP)
curl https://ifconfig.me

# Не-маркированный домен идёт мимо — контрольный тест
curl https://ip-api.com/json
```

Также можно открыть в браузере любой сайт из address-list и глянуть, что геоопределение показывает страну SSH-сервера.

#### 9. Тест фолбэка (если в SSH_HOSTS несколько серверов)

Временно подмени первый хост на заведомо мёртвый:

```routeros
/container stop number=<N>
/container envs remove [find name=route-env key=SSH_HOSTS]
/container envs add name=route-env key=SSH_HOSTS value="bad.example.com:22,<реальный-сервер-2>"
/container start number=<N>
```

В логе через ~10 сек (`ConnectTimeout`) увидишь:

```
SSH bad.example.com:22 exited, trying next...
SSH: trying <реальный-сервер-2>...
```

`curl https://ifconfig.me` продолжит работать. Восстанови:

```routeros
/container stop number=<N>
/container envs remove [find name=route-env key=SSH_HOSTS]
/container envs add name=route-env key=SSH_HOSTS value="<реальные-серверы>"
/container start number=<N>
```

### Переменные окружения

| Переменная   | По умолчанию      | Описание                                                       |
|--------------|-------------------|----------------------------------------------------------------|
| `SSH_HOSTS`  | —                 | Список серверов через запятую, формат `host[:port]` (обязательная) |
| `SSH_HOST`   | —                 | Совместимость с `socks/`. Если задан, а `SSH_HOSTS` нет — используется как единственный сервер |
| `SSH_USER`   | `root`            | SSH-пользователь (общий для всех серверов)                     |
| `SSH_PORT`   | `22`              | Дефолтный SSH-порт, если в `SSH_HOSTS` порт не указан          |
| `SSH_KEY`    | `id_ed25519`      | Имя файла ключа в `/ssh`                                       |
| `TUN_NAME`   | `tun0`            | Имя TUN-устройства внутри namespace                             |
| `TUN_ADDR`   | `198.18.0.1/30`   | Адрес на tun0 (CGNAT RFC 6815, не пересекается с LAN)          |
| `SOCKS_PORT` | `1080`            | Локальный порт SSH `-D` и upstream для hev-socks5-tunnel        |
| `RETRY_DELAY`| `5`               | Секунды между попытками после полного перебора серверов        |

### Фолбэк при недоступности сервера

`entrypoint.sh` в фоне крутит `for host in $SSH_HOSTS; do ssh -N -D ... $host; done`. При падении `ssh` (любая причина — сетевой таймаут, разрыв keepalive, ConnectTimeout) цикл идёт к следующему серверу. Когда список заканчивается — `sleep RETRY_DELAY`, повтор сначала. Существующие TCP-соединения на момент переключения рвутся (нечего поделать — туннель сменился), новые открываются через активный сервер.

### Troubleshooting route/

#### Контейнер постоянно перезапускается (`*** start` → `Killed` → `*** start` в логе)

Скорее всего что-то падает в entrypoint. Полный лог от `*** start` до `Killed` покажет где. Частые причины:
- `chmod: /ssh/id_ed25519: No such file or directory` — `SSH_KEY` указывает на несуществующий файл в `/ssh`. Проверь имя.
- `SSH_HOSTS (or SSH_HOST) required` — не задана обязательная env-переменная.
- `iptables: not found` / `nft: not found` — это **не блокер**, эти команды убраны из image. Если видишь — у тебя устаревший образ, пересобери.

#### `curl` с тест-клиента таймаутит, в логе всё «policy routing ready»

Внутри контейнера (`/container shell number=<N>`):

```sh
grep -A1 '^Ip:' /proc/net/snmp | head -2
```

Ищи колонку `ForwDatagrams`. Если **0** и не растёт после `curl` — kernel не считает пакеты forward-кандидатами. **На 99% — неправильный gateway** в `/ip route` на MikroTik.

✅ Правильно: `gateway=192.168.254.10%Bridge-Docker`
❌ Неправильно: `gateway=veth-route` (имя интерфейса)
❌ Неправильно: `gateway=192.168.254.10` без scope (может работать, но ARP-резолюция через bridge нестабильна)

Поправь:

```routeros
/ip route set [find routing-table=<твоя-таблица>] gateway=192.168.254.10%Bridge-Docker
/ip route print where routing-table=<твоя-таблица>
# должно быть As (Active static)
```

#### SSH-туннель встал, потом отваливается через 45 секунд по keepalive

В логе:
```
policy routing ready, waiting on hev-socks5-tunnel...
Timeout, server X.X.X.X not responding.
SSH X.X.X.X:22 exited, trying next...
```

Это означает, что наш policy-routing-rule отлавливает и **SSH-ответы**, отправляя их через `tun0` вместо локальной доставки. Проблема ушла в коде (priority 300, после local-table 200), но если ты видишь — у тебя устаревший образ. Пересобери из текущего `entrypoint.sh`.

#### Поток `mangle-prerouting + connection-mark + routing-mark` не работает

Проверь по счётчикам:

```routeros
/ip firewall mangle print stats where new-routing-mark=<твоя-метка>
# смотри столбец BYTES — растёт ли при curl с LAN
```

Если 0:
- Адрес-лист пустой/не резолвится: `/ip firewall address-list print where list=<имя>` — есть ли строки с разрешёнными IP
- Mangle не доходит до этого правила: проверь предыдущие правила, не выпил ли кто-то passthrough

#### Хочу увидеть, какой именно адрес был использован SSH в данный момент

В логе после `policy routing ready` будет последняя строка `SSH: trying <host>:<port>...`, после которой нет ошибок — значит этот сервер активен. Также:

```routeros
/container shell number=<N>
```
```sh
busybox netstat -ant | grep ESTABLISHED
# увидишь Foreign Address — это и есть активный SSH-сервер
```
