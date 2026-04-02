# MikroTik Proxy Containers

Минимальные Docker-контейнеры для MikroTik RouterOS — прокси через SSH-туннель на удалённый сервер.

## Состав

| Контейнер | Описание | Размер |
|-----------|----------|--------|
| [socks/](socks/) | SOCKS5-прокси (SSH -D), опционально с авторизацией через 3proxy | ~3.5 МБ |
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

SOCKS5-прокси через SSH-туннель. Два режима работы:

- **Без авторизации** — чистый SSH `-D` (совместим с Telegram, curl, браузерами)
- **С авторизацией** — 3proxy + SSH-туннель (логин/пароль, для curl/браузеров; Telegram не поддерживается из-за ограничений 3proxy)

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
# Опционально — включить авторизацию:
# /container envs add name=socks-env key=SOCKS_USER value="myuser"
# /container envs add name=socks-env key=SOCKS_PASS value="mypassword"

# Контейнер
/container add file=socks-tunnel.tar.gz interface=veth-socks envlist=socks-env mounts=ssh-key start-on-boot=yes

# DST-NAT (локальная сеть)
/ip firewall nat add chain=dstnat dst-port=1080 protocol=tcp src-address=192.168.88.0/24 action=dst-nat to-addresses=192.168.254.8 to-ports=1080

# DST-NAT (внешний доступ)
/ip firewall nat add chain=dstnat dst-port=1080 protocol=tcp in-interface=ether1 action=dst-nat to-addresses=192.168.254.8 to-ports=1080
```

### Переменные окружения

| Переменная   | По умолчанию  | Описание                              |
|--------------|---------------|---------------------------------------|
| `SSH_HOST`   | —             | Адрес удалённого сервера              |
| `SSH_USER`   | `root`        | Пользователь SSH                      |
| `SSH_PORT`   | `22`          | Порт SSH                              |
| `SOCKS_PORT` | `1080`        | Порт SOCKS-прокси                     |
| `SSH_KEY`    | `id_ed25519`  | Имя файла ключа в `/ssh`             |
| `SOCKS_USER` | —             | Логин SOCKS5 (без — auth отключён)   |
| `SOCKS_PASS` | —             | Пароль SOCKS5                         |

### Проверка

```bash
# Без авторизации
curl -x socks5://192.168.88.1:1080 https://ifconfig.me

# С авторизацией
curl -x socks5://myuser:mypassword@192.168.88.1:1080 https://ifconfig.me
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
