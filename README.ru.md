# Docker-образ Angie с Brotli, Zstandard, GeoIP2, ModSecurity (WAF) и подстановками

Готовый к эксплуатации [Angie](https://angie.software) (форк nginx) с пятью
динамическими модулями, рантайм-тумблерами функций и rootless-вариантом.

[![CI](https://github.com/6RUN0/docker-angie/actions/workflows/ci.yml/badge.svg)](https://github.com/6RUN0/docker-angie/actions/workflows/ci.yml)
[![Docker pulls](https://img.shields.io/docker/pulls/6run0/angie)](https://hub.docker.com/r/6run0/angie)
[![Image size](https://img.shields.io/docker/image-size/6run0/angie/alpine?label=alpine%20size)](https://hub.docker.com/r/6run0/angie/tags)
[![Architectures](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-blue)](#загрузка-образа)
[![License: MIT](https://img.shields.io/github/license/6RUN0/docker-angie)](LICENSE)
[![Status: alpha](https://img.shields.io/badge/status-alpha-orange)](#версионирование)

Встроенные модули — Brotli, Zstandard, GeoIP2, ModSecurity (WAF) и фильтр
подстановок — поставляются **выключенными** и включаются при старте контейнера через
переменные окружения `ANGIE_*`. Публикуются две базы: **Alpine** (по умолчанию)
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

Для воспроизводимых развёртываний фиксируйте неизменяемый тег — см.
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
закрывается) — добавьте свои server-блоки через том кастомной конфигурации,
чтобы обслуживать реальный трафик.

## Использование

Включайте функции переменными `ANGIE_*` и монтируйте свою конфигурацию:

```bash
docker run -d --name angie \
  -p 80:80 \
  -e ANGIE_BROTLI_ENABLED=yes \
  -e ANGIE_GZIP_ENABLED=yes \
  -v "$PWD/angie-config:/etc/angie/custom:ro" \
  6run0/angie:alpine
```

Rootless-развёртывание (слушает 8080, работает от uid/gid 65532):

```bash
docker run -d -p 8080:8080 6run0/angie:alpine-unprivileged
```

- Примеры Compose → [docs/compose.ru.md](docs/compose.ru.md)
- Сборка образов из исходников → [docs/usage.ru.md](docs/usage.ru.md)

## Конфигурация

Ключевые тумблеры (полная таблица из 20+ переменных в
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
| `ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` | unset | Настроить `worker_processes` под число CPU при старте. |

Монтируйте кастомную конфигурацию в том **`/etc/angie/custom`**.

## Данные и состояние

Образ **stateless** — вся рантайм-конфигурация выводится из переменных `ANGIE_*`
и тома `/etc/angie/custom` при старте контейнера; ничего, что нужно бэкапить, не
пишется. Конфигурация применяется **один раз при создании**, поэтому изменение
переменной `ANGIE_*` вступает в силу при **пересоздании** контейнера, а не через
`docker restart`. Unprivileged-образ работает от uid/gid `65532` и владеет
`/etc/angie/*.d`; о запуске под сторонним `--user` см.
[docs/security.ru.md](docs/security.ru.md).

## Ограничения

- ModSecurity загружает только движок — набор правил по умолчанию не
  поставляется; подключите свой (например, OWASP CRS).
- Встроенные модули динамические и выключены до активации.
- Полный список → [docs/limitations.ru.md](docs/limitations.ru.md).

## Версионирование

Тег образа кодирует **версию Angie** плюс **номер сборки** упаковки —
`<angie>-build<N>-<variant>`. Номер сборки растёт, когда та же версия Angie
переупаковывается (бамп базового образа, правка entrypoint, обновление
angie-ctl). Версия Angie внутри образа также видна в метке
`software.angie.version` (`docker inspect`) и через `angie -v`.

| Тег | Значение |
| --- | --- |
| `1.11.8-build2-alpine`, `…-debian` | Неизменяемый — точная версия Angie и упаковка. **Фиксируйте его.** |
| `1.11.8-alpine` | Последняя сборка этого патча Angie. |
| `1.11-alpine` | Последний патч этой минорной линии Angie. |
| `alpine`, `debian` | Последний стабильный образ этой базы. |
| `latest` | Последний стабильный образ **Alpine**. |
| `*-unprivileged` | Rootless-вариант; суффикс ко всем тегам выше, кроме `latest` (например, `alpine-unprivileged`, `1.11.8-build2-alpine-unprivileged`). |

Плавающие теги двигаются только для стабильных релизов Angie; prerelease-версия
Angie (например, `1.11.8-rc1`) публикует лишь свой неизменяемый тег `…-build<N>`.

## Документация

- [Конфигурация](docs/configuration.ru.md) — полный справочник env/томов/портов
- [Использование](docs/usage.ru.md) — сборка, entrypoint, логи, коды возврата
- [Compose](docs/compose.ru.md) — готовые к запуску compose-файлы
- [Безопасность](docs/security.ru.md) — non-root, capabilities, секреты
- [Ограничения](docs/limitations.ru.md) — известные границы
- [Устранение неполадок](docs/troubleshooting.ru.md) — типичные ошибки
- [История изменений](CHANGELOG.ru.md) — история релизов

English: [README.md](README.md).

## Лицензия

[MIT](LICENSE) для этой упаковки. Angie и встроенные сторонние модули сохраняют
свои собственные лицензии.
