import 'package:flutter/material.dart';
import '../services/preview_service.dart';
import '../services/project_store.dart';
import '../widgets/html_preview.dart';

class PreviewScreen extends StatefulWidget {
  const PreviewScreen({super.key});

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  final _input = TextEditingController();
  String _lang = PreviewService.languages.first;
  bool _busy = false;
  String? _err;
  final Map<String, String> _projectApps = {};

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final found = <String, String>{};
    for (var i = 1; i <= 2; i++) {
      final code = await ProjectStore.read('app$i/lib/app_home.dart');
      if (code != null) {
        final name = await ProjectStore.read('app$i/app_name.txt');
        found['app$i'] = (name == null || name.trim().isEmpty) ? 'تطبيق $i' : name;
      }
    }
    if (mounted) setState(() => _projectApps.addAll(found));
  }

  Future<void> _loadApp(String dir) async {
    final code = await ProjectStore.read('$dir/lib/app_home.dart');
    if (code == null || !mounted) return;
    setState(() {
      _lang = 'Flutter';
      _input.text = code;
    });
  }

  Future<void> _run() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final html = await PreviewService.build(_lang, text);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => HtmlPreviewPage(title: 'معاينة $_lang', html: html),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final direct = PreviewService.isDirect(_lang);

    return Scaffold(
      appBar: AppBar(title: const Text('المعاينة الفورية')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            value: _lang,
            decoration: const InputDecoration(labelText: 'اللغة أو نوع المدخل'),
            items: PreviewService.languages
                .map((l) => DropdownMenuItem(value: l, child: Text(l)))
                .toList(),
            onChanged: (v) => setState(() => _lang = v ?? _lang),
          ),
          const SizedBox(height: 10),
          Text(
            direct
                ? 'تشغيل مباشر للكود (React يحتاج إنترنت لتحميل المكتبات).'
                : 'معاينة تقريبية: الذكاء الاصطناعي بيحوّل المدخل لصفحة بتحاكي الشاشات.',
            style: const TextStyle(color: Colors.white60, fontSize: 13),
          ),
          if (_projectApps.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in _projectApps.entries)
                  ActionChip(
                    avatar: const Icon(Icons.folder_open_rounded, size: 18),
                    label: Text('تحميل كود: ${e.value}'),
                    onPressed: () => _loadApp(e.key),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _input,
            minLines: 12,
            maxLines: 20,
            textDirection: _lang == 'وصف فقط' ? TextDirection.rtl : TextDirection.ltr,
            style: TextStyle(
              fontFamily: _lang == 'وصف فقط' ? null : 'monospace',
              fontSize: 12.5,
              height: 1.5,
            ),
            decoration: InputDecoration(
              hintText: _lang == 'وصف فقط'
                  ? 'اكتب وصف الواجهات...'
                  : 'الصق الكود هنا...',
            ),
          ),
          if (_err != null) ...[
            const SizedBox(height: 10),
            Text(_err!, style: const TextStyle(color: Color(0xFFFF8A80))),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _run,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: Text(_busy ? 'جاري التجهيز...' : 'تشغيل المعاينة'),
          ),
        ],
      ),
    );
  }
}
