import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyroute_mobile/core.dart';
import 'package:hyroute_mobile/main.dart';

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
    await _tap(tester, 'Журнал VPN');
    expect(find.text('00:00:01  VPN отключён'), findsOneWidget);
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
    await _tap(tester, 'Финляндия');
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
    await _tap(tester, 'Профиль через профиль');
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
    expect(find.text('Только выбранные'), findsOneWidget);
    expect(find.text('Нидерланды через Финляндия'), findsOneWidget);
  });
}
