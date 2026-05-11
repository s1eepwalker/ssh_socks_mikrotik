# MikroTik Proxy Containers

Минимальные Docker-контейнеры для MikroTik RouterOS — прокси через SSH-туннель на удалённый сервер.

## Состав

| Контейнер | Описание | Размер |
|-----------|----------|--------|
| [sshgate/](sshgate/) | Объединённый: L3-gateway + опциональный SOCKS5/HTTP-листенер, общий SSH-туннель с фолбэком | ~4.5 МБ |
| [mtg/](mtg/) | MTProto Proxy для Telegram, маскировка под TLS для обхода DPI | ~8 МБ |
| [socks/](socks/) | **Deprecated** — заменён `sshgate/`. SOCKS5-прокси (SSH -D), опционально с авторизацией через 3proxy | ~3.5 МБ |
| [route/](route/) | **Deprecated** — заменён `sshgate/`. Прозрачный L3-gateway: маркированный TCP MikroTik → SOCKS5 → SSH-туннель с фолбэком | ~4 МБ |

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

#### 1. Сгенерировать пару ключей (на твоей машине)

```bash
ssh-keygen -t ed25519 -f id_ed25519 -N ""
```

#### 2. Публичный — на удалённый сервер

`id_ed25519.pub` добавить в `~/.ssh/authorized_keys` пользователя, чьё имя пойдёт в env `SSH_USER` контейнера.

Проверь с PC, что приватный ключ принят:
```bash
ssh -i id_ed25519 user@your-server.com "echo ok"
```

#### 3. Создать mount на MikroTik (один раз, общий для всех контейнеров)

```routeros
/container mounts add name=ssh-key src=/ssh dst=/ssh
```

Это создаст «приватную» директорию `/ssh/` в файловой системе RouterOS, которую будут монтировать контейнеры.

#### 4. Загрузить приватный ключ в /ssh/

Несколько способов, выбери удобный:

- **WinBox Files (drag-n-drop):**
  - Открой панель **Files** в WinBox
  - Перетащи `id_ed25519` в строку с папкой `ssh` (тип `container-store`)
  - Подсказка: проще, **пока ни один контейнер с `mounts=ssh-key` ещё не запущен** — иначе папка станет «невидимой» (см. подводный камень ниже)

- **SCP** с PC (если включён SSH-сервис на роутере, по умолчанию):
  ```bash
  scp -O id_ed25519 admin@<router-ip>:/ssh/
  # -O форсит legacy SCP-протокол, RouterOS-сервер ждёт именно его
  ```

- **`/tool fetch`** через временный HTTP-сервер:
  ```bash
  # На PC, в директории с ключом
  python -m http.server 8080
  # или: npx http-server -p 8080
  ```
  ```routeros
  /tool fetch url="http://<your-pc-ip>:8080/id_ed25519" dst-path=/ssh/id_ed25519
  ```

- **FTP** (если `/ip service print` показывает ftp enabled):
  ```bash
  ftp <router-ip>
  ftp> binary
  ftp> cd ssh
  ftp> put id_ed25519
  ```

#### 5. ⚠️ Подводный камень: WinBox прячет содержимое /ssh/

После того как любой контейнер с `mounts=ssh-key` стартанул хотя бы раз, RouterOS помечает `/ssh/` как «приватную для контейнеров» — её содержимое **перестаёт отображаться** в `/file print` и WinBox Files, и остановка контейнеров уже **не возвращает** видимость. Файл не пропал, контейнеры его читают, просто из админ-панели его не видно.

**Это только проблема отображения** — SCP, `/tool fetch` и FTP продолжают писать в `/ssh/` нормально, даже когда контейнеры запущены. То есть для замены/добавления ключей **WinBox не нужен** вообще; пользуйся `/tool fetch` или scp из пункта 4.

**Подтвердить, что ключ на месте** — через shell любого работающего контейнера с этим mount:

```routeros
/container shell number=<N>
```
```sh
ls -la /ssh/
cat /ssh/id_ed25519 | head -1
# Должен показать "-----BEGIN OPENSSH PRIVATE KEY-----"
```

**Заменить ключ позже** (без оглядки на Files):
1. Залить новый файл через scp/fetch (см. пункт 4) — пишется в `/ssh/` независимо от WinBox-видимости
2. Если контейнер уже запущен и читает старый ключ — `/container stop` + `/container start` чтобы он подхватил новый

### Создать bridge для контейнеров (если ещё нет)

```routeros
/interface bridge add name=Bridge-Docker
/ip address add address=192.168.254.1/24 interface=Bridge-Docker
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

## sshgate/ — SSH-туннель: L3-роутинг + SOCKS5/HTTP-прокси

Один контейнер, объединяющий роли `socks/` (application-level SOCKS5/HTTP) и `route/` (transparent L3-gateway). Общий SSH-туннель с фолбэком обслуживает обе роли.

### Что внутри

```
LAN-клиент (mangle mark)──veth──┐
                                ├──→ hev-socks5-tunnel (всегда)
                                │       ↓
External SOCKS5/HTTP client  ───┤    127.0.0.1:10800 ← ssh -N -D
                                │       ↑
                                └──→ 3proxy (если SOCKS_PORT)
                                        ↑
                                  Любой LAN/WAN клиент
```

- **L3-роль активна всегда** — `hev-socks5-tunnel` слушает `tun0`, kernel форвардит туда маркированный трафик от MikroTik. Без mangle-rule на роутере просто idle.
- **App-listener — opt-in через `SOCKS_PORT`** — `3proxy` слушает на нём (`auth none` или с креденшелами). Опционально HTTP через `HTTP_PORT`.
- Обе роли используют один `ssh -N -D 127.0.0.1:$SOCKS_BACKEND_PORT` как SOCKS5-upstream.
- **TCP-only.** SSH `-D` UDP не поддерживает.

### Полная установка

#### 1. Подготовка (общие шаги)

Сделай один раз, если ещё нет: [архитектура роутера](#архитектура-роутера), [SSH-ключ](#подготовка-ssh-ключа), [Bridge для контейнеров](#создать-bridge-для-контейнеров-если-ещё-нет), [Mount для ключа](#монтирование-ssh-ключа).

#### 2. Сборка образа

```bash
cd sshgate
docker buildx build --platform linux/arm64 --provenance=false --sbom=false -t sshgate:latest --load .

docker volume create imgvol
docker run --rm -v imgvol:/out -v /var/run/docker.sock:/var/run/docker.sock \
  quay.io/skopeo/stable:latest copy \
  docker-daemon:sshgate:latest \
  docker-archive:/out/image.tar:sshgate:latest

docker run --rm -v imgvol:/data -v "$(pwd):/host" --entrypoint "" \
  quay.io/skopeo/stable:latest \
  sh -c "cat /data/image.tar | gzip > /host/sshgate.tar.gz"

docker volume rm imgvol
```

На Windows есть `sshgate\build.ps1`.

#### 3. Залить на роутер

WinBox Files / SFTP / `scp`.

#### 4. veth и env

```routeros
/interface veth add name=veth-sshgate address=192.168.254.11/24 gateway=192.168.254.1
/interface bridge port add bridge=Bridge-Docker interface=veth-sshgate

# Минимум для L3-роли
/container envs add name=sshgate-env key=SSH_HOSTS value="ams.example.com:2222,bishkek.example.com"
/container envs add name=sshgate-env key=SSH_USER  value="user1"
/container envs add name=sshgate-env key=SSH_KEY   value="id_ed25519"

# Опционально — включить SOCKS5/HTTP листенер
# /container envs add name=sshgate-env key=SOCKS_PORT value="1080"
# /container envs add name=sshgate-env key=SOCKS_USER value="myuser"   # включит auth
# /container envs add name=sshgate-env key=SOCKS_PASS value="mypassword"
# /container envs add name=sshgate-env key=HTTP_PORT  value="3128"      # требует SOCKS_PORT
```

#### 5. Контейнер

```routeros
/container add file=sshgate.tar.gz interface=veth-sshgate envlist=sshgate-env mounts=ssh-key logging=yes start-on-boot=yes
/container print
/container start number=<N>
```

Важно: **никакого `mounts=tun-dev`** — RouterOS сам кладёт `/dev/net/tun` в namespace.

#### 6. L3-роль: routing-rule на gateway контейнера

```routeros
# КРИТИЧНО — формат gateway: IP%Bridge-Docker
/ip route add dst-address=0.0.0.0/0 gateway=192.168.254.11%Bridge-Docker routing-table=<твоя-таблица>
```

⚠️ Использовать `gateway=192.168.254.11%Bridge-Docker`, не имя интерфейса (`veth-sshgate`) и не голый IP без scope. См. Troubleshooting ниже.

#### 7. App-listener: dst-nat (опционально)

```routeros
# Доступ из LAN
/ip firewall nat add chain=dstnat dst-port=1080 protocol=tcp src-address=192.168.88.0/24 action=dst-nat to-addresses=192.168.254.11 to-ports=1080

# Доступ из интернета (если хочешь)
/ip firewall nat add chain=dstnat dst-port=1080 protocol=tcp in-interface=ether1 action=dst-nat to-addresses=192.168.254.11 to-ports=1080

# Если задан HTTP_PORT, симметрично для 3128
```

#### 8. Проверка

В логе (`/log print where topics~"container"`) ожидаем:
```
SSH: trying ...
Warning: Permanently added ...
Starting hev-socks5-tunnel...
tun0 is up
input interface detected: veth-sshgate
3proxy listening: SOCKS=1080, auth=none   (если SOCKS_PORT задан)
sshgate ready (route=on, listener=1080)
```

С LAN-клиента под mangle-маркировкой:
```bash
curl https://ifconfig.me               # → IP активного SSH-сервера, не РФ
```

С любого клиента через listener (если включён):
```bash
curl -x socks5://<router-ip>:1080 https://ifconfig.me
# или с auth:
curl -x socks5://u:p@<router-ip>:1080 https://ifconfig.me
# HTTP:
curl -x http://u:p@<router-ip>:3128 https://ifconfig.me
```

### Переменные окружения

| Переменная | По умолчанию | Описание |
|---|---|---|
| **SSH-туннель** | | |
| `SSH_HOSTS` | — (обязательная) | Список серверов через запятую, формат `host[:port]`. Пример: `ams.example.com:2222,bishkek.example.com` |
| `SSH_HOST` | — | Совместимость с `socks/`. Если задан, а `SSH_HOSTS` нет — используется как единственный сервер |
| `SSH_USER` | `root` | SSH-пользователь (один для всех серверов) |
| `SSH_PORT` | `22` | Дефолтный порт, если в `SSH_HOSTS` явно не указан |
| `SSH_KEY` | `id_ed25519` | Имя файла ключа в `/ssh` |
| `RETRY_DELAY` | `5` | Пауза в секундах после полного перебора серверов |
| `SOCKS_BACKEND_PORT` | `10800` | Локальный 127.0.0.1 порт SSH `-D` (внутренний) |
| **L3-роль (всегда активна)** | | |
| `TUN_NAME` | `tun0` | Имя TUN-устройства внутри namespace |
| `TUN_ADDR` | `198.18.0.1/30` | Адрес на tun0 (CGNAT RFC 6815) |
| **App-listener (opt-in)** | | |
| `SOCKS_PORT` | — | Внешний порт SOCKS5. Если задан → 3proxy слушает. Без — листенер не запускается. |
| `HTTP_PORT` | — | Внешний порт HTTP. Требует `SOCKS_PORT`. |
| `SOCKS_USER` | — | Логин для auth. Без — `auth none` (Telegram-совместимо). |
| `SOCKS_PASS` | — | Пароль (требует `SOCKS_USER`). |

### Миграция со старых контейнеров

| С чего | Что менять |
|---|---|
| `socks/` без auth | `SSH_HOST` → `SSH_HOSTS` (одно значение OK). `SOCKS_PORT` оставить — получишь 3proxy без auth. |
| `socks/` с auth | `SSH_HOST` → `SSH_HOSTS`. Остальное (`SOCKS_USER`, `SOCKS_PASS`, опц. `HTTP_PORT`) без изменений. |
| `route/` (только L3) | **Убрать `SOCKS_PORT` env.** В sshgate `SOCKS_PORT` означает внешний листенер. Внутренний порт переименован в `SOCKS_BACKEND_PORT` (дефолт `10800`). |

### Troubleshooting sshgate/

**Контейнер перезапускается в цикле (`*** start` → `Killed`):**
- Полный лог от `*** start` до `Killed` покажет, где упало
- `SSH_HOSTS (or SSH_HOST) required` — не задана обязательная env
- `HTTP_PORT requires SOCKS_PORT` — задан HTTP_PORT без SOCKS_PORT
- `SOCKS_PASS requires SOCKS_USER` — задан пароль без логина

**`curl` через L3-роль таймаутит, в логе всё «sshgate ready»:**
- Внутри контейнера (`/container shell number=<N>`):
  ```sh
  grep -A1 '^Ip:' /proc/net/snmp | head -2
  ```
  Колонка `ForwDatagrams` остаётся 0 после curl — kernel не форвардит. На 99% — **gateway в `/ip route` указан неправильно**:
  - ✅ `gateway=192.168.254.11%Bridge-Docker`
  - ❌ `gateway=veth-sshgate` (имя интерфейса)
  - ❌ `gateway=192.168.254.11` (без scope — ARP-резолюция нестабильна через bridge)

  Фикс: `/ip route set [find routing-table=<твоя-таблица>] gateway=192.168.254.11%Bridge-Docker`

**`curl -x socks5://...` через listener не работает:**
- Проверь dst-nat правило (см. шаг 7)
- В контейнере: `busybox netstat -lnt` должен показывать `0.0.0.0:1080` (порт SOCKS_PORT) и `127.0.0.1:10800` (backend)
- Если SOCKS_USER задан — без пароля будет `407` или connection refused, это нормально

**Какой SSH-сервер сейчас активен:**
- В логе ищи последнюю строку `SSH: trying ...` без ошибки после неё
- Или внутри: `busybox netstat -ant | grep ESTABLISHED` → колонка Foreign Address

---

## socks/ — SOCKS5 Proxy

> **⚠️ DEPRECATED.** Этот контейнер заменён `sshgate/` (см. соответствующую секцию выше), который объединяет роли `socks/` и `route/` в одном образе с общим SSH-туннелем. Для новых деплоев используй `sshgate/`. Старый `socks/` оставлен для обратной совместимости.

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

> **⚠️ DEPRECATED.** Этот контейнер заменён `sshgate/` (см. соответствующую секцию выше), который добавляет к нему ещё и опциональный SOCKS5/HTTP-листенер на том же SSH-туннеле. Для новых деплоев используй `sshgate/`. Старый `route/` оставлен для обратной совместимости.

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
