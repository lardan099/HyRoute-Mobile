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

Future<_TestCore> _openApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final core = _TestCore();
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
      expect(find.text('.example.org'), findsOneWidget);
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
