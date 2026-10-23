# Docker-образ Angie с Brotli, Zstandard, GeoIP2, ModSecurity (WAF) и подстановками

Готовый к эксплуатации [Angie](https://angie.software) (форк nginx) с пятью
динамическими модулями, рантайм-тумблерами функций и rootless-вариантом.

[![CI](https://github.com/6RUN0/docker-angie/actions/workflows/ci.yml/badge.svg)](https://github.com/6RUN0/docker-angie/actions/workflows/ci.yml)
[![Docker pulls](https://img.shields.io/docker/pulls/6run0/angie)](https://hub.docker.com/r/6run0/angie)
[![Image size](https://img.shields.io/docker/image-size/6run0/angie/alpine?label=alpine%20size)](https://hub.docker.com/r/6run0/angie/tags)
[![Architectures](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-blue)](#загрузка-образа)
[![License: MIT](https://img.shields.io/github/license/6RUN0/docker-angie)](LICENSE)
[![Status: alpha](https://img.shields.io/badge/status-alpha-orange)](#версионирование)

Встроенные модули - Brotli, Zstandard, GeoIP2, ModSecurity (WAF) и фильтр
подстановок - поставляются **выключенными** и включаются при старте контейнера через
переменные окружения `ANGIE_*`. Также есть необязательные ACME, Console Light,
кеширование, CORS, HSTS и переиспользуемые сниппеты. Публикуются две базы:
**Alpine** (по умолчанию)
и **Debian**, у каждой есть rootless-вариант **unprivileged**.

## Требования

- Docker Engine 20.10+ (или любой runtime, умеющий тянуть OCI-образы).
- Для самостоятельной сборки multi-arch образов: Docker с плагином `buildx`.
- Образ по умолчанию слушает порт **80** внутри контейнера; unprivileged-вариант
  слушает **8080** и работает от непривилегированного пользователя.

## Загрузка образа

Образы публикуются при каждом теге `v*` в два реестра, для `linux/amd64` и
`linux/arm64`:

```bash
# GitHub Container Registry
docker pull ghcr.io/6run0/docker-angie:alpine

# Docker Hub
docker pull 6run0/angie:alpine
```

Для воспроизводимых развёртываний фиксируйте неизменяемый тег - см.
[Версионирование](#версионирование).

## Быстрый старт

```bash
docker run -d --name angie -p 8080:80 6run0/angie:alpine
```

Проверьте, что сервер жив, через тот же loopback-эндпоинт, что использует
встроенный HEALTHCHECK (`/healthz` намеренно доступен только с loopback, поэтому
запрашивайте его изнутри контейнера):

```bash
docker exec angie wget -qO- http://127.0.0.1/healthz   # -> ok
```

С хоста любой запрос к несопоставленному хосту возвращает `444` (соединение
закрывается) - добавьте свои server-блоки через том кастомной конфигурации,
чтобы обслуживать реальный трафик.

## Использование

Включайте функции переменными `ANGIE_*` и монтируйте свою конфигурацию:

```bash
docker run -d --name angie \
  --read-only --tmpfs /data:mode=1777 \
  -p 80:80 \
  -e ANGIE_BROTLI_ENABLED=yes \
  -e ANGIE_GZIP_ENABLED=yes \
  -v "$PWD/angie-config:/etc/angie/custom:ro" \
  6run0/angie:alpine
```

Rootless-развёртывание (слушает 8080, работает от uid/gid 65532):

```bash
docker run -d --read-only --tmpfs /data:mode=1777 \
  -p 8080:8080 6run0/angie:alpine-unprivileged
```

Оба варианта поддерживают корень только для чтения. Обычный образ сохраняет
root-мастер, рабочие процессы `angie` и порт 80; непривилегированный использует
порт 8080 и по умолчанию uid/gid 65532. В обоих вариантах `/etc/angie` -
неизменяемый шаблон, а рабочее дерево пересобирается в `/data/conf` при старте.

- Примеры Compose: [docs/compose.ru.md](docs/compose.ru.md)
- Сборка образов из исходников: [docs/usage.ru.md](docs/usage.ru.md)

## Конфигурация

Ключевые тумблеры (полный справочник в
[docs/configuration.ru.md](docs/configuration.ru.md)):

| Переменная | По умолчанию | Описание |
| --- | --- | --- |
| `ANGIE_BROTLI_ENABLED` | `no` | Загрузить модуль Brotli и включить сжатие Brotli. |
| `ANGIE_GZIP_ENABLED` | `no` | Включить сжатие gzip. |
| `ANGIE_ZSTD_ENABLED` | `no` | Загрузить модуль Zstandard и включить сжатие zstd. |
| `ANGIE_MODSECURITY_ENABLED` | `no` | Включить модуль WAF ModSecurity. |
| `ANGIE_SUBS_ENABLED` | `no` | Включить фильтр подстановок в теле ответа. |
| `GEOIP2_DB_COUNTRY` | unset | Путь к базе GeoIP2 стран; включает GeoIP2, если файл доступен. |
| `ANGIE_MAP_WEBSOCKET_ENABLED` | `no` | Включить карту переменных для апгрейда WebSocket. |
| `ANGIE_REAL_IP_FROM` | unset | CIDR доверенных прокси; восстанавливает реальный IP клиента за прокси/балансировщиком. |
| `ANGIE_SECURITY_HEADERS_ENABLED` | `no` | Отдавать консервативный базовый набор security-заголовков. |
| `ANGIE_CHARSET_UTF8_ENABLED` | `no` | Объявлять UTF-8 для текстовых типов ответов. |
| `ANGIE_EXPIRES_ENABLED` | `no` | Объявить сроки кеширования для `snippets/expires-by-type.conf`. |
| `ANGIE_OPEN_FILE_CACHE_ENABLED` | `no` | Кешировать открытые файлы и метаданные. |
| `ANGIE_HSTS_ENABLED` | `no` | Отдавать HSTS по HTTPS; сначала прочитайте порядок отключения. |
| `ANGIE_CORS_ASSETS_ENABLED` | `no` | Разрешить использование шрифтов и изображений с других источников. |
| `ANGIE_STATUS_API_ENABLED` | `no` | Отдавать JSON статус-API и Prometheus `/metrics` на `:8181`. |
| `ANGIE_CONSOLE_ENABLED` | `no` | Отдавать Console Light по секретному пути, обычно под basic auth. |
| `ANGIE_ACME_ENABLED` | `no` | Настроить встроенный клиент ACME; при включении сохраняйте `/data`. |
| `ANGIE_ERROR_LOG_JSON_ENABLED` | `yes` | Писать error log и журнал entrypoint как JSON, один объект на строку. |
| `ANGIE_WORKER_SHUTDOWN_TIMEOUT` | `8s` | Ограничить мягкое завершение worker меньше grace period контейнера. |
| `ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` | unset | Настроить `worker_processes` под число CPU при старте. |

Переменные access-лога делятся на два семейства, которые легко спутать по
именам, - разница в том, **регистрируют** они формат или **активируют**:

- `ANGIE_LOG_FORMAT_*` (например, `ANGIE_LOG_FORMAT_LOGFMT_GEOIP2`) только
  **регистрируют** определение `log_format`, чтобы на него можно было ссылаться.
  Они **не** меняют активный access-лог и **не** отключают другие форматы.
- `ANGIE_LOG_*` (например, `ANGIE_LOG_LOGFMT_GEOIP2`) **регистрируют и
  активируют** формат как access-лог. Активация одного сбрасывает остальные,
  поэтому активным остаётся ровно один access-лог - именно это переопределяет
  формат JSON по умолчанию. Включение двух привело бы к двойной записи
  каждого запроса.

Варианты `*_GEOIP2` дополнительно требуют поднятого GeoIP2 (`GEOIP2_DB_COUNTRY`
задан и доступен для чтения). Полная таблица:
[docs/configuration.ru.md](docs/configuration.ru.md#логи-доступа).

Монтируйте кастомную конфигурацию в том **`/etc/angie/custom`**. Подключаются
только его подкаталоги `conf.d`, `http-conf.d` и `http.d`.

## Данные и состояние

Пока ACME выключен, образ не хранит состояние. При каждом старте точка входа
копирует неизменяемый шаблон `/etc/angie` в `/data/conf`, применяет там
настройки `ANGIE_*`, а временные файлы размещает в `/data/tmp`. Пользовательскую
конфигурацию монтируйте только в `/etc/angie/custom`; не монтируйте `/data/conf`.

Каталог `/data` должен быть доступен для записи. При обычном запуске достаточно
слоя контейнера; с `--read-only` подключите `--tmpfs /data:mode=1777` или том.
При включённом ACME нужен постоянный том, а не tmpfs: в `/data/acme` находятся
ключи учётной записи и сертификаты. Изменение переменной окружения требует
пересоздать контейнер. После правки пользовательского тома проверьте
конфигурацию и отправьте HUP:

```bash
docker exec angie angie -p /data/conf -c angie.conf -t
docker kill -s HUP angie
```

`angie -s reload` не поддерживается, потому что задано `pid off`.
Переход со старой изменяемой раскладки `/etc/angie` описан в
[docs/usage.ru.md](docs/usage.ru.md).

## Ограничения

- ModSecurity загружает только движок - набор правил по умолчанию не
  поставляется; подключите свой (например, OWASP CRS).
- Встроенные модули динамические и выключены до активации.
- Полный список: [docs/limitations.ru.md](docs/limitations.ru.md).

## Версионирование

Тег образа кодирует **версию Angie** плюс **номер сборки** упаковки -
`<angie>-build<N>-<variant>`. Номер сборки растёт, когда та же версия Angie
переупаковывается (подъём базового образа, правка entrypoint, обновление
angie-ctl). Версия Angie внутри образа также видна в метке
`software.angie.version` (`docker inspect`) и через `angie -v`.

| Тег | Значение |
| --- | --- |
| `1.12.4-build1-alpine`, `...-debian` | Неизменяемый - точная версия Angie и упаковка. **Фиксируйте его.** |
| `1.12.4-alpine` | Последняя сборка этого патча Angie. |
| `1.12-alpine` | Последний патч этой минорной линии Angie. |
| `alpine`, `debian` | Последний стабильный образ этой базы. |
| `latest` | Последний стабильный образ **Alpine**. |
| `*-unprivileged` | Rootless-вариант; суффикс ко всем тегам выше, кроме `latest` (например, `alpine-unprivileged`, `1.12.4-build1-alpine-unprivileged`). |

Плавающие теги двигаются только для стабильных релизов Angie; prerelease-версия
Angie (например, `1.12.4-rc1`) публикует лишь свой неизменяемый тег `...-build<N>`.

## Документация

- [Конфигурация](docs/configuration.ru.md) - полный справочник env/томов/портов
- [Использование](docs/usage.ru.md) - сборка, entrypoint, логи, коды возврата
- [Compose](docs/compose.ru.md) - готовые к запуску compose-файлы
- [Безопасность](docs/security.ru.md) - non-root, capabilities, секреты
- [Ограничения](docs/limitations.ru.md) - известные границы
- [Устранение неполадок](docs/troubleshooting.ru.md) - типичные ошибки
- [Устройство образов](docs/architecture.ru.md) - как собраны образы и почему
- [История изменений](CHANGELOG.ru.md) - история релизов

## Лицензия

[MIT](LICENSE) для этой упаковки. Angie и встроенные сторонние модули сохраняют
свои собственные лицензии.

English: [README.md](README.md).
