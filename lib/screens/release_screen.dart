import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ota_update/ota_update.dart';
import '../services/github_service.dart';
import '../services/project_store.dart';
import '../services/release_service.dart';
import '../services/settings_service.dart';
import '../services/supabase_service.dart';

class ReleaseScreen extends StatefulWidget {
  const ReleaseScreen({super.key});

  @override
  State<ReleaseScreen> createState() => _ReleaseScreenState();
}

class _ReleaseScreenState extends State<ReleaseScreen> {
  Map<String, dynamic>? _spec;
  String? _busy;
  final List<String> _log = [];
  final Map<int, String> _apk = {};
  final Map<int, int> _run = {};

  List get _apps => (_spec?['apps'] as List?) ?? [];

  @override
  void initState() {
    super.initState();
    _load();
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
        final r = await ProjectStore.read('meta/app${i + 1}_release.json');
        if (r != null) {
          final m = jsonDecode(r) as Map<String, dynamic>;
          _apk[i] = m['apk'] as String;
          _run[i] = m['run'] as int;
        }
      }
      _set(() => _spec = spec);
    } catch (e) {
      _addLog('تعذر التحميل: $e');
    }
  }

  Future<void> _prepareRepo() async {
    if (_busy != null) return;
    _set(() => _busy = 'جاري تجهيز الريبو...');
    try {
      final info = await GithubService.repoInfo();
      final sha = await GithubService.push(
        ReleaseService.toolFiles(),
        message: 'chore: AAS build tools',
      );
      _addLog('تم تجهيز الريبو (${sha.substring(0, 7)})');
      if (info['private'] == true) {
        _addLog(
            'تنبيه: الريبو خاص. التحميل والتحديث الداخلي بيحتاجوا ريبو عام.');
      }
    } catch (e) {
      _addLog('فشل التجهيز: $e');
    } finally {
      _set(() => _busy = null);
    }
  }

  String _statusAr(String s) {
    switch (s) {
      case 'queued':
        return 'في الانتظار';
      case 'in_progress':
        return 'قيد البناء';
      case 'completed':
        return 'اكتمل';
    }
    return s;
  }

  Future<void> _publish(int i) async {
    if (_busy != null || _spec == null) return;
    final key = 'app${i + 1}';
    final name = ((_apps[i] as Map)['name'] ?? key).toString();
    try {
      _set(() => _busy = 'جاري رفع ملفات "$name"...');
      final files = await ReleaseService.collectApp(i);
      if (!files.any((f) => f.path == 'apps/$key/lib/app_home.dart')) {
        throw Exception('ولّد كود التطبيقات أولاً من شاشة "توليد المشروع"');
      }
      await GithubService.push(
        files,
        message: 'feat: $name',
        pruneUnder: ['apps/$key/lib/'],
      );
      _addLog('تم رفع ${files.length} ملف');

      _set(() => _busy = 'جاري بدء البناء...');
      final started = await GithubService.dispatchBuild(
        appDir: 'apps/$key',
        appKey: key,
        appName: name,
      );

      Map<String, dynamic>? run;
      for (var n = 0; n < 180; n++) {
        await Future.delayed(const Duration(seconds: 10));
        run ??= await GithubService.findRun(started);
        if (run != null) {
          run = await GithubService.getRun(run['id'] as int);
          final st = (run['status'] ?? '').toString();
          _set(() => _busy = 'البناء: ${_statusAr(st)} (${(n + 1) * 10} ثانية)');
          if (st == 'completed') break;
        } else {
          _set(() => _busy = 'في انتظار بدء البناء...');
        }
      }
      if (run == null || run['status'] != 'completed') {
        throw Exception('انتهت مهلة الانتظار. افحص تبويب Actions في GitHub.');
      }
      if (run['conclusion'] != 'success') {
        throw Exception('فشل البناء. افتح الرابط وابعت لي الخطأ:\n${run['html_url']}');
      }

      final number = run['run_number'] as int;
      final repo = (await SettingsService.get('github_repo')).trim();
      final apk = ReleaseService.apkUrl(repo, key, number);
      await ProjectStore.write(
          'meta/${key}_release.json', jsonEncode({'run': number, 'apk': apk}));

      try {
        await SupabaseService.runSql(
            ReleaseService.versionSql(key, number, apk, 'تحديث $name'));
        _addLog('تم نشر الإصدار $number للتطبيقات المثبتة');
      } catch (e) {
        _addLog('تعذر نشر رقم الإصدار في Supabase: $e');
      }

      _set(() {
        _apk[i] = apk;
        _run[i] = number;
      });
      _addLog('جاهز: $name (إصدار $number)');
    } catch (e) {
      _addLog('فشل: $e');
    } finally {
      _set(() => _busy = null);
    }
  }

  Future<void> _install(int i) async {
    final apk = _apk[i];
    if (apk == null) return;
    await showDialog(
      context: context,
      builder: (_) => _InstallDialog(url: apk, fileName: 'app${i + 1}.apk'),
    );
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
            Text(title,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      );

  Widget _appCard(int i) {
    final name = ((_apps[i] as Map)['name'] ?? 'تطبيق ${i + 1}').toString();
    final idle = _busy == null;
    final apk = _apk[i];

    return _card(name, [
      if (_run[i] != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text('آخر إصدار منشور: ${_run[i]}',
              style: const TextStyle(color: Colors.white70)),
        ),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: idle ? () => _publish(i) : null,
          icon: const Icon(Icons.rocket_launch_rounded),
          label: const Text('نشر وبناء'),
        ),
      ),
      if (apk != null) ...[
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: idle ? () => _install(i) : null,
                icon: const Icon(Icons.install_mobile_rounded),
                label: const Text('تثبيت هنا'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: apk));
                  _addLog('تم نسخ رابط التحميل');
                },
                icon: const Icon(Icons.link_rounded),
                label: const Text('نسخ الرابط'),
              ),
            ),
          ],
        ),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('النشر والبناء')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card('قبل ما تبدأ', [
            const Text(
              '1) في GitHub: Settings ثم Secrets and variables ثم Actions، أضف Secret باسم KS_PASS وقيمتو نص عشوائي طويل. احفظو: لو ضاع ما بتقدر تحدّث التطبيقات المثبتة.\n\n'
              '2) الريبو لازم يكون Public عشان التحميل والتحديث الداخلي يشتغلوا بدون توكن.\n\n'
              '3) توكن GitHub لازم فيهو صلاحيتي repo و workflow.',
              style: TextStyle(color: Colors.white70, height: 1.7),
            ),
          ]),
          _card('1) تجهيز الريبو (مرة واحدة)', [
            const Text(
              'بيرفع أدوات البناء والتوقيع وملفات الـ workflow لريبو GitHub.',
              style: TextStyle(color: Colors.white70, height: 1.6),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy == null ? _prepareRepo : null,
              icon: const Icon(Icons.build_circle_rounded),
              label: const Text('تجهيز الريبو'),
            ),
          ]),
          if (_spec != null)
            for (var i = 0; i < _apps.length && i < 2; i++) _appCard(i),
          if (_busy != null)
            _card('جاري العمل', [
              const LinearProgressIndicator(),
              const SizedBox(height: 10),
              Text(_busy!),
              const SizedBox(height: 6),
              const Text('خلّي الشاشة مفتوحة لحدي ما يكتمل البناء.',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
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

class _InstallDialog extends StatefulWidget {
  final String url;
  final String fileName;
  const _InstallDialog({required this.url, required this.fileName});

  @override
  State<_InstallDialog> createState() => _InstallDialogState();
}

class _InstallDialogState extends State<_InstallDialog> {
  double? _p;
  String _status = 'جاري التنزيل...';

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    try {
      OtaUpdate()
          .execute(widget.url, destinationFilename: widget.fileName)
          .listen((e) {
        if (!mounted) return;
        final n = e.status.name;
        setState(() {
          if (n == 'DOWNLOADING') {
            final v = double.tryParse(e.value ?? '') ?? 0;
            _p = v / 100;
            _status = 'جاري التنزيل ${v.toStringAsFixed(0)}%';
          } else if (n == 'INSTALLING') {
            _p = null;
            _status = 'جاري التثبيت...';
          } else if (n.endsWith('ERROR')) {
            _p = null;
            _status = 'تعذر التثبيت ($n)';
          }
        });
      }, onError: (_) {
        if (mounted) setState(() => _status = 'تعذر التنزيل');
      });
    } catch (_) {
      _status = 'تعذر بدء التثبيت';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('تثبيت التطبيق'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: _p),
          const SizedBox(height: 10),
          Text(_status),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إغلاق'),
        ),
      ],
    );
  }
}
