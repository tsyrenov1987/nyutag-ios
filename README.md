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
Файл `App/Catalogue/nyutag-catalogue.txt` с путём до входа в репозиторий не входит (рядом лежит `.example`).

## Сборка приложения

Проект Xcode генерирует свой скрипт на Python 3 (только стандартная библиотека), сторонних генераторов нет.
`Nyutag.xcodeproj` лежит в репозитории; после добавления или переименования файлов в `App/` перегенерируйте его:

```sh
python3 tools/gen-xcodeproj.py
xcodebuild -project Nyutag.xcodeproj -scheme Nyutag -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Цели: `Nyutag` (приложение) и `NyutagNSE` (расширение уведомлений, встроено в приложение). Обе зависят от `NyutagCore`
через локальный пакет в корне репозитория. `App/Catalogue` подключена как папка: если `nyutag-catalogue.txt` нет, сборка
проходит, в бандл попадает только `.example`.
