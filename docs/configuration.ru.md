# Справочник конфигурации

Переменные окружения, тома, порты, сниппеты и аргументы сборки образа
`6run0/angie`. См. также [usage.ru.md](usage.ru.md) и
[security.ru.md](security.ru.md).

## Переменные окружения

Тумблеры принимают `yes`, `on`, `1`, `true`, `enable` и `enabled`. Любое другое
значение выключает функцию. Два исключения:
`ANGIE_ENTRYPOINT_QUIET_LOGS` и
`ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` включаются любым непустым
значением, включая `no` и `0`.

Точка входа применяет настройки к свежей копии неизменяемого шаблона
`/etc/angie` в `/data/conf`. Поэтому тумблеры работают в обоих вариантах
образа, под произвольным UID в непривилегированном образе и с корнем только для
чтения, если `/data` доступен для записи.

### Общие

| Переменная | По умолчанию | Описание |
|---|---|---|
| `ANGIE_ENTRYPOINT_QUIET_LOGS` | не задана | Скрыть все сообщения entrypoint, включая ошибки; отказ виден только по коду возврата. Включает любое непустое значение. |
| `ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` | не задана | Определять `worker_processes` из квоты и cpuset cgroup v1/v2 при каждом старте. Включает любое непустое значение. |
| `ANGIE_ERROR_LOG_JSON_ENABLED` | `yes` | Использовать JSON для error log Angie и сообщений entrypoint. Нетипичное значение возвращает текстовый формат. |
| `ANGIE_WORKER_SHUTDOWN_TIMEOUT` | `8s` | Предел мягкого завершения worker. Положительное число с необязательным `ms`, `s` или `m`; держите меньше grace period контейнера. |
| `CACHE_DIR` | не задана | Только обычный образ: существующий каталог, в котором при старте всё, что не принадлежит `angie`, передаётся `angie`; символические ссылки пропускаются. В непривилегированном образе ничего не делает. |

### Формат лога ошибок

`ANGIE_ERROR_LOG_JSON_ENABLED` переключает сразу две вещи: строку `error_log` в
главном контексте рабочего `angie.conf` и формат собственных строк точки входа
в stderr. Набор полей JSON у лога ошибок задаёт сам Angie, и, в отличие от
форматов лога доступа, шаблона в образе у него нет. Тумблер переписывает только
две поставляемые строки, `error_log /dev/stderr;` и
`error_log /dev/stderr format=json;`. Любую другую строку `error_log` в
подменённом `angie.conf` он не трогает и печатает предупреждение
`31-error-log-json.sh: neither known error_log state found in
/data/conf/angie.conf (customized config?); leaving error_log as is`.

При умолчании `yes` каждая строка точки входа - объект JSON с ключами Angie в
его порядке:

```json
{"time":"2026-10-23T10:50:42Z","level":"info","pid":64,"message":"ACME client 'le' configured: https://acme.invalid/directory, challenge=http, state /data/acme","tags":["entrypoint"]}
```

Отличия от записей самого Angie: `time` с точностью до секунды (busybox `date`
не знает долей секунды), нет `tid` и `connection`, `tags` всегда
`["entrypoint"]` - по нему сборщик и отделяет один источник от другого. Уровни
те же, что у Angie: `error`, `warn`, `notice`, `info`. Кавычки, обратные слэши
и управляющие символы в `message` экранируются, поэтому значение из окружения
строку не ломает; подстроку с кавычкой ищите в экранированном виде (`\"`).
Упавшая итоговая проверка `angie -t` приходит одной записью уровня `error`, её
строки разделены `\n` внутри `message`.

Три вида строк stderr остаются текстом и при `yes`, поэтому сборщику нужен
запасной разбор нераспознанной строки:

- сообщения Angie на этапе разбора конфигурации, до того как действует
  `error_log ... format=json`, например
  `[notice] 7#7: creating implicit client block for "@acme"`;
- вывод утилит оболочки внутри скриптов `/docker-entrypoint.d/`, например
  отказ `cp` или `sed` под `set -e`;
- отказы `angie-ctl`.

При `no` строки точки входа идут в текстовом формате из
[usage.ru.md](usage.ru.md#логи-entrypoint).

### Сжатие и отдача файлов

| Переменная | По умолчанию | Описание |
|---|---|---|
| `ANGIE_BROTLI_ENABLED` | `no` | Загрузить Brotli и включить динамическое сжатие. |
| `ANGIE_BROTLI_STATIC_ENABLED` | `no` | Отдавать готовые `*.br`; включает базовый тумблер Brotli. |
| `ANGIE_GZIP_ENABLED` | `no` | Включить динамическое gzip-сжатие. |
| `ANGIE_GZIP_STATIC_ENABLED` | `no` | Отдавать готовые `*.gz`; включает базовый тумблер gzip. |
| `ANGIE_ZSTD_ENABLED` | `no` | Загрузить Zstandard и включить динамическое сжатие. |
| `ANGIE_ZSTD_STATIC_ENABLED` | `no` | Отдавать готовые `*.zst`; включает базовый тумблер Zstandard. |
| `ANGIE_CHARSET_UTF8_ENABLED` | `no` | Добавлять UTF-8 к поддерживаемым текстовым типам. |
| `ANGIE_EXPIRES_ENABLED` | `no` | Объявить карту сроков по типу содержимого для `snippets/expires-by-type.conf`; сам `expires` не добавляет. |
| `ANGIE_OPEN_FILE_CACHE_ENABLED` | `no` | Кешировать открытые файлы и метаданные; правка файла может стать видна с задержкой. |

Только gzip добавляет `Vary: Accept-Encoding`. При Brotli или Zstandard без
gzip за общим кешем добавьте этот заголовок сами.

### Модули и GeoIP2

| Переменная | По умолчанию | Описание |
|---|---|---|
| `ANGIE_MODSECURITY_ENABLED` | `no` | Загрузить движок ModSecurity. Правила не поставляются. |
| `ANGIE_SUBS_ENABLED` | `no` | Загрузить фильтр подстановок в теле ответа. |
| `GEOIP2_DB_COUNTRY` | не задана | Читаемый абсолютный путь к базе стран MaxMind; включает GeoIP2. Разрешены `A-Za-z0-9._/-`. |

### Логи доступа

По умолчанию access log использует JSON. `ANGIE_LOG_FORMAT_*` регистрирует
формат, но не выбирает его. `ANGIE_LOG_*` регистрирует и выбирает один формат,
отключая другие логи, которыми управляет образ. Имена форматов имеют префикс
`angie_`, поэтому обычные имена вроде `main` свободны для своей конфигурации.

| Переменная | По умолчанию | Описание |
|---|---|---|
| `ANGIE_LOG_FORMAT_EXTENDED` / `ANGIE_LOG_EXTENDED` | `no` | Зарегистрировать / выбрать расширенный формат. |
| `ANGIE_LOG_FORMAT_JSON` / `ANGIE_LOG_JSON` | `no` | Зарегистрировать / выбрать структурированный JSON; выбирается и без неё, когда не задана ни одна `ANGIE_LOG_*`. |
| `ANGIE_LOG_FORMAT_LOGFMT` / `ANGIE_LOG_LOGFMT` | `no` | Зарегистрировать / выбрать logfmt. |
| `ANGIE_LOG_FORMAT_MAIN` / `ANGIE_LOG_MAIN` | `no` | Зарегистрировать / выбрать классический combined-подобный формат. |
| `ANGIE_LOG_FORMAT_MATOMO` / `ANGIE_LOG_MATOMO` | `no` | Зарегистрировать / выбрать формат Matomo. |
| `ANGIE_LOG_FORMAT_JSON_GEOIP2` / `ANGIE_LOG_JSON_GEOIP2` | `no` | Зарегистрировать / выбрать JSON с полем страны; требует GeoIP2. |
| `ANGIE_LOG_FORMAT_LOGFMT_GEOIP2` / `ANGIE_LOG_LOGFMT_GEOIP2` | `no` | Зарегистрировать / выбрать logfmt с полем страны; требует GeoIP2. |

### Проксирование и заголовки ответа

| Переменная | По умолчанию | Описание |
|---|---|---|
| `ANGIE_MAP_WEBSOCKET_ENABLED` | `no` | Объявить карту апгрейда WebSocket. |
| `ANGIE_REAL_IP_FROM` | не задана | Адреса/CIDR доверенных прокси через пробел или запятую; наличие включает real-IP. |
| `ANGIE_REAL_IP_HEADER` | `X-Forwarded-For` | Заголовок или `proxy_protocol`, откуда читать адрес клиента. |
| `ANGIE_REAL_IP_RECURSIVE` | `on` | При `on` обходить цепочку прокси; только `on` или `off`. |
| `ANGIE_SECURITY_HEADERS_ENABLED` | `no` | Добавить `X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options` и `Permissions-Policy`. |
| `ANGIE_HSTS_ENABLED` | `no` | Добавить HSTS только к HTTPS-ответам. До включения прочитайте [security.ru.md](security.ru.md#hsts). |
| `ANGIE_HSTS_MAX_AGE` | `16070400` | Срок HSTS в секундах. Ноль просит клиентов забыть HSTS. |
| `ANGIE_HSTS_INCLUDE_SUBDOMAINS` | `no` | Добавить `includeSubDomains`; включайте, только если все поддомены работают по HTTPS. |
| `ANGIE_CORS_ASSETS_ENABLED` | `no` | Добавить `Access-Control-Allow-Origin: *` шрифтам и изображениям, но не документам и API. |

Доверяйте только известным CIDR прокси: широкий диапазон позволяет подделать
`$remote_addr`. Директива `add_header` не сливается между контекстами: свой
`add_header` в `server`/`location` заменяет унаследованные заголовки.

### Status API и Console Light

| Переменная | По умолчанию | Описание |
|---|---|---|
| `ANGIE_STATUS_API_ENABLED` | `no` | Отдавать read-only JSON `/status/` и Prometheus `/metrics` отдельным слушателем. |
| `ANGIE_STATUS_API_HOST` | `0.0.0.0` | Адрес слушателя статуса. |
| `ANGIE_STATUS_API_PORT` | `8181` | Порт статуса, `1-65535`; не должен совпадать с публичным. |
| `ANGIE_CONSOLE_ENABLED` | `no` | Отдавать Console Light через встроенный catch-all server. |
| `ANGIE_CONSOLE_PATH` | не задана | Обязательный секретный сегмент URL минимум из 16 символов, без `/`. Генерация: `openssl rand -hex 16`. |
| `ANGIE_CONSOLE_HTPASSWD_FILE` | `/etc/angie/custom/console.htpasswd` | Непустой читаемый htpasswd. `none` отключает basic auth и опасен на открытом слушателе. |

Console Light доступна по `http://host:<публичный-порт>/<путь>/`. Поставьте
перед ней TLS. Обычный образ использует порт 80, непривилегированный - 8080.
Рабочие процессы обычного образа должны читать htpasswd.

### ACME

| Переменная | По умолчанию | Описание |
|---|---|---|
| `ANGIE_ACME_ENABLED` | `no` | Настроить встроенный клиент ACME и каталог состояния `/data/acme`. |
| `ANGIE_ACME_CLIENT` | `le` | Имя клиента для переменных `$acme_cert_<имя>`. |
| `ANGIE_ACME_DIRECTORY` | не задана | URL каталога CA. Если не задан, объявите `acme_client` сами в `custom/http-conf.d`. |
| `ANGIE_ACME_EMAIL` | не задана | Необязательная почта учётной записи. |
| `ANGIE_ACME_CHALLENGE` | `http` | `http`, `dns` или `alpn`. Образ готовит только HTTP-сценарий. |
| `ANGIE_ACME_HTTP_PORT` | публичный порт образа | Порт HTTP-проверки: 80 в обычном образе, 8080 в непривилегированном. Непривилегированный вариант запрещает порты ниже 1024. |

Сертификат заказывается только после ссылки на клиента из своего `server`:

```nginx
server {
  listen 80;
  server_name site.example;
  acme le;
  return 301 https://$host$request_uri;
}

server {
  listen 443 ssl;
  server_name site.example;
  ssl_certificate     $acme_cert_le;
  ssl_certificate_key $acme_cert_key_le;
}
```

Для непривилегированного образа используйте внутри 8080/8443 и публикуйте их
как 80/443. Сначала проверяйте на тестовом CA. Состояние ACME содержит ключи и
сертификаты, поэтому подключайте постоянный том к `/data`: tmpfs приведёт к
новому заказу после каждого пересоздания и может исчерпать лимит CA.

## Зависимости между переменными

- `ANGIE_BROTLI_STATIC_ENABLED`, `ANGIE_GZIP_STATIC_ENABLED` и
  `ANGIE_ZSTD_STATIC_ENABLED` сначала включают свой базовый тумблер; достаточно
  задать только переменную static.
- `ANGIE_REAL_IP_HEADER` и `ANGIE_REAL_IP_RECURSIVE` читаются только при
  заданной `ANGIE_REAL_IP_FROM`; без неё они не применяются и не проверяются.
- `ANGIE_LOG_FORMAT_*` только регистрирует формат. `ANGIE_LOG_*` регистрирует и
  выбирает его; если задано несколько, побеждает первый в порядке `EXTENDED`,
  `JSON`, `LOGFMT`, `MAIN`, `MATOMO`, а если ни одного - выбирается JSON.
- Четыре переменные лога `*_GEOIP2` обрабатывает `50-geoip2.sh`, он идёт после
  `40-log.sh`, поэтому `ANGIE_LOG_JSON_GEOIP2` или `ANGIE_LOG_LOGFMT_GEOIP2`
  перекрывает выбор выше; если заданы обе, побеждает logfmt. Пока GeoIP2 не
  поднят, они игнорируются: молча при незаданной `GEOIP2_DB_COUNTRY`, с
  предупреждением `GeoIP database '<путь>' not found` при нечитаемом файле.
  Старт в обоих случаях продолжается.
- Выбор лога через `ANGIE_LOG_*` сначала отключает все остальные `access_log`
  образа, поэтому активен ровно один.
- `ANGIE_STATUS_API_HOST`/`_PORT`, `ANGIE_HSTS_MAX_AGE`/`_INCLUDE_SUBDOMAINS`,
  `ANGIE_CONSOLE_PATH`/`_HTPASSWD_FILE` и все `ANGIE_ACME_*` читаются только при
  включённом тумблере `_ENABLED`. Пока он выключен, негодное значение старт не
  роняет.
- `ANGIE_ACME_CLIENT`, `ANGIE_ACME_CHALLENGE` и `ANGIE_ACME_EMAIL` попадают в
  директиву `acme_client`, а её образ объявляет только при заданной
  `ANGIE_ACME_DIRECTORY`. Без неё они молча не используются: сниппет
  включается с каталогом состояния и портом проверки, но без клиента. Негодные
  `ANGIE_ACME_CLIENT` и `ANGIE_ACME_CHALLENGE` роняют старт и без
  `ANGIE_ACME_DIRECTORY`, `ANGIE_ACME_EMAIL` проверяется только вместе с ней.

## Тома и рабочая раскладка

### `/etc/angie/custom`

Монтируйте пользовательскую конфигурацию только для чтения. Подключаются ровно
три подкаталога:

- `custom/conf.d/*.conf` в основном контексте;
- `custom/http-conf.d/*.conf` в контексте `http`;
- `custom/http.d/*.conf` для виртуальных хостов.

Файлы в корне тома игнорируются. Каталогам нужен бит исполнения, файлам - право
чтения для runtime-UID. Нечитаемая маска может выглядеть как пустой каталог без
ошибки Angie.

### `/data`

`/data` - единственное изменяемое место:

- `/data/conf` пересобирается из `/etc/angie` при каждом старте;
- `/data/tmp` содержит временные файлы без pid-файла;
- `/data/acme` хранит постоянное состояние ACME.

Не монтируйте `/data/conf` отдельно. Точка входа не перезаписывает непустое
чужое дерево и отказывает, если оно принадлежит другому UID. При смене UID
непривилегированного контейнера возьмите новый том или измените владельца
снаружи прикладного контейнера.

```sh
# Stateless-запуск с корнем только для чтения

docker run --read-only --tmpfs /data:mode=1777 6run0/angie:alpine

# Постоянное состояние, обязательно для ACME

docker run --read-only -v angie-data:/data 6run0/angie:alpine
```

Инструкции `VOLUME` нет, поэтому Docker не создаёт анонимные тома.

### `CACHE_DIR` (кеш через bind mount)

Если Angie работает кеширующим прокси, смонтируйте каталог хоста под кеш и
передайте его путь в `CACHE_DIR`, чтобы точка входа исправила владельца:

```sh
docker run -v /host/cache:/var/cache/angie/proxy \
  -e CACHE_DIR=/var/cache/angie/proxy \
  6run0/angie:alpine
```

Исправление работает только в обычном образе: его root-мастер передаёт работу
пользователю worker `angie`. Обход рекурсивный, но символические ссылки он не
разыменовывает и не меняет: иначе ссылка, подложенная в том, отдала бы worker
свою цель, принадлежащую root. В непривилегированном образе мастер и worker
работают под одним UID, поэтому каталог хоста должен заранее принадлежать ему,
см. [troubleshooting.ru.md](troubleshooting.ru.md#4b-том-cache_dir).

Worker читают `auth_basic_user_file` и при обработке запроса, поэтому обычный
образ передаёт `angie` обычные файлы с именем по маске `*htpasswd*` в
`/etc/angie/custom`; другие пути не затрагиваются. На томе только для чтения
chown не проходит, и точка входа лишь предупреждает: сделайте эти файлы
читаемыми для пользователя `angie` на хосте.

## Переиспользуемые сниппеты

Подключайте их из своих `server` или `location`:

| Файл | Контекст | Назначение |
|---|---|---|
| `snippets/healthz.conf` | `server` | `/healthz`, доступный только с loopback. |
| `snippets/proxy-headers.conf` | `location` | Типовые proxy-заголовки и HTTP/1.1. |
| `snippets/status-api-locations.conf` | `server` | `/status/` и `/metrics`; при выключенном тумблере также подключите шаблон Prometheus в `http`. |
| `snippets/deny-dotfiles.conf` | `server` | Вернуть 404 для точечных путей, кроме `/.well-known/`. |
| `snippets/robots-disallow-all.conf` | `server` | Отдать запрещающий `robots.txt`; это рекомендация роботу, не контроль доступа. |
| `snippets/expires-by-type.conf` | `server` или `location` | Применить карту из `ANGIE_EXPIRES_ENABLED`. |
| `snippets/cache-busting.conf` | `server` | Сопоставить версионное имя ресурса с файлом без версии. |
| `snippets/console.conf` | `server` | Автоматически отрисовывается при включении Console Light. |

Относительные include разрешаются от префикса Angie (`/data/conf`), поэтому
одни пути работают во встроенных и пользовательских файлах.

## За балансировщиком или TLS-терминатором

TLS в такой схеме завершается перед контейнером, и образ получает чистый HTTP
на публичном порту (80 у обычного, 8080 у непривилегированного). Три вещи
настраиваются под это отдельно.

Адрес клиента. Без real-IP в `$remote_addr` и в логе доступа стоит адрес
прокси. Задайте `ANGIE_REAL_IP_FROM` подсетью прокси, см.
[Проксирование и заголовки ответа](#проксирование-и-заголовки-ответа).

Схема для приложения. `snippets/proxy-headers.conf` передаёт
`X-Forwarded-Proto $scheme`, а за терминатором `$scheme` всегда `http`, и
приложение строит ссылки и редиректы на `http://`. Схему от терминатора берёт
карта, а набор заголовков тогда пишется целиком вместо подключения
`proxy-headers.conf`: вторая строка `proxy_set_header X-Forwarded-Proto` на том
же уровне не заменяет первую, оба значения складываются в один заголовок.

```nginx
# /etc/angie/custom/http-conf.d/100-forwarded-proto.conf
map $http_x_forwarded_proto $forwarded_proto {
  default $scheme;
  https   https;
}
```

```nginx
# внутри своего location
proxy_http_version 1.1;
proxy_set_header Host $http_host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $remote_addr;
proxy_set_header X-Forwarded-Proto $forwarded_proto;
proxy_set_header X-Request-ID $request_id;
proxy_pass http://app:3000;
```

Карта верит заголовку от любого клиента, который дотянется до публичного порта
мимо терминатора: не публикуйте этот порт в обход него.

HSTS и редиректы. `ANGIE_HSTS_ENABLED` отдаёт заголовок только при `$scheme`
`https`, поэтому за терминатором не отдаёт ничего; HSTS принадлежит
терминатору. Редиректы, которые строит сам Angie (слэш в конце каталога), по
умолчанию абсолютные, со схемой и портом слушателя: `http://<хост>/...` у
обычного образа, `http://<хост>:8080/...` у непривилегированного.
`absolute_redirect off;` в своём `server {}` делает их относительными.

## Переменные, которые объявляет образ

Имена ниже заняты поставленным деревом. Переменная с тем же именем, объявленная
в `/etc/angie/custom`, заменяет переменную образа без ошибки: `angie -t`
проходит, побеждает пользовательское объявление. Например,
`map $host $_stock_loopback { default 1; }` в `custom/http-conf.d` заставляет
`/healthz` отвечать удалённым клиентам `ok` вместо `404` (измерено на образе
1.12.4, 2026-10-23).

| Переменная | Где объявлена | Когда есть |
|---|---|---|
| `$_stock_loopback` | `http-conf.d/010-common.conf` | всегда |
| `$_stock_time_ms` | `http-conf.d/010-common.conf` | всегда |
| `$_stock_connection_upgrade` | `060-map-websocket.conf` | `ANGIE_MAP_WEBSOCKET_ENABLED` |
| `$_stock_geoip2_country_code` | `025-geoip2.conf` | GeoIP2 поднят |
| `$_stock_expires` | `023-expires.conf` | `ANGIE_EXPIRES_ENABLED` |
| `$_stock_cors_assets` | `057-cors-assets.conf` | `ANGIE_CORS_ASSETS_ENABLED` |
| `$_stock_x_frame_options` | `055-security-headers.conf` | `ANGIE_SECURITY_HEADERS_ENABLED` |
| `$_stock_referrer_policy` | `055-security-headers.conf` | `ANGIE_SECURITY_HEADERS_ENABLED` |
| `$_stock_permissions_policy` | `055-security-headers.conf` | `ANGIE_SECURITY_HEADERS_ENABLED` |
| `$_stock_hsts` | `056-hsts.conf` | `ANGIE_HSTS_ENABLED` |

Своим переменным приставку `$_stock_` не давайте: следующая версия образа может
занять это имя, и тогда ваше объявление молча заменит переменную образа.

## Порты

| Вариант | Публичный HTTP | Пользователь по умолчанию |
|---|---:|---|
| Обычный Alpine/Debian | 80 | root-мастер, worker `angie` |
| Непривилегированный Alpine/Debian | 8080 | uid/gid 65532; поддержан произвольный UID |

Необязательный слушатель статуса использует 8181 и автоматически не
публикуется.

TLS-слушателя нет, и порта TLS нет в `EXPOSE`: сертификат и имя хоста приходят
от пользователя. `listen 443 ssl` (обычный образ) или `listen 8443 ssl`
(непривилегированный, публикуется как `-p 443:8443`) объявляется в
`custom/http.d`. Сможет ли мастер не от root занять порт ниже 1024, зависит от
runtime: Docker 20.10 и новее выставляет `net.ipv4.ip_unprivileged_port_start=0`,
Kubernetes и голый runc - нет. Поэтому `listen 443` в непривилегированном
образе не переносим, а `ANGIE_ACME_HTTP_PORT` ниже 1024 там отвергается как
политика образа.

Встроенный перехватчик слушает `0.0.0.0` и `[::]` публичного порта. На ядре
без IPv6 (нет `/proc/net/if_inet6`) точка входа удаляет строку `[::]` из
рабочей копии и пишет `notice`
`IPv6 is unavailable; the built-in listener serves 0.0.0.0:<port> only`. Ваши
строки `listen [::]` она не трогает, и на таком ядре они роняют старт, см.
[troubleshooting.ru.md](troubleshooting.ru.md#26-ipv6-is-unavailable-в-журнале-старта).

Сервером по умолчанию на публичном порту перехватчик становится по порядку
объявления, без флага `default_server`, поэтому `listen 80 default_server` (или
`8080 default_server`) в `custom/http.d` принимается. Три следствия:

- забрав умолчание, вы забираете и запросы `/healthz` без имени
  `healthz-catchall.invalid`. `HEALTHCHECK` образа посылает это имя и
  по-прежнему попадает во встроенную точку; своя проба без него попадёт в ваш
  сервер;
- флаг ставится на обе строки `listen`: умолчание выбирается отдельно для
  `0.0.0.0` и `[::]`, и одна строка оставит IPv6-клиентам `444` образа;
- без флага пользовательский `server {}` умолчанием не станет ни из
  `custom/http.d`, ни из `custom/http-conf.d`: оба подключаются после
  встроенного виртуального хоста.

## Разрешение DNS-имён

С Angie 1.12.0 директива `resolver` в модулях `http` и `stream` по умолчанию
имеет значение `conf` (документация Angie): DNS-серверы берутся из
`/etc/resolv.conf`, в контейнере это встроенный DNS Docker, и файл
перечитывается при изменении. Динамическое разрешение имён (`proxy_pass` с
переменными, `server ... resolve` в апстримах) работает без строки `resolver`
в виртуальных хостах.

`resolver off;` в своей конфигурации выключает его, а вместе с ним и
встроенный клиент ACME, которому имя каталога CA нужно разрешать во время
работы, см.
[troubleshooting.ru.md](troubleshooting.ru.md#22-ssl-alert-number-80-при-включённом-acme).
Собственная строка `resolver` в `custom/http-conf.d` при включённом ACME
принимается: сниппет ACME своего `resolver` не объявляет.

## Аргументы сборки и встроенный helper

Аргументы передаются в `docker build` через `--build-arg`; полные команды
сборки - в [usage.ru.md](usage.ru.md#сборка-из-исходников). Конвейер выпуска
передаёт только `ANGIE_VERSION`, `IMAGE_VERSION` и `VCS_REF`, одинаково обеим
целям; остальные берут умолчание Dockerfile.

### Версия Angie и метаданные образа (`alpine/Dockerfile`, `debian/Dockerfile`)

| Аргумент | По умолчанию | Описание |
|---|---|---|
| `ANGIE_VERSION` | `1.12.4` | Версия ядра Angie и модулей; закреплена оператором `=~` в apk (Alpine) или сведена к одной точной версии пакета через `apt-cache madison` (Debian). Теги выпуска обязаны с ней совпадать. |
| `ANGIE_CONSOLE_VERSION` | `1.9.0` | Версия пакета Console Light; у него свой цикл выпусков. |
| `IMAGE_VERSION` | `dev` | Значение метки `org.opencontainers.image.version`, тег образа без суффикса варианта. |
| `VCS_REF` | пусто | Коммит источника в метке `org.opencontainers.image.revision`. |

Образ несёт метки `org.opencontainers.image.title`, `description`, `source`,
`url`, `documentation`, `licenses`, `version`, `revision` и `base.name`
(аргумент базового образа дистрибутива, в обеих целях), плюс
`software.angie.version`; `title` и `description` называют цель.
`IMAGE_VERSION` и `VCS_REF` объявлены прямо перед последним `LABEL` каждой
цели, поэтому их смена не сбрасывает общую стадию `runtime`.
Читаются командой `docker inspect --format '{{json .Config.Labels}}' <image>`.

### Источники пакетов (`alpine/Dockerfile`, `debian/Dockerfile`)

| Аргумент | По умолчанию | Описание |
|---|---|---|
| `ANGIE_MIRROR` | `https://download.angie.software/angie` | Зеркало пакетов Angie; к нему дописывается `/alpine/v<ветка>/main` или `/debian/<версия>`. Из него ставятся только пакеты Angie: в Alpine репозиторий помечен тегом `@angie`, в Debian `/etc/apt/preferences.d/angie` даёт прочим пакетам с его хоста приоритет `-1` (сравнение по хосту без числового порта; не сработавший пин роняет сборку строкой `apt pin 'origin <host>' does not hold the Angie repository at priority -1`). |
| `ANGIE_SIGNING_KEY_URL` | ключ на `angie.software` | Откуда скачивается ключ подписи пакетов. |
| `ANGIE_SIGNING_KEY` | путь в хранилище ключей дистрибутива | Куда кладётся ключ. |
| `ANGIE_SIGNING_KEY_SHA256` | отпечаток ключа по умолчанию, свой у каждого Dockerfile | Ожидаемый sha256 скачанного ключа. Несовпадение роняет сборку строкой `signing key sha256 mismatch for <url>` до того, как ключу начинают доверять. После смены ключа поставщиком пересчитывается командой `curl -fsSL "$ANGIE_SIGNING_KEY_URL" \| sha256sum`; меняется вместе с `ANGIE_SIGNING_KEY_URL`. |

### Только Alpine (`alpine/Dockerfile`)

| Аргумент | По умолчанию | Описание |
|---|---|---|
| `ALPINE_BASE_IMAGE` | `alpine:3.24`, закреплён по digest | Базовый образ. |
| `ALPINE_MIRROR` | `https://dl-cdn.alpinelinux.org/alpine` | Зеркало пакетов Alpine. `/etc/apk/repositories` пишется заново: `main` и `community` ветки базового образа на этом зеркале плюс репозиторий из `ANGIE_MIRROR`. Недоступный адрес роняет первый же `apk`. |

### Только Debian (`debian/Dockerfile`)

| Аргумент | По умолчанию | Описание |
|---|---|---|
| `DEBIAN_BASE_IMAGE` | `debian:trixie-slim`, закреплён по digest | Базовый образ. |
| `DEBIAN_MIRROR` | `http://deb.debian.org/debian` | Зеркало APT для наборов выпуска и `-updates`. `/etc/apt/sources.list.d/debian.sources` пишется заново, `sources.list` прежнего формата удаляется. Недоступный адрес роняет первый же `apt-get update`. |
| `DEBIAN_SECURITY_MIRROR` | `http://deb.debian.org/debian-security` | Зеркало APT для набора `-security`, пишется в тот же файл. |
| `ANGIE_SOURCE_LIST` | `/etc/apt/sources.list.d/angie.sources` | Куда пишется источник APT репозитория Angie. |

Зеркала Debian по умолчанию идут по `http` намеренно: `debian:trixie-slim` не
несёт `ca-certificates`, а первый `apt-get update` идёт до их установки, поэтому
`https`-зеркало падает на нём с `certificate verify failed`. Целостность APT
держится на подписях GPG репозитория, а не на транспорте. Хост зеркала Angie не
должен совпадать с хостами `DEBIAN_MIRROR` и `DEBIAN_SECURITY_MIRROR`: пин `-1`
скроет и пакеты Debian, и сборка упадёт на их установке. У Alpine такого
ограничения нет: его база несёт `ca-certificates-bundle`, отсюда умолчание
`https`.

### Непривилегированная цель (`--target unprivileged`)

| Аргумент | По умолчанию | Описание |
|---|---|---|
| `APP_USER` | `app` | Имя выделенного пользователя ОС. |
| `APP_GROUP` | `app` | Имя его группы. |
| `APP_UID` | `65532` | uid учётной записи по умолчанию (`USER` числовой). |
| `APP_GID` | `65532` | gid учётной записи по умолчанию. |

`angie-ctl` хранится в `rootfs/usr/local/bin/angie-ctl` и не клонируется при
сборке. Текущая проверенная ревизия исходника:
`a69c1d102ec99a893a11f08015ea150c1e287482`; SHA-256 встроенного файла:
`2341a4a9f811a4f9fa463506149bd5a91dcd5a9ad2cb305473c87095bf247830`.
Ревизия взята из
[репозитория angie-ctl](https://github.com/6RUN0/angie-ctl); ни один workflow
её не отслеживает, поэтому обновление требует ручной проверки исходника,
запуска тестов, обновления checksum и записи в changelog.

---

English: [configuration.md](configuration.md).
