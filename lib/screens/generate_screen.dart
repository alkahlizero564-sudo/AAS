import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/ai_service.dart';
import '../services/app_templates.dart';
import '../services/project_store.dart';
import '../services/settings_service.dart';
import '../services/supabase_service.dart';

const _sqlSystem = r'''
You are a senior Supabase / PostgreSQL engineer. Given an app spec as JSON, write ONE idempotent SQL script. Output ONLY raw SQL (no markdown fences, no explanations; SQL comments are fine).

Rules:
- Schema public. Use "create table if not exists". Primary keys: uuid default gen_random_uuid(). Timestamps: timestamptz default now().
- Create public.profiles (id uuid primary key references auth.users(id) on delete cascade, email text, full_name text, role text not null default 'customer', created_at timestamptz default now()).
- Create function public.handle_new_user() (security definer, set search_path = public) that inserts a profiles row for each new auth user, and a trigger on auth.users (drop trigger if exists first, then create).
- Create helper functions public.is_admin() and public.is_staff() (security definer, stable, set search_path = public) that read the role of auth.uid() from profiles.
- Enable row level security on EVERY table.
- Write explicit policies for every table (drop policy if exists, then create policy): customers can only read/write their own rows; admin and staff get access according to the roles in the spec. Never use "using (true)" for insert, update or delete.
- Add indexes on foreign keys.
- Add a table device_tokens (user_id uuid references auth.users(id) on delete cascade, token text, created_at timestamptz default now()) with RLS so users manage only their own tokens.
- NEVER use DROP TABLE, DROP SCHEMA, TRUNCATE, or DELETE without a where clause.
''';

const _codeSystem = r'''
You are a senior Flutter engineer. Write the screens of ONE mobile app, given its spec and the backend spec (JSON).

The project ALREADY contains lib/main.dart (Supabase initialized, auth gate) and lib/login_screen.dart (email OTP login). DO NOT write those two files.

You MUST write lib/app_home.dart defining a widget class named AppHome with a const constructor: const AppHome({super.key}). It is shown after login. You may add more files under lib/ (for example lib/screens/ and lib/widgets/).

Rules:
- Allowed imports: package:flutter/material.dart, dart:* libraries, package:supabase_flutter/supabase_flutter.dart. No other packages.
- Use Supabase.instance.client for data (tables from the backend spec). Read the user's role from the profiles table to decide what to show.
- UI: modern, luxurious, Arabic RTL friendly, Material 3. The theme is already dark navy (0xFF0F1630) with lime accent (0xFFC6F750): use Theme.of(context) colors, rounded cards (radius 20 or more), generous spacing, a bottom navigation bar, loading states, empty states, and try/catch with snackbars.
- The code must compile: no placeholders, no TODO, every import present, every referenced class defined. Keep the total under 700 lines.

Output format (plain text, no markdown fences). For each file:
=== FILE: lib/app_home.dart ===
<file content>
=== END ===
''';

class GenerateScreen extends StatefulWidget {
  const GenerateScreen({super.key});

  @override
  State<GenerateScreen> createState() => _GenerateScreenState();
}

class _GenerateScreenState extends State<GenerateScreen> {
  Map<String, dynamic>? _spec;
  String _sql = '';
  String? _busy;
  List<String> _files = [];
  final List<String> _log = [];

  List get _apps => (_spec?['apps'] as List?) ?? [];

  @override
  void initState() {
    super.initState();
    _loadSpec();
  }

  void _addLog(String s) {
    if (!mounted) return;
    setState(() {
      _log.add(s);
      if (_log.length > 8) _log.removeAt(0);
    });
  }

  Future<void> _loadSpec() async {
    try {
      final raw = await SettingsService.get('project_spec');
      if (raw.isEmpty) {
        _addLog('ما في فكرة معتمدة. ارجع واضغط "تطبيق جديد" واعتمد فكرة.');
        return;
      }
      final sql = await ProjectStore.read('schema.sql');
      final files = await ProjectStore.list();
      if (!mounted) return;
      setState(() {
        _spec = jsonDecode(raw) as Map<String, dynamic>;
        _sql = sql ?? '';
        _files = files;
      });
    } catch (e) {
      _addLog('تعذر قراءة الفكرة: $e');
    }
  }

  String _stripFences(String s) => s
      .replaceAll(RegExp(r'^```[a-zA-Z]*[ \t]*\r?\n?', multiLine: true), '')
      .trim();

  Map<String, String> _parseFiles(String raw) {
    final out = <String, String>{};
    final re = RegExp(
        r'=== FILE: (.+?) ===\r?\n([\s\S]*?)(?:\r?\n=== END ===|$)');
    for (final m in re.allMatches(raw)) {
      final path = (m.group(1) ?? '').trim();
      final body = _stripFences(m.group(2) ?? '');
      final ok = path.startsWith('lib/') &&
          path.endsWith('.dart') &&
          !path.contains('..') &&
          body.isNotEmpty;
      if (ok) out[path] = body;
    }
    return out;
  }

  Future<void> _genSql() async {
    if (_spec == null || _busy != null) return;
    setState(() => _busy = 'جاري توليد SQL...');
    try {
      final raw = await AiService.ask(
        _sqlSystem,
        [ChatTurn(true, jsonEncode(_spec))],
        json: false,
        maxTokens: 10000,
      );
      final sql = _stripFences(raw);
      await ProjectStore.write('schema.sql', sql);
      if (!mounted) return;
      setState(() => _sql = sql);
      final problem = SupabaseService.sqlProblem(sql);
      _addLog(problem == null
          ? 'تم توليد SQL (${sql.split('\n').length} سطر)'
          : 'تحذير: $problem');
    } catch (e) {
      _addLog('فشل التوليد: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _runSql() async {
    if (_sql.isEmpty || _busy != null) return;
    final problem = SupabaseService.sqlProblem(_sql);
    if (problem != null) {
      _addLog('لن يتم التنفيذ: $problem');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('تنفيذ SQL'),
        content: const Text(
            'سيتم إنشاء الجداول والصلاحيات في مشروع Supabase الخاص بك. متأكد؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('تنفيذ'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = 'جاري تنفيذ SQL...');
    try {
      await SupabaseService.runSql(_sql);
      _addLog('تم تنفيذ SQL بنجاح');
    } catch (e) {
      _addLog('فشل التنفيذ: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _genApps() async {
    if (_spec == null || _busy != null) return;
    final key = (await SettingsService.get('supabase_key')).trim();
    final ref = (await SettingsService.get('supabase_ref')).trim();
    if (key.isEmpty || ref.isEmpty) {
      _addLog('أضف Supabase API Key و Project Ref في الإعدادات');
      return;
    }
    final kp = SupabaseService.keyProblem(key);
    if (kp != null) {
      _addLog(kp);
      return;
    }
    final url = await SupabaseService.url();
    final backend = _spec!['backend'] ?? {};
    final apps = _apps;

    setState(() => _busy = 'جاري توليد التطبيقات...');
    try {
      await ProjectStore.remove('app1');
      await ProjectStore.remove('app2');

      for (var i = 0; i < apps.length && i < 2; i++) {
        final app = Map<String, dynamic>.from(apps[i] as Map);
        final name = (app['name'] ?? 'App ${i + 1}').toString();
        if (mounted) setState(() => _busy = 'جاري توليد "$name" ...');

        final raw = await AiService.ask(
          _codeSystem,
          [ChatTurn(true, jsonEncode({'app': app, 'backend': backend}))],
          json: false,
          maxTokens: 12000,
        );
        final files = _parseFiles(raw);
        if (!files.containsKey('lib/app_home.dart')) {
          throw Exception(
              'الذكاء الاصطناعي ما كتب app_home.dart لتطبيق "$name". حاول مرة أخرى.');
        }

        final dir = 'app${i + 1}';
        await ProjectStore.write('$dir/pubspec.yaml',
            AppTemplates.pubspec('aas_app${i + 1}'));
        await ProjectStore.write(
            '$dir/lib/main.dart', AppTemplates.main(name, url, key));
        await ProjectStore.write(
            '$dir/lib/login_screen.dart', AppTemplates.login);
        await ProjectStore.write('$dir/app_name.txt', name);
        for (final e in files.entries) {
          if (e.key == 'lib/main.dart' || e.key == 'lib/login_screen.dart') {
            continue;
          }
          await ProjectStore.write('$dir/${e.key}', e.value);
        }
        _addLog('تم توليد "$name" (${files.length} ملف)');
      }
      final all = await ProjectStore.list();
      if (mounted) setState(() => _files = all);
    } catch (e) {
      _addLog('فشل: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Widget _card(String title, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF1A2347),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final idle = _busy == null;

    return Scaffold(
      appBar: AppBar(title: const Text('توليد المشروع')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_spec != null) ...[
            _card('1) قاعدة البيانات والصلاحيات', [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: idle ? _genSql : null,
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: const Text('توليد SQL'),
                  ),
                  OutlinedButton.icon(
                    onPressed: idle && _sql.isNotEmpty ? _runSql : null,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('تنفيذ على Supabase'),
                  ),
                  if (_sql.isNotEmpty)
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _sql));
                        _addLog('تم نسخ SQL');
                      },
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('نسخ'),
                    ),
                ],
              ),
              if (_sql.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  height: 240,
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F1630),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _sql,
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ],
            ]),
            _card('2) كود التطبيقات', [
              for (final a in _apps)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('• ${(a as Map)['name'] ?? ''}'),
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: idle ? _genApps : null,
                icon: const Icon(Icons.code_rounded),
                label: const Text('توليد كود التطبيقات'),
              ),
              if (_files.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '${_files.length} ملف محفوظ:',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  _files.take(24).join('\n'),
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.white60,
                    height: 1.5,
                  ),
                ),
              ],
            ]),
          ],
          if (_busy != null)
            _card('جاري العمل', [
              const LinearProgressIndicator(),
              const SizedBox(height: 10),
              Text(_busy!),
            ]),
          if (_log.isNotEmpty)
            _card('السجل', [
              for (final l in _log)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(l, style: const TextStyle(height: 1.5)),
                ),
            ]),
        ],
      ),
    );
  }
}
