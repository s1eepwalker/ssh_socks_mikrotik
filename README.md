# socks-tunnel

Минимальный Docker-контейнер для MikroTik RouterOS — SOCKS5-прокси через SSH-туннель.

- scratch + openssh-client + busybox (~3.4 МБ сжатый)
- Автоматическое переподключение при обрыве
- Детекция зависших соединений через SSH keepalive

## Сборка

```bash
# arm64 (hAP ax³, RB5009, ...)
docker buildx build --platform linux/arm64 --provenance=false --sbom=false -t socks-tunnel:latest --load .

# amd64 (CHR, x86)
docker buildx build --platform linux/amd64 --provenance=false --sbom=false -t socks-tunnel:latest --load .
```

### Конвертация в Docker V2 формат

Новые версии Docker Desktop сохраняют образы в OCI-формате, который MikroTik не понимает.
Нужно сконвертировать через `skopeo`:

```bash
# Конвертировать OCI → Docker V2
docker volume create imgvol
docker run --rm -v imgvol:/out -v /var/run/docker.sock:/var/run/docker.sock \
  quay.io/skopeo/stable:latest copy \
  docker-daemon:socks-tunnel:latest \
  docker-archive:/out/socks-tunnel.tar:socks-tunnel:latest

# Скопировать и сжать
docker run --rm -v imgvol:/data -v "$(pwd):/host" --entrypoint "" \
  quay.io/skopeo/stable:latest \
  sh -c "cat /data/socks-tunnel.tar | gzip > /host/socks-tunnel.tar.gz"

# Очистка
docker volume rm imgvol
```

Архитектуру роутера можно узнать:

```routeros
/system resource print
```

Смотреть поле `architecture-name`.

## Подготовка SSH-ключа

На своей машине:

```bash
ssh-keygen -t ed25519 -f id_ed25519 -N ""
```

Публичный ключ (`id_ed25519.pub`) добавить в `~/.ssh/authorized_keys` на удалённом сервере.

Приватный ключ (`id_ed25519`) загрузить на MikroTik в `/ssh/id_ed25519` (через WinBox или SCP).

## Настройка на MikroTik

### 1. Создать bridge для контейнеров (если ещё нет)

```routeros
/interface bridge add name=Bridge-Docker
/ip address add address=192.168.254.1/24 interface=Bridge-Docker
```

### 2. Загрузить образ

Загрузить `socks-tunnel.tar.gz` на роутер через WinBox (drag-and-drop в Files) или SCP:

```bash
scp socks-tunnel.tar.gz admin@192.168.88.1:/
```

### 3. Создать veth-интерфейс

```routeros
/interface veth add name=veth-socks address=192.168.254.8/24 gateway=192.168.254.1
/interface bridge port add bridge=Bridge-Docker interface=veth-socks
```

### 4. Переменные окружения

```routeros
/container envs add name=socks-env key=SSH_HOST value="1.2.3.4"
/container envs add name=socks-env key=SSH_USER value="user1"
/container envs add name=socks-env key=SSH_PORT value="22"
/container envs add name=socks-env key=SOCKS_PORT value="1080"
/container envs add name=socks-env key=SSH_KEY value="id_ed25519"
/container envs add name=socks-env key=SOCKS_USER value="myuser"
/container envs add name=socks-env key=SOCKS_PASS value="mypassword"
```

### 5. Монтирование SSH-ключа

```routeros
/container mounts add name=ssh-key src=/ssh dst=/ssh
```

### 6. Создать и запустить контейнер

```routeros
/container add file=socks-tunnel.tar.gz interface=veth-socks envlist=socks-env mounts=ssh-key start-on-boot=yes
/container start 0
```

### 7. Проброс порта — локальная сеть (DST-NAT)

Чтобы клиенты из LAN могли использовать прокси через IP роутера:

```routeros
/ip firewall nat add chain=dstnat dst-port=1080 protocol=tcp src-address=192.168.88.0/24 action=dst-nat to-addresses=192.168.254.8 to-ports=1080
```

### 8. Проброс порта — доступ извне по белому IP

Чтобы внешние клиенты могли подключаться к прокси через публичный IP роутера:

```routeros
/ip firewall nat add chain=dstnat dst-port=1080 protocol=tcp in-interface=ether1 action=dst-nat to-addresses=192.168.254.8 to-ports=1080
```

> `ether1` — WAN-интерфейс роутера. Замените на свой, если отличается.

**Важно:** SOCKS5 без аутентификации — любой, кто знает ваш IP, сможет им пользоваться. Рекомендуется ограничить доступ по IP:

```routeros
/ip firewall filter add chain=forward dst-port=1080 protocol=tcp in-interface=ether1 src-address-list=socks-allowed action=accept
/ip firewall filter add chain=forward dst-port=1080 protocol=tcp in-interface=ether1 action=drop

# Добавить разрешённые IP:
/ip firewall address-list add list=socks-allowed address=203.0.113.10
/ip firewall address-list add list=socks-allowed address=198.51.100.0/24
```

## Использование

В браузере или системных настройках указать SOCKS5-прокси:

```
Хост: 192.168.88.1 (IP роутера) или публичный IP
Порт: 1080
Тип:  SOCKS5
```

## Переменные окружения

| Переменная   | По умолчанию | Описание                 |
|--------------|-------------|--------------------------|
| `SSH_HOST`   | —           | Адрес удалённого сервера |
| `SSH_USER`   | `root`      | Пользователь SSH         |
| `SSH_PORT`   | `22`        | Порт SSH                 |
| `SOCKS_PORT` | `1080`      | Порт SOCKS-прокси        |
| `SSH_KEY`    | `id_ed25519`| Имя файла ключа в `/ssh` |
| `SOCKS_USER` | —           | Логин SOCKS5 (без — auth отключён) |
| `SOCKS_PASS` | —           | Пароль SOCKS5             |

## Проверка работы

Логи контейнера:

```routeros
/container shell 0
```

Проверить прокси с любой машины в сети (без авторизации):

```bash
curl -x socks5://192.168.88.1:1080 https://ifconfig.me
```

С авторизацией:

```bash
curl -x socks5://user_login:user_passw@192.168.88.1:1080 https://ifconfig.me
```

Должен показать IP удалённого сервера.
