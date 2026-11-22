import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyroute_mobile/core.dart';
import 'package:hyroute_mobile/main.dart';

class _TestCore implements ClientCore {
  String? configuration;
  String? input;
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
    final selector = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(selector.value, 'auto');
  });

  testWidgets('adds a geosite category from the rule editor', (tester) async {
    final core = await _openApp(tester);
    await _tap(tester, 'Правила');
    await _tap(tester, 'Добавить правило');
    await _tap(tester, 'Выбрать GeoSite или GeoIP');
    await _tap(tester, 'geosite:youtube');
    await _tap(tester, 'Сохранить');
    expect(jsonDecode(core.configuration!)['rules'].single['domains'], [
      'geosite:youtube',
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
    final connect = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Подключить'),
    );
    expect(connect.onPressed, isNull);
    await _importTestSubscription(tester);
    expect(core.input, 'https://example.org/subscribe');
    expect(find.text('Тестовая подписка'), findsOneWidget);
    await _tap(tester, 'Главная');
    final selected = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(selected.value, 'nl');
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
    await tester.enterText(find.byType(TextField), 'org.example.app');
    await _tap(tester, 'Сохранить');
    expect(find.text('Только выбранные'), findsOneWidget);

    await _tap(tester, 'Подписки');
    await _tap(tester, 'Тестовая подписка');
    await _tap(tester, 'Финляндия');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(HyRouteApp(core: core));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
          .value,
      'fi',
    );
    await _tap(tester, 'Подписки');
    expect(find.text('Тестовая подписка'), findsOneWidget);
    await _tap(tester, 'Правила');
    expect(find.text('Только выбранные'), findsOneWidget);
    expect(find.text('Нидерланды через Финляндия'), findsOneWidget);
  });
}
