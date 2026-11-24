import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyroute_mobile/core.dart';
import 'package:hyroute_mobile/main.dart';
import 'package:hyroute_mobile/network_tools.dart';

class _TestCore implements ClientCore {
  String? configuration;
  String? input;
  bool rejectSave = false;
  var state = const ClientState();

  @override
  bool get supportsAndroidRules => true;

  @override
  Future<ClientState> loadState() async => state;

  @override
  Future<List<String>> geoTags() async => ['geosite:youtube', 'geoip:ru'];

  @override
  Future<void> updateGeo() async {}

  @override
  Future<Map<String, String>> launchableApps() async => {
    'org.example.app': 'Тестовый браузер',
  };

  @override
  Future<ClientState> refreshSubscription(String id) async {
    final old = state.subscriptions.single;
    expect(id, old.id);
    return state = ClientState(
      settings: state.settings,
      subscriptions: [
        Subscription(
          id: old.id,
          title: old.title,
          canRefresh: true,
          servers: [
            const Server(
              id: 'auto',
              name: '⚡️ Автовыбор',
              protocol: 'VLESS · leastPing',
              balance: true,
            ),
            ...old.servers,
          ],
        ),
      ],
    );
  }

  @override
  Future<ClientState> importSubscription(String input) async {
    this.input = input;
    const subscription = Subscription(
      id: 'test',
      canRefresh: true,
      title: 'Тестовая подписка',
      servers: [
        Server(id: 'nl', name: 'Нидерланды', protocol: 'Hysteria 2'),
        Server(id: 'fi', name: 'Финляндия', protocol: 'VLESS'),
      ],
    );
    return state = ClientState(
      subscriptions: [...state.subscriptions, subscription],
      settings: state.settings,
    );
  }

  @override
  Future<void> saveSettings(ClientSettings settings) async {
    if (rejectSave) throw PlatformException(code: 'core');
    configuration = jsonEncode(settings.toJson()['routing']);
    state = ClientState(subscriptions: state.subscriptions, settings: settings);
  }
}

class _DiagnosticsTestCore extends _TestCore
    implements VPNControl, DiagnosticsControl {
  final probes = <(String, String)>[];

  @override
  bool get vpnAvailable => true;

  @override
  Future<String> vpnStatus() async => 'off';

  @override
  Future<void> startVpn() async {}

  @override
  Future<void> stopVpn() async {}

  @override
  Future<List<String>> vpnJournal() async => ['00:00:01  VPN отключён'];

  @override
  Future<ProbeSnapshot> startProbe(String scope, String id) {
    probes.add((scope, id));
    return probeStatus();
  }

  @override
  Future<ProbeSnapshot> probeStatus() async => const ProbeSnapshot(true, [
    {'name': 'Узел', 'host': 'vpn.example', 'status': 'ok', 'ms': 42},
  ]);

  @override
  Future<void> cancelProbe() async {}
}

class _InlineDiagnosticsTestCore extends _DiagnosticsTestCore {
  var status = 'off';
  var starts = 0;
  var stops = 0;

  @override
  Future<String> vpnStatus() async => status;

  @override
  Future<void> startVpn() async {
    starts++;
    status = 'on';
  }

  @override
  Future<void> stopVpn() async {
    stops++;
    status = 'off';
  }

  @override
  Future<ProbeSnapshot> probeStatus() async => const ProbeSnapshot(true, [
    {'profileId': 'one', 'name': 'Первый', 'status': 'ok', 'ms': 88},
    {'profileId': 'two', 'name': 'Второй', 'status': 'ok', 'ms': 24},
  ]);
}

class _MaintenanceTestCore extends _DiagnosticsTestCore
    implements MaintenanceControl {
  int refreshes = 0;
  String? importedKind;
  final sources = <String, String>{'site': '', 'ip': ''};

  @override
  Future<ClientState> refreshDue() async {
    refreshes++;
    return state;
  }

  @override
  Future<Map<String, String>> geoSources() async => sources;

  @override
  Future<void> setGeoSource(String kind, String address) async {
    sources[kind == 'geosite' ? 'site' : 'ip'] = address;
  }

  @override
  Future<bool> importGeoFile(String kind) async {
    importedKind = kind;
    sources[kind == 'geosite' ? 'site' : 'ip'] = 'file';
    return true;
  }
}

class _RoutingTestCore extends _TestCore implements RoutingControl {
  final changes = <(String, String, String)>[];
  String? checkedAddress;

  @override
  Future<ClientState> changeRoutingProfile(
    String operation, {
    String id = '',
    String name = '',
  }) async {
    changes.add((operation, id, name));
    return state = ClientState(
      subscriptions: state.subscriptions,
      settings: state.settings,
      routingProfiles: const [
        RoutingProfile('default', 'Основной', 0),
        RoutingProfile('work', 'Работа', 0),
      ],
      activeRoutingProfile: operation == 'copy' ? 'work' : id,
    );
  }

  @override
  Future<CheckedRoute> checkRoute(
    String address, {
    required String ip,
    required String protocol,
    required String packageID,
  }) async {
    checkedAddress = address;
    return const CheckedRoute(
      target: 'example.org:443',
      action: RouteAction.direct,
      rule: 'Сайт без VPN',
    );
  }
}

Future<_TestCore> _openApp(WidgetTester tester, {_TestCore? core}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  core ??= _TestCore();
  await tester.pumpWidget(HyRouteApp(core: core));
  await tester.pumpAndSettle();
  return core;
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _importTestSubscription(WidgetTester tester) async {
  await _tap(tester, 'Подписки');
  await _submitTestSubscription(tester);
}

Future<void> _submitTestSubscription(WidgetTester tester) async {
  await _tap(tester, 'Добавить подписку');
  await tester.enterText(
    find.byType(TextField),
    'https://example.org/subscribe',
  );
  await tester.pumpAndSettle();
  await _tap(tester, 'Импортировать');
}

void main() {
  test('keeps existing routing names, fallbacks and app conditions', () {
    final settings = ClientSettings.fromJson({
      'selected': 'server',
      'routing': {
        'defaultAction': 'tunnel',
        'defaultProfile': 'fallback',
        'defaultFallback': ['second'],
        'rules': [
          {
            'id': 'video',
            'name': 'Видео',
            'enabled': false,
            'action': 'tunnel',
            'domain': {'pattern': '.example.org'},
            'ports': [443, '8000-8100'],
            'fallback': ['fallback'],
            'apps': [
              {'pattern': 'com.example.one', 'kind': 'package'},
              {'pattern': 'com.example.two', 'kind': 'package'},
            ],
          },
        ],
      },
    });
    final routing = settings.toJson()['routing'] as Map;
    final rule = (routing['rules'] as List).single as Map;
    expect(routing['defaultProfile'], 'fallback');
    expect(routing['defaultFallback'], ['second']);
    expect(rule['id'], 'video');
    expect(rule['name'], 'Видео');
    expect(rule['enabled'], false);
    expect(rule['domains'], ['.example.org']);
    expect(rule['ports'], '443,8000-8100');
    expect(rule['fallback'], ['fallback']);
    expect(rule['apps'], hasLength(2));
  });

  testWidgets('saves a server group without a reserve', (tester) async {
    ServerGroup? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: ServerGroupsPage(
          groups: const [],
          servers: const [
            Server(id: 'first', name: 'Основной', protocol: 'VLESS'),
          ],
          save: (_, group) async {
            saved = group;
            return [?group];
          },
        ),
      ),
    );
    await tester.tap(find.text('Создать группу'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Моя группа');
    await tester.tap(find.text('Основной'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Сохранить'));
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(saved?.primary, ['first']);
    expect(saved?.reserve, isEmpty);
    expect(find.text('Моя группа'), findsOneWidget);
  });
  test('formats VPN journal timestamps with the device clock', () {
    final at = DateTime(2026, 11, 23, 1, 25, 34).millisecondsSinceEpoch;
    final result = formatVpnJournal(
      jsonEncode([
        {'at': at, 'message': 'Интерфейс VPN включён'},
      ]),
    );
    expect(result, ['23.11 01:25:34  Интерфейс VPN включён']);
  });

  testWidgets('adds and edits plain domain suffix and keyword conditions', (
    tester,
  ) async {
    final core = await _openApp(tester);
    await _tap(tester, 'Правила');
    await _tap(tester, 'Добавить правило');
    await _tap(tester, 'Домен заканчивается на');
    final suffix = find.byKey(const ValueKey(RuleDomainCondition.suffix));
    await tester.enterText(suffix, 'ru');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('В домене есть'));
    await _tap(tester, 'В домене есть');
    final keyword = find.byKey(const ValueKey(RuleDomainCondition.contains));
    await tester.enterText(keyword, 'pzdcflix');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final direct = find.text('Напрямую');
    await tester.ensureVisible(direct);
    await _tap(tester, 'Напрямую');
    await _tap(tester, 'Сохранить');
    expect(jsonDecode(core.configuration!)['rules'].single, {
      'action': 'direct',
      'domains': ['.ru', 'keyword:pzdcflix'],
    });
    await _tap(tester, 'Окончание .ru, Содержит «pzdcflix»');
    expect(tester.widget<TextField>(suffix).controller!.text, '.ru');
    expect(tester.widget<TextField>(keyword).controller!.text, 'pzdcflix');
    await _tap(tester, 'Сохранить');
    expect(jsonDecode(core.configuration!)['rules'].single['domains'], [
      '.ru',
      'keyword:pzdcflix',
    ]);
  });

  testWidgets('saves and reopens the split DNS settings', (tester) async {
    final core = _DiagnosticsTestCore();
    await _openApp(tester, core: core);
    await tester.tap(find.widgetWithText(NavigationDestination, 'Правила'));
    await tester.pumpAndSettle();
    await _tap(tester, 'Настройки');
    final dns = find.text('Раздельный DNS');
    await tester.scrollUntilVisible(dns, 180);
    await tester.tap(dns);
    await tester.pumpAndSettle();
    await _tap(tester, 'Включить');
    await tester.enterText(
      find.byType(TextField).last,
      'example.org\nexample.net',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Сохранить'));
    await _tap(tester, 'Сохранить');
    expect(core.state.settings.splitDns?.domains, [
      'example.org',
      'example.net',
    ]);
    await tester.ensureVisible(dns);
    await tester.tap(dns);
    await tester.pumpAndSettle();
    expect(find.text('example.org\nexample.net'), findsOneWidget);
    await _tap(tester, 'Включить');
    await _tap(tester, 'Сохранить');
    expect(core.state.settings.splitDns, isNull);
  });
  testWidgets('opens route checking and copies a named rule profile', (
    tester,
  ) async {
    final core = _RoutingTestCore();
    await _openApp(tester, core: core);
    await _tap(tester, 'Правила');
    await _tap(tester, 'Профили правил');
    await _tap(tester, 'Создать копию текущего');
    await tester.enterText(find.byType(TextFormField), 'Работа');
    await _tap(tester, 'Сохранить');
    expect(core.changes.single, ('copy', '', 'Работа'));
    await _tap(tester, 'Основной');
    expect(core.changes.last, ('activate', 'default', ''));
    await tester.pageBack();
    await tester.pumpAndSettle();
    await _tap(tester, 'Проверить адрес');
    await tester.enterText(find.byType(TextField), 'example.org');
    await tester.pumpAndSettle();
    await _tap(tester, 'Проверить');
    expect(core.checkedAddress, 'example.org');
    expect(find.text('Сайт без VPN'), findsOneWidget);
  });

  testWidgets('shows quota and failed refresh while retaining the server', (
    tester,
  ) async {
    final core = _TestCore()
      ..state = const ClientState(
        subscriptions: [
          Subscription(
            id: 'quota',
            title: 'Подписка с лимитом',
            canRefresh: true,
            usedBytes: 1 << 30,
            limitBytes: 10 << 30,
            refreshedAt: 1795400000,
            attemptedAt: 1795400100,
            refreshFailed: true,
            servers: [
              Server(id: 'demo', name: 'Рабочий сервер', protocol: 'VLESS'),
            ],
          ),
        ],
      );
    await _openApp(tester, core: core);
    await _tap(tester, 'Подписки');
    await _tap(tester, 'Подписка с лимитом');
    expect(find.text('1 ГиБ из 10 ГиБ'), findsOneWidget);
    expect(find.textContaining('Обновление не удалось'), findsOneWidget);
    expect(find.text('Рабочий сервер'), findsOneWidget);
  });

  testWidgets('configures a separate HTTPS source and local GeoIP file', (
    tester,
  ) async {
    final core = _MaintenanceTestCore();
    await _openApp(tester, core: core);
    await _tap(tester, 'Правила');
    await _tap(tester, 'Настройки');
    await _tap(tester, 'Базы правил');
    await _tap(tester, 'geosite.dat ▾');
    await _tap(tester, 'Указать ссылку');
    await tester.enterText(
      find.byType(TextFormField),
      'https://example.org/geosite.dat',
    );
    await _tap(tester, 'Сохранить');
    expect(core.sources['site'], 'https://example.org/geosite.dat');
    await _tap(tester, 'geoip.dat ▾');
    await _tap(tester, 'Импортировать файл');
    expect(core.importedKind, 'geoip');
    expect(core.sources['ip'], 'file');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('checks for updates when returning to the app', (tester) async {
    final core = _MaintenanceTestCore();
    await _openApp(tester, core: core);
    final before = core.refreshes;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(core.refreshes, before + 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('opens the VPN journal and checks servers at each scope', (
    tester,
  ) async {
    final core = _DiagnosticsTestCore();
    await _openApp(tester, core: core);
    await tester.tap(find.byTooltip('Настройки VPN'));
    await tester.pumpAndSettle();
    await _tap(tester, 'Журнал VPN');
    expect(find.text('00:00:01  VPN отключён'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    await _importTestSubscription(tester);
    await _tap(tester, 'Тестовая подписка');
    await _tap(tester, 'Обновить подписку');
    await _tap(tester, 'Финляндия');
    await _tap(tester, 'Проверить всю подписку');
    expect(find.text('vpn.example · 42 мс'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Проверить узлы группы'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Проверить задержку').first);
    await tester.pumpAndSettle();
    expect(core.probes, [
      ('subscription', 'test'),
      ('profile', 'auto'),
      ('profile', 'nl'),
    ]);
    expect(core.state.settings.selected, 'fi');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('refresh makes the auto profile selectable', (tester) async {
    await _openApp(tester);
    await _importTestSubscription(tester);
    await _tap(tester, 'Тестовая подписка');
    await _tap(tester, 'Обновить подписку');
    expect(find.text('⚡️ Автовыбор'), findsOneWidget);
    expect(find.text('VLESS · leastPing'), findsOneWidget);
    await _tap(tester, '⚡️ Автовыбор');
    await _tap(tester, 'Главная');
    final selector = find.byKey(const ValueKey('primary-profile'));
    expect(
      find.descendant(of: selector, matching: find.text('⚡️ Автовыбор')),
      findsOneWidget,
    );
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'фин');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Финляндия'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: selector, matching: find.text('Финляндия')),
      findsOneWidget,
    );
  });

  testWidgets('adds a geosite category from the rule editor', (tester) async {
    final core = await _openApp(tester);
    await _tap(tester, 'Правила');
    await _tap(tester, 'Добавить правило');
    await _tap(tester, 'Готовый список');
    await _tap(tester, 'geosite:youtube');
    await _tap(tester, 'Сохранить');
    expect(jsonDecode(core.configuration!)['rules'].single['domains'], [
      'geosite:youtube',
    ]);
  });

  testWidgets('uses the host of a pasted URL and keeps the draft on failure', (
    tester,
  ) async {
    final core = await _openApp(tester);
    await _tap(tester, 'Правила');
    await _tap(tester, 'Добавить правило');
    final input = find.byType(TextField).first;
    await tester.enterText(input, 'https://example.org/page?token=test');
    await tester.pumpAndSettle();
    expect(find.text('В правило попадёт: example.org'), findsOneWidget);
    await _tap(tester, 'Напрямую');
    core.rejectSave = true;
    await _tap(tester, 'Сохранить');
    expect(
      tester.widget<TextField>(input).controller!.text,
      'https://example.org/page?token=test',
    );
    expect(find.textContaining('Проверьте сайт'), findsOneWidget);
    core.rejectSave = false;
    await _tap(tester, 'Сохранить');
    expect(jsonDecode(core.configuration!)['rules'].single, {
      'action': 'direct',
      'domains': ['example.org'],
    });
  });

  testWidgets('adds an Android rule by app name', (tester) async {
    final core = await _openApp(tester);
    await _tap(tester, 'Правила');
    await _tap(tester, 'Добавить правило');
    await _tap(tester, 'Приложение');
    await _tap(tester, 'Тестовый браузер');
    await _tap(tester, 'Сохранить');
    expect(find.text('Тестовый браузер'), findsOneWidget);
    expect(jsonDecode(core.configuration!)['rules'].single['apps'], [
      {'kind': 'package', 'pattern': 'org.example.app'},
    ]);
  });

  testWidgets('imports after the subscription tab saves its scroll offset', (
    tester,
  ) async {
    await _openApp(tester);
    await _tap(tester, 'Подписки');
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    scrollable.position.jumpTo(1);
    await tester.pumpAndSettle();
    await _submitTestSubscription(tester);
    expect(tester.takeException(), isNull);
    await _tap(tester, 'Тестовая подписка');
    expect(find.text('Нидерланды'), findsOneWidget);
    await _tap(tester, 'Главная');
    await _tap(tester, 'Подписки');
    expect(tester.takeException(), isNull);
    expect(find.text('Нидерланды'), findsOneWidget);
  });

  testWidgets('imports a subscription and selects its first profile', (
    tester,
  ) async {
    final core = await _openApp(tester);
    expect(find.text('VPN выключен'), findsOneWidget);
    await _importTestSubscription(tester);
    expect(core.input, 'https://example.org/subscribe');
    expect(find.text('Тестовая подписка'), findsOneWidget);
    await _tap(tester, 'Главная');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('primary-profile')),
        matching: find.text('Нидерланды'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'submits a destination rule using the native configuration schema',
    (tester) async {
      final core = await _openApp(tester);
      await _tap(tester, 'Правила');
      await _tap(tester, 'Добавить правило');
      await tester.enterText(find.byType(TextField).first, '.example.org');
      await _tap(tester, 'Сохранить');
      expect(find.text('Окончание .example.org'), findsOneWidget);
      expect(jsonDecode(core.configuration!), {
        'defaultAction': 'tunnel',
        'rules': [
          {
            'action': 'tunnel',
            'domains': ['.example.org'],
          },
        ],
        'viaProfiles': <String, String>{},
      });
    },
  );

  testWidgets('sets a profile chain and Android app scope', (tester) async {
    final core = await _openApp(tester);
    await _importTestSubscription(tester);
    await _tap(tester, 'Правила');
    await _tap(tester, 'Настройки');
    await _tap(tester, 'Профиль через профиль');
    await tester.tap(find.byKey(const ValueKey('chain-exit')));
    await tester.pumpAndSettle();
    await _tap(tester, 'Нидерланды');
    await _tap(tester, 'Без промежуточного профиля');
    await _tap(tester, 'Финляндия');
    await _tap(tester, 'Сохранить');
    expect(find.text('Нидерланды через Финляндия'), findsOneWidget);
    expect(jsonDecode(core.configuration!)['viaProfiles'], {'nl': 'fi'});

    await _tap(tester, 'Приложения в VPN');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Все приложения'),
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, 'Только выбранные');
    await _tap(tester, 'Выбрать приложения');
    await _tap(tester, 'Тестовый браузер');
    await _tap(tester, 'Готово (1)');
    await _tap(tester, 'Сохранить');
    expect(find.text('Только выбранные'), findsOneWidget);

    await _tap(tester, 'Подписки');
    await _tap(tester, 'Тестовая подписка');
    await _tap(tester, 'Финляндия');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(HyRouteApp(core: core));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('primary-profile')),
        matching: find.text('Финляндия'),
      ),
      findsOneWidget,
    );
    await _tap(tester, 'Подписки');
    expect(find.text('Тестовая подписка'), findsOneWidget);
    await _tap(tester, 'Правила');
    await _tap(tester, 'Настройки');
    expect(find.text('Только выбранные'), findsOneWidget);
    expect(find.text('Нидерланды через Финляндия'), findsOneWidget);
  });

  testWidgets(
    'measures and sorts servers on home with a pinned connect button',
    (tester) async {
      final core = _InlineDiagnosticsTestCore()
        ..state = ClientState(
          subscriptions: [
            Subscription(
              id: 'latency-list',
              title: 'Рабочие серверы',
              servers: [
                const Server(id: 'one', name: 'Первый', protocol: 'VLESS'),
                const Server(id: 'two', name: 'Второй', protocol: 'Hysteria 2'),
                for (var index = 0; index < 12; index++)
                  Server(
                    id: 'extra-$index',
                    name: 'Ещё $index',
                    protocol: 'VLESS',
                  ),
              ],
            ),
          ],
        );
      await _openApp(tester, core: core);
      tester.view.physicalSize = const Size(320, 650);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('home-probe-latency-list')));
      await tester.pumpAndSettle();
      expect(core.probes, [('subscription', 'latency-list')]);
      expect(find.text('Задержка серверов'), findsNothing);
      expect(find.textContaining('24 мс'), findsOneWidget);
      final first = find.byKey(const ValueKey('home-server-one'));
      final second = find.byKey(const ValueKey('home-server-two'));
      expect(
        tester.getTopLeft(first).dy,
        lessThan(tester.getTopLeft(second).dy),
      );
      await _tap(tester, 'Сначала быстрые');
      expect(
        tester.getTopLeft(second).dy,
        lessThan(tester.getTopLeft(first).dy),
      );

      final button = find.byKey(const ValueKey('sticky-connect'));
      final buttonPosition = tester.getTopLeft(button);
      await tester.drag(find.byType(ListView).first, const Offset(0, -350));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(button), buttonPosition);
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('finds matching profiles across subscriptions', (tester) async {
    final core = _InlineDiagnosticsTestCore()
      ..state = const ClientState(
        subscriptions: [
          Subscription(
            id: 'mixed',
            title: 'Рабочие',
            servers: [
              Server(id: 'finland', name: 'Финляндия', protocol: 'VLESS'),
              Server(id: 'japan', name: 'Япония', protocol: 'Hysteria 2'),
            ],
          ),
          Subscription(
            id: 'separate',
            title: 'Резерв',
            servers: [Server(id: 'poland', name: 'Польша', protocol: 'VLESS')],
          ),
        ],
      );
    await _openApp(tester, core: core);
    await _tap(tester, 'Подписки');
    final search = find.byKey(const ValueKey('subscription-search'));
    await tester.enterText(search, 'фИн');
    await tester.pumpAndSettle();
    expect(find.text('Финляндия'), findsOneWidget);
    expect(find.text('Япония'), findsNothing);
    expect(find.text('Резерв'), findsNothing);
    await tester.enterText(search, 'нет такого');
    await tester.pumpAndSettle();
    expect(find.text('Серверы и подписки не найдены.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('switches server and applies it with one reconnect action', (
    tester,
  ) async {
    final core = _InlineDiagnosticsTestCore()
      ..state = const ClientState(
        subscriptions: [
          Subscription(
            id: 'work',
            title: 'Серверы',
            servers: [
              Server(id: 'one', name: 'Первый', protocol: 'VLESS'),
              Server(id: 'two', name: 'Второй', protocol: 'Hysteria 2'),
            ],
          ),
        ],
      );
    await _openApp(tester, core: core);
    await _tap(tester, 'Подключить VPN');
    await tester.tap(find.byKey(const ValueKey('home-server-two')));
    await tester.pumpAndSettle();
    expect(core.state.settings.selected, 'two');
    await _tap(tester, 'Переподключить и применить настройки');
    expect(core.stops, 1);
    expect(core.starts, 2);
    expect(find.text('Переподключить и применить настройки'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
