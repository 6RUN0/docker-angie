# Использование

Практическое руководство по запуску и сборке Docker-образа Angie.

---

## Содержание

- [Запуск из реестра](#запуск-из-реестра)
- [Сборка из исходников](#сборка-из-исходников)
- [Цели Makefile](#цели-makefile)
- [Entrypoint и порядок выполнения](#entrypoint-и-порядок-выполнения)
- [Инспекция эффективной конфигурации](#инспекция-эффективной-конфигурации)
- [Логи](#логи)
- [Fail-fast при ошибках entrypoint](#fail-fast-при-ошибках-entrypoint)

---

## Запуск из реестра

Образы публикуются в двух реестрах под одинаковыми тегами:

- Docker Hub: `6run0/angie`
- GHCR: `ghcr.io/6run0/docker-angie`

Поддерживаемые архитектуры: `linux/amd64`, `linux/arm64`.

### Минимальная проверка работоспособности

Скачать образ и убедиться, что health-эндпоинт отвечает. `/healthz` доступен
только с loopback, поэтому запрашивайте его изнутри контейнера (ровно так
работает встроенный HEALTHCHECK):

```sh
docker run -d --name angie -p 8080:80 6run0/angie:alpine
docker exec angie wget -qO- http://127.0.0.1/healthz   # вернёт: ok
```

`GET /healthz` возвращает `200 ok` только loopback-клиентам; запрос через
проброшенный порт (не-loopback источник) получает `404`. Все остальные запросы
с неизвестным заголовком `Host` отклоняются без ответа (`444`).

### Реалистичный запуск с тумблерами

```sh
docker run -d \
  -p 80:80 \
  -e ANGIE_BROTLI_ENABLED=1 \
  -e ANGIE_GZIP_ENABLED=1 \
  -e ANGIE_MODSECURITY_ENABLED=1 \
  -v /путь/к/моей/конфигурации:/etc/angie/custom:ro \
  6run0/angie:alpine
```

Размещайте виртуальные хосты и дополнительные сниппеты в
`/путь/к/моей/конфигурации/http.d/`. `angie.conf` содержит параллельные
`include` для `custom/` на каждом уровне, поэтому пользовательская конфигурация
накладывается поверх встроенного дерева без редактирования системных файлов.

Полная таблица переменных `ANGIE_*` приведена в `../README.md`.

### Rootless-вариант (unprivileged)

Варианты с суффиксом `-unprivileged` не требуют никаких привилегий. Слушатель
перенесён на порт 8080 (`CAP_NET_BIND_SERVICE` не нужен), pid-файл и временные
пути relocated в `/tmp/angie`.

```sh
docker run -d \
  -p 8080:8080 \
  -e ANGIE_BROTLI_ENABLED=1 \
  -v /путь/к/моей/конфигурации:/etc/angie/custom:ro \
  6run0/angie:alpine-unprivileged
```

UID по умолчанию внутри образа -- `65532` (distroless "nonroot"). Его можно
свободно переопределить:

```sh
docker run --user 1000:1000 -p 8080:8080 6run0/angie:alpine-unprivileged
```

Если UID времени выполнения не является владельцем директорий активации,
entrypoint-скрипты используют конфигурацию, запечённую на этапе сборки, и
записывают предупреждение -- контейнер всё равно запускается.

Стандартный (не-unprivileged) образ требует root и отказывается запускаться
под `--user`, выводя понятное сообщение об ошибке вместо аварийного завершения
с `EACCES`.

---

## Сборка из исходников

Контекст сборки всегда -- корень репозитория (`.`).

### Базовые образы Alpine и Debian

```sh
docker build -t angie-alpine -f alpine/Dockerfile .
docker build -t angie-debian -f debian/Dockerfile .
```

### Rootless-наложения

Unprivileged-образы строятся поверх соответствующего базового образа.
Локальный тег базового образа передаётся через `--build-arg BASE_IMAGE`:

```sh
# Alpine rootless (базовый образ должен быть собран первым)
docker build \
  -f alpine/Dockerfile.unprivileged \
  --build-arg BASE_IMAGE=angie-alpine \
  -t angie-alpine-unprivileged \
  .

# Debian rootless
docker build \
  -f debian/Dockerfile.unprivileged \
  --build-arg BASE_IMAGE=angie-debian \
  -t angie-debian-unprivileged \
  .
```

Дополнительные build-аргументы (`APP_USER`, `APP_GROUP`, `APP_UID`,
`APP_GID`) позволяют задать идентификатор непривилегированного пользователя на
этапе сборки (uid/gid по умолчанию: `65532`).

### Все варианты через Compose

```sh
docker compose up --build
```

### Через Make

```sh
make build              # все четыре образа
make build-alpine       # только Alpine
make build-debian       # только Debian
make build-alpine-unprivileged
make build-debian-unprivileged
```

---

## Цели Makefile

| Цель | Описание |
|---|---|
| `help` | Показать все доступные цели |
| **Линтеры** | |
| `lint` | Запустить все линтеры |
| `lint-shell` | `shellcheck` для entrypoint-скриптов (POSIX sh) и `test/*.sh` (bash) |
| `lint-docker` | `hadolint` для всех четырёх Dockerfile |
| `lint-config` | Проверка безопасности `gixy` для отдельных фрагментов vhost |
| `lint-config-full` | `gixy` для полной эффективной конфигурации (требует собранного `angie-alpine`) |
| `lint-ci` | `actionlint` + `zizmor` для GitHub Actions workflows |
| **Сборка** | |
| `build` | Собрать все четыре образа |
| `build-alpine` | Собрать образ Alpine |
| `build-debian` | Собрать образ Debian |
| `build-alpine-unprivileged` | Собрать rootless-образ Alpine (зависит от `build-alpine`) |
| `build-debian-unprivileged` | Собрать rootless-образ Debian (зависит от `build-debian`) |
| **Тесты** | |
| `test` | Smoke-тестирование всех четырёх образов |
| `test-alpine` | Сборка и smoke-тест образа Alpine |
| `test-debian` | Сборка и smoke-тест образа Debian |
| `test-alpine-unprivileged` | Сборка и smoke-тест rootless-образа Alpine |
| `test-debian-unprivileged` | Сборка и smoke-тест rootless-образа Debian |
| **Прочее** | |
| `clean` | Удалить четыре локально собранных образа |

Имена образов по умолчанию: `angie-alpine`, `angie-debian` и т.д. Переопределить
можно в командной строке:

```sh
make build IMAGE_ALPINE=myrepo/angie:latest
```

---

## Entrypoint и порядок выполнения

Цепочка запуска:

```text
tini -- /docker-entrypoint.sh  [CMD: angie -g 'daemon off;']
```

`tini` выступает как PID 1: собирает зомби-процессы и перенаправляет сигналы
в `angie`.

### Фаза конфигурации

`docker-entrypoint.sh` источникует `docker-entrypoint-common.sh` (функции
логирования, `is_root`, `skip_toggle_unless_writable`, хелперы
`enable_log`/`enable_log_format`) и проверяет первый аргумент:

- Если `$1` равен `angie` или `angie-debug` -- фаза конфигурации выполняется.
- Для любой другой команды (например, `sh`) фаза пропускается и сразу
  вызывается `exec "$@"`. Это позволяет запускать произвольные команды внутри
  контейнера без инициализации Angie.

### Выполнение скриптов

В ходе фазы конфигурации все файлы из `/docker-entrypoint.d/` обходятся в
порядке `sort -V` (двухзначный числовой префикс в именах файлов обеспечивает
корректную лексическую сортировку, внешний `sort` не нужен):

| Паттерн файла | Поведение |
|---|---|
| `*.sh` с битом исполнения | Выполняется в основной оболочке; ненулевой код возврата немедленно прерывает запуск. |
| `*.sh` без бита исполнения | Пропускается с сообщением `warning`. |
| Любой другой файл | Пропускается с сообщением `warning`. |

Скрипты, поставляемые в этом образе, следуют схеме нумерации:

| Диапазон | Назначение |
|---|---|
| `30-*` | Системная настройка (например, автонастройка `worker_processes`) |
| `40-*` | Тумблеры функций (gzip, brotli, формат логов, WAF, subs, websocket-карта) |
| `50-*` | Настройка GeoIP2 (валидация пути, рендеринг конфигурации, активация модуля) |
| `90-*` | Исправление прав доступа |

После успешного завершения всех скриптов `docker-entrypoint.sh` выводит
`configuration complete; ready for start up` и вызывает `exec "$@"`, заменяя
себя процессом Angie.

### Конвенция тумблеров

Каждый скрипт-тумблер следует единому шаблону:

```sh
: "${ANGIE_SOME_FEATURE:=no}"
case "${ANGIE_SOME_FEATURE}" in
yes | on | 1 | true | enable | enabled)
  angie-ctl httpconf en "NNN-snippet.conf"
  ;;
esac
```

Допустимые «истинные» значения: `yes`, `on`, `1`, `true`, `enable`, `enabled`.

---

## Инспекция эффективной конфигурации

После запуска контейнера можно получить полностью разрешённую конфигурацию
Angie (все `include` раскрыты, комментарии удалены):

```sh
docker exec <container> angie -T
```

Именно так работает `make lint-config-full`: запускается временный контейнер,
опрашивается `angie -T` до успеха, вывод захватывается и передаётся в `gixy`.

---

## Логи

### Логи доступа и ошибок

Angie пишет логи доступа и ошибок в `stdout`/`stderr`, и Docker-драйвер логов
захватывает их без дополнительной настройки.

Формат логов доступа по умолчанию -- `logfmt`. Полный список доступных
форматов (`main`, `logfmt`, `logfmt-with-geoip2`, `extended`, `matomo`) и
соответствующих переменных `ANGIE_LOG_*` приведён в
[configuration.md](configuration.md).

Одновременно может быть активен только один формат логов доступа. Хелпер
`enable_log` в `docker-entrypoint-common.sh` отключает всю группу
`040-log-*.conf` перед активацией запрошенного формата, поэтому переключение
идемпотентно при перезапусках и не порождает дублирующих директив `access_log`.

### Логи entrypoint

`docker-entrypoint-common.sh` открывает файловый дескриптор 3 при старте:

- `ANGIE_ENTRYPOINT_QUIET_LOGS` не задан или пуст: дескриптор 3 указывает на
  stderr -- сообщения entrypoint видны в `docker logs`.
- `ANGIE_ENTRYPOINT_QUIET_LOGS` задан любым непустым значением: дескриптор 3
  указывает на `/dev/null` -- сообщения entrypoint подавляются.

Все функции логирования entrypoint (`ngx_err`, `ngx_warning`, `ngx_notice`,
`ngx_info`) пишут в дескриптор 3 в формате:

```text
YYYY/MM/DD HH:MM:SS [level] <pid>: entrypoint: <message>
```

---

## Fail-fast при ошибках entrypoint

Скрипт в `/docker-entrypoint.d/`, завершившийся с ненулевым кодом возврата,
заставляет entrypoint записать ошибку и немедленно завершиться с тем же кодом:

```text
YYYY/MM/DD HH:MM:SS [err] 1: entrypoint:
  /docker-entrypoint.d/99-myscript.sh failed with exit 7, aborting startup
```

Контейнер останавливается до запуска Angie. Это исключает ситуацию, когда
частично применённая конфигурация обслуживает запросы молча.

Проверить поведение можно так:

```sh
printf '#!/bin/sh\nexit 7\n' > /tmp/99-fail.sh
chmod +x /tmp/99-fail.sh
docker run --rm \
  -v /tmp/99-fail.sh:/docker-entrypoint.d/99-fail.sh:ro \
  6run0/angie:alpine
# Контейнер завершается с ненулевым кодом; Angie не запускается.
```

---

[English version](usage.md) |
[Конфигурация](configuration.md) |
[Compose](compose.md) |
[Назад к README](../README.md)
