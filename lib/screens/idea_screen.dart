import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/ai_service.dart';
import '../services/settings_service.dart';

const _system = r'''
You are the product analyst inside an "app factory". The user describes ONE or TWO mobile apps (for example a customer app and an admin app that share one backend).

Reply ONLY with a JSON object, no other text, with this shape:
{
  "status": "need_info" or "ready",
  "message": "short friendly message in the user's language (simple Arabic if the user writes Arabic)",
  "questions": ["at most 3 short questions, only when status is need_info"],
  "suggestions": ["short feature ideas the user did not mention but probably needs"],
  "spec": {
    "apps": [
      {
        "name": "app name",
        "role": "who uses it (customer, admin, ...)",
        "description": "one or two sentences",
        "screens": ["screen names"],
        "features": ["feature names"],
        "design": "short direction for a modern, luxurious UI"
      }
    ],
    "backend": {
      "tables": ["table names"],
      "roles": ["user roles and permissions"],
      "notifications": ["events that send push notifications between the apps"],
      "auth": "login method, e.g. email + OTP verification"
    }
  }
}

Rules:
- Maximum 2 apps.
- If the idea is vague, use status "need_info" and ask at most 3 questions. Otherwise use "ready".
- Always include "spec" with your best current understanding, and update it after each user answer.
- Always suggest 2 to 5 missing features, short.
- When the user accepts or says to continue (ok, تمام, ابدأ), use status "ready".
''';

class IdeaScreen extends StatefulWidget {
  const IdeaScreen({super.key});

  @override
  State<IdeaScreen> createState() => _IdeaScreenState();
}

class _Msg {
  final bool user;
  final String text;
  final Map<String, dynamic>? data;
  _Msg(this.user, this.text, [this.data]);
}

class _IdeaScreenState extends State<IdeaScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _msgs = [];
  final List<ChatTurn> _turns = [];
  List<TextEditingController> _names = [];
  bool _busy = false;
  bool _ready = false;
  Map<String, dynamic>? _spec;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    for (final c in _names) {
      c.dispose();
    }
    super.dispose();
  }

  void _jump() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _addSuggestion(String s) {
    final cur = _input.text.trim();
    _input.text = cur.isEmpty ? 'أضف: $s' : '$cur، أضف: $s';
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    setState(() {
      _msgs.add(_Msg(true, text));
      _busy = true;
    });
    _turns.add(ChatTurn(true, text));
    _jump();

    try {
      final raw = await AiService.ask(_system, _turns);
      final data = AiService.parseJson(raw);
      if (data == null) throw Exception('رد غير مفهوم، حاول مرة أخرى');
      _applyReply(data);
      _turns.add(ChatTurn(false, raw));
    } catch (e) {
      if (_turns.isNotEmpty && _turns.last.user) _turns.removeLast();
      if (mounted) {
        setState(() => _msgs.add(_Msg(false, 'تعذر الاتصال:\n$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _jump();
    }
  }

  void _applyReply(Map<String, dynamic> d) {
    final msg = (d['message'] ?? '').toString();
    final spec = d['spec'];
    setState(() {
      _msgs.add(_Msg(false, msg, d));
      if (spec is Map<String, dynamic>) {
        _spec = spec;
        final old = _names.map((c) => c.text).toList();
        final apps = (spec['apps'] as List? ?? []);
        final fresh = <TextEditingController>[];
        for (var i = 0; i < apps.length; i++) {
          final aiName = ((apps[i] as Map)['name'] ?? '').toString();
          final keep = i < old.length && old[i].trim().isNotEmpty;
          fresh.add(TextEditingController(text: keep ? old[i] : aiName));
        }
        _names = fresh;
      }
      _ready = d['status'] == 'ready' && _spec != null;
    });
  }

  Future<void> _approve() async {
    final spec = Map<String, dynamic>.from(_spec!);
    final apps = (spec['apps'] as List)
        .map((a) => Map<String, dynamic>.from(a as Map))
        .toList();
    for (var i = 0; i < apps.length && i < _names.length; i++) {
      final n = _names[i].text.trim();
      if (n.isNotEmpty) apps[i]['name'] = n;
    }
    spec['apps'] = apps;
    await SettingsService.set('project_spec', jsonEncode(spec));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم اعتماد الفكرة وحفظها')),
    );
    Navigator.pop(context);
  }

  Widget _bubble(_Msg m) {
    final d = m.data;
    final questions =
        (d?['questions'] as List?)?.map((e) => e.toString()).toList() ?? [];
    final sugg =
        (d?['suggestions'] as List?)?.map((e) => e.toString()).toList() ?? [];

    return Align(
      alignment:
          m.user ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
      child: Container(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: m.user ? const Color(0xFFC6F750) : const Color(0xFF1A2347),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              m.text,
              style: TextStyle(
                height: 1.5,
                color: m.user ? const Color(0xFF0F1630) : Colors.white,
              ),
            ),
            if (questions.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final q in questions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('• $q', style: const TextStyle(height: 1.5)),
                ),
            ],
            if (sugg.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'اقتراحات (اضغط للإضافة):',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in sugg)
                    ActionChip(
                      label: Text(s),
                      onPressed: () => _addSuggestion(s),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _appBlock(int i, Map a) {
    final role = (a['role'] ?? '').toString();
    final desc = (a['description'] ?? '').toString();
    final features =
        (a['features'] as List? ?? []).map((e) => e.toString()).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _names[i],
            decoration: InputDecoration(labelText: 'اسم التطبيق ${i + 1}'),
          ),
          const SizedBox(height: 8),
          Text(role, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(desc, style: const TextStyle(color: Colors.white70, height: 1.5)),
          if (features.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final f in features)
                  Chip(
                    label: Text(f, style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _specCard() {
    final apps = (_spec!['apps'] as List? ?? []);
    final backend = (_spec!['backend'] as Map?) ?? {};
    String j(dynamic v) =>
        v is List ? v.map((e) => e.toString()).join('، ') : '';

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF141C3D),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFC6F750), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ملخص الفكرة',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < apps.length && i < _names.length; i++)
            _appBlock(i, apps[i] as Map),
          Text('الجداول: ${j(backend['tables'])}',
              style: const TextStyle(color: Colors.white70, height: 1.6)),
          Text('الصلاحيات: ${j(backend['roles'])}',
              style: const TextStyle(color: Colors.white70, height: 1.6)),
          Text('الإشعارات: ${j(backend['notifications'])}',
              style: const TextStyle(color: Colors.white70, height: 1.6)),
          Text('تسجيل الدخول: ${(backend['auth'] ?? '').toString()}',
              style: const TextStyle(color: Colors.white70, height: 1.6)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _approve,
              icon: const Icon(Icons.check_rounded),
              label: const Text('اعتمد الفكرة'),
            ),
          ),
          const SizedBox(height: 6),
          const Center(
            child: Text(
              'أو اكتب تعديلاتك تحت وأنا أحدّث الملخص',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('فكرة التطبيق')),
      body: Column(
        children: [
          Expanded(
            child: _msgs.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'اكتب وصف تطبيق أو تطبيقين.\n\nمثال: تطبيق للزبون لحجز الورش، وتطبيق للإدارة لمتابعة الطلبات، والإشعارات بينهم.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white60, height: 1.7),
                      ),
                    ),
                  )
                : ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final m in _msgs) _bubble(m),
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      if (_ready && _spec != null) _specCard(),
                    ],
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        hintText: 'اكتب فكرة تطبيقك...',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _busy ? null : _send,
                    icon: const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
