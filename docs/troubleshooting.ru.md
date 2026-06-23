# Устранение неполадок

Типичные проблемы, их причины и способы устранения.

См. также: [../README.md](../README.md)

---

## 1. Порт занят (`bind: address already in use`)

**Симптом.** Контейнер сразу завершается с ошибкой:

```text
nginx: [emerg] bind() to 0.0.0.0:80 failed (98: Address already in use)
```

**Причина.** На хосте другой процесс уже слушает указанный порт.

**Решение.** Привяжите другой порт хоста:

```sh
docker run -p 8081:80 6run0/angie:alpine
```

Чтобы найти процесс, занявший порт:

```sh
# Linux
ss -tlnp sport = :80
# или
lsof -i :80
```

Вариант `unprivileged` слушает внутри контейнера на порту 8080 - привязывайте
соответственно:

```sh
docker run -p 8081:8080 6run0/angie:alpine-unprivileged
```

---

## 2. На любой запрос приходит 444 / соединение закрывается без ответа

**Симптом.** `curl http://localhost/` завершается с сообщением "Empty reply from
server" или ошибкой 52. Браузер показывает "соединение сброшено".

**Причина.** Это штатное поведение по умолчанию. Встроенный блок `server`
возвращает 444 (закрытие соединения без ответа) для любого запроса, у которого
не нашлось совпадения по `server_name`. Пользовательский виртуальный хост ещё
не добавлен.

**Решение.** Добавьте собственный server-блок через том `/etc/angie/custom`:

```sh
# /path/to/custom/http.d/mysite.conf
server {
  listen 80;
  server_name mysite.example.com;
  location / { return 200 "hello\n"; }
}
```

```sh
docker run -p 80:80 \
  -v /path/to/custom:/etc/angie/custom:ro \
  6run0/angie:alpine
```

**Health check не затронут.** `GET /healthz` всегда возвращает `ok` (200) по
loopback-интерфейсу независимо от того, настроен ли пользовательский хост.

---

## 3. Тумблер `ANGIE_*` не применяется

### 3a. Контейнер перезапущен командой `restart`, а не пересоздан

**Симптом.** Вы обновили переменную окружения и выполнили `docker restart
<container>`. Функция по-прежнему не активна.

**Причина.** `docker restart` сохраняет тот же контейнер и те же переменные
окружения, что были зафиксированы при `docker run`. Entrypoint-скрипты
перезапускаются при каждом старте, но видят исходное окружение, а не
обновлённое.

**Решение.** Удалите и пересоздайте контейнер:

```sh
docker rm -f mycontainer
docker run ... -e ANGIE_BROTLI_ENABLED=1 --name mycontainer 6run0/angie:alpine
```

В Compose достаточно `docker compose up` (не `restart`) - он пересоздаёт
контейнеры, у которых изменилось окружение.

### 3b. Запуск unprivileged-варианта со сторонним uid

**Симптом.** Образ запущен с `--user <uid>`, где `<uid>` отличается от
встроенного пользователя `app` (uid/gid 65532). Тумблеры молча пропускаются,
контейнер стартует с конфигурацией, зашитой при сборке.

**Причина.** Entrypoint-скрипты вызывают `angie-ctl`, чтобы создать симлинки
в `/etc/angie/*.d`. Эти директории при сборке передаются во владение
uid/gid 65532. Другой uid не имеет права записи, поэтому
`skip_toggle_unless_writable` в `docker-entrypoint-common.sh` обнаруживает
недоступные директории, выводит предупреждение и пропускает тумблер без
прерывания запуска.

**Решение.** Используйте uid по умолчанию:

```sh
docker run --user 65532:65532 6run0/angie:alpine-unprivileged
```

Либо пересоберите unprivileged-образ с нужными значениями:

```sh
docker build \
  --build-arg APP_UID=<your-uid> \
  --build-arg APP_GID=<your-gid> \
  -f alpine/Dockerfile.unprivileged .
```

---

## 4. Ошибки доступа к смонтированным томам

### 4a. Том `/etc/angie/custom`

**Симптом.** Angie не запускается или выводит ошибки доступа при чтении
конфигурационных файлов из `/etc/angie/custom`.

**Причина.** Директория монтируется внутрь контейнера только для чтения, но
файлы на хосте недоступны runtime-пользователю контейнера.

**Решение.** Убедитесь, что путь на хосте доступен для чтения нужным
пользователем:

- **Обычный образ (запускается от root):** путь должен быть доступен для
  чтения всем (`chmod o+r`) или принадлежать root.
- **Unprivileged-образ (uid/gid 65532 по умолчанию):** передайте директорию
  во владение uid 65532 или разрешите чтение всем:

  ```sh
  chown -R 65532:65532 /path/to/custom
  docker run --user 65532:65532 \
    -v /path/to/custom:/etc/angie/custom:ro \
    6run0/angie:alpine-unprivileged
  ```

### 4b. Том `CACHE_DIR`

**Симптом.** Angie выводит ошибки `chown` или прокси-кэш не работает во время
выполнения.

**Причина.** Когда задана переменная `CACHE_DIR`, скрипт
`90-fix-cache-permission.sh` при старте рекурсивно выполняет `chown angie:
<CACHE_DIR>`. Это требует, чтобы контейнер работал от root; в unprivileged-
варианте скрипт молча пропускается.

**Решение.** Для обычного образа убедитесь, что смонтированная директория
доступна для записи контейнеру:

```sh
docker run \
  -e CACHE_DIR=/var/cache/angie/proxy \
  -v /host/cache:/var/cache/angie/proxy \
  6run0/angie:alpine
```

Для unprivileged-образа заранее измените владельца на хосте:

```sh
chown -R 65532:65532 /host/cache
docker run --user 65532:65532 \
  -e CACHE_DIR=/var/cache/angie/proxy \
  -v /host/cache:/var/cache/angie/proxy \
  6run0/angie:alpine-unprivileged
```

---

## 5. Модуль GeoIP2 не работает

**Симптом.** Переменные GeoIP2 (`$geoip2_data_country_code` и др.) пусты или
модуль не загружен.

**Причина.** Скрипт `50-geoip2.sh` активирует GeoIP2 только если
`GEOIP2_DB_COUNTRY` указывает на существующий и читаемый внутри контейнера
файл. Если путь неверный, файл не смонтирован или недоступен, скрипт выводит
предупреждение и завершается с кодом 0, не включая модуль.

```sh
# Поведение скрипта (rootfs/docker-entrypoint.d/50-geoip2.sh):
# - GEOIP2_DB_COUNTRY не задана    -> пропуск без сообщений
# - путь не существует или не читаем -> предупреждение, модуль не загружается
# - путь содержит символы вне [A-Za-z0-9._/-] -> фатальная ошибка, запуск прерывается
```

**Решение.** Смонтируйте базу данных MaxMind `.mmdb` и укажите путь внутри
контейнера:

```sh
docker run \
  -e GEOIP2_DB_COUNTRY=/geoip/GeoLite2-Country.mmdb \
  -v /host/path/to/GeoLite2-Country.mmdb:/geoip/GeoLite2-Country.mmdb:ro \
  6run0/angie:alpine
```

Проверьте, что модуль загрузился:

```sh
docker exec <container> angie -T 2>/dev/null | grep geoip2
```

---

## 6. ModSecurity включён, но ничего не блокирует

**Симптом.** Установлена переменная `ANGIE_MODSECURITY_ENABLED=1`, Angie
запускается, но вредоносные запросы проходят без блокировки.

**Причина.** Образ загружает динамический модуль ModSecurity
(`libmodsecurity`) и включает коннектор для Angie, однако набор правил не
поставляется в комплекте. Без правил WAF-движок работает в режиме обнаружения
без каких-либо сигнатур для сопоставления и ничего не блокирует.

**Решение.** Подключите внешний набор правил, например OWASP Core Rule Set
(CRS):

```sh
docker run \
  -e ANGIE_MODSECURITY_ENABLED=1 \
  -v /host/path/to/crs:/etc/angie/modsec/crs:ro \
  6run0/angie:alpine
```

В конфигурации ModSecurity файлы правил подключаются через `Include`. См.
[limitations.md](limitations.md) для полного списка ограничений WAF и
[configuration.md](configuration.md) для описания тумблера
`ANGIE_MODSECURITY_ENABLED`.

---

## 7. Контейнер убит OOM / нехватка памяти

**Symptom.** Контейнер завершается со статусом 137 (убит SIGKILL), в журнале
ядра OOM killer виден мастер- или рабочий процесс Angie.

**Причина.** Конфигурация по умолчанию рассчитана на высоконагруженное
production-окружение:

- `worker_rlimit_nofile 65536` - максимальное число открытых файловых
  дескрипторов на рабочий процесс;
- `worker_connections 32768` - максимальное число одновременных соединений на
  рабочий процесс.

При ограничении памяти Docker это может исчерпать адресное пространство
контейнера или вызвать OOM killer ещё до того, как очереди соединений реально
заполнятся.

**Решение.** Уменьшите лимиты через том `custom`:

```sh
# /path/to/custom/angie.conf или сниппет в custom/http.d/
worker_rlimit_nofile 8192;
events {
  worker_connections 4096;
}
```

```sh
docker run \
  -m 256m \
  -v /path/to/custom:/etc/angie/custom:ro \
  6run0/angie:alpine
```

Либо увеличьте лимит памяти контейнера в соответствии с ожидаемой нагрузкой.

---

## 8. `exec format error` / неверная архитектура

**Симптом.** Контейнер немедленно завершается с ошибкой:

```text
standard_init_linux.go:228: exec user process caused "exec format error"
```

**Причина.** Docker скачал образ для архитектуры, отличной от архитектуры
хоста (например, arm64-образ на amd64-хосте или наоборот). Образ поддерживает
`linux/amd64` и `linux/arm64`.

**Решение.** Укажите архитектуру явно:

```sh
docker run --platform linux/amd64 6run0/angie:alpine
docker run --platform linux/arm64 6run0/angie:alpine
```

При сборке multi-arch образа через Buildx указывайте
`--platform linux/amd64,linux/arm64`.

---

## 9. Контейнер сразу падает при запуске (fail-fast)

**Симптом.** `docker ps` никогда не показывает контейнер как работающий.
`docker logs <container>` содержит ошибку одного из entrypoint-скриптов.

**Причина.** Entrypoint выполняет все исполняемые файлы `*.sh` в директории
`/docker-entrypoint.d/` в лексикографическом порядке. Если хотя бы один
скрипт завершается с ненулевым кодом, оболочка (`set -e` активен) прерывает
выполнение и контейнер завершается до запуска Angie. Типичные подпричины:

- Пользовательский скрипт, смонтированный в `/docker-entrypoint.d/`, содержит
  ошибку или завершается с ненулевым кодом.
- Скрипт не отмечен как исполняемый (entrypoint выводит предупреждение и
  пропускает его, что может замаскировать отсутствие нужной функции).
- Обычный образ запущен от пользователя, не являющегося root (см. раздел 3b).

**Решение.** Просмотрите журнал:

```sh
docker logs <container>
```

Упавший скрипт и код завершения выводятся явно:

```text
<timestamp> [error] 99-zz-fail.sh failed with exit 7, aborting startup
```

Проверьте код завершения, shebang и бит исполняемости:

```sh
ls -la /path/to/script.sh
# должно быть -rwxr-xr-x
```

Если скрипт не исполняемый, предупреждение будет таким:

```text
<timestamp> [warn] ignoring /docker-entrypoint.d/myscript.sh, not executable
```

Установите бит и перезапустите: `chmod +x /path/to/script.sh`.

---

## 10. Автонастройка `worker_processes` не сработала (read-only FS)

**Симптом.** Задана переменная
`ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE=1`, но `worker_processes` в
`angie.conf` остаётся значением `auto`, а не конкретным числом.

**Причина.** Скрипт `30-tune-worker-processes.sh` перезаписывает
`/etc/angie/angie.conf` командой `sed -i`. Если файловая система смонтирована
только для чтения (например, через `--read-only` или read-only bind-mount,
покрывающий `/etc/angie`), зондирование через `touch` в начале скрипта
обнаруживает неизменяемую FS, выводит ошибку и завершается с кодом 0, не
модифицируя файл.

Angie продолжает запускаться с `worker_processes auto`, при котором
мастер-процесс определяет число воркеров самостоятельно. Скрипт автонастройки
предоставляет более точное значение с учётом cgroup (cpuset и квота CPU для v1
и v2), что актуально для контейнеров с ограниченным CPU.

При перезапуске контейнера с персистентным writable-слоем скрипт применяет
настройку только один раз: он обнаруживает свой собственный sentinel-комментарий
и пропускает выполнение при последующих стартах.

**Решение.** Либо уберите ограничение read-only на `/etc/angie`, либо
смиритесь с `worker_processes auto` и положитесь на встроенное определение
Angie. См. [configuration.md](configuration.md) для описания переменной
`ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` и [limitations.md](limitations.md)
для описания ограничений файловой системы.

---

[English](troubleshooting.md) |
[Конфигурация](configuration.md) |
[Безопасность](security.md) |
[Использование](usage.md) |
[Назад к README](../README.md)
