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

L3-gateway для MikroTik. Маркированный по `dst-address-list` TCP-трафик заворачивается в SOCKS5 поверх SSH-туннеля на удалённый сервер. Поддерживает список SSH-серверов с автоматическим фолбэком при падении активного.

Внутри:
- `ssh -N -D 127.0.0.1:1080` (в фоне, с реконнектом и перебором серверов из `SSH_HOSTS`)
- `hev-socks5-tunnel` (~330KB) — терминирует TCP с TUN-устройства и форвардит через локальный SOCKS5
- Policy routing внутри namespace: forwarded трафик → `tun0`; собственный SSH-исходящий → main table

**Только TCP.** SSH `-D` не поддерживает UDP. Для UDP-сценариев (QUIC, игры) нужен отдельный канал.

### Настройка на MikroTik

```routeros
# veth (адрес не должен пересекаться с другими контейнерами)
/interface veth add name=veth-route address=192.168.254.10/24 gateway=192.168.254.1
/interface bridge port add bridge=Bridge-Docker interface=veth-route

# Переменные окружения
/container envs add name=route-env key=SSH_HOSTS value="ams.example.com:2222,bishkek.example.com"
/container envs add name=route-env key=SSH_USER value="user1"
/container envs add name=route-env key=SSH_KEY value="id_ed25519"
# опционально: SSH_PORT, SOCKS_PORT, TUN_ADDR, RETRY_DELAY

# Контейнер — ВАЖНО: /dev/net/tun mount НЕ нужен, RouterOS создаёт его сам
/container add file=route.tar.gz interface=veth-route envlist=route-env mounts=ssh-key logging=yes start-on-boot=yes

# Routing: точка переключения с SSTP (или любого старого шлюза) на наш контейнер
# Если у тебя уже есть routing-rule для маркированного трафика — поменяй gateway:
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
