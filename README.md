# HyRoute Mobile

Общее Go-ядро HyRoute для Android и iOS. Код вынесен из рабочей копии
настольного HyRoute на базе коммита `07feef9`.

- Импорт и обновление подписок Hysteria 2 и VLESS с сохранением ID серверов.
- Локальные правила по домену, IP, порту и протоколу, включая цепочки VPN-профилей.
- Android-адаптер split tunneling и назначения VPN-профиля по пакету приложения.

Клиенты запускают системный VPN через `VpnService` на Android и Packet Tunnel
на iOS. Встроенное ядро поддерживает VLESS и Hysteria 2, включая профили
автовыбора VLESS. Клиент применяет правила из своего редактора. После правки
профиля или правил переподключите VPN.

В журнале на главной сохраняются последние события VPN и замеров, включая
этап сбоя. На экране подписки можно измерить задержку отдельного сервера,
узлов «Автовыбора» или всей подписки. Замер выполняет HTTPS-запрос через
каждый сервер и показывает время до ответа `204`.

Сетевое ядро включает [Xray-core v26.10.31](https://github.com/XTLS/Xray-core/tree/a4a3dff5b20c)
под [MPL 2.0](https://github.com/XTLS/Xray-core/blob/a4a3dff5b20c/LICENSE).

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
APK для Android и IPA для iPhone с версией в имени, например
`HyRoute-Android-debug-0.3.1.apk` и `HyRoute-iOS-unsigned-0.3.1.ipa`.
Для запуска VPN на iPhone нужны профили подписи Apple с Network Extension
для HyRoute и HyRouteTunnel. App Group `group.io.hyroute.mobile` позволяет
приложению и расширению использовать общие базы правил.
