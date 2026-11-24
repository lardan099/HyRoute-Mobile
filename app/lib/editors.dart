import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core.dart';

final _packageId = RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*$');

String geoListName(String tag) => switch (tag) {
  'geosite:youtube' => 'YouTube',
  'geosite:telegram' => 'Telegram',
  'geosite:discord' => 'Discord',
  'geosite:category-ads-all' => 'Реклама',
  'geoip:ru' => 'IP России',
  'geoip:private' => 'Локальная сеть',
  _ => tag,
};

class SubscriptionEditor extends StatefulWidget {
  const SubscriptionEditor({super.key, required this.onImport});

  final Future<String?> Function(String) onImport;

  @override
  State<SubscriptionEditor> createState() => _SubscriptionEditorState();
}

class _SubscriptionEditorState extends State<SubscriptionEditor> {
  final _input = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerClipboard());
  }

  Future<void> _offerClipboard() async {
    if (!mounted ||
        !await Clipboard.hasStrings() ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent != true ||
        _input.text.isNotEmpty) {
      return;
    }
    final allowed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Разрешить вставку?'),
        content: const Text('Вставить ссылку или конфиг из буфера обмена.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Не сейчас'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Разрешить'),
          ),
        ],
      ),
    );
    if (allowed != true || !mounted || _input.text.isNotEmpty) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || _input.text.isNotEmpty) return;
    final value = data?.text?.trim() ?? '';
    if (value.isEmpty) return;
    setState(() {
      _input.text = value;
      _error = null;
    });
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.onImport(_input.text.trim());
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Добавить подписку'),
          automaticallyImplyLeading: !_busy,
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _input,
                    enabled: !_busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    minLines: 4,
                    maxLines: 9,
                    onChanged: (_) => setState(() => _error = null),
                    decoration: const InputDecoration(
                      labelText: 'Ссылка или конфиг',
                      hintText: 'https://…',
                      alignLabelWithHint: true,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (_busy) const LinearProgressIndicator(),
                    FilledButton(
                      onPressed: _busy || _input.text.trim().isEmpty
                          ? null
                          : _submit,
                      child: Text(_busy ? 'Импортируем…' : 'Импортировать'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RuleEditor extends StatefulWidget {
  const RuleEditor({
    super.key,
    required this.servers,
    required this.android,
    required this.pickGeoTag,
    required this.pickProfile,
    required this.save,
    this.pickApp,
    this.destination,
    this.initial,
  });

  final List<Server> servers;
  final bool android;
  final Future<String?> Function() pickGeoTag;
  final Future<String?> Function(String) pickProfile;
  final Future<String?> Function(RouteRule) save;
  final Future<MapEntry<String, String>?> Function()? pickApp;
  final String? destination;
  final RouteRule? initial;

  @override
  State<RuleEditor> createState() => _RuleEditorState();
}

class GeoCatalogDialog extends StatefulWidget {
  const GeoCatalogDialog({
    super.key,
    required this.core,
    this.manageSources = false,
  });

  final ClientCore core;
  final bool manageSources;

  @override
  State<GeoCatalogDialog> createState() => _GeoCatalogDialogState();
}

class _GeoCatalogDialogState extends State<GeoCatalogDialog> {
  var _tags = <String>[];
  var _query = '';
  var _busy = true;
  String? _error;
  var _sources = <String, String>{};

  MaintenanceControl? get _maintenance {
    final core = widget.core;
    return widget.manageSources && core is MaintenanceControl
        ? core as MaintenanceControl
        : null;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool update = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (update) await widget.core.updateGeo();
      final tags = await widget.core.geoTags();
      final sources = await _maintenance?.geoSources();
      if (mounted) {
        setState(() {
          _tags = tags;
          _sources = sources ?? {};
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = update
              ? 'Не удалось обновить базы. Проверьте источник и наличие используемых категорий.'
              : 'Не удалось прочитать базы правил.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeSource(String kind, bool importing) async {
    final maintenance = _maintenance;
    if (maintenance == null || _busy) return;
    String? source;
    if (!importing) {
      var address = _sources[kind == 'geosite' ? 'site' : 'ip'] ?? '';
      if (address == 'file') address = '';
      source = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('$kind.dat'),
          content: TextFormField(
            initialValue: address,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Ссылка HTTPS'),
            onChanged: (value) => address = value,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, ''),
              child: const Text('runetfreedom'),
            ),
            FilledButton(
              onPressed: () {
                if (address.trim().isNotEmpty) {
                  Navigator.pop(dialog, address.trim());
                }
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      );
      if (!mounted || source == null) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (importing) {
        if (!await maintenance.importGeoFile(kind)) return;
      } else {
        await maintenance.setGeoSource(kind, source!);
      }
      if (mounted) await _load(update: !importing);
    } on PlatformException {
      if (mounted) {
        setState(
          () => _error = importing
              ? 'Не удалось импортировать $kind.dat. Проверьте тип файла.'
              : 'Укажите ссылку HTTPS на файл базы.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final matches = _tags
        .where(
          (tag) =>
              tag.contains(_query) ||
              geoListName(tag).toLowerCase().contains(_query),
        )
        .toList();
    return AlertDialog(
      title: Text(widget.manageSources ? 'GeoSite и GeoIP' : 'Готовые списки'),
      content: SizedBox(
        width: 400,
        height: 300,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_maintenance != null)
              Wrap(
                spacing: 8,
                children: [
                  for (final kind in ['geosite', 'geoip'])
                    PopupMenuButton<bool>(
                      enabled: !_busy,
                      tooltip: 'Источник $kind.dat',
                      onSelected: (importing) => _changeSource(kind, importing),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: true,
                          child: Text('Импортировать файл'),
                        ),
                        PopupMenuItem(
                          value: false,
                          child: Text('Указать ссылку'),
                        ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text('$kind.dat ▾'),
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            if (_error case final error?) Text(error),
            if (_tags.isNotEmpty) ...[
              TextField(
                autocorrect: false,
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
                decoration: const InputDecoration(
                  labelText: 'Найти список',
                  hintText: 'YouTube',
                ),
              ),
              Expanded(
                child: matches.isEmpty
                    ? const Center(child: Text('Категория не найдена.'))
                    : ListView.builder(
                        itemCount: matches.length,
                        itemBuilder: (context, index) => ListTile(
                          dense: true,
                          title: Text(geoListName(matches[index])),
                          subtitle:
                              geoListName(matches[index]) == matches[index]
                              ? null
                              : Text(matches[index]),
                          onTap: () => Navigator.pop(context, matches[index]),
                        ),
                      ),
              ),
            ] else if (!_busy && _error == null)
              const Text('Скачайте базы, чтобы выбрать категорию.'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _load(update: true),
          child: Text(_tags.isEmpty ? 'Скачать' : 'Обновить'),
        ),
      ],
    );
  }
}

class _RuleEditorState extends State<RuleEditor> {
  late final _stored = (widget.initial?.destination ?? widget.destination ?? '')
      .split('\n');
  late final _conditions = {
    for (final kind in RuleDomainCondition.values)
      kind: TextEditingController(
        text: _stored.map(kind.valueFrom).whereType<String>().join('\n'),
      ),
  };
  late final _expandedConditions = {
    for (final kind in RuleDomainCondition.values)
      if (_conditions[kind]!.text.isNotEmpty) kind,
  };
  late final _destination = TextEditingController(
    text: _stored
        .where(
          (item) => !RuleDomainCondition.values.any(
            (kind) => kind.valueFrom(item) != null,
          ),
        )
        .join('\n'),
  );
  late final _port = TextEditingController(text: widget.initial?.port);
  late final _package = TextEditingController(text: widget.initial?.package);
  late RouteAction _action = widget.initial?.action ?? RouteAction.tunnel;
  late String _server = widget.initial?.server ?? '';
  late String _protocol = widget.initial?.protocol ?? '';
  late bool _advanced = _port.text.isNotEmpty || _protocol.isNotEmpty;
  late String? _appName = widget.initial?.appName.isNotEmpty == true
      ? widget.initial!.appName
      : null;
  String? _error;
  var _saving = false;

  @override
  void dispose() {
    _destination.dispose();
    for (final controller in _conditions.values) {
      controller.dispose();
    }
    _port.dispose();
    _package.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final destinations = ruleDestinations(_destination.text);
    for (final kind in RuleDomainCondition.values) {
      final patterns = kind.patterns(_conditions[kind]!.text);
      if (patterns == null) {
        setState(
          () => _error =
              'Проверьте условие «${kind.label}». Пример ${kind.example}.',
        );
        return;
      }
      destinations.addAll(patterns);
    }
    final port = _port.text.trim();
    final package = widget.android ? _package.text.trim() : '';
    if (destinations.isEmpty &&
        port.isEmpty &&
        package.isEmpty &&
        _protocol.isEmpty) {
      setState(() => _error = 'Укажите сайт, IP или условие для домена.');
      return;
    }
    if (package.isNotEmpty && !_packageId.hasMatch(package)) {
      setState(() => _error = 'Проверьте идентификатор приложения Android.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.save(
      RouteRule(
        action: _action,
        destination: destinations.toSet().join('\n'),
        port: port,
        package: package,
        appName: _appName ?? '',
        server: _action == RouteAction.tunnel ? _server : '',
        protocol: _protocol,
        stored: widget.initial?.stored ?? const {},
      ),
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  void _appendDestination(String? value) {
    if (!mounted || value == null || value.trim().isEmpty) return;
    setState(() {
      _destination.text = ruleDestinations(
        '${_destination.text}\n$value',
      ).join('\n');
      _error = null;
    });
  }

  Future<void> _chooseApp() async {
    final app = await widget.pickApp?.call();
    if (!mounted || app == null) return;
    setState(() {
      _package.text = app.key;
      _appName = app.value;
      _error = null;
    });
  }

  Future<void> _chooseProfile() async {
    final id = await widget.pickProfile(_server);
    if (mounted && id != null) setState(() => _server = id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = widget.servers
        .where((server) => server.id == _server)
        .firstOrNull;
    final destinations = ruleDestinations(_destination.text);
    final hasURL =
        destinations.join('\n') != _destination.text.trim() &&
        RegExp(
          r'^https?://',
          multiLine: true,
          caseSensitive: false,
        ).hasMatch(_destination.text);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? 'Новое правило' : 'Правило'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  Text('Что направить?', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _destination,
                    enabled: !_saving,
                    autocorrect: false,
                    enableSuggestions: false,
                    minLines: 1,
                    maxLines: 4,
                    onChanged: (_) => setState(() => _error = null),
                    decoration: const InputDecoration(
                      labelText: 'Сайт, ссылка или IP',
                      hintText: 'youtube.com',
                    ),
                  ),
                  if (hasURL)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'В правило попадёт: ${destinations.join(', ')}',
                      ),
                    ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.content_paste_rounded, size: 18),
                        label: const Text('Вставить'),
                        onPressed: _saving
                            ? null
                            : () async {
                                _appendDestination(
                                  (await Clipboard.getData(
                                    Clipboard.kTextPlain,
                                  ))?.text,
                                );
                              },
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.public_rounded, size: 18),
                        label: const Text('Готовый список'),
                        onPressed: _saving
                            ? null
                            : () async =>
                                  _appendDestination(await widget.pickGeoTag()),
                      ),
                      if (widget.pickApp != null)
                        TextButton.icon(
                          icon: const Icon(Icons.apps_rounded, size: 18),
                          label: const Text('Приложение'),
                          onPressed: _saving ? null : _chooseApp,
                        ),
                    ],
                  ),
                  if (_package.text.isNotEmpty)
                    InputChip(
                      label: Text(_appName ?? _package.text),
                      onDeleted: _saving
                          ? null
                          : () => setState(() {
                              _package.clear();
                              _appName = null;
                            }),
                    ),
                  const SizedBox(height: 14),
                  Text('Куда?', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 7,
                    runSpacing: 2,
                    children: [
                      for (final action in RouteAction.values)
                        ChoiceChip(
                          label: Text(action.label),
                          selected: _action == action,
                          onSelected: _saving
                              ? null
                              : (_) => setState(() => _action = action),
                        ),
                    ],
                  ),
                  Text(_action.help, style: theme.textTheme.bodySmall),
                  if (_action == RouteAction.tunnel)
                    TextButton.icon(
                      icon: const Icon(Icons.dns_outlined),
                      label: Text(
                        profile?.name ??
                            (_server.isEmpty
                                ? 'Основной профиль'
                                : 'Профиль недоступен'),
                      ),
                      onPressed: _saving ? null : _chooseProfile,
                    ),
                  for (final kind in RuleDomainCondition.values) ...[
                    TextButton.icon(
                      icon: Icon(
                        _expandedConditions.contains(kind)
                            ? Icons.expand_less
                            : Icons.expand_more,
                      ),
                      label: Text(kind.label),
                      onPressed: _saving
                          ? null
                          : () => setState(() {
                              if (!_expandedConditions.remove(kind)) {
                                _expandedConditions.add(kind);
                              }
                            }),
                    ),
                    if (_expandedConditions.contains(kind)) ...[
                      TextField(
                        key: ValueKey(kind),
                        controller: _conditions[kind],
                        enabled: !_saving,
                        minLines: 1,
                        maxLines: 4,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: kind.label,
                          hintText: kind.example,
                        ),
                        onChanged: (_) => setState(() => _error = null),
                      ),
                      const SizedBox(height: 6),
                      Text(kind.exampleMatch, style: theme.textTheme.bodySmall),
                    ],
                  ],
                  const SizedBox(height: 8),
                  TextButton.icon(
                    icon: Icon(
                      _advanced ? Icons.expand_less : Icons.expand_more,
                    ),
                    label: const Text('Дополнительные условия'),
                    onPressed: _saving
                        ? null
                        : () => setState(() => _advanced = !_advanced),
                  ),
                  if (_advanced) ...[
                    TextField(
                      controller: _port,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                        labelText: 'Порт или диапазон',
                        hintText: '443',
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: _protocol,
                      decoration: const InputDecoration(labelText: 'Протокол'),
                      items: const [
                        DropdownMenuItem(value: '', child: Text('Любой')),
                        DropdownMenuItem(value: 'tcp', child: Text('TCP')),
                        DropdownMenuItem(value: 'udp', child: Text('UDP')),
                      ],
                      onChanged: _saving ? null : (value) => _protocol = value!,
                    ),
                    if (widget.android) ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: _package,
                        enabled: !_saving,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Идентификатор приложения',
                          hintText: 'org.example.app',
                        ),
                        onChanged: (_) => setState(() => _appName = null),
                      ),
                    ],
                  ],
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('Отмена'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Сохранение…' : 'Сохранить'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<DropdownMenuItem<String>> serverItems(
  List<Server> servers, {
  String? emptyLabel,
}) {
  return [
    if (emptyLabel != null)
      DropdownMenuItem(value: '', child: Text(emptyLabel)),
    for (final server in servers)
      DropdownMenuItem(
        value: server.id,
        child: Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
  ];
}

class ChainEditor extends StatefulWidget {
  const ChainEditor({
    super.key,
    required this.servers,
    required this.entries,
    required this.via,
    required this.save,
  });

  final List<Server> servers;
  final List<Server> entries;
  final Map<String, String> via;
  final Future<String?> Function(String exit, String entry) save;

  @override
  State<ChainEditor> createState() => _ChainEditorState();
}

class _ChainEditorState extends State<ChainEditor> {
  String? _exit;
  var _entry = '';
  var _saving = false;
  String? _error;

  Future<void> _save(String entry) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.save(_exit!, entry);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries
        .where((server) => server.id != _exit)
        .toList();
    final entryExists = entries.any((server) => server.id == _entry);
    final saved = widget.via[_exit];
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        scrollable: true,
        title: const Text('Цепочка профилей'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              key: const ValueKey('chain-exit'),
              isExpanded: true,
              initialValue: _exit,
              hint: const Text('Выбрать выходной профиль'),
              decoration: const InputDecoration(labelText: 'Выходной профиль'),
              items: serverItems(widget.servers),
              onChanged: _saving
                  ? null
                  : (value) => setState(() {
                      _exit = value!;
                      _entry = widget.via[_exit] ?? '';
                      _error = null;
                    }),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey(_exit),
              isExpanded: true,
              initialValue: entryExists ? _entry : '',
              decoration: const InputDecoration(labelText: 'Подключать через'),
              items: serverItems(
                entries,
                emptyLabel: 'Без промежуточного профиля',
              ),
              onChanged: _saving || _exit == null
                  ? null
                  : (value) => setState(() {
                      _entry = value!;
                      _error = null;
                    }),
            ),
            if (!entryExists && _entry.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Первый профиль недоступен. Выберите замену.'),
              ),
            if (_error case final String error)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          if (saved != null)
            TextButton(
              onPressed: _saving ? null : () => _save(''),
              child: const Text('Удалить связь'),
            ),
          FilledButton(
            onPressed:
                _saving || _exit == null || !entryExists || saved == _entry
                ? null
                : () => _save(_entry),
            child: Text(_saving ? 'Сохраняем…' : 'Сохранить'),
          ),
        ],
      ),
    );
  }
}

class AppPicker extends StatefulWidget {
  const AppPicker({super.key, required this.core, this.existing});

  final ClientCore core;
  final List<String>? existing;

  @override
  State<AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<AppPicker> {
  late final _load = widget.core.launchableApps();
  late final _selected = {...?widget.existing};
  var _query = '';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.existing == null ? 'Выбрать приложение' : 'Выбрать приложения',
    ),
    content: SizedBox(
      width: 400,
      height: 330,
      child: Column(
        children: [
          TextField(
            decoration: const InputDecoration(labelText: 'Найти приложение'),
            onChanged: (value) =>
                setState(() => _query = value.trim().toLowerCase()),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<Map<String, String>>(
              future: _load,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Text('Не удалось открыть список приложений.'),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final apps =
                    snapshot.data!.entries
                        .where(
                          (app) =>
                              app.value.toLowerCase().contains(_query) ||
                              app.key.toLowerCase().contains(_query),
                        )
                        .toList()
                      ..sort(
                        (a, b) => a.value.toLowerCase().compareTo(
                          b.value.toLowerCase(),
                        ),
                      );
                if (apps.isEmpty) {
                  return const Center(child: Text('Приложение не найдено.'));
                }
                return ListView.builder(
                  itemCount: apps.length,
                  itemBuilder: (context, index) {
                    final app = apps[index];
                    if (widget.existing == null) {
                      return ListTile(
                        title: Text(app.value),
                        onTap: () => Navigator.pop(context, [app]),
                      );
                    }
                    return CheckboxListTile(
                      title: Text(app.value),
                      value: _selected.contains(app.key),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          _selected.add(app.key);
                        } else {
                          _selected.remove(app.key);
                        }
                      }),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      if (widget.existing != null)
        FilledButton(
          onPressed: () => Navigator.pop(context, [
            for (final id in _selected) MapEntry(id, id),
          ]),
          child: Text('Готово (${_selected.length})'),
        ),
    ],
  );
}

class ScopeEditor extends StatefulWidget {
  const ScopeEditor({
    super.key,
    required this.scope,
    required this.packages,
    required this.pickApps,
  });

  final AppScope scope;
  final List<String> packages;
  final Future<List<MapEntry<String, String>>?> Function(List<String>) pickApps;

  @override
  State<ScopeEditor> createState() => _ScopeEditorState();
}

class _ScopeEditorState extends State<ScopeEditor> {
  late AppScope _scope = widget.scope;
  late final _packages = TextEditingController(
    text: widget.packages.join('\n'),
  );
  String? _error;
  bool _manual = false;

  List<String> get _selection => _packages.text
      .split(RegExp(r'[\s,]+'))
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList();

  @override
  void dispose() {
    _packages.dispose();
    super.dispose();
  }

  void _save() {
    final packages = _scope == AppScope.all
        ? <String>[]
        : _packages.text
              .split(RegExp(r'[\s,]+'))
              .where((text) => text.isNotEmpty)
              .toSet()
              .toList();
    if (_scope != AppScope.all &&
        (packages.isEmpty ||
            packages.any((package) => !_packageId.hasMatch(package)))) {
      setState(
        () => _error = packages.isEmpty
            ? 'Выберите хотя бы одно приложение.'
            : 'Проверьте введённые идентификаторы приложений.',
      );
      return;
    }
    Navigator.pop(context, (_scope, packages));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Приложения в VPN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<AppScope>(
            initialValue: _scope,
            decoration: const InputDecoration(labelText: 'Режим'),
            isExpanded: true,
            items: AppScope.values
                .map(
                  (scope) =>
                      DropdownMenuItem(value: scope, child: Text(scope.label)),
                )
                .toList(),
            onChanged: (value) => setState(() {
              _scope = value!;
              _error = null;
            }),
          ),
          if (_scope != AppScope.all) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.apps_rounded),
              label: Text(
                _selection.isEmpty
                    ? 'Выбрать приложения'
                    : 'Выбрано: ${_selection.length}',
              ),
              onPressed: () async {
                final apps = await widget.pickApps(_selection);
                if (mounted && apps != null) {
                  setState(() {
                    _packages.text = apps.map((app) => app.key).join('\n');
                    _error = null;
                  });
                }
              },
            ),
            TextButton(
              onPressed: () => setState(() => _manual = !_manual),
              child: const Text('Указать идентификаторы вручную'),
            ),
            if (_manual)
              TextField(
                controller: _packages,
                minLines: 2,
                maxLines: 5,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Пакеты Android, по одному на строку',
                  hintText: 'org.example.app',
                ),
              ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(onPressed: _save, child: const Text('Сохранить')),
      ],
    );
  }
}
