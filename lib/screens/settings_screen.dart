import 'package:flutter/material.dart';
import '../services/gemini_service.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final Map<String, TextEditingController> _c = {
    for (final f in SettingsService.fields) f.key: TextEditingController(),
  };

  bool _hide = true;
  bool _loading = true;
  bool _fetching = false;
  String? _model;
  List<String> _models = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    for (final f in SettingsService.fields) {
      _c[f.key]!.text = await SettingsService.get(f.key);
    }
    final m = await SettingsService.get(SettingsService.modelKey);
    if (!mounted) return;
    setState(() {
      if (m.isNotEmpty) {
        _model = m;
        _models = [m];
      }
      _loading = false;
    });
  }

  void _toast(String t) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _fetchModels() async {
    var key = '';
    for (var i = 1; i <= 4; i++) {
      final k = _c['gemini_key_$i']!.text.trim();
      if (k.isNotEmpty) {
        key = k;
        break;
      }
    }
    if (key.isEmpty) {
      _toast('أدخل مفتاح Gemini أولاً');
      return;
    }
    setState(() => _fetching = true);
    try {
      final list = await GeminiService.listModels(key);
      if (!mounted) return;
      setState(() {
        _models = list;
        if (_model == null || !list.contains(_model)) {
          _model = list.isNotEmpty ? list.first : null;
        }
      });
      _toast('تم جلب ${list.length} نموذج');
    } catch (e) {
      _toast('فشل الجلب: $e');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _save() async {
    for (final f in SettingsService.fields) {
      await SettingsService.set(f.key, _c[f.key]!.text);
    }
    await SettingsService.set(SettingsService.modelKey, _model ?? '');
    if (!mounted) return;
    _toast('تم الحفظ');
  }

  Widget _header(String t) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 10),
        child: Text(
          t,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: Color(0xFFC6F750),
          ),
        ),
      );

  Widget _field(SettingField f) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: _c[f.key],
          obscureText: _hide && !f.plain && !f.multiline,
          minLines: f.multiline ? 4 : 1,
          maxLines: f.multiline ? 8 : 1,
          keyboardType:
              f.multiline ? TextInputType.multiline : TextInputType.text,
          textDirection: TextDirection.ltr,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: f.label, hintText: f.hint),
        ),
      );

  List<Widget> _modelPicker() => [
        OutlinedButton.icon(
          onPressed: _fetching ? null : _fetchModels,
          icon: _fetching
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_download_rounded),
          label: const Text('جلب نماذج Gemini'),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _model,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'النموذج المستخدم'),
          items: _models
              .map((m) => DropdownMenuItem(
                    value: m,
                    child: Text(m, overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: (v) => setState(() => _model = v),
        ),
        const SizedBox(height: 12),
      ];

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    String? last;
    for (final f in SettingsService.fields) {
      if (f.group != last) {
        if (last == 'Gemini') items.addAll(_modelPicker());
        items.add(_header(f.group));
        last = f.group;
      }
      items.add(_field(f));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('الإعدادات'),
        actions: [
          IconButton(
            onPressed: () => setState(() => _hide = !_hide),
            icon: Icon(_hide
                ? Icons.visibility_rounded
                : Icons.visibility_off_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              children: items,
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_rounded),
            label: const Text('حفظ'),
          ),
        ),
      ),
    );
  }
}
