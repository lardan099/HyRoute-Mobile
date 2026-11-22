import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core.dart';
import 'editors.dart';

class Home extends StatefulWidget {
  const Home({super.key, required this.core});

  final ClientCore core;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final _subscriptions = <Subscription>[];
  var _rules = <RouteRule>[];
  var _via = <String, String>{};
  var _defaultAction = RouteAction.tunnel;
  var _scope = AppScope.all;
  var _packages = <String>[];
  String? _selected;
  int _tab = 0;
  bool _importing = false;
  bool _validating = false;

  List<Server> get _servers => [
    for (final subscription in _subscriptions)
      ...subscription.servers.where((server) => !server.missing),
  ];

  String _serverName(String id) {
    for (final server in _servers) {
      if (server.id == id) return server.name;
    }
    return 'Сервер недоступен';
  }

  void _notify(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _import() async {
    final input = await showDialog<String>(
      context: context,
      builder: (_) => const SubscriptionEditor(),
    );
    if (!mounted || input == null) return;
    setState(() => _importing = true);
    try {
      final subscription = await widget.core.importSubscription(input);
      if (!mounted) return;
      setState(() {
        _subscriptions.add(subscription);
        if (_selected == null && _servers.isNotEmpty) {
          _selected = _servers.first.id;
        }
      });
    } on MissingPluginException {
      if (mounted) _notify('Для импорта нужна сборка с мобильным ядром.');
    } on PlatformException {
      if (mounted) {
        _notify('Импорт не удался. Проверьте ссылку или формат подписки.');
      }
    } on FormatException {
      if (mounted) _notify('Импорт не вернул серверы.');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _saveRouting({
    List<RouteRule>? rules,
    RouteAction? defaultAction,
    Map<String, String>? via,
  }) async {
    if (_validating) return;
    final nextRules = rules ?? _rules;
    final nextDefault = defaultAction ?? _defaultAction;
    final nextVia = via ?? _via;
    setState(() => _validating = true);
    try {
      await widget.core.validateRouting(
        jsonEncode({
          'defaultAction': nextDefault.value,
          'rules': nextRules.map((rule) => rule.toJson()).toList(),
          'viaProfiles': nextVia,
        }),
        _selected,
      );
      if (!mounted) return;
      setState(() {
        _rules = nextRules;
        _defaultAction = nextDefault;
        _via = nextVia;
      });
    } on PlatformException {
      if (mounted) _notify('Проверьте адрес, порт и VPN-профиль в правиле.');
    } on MissingPluginException {
      if (mounted) {
        _notify('Для проверки правил нужна сборка с мобильным ядром.');
      }
    } finally {
      if (mounted) setState(() => _validating = false);
    }
  }

  Future<void> _editRule([int? index]) async {
    final edit = await showDialog<RouteRule>(
      context: context,
      builder: (_) => RuleEditor(
        servers: _servers,
        android: widget.core.supportsAndroidRules,
        initial: index == null ? null : _rules[index],
      ),
    );
    if (!mounted || edit == null) return;
    final next = [..._rules];
    if (index == null) {
      next.add(edit);
    } else {
      next[index] = edit;
    }
    await _saveRouting(rules: next);
  }

  Future<void> _editChain() async {
    final edit = await showDialog<(String, String)>(
      context: context,
      builder: (_) => ChainEditor(servers: _servers, via: _via),
    );
    if (!mounted || edit == null) return;
    final (exit, entry) = edit;
    final next = {..._via};
    if (entry.isEmpty) {
      next.remove(exit);
    } else {
      next[exit] = entry;
      String? id = entry;
      while (id != null) {
        if (id == exit) {
          _notify('Профили в цепочке образуют цикл.');
          return;
        }
        id = next[id];
      }
    }
    await _saveRouting(via: next);
  }

  Future<void> _editScope() async {
    final edit = await showDialog<(AppScope, List<String>)>(
      context: context,
      builder: (_) => ScopeEditor(scope: _scope, packages: _packages),
    );
    if (!mounted || edit == null) return;
    final (scope, packages) = edit;
    setState(() {
      _scope = scope;
      _packages = packages;
    });
  }

  void _ruleAction(int index, String action) {
    final next = [..._rules];
    final item = next.removeAt(index);
    if (action == 'up') next.insert(index - 1, item);
    _saveRouting(rules: next);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'HyRoute',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        leadingWidth: 56,
        leading: Padding(
          padding: const EdgeInsets.only(left: 16, top: 6, bottom: 6),
          child: Center(
            child: Image.asset('assets/hyroute.png', width: 38, height: 38),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              key: PageStorageKey(_tab),
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
              children: switch (_tab) {
                1 => _subscriptionPage(context),
                2 => _rulesPage(context),
                _ => _connectionPage(context),
              },
            ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (tab) => setState(() => _tab = tab),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Главная',
          ),
          NavigationDestination(
            icon: Icon(Icons.layers_outlined),
            selectedIcon: Icon(Icons.layers_rounded),
            label: 'Подписки',
          ),
          NavigationDestination(
            icon: Icon(Icons.alt_route_outlined),
            selectedIcon: Icon(Icons.alt_route_rounded),
            label: 'Правила',
          ),
        ],
      ),
    );
  }

  List<Widget> _connectionPage(BuildContext context) {
    final servers = _servers;
    return [
      const _ConnectionCard(),
      const _SectionTitle('Основной профиль'),
      Card(
        child: servers.isEmpty
            ? ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('Сервер не выбран'),
                subtitle: const Text('Добавьте подписку или ссылку сервера'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => setState(() => _tab = 1),
              )
            : ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _selected,
                    items: serverItems(servers),
                    onChanged: (value) => setState(() => _selected = value),
                  ),
                ),
              ),
      ),
      const _SectionTitle('Маршрутизация'),
      Card(
        child: ListTile(
          leading: const Icon(Icons.alt_route_rounded),
          title: const Text('Всё остальное'),
          subtitle: Text(_defaultAction.label),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => setState(() => _tab = 2),
        ),
      ),
    ];
  }

  List<Widget> _subscriptionPage(BuildContext context) {
    return [
      const _PageTitle('Подписки'),
      if (_subscriptions.isEmpty)
        const Card(
          child: ListTile(
            leading: Icon(Icons.layers_outlined),
            title: Text('Подписок пока нет'),
            subtitle: Text('Импортируйте HTTPS-ссылку, Hysteria 2 или VLESS.'),
          ),
        ),
      for (final (index, subscription) in _subscriptions.indexed)
        Card(
          child: ExpansionTile(
            key: PageStorageKey('subscription:$index'),
            leading: const Icon(Icons.layers_outlined),
            title: Text(
              subscription.title.isEmpty
                  ? 'Импортированные серверы'
                  : subscription.title,
            ),
            children: [
              for (final server in subscription.servers)
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(server.name),
                  subtitle: Text(
                    [
                      server.protocol,
                      if (server.host.isNotEmpty) server.host,
                    ].join(' · '),
                  ),
                  trailing: server.id == _selected
                      ? const Icon(Icons.check_circle_outline)
                      : null,
                  enabled: !server.missing,
                  onTap: server.missing
                      ? null
                      : () => setState(() => _selected = server.id),
                ),
            ],
          ),
        ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _importing ? null : _import,
        icon: _importing
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add_rounded),
        label: Text(_importing ? 'Импорт…' : 'Добавить подписку'),
      ),
    ];
  }

  List<Widget> _rulesPage(BuildContext context) {
    return [
      const _PageTitle('Маршрутизация'),
      Card(
        child: ListTile(
          leading: const Icon(Icons.alt_route_rounded),
          title: const Text('Всё остальное'),
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<RouteAction>(
              value: _defaultAction,
              items: RouteAction.values
                  .map(
                    (action) => DropdownMenuItem(
                      value: action,
                      child: Text(action.label),
                    ),
                  )
                  .toList(),
              onChanged: _validating
                  ? null
                  : (value) => _saveRouting(defaultAction: value),
            ),
          ),
        ),
      ),
      if (widget.core.supportsAndroidRules)
        Card(
          child: ListTile(
            leading: const Icon(Icons.apps_rounded),
            title: const Text('Приложения в VPN'),
            subtitle: Text(_scope.label),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _editScope,
          ),
        ),
      const _SectionTitle('Правила'),
      for (var index = 0; index < _rules.length; index++) _ruleTile(index),
      if (_rules.isEmpty)
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 10),
          child: Text('Добавьте правило для сайта, IP или порта.'),
        ),
      FilledButton.icon(
        onPressed: _validating ? null : () => _editRule(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Добавить правило'),
      ),
      const _SectionTitle('Цепочки профилей'),
      Card(
        child: ListTile(
          leading: const Icon(Icons.link_rounded),
          title: const Text('Профиль через профиль'),
          subtitle: Text(
            _via.isEmpty
                ? (_servers.length < 2
                      ? 'Нужно два VPN-профиля'
                      : 'Выберите входной и выходной профили')
                : _via.entries
                      .map(
                        (hop) =>
                            '${_serverName(hop.key)} через ${_serverName(hop.value)}',
                      )
                      .join('\n'),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: _servers.length < 2 || _validating ? null : _editChain,
        ),
      ),
    ];
  }

  Widget _ruleTile(int index) {
    final rule = _rules[index];
    final label = rule.server.isEmpty
        ? rule.action.label
        : _serverName(rule.server);
    return Card(
      child: ListTile(
        leading: Icon(switch (rule.action) {
          RouteAction.tunnel => Icons.vpn_lock_outlined,
          RouteAction.direct => Icons.open_in_new_rounded,
          RouteAction.block => Icons.block_rounded,
        }),
        title: Text(rule.title),
        subtitle: Text(label),
        onTap: _validating ? null : () => _editRule(index),
        trailing: PopupMenuButton<String>(
          tooltip: 'Действия с правилом',
          enabled: !_validating,
          onSelected: (action) => _ruleAction(index, action),
          itemBuilder: (_) => [
            if (index > 0)
              const PopupMenuItem(value: 'up', child: Text('Поднять выше')),
            const PopupMenuItem(value: 'delete', child: Text('Удалить')),
          ],
        ),
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xff111d34),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff11203a), Color(0xff203b67)],
        ),
        borderRadius: BorderRadius.circular(26),
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const CircleAvatar(
              radius: 26,
              backgroundColor: Color(0xff2e4875),
              foregroundColor: Color(0xffd5e4ff),
              child: Icon(Icons.power_settings_new_rounded, size: 29),
            ),
            const SizedBox(height: 18),
            Text(
              'VPN выключен',
              style: Theme.of(context).textTheme.headlineSmall!.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Туннель ещё в разработке',
              style: TextStyle(color: Color(0xffc1cfe7)),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: null,
              style: FilledButton.styleFrom(
                disabledBackgroundColor: const Color(0xff2e4875),
                disabledForegroundColor: const Color(0xffc1cfe7),
              ),
              child: const Text('Подключить'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PageTitle extends StatelessWidget {
  const _PageTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.headlineMedium!.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 21, 4, 8),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}
