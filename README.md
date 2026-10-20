# Нютаг для iOS

Мессенджер для бурятского сообщества: сервер `nyutag.chat` (протокол Matrix), вход по приглашению, интерфейс на бурятском и русском.

Клиент написан с нуля на Swift. В проекте нет сторонних библиотек и пакетов: только системные фреймворки Apple
(Foundation, SwiftUI, CryptoKit, CommonCrypto, SQLite из состава ОС, Network, AVFoundation, CallKit, PushKit)
и наш собственный транспортный модуль `FarvaterCore` (Go, репозиторий [farvater-core](https://github.com/tsyrenov1987/farvater-core)).

## Состав

| Модуль | Что делает |
| --- | --- |
| `NyutagCore` | HTTP-слой клиент-серверного API, вход, `/sync`, хранилище SQLite, события комнат, доверие своему CA |
| `NyutagCrypto` | Сквозное шифрование: собственная реализация Olm и Megolm на CryptoKit и CommonCrypto |
| `App` | Приложение, расширение уведомлений (появятся следующими) |

## Сборка и тесты

```sh
swift build
swift test
```

Живые тесты против ядра включаются переменными окружения, см. `tools/test-env.sh`.
Файл `App/Resources/nyutag-catalogue.txt` с путём до входа в репозиторий не входит (рядом лежит `.example`).
