import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core.dart';
import 'diagnostics.dart';
import 'editors.dart';

class Home extends StatefulWidget {
  const Home({super.key, required this.core});

  final ClientCore core;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  var _subscriptions = <Subscription>[];
  var _rules = <RouteRule>[];
  var _via = <String, String>{};
  var _defaultAction = RouteAction.tunnel;
  var _scope = AppScope.all;
  var _packages = <String>[];
  String? _selected;
  int _tab = 0;
  bool _importing = false;
  bool _validating = false;
  bool _loading = true;
  bool _storageFailed = false;
  Timer? _vpnTimer;
  Timer? _maintenanceTimer;
  bool _updatingAutomatically = false;
  var _vpnStatus = 'off';

  VPNControl? get _vpn {
    final core = widget.core;
    return core is VPNControl && (core as VPNControl).vpnAvailable
        ? core as VPNControl
        : null;
  }

  DiagnosticsControl? get _diagnostics =>
      _vpn is DiagnosticsControl ? _vpn as DiagnosticsControl : null;

  void _openProbe(String scope, String id) {
    final core = _diagnostics;
    if (core == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProbePage(core: core, scope: scope, id: id),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadState();
    if (_vpn != null) {
      _readVPNStatus();
      _vpnTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _readVPNStatus(),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _maintenanceTimer?.cancel();
    _vpnTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _maintenanceTimer?.cancel();
    if (state == AppLifecycleState.resumed && !_loading && !_storageFailed) {
      _startMaintenance();
    }
  }

  void _startMaintenance() {
    if (widget.core is! MaintenanceControl || _vpn == null) return;
    unawaited(_refreshDue());
    _maintenanceTimer?.cancel();
    _maintenanceTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => _refreshDue(),
    );
  }

  Future<void> _refreshDue() async {
    if (_updatingAutomatically || _importing || _validating) return;
    final core = widget.core;
    if (core is! MaintenanceControl) return;
    _updatingAutomatically = true;
    try {
      final state = await (core as MaintenanceControl).refreshDue();
      if (mounted && !_importing && !_validating) {
        setState(() => _restore(state));
      }
    } on PlatformException {
      // The saved state remains usable until the next attempt.
    } on MissingPluginException {
      // Prior native builds can still open the saved state.
    } finally {
      _updatingAutomatically = false;
    }
  }

  Future<void> _readVPNStatus() async {
    final vpn = _vpn;
    if (vpn == null) return;
    try {
      final status = await vpn.vpnStatus();
      if (mounted && status != _vpnStatus) setState(() => _vpnStatus = status);
    } on PlatformException {
      if (mounted) setState(() => _vpnStatus = 'error');
    } on MissingPluginException {
      if (mounted) setState(() => _vpnStatus = 'error');
    }
  }

  Future<void> _toggleVPN() async {
    final vpn = _vpn;
    if (vpn == null) return;
    try {
      if (_vpnStatus == 'on' || _vpnStatus == 'starting') {
        await vpn.stopVpn();
      } else {
        await vpn.startVpn();
      }
      await _readVPNStatus();
    } on PlatformException {
      if (mounted) setState(() => _vpnStatus = 'error');
    }
  }

  Future<void> _loadState() async {
    try {
      final state = await widget.core.loadState();
      if (mounted) setState(() => _restore(state));
    } catch (_) {
      if (mounted) setState(() => _storageFailed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (mounted &&
        !_storageFailed &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _startMaintenance();
    }
  }

  void _restore(ClientState state) {
    _subscriptions = state.subscriptions;
    final settings = state.settings;
    _rules = settings.rules;
    _via = settings.via;
    _defaultAction = settings.defaultAction;
    _scope = settings.scope;
    _packages = settings.packages;
    final servers = _servers;
    _selected = servers.any((server) => server.id == settings.selected)
        ? settings.selected
        : (servers.where((server) => server.balance).firstOrNull ??
                  servers.firstOrNull)
              ?.id;
  }

  List<Server> get _servers {
    final active = _subscriptions
        .expand((subscription) => subscription.servers)
        .where((server) => !server.missing);
    return [
      ...active.where((server) => server.balance),
      ...active.where((server) => !server.balance),
    ];
  }

  Future<void> _chooseProfile() async {
    final id = await _pickProfile(_selected);
    if (mounted && id != null) await _saveSettings(selected: id);
  }

  Future<String?> _pickProfile(String? selected, {bool useMain = false}) =>
      showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => _ProfilePicker(
          servers: _servers,
          selected: selected,
          useMain: useMain,
        ),
      );

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
    if (_importing || _validating) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SubscriptionEditor(
        onImport: (input) =>
            _updateSubscriptions(() => widget.core.importSubscription(input)),
      ),
    );
  }

  Future<String?> _updateSubscriptions(
    Future<ClientState> Function() update, {
    bool refresh = false,
  }) async {
    if (_importing || _validating) return 'Дождитесь завершения загрузки.';
    setState(() => _importing = true);
    try {
      final state = await update();
      if (mounted) setState(() => _restore(state));
      return null;
    } on MissingPluginException {
      return 'Для импорта нужна сборка с мобильным ядром.';
    } on PlatformException catch (error) {
      return error.code == 'storage'
          ? 'Подписку не удалось сохранить. Проверьте хранилище устройства.'
          : refresh
          ? 'Подписку не удалось обновить. Сохранён предыдущий список.'
          : 'Импорт не удался. Проверьте ссылку или формат подписки.';
    } on FormatException {
      return 'В подписке не нашлось серверов.';
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _refresh(String id) async {
    final error = await _updateSubscriptions(
      () => widget.core.refreshSubscription(id),
      refresh: true,
    );
    if (mounted) _notify(error ?? 'Подписка обновлена.');
  }

  Future<String?> _saveSettings({
    List<RouteRule>? rules,
    RouteAction? defaultAction,
    Map<String, String>? via,
    String? selected,
    AppScope? scope,
    List<String>? packages,
    bool inline = false,
  }) async {
    if (_validating || _importing) return 'Дождитесь завершения загрузки.';
    final next = ClientSettings(
      rules: rules ?? _rules,
      defaultAction: defaultAction ?? _defaultAction,
      via: via ?? _via,
      selected: selected ?? _selected,
      scope: scope ?? _scope,
      packages: packages ?? _packages,
    );
    setState(() => _validating = true);
    try {
      await widget.core.saveSettings(next);
      if (mounted) {
        setState(
          () => _restore(
            ClientState(subscriptions: _subscriptions, settings: next),
          ),
        );
        if (_vpnStatus == 'on') {
          _notify('Настройки сохранены. Они применятся после переподключения.');
        }
      }
      return null;
    } on PlatformException catch (error) {
      final message = error.code == 'storage'
          ? 'Не удалось сохранить настройки.'
          : 'Проверьте сайт, IP и порт. Для готового списка нужны базы правил.';
      if (!inline && mounted) _notify(message);
      return message;
    } on MissingPluginException {
      const message = 'Для проверки правил нужна сборка с мобильным ядром.';
      if (!inline && mounted) _notify(message);
      return message;
    } finally {
      if (mounted) setState(() => _validating = false);
    }
  }

  Future<void> _editRule([int? index, String? destination]) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RuleEditor(
        servers: _servers,
        android: widget.core.supportsAndroidRules,
        pickGeoTag: _pickGeoTag,
        pickProfile: (id) => _pickProfile(id, useMain: true),
        pickApp: widget.core.supportsAndroidRules ? _pickApp : null,
        save: (rule) {
          final next = [..._rules];
          if (index == null) {
            next.add(rule);
          } else {
            next[index] = rule;
          }
          return _saveSettings(rules: next, inline: true);
        },
        destination: destination,
        initial: index == null ? null : _rules[index],
      ),
    );
  }

  Future<MapEntry<String, String>?> _pickApp() async {
    final result = await _pickApps(null);
    return result?.firstOrNull;
  }

  Future<List<MapEntry<String, String>>?> _pickApps(List<String>? existing) =>
      showDialog<List<MapEntry<String, String>>>(
        context: context,
        builder: (_) => AppPicker(core: widget.core, existing: existing),
      );

  Future<String?> _pickGeoTag() => showDialog<String>(
    context: context,
    builder: (_) => GeoCatalogDialog(core: widget.core),
  );

  Future<void> _openGeo() async {
    final tag = await showDialog<String>(
      context: context,
      builder: (_) => GeoCatalogDialog(core: widget.core, manageSources: true),
    );
    if (mounted && tag != null) await _editRule(null, tag);
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
    await _saveSettings(via: next);
  }

  Future<void> _editScope() async {
    final edit = await showDialog<(AppScope, List<String>)>(
      context: context,
      builder: (_) =>
          ScopeEditor(scope: _scope, packages: _packages, pickApps: _pickApps),
    );
    if (!mounted || edit == null) return;
    final (scope, packages) = edit;
    await _saveSettings(scope: scope, packages: packages);
  }

  void _ruleAction(int index, String action) {
    final next = [..._rules];
    final item = next.removeAt(index);
    if (action == 'up') next.insert(index - 1, item);
    if (action == 'down') next.insert(index + 1, item);
    _saveSettings(rules: next);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: const Text(
          'HyRoute',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        leadingWidth: 56,
        leading: Padding(
          padding: const EdgeInsets.only(left: 16, top: 6, bottom: 6),
          child: Center(
            child: Image.asset('assets/hyroute.png', width: 31, height: 31),
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
              children: switch ((_loading, _storageFailed, _tab)) {
                (true, _, _) => const [
                  Center(child: CircularProgressIndicator()),
                ],
                (_, true, _) => [
                  const Text('Не удалось открыть хранилище HyRoute.'),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _loading = true;
                        _storageFailed = false;
                      });
                      _loadState();
                    },
                    child: const Text('Повторить'),
                  ),
                ],
                (_, _, 1) => _subscriptionPage(context),
                (_, _, 2) => _rulesPage(context),
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
    final selected = servers
        .where((server) => server.id == _selected)
        .firstOrNull;
    return [
      _ConnectionCard(
        status: _vpnStatus,
        available: _vpn != null,
        hasProfile: selected != null,
        onToggle: _toggleVPN,
      ),
      if (_diagnostics case final DiagnosticsControl core)
        ListTile(
          leading: const Icon(Icons.receipt_long_outlined),
          title: const Text('Журнал VPN'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => VPNJournalPage(core: core)),
          ),
        ),
      const _SectionTitle('Основной профиль'),
      Card(
        child: selected == null
            ? ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('Сервер не выбран'),
                subtitle: const Text('Добавьте подписку или ссылку сервера'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _import,
              )
            : ListTile(
                key: const ValueKey('primary-profile'),
                leading: _ProfileIcon(balance: selected.balance),
                title: Text(selected.name),
                subtitle: Text(selected.protocol),
                trailing: const Icon(Icons.unfold_more_rounded),
                onTap: _importing || _validating ? null : _chooseProfile,
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
      OutlinedButton.icon(
        onPressed: _importing || _validating ? null : _import,
        icon: _importing
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add_rounded),
        label: Text(_importing ? 'Загрузка…' : 'Добавить подписку'),
      ),
      const SizedBox(height: 10),
      if (_subscriptions.isEmpty)
        const Card(
          child: ListTile(
            leading: Icon(Icons.layers_outlined),
            title: Text('Подписок пока нет'),
            subtitle: Text('Импортируйте HTTPS-ссылку, Hysteria 2 или VLESS.'),
          ),
        ),
      for (final subscription in _subscriptions)
        Card(
          child: ExpansionTile(
            key: PageStorageKey('subscription:${subscription.id}'),
            leading: const Icon(Icons.layers_outlined),
            title: Text(
              subscription.title.isEmpty
                  ? 'Импортированные серверы'
                  : subscription.title,
            ),
            children: [
              if (_diagnostics != null &&
                  subscription.servers.any((server) => !server.missing))
                ListTile(
                  leading: const Icon(Icons.speed),
                  title: const Text('Проверить всю подписку'),
                  onTap: () => _openProbe('subscription', subscription.id),
                ),
              if (subscription.canRefresh)
                ListTile(
                  leading: const Icon(Icons.refresh_rounded),
                  title: const Text('Обновить подписку'),
                  onTap: _importing || _validating
                      ? null
                      : () => _refresh(subscription.id),
                ),
              for (final server in subscription.servers)
                ListTile(
                  leading: _ProfileIcon(balance: server.balance),
                  title: Text(server.name),
                  subtitle: Text(
                    [
                      server.protocol,
                      if (server.host.isNotEmpty) server.host,
                    ].join(' · '),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (server.id == _selected)
                        const Icon(Icons.check_circle_outline),
                      if (_diagnostics != null && !server.missing)
                        IconButton(
                          icon: const Icon(Icons.speed),
                          tooltip: server.balance
                              ? 'Проверить узлы группы'
                              : 'Проверить задержку',
                          onPressed: () => _openProbe('profile', server.id),
                        ),
                    ],
                  ),
                  enabled: !server.missing,
                  onTap: server.missing || _importing || _validating
                      ? null
                      : () => _saveSettings(selected: server.id),
                ),
            ],
          ),
        ),
    ];
  }

  List<Widget> _rulesPage(BuildContext context) {
    return [
      const _PageTitle('Маршрутизация'),
      FilledButton.icon(
        onPressed: _validating || _importing ? null : () => _editRule(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Добавить правило'),
      ),
      if (_rules.length > 1)
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 12, 4, 8),
          child: Text('Срабатывает первое подходящее правило сверху.'),
        ),
      for (var index = 0; index < _rules.length; index++) _ruleTile(index),
      const _SectionTitle('Другие настройки'),
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
                  : (value) => _saveSettings(defaultAction: value),
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
      Card(
        child: ListTile(
          leading: const Icon(Icons.public_rounded),
          title: const Text('Базы правил'),
          subtitle: const Text('GeoSite и GeoIP'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: _validating || _importing ? null : _openGeo,
        ),
      ),
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
            if (index < _rules.length - 1)
              const PopupMenuItem(value: 'down', child: Text('Опустить ниже')),
            const PopupMenuItem(value: 'delete', child: Text('Удалить')),
          ],
        ),
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.status,
    required this.available,
    required this.hasProfile,
    required this.onToggle,
  });

  final String status;
  final bool available;
  final bool hasProfile;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final title = switch (status) {
      'on' => 'VPN включён',
      'starting' || 'permission' => 'Подключение VPN',
      'stopping' => 'Отключение VPN',
      'error' => 'Не удалось подключить VPN',
      _ => 'VPN выключен',
    };
    final details = !available
        ? 'Подключение доступно в мобильном приложении.'
        : switch (status) {
            'permission' => 'Разрешите подключение в системном окне.',
            'error' => 'Проверьте профиль, правила и доступ к интернету.',
            _ => hasProfile ? null : 'Выберите профиль, чтобы подключиться.',
          };
    final canStop = status == 'on' || status == 'starting';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xff122522),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff203d34), Color(0xff111f20)],
        ),
        borderRadius: BorderRadius.circular(23),
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0xff355049),
                borderRadius: BorderRadius.all(Radius.circular(14)),
              ),
              child: SizedBox.square(
                dimension: 48,
                child: Icon(
                  Icons.power_settings_new_rounded,
                  size: 23,
                  color: Color(0xff91efcb),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall!.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (details != null) ...[
              const SizedBox(height: 6),
              Text(details, style: const TextStyle(color: Color(0xffc4d7ce))),
            ],
            if (available) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed:
                    canStop ||
                        hasProfile && (status == 'off' || status == 'error')
                    ? onToggle
                    : null,
                child: Text(canStop ? 'Отключить' : 'Подключить'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfileIcon extends StatelessWidget {
  const _ProfileIcon({required this.balance});

  final bool balance;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(9),
      ),
      child: SizedBox.square(
        dimension: 34,
        child: Icon(
          balance ? Icons.bolt_rounded : Icons.dns_outlined,
          size: 19,
          color: colors.primary,
        ),
      ),
    );
  }
}

class _ProfilePicker extends StatefulWidget {
  const _ProfilePicker({
    required this.servers,
    required this.selected,
    this.useMain = false,
  });

  final List<Server> servers;
  final String? selected;
  final bool useMain;

  @override
  State<_ProfilePicker> createState() => _ProfilePickerState();
}

class _ProfilePickerState extends State<_ProfilePicker> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final matches = widget.servers
        .where(
          (server) =>
              server.name.toLowerCase().contains(_query) ||
              server.host.toLowerCase().contains(_query),
        )
        .toList(growable: false);
    return FractionallySizedBox(
      heightFactor: 0.86,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              _PageTitle(
                widget.useMain ? 'VPN-профиль правила' : 'Основной профиль',
              ),
              if (widget.useMain)
                ListTile(
                  title: const Text('Основной профиль'),
                  subtitle: const Text(
                    'Использовать профиль с главного экрана',
                  ),
                  selected: widget.selected == '',
                  onTap: () => Navigator.pop(context, ''),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: TextField(
                  onChanged: (value) =>
                      setState(() => _query = value.trim().toLowerCase()),
                  decoration: const InputDecoration(
                    labelText: 'Найти профиль',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
              Expanded(
                child: matches.isEmpty
                    ? const Center(child: Text('Профиль не найден.'))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                        itemCount: matches.length,
                        itemBuilder: (context, index) {
                          final server = matches[index];
                          return ListTile(
                            leading: _ProfileIcon(balance: server.balance),
                            title: Text(server.name),
                            subtitle: Text(server.protocol),
                            selected: server.id == widget.selected,
                            trailing: server.id == widget.selected
                                ? const Icon(Icons.check_rounded)
                                : null,
                            onTap: () => Navigator.pop(context, server.id),
                          );
                        },
                      ),
              ),
            ],
          ),
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
