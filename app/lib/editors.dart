import 'package:flutter/material.dart';

import 'core.dart';

final _packageId = RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*$');

class SubscriptionEditor extends StatefulWidget {
  const SubscriptionEditor({super.key});

  @override
  State<SubscriptionEditor> createState() => _SubscriptionEditorState();
}

class _SubscriptionEditorState extends State<SubscriptionEditor> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Добавить подписку'),
      content: TextField(
        controller: _input,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        minLines: 3,
        maxLines: 6,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: 'Подписка или ссылки серверов',
          hintText: 'https://…',
          alignLabelWithHint: true,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _input.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, _input.text.trim()),
          child: const Text('Импортировать'),
        ),
      ],
    );
  }
}

class RuleEditor extends StatefulWidget {
  const RuleEditor({
    super.key,
    required this.servers,
    required this.android,
    required this.pickGeoTag,
    this.destination,
    this.initial,
  });

  final List<Server> servers;
  final bool android;
  final Future<String?> Function() pickGeoTag;
  final String? destination;
  final RouteRule? initial;

  @override
  State<RuleEditor> createState() => _RuleEditorState();
}

class GeoCatalogDialog extends StatefulWidget {
  const GeoCatalogDialog({super.key, required this.core});

  final ClientCore core;

  @override
  State<GeoCatalogDialog> createState() => _GeoCatalogDialogState();
}

class _GeoCatalogDialogState extends State<GeoCatalogDialog> {
  var _tags = <String>[];
  var _query = '';
  var _busy = true;
  String? _error;

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
      if (mounted) setState(() => _tags = tags);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = update
              ? 'Не удалось обновить базы правил. Проверьте интернет.'
              : 'Не удалось прочитать базы правил.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final matches = _tags.where((tag) => tag.contains(_query)).toList();
    return AlertDialog(
      title: const Text('GeoSite и GeoIP'),
      content: SizedBox(
        width: 400,
        height: 300,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Источник runetfreedom · загрузка около 90 МБ'),
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            if (_error case final error?) Text(error),
            if (_tags.isNotEmpty) ...[
              TextField(
                autocorrect: false,
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
                decoration: const InputDecoration(labelText: 'Поиск категории'),
              ),
              Expanded(
                child: matches.isEmpty
                    ? const Center(child: Text('Категория не найдена.'))
                    : ListView.builder(
                        itemCount: matches.length,
                        itemBuilder: (context, index) => ListTile(
                          dense: true,
                          title: Text(matches[index]),
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
  late final _destination = TextEditingController(
    text: widget.initial?.destination ?? widget.destination,
  );
  late final _port = TextEditingController(text: widget.initial?.port);
  late final _package = TextEditingController(text: widget.initial?.package);
  late RouteAction _action = widget.initial?.action ?? RouteAction.tunnel;
  late String _server = widget.initial?.server ?? '';
  late String _protocol = widget.initial?.protocol ?? '';
  String? _error;

  @override
  void dispose() {
    _destination.dispose();
    _port.dispose();
    _package.dispose();
    super.dispose();
  }

  void _save() {
    final destination = _destination.text.trim();
    final port = _port.text.trim();
    final package = widget.android ? _package.text.trim() : '';
    if (destination.isEmpty &&
        port.isEmpty &&
        package.isEmpty &&
        _protocol.isEmpty) {
      setState(
        () => _error = 'Укажите домен, IP, порт, протокол или приложение.',
      );
      return;
    }
    if (package.isNotEmpty && !_packageId.hasMatch(package)) {
      setState(() => _error = 'Проверьте идентификатор пакета Android.');
      return;
    }
    Navigator.pop(
      context,
      RouteRule(
        action: _action,
        destination: destination,
        port: port,
        package: package,
        server: _action == RouteAction.tunnel ? _server : '',
        protocol: _protocol,
      ),
    );
  }

  Future<void> _addGeoTag() async {
    final tag = await widget.pickGeoTag();
    if (!mounted || tag == null) return;
    final current = _destination.text.trim();
    if (current.split('\n').any((line) => line.trim() == tag)) return;
    _destination.text = current.isEmpty ? tag : '$current\n$tag';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(widget.initial == null ? 'Новое правило' : 'Правило'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _destination,
            autocorrect: false,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Домены, IP и категории',
              hintText: '.example.org',
              helperText: 'По одному на строку',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addGeoTag,
              icon: const Icon(Icons.public_rounded),
              label: const Text('Выбрать GeoSite или GeoIP'),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _port,
            keyboardType: TextInputType.text,
            decoration: const InputDecoration(
              labelText: 'Порт или диапазон',
              hintText: '443',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _protocol,
            decoration: const InputDecoration(labelText: 'Протокол'),
            items: const [
              DropdownMenuItem(value: '', child: Text('Любой')),
              DropdownMenuItem(value: 'tcp', child: Text('TCP')),
              DropdownMenuItem(value: 'udp', child: Text('UDP')),
            ],
            onChanged: (value) => _protocol = value!,
          ),
          if (widget.android) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _package,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Пакет Android',
                hintText: 'org.example.app',
              ),
            ),
          ],
          const SizedBox(height: 12),
          DropdownButtonFormField<RouteAction>(
            initialValue: _action,
            decoration: const InputDecoration(labelText: 'Действие'),
            items: RouteAction.values
                .map(
                  (action) => DropdownMenuItem(
                    value: action,
                    child: Text(action.label),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => _action = value!),
          ),
          if (_action == RouteAction.tunnel) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: _server,
              decoration: const InputDecoration(labelText: 'VPN-профиль'),
              items: serverItems(
                widget.servers,
                emptyLabel: 'Основной профиль',
              ),
              onChanged: (value) => setState(() => _server = value!),
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
  const ChainEditor({super.key, required this.servers, required this.via});

  final List<Server> servers;
  final Map<String, String> via;

  @override
  State<ChainEditor> createState() => _ChainEditorState();
}

class _ChainEditorState extends State<ChainEditor> {
  late String _exit = widget.servers.first.id;
  late String _entry = widget.via[_exit] ?? '';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Цепочка профилей'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _exit,
            decoration: const InputDecoration(labelText: 'Выходной профиль'),
            items: serverItems(widget.servers),
            onChanged: (value) => setState(() {
              _exit = value!;
              _entry = widget.via[_exit] ?? '';
            }),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey(_exit),
            isExpanded: true,
            initialValue: _entry,
            decoration: const InputDecoration(labelText: 'Подключать через'),
            items: serverItems(
              widget.servers.where((server) => server.id != _exit).toList(),
              emptyLabel: 'Без промежуточного профиля',
            ),
            onChanged: (value) => setState(() => _entry = value!),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (_exit, _entry)),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

class ScopeEditor extends StatefulWidget {
  const ScopeEditor({super.key, required this.scope, required this.packages});

  final AppScope scope;
  final List<String> packages;

  @override
  State<ScopeEditor> createState() => _ScopeEditorState();
}

class _ScopeEditorState extends State<ScopeEditor> {
  late AppScope _scope = widget.scope;
  late final _packages = TextEditingController(
    text: widget.packages.join('\n'),
  );
  String? _error;

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
      setState(() => _error = 'Укажите хотя бы один корректный пакет Android.');
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
            TextField(
              controller: _packages,
              minLines: 2,
              maxLines: 5,
              autocorrect: false,
              enableSuggestions: false,
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
