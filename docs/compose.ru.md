# Примеры Docker Compose

Файл `docker-compose.yml` в корне репозитория ориентирован на **локальную
сборку** образов (`build: context: .`) с закомментированными портами.
Примеры ниже используют **публикуемые образы** с Docker Hub / GHCR и
запускаются без клонирования репозитория и локальной сборки.

Доступные теги:

| Тег | База | Порт | Пользователь |
|-----|------|------|--------------|
| `alpine` / `latest` | Alpine | 80 | root |
| `debian` | Debian | 80 | root |
| `alpine-unprivileged` | Alpine | 8080 | uid 65532 |
| `debian-unprivileged` | Debian | 8080 | uid 65532 |

Зеркало GHCR: `ghcr.io/6run0/docker-angie:<tag>`

---

## Минимальный пример

Один сервис, запускается без дополнительной конфигурации. Встроенный
`HEALTHCHECK` (порт 80) срабатывает автоматически; блок `healthcheck:` ниже
переопределяет его только для демонстрации синтаксиса compose -- его можно
полностью опустить.

```yaml
services:
  angie:
    image: 6run0/angie:alpine
    container_name: angie
    restart: unless-stopped
    ports:
      - "8080:80"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost/healthz"]
      interval: 30s
      timeout: 3s
      start_period: 5s
      retries: 3
```

```bash
docker compose up
```

Сервер доступен по адресу `http://localhost:8080/`.

---

## Реалистичный пример с тумблерами функций и пользовательской конфигурацией

Монтируйте конфиги виртуальных хостов и сниппеты в `/etc/angie/custom`
(только для чтения), а встроенные функции включайте через переменные окружения
`ANGIE_*`. Путь `./angie-config` -- это каталог, который вы создаёте рядом со
своим `compose.yml`; он не встроен в образ.

```yaml
networks:
  front:

services:
  angie:
    image: 6run0/angie:alpine
    container_name: angie
    restart: unless-stopped
    networks:
      - front
    ports:
      - "80:80"
    volumes:
      # Здесь размещаются конфиги виртуальных хостов, SSL-сертификаты
      # и пользовательские сниппеты.
      # Флаг :ro запрещает контейнеру записывать что-либо на хост.
      - ./angie-config:/etc/angie/custom:ro
    environment:
      ANGIE_BROTLI_ENABLED: "yes"
      ANGIE_GZIP_ENABLED: "yes"
      ANGIE_MAP_WEBSOCKET_ENABLE: "yes"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost/healthz"]
      interval: 30s
      timeout: 3s
      start_period: 5s
      retries: 3
```

Допустимые значения «включено» для всех тумблеров `ANGIE_*`: `yes`, `on`,
`1`, `true`, `enable`, `enabled`. Любое другое значение (или отсутствие
переменной) оставляет функцию выключенной.

Полный справочник по переменным окружения -- в `../README.md`.

---

## Rootless-вариант (без привилегий)

Образы `-unprivileged` слушают порт **8080** и по умолчанию работают под
uid/gid `65532` -- без root, без `CAP_NET_BIND_SERVICE`. Ключ `user:` ниже
избыточен (образ уже устанавливает `USER 65532`), но делает намерение явным
для аудиторов и упрощает перенос в k8s с `runAsUser`.

```yaml
services:
  angie:
    image: 6run0/angie:alpine-unprivileged
    container_name: angie
    user: "65532:65532"
    restart: unless-stopped
    ports:
      - "8080:8080"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:8080/healthz"]
      interval: 30s
      timeout: 3s
      start_period: 5s
      retries: 3
```

Переопределить пользователя без пересборки:

```bash
docker compose run --user 1000:1000 angie
```

Любой uid, имеющий права на запись в `/etc/angie/http-conf.d` и
`/etc/angie/modules.d` (принадлежат `65532` в образе), может переключать
функции через `ANGIE_*` при старте. Чужой uid без таких прав молча
использует встроенные настройки по умолчанию.

---

## Справка по портам healthcheck

| Вариант образа | Порт контейнера | URL healthcheck |
|----------------|----------------|-----------------|
| `alpine` / `debian` | 80 | `http://127.0.0.1/healthz` |
| `alpine-unprivileged` / `debian-unprivileged` | 8080 | `http://127.0.0.1:8080/healthz` |

Оба образа содержат инструкцию `HEALTHCHECK`; блок `healthcheck:` в compose
переопределяет её только если нужны другие параметры тайминга. Чтобы
использовать значения из образа, просто не указывайте ключ `healthcheck:`.

---

- [English](compose.md) | [Русский](compose.ru.md)
- [Использование и конфигурация](../README.md)
