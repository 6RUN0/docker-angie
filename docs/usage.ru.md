# Использование

Практическое руководство по запуску и сборке Docker-образа Angie.

---

## Содержание

- [Запуск из реестра](#запуск-из-реестра)
- [Сборка из исходников](#сборка-из-исходников)
- [Цели Makefile](#цели-makefile)
- [Entrypoint и порядок выполнения](#entrypoint-и-порядок-выполнения)
- [Инспекция эффективной конфигурации](#инспекция-эффективной-конфигурации)
- [Применение правки конфигурации](#применение-правки-конфигурации)
- [Переход с изменяемой раскладки `/etc/angie`](#переход-с-изменяемой-раскладки-etcangie)
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
  --read-only --tmpfs /data:mode=1777 \
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

Полная таблица переменных `ANGIE_*` приведена в `../README.ru.md`.

### Rootless-вариант (unprivileged)

Варианты с суффиксом `-unprivileged` не требуют никаких привилегий. Слушатель
перенесён на порт 8080 (`CAP_NET_BIND_SERVICE` не нужен). Как и обычный образ,
он использует `/data/conf` для рабочей конфигурации и `/data/tmp` для временных
файлов; pid-файла нет.

```sh
docker run -d \
  --read-only --tmpfs /data:mode=1777 \
  -p 8080:8080 \
  -e ANGIE_BROTLI_ENABLED=1 \
  -v /путь/к/моей/конфигурации:/etc/angie/custom:ro \
  6run0/angie:alpine-unprivileged
```

UID по умолчанию внутри образа - `65532` (distroless "nonroot"). Его можно
свободно переопределить:

```sh
docker run --user 1000:1000 -p 8080:8080 6run0/angie:alpine-unprivileged
```

Непривилегированный образ работает под любым UID. `/data` должен быть доступен
ему для записи; свежий tmpfs с `mode=1777` удовлетворяет условию. Постоянный
`/data/conf`, созданный другим UID, не перезаписывается, а вызывает отказ.

Стандартный (не-unprivileged) образ требует root и отказывается запускаться
под `--user`, выводя понятное сообщение об ошибке вместо аварийного завершения
с `EACCES`.

---

## Сборка из исходников

Контекст сборки всегда - корень репозитория (`.`).

### Базовые образы Alpine и Debian

У каждого Dockerfile две конечные цели: `standard` (root-мастер, порт 80) и
`unprivileged` (порт 8080, см. ниже). Сборка без `--target` даёт `standard`.

```sh
docker build --target standard -t angie-alpine -f alpine/Dockerfile .
docker build --target standard -t angie-debian -f debian/Dockerfile .
```

### Rootless-цели

Unprivileged-образы собираются из цели `unprivileged` того же Dockerfile. Обе
цели делят стадию `runtime`, поэтому вторая сборка берёт слои с пакетами и
конфигурацией из кеша сборки, и собирать что-то заранее не нужно:

```sh
docker build --target unprivileged -t angie-alpine-unprivileged -f alpine/Dockerfile .
docker build --target unprivileged -t angie-debian-unprivileged -f debian/Dockerfile .
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
| `lint-shell` | `shellcheck` для entrypoint-скриптов, утилит и тестов (POSIX sh) |
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
| `test` | Тесты утилиты и оба smoke-набора для всех четырёх образов |
| `test-unit` | Проверка встроенного `angie-ctl` без Docker |
| `test-alpine` | Сборка и smoke-тест образа Alpine |
| `test-debian` | Сборка и smoke-тест образа Debian |
| `test-alpine-unprivileged` | Сборка и smoke-тест rootless-образа Alpine |
| `test-debian-unprivileged` | Сборка и smoke-тест rootless-образа Debian |
| **Прочее** | |
| `ci-local` | Прогнать workflow CI из GitHub Actions локально через [act](https://github.com/nektos/act) |
| `clean` | Удалить четыре локально собранных образа |

Имена образов по умолчанию: `angie-alpine`, `angie-debian` и т.д. Переопределить
можно в командной строке:

```sh
make build IMAGE_ALPINE=myrepo/angie:latest
```

`ci-local` выполняет все job из `.github/workflows/ci.yml`; `ACT_JOB` сужает
прогон до одного (`make ci-local ACT_JOB=lint`). Нужны `act` и демон Docker, а
smoke-тесты с монтированием фикстур проходят только потому, что цель монтирует
репозиторий по его собственному абсолютному пути и уводит туда же `TMPDIR`: act
выполняет job в контейнере, а `docker run` внутри job уходит на хостовый демон,
поэтому путь, существующий лишь с одной стороны, молча подменяется пустым
каталогом.

---

## Entrypoint и порядок выполнения

Цепочка запуска:

```text
tini -- /docker-entrypoint.sh \
  [CMD: angie -p /data/conf -c angie.conf -g 'daemon off;']
```

`tini` выступает как PID 1: собирает зомби-процессы и перенаправляет сигналы
в `angie`.

### Фаза конфигурации

`docker-entrypoint.sh` подключает `docker-entrypoint-common.sh` (логирование,
рабочие пути и хелперы активации) и проверяет первый аргумент:

- Если `$1` равен `angie` или `angie-debug` - фаза конфигурации выполняется.
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
| `10-*` | Пересборка `/data/conf` из неизменяемого шаблона |
| `30-*` | Системная настройка (например, автонастройка `worker_processes`) |
| `40-*` | Тумблеры, включая ACME, Console, сжатие, логи и модули |
| `45-*` / `46-*` | Заголовки безопасности, HSTS и CORS для ресурсов |
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

Допустимые "истинные" значения: `yes`, `on`, `1`, `true`, `enable`, `enabled`.

---

## Инспекция эффективной конфигурации

После запуска проверяйте и выводите рабочую конфигурацию с явным префиксом:

```sh
docker exec <container> angie -p /data/conf -c angie.conf -t
docker exec <container> angie -p /data/conf -c angie.conf -T
```

Wrapper `/usr/local/bin/angie-runtime` передаёт эти параметры встроенным
проверкам и скриптам. В операционных процедурах используйте явную форму, чтобы
не было неоднозначности, какое дерево проверяется.

## Применение правки конфигурации

Пользовательский том остаётся в `/etc/angie/custom`, поэтому изменение его
файлов не требует пересоздавать контейнер. Проверьте конфигурацию и отправьте
сигнал контейнеру:

```sh
docker exec angie angie -p /data/conf -c angie.conf -t
docker kill -s HUP angie
```

`angie -s reload` не поддерживается: образ использует `pid off`. Переменные
окружения закреплены в описании контейнера; после их правки пересоздайте
контейнер, а не отправляйте HUP.

Внутри контейнера работает и `angie-ctl --reload`: образ задаёт
`ANGIE_RELOAD_CMD="kill -HUP 1"`, а tini (PID 1) пересылает сигнал мастеру.
Включённый так сниппет действует до следующего старта: тот пересобирает
`/data/conf` из образца и переменных окружения.

## Переход с изменяемой раскладки `/etc/angie`

Новая раскладка несовместима с подключениями сгенерированной конфигурации и
временных каталогов напрямую:

1. Оставьте свои файлы в `/etc/angie/custom/{conf.d,http-conf.d,http.d}`.
2. Уберите тома `/etc/angie`, `/etc/angie/*.d`, `/run/angie.pid`, `/tmp/angie`
   и `/var/cache/angie`, которые требовались только для записи.
3. Подключите один записываемый `/data`: tmpfs для stateless-сценария,
   постоянный том для ACME или дискового кеша.
4. Обновите команды проверки и reload на явный префикс и HUP выше.

Не сохраняйте `/data/conf`: entrypoint пересобирает его из нового образа при
каждом старте, чтобы обновлённые умолчания попадали в существующие развёртывания.

---

## Логи

### Логи доступа и ошибок

Angie пишет логи доступа и ошибок в `stdout`/`stderr`, и Docker-драйвер логов
захватывает их без дополнительной настройки.

Формат логов доступа по умолчанию - структурированный JSON. Полный список
форматов (`main`, `json`, `logfmt`, варианты GeoIP2, `extended`, `matomo`) и
соответствующих переменных `ANGIE_LOG_*` приведён в
[configuration.ru.md](configuration.ru.md).

Одновременно может быть активен только один формат логов доступа. Хелпер
`enable_log` в `docker-entrypoint-common.sh` отключает всю группу
`040-log-*.conf` перед активацией запрошенного формата, поэтому переключение
идемпотентно при перезапусках и не порождает дублирующих директив `access_log`.

### Логи entrypoint

`docker-entrypoint-common.sh` открывает файловый дескриптор 3 при старте:

- `ANGIE_ENTRYPOINT_QUIET_LOGS` не задан или пуст: дескриптор 3 указывает на
  stderr - сообщения entrypoint видны в `docker logs`.
- `ANGIE_ENTRYPOINT_QUIET_LOGS` задан любым непустым значением: дескриптор 3
  указывает на `/dev/null` - сообщения entrypoint подавляются.

По умолчанию все функции логирования entrypoint пишут JSON, один объект на
строку. `ANGIE_ERROR_LOG_JSON_ENABLED=no` возвращает текстовый формат:

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
# Создать падающий скрипт и примонтировать его
printf '#!/bin/sh\nexit 7\n' > /tmp/99-fail.sh
chmod +x /tmp/99-fail.sh
docker run --rm \
  -v /tmp/99-fail.sh:/docker-entrypoint.d/99-fail.sh:ro \
  6run0/angie:alpine
# Контейнер завершается с ненулевым кодом; Angie не запускается.
```

---

[Конфигурация](configuration.ru.md) |
[Compose](compose.ru.md) |
[Назад к README](../README.ru.md)

English: [usage.md](usage.md).
