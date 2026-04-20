# SOCKS+HTTP Auth в socks/ — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Расширить `socks/` контейнер, чтобы в auth-режиме 3proxy мог одновременно обслуживать SOCKS5 и HTTP с общими кредами, гейтится новой env `HTTP_PORT`.

**Architecture:** Минимальное изменение `socks/entrypoint.sh` — в auth-ветке дописывается строка `proxy -p${HTTP_PORT} -i0.0.0.0` в генерируемый конфиг 3proxy, когда `HTTP_PORT` задана. Dockerfile, зависимости, размер образа — без изменений. Документация (README, CLAUDE.md) синхронизируется.

**Tech Stack:** 3proxy (уже в образе), busybox sh, Alpine build stage, Docker/skopeo для сборки под MikroTik arm64/amd64.

**Testing notes:** В репозитории нет CI и тестов — валидация ручная через `curl` на собранном образе. План содержит шаги сборки/деплоя, но физический деплой на роутер пользователь делает сам после финального коммита.

**Spec:** `docs/superpowers/specs/2026-04-20-socks-http-auth-design.md`

---

## File Structure

- **Modify:** `socks/entrypoint.sh` — добавить опциональный HTTP-листенер и обновить стартовое сообщение.
- **Modify:** `README.md` — таблица env, RouterOS-примеры, DST-NAT, раздел «Проверка», вводное описание режимов.
- **Modify:** `CLAUDE.md` — обновить описание `socks/` в секции «Обзор».

Новых файлов нет. Dockerfile не трогаем.

---

## Task 1: Обновить socks/entrypoint.sh

**Files:**
- Modify: `socks/entrypoint.sh:36-48` (блок генерации конфига и стартового echo в auth-ветке)

- [ ] **Step 1.1: Заменить блок генерации конфига и стартового echo**

В текущем файле строки 35–48 содержат heredoc `cat > ${CFG}` и `echo "$(date) Starting 3proxy..."` + `exec 3proxy ${CFG}`. Заменить так, чтобы после heredoc опционально дописывался HTTP-листенер и стартовое сообщение отражало активные листенеры.

Найти в `socks/entrypoint.sh`:

```sh
  # Конфиг 3proxy
  CFG=/tmp/3proxy.cfg
  cat > ${CFG} <<EOF
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /dev/stderr
users ${SOCKS_USER}:CL:${SOCKS_PASS}
auth strong
allow ${SOCKS_USER}
parent 1000 socks5 127.0.0.1 ${SSH_TUNNEL_PORT}
socks -p${PROXY_PORT} -i0.0.0.0
EOF

  echo "$(date) Starting 3proxy on port ${PROXY_PORT} (auth: ${SOCKS_USER})..."
  exec 3proxy ${CFG}
```

Заменить на:

```sh
  # Конфиг 3proxy
  CFG=/tmp/3proxy.cfg
  cat > ${CFG} <<EOF
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /dev/stderr
users ${SOCKS_USER}:CL:${SOCKS_PASS}
auth strong
allow ${SOCKS_USER}
parent 1000 socks5 127.0.0.1 ${SSH_TUNNEL_PORT}
socks -p${PROXY_PORT} -i0.0.0.0
EOF

  if [ -n "${HTTP_PORT}" ]; then
    echo "parent 1000 socks5 127.0.0.1 ${SSH_TUNNEL_PORT}" >> ${CFG}
    echo "proxy -p${HTTP_PORT} -i0.0.0.0" >> ${CFG}
    echo "$(date) Starting 3proxy: SOCKS=${PROXY_PORT}, HTTP=${HTTP_PORT} (auth: ${SOCKS_USER})..."
  else
    echo "$(date) Starting 3proxy: SOCKS=${PROXY_PORT} (auth: ${SOCKS_USER})..."
  fi
  exec 3proxy ${CFG}
```

**Примечание по `parent`:** директива 3proxy применяется только к ближайшему последующему листенеру, поэтому перед HTTP-листенером строка `parent` дублируется явно — это гарантирует, что HTTP-трафик тоже пойдёт через SSH-туннель, независимо от внутреннего поведения 3proxy.

- [ ] **Step 1.2: Проверить синтаксис шелл-скрипта**

Run: `sh -n socks/entrypoint.sh`
Expected: нет вывода, exit code 0.

- [ ] **Step 1.3: Коммит**

```bash
git add socks/entrypoint.sh
git commit -m "Add optional HTTP proxy listener to socks auth mode"
```

---

## Task 2: Обновить README.md — секция socks/

**Files:**
- Modify: `README.md:77-131` (секция `## socks/ — SOCKS5 Proxy`)

- [ ] **Step 2.1: Обновить вводное описание режимов**

Найти в `README.md` (около строки 79):

```markdown
SOCKS5-прокси через SSH-туннель. Два режима работы:

- **Без авторизации** — чистый SSH `-D` (совместим с Telegram, curl, браузерами)
- **С авторизацией** — 3proxy + SSH-туннель (логин/пароль, для curl/браузеров; Telegram не поддерживается из-за ограничений 3proxy)
```

Заменить на:

```markdown
SOCKS5- и HTTP-прокси через SSH-туннель. Три режима работы:

- **Без авторизации** — чистый SSH `-D`, только SOCKS5 (совместим с Telegram, curl, браузерами)
- **SOCKS с авторизацией** — 3proxy + SSH-туннель, SOCKS5 с логином/паролем (Telegram не поддерживается из-за ограничений 3proxy)
- **SOCKS + HTTP с авторизацией** — то же, плюс HTTP-прокси на отдельном порту с теми же кредами (задаётся переменной `HTTP_PORT`)
```

- [ ] **Step 2.2: Добавить пример env для HTTP_PORT в блок RouterOS**

Найти в `README.md` (секция socks/, подсекция «Настройка на MikroTik»):

```routeros
# Опционально — включить авторизацию:
# /container envs add name=socks-env key=SOCKS_USER value="myuser"
# /container envs add name=socks-env key=SOCKS_PASS value="mypassword"
```

Заменить на:

```routeros
# Опционально — включить авторизацию (SOCKS):
# /container envs add name=socks-env key=SOCKS_USER value="myuser"
# /container envs add name=socks-env key=SOCKS_PASS value="mypassword"
# Опционально — включить HTTP-прокси (требует SOCKS_USER/SOCKS_PASS):
# /container envs add name=socks-env key=HTTP_PORT value="3128"
```

- [ ] **Step 2.3: Добавить DST-NAT правила для HTTP в блок RouterOS**

Найти в `README.md` (конец блока RouterOS секции socks/):

```routeros
# DST-NAT (локальная сеть)
/ip firewall nat add chain=dstnat dst-port=1080 protocol=tcp src-address=192.168.88.0/24 action=dst-nat to-addresses=192.168.254.8 to-ports=1080

# DST-NAT (внешний доступ)
/ip firewall nat add chain=dstnat dst-port=1080 protocol=tcp in-interface=ether1 action=dst-nat to-addresses=192.168.254.8 to-ports=1080
```

Заменить на:

```routeros
# DST-NAT SOCKS (локальная сеть)
/ip firewall nat add chain=dstnat dst-port=1080 protocol=tcp src-address=192.168.88.0/24 action=dst-nat to-addresses=192.168.254.8 to-ports=1080

# DST-NAT SOCKS (внешний доступ)
/ip firewall nat add chain=dstnat dst-port=1080 protocol=tcp in-interface=ether1 action=dst-nat to-addresses=192.168.254.8 to-ports=1080

# DST-NAT HTTP (локальная сеть) — если задан HTTP_PORT
# /ip firewall nat add chain=dstnat dst-port=3128 protocol=tcp src-address=192.168.88.0/24 action=dst-nat to-addresses=192.168.254.8 to-ports=3128

# DST-NAT HTTP (внешний доступ) — если задан HTTP_PORT
# /ip firewall nat add chain=dstnat dst-port=3128 protocol=tcp in-interface=ether1 action=dst-nat to-addresses=192.168.254.8 to-ports=3128
```

- [ ] **Step 2.4: Добавить HTTP_PORT в таблицу env-переменных**

Найти в `README.md` таблицу env для socks/:

```markdown
| Переменная   | По умолчанию  | Описание                              |
|--------------|---------------|---------------------------------------|
| `SSH_HOST`   | —             | Адрес удалённого сервера              |
| `SSH_USER`   | `root`        | Пользователь SSH                      |
| `SSH_PORT`   | `22`          | Порт SSH                              |
| `SOCKS_PORT` | `1080`        | Порт SOCKS-прокси                     |
| `SSH_KEY`    | `id_ed25519`  | Имя файла ключа в `/ssh`             |
| `SOCKS_USER` | —             | Логин SOCKS5 (без — auth отключён)   |
| `SOCKS_PASS` | —             | Пароль SOCKS5                         |
```

Заменить на:

```markdown
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
```

- [ ] **Step 2.5: Обновить секцию «Проверка»**

Найти в `README.md` (секция socks/):

```markdown
### Проверка

```bash
# Без авторизации
curl -x socks5://192.168.88.1:1080 https://ifconfig.me

# С авторизацией
curl -x socks5://myuser:mypassword@192.168.88.1:1080 https://ifconfig.me
```
```

Заменить на:

```markdown
### Проверка

```bash
# SOCKS без авторизации
curl -x socks5://192.168.88.1:1080 https://ifconfig.me

# SOCKS с авторизацией
curl -x socks5://myuser:mypassword@192.168.88.1:1080 https://ifconfig.me

# HTTP с авторизацией (если задан HTTP_PORT)
curl -x http://myuser:mypassword@192.168.88.1:3128 https://ifconfig.me
```
```

- [ ] **Step 2.6: Коммит**

```bash
git add README.md
git commit -m "Document HTTP_PORT and SOCKS+HTTP auth mode in README"
```

---

## Task 3: Обновить CLAUDE.md

**Files:**
- Modify: `CLAUDE.md:9` (одна строка в секции «Обзор»)

- [ ] **Step 3.1: Обновить описание socks/ в CLAUDE.md**

Найти в `CLAUDE.md`:

```markdown
- `socks/` — SOCKS5-прокси через SSH `-D` туннель. Два режима в одном образе: чистый `ssh -D` (без auth) или `3proxy` поверх SSH-туннеля (с логином/паролем). Режим выбирается по наличию `SOCKS_USER`/`SOCKS_PASS` в `entrypoint.sh`.
```

Заменить на:

```markdown
- `socks/` — SOCKS5/HTTP-прокси через SSH `-D` туннель. Три режима в одном образе: чистый `ssh -D` (SOCKS без auth), `3proxy` поверх SSH-туннеля (SOCKS с логином/паролем) и тот же `3proxy` с дополнительным HTTP-листенером при заданной `HTTP_PORT` (общие креды для обоих протоколов). Режим выбирается по наличию `SOCKS_USER`/`SOCKS_PASS` и `HTTP_PORT` в `entrypoint.sh`.
```

- [ ] **Step 3.2: Коммит**

```bash
git add CLAUDE.md
git commit -m "Update CLAUDE.md overview with SOCKS+HTTP auth mode"
```

---

## Task 4: Валидация (ручная, опциональная в сессии)

В репозитории нет CI и автотестов — реальная проверка возможна только после сборки и деплоя на MikroTik. Шаги ниже выполняются пользователем; агент останавливается после Task 3 и сообщает о готовности к ручной валидации.

- [ ] **Step 4.1: Собрать образ (из `socks/`)**

```bash
cd socks
docker buildx build --platform linux/arm64 --provenance=false --sbom=false -t socks-tunnel:latest --load .
```

Expected: успешная сборка. Размер образа — сопоставим с предыдущей версией (~3.5 МБ), не больше.

- [ ] **Step 4.2: Быстрая локальная smoke-проверка конфига 3proxy (опционально)**

Запустить контейнер с фейковыми значениями только чтобы увидеть содержимое `/tmp/3proxy.cfg` в логах или через `docker exec`:

```bash
docker run --rm -e SOCKS_USER=u -e SOCKS_PASS=p -e HTTP_PORT=3128 -e SSH_HOST=127.0.0.1 socks-tunnel:latest 2>&1 | head -20
```

Expected: в логе — строка `Starting 3proxy: SOCKS=1080, HTTP=3128 (auth: u)...`. SSH будет падать в реконнект-цикл — это нормально, нам нужна только демонстрация ветки кода.

- [ ] **Step 4.3: Сконвертировать и загрузить на роутер**

Шаги конвертации в Docker V2 tar через skopeo — в `README.md`, секция «Сборка и конвертация образа». Пользователь выполняет сам.

- [ ] **Step 4.4: Регресс-проверка (без HTTP_PORT)**

На роутере убедиться, что существующий набор env без `HTTP_PORT` даёт то же поведение:

```bash
curl -x socks5://myuser:mypassword@192.168.88.1:1080 https://ifconfig.me
```

Expected: ответ — IP удалённого сервера.

- [ ] **Step 4.5: Новый режим SOCKS+HTTP**

Добавить `HTTP_PORT=3128` в `socks-env`, перезапустить контейнер, добавить DST-NAT правила для `3128`.

```bash
# SOCKS
curl -x socks5://myuser:mypassword@192.168.88.1:1080 https://ifconfig.me
# HTTP
curl -x http://myuser:mypassword@192.168.88.1:3128 https://ifconfig.me
# HTTP без кредов (должно отбить)
curl -x http://192.168.88.1:3128 https://ifconfig.me
```

Expected:
- Первые два запроса — IP удалённого сервера.
- Третий — `407 Proxy Authentication Required` или ошибка curl.

- [ ] **Step 4.6: Сообщить об успехе валидации**

После успешного прохождения 4.4 и 4.5 — задача завершена. Если что-то не так со вторым листенером (например, HTTP ходит не через туннель) — вернуться к Task 1 Step 1.1 и проверить необходимость дополнительного `parent` перед HTTP-листенером (уже включено в план).

---

## Self-Review

**Spec coverage:**
- Архитектура и три режима → Task 1 Step 1.1 (логика), Task 2 Step 2.1 (описание в README), Task 3 Step 3.1 (CLAUDE.md). ✅
- Добавление `HTTP_PORT` env → Task 2 Step 2.4 (таблица). ✅
- Конфиг 3proxy с условным HTTP-листенером → Task 1 Step 1.1. ✅
- Дублирование `parent` перед HTTP-листенером → Task 1 Step 1.1 (включено явно, без привязки к sticky-поведению — безопаснее). ✅
- Обновление README (описание режимов, env, RouterOS примеры, DST-NAT, проверка) → Task 2 целиком. ✅
- Обновление CLAUDE.md → Task 3. ✅
- Валидация (регресс + новый режим + 407 без кредов) → Task 4 Steps 4.4, 4.5. ✅
- Обратная совместимость (существующие деплои без `HTTP_PORT`) → Task 1 Step 1.1 (условная ветка), Task 4 Step 4.4 (регресс-проверка). ✅

**Placeholder scan:** нет TBD/TODO, код во всех code-шагах полный, пути и команды точные.

**Type consistency:** имена env (`HTTP_PORT`, `SOCKS_USER`, `SOCKS_PASS`, `SOCKS_PORT`, `SSH_TUNNEL_PORT`) используются единообразно между Task 1, Task 2 и Task 4. Переменная `PROXY_PORT` используется в entrypoint как локальный алиас `SOCKS_PORT` — сохранено как в исходнике, не меняется.
