# HyRoute Mobile

Общее Go-ядро HyRoute для Android и iOS. Код вынесен из рабочей копии
настольного HyRoute на базе коммита `07feef9`.

- Импорт и обновление подписок Hysteria 2 и VLESS с сохранением ID серверов.
- Локальные правила по домену, IP, порту и протоколу, включая цепочки VPN-профилей.
- Android-адаптер split tunneling и назначения VPN-профиля по пакету приложения.

Нативные VPN-туннели и установочные приложения ещё в разработке.

## Проверка

```sh
go test ./...
go vet ./...
```

Ручной workflow **Mobile Go bindings** собирает AAR и адаптер для Android,
а также XCFramework для iOS.

## Интерфейс

Клиент Flutter находится в `app/`. Для веб-предпросмотра и тестов
нативные привязки не нужны.

```sh
cd app
flutter pub get
flutter test
flutter run -d chrome
```

Для импорта подписок на телефоне положите артефакт той же ревизии
в `dist/HyRouteCore.aar` для Android или `dist/HyRouteCore.xcframework`
для iOS. Клиент вызывает Go-ядро через платформенный канал. UI получает
только сведения для показа. Изменения правил и выбранный профиль
пока хранятся в памяти на время работы приложения.

Для тестовой сборки включите `build_apps` в workflow **Mobile Go bindings**.
Для сборки одной платформы укажите её в поле `platform`. Workflow выдаёт
APK для Android и IPA для iPhone. Для установки IPA требуется подпись Apple.
