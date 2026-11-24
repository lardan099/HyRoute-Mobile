import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core.dart';
import 'diagnostics.dart';
import 'editors.dart';
import 'network_tools.dart';
import 'routing_tools.dart';

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
  String? _defaultProfile;
  var _defaultFallback = <String>[];
  var _scope = AppScope.all;
  var _packages = <String>[];
  var _routingProfiles = <RoutingProfile>[];
  var _serverGroups = <ServerGroup>[];
  SplitDns? _splitDns;
  var _activeRoutingProfile = 'default';
  String? _selected;
  int _tab = 0;
  var _routingSettings = false;
  var _subscriptionQuery = '';
  bool _importing = false;
  bool _validating = false;
  bool _loading = true;
  bool _storageFailed = false;
  Timer? _vpnTimer;
  Timer? _maintenanceTimer;
  bool _updatingAutomatically = false;
  int _stateRevision = 0;
  var _vpnStatus = 'off';
  var _changingVpn = false;
  var _pendingReconnect = false;
  final _expandedSubscriptions = <String, bool>{};
  final _sortLatency = <String>{};
  final _latencies = <String, List<Map<String, dynamic>>>{};
  String? _inlineProbe;
  String? _probeError;
  var _cancelInlineProbe = false;

  VPNControl? get _vpn {
    final core = widget.core;
    return core is VPNControl && (core as VPNControl).vpnAvailable
        ? core as VPNControl
        : null;
  }

  DiagnosticsControl? get _diagnostics =>
      _vpn is DiagnosticsControl ? _vpn as DiagnosticsControl : null;

  RoutingControl? get _routing {
    final core = widget.core;
    return core is RoutingControl ? core as RoutingControl : null;
  }

  void _openProbe(String scope, String id) {
    final core = _diagnostics;
    if (core == null || _inlineProbe != null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProbePage(core: core, scope: scope, id: id),
      ),
    );
  }

  Future<void> _checkSubscription(Subscription subscription) async {
    final core = _diagnostics;
    if (core == null) return;
    if (_inlineProbe == subscription.id) {
      setState(() => _cancelInlineProbe = true);
      return;
    }
    if (_inlineProbe != null) return;

    final previous = {..._latencies};
    setState(() {
      _expandedSubscriptions[subscription.id] = true;
      _inlineProbe = subscription.id;
      _cancelInlineProbe = false;
      _probeError = null;
    });
    try {
      await pollProbe(
        core,
        'subscription',
        subscription.id,
        active: () => mounted && !_cancelInlineProbe,
        report: (snapshot) {
          final rows = <String, List<Map<String, dynamic>>>{};
          for (final row in snapshot.results) {
            if (row['profileId'] case final String id) {
              rows.putIfAbsent(id, () => []).add(row);
            }
          }
          setState(() => _latencies.addAll(rows));
        },
      );
    } on Exception {
      if (mounted && !_cancelInlineProbe) {
        setState(() => _probeError = subscription.id);
      }
    } finally {
      try {
        await core.cancelProbe();
      } on Exception {
        // The activity can lose its channel while closing a batch.
      }
      if (mounted) {
        setState(() {
          for (final server in subscription.servers) {
            final rows = _latencies[server.id] ?? const [];
            if (rows.any(
              (row) => ['pending', 'running'].contains(row['status']),
            )) {
              final saved = previous[server.id];
              if (saved == null) {
                _latencies.remove(server.id);
              } else {
                _latencies[server.id] = saved;
              }
            }
          }
          _inlineProbe = null;
        });
      }
    }
  }

  int? _latency(String id) {
    int? best;
    for (final row in _latencies[id] ?? const []) {
      if (row['ms'] case final int ms when row['status'] == 'ok') {
        if (best == null || ms < best) best = ms;
      }
    }
    return best;
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
    final revision = _stateRevision;
    try {
      final state = await (core as MaintenanceControl).refreshDue();
      if (mounted &&
          !_importing &&
          !_validating &&
          revision == _stateRevision) {
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
      if (mounted && status != _vpnStatus) {
        setState(() {
          _vpnStatus = status;
          if (status == 'off' && !_changingVpn) _pendingReconnect = false;
        });
      }
    } on PlatformException {
      if (mounted) setState(() => _vpnStatus = 'error');
    } on MissingPluginException {
      if (mounted) setState(() => _vpnStatus = 'error');
    }
  }

  Future<void> _toggleVPN() async {
    final vpn = _vpn;
    if (vpn == null || _changingVpn) return;
    setState(() => _changingVpn = true);
    try {
      if (_vpnStatus == 'on' || _vpnStatus == 'starting') {
        await vpn.stopVpn();
      } else {
        await vpn.startVpn();
        if (mounted) setState(() => _pendingReconnect = false);
      }
      await _readVPNStatus();
    } on PlatformException {
      if (mounted) setState(() => _vpnStatus = 'error');
    } finally {
      if (mounted) setState(() => _changingVpn = false);
    }
  }

  Future<void> _reconnect() async {
    final vpn = _vpn;
    if (vpn == null || _changingVpn) return;
    setState(() => _changingVpn = true);
    try {
      await vpn.stopVpn();
      for (var attempt = 0; attempt < 30; attempt++) {
        if (!mounted) return;
        if (await vpn.vpnStatus() == 'off') {
          await vpn.startVpn();
          if (mounted) setState(() => _pendingReconnect = false);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (mounted) _notify('Android ещё останавливает VPN.');
    } on PlatformException {
      if (mounted) _notify('Не удалось переподключиться. Откройте журнал VPN.');
    } finally {
      if (mounted) {
        await _readVPNStatus();
        if (mounted) setState(() => _changingVpn = false);
      }
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
    _stateRevision++;
    _subscriptions = state.subscriptions;
    _routingProfiles = state.routingProfiles;
    _serverGroups = state.serverGroups;
    _activeRoutingProfile = state.activeRoutingProfile;
    final settings = state.settings;
    _rules = settings.rules;
    _via = settings.via;
    _defaultAction = settings.defaultAction;
    _defaultProfile = settings.defaultProfile;
    _defaultFallback = settings.defaultFallback;
    _scope = settings.scope;
    _packages = settings.packages;
    _splitDns = settings.splitDns;
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

  List<Server> get _chainServers {
    final groupIds = _serverGroups.map((group) => group.id).toSet();
    return _servers.where((server) => !groupIds.contains(server.id)).toList();
  }

  void _openServerGroups(ServerGroupControl control) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ServerGroupsPage(
          groups: _serverGroups,
          servers: {
            for (final server in _servers)
              if (!server.balance) server.id: server,
          }.values.toList(),
          save: (id, group) async {
            final state = await control.changeServerGroup(id, group);
            if (mounted) setState(() => _restore(state));
            return state.serverGroups;
          },
        ),
      ),
    );
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
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => SubscriptionEditor(
          onImport: (input) =>
              _updateSubscriptions(() => widget.core.importSubscription(input)),
        ),
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
          : error.code == 'subscription' && error.message != null
          ? error.message!
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
    if (mounted) {
      final failed =
          _subscriptions
              .where((item) => item.id == id)
              .firstOrNull
              ?.refreshFailed ==
          true;
      _notify(
        error ??
            (failed
                ? 'Подписку не удалось обновить. Сохранён предыдущий список.'
                : 'Подписка обновлена.'),
      );
    }
  }

  Future<String?> _saveSettings({
    List<RouteRule>? rules,
    RouteAction? defaultAction,
    Map<String, String>? via,
    String? selected,
    AppScope? scope,
    List<String>? packages,
    SplitDns? splitDns,
    bool changeSplitDns = false,
    bool inline = false,
  }) async {
    if (_validating || _importing) return 'Дождитесь завершения загрузки.';
    final next = ClientSettings(
      rules: rules ?? _rules,
      defaultAction: defaultAction ?? _defaultAction,
      defaultProfile: _defaultProfile,
      defaultFallback: _defaultFallback,
      via: via ?? _via,
      selected: selected ?? _selected,
      scope: scope ?? _scope,
      packages: packages ?? _packages,
      splitDns: changeSplitDns ? splitDns : _splitDns,
    );
    setState(() => _validating = true);
    try {
      await widget.core.saveSettings(next);
      if (mounted) {
        setState(
          () => _restore(
            ClientState(
              subscriptions: _subscriptions,
              settings: next,
              routingProfiles: _routingProfiles,
              serverGroups: _serverGroups,
              activeRoutingProfile: _activeRoutingProfile,
            ),
          ),
        );
        if (_vpnStatus == 'on') setState(() => _pendingReconnect = true);
      }
      return null;
    } on PlatformException catch (error) {
      final message = error.code == 'storage'
          ? 'Не удалось сохранить настройки.'
          : error.message ??
                'Проверьте сайт, IP и порт. Для готового списка нужны базы правил.';
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

  Future<ClientState> _changeRuleProfile(
    String operation,
    String id,
    String name,
  ) async {
    final core = _routing;
    if (core == null || _validating || _importing) {
      throw PlatformException(
        code: 'busy',
        message: 'Дождитесь окончания сохранения.',
      );
    }
    setState(() => _validating = true);
    try {
      final state = await core.changeRoutingProfile(
        operation,
        id: id,
        name: name,
      );
      if (mounted) setState(() => _restore(state));
      return state;
    } finally {
      if (mounted) setState(() => _validating = false);
    }
  }

  void _openRuleProfiles() {
    final profiles = _routingProfiles.isEmpty
        ? [RoutingProfile('default', 'Основной', _rules.length)]
        : [
            for (final profile in _routingProfiles)
              profile.id == _activeRoutingProfile
                  ? RoutingProfile(profile.id, profile.name, _rules.length)
                  : profile,
          ];
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RoutingProfilesPage(
          profiles: profiles,
          active: _activeRoutingProfile,
          onChange: _changeRuleProfile,
        ),
      ),
    );
  }

  void _openRouteCheck() {
    final core = _routing;
    if (core == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RouteCheckPage(
          core: core,
          serverName: _serverName,
          pickApp: widget.core.supportsAndroidRules ? _pickApp : null,
        ),
      ),
    );
  }

  Future<void> _editRule([int? index, String? destination]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
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
      builder: (_) =>
          ChainEditor(servers: _chainServers, entries: _servers, via: _via),
    );
    if (!mounted || edit == null) return;
    final (exit, entry) = edit;
    final next = {..._via};
    if (entry.isEmpty) {
      next.remove(exit);
    } else {
      next[exit] = entry;
      final seen = {exit};
      String? id = entry;
      while (id != null) {
        if (!seen.add(id)) {
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
        title: Text(
          _tab == 0
              ? 'HyRoute'
              : _tab == 1
              ? 'Серверы'
              : 'Маршрутизация',
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        actions: [
          if (_tab == 0 &&
              (_diagnostics != null || widget.core is VPNSystemSettings))
            IconButton(
              tooltip: 'Настройки VPN',
              onPressed: _openVpnControls,
              icon: const Icon(Icons.settings_outlined),
            ),
          if (_tab == 0 && !_loading && !_storageFailed)
            IconButton(
              tooltip: 'Добавить подписку',
              onPressed: _importing || _validating ? null : _import,
              icon: const Icon(Icons.add_rounded),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              children: [
                if (!_loading && !_storageFailed && _tab == 2)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('Список')),
                          ButtonSegment(value: true, label: Text('Настройки')),
                        ],
                        selected: {_routingSettings},
                        onSelectionChanged: (values) =>
                            setState(() => _routingSettings = values.single),
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView(
                    key: PageStorageKey((_tab, _tab == 2 && _routingSettings)),
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
                      (_, _, 2) =>
                        _routingSettings ? _ruleSettings() : _rulesPage(),
                      _ => _connectionPage(context),
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_vpn != null &&
              ((_tab == 0 && _selected != null) ||
                  (_pendingReconnect && _vpnStatus == 'on')))
            _connectionActions(),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (tab) => setState(() => _tab = tab),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.power_settings_new_outlined),
                selectedIcon: Icon(Icons.power_settings_new_rounded),
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
        ],
      ),
    );
  }

  List<Widget> _connectionPage(BuildContext context) {
    final selected = _servers
        .where((server) => server.id == _selected)
        .firstOrNull;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final connected = _vpnStatus == 'on';
    final signal = connected ? colors.primary : colors.onSurfaceVariant;
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 8, color: signal),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _vpnTitle,
                    style: theme.textTheme.bodyMedium?.copyWith(color: signal),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (selected == null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Добавить подписку'),
                subtitle: const Text('Ссылка или конфиг сервера'),
                trailing: const Icon(Icons.add_rounded),
                onTap: _importing || _validating ? null : _import,
              )
            else
              ListTile(
                key: const ValueKey('primary-profile'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  selected.name,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  selected.protocol,
                  style: theme.textTheme.bodySmall,
                ),
                trailing: const Icon(
                  Icons.unfold_more_rounded,
                  semanticLabel: 'Сменить сервер',
                ),
                onTap: _importing || _validating ? null : _chooseProfile,
              ),
          ],
        ),
      ),
      if (_subscriptions.isNotEmpty) ...[
        for (final item in _subscriptions) ...[
          const Divider(height: 1),
          _homeSubscription(context, item),
        ],
      ],
    ];
  }

  String get _vpnTitle => switch (_vpnStatus) {
    'on' => 'VPN включён',
    'permission' => 'Ожидание разрешения Android',
    'starting' => 'Подключение VPN',
    'stopping' => 'Отключение VPN',
    'error' => 'Не удалось подключить VPN',
    _ => 'VPN выключен',
  };

  Widget _homeSubscription(BuildContext context, Subscription item) {
    final servers = item.servers.where((server) => !server.missing).toList();
    final expanded =
        _expandedSubscriptions[item.id] ??
        servers.any((server) => server.id == _selected);
    final probing = _inlineProbe == item.id;
    final canMeasure = _diagnostics != null && servers.isNotEmpty;
    final hasLatency = servers.any((server) => _latency(server.id) != null);
    final sort = _sortLatency.contains(item.id) && hasLatency;
    if (sort) {
      final position = {
        for (final (index, server) in servers.indexed) server.id: index,
      };
      servers.sort((first, second) {
        final a = _latency(first.id);
        final b = _latency(second.id);
        if (a == b) return position[first.id]!.compareTo(position[second.id]!);
        if (a == null) return 1;
        if (b == null) return -1;
        return a.compareTo(b);
      });
    }
    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: ListTile(
                  key: ValueKey('home-subscription-${item.id}'),
                  contentPadding: const EdgeInsets.only(left: 12),
                  leading: Icon(
                    expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 20,
                  ),
                  title: Text(
                    item.title.isEmpty ? 'Импортированные серверы' : item.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text('Доступно ${servers.length}'),
                  onTap: () => setState(
                    () => _expandedSubscriptions[item.id] = !expanded,
                  ),
                ),
              ),
              if (item.canRefresh)
                IconButton(
                  tooltip: 'Обновить подписку',
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: _importing || _validating || probing
                      ? null
                      : () => _refresh(item.id),
                ),
              if (canMeasure)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: IconButton(
                    key: ValueKey('home-probe-${item.id}'),
                    tooltip: probing
                        ? 'Остановить замер'
                        : 'Проверить всю подписку',
                    icon: Icon(
                      probing
                          ? Icons.stop_circle_outlined
                          : Icons.speed_rounded,
                    ),
                    onPressed: probing
                        ? (_cancelInlineProbe
                              ? null
                              : () => _checkSubscription(item))
                        : _inlineProbe != null || _importing || _validating
                        ? null
                        : () => _checkSubscription(item),
                  ),
                ),
            ],
          ),
          if (expanded) ...[
            const Divider(height: 1),
            if (probing) const LinearProgressIndicator(),
            if (_probeError == item.id)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                child: Text(
                  'Не удалось измерить задержку',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            SubscriptionDetails(subscription: item, compact: true),
            if (hasLatency)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilterChip(
                    selected: sort,
                    label: const Text('Сначала быстрые'),
                    onSelected: probing
                        ? null
                        : (selected) => setState(() {
                            if (selected) {
                              _sortLatency.add(item.id);
                            } else {
                              _sortLatency.remove(item.id);
                            }
                          }),
                  ),
                ),
              ),
            for (final (index, server) in servers.indexed) ...[
              if (index > 0)
                const Divider(height: 1, indent: 16, endIndent: 16),
              _homeServer(server),
            ],
          ],
        ],
      ),
    );
  }

  Widget _homeServer(Server server) {
    final ms = _latency(server.id);
    final row = _latencies[server.id]?.firstOrNull;
    final delay = ms != null
        ? '$ms мс'
        : (row == null ? null : probeRowLabel(row));
    final selected = server.id == _selected;
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      key: ValueKey('home-server-${server.id}'),
      visualDensity: VisualDensity.compact,
      selected: selected,
      selectedTileColor: colors.primary.withValues(alpha: 0.08),
      title: Text(server.name),
      subtitle: Text(server.protocol),
      trailing: delay == null && !selected
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (delay != null)
                  Text(
                    delay,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: ms == null
                          ? colors.onSurfaceVariant
                          : colors.primary,
                    ),
                  ),
                if (selected) ...[
                  if (delay != null) const SizedBox(width: 5),
                  const Icon(
                    Icons.check_rounded,
                    size: 18,
                    semanticLabel: 'Выбран',
                  ),
                ],
              ],
            ),
      onTap: _importing || _validating
          ? null
          : () => _saveSettings(selected: server.id),
    );
  }

  void _openVpnControls() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Настройки VPN')),
          body: ListView(
            children: [
              if (_diagnostics case final DiagnosticsControl core)
                ListTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('Журнал VPN'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => VPNJournalPage(core: core),
                    ),
                  ),
                ),
              if (widget.core case final VPNSystemSettings settings)
                ListTile(
                  leading: const Icon(Icons.shield_outlined),
                  title: const Text('Защита VPN'),
                  subtitle: const Text(
                    'Постоянный VPN и блокировка соединений',
                  ),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () async {
                    try {
                      await settings.openVpnSettings();
                    } on PlatformException {
                      if (mounted) {
                        _notify('Откройте VPN в настройках Android.');
                      }
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _connectionActions() {
    final canStop = _vpnStatus == 'on' || _vpnStatus == 'starting';
    final canStart = _selected != null && ['off', 'error'].contains(_vpnStatus);
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_pendingReconnect && _vpnStatus == 'on')
              TextButton.icon(
                onPressed: _changingVpn ? null : _reconnect,
                icon: const Icon(Icons.sync_rounded),
                label: const Text('Переподключить и применить настройки'),
              ),
            if (_tab == 0)
              FilledButton.icon(
                key: const ValueKey('sticky-connect'),
                style: FilledButton.styleFrom(
                  backgroundColor: canStop
                      ? colors.surfaceContainerHigh
                      : colors.onSurface,
                  foregroundColor: canStop ? colors.onSurface : colors.surface,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: !_changingVpn && (canStart || canStop)
                    ? _toggleVPN
                    : null,
                icon: const Icon(Icons.power_settings_new),
                label: Text(canStop ? 'Отключить VPN' : 'Подключить VPN'),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _subscriptionPage(BuildContext context) {
    final query = _subscriptionQuery.trim().toLowerCase();
    final visible = _subscriptions.where(
      (item) =>
          query.isEmpty ||
          item.title.toLowerCase().contains(query) ||
          item.servers.any(
            (server) =>
                server.name.toLowerCase().contains(query) ||
                server.protocol.toLowerCase().contains(query),
          ),
    );
    return [
      if (_subscriptions.isNotEmpty)
        TextFormField(
          key: const ValueKey('subscription-search'),
          initialValue: _subscriptionQuery,
          onChanged: (value) => setState(() => _subscriptionQuery = value),
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search_rounded),
            hintText: 'Найти сервер или подписку',
          ),
        ),
      const SizedBox(height: 10),
      FilledButton.icon(
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
      if (widget.core case final ServerGroupControl control)
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('Управление группами'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openServerGroups(control),
        ),
      if (_subscriptions.isEmpty)
        const Card(
          child: ListTile(
            leading: Icon(Icons.layers_outlined),
            title: Text('Подписок пока нет'),
            subtitle: Text('Импортируйте HTTPS-ссылку, Hysteria 2 или VLESS.'),
          ),
        ),
      if (_subscriptions.isNotEmpty && visible.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Text('Серверы и подписки не найдены.'),
        ),
      for (final subscription in visible)
        Card(
          child: ExpansionTile(
            key: PageStorageKey((
              'subscription:${subscription.id}',
              query.isNotEmpty,
            )),
            initiallyExpanded: query.isNotEmpty,
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
                  title: Text(
                    subscription.id == 'server-groups'
                        ? 'Проверить все группы'
                        : 'Проверить всю подписку',
                  ),
                  onTap: _inlineProbe != null
                      ? null
                      : () => _openProbe('subscription', subscription.id),
                ),
              if (subscription.canRefresh)
                ListTile(
                  leading: const Icon(Icons.refresh_rounded),
                  title: const Text('Обновить подписку'),
                  onTap: _importing || _validating
                      ? null
                      : () => _refresh(subscription.id),
                ),
              SubscriptionDetails(subscription: subscription),
              for (final server in subscription.servers.where(
                (server) =>
                    query.isEmpty ||
                    subscription.title.toLowerCase().contains(query) ||
                    server.name.toLowerCase().contains(query) ||
                    server.protocol.toLowerCase().contains(query),
              ))
                ListTile(
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
                          onPressed: _inlineProbe != null
                              ? null
                              : () => _openProbe('profile', server.id),
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

  List<Widget> _rulesPage() {
    return [
      if (_routing != null) ...[
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.layers_outlined),
                title: const Text('Профили правил'),
                subtitle: Text(
                  _routingProfiles
                          .where(
                            (profile) => profile.id == _activeRoutingProfile,
                          )
                          .firstOrNull
                          ?.name ??
                      'Основной',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _validating || _importing ? null : _openRuleProfiles,
              ),
              const Divider(height: 1, indent: 54, endIndent: 14),
              ListTile(
                leading: const Icon(Icons.search_rounded),
                title: const Text('Проверить адрес'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _validating || _importing ? null : _openRouteCheck,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
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
      if (_rules.isNotEmpty)
        Card(
          child: Column(
            children: [
              for (var index = 0; index < _rules.length; index++) ...[
                if (index > 0)
                  const Divider(height: 1, indent: 54, endIndent: 14),
                _ruleTile(index),
              ],
            ],
          ),
        ),
    ];
  }

  List<Widget> _ruleSettings() {
    return [
      Card(
        child: ListTile(
          leading: const Icon(Icons.alt_route_rounded),
          title: const Text('Трафик без правила'),
          subtitle: Text(_defaultAction.label),
          trailing: PopupMenuButton<RouteAction>(
            tooltip: 'Выбрать маршрут по умолчанию',
            initialValue: _defaultAction,
            enabled: !_validating && !_importing,
            onSelected: (value) => _saveSettings(defaultAction: value),
            itemBuilder: (_) => [
              for (final action in RouteAction.values)
                PopupMenuItem(value: action, child: Text(action.label)),
            ],
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
      if (_vpn != null)
        Card(
          child: ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Раздельный DNS'),
            subtitle: Text(
              _splitDns == null
                  ? 'Выключен'
                  : 'Доменов напрямую: ${_splitDns!.domains.length}',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SplitDnsPage(
                  settings: _splitDns,
                  save: (dns) => _saveSettings(
                    splitDns: dns,
                    changeSplitDns: true,
                    inline: true,
                  ),
                ),
              ),
            ),
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
          onTap:
              _chainServers.isEmpty ||
                  (_servers.length < 2 && _via.isEmpty) ||
                  _validating
              ? null
              : _editChain,
        ),
      ),
    ];
  }

  Widget _ruleTile(int index) {
    final rule = _rules[index];
    final label = rule.server.isEmpty
        ? rule.action.label
        : _serverName(rule.server);
    return ListTile(
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
