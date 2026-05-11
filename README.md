# MikroTik Proxy Containers

Минимальные Docker-контейнеры для MikroTik RouterOS — прокси через SSH-туннель на удалённый сервер.

## Состав

| Контейнер | Описание | Размер |
|-----------|----------|--------|
| [sshgate/](sshgate/) | L3-gateway + опциональный SOCKS5/HTTP-листенер, общий SSH-туннель с фолбэком | ~4.5 МБ |
| [mtg/](mtg/) | MTProto Proxy для Telegram, маскировка под TLS для обхода DPI | ~8 МБ |

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

- **WinBox Files drag-n-drop + переименование в подкаталог** (самый простой):
  1. Перетащи `id_ed25519` в Files-панель — файл попадёт в корень
  2. В терминале RouterOS «переедь» файл в `ssh/` сменой имени:
     ```routeros
     /file set [find name="id_ed25519"] name="ssh/id_ed25519"
     ```
     RouterOS трактует slash в имени как «подкаталог».
  3. Альтернатива — в WinBox правой-кнопкой на файле → **Rename** → поменять имя с `id_ed25519` на `ssh/id_ed25519`.

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
/container envs add list=sshgate-env key=SSH_HOSTS value="ams.example.com:2222,bishkek.example.com"
/container envs add list=sshgate-env key=SSH_USER  value="user1"
/container envs add list=sshgate-env key=SSH_KEY   value="id_ed25519"

# Опционально — включить SOCKS5/HTTP листенер
# /container envs add list=sshgate-env key=SOCKS_PORT value="1080"
# /container envs add list=sshgate-env key=SOCKS_USER value="myuser"   # включит auth
# /container envs add list=sshgate-env key=SOCKS_PASS value="mypassword"
# /container envs add list=sshgate-env key=HTTP_PORT  value="3128"      # требует SOCKS_PORT
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

## mtg/ — MTProto Proxy для Telegram

MTProto Proxy с маскировкой под TLS для обхода DPI. Трафик к Telegram DC идёт через SSH-туннель на удалённый сервер.

### Настройка на MikroTik

```routeros
# veth
/interface veth add name=veth-mtg address=192.168.254.9/24 gateway=192.168.254.1
/interface bridge port add bridge=Bridge-Docker interface=veth-mtg

# Переменные окружения
/container envs add list=mtg-env key=SSH_HOST value="1.2.3.4"
/container envs add list=mtg-env key=SSH_USER value="user1"
/container envs add list=mtg-env key=SSH_PORT value="22"
/container envs add list=mtg-env key=SSH_KEY value="id_ed25519"
/container envs add list=mtg-env key=MTG_PORT value="443"
/container envs add list=mtg-env key=MTG_DOMAIN value="google.com"
# Опционально — зафиксировать секрет (иначе генерируется при каждом запуске):
# /container envs add list=mtg-env key=MTG_SECRET value="секрет_из_лога"

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
