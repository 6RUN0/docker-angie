# Docker-образы Angie с дополнительными модулями

Этот репозиторий предоставляет кастомные Docker-образы для [Angie web server](https://angie.software)
с дополнительными модулями и опциями конфигурации.
Поддерживаются образы на базе Alpine и Debian, а также включены модули
для сжатия Brotli, GeoIP2, ModSecurity (WAF) и фильтр подстановок.

## Включённые модули

Доступны следующие сторонние модули:

- [ngx_brotli](https://github.com/google/ngx_brotli) — динамическое и статическое сжатие Brotli.
- [ngx_http_geoip2_module](https://github.com/leev/ngx_http_geoip2_module) — определение географической локации по IP клиента.
- [ModSecurity‑nginx](https://github.com/owasp-modsecurity/ModSecurity-nginx) — межсетевой экран ModSecurity.
- [ngx_http_substitutions_filter_module](https://github.com/yaoweibin/ngx_http_substitutions_filter_module) — подстановки в теле ответа.

Эти модули поставляются как динамические.
Они не включаются автоматически; их нужно активировать
во время запуска через переменные окружения, описанные ниже.

## Томa

- `/etc/angie/custom` — для кастомной конфигурации Angie

## Переменные окружения

| Переменная | Описание | Значение по умолчанию |
| ----------- | ----------- | ------- |
| `ANGIE_ENTRYPOINT_QUIET_LOGS` | Подавить информационные сообщения от entrypoint (будут выводиться только предупреждения и ошибки). | unset |
| `ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` | Автоматически настраивать `worker_processes` в зависимости от числа CPU (не работает, если `/etc/angie/angie.conf` доступен только для чтения). | unset |
| `ANGIE_BROTLI_ENABLED` | Загружать модуль Brotli и включить сжатие Brotli. | `no` |
| `ANGIE_BROTLI_STATIC_ENABLE` | Включить Brotli и отдачу заранее сжатых файлов (`*.br`). Включает `ANGIE_BROTLI_ENABLED`. | `no` |
| `ANGIE_GZIP_ENABLED` | Включить сжатие gzip. | `no` |
| `ANGIE_GZIP_STATIC_ENABLE` | Включить отдачу заранее сжатых gzip файлов (`*.gz`). Включает `ANGIE_GZIP_ENABLED`. | `no` |
| `ANGIE_MODSECURITY_ENABLE` | Включить модуль ModSecurity. | `no` |
| `ANGIE_SUBS_ENABLE` | Включить фильтр подстановок. | `no` |
| `GEOIP2_DB_COUNTRY` | Абсолютный путь к базе GeoIP2 стран. Если указан и файл доступен, модуль GeoIP2 и его конфигурация будут включены. | unset |
| `ANGIE_LOG_FORMAT_EXTENDED` | Зарегистрировать формат логов `extended`. Не меняет активный лог, если не указана одна из переменных `ANGIE_LOG_*` ниже. | `no` |
| `ANGIE_LOG_FORMAT_LOGFMT` | Зарегистрировать формат логов `logfmt` (key=value). Включён по умолчанию, так как используется для стандартного access log. | `yes` |
| `ANGIE_LOG_FORMAT_MAIN` | Зарегистрировать классический формат логов `main`. | `no` |
| `ANGIE_LOG_FORMAT_MATOMO` | Зарегистрировать формат логов `matomo`, совместимый с платформой аналитики Matomo. | `no` |
| `ANGIE_LOG_EXTENDED` | Использовать формат логов `extended` для `/dev/stdout`. | `no` |
| `ANGIE_LOG_LOGFMT` | Использовать формат логов `logfmt` для `/dev/stdout`. | `yes` |
| `ANGIE_LOG_MAIN` | Использовать формат логов `main` для `/dev/stdout`. | `no` |
| `ANGIE_LOG_MATOMO` | Использовать формат логов `matomo` для `/dev/stdout`. | `no` |
| `ANGIE_LOG_FORMAT_LOGFMT_GEOIP2` | При использовании GeoIP2 зарегистрировать формат логов `logfmt-with-geoip2` (добавляет поле `country`) без активации. | `no` |
| `ANGIE_LOG_LOGFMT_GEOIP2` | При использовании GeoIP2 использовать формат логов `logfmt-with-geoip2` для `/dev/stdout`. | `no` |
| `ANGIE_MAP_WEBSOCKET_ENABLE` | Включить карту переменных WebSocket для упрощения проксирования WebSocket. | `no` |
| `CACHE_DIR` | Если указано, entrypoint сменит владельца указанного каталога кэша на пользователя `angie` (удобно при bind‑mount кэша). | unset |

## Сборка

Используйте предоставленные Dockerfile для самостоятельной сборки образов:

```bash
# Сборка образа на базе Alpine
docker build -t angie‑alpine -f alpine/Dockerfile .
# Сборка образа на базе Debian
docker build -t angie‑debian -f debian/Dockerfile .
```

Также можно использовать `docker‑compose.yml` для сборки и запуска всех вариантов:

```bash
docker compose up --build
```

## Примечания

- В конфигурации по умолчанию увеличены значения `worker_connections` и `worker_rlimit_nofile` до 65536
для поддержки высокой конкуренции. При необходимости измените эти параметры в `rootfs/etc/angie/angie.conf`.

- В entrypoint устанавливается **angie‑ctl** (из коммита, указанного в аргументе сборки `ANGIE_CTL_COMMIT`) в `/usr/local/bin`.
Эта утилита используется для включения или отключения конфигурационных сниппетов и модулей во время работы.

## См. также

- [Установка Angie](https://angie.software/installation/)
