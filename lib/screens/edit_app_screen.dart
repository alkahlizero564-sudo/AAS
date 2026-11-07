import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/ai_service.dart';
import '../services/project_store.dart';
import '../services/settings_service.dart';
import 'release_screen.dart';

const _editSystem = r'''
You are a senior Flutter engineer modifying an EXISTING mobile app. You receive JSON: {"instruction": "...", "files": {"lib/app_home.dart": "...", ...}}.

Apply the instruction (add, change or delete something). Return ONLY the files that change or are new, in this plain-text format (no markdown fences):
=== FILE: lib/some_file.dart ===
<full new content of the file>
=== END ===

To delete a file output a line:
=== DELETE: lib/some_file.dart ===

Rules:
- Always return the COMPLETE content of a changed file, never a diff.
- Never write or delete lib/main.dart, lib/login_screen.dart or lib/update_gate.dart (they exist and are managed by the system).
- lib/app_home.dart must keep a class named AppHome with a const constructor: const AppHome({super.key}). Never delete it.
- Allowed imports: package:flutter/material.dart, dart:* libraries, package:supabase_flutter/supabase_flutter.dart. No other packages.
- The code must compile: no placeholders, every import present, every referenced class defined.
- Keep the existing modern, luxurious Arabic RTL design style.
''';

const _protected = {
  'lib/main.dart',
  'lib/login_screen.dart',
  'lib/update_gate.dart',
};

class EditAppScreen extends StatefulWidget {
  const EditAppScreen({super.key});

  @override
  State<EditAppScreen> createState() => _EditAppScreenState();
}

class _EditAppScreenState extends State<EditAppScreen> {
  final _instr = TextEditingController();
  final List<String> _names = [];
  final List<String> _log = [];
  int _sel = 0;
  bool _loaded = false;
  String? _busy;
  bool _applied = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _instr.dispose();
    super.dispose();
  }

  void _addLog(String s) {
    if (!mounted) return;
    setState(() {
      _log.add(s);
      if (_log.length > 8) _log.removeAt(0);
    });
  }

  Future<void> _load() async {
    try {
      final raw = await SettingsService.get('project_spec');
      if (raw.isNotEmpty) {
        final spec = jsonDecode(raw) as Map<String, dynamic>;
        for (final a in (spec['apps'] as List? ?? [])) {
          _names.add(((a as Map)['name'] ?? '').toString());
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loaded = true);
  }

  Future<Map<String, String>> _readLib(String dir) async {
    final out = <String, String>{};
    for (final rel in await ProjectStore.list()) {
      if (rel.startsWith('$dir/lib/') && rel.endsWith('.dart')) {
        final sub = rel.substring(dir.length + 1);
        if (_protected.contains(sub)) continue;
        final t = await ProjectStore.read(rel);
        if (t != null) out[sub] = t;
      }
    }
    return out;
  }

  bool _okPath(String p) =>
      p.startsWith('lib/') &&
      p.endsWith('.dart') &&
      !p.contains('..') &&
      !_protected.contains(p);

  String _strip(String s) => s
      .replaceAll(RegExp(r'^```[a-zA-Z]*[ \t]*\r?\n?', multiLine: true), '')
      .trim();

  Future<void> _apply() async {
    final text = _instr.text.trim();
    if (text.isEmpty || _busy != null || _names.isEmpty) return;
    final dir = 'app${_sel + 1}';
    setState(() {
      _busy = 'جاري تعديل الكود...';
      _applied = false;
    });
    try {
      final files = await _readLib(dir);
      if (!files.containsKey('lib/app_home.dart')) {
        throw Exception('ما في كود لهذا التطبيق. ولّد الكود أولاً.');
      }
      final raw = await AiService.ask(
        _editSystem,
        [ChatTurn(true, jsonEncode({'instruction': text, 'files': files}))],
        json: false,
        maxTokens: 14000,
      );

      final re = RegExp(
          r'=== FILE: (.+?) ===\r?\n([\s\S]*?)(?:\r?\n=== END ===|$)');
      final changed = <String, String>{};
      for (final m in re.allMatches(raw)) {
        final p = (m.group(1) ?? '').trim();
        final body = _strip(m.group(2) ?? '');
        if (_okPath(p) && body.isNotEmpty) changed[p] = body;
      }
      final deletes = RegExp(r'=== DELETE: (.+?) ===')
          .allMatches(raw)
          .map((m) => m.group(1)!.trim())
          .where((p) => _okPath(p) && p != 'lib/app_home.dart')
          .toList();

      if (changed.isEmpty && deletes.isEmpty) {
        throw Exception('ما حصل تعديل. وضّح الطلب أكتر وحاول تاني.');
      }

      for (final e in changed.entries) {
        await ProjectStore.write('$dir/${e.key}', e.value);
      }
      for (final p in deletes) {
        await ProjectStore.remove('$dir/$p');
      }
      _addLog('تم تعديل ${changed.length} ملف وحذف ${deletes.length}');
      if (mounted) setState(() => _applied = true);
    } catch (e) {
      _addLog('فشل: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تعديل تطبيق')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _names.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'ما في مشروع. اعتمد فكرة وولّد الكود أولاً.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white60),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    DropdownButtonFormField<int>(
                      value: _sel,
                      decoration: const InputDecoration(labelText: 'التطبيق'),
                      items: [
                        for (var i = 0; i < _names.length && i < 2; i++)
                          DropdownMenuItem(value: i, child: Text(_names[i])),
                      ],
                      onChanged: (v) => setState(() => _sel = v ?? 0),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _instr,
                      minLines: 4,
                      maxLines: 10,
                      decoration: const InputDecoration(
                        labelText: 'اكتب التعديل أو التحديث أو الحذف',
                        hintText:
                            'مثال: أضف شاشة عروض خاصة، أو احذف شاشة حسابي، أو غيّر لون الأزرار للذهبي',
                      ),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: _busy == null ? _apply : null,
                      icon: const Icon(Icons.edit_rounded),
                      label: const Text('نفّذ التعديل'),
                    ),
                    if (_busy != null) ...[
                      const SizedBox(height: 14),
                      const LinearProgressIndicator(),
                      const SizedBox(height: 8),
                      Text(_busy!),
                    ],
                    if (_applied) ...[
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const ReleaseScreen()),
                        ),
                        icon: const Icon(Icons.rocket_launch_rounded),
                        label: const Text('انشر التحديث'),
                      ),
                    ],
                    if (_log.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      for (final l in _log)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(l, style: const TextStyle(height: 1.5)),
                        ),
                    ],
                    const SizedBox(height: 18),
                    const Text(
                      'لو التعديل محتاج جداول جديدة في قاعدة البيانات، أعد توليد SQL من "توليد المشروع" ونفّذو.',
                      style: TextStyle(color: Colors.white54, fontSize: 12.5, height: 1.6),
                    ),
                  ],
                ),
    );
  }
}
