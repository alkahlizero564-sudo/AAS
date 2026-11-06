import 'package:flutter/material.dart';
import '../services/gemini_service.dart';
import '../services/settings_service.dart';
import '../services/supabase_service.dart';

class _Service {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  const _Service(this.id, this.title, this.subtitle, this.icon);
}

const _services = <_Service>[
  _Service('Gemini', 'Gemini', 'مفاتيح ونموذج الذكاء الاصطناعي',
      Icons.auto_awesome_rounded),
  _Service('Claude', 'Claude', 'مفتاح احتياطي للذكاء الاصطناعي',
      Icons.psychology_rounded),
  _Service('GitHub', 'GitHub', 'بناء التطبيقات في المستودع', Icons.code_rounded),
  _Service('Supabase', 'Supabase', 'قاعدة البيانات وتسجيل الدخول',
      Icons.storage_rounded),
  _Service('Firebase', 'Firebase', 'الإشعارات بين التطبيقين',
      Icons.notifications_active_rounded),
];

const _intro = <String, String>{
  'Gemini':
      'أضف حتى 4 مفاتيح. لو واحد انتهت حصتو ينتقل للتاني تلقائياً. بعد الإضافة اضغط "جلب نماذج Gemini".',
  'Claude': 'احتياطي: بيشتغل لو فشلت كل مفاتيح Gemini.',
  'GitHub':
      'التوكن لازم يكون فيهو صلاحيات repo و workflow. المستودع بصيغة username/AAS.',
  'Supabase':
      'قاعدة البيانات وتسجيل الدخول للتطبيقين المتصلين. بريد الرموز (SMTP) اختياري، لكن بدونو Supabase بيرسل رموز قليلة في الساعة ولعناوين فريقك فقط (مثلاً Gmail: smtp.gmail.com، المنفذ 587، وكلمة مرور تطبيق).',
  'Firebase':
      'الصق محتوى ملف JSON الخاص بحساب الخدمة (Service Account) لإرسال الإشعارات.',
};

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final Map<String, TextEditingController> _c = {
    for (final f in SettingsService.fields) f.key: TextEditingController(),
  };
  final _testEmail = TextEditingController();

  bool _hide = true;
  bool _loading = true;
  bool _sheetOpen = false;
  bool _fetching = false;
  bool _testing = false;
  String _testResult = '';
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
    _testEmail.dispose();
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
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  /// يحدّث واجهة النافذة لو كانت مفتوحة
  void _s(StateSetter set, VoidCallback fn) {
    if (_sheetOpen) {
      set(fn);
    } else {
      fn();
    }
  }

  bool _isSet(String key) => _c[key]!.text.trim().isNotEmpty;

  bool _configured(String id) {
    switch (id) {
      case 'Gemini':
        return ['gemini_key_1', 'gemini_key_2', 'gemini_key_3', 'gemini_key_4']
            .any(_isSet);
      case 'Claude':
        return _isSet('claude_key');
      case 'GitHub':
        return _isSet('github_token') && _isSet('github_repo');
      case 'Supabase':
        return _isSet('supabase_token') &&
            _isSet('supabase_ref') &&
            _isSet('supabase_key');
      case 'Firebase':
        return _isSet('firebase_json');
    }
    return false;
  }

  Future<void> _saveGroup(String id) async {
    for (final f in SettingsService.group(id)) {
      await SettingsService.set(f.key, _c[f.key]!.text);
    }
    if (id == 'Gemini') {
      await SettingsService.set(SettingsService.modelKey, _model ?? '');
    }
  }

  Future<void> _openService(_Service s) async {
    _sheetOpen = true;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF0B1124),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => _sheetBody(ctx, s, set),
      ),
    );
    _sheetOpen = false;
    await _saveGroup(s.id);
    if (mounted) setState(() {});
  }

  // ---------- Gemini ----------
  Future<void> _fetchModels(StateSetter set) async {
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
    _s(set, () => _fetching = true);
    try {
      final list = await GeminiService.listModels(key);
      _s(set, () {
        _models = list;
        if (_model == null || !list.contains(_model)) {
          _model = list.isNotEmpty ? list.first : null;
        }
      });
      _toast('تم جلب ${list.length} نموذج');
    } catch (e) {
      _toast('فشل الجلب: $e');
    } finally {
      _s(set, () => _fetching = false);
    }
  }

  // ---------- Supabase ----------
  Future<void> _testConnection(StateSetter set) async {
    _s(set, () {
      _testing = true;
      _testResult = '';
    });
    try {
      await _saveGroup('Supabase');
      final lines = await SupabaseService.applyAndVerifyEmailConfig();
      _s(set, () => _testResult = lines.join('\n'));
    } catch (e) {
      _s(set, () => _testResult = 'فشل: $e');
    } finally {
      _s(set, () => _testing = false);
    }
  }

  Future<void> _sendTest(StateSetter set) async {
    final email = _testEmail.text.trim();
    if (!email.contains('@')) {
      _toast('اكتب بريد صحيح');
      return;
    }
    _s(set, () {
      _testing = true;
      _testResult = '';
    });
    try {
      await _saveGroup('Supabase');
      final r = await SupabaseService.sendTestOtp(email);
      _s(set, () => _testResult = r);
    } catch (e) {
      _s(set, () => _testResult = 'فشل: $e');
    } finally {
      _s(set, () => _testing = false);
    }
  }

  // ---------- UI ----------
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

  Widget _sub(String t) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 10),
        child: Text(
          t,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: Color(0xFFC6F750),
          ),
        ),
      );

  Widget _spinner() => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );

  List<Widget> _extras(String id, StateSetter set) {
    if (id == 'Gemini') {
      return [
        OutlinedButton.icon(
          onPressed: _fetching ? null : () => _fetchModels(set),
          icon: _fetching
              ? _spinner()
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
          onChanged: (v) => set(() => _model = v),
        ),
      ];
    }

    if (id == 'Supabase') {
      return [
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _testing ? null : () => _testConnection(set),
            icon: _testing ? _spinner() : const Icon(Icons.bolt_rounded),
            label: const Text('اختبار الاتصال'),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'تجربة رمز الدخول بالبريد',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        const Text(
          'بنرسل رمز حقيقي لبريدك بنفس طريقة التطبيقات، ونعرض رد Supabase.',
          style: TextStyle(color: Colors.white60, height: 1.6),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _testEmail,
          keyboardType: TextInputType.emailAddress,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(
            labelText: 'البريد',
            hintText: 'you@gmail.com',
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _testing ? null : () => _sendTest(set),
            icon: const Icon(Icons.mail_outline_rounded),
            label: const Text('أرسل رمز تجريبي'),
          ),
        ),
        if (_testResult.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1A2347),
              borderRadius: BorderRadius.circular(14),
            ),
            child: SelectableText(
              _testResult,
              style: const TextStyle(height: 1.6, fontSize: 13),
            ),
          ),
        ],
      ];
    }

    return [];
  }

  Widget _sheetBody(BuildContext ctx, _Service s, StateSetter set) {
    final fields = SettingsService.group(s.id);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.title,
                    style: const TextStyle(
                        fontSize: 26, fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  onPressed: () => set(() => _hide = !_hide),
                  icon: Icon(_hide
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded),
                ),
                IconButton.filledTonal(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _intro[s.id] ?? '',
              style: const TextStyle(color: Colors.white60, height: 1.7),
            ),
            const SizedBox(height: 18),
            for (final f in fields) ...[
              if (f.key == 'smtp_host') _sub('بريد الرموز (SMTP)'),
              _field(f),
            ],
            ..._extras(s.id, set),
          ],
        ),
      ),
    );
  }

  Widget _serviceCard(_Service s) {
    final ok = _configured(s.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _openService(s),
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1A2347),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF0F1630),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(s.icon, color: const Color(0xFFC6F750)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.title,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      s.subtitle,
                      style:
                          const TextStyle(color: Colors.white60, fontSize: 13),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: ok ? const Color(0xFFC6F750) : const Color(0xFF0F1630),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  ok ? 'مضبوط' : 'غير مضبوط',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: ok ? const Color(0xFF0F1630) : Colors.white54,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final done = _services.where((s) => _configured(s.id)).length;

    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  '$done من ${_services.length} خدمات مضبوطة',
                  style: const TextStyle(color: Colors.white60, fontSize: 15),
                ),
                const SizedBox(height: 22),
                const Text(
                  'الخدمات',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                for (final s in _services) _serviceCard(s),
              ],
            ),
    );
  }
}
