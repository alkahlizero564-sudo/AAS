import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/notify_service.dart';
import '../services/project_store.dart';
import '../services/settings_service.dart';
import '../services/supabase_service.dart';

class NotifyScreen extends StatefulWidget {
  const NotifyScreen({super.key});

  @override
  State<NotifyScreen> createState() => _NotifyScreenState();
}

class _NotifyScreenState extends State<NotifyScreen> {
  Map<String, dynamic>? _spec;
  String? _busy;
  final List<String> _log = [];
  final Map<int, bool> _linked = {};
  String _trigSql = '';
  bool _fnFailed = false;
  final _email = TextEditingController();

  List get _apps => (_spec?['apps'] as List?) ?? [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _set(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  void _addLog(String s) => _set(() {
        _log.add(s);
        if (_log.length > 10) _log.removeAt(0);
      });

  Future<void> _load() async {
    try {
      final raw = await SettingsService.get('project_spec');
      if (raw.isEmpty) {
        _addLog('ما في فكرة معتمدة.');
        return;
      }
      final spec = jsonDecode(raw) as Map<String, dynamic>;
      final n = (spec['apps'] as List? ?? []).length;
      for (var i = 0; i < n && i < 2; i++) {
        final g = await ProjectStore.read('meta/app${i + 1}_google_services.json');
        _linked[i] = g != null && g.trim().isNotEmpty;
      }
      _set(() => _spec = spec);
    } catch (e) {
      _addLog('تعذر التحميل: $e');
    }
  }

  Future<void> _run(String label, Future<void> Function() job) async {
    if (_busy != null) return;
    _set(() => _busy = label);
    try {
      await job();
    } catch (e) {
      _addLog('فشل: $e');
    } finally {
      _set(() => _busy = null);
    }
  }

  // 1) قاعدة البيانات
  Future<void> _prepareDb() => _run('جاري تجهيز قاعدة الإشعارات...', () async {
        await SupabaseService.runSql(await NotifyService.migrationSql());
        _addLog('تم تجهيز جدول الأجهزة ودالة الإرسال في قاعدة البيانات');
      });

  // 2) الدالة
  Future<void> _publishFn() => _run('جاري نشر دالة الإشعارات...', () async {
        await NotifyService.setSecrets();
        _addLog('تم حفظ أسرار Firebase في Supabase');
        try {
          await NotifyService.deployFunction();
          _set(() => _fnFailed = false);
          _addLog('تم نشر الدالة notify');
        } catch (e) {
          _set(() => _fnFailed = true);
          _addLog('تعذر النشر التلقائي: $e');
        }
      });

  // 3) ربط التطبيقات
  Future<void> _linkAuto(int i) => _run('جاري ربط التطبيق ${i + 1} بـ Firebase...', () async {
        final gs = await NotifyService.fetchGoogleServices(NotifyService.packageFor(i));
        await ProjectStore.write('meta/app${i + 1}_google_services.json', gs);
        _set(() => _linked[i] = true);
        _addLog('تم ربط التطبيق ${i + 1}');
      });

  Future<void> _linkManual(int i) async {
    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('الصق google-services.json (تطبيق ${i + 1})'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'سجّل تطبيق أندرويد في Firebase باسم الحزمة:\n${NotifyService.packageFor(i)}',
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: ctl,
                minLines: 6,
                maxLines: 10,
                textDirection: TextDirection.ltr,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                decoration: const InputDecoration(hintText: '{ ... }'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctl.text.trim()),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    final pkg = NotifyService.packageOf(text);
    if (pkg == null) {
      _addLog('الملف غير صالح.');
      return;
    }
    if (pkg != NotifyService.packageFor(i)) {
      _addLog('اسم الحزمة في الملف ($pkg) لازم يكون ${NotifyService.packageFor(i)}');
      return;
    }
    await ProjectStore.write('meta/app${i + 1}_google_services.json', text);
    _set(() => _linked[i] = true);
    _addLog('تم ربط التطبيق ${i + 1}');
  }

  // 4) القواعد
  Future<void> _genTriggers() => _run('جاري توليد قواعد الإشعارات...', () async {
        final schema = await ProjectStore.read('schema.sql');
        if (schema == null || schema.isEmpty) {
          throw Exception('ولّد SQL قاعدة البيانات أولاً من "توليد المشروع".');
        }
        final sql = await NotifyService.genTriggersSql(_spec!, schema);
        final problem = SupabaseService.sqlProblem(sql);
        _set(() => _trigSql = sql);
        _addLog(problem == null
            ? 'تم توليد القواعد (${sql.split('\n').length} سطر)'
            : 'تحذير: $problem');
      });

  Future<void> _runTriggers() async {
    if (_trigSql.isEmpty || _busy != null) return;
    final problem = SupabaseService.sqlProblem(_trigSql);
    if (problem != null) {
      _addLog('لن يتم التنفيذ: $problem');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('تنفيذ قواعد الإشعارات'),
        content: const Text('سيتم إنشاء Triggers في قاعدة البيانات. متأكد؟'),
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
    await _run('جاري التنفيذ...', () async {
      await SupabaseService.runSql(_trigSql);
      _addLog('تم تنفيذ قواعد الإشعارات');
    });
  }

  // 5) اختبار
  Future<void> _sendTest() => _run('جاري إرسال إشعار تجريبي...', () async {
        final email = _email.text.trim();
        if (!email.contains('@')) throw Exception('اكتب بريد صحيح');
        final r = await NotifyService.sendTest(email);
        _addLog('رد الدالة: $r');
      });

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
            Text(title,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      );

  Widget _hint(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(t, style: const TextStyle(color: Colors.white70, height: 1.6)),
      );

  @override
  Widget build(BuildContext context) {
    final idle = _busy == null;

    return Scaffold(
      appBar: AppBar(title: const Text('الإشعارات')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card('1) قاعدة الإشعارات', [
            _hint('بينشئ جدول الأجهزة ودالة التسجيل ودالة الإرسال في Supabase.'),
            FilledButton.icon(
              onPressed: idle ? _prepareDb : null,
              icon: const Icon(Icons.storage_rounded),
              label: const Text('تجهيز قاعدة البيانات'),
            ),
          ]),
          _card('2) دالة الإرسال', [
            _hint('بتحفظ مفتاح Firebase كسر في Supabase وبتنشر دالة notify اللي بترسل عن طريق FCM.'),
            FilledButton.icon(
              onPressed: idle ? _publishFn : null,
              icon: const Icon(Icons.cloud_upload_rounded),
              label: const Text('نشر الدالة'),
            ),
            if (_fnFailed) ...[
              const SizedBox(height: 10),
              _hint(
                  'النشر اليدوي: Supabase Dashboard ثم Edge Functions ثم Deploy a new function، الاسم notify، الصق الكود، وعطّل Verify JWT.'),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                      const ClipboardData(text: NotifyService.functionCode));
                  _addLog('تم نسخ كود الدالة');
                },
                icon: const Icon(Icons.copy_rounded),
                label: const Text('نسخ كود الدالة'),
              ),
            ],
          ]),
          _card('3) ربط التطبيقات بـ Firebase', [
            _hint('كل تطبيق ليهو اسم حزمة. الربط التلقائي بيسجّل التطبيق في Firebase ويجلب إعداداتو. لو فشل استخدم اللصق اليدوي.'),
            if (_spec != null)
              for (var i = 0; i < _apps.length && i < 2; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              ((_apps[i] as Map)['name'] ?? 'تطبيق ${i + 1}')
                                  .toString(),
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                          Text(
                            _linked[i] == true ? 'مربوط' : 'غير مربوط',
                            style: TextStyle(
                              color: _linked[i] == true
                                  ? const Color(0xFFC6F750)
                                  : Colors.white54,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      Text(NotifyService.packageFor(i),
                          textDirection: TextDirection.ltr,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed: idle ? () => _linkAuto(i) : null,
                              child: const Text('ربط تلقائي'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: idle ? () => _linkManual(i) : null,
                              child: const Text('لصق يدوي'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
          ]),
          _card('4) قواعد الإشعارات', [
            _hint('الذكاء الاصطناعي بيقرا الإشعارات المذكورة في فكرتك وجداول قاعدة البيانات، وبيكتب Triggers ترسل الإشعار للشخص المناسب.'),
            FilledButton.icon(
              onPressed: idle ? _genTriggers : null,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: const Text('توليد القواعد'),
            ),
            if (_trigSql.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                height: 220,
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F1630),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _trigSql,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 11, height: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: idle ? _runTriggers : null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('تنفيذ على Supabase'),
              ),
            ],
          ]),
          _card('5) اختبار', [
            _hint('سجّل الدخول في التطبيق (بعد ما تنشرو بعد الربط)، بعدين اكتب نفس البريد هنا.'),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                labelText: 'بريد المستخدم',
                hintText: 'you@gmail.com',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: idle ? _sendTest : null,
              icon: const Icon(Icons.notifications_active_rounded),
              label: const Text('أرسل إشعار تجريبي'),
            ),
          ]),
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
                  child: SelectableText(l, style: const TextStyle(height: 1.5)),
                ),
            ]),
        ],
      ),
    );
  }
}
