# Angie + Brotli, GeoIP2, ModSecurity (WAF), substitutions

[Angie](https://angie.software) (an nginx fork) with four dynamic modules and
runtime feature toggles. Modules ship disabled and are switched on at container
start via `ANGIE_*` environment variables. Bases: **Alpine** (default) and
**Debian**, each with a rootless **unprivileged** variant.
Multi-arch: `linux/amd64`, `linux/arm64`.

## English

### Pull

```bash
docker pull 6run0/angie:alpine
# also on GHCR: ghcr.io/6run0/docker-angie:alpine
```

### Run

```bash
docker run -d -p 80:80 \
  -e ANGIE_BROTLI_ENABLED=yes \
  -e ANGIE_GZIP_ENABLED=yes \
  -v /srv/angie-config:/etc/angie/custom:ro \
  6run0/angie:alpine
```

The built-in HEALTHCHECK probes `/healthz` on loopback (`/healthz` is
loopback-only); from outside, every unmatched host returns `444`.
Rootless variant `6run0/angie:alpine-unprivileged` listens on `8080` and runs as
uid/gid `65532`.

### Tags

| Tag | Meaning |
| --- | --- |
| `1.11.8-build1-alpine`, `…-debian` | Immutable — exact Angie version + build. Pin this. |
| `1.11.8-alpine` | Latest build of that Angie patch. |
| `1.11-alpine` | Latest patch of that Angie minor line. |
| `alpine`, `debian` | Latest stable of that base. |
| `latest` | Latest stable Alpine image. |
| `*-unprivileged` | Rootless variant; suffixes every tag above except `latest`. |

### Key environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `ANGIE_BROTLI_ENABLED` | `no` | Brotli compression. |
| `ANGIE_GZIP_ENABLED` | `no` | gzip compression. |
| `ANGIE_MODSECURITY_ENABLED` | `no` | ModSecurity WAF (engine only; bring your own rules). |
| `ANGIE_SUBS_ENABLED` | `no` | Response-body substitutions filter. |
| `GEOIP2_DB_COUNTRY` | unset | Path to a GeoIP2 country DB; enables GeoIP2 when readable. |

Full reference:
[configuration](https://github.com/6RUN0/docker-angie/blob/main/docs/configuration.md) ·
[usage](https://github.com/6RUN0/docker-angie/blob/main/docs/usage.md) ·
[security](https://github.com/6RUN0/docker-angie/blob/main/docs/security.md) ·
[source repository](https://github.com/6RUN0/docker-angie).

## Русский

### Загрузка

```bash
docker pull 6run0/angie:alpine
# также в GHCR: ghcr.io/6run0/docker-angie:alpine
```

### Запуск

```bash
docker run -d -p 80:80 \
  -e ANGIE_BROTLI_ENABLED=yes \
  -e ANGIE_GZIP_ENABLED=yes \
  -v /srv/angie-config:/etc/angie/custom:ro \
  6run0/angie:alpine
```

Встроенный HEALTHCHECK проверяет `/healthz` по loopback (`/healthz` доступен
только с loopback); снаружи любой несопоставленный хост получает `444`.
Rootless-вариант `6run0/angie:alpine-unprivileged` слушает `8080` и работает от
uid/gid `65532`.

### Теги

| Тег | Значение |
| --- | --- |
| `1.11.8-build1-alpine`, `…-debian` | Неизменяемый — точная версия Angie + сборка. Фиксируйте его. |
| `1.11.8-alpine` | Последняя сборка этого патча Angie. |
| `1.11-alpine` | Последний патч этой минорной линии Angie. |
| `alpine`, `debian` | Последний стабильный образ этой базы. |
| `latest` | Последний стабильный образ Alpine. |
| `*-unprivileged` | Rootless-вариант; суффикс ко всем тегам выше, кроме `latest`. |

### Ключевые переменные окружения

| Переменная | По умолчанию | Описание |
| --- | --- | --- |
| `ANGIE_BROTLI_ENABLED` | `no` | Сжатие Brotli. |
| `ANGIE_GZIP_ENABLED` | `no` | Сжатие gzip. |
| `ANGIE_MODSECURITY_ENABLED` | `no` | WAF ModSecurity (только движок; правила свои). |
| `ANGIE_SUBS_ENABLED` | `no` | Фильтр подстановок в теле ответа. |
| `GEOIP2_DB_COUNTRY` | unset | Путь к базе GeoIP2 стран; включает GeoIP2, если файл доступен. |

Полный справочник:
[конфигурация](https://github.com/6RUN0/docker-angie/blob/main/docs/configuration.ru.md) ·
[использование](https://github.com/6RUN0/docker-angie/blob/main/docs/usage.ru.md) ·
[безопасность](https://github.com/6RUN0/docker-angie/blob/main/docs/security.ru.md) ·
[репозиторий](https://github.com/6RUN0/docker-angie).
