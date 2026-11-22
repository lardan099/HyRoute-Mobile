# HyRoute Mobile

Общее Go-ядро HyRoute для Android и iOS. Код вынесен из рабочей копии
настольного HyRoute на базе коммита `07feef9`.

- Импорт и обновление подписок Hysteria 2 и VLESS с сохранением ID серверов.
- Локальные правила по домену, IP, порту и протоколу, включая цепочки VPN-профилей.
- Android-адаптер split tunneling и назначения VPN-профиля по пакету приложения.

Установочные сборки поддерживают импорт и сохранение профилей и настройку правил.
Подключение VPN-туннелей ещё в разработке.

## Проверка

```sh
go test ./...
go vet ./...
```

Ручной workflow **Mobile Go bindings** собирает AAR и адаптер для Android,
а также XCFramework для iOS.

## Интерфейс

Клиент Android на Flutter находится в `app/`. Для веб-предпросмотра и
Flutter-тестов нативные привязки не нужны.

```sh
cd app
flutter pub get
flutter test
flutter run -d chrome
```

Клиент iOS 16+ на SwiftUI собирается из `app/ios/HyRoute.xcodeproj`.
Поместите `HyRouteCore.xcframework` той же ревизии в `dist/`.
Сборка SwiftUI использует прежний идентификатор приложения и хранилище
Keychain и сохраняет данные при обновлении с той же подписью.
Для сборки Android с импортом нужен `dist/HyRouteCore.aar`.
Оба клиента передают в интерфейс сведения о профилях без ключей и ссылок подписок.

Для тестовой сборки включите `build_apps` в workflow **Mobile Go bindings**.
Для сборки одной платформы укажите её в поле `platform`. Workflow выдаёт
APK для Android и IPA для iPhone. Для установки IPA требуется подпись Apple.
