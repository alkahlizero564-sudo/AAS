import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/preview_service.dart';
import '../services/project_store.dart';
import '../services/settings_service.dart';
import '../widgets/html_preview.dart';

class DesignScreen extends StatefulWidget {
  const DesignScreen({super.key});

  @override
  State<DesignScreen> createState() => _DesignScreenState();
}

class _DesignScreenState extends State<DesignScreen> {
  Map<String, dynamic>? _spec;
  bool _loaded = false;
  String? _busy;
  final List<TextEditingController> _names = [];
  final Map<int, Uint8List> _icons = {};
  final Map<int, bool> _hasDesign = {};
  final _notes = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _names) {
      c.dispose();
    }
    _notes.dispose();
    super.dispose();
  }

  void _toast(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _load() async {
    try {
      final raw = await SettingsService.get('project_spec');
      if (raw.isNotEmpty) {
        final spec = jsonDecode(raw) as Map<String, dynamic>;
        final apps = (spec['apps'] as List? ?? []);
        for (var i = 0; i < apps.length && i < 2; i++) {
          _names.add(TextEditingController(
              text: ((apps[i] as Map)['name'] ?? '').toString()));
          final b = await ProjectStore.readBytes('meta/app${i + 1}_icon.png');
          if (b != null) _icons[i] = b;
          _hasDesign[i] =
              (await ProjectStore.read('meta/app${i + 1}_design.html')) != null;
        }
        _spec = spec;
      }
    } catch (e) {
      _toast('تعذر التحميل: $e');
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _saveNames() async {
    if (_spec == null) return;
    final spec = Map<String, dynamic>.from(_spec!);
    final apps = (spec['apps'] as List)
        .map((a) => Map<String, dynamic>.from(a as Map))
        .toList();
    for (var i = 0; i < apps.length && i < _names.length; i++) {
      final n = _names[i].text.trim();
      if (n.isNotEmpty) apps[i]['name'] = n;
    }
    spec['apps'] = apps;
    _spec = spec;
    await SettingsService.set('project_spec', jsonEncode(spec));
  }

  Future<Uint8List> _toSquarePng(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final side = img.width < img.height ? img.width : img.height;
    final src = ui.Rect.fromLTWH(
      (img.width - side) / 2,
      (img.height - side) / 2,
      side.toDouble(),
      side.toDouble(),
    );
    final dst = ui.Rect.fromLTWH(0, 0, 512, 512);
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.drawImageRect(
      img,
      src,
      dst,
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final out = await rec.endRecording().toImage(512, 512);
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  Future<void> _pickIcon(int i) async {
    try {
      final x = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (x == null) return;
      final png = await _toSquarePng(await x.readAsBytes());
      await ProjectStore.writeBytes('meta/app${i + 1}_icon.png', png);
      if (mounted) setState(() => _icons[i] = png);
      _toast('تم حفظ الأيقونة');
    } catch (e) {
      _toast('تعذر اختيار الصورة: $e');
    }
  }

  Future<void> _showDesign(int i, [String? html]) async {
    final h = html ?? await ProjectStore.read('meta/app${i + 1}_design.html');
    if (h == null || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HtmlPreviewPage(title: _names[i].text, html: h),
      ),
    );
  }

  Future<void> _genDesign(int i) async {
    if (_busy != null || _spec == null) return;
    await _saveNames();
    setState(() => _busy = 'جاري تصميم الواجهات...');
    try {
      final app = (_spec!['apps'] as List)[i];
      final html = await PreviewService.aiHtml(
        'وصف فقط',
        jsonEncode({
          'app': app,
          'backend': _spec!['backend'],
          'notes': _notes.text.trim(),
        }),
      );
      await ProjectStore.write('meta/app${i + 1}_design.html', html);
      if (mounted) setState(() => _hasDesign[i] = true);
      await _showDesign(i, html);
    } catch (e) {
      _toast('فشل التصميم: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Widget _appCard(int i) {
    final idle = _busy == null;
    final icon = _icons[i];

    return Container(
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
            'التطبيق ${i + 1}',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _names[i],
            decoration: const InputDecoration(
              labelText: 'اسم التطبيق (يظهر في الشاشة)',
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: icon != null
                    ? Image.memory(icon, width: 72, height: 72, fit: BoxFit.cover)
                    : Container(
                        width: 72,
                        height: 72,
                        color: const Color(0xFF0F1630),
                        child: const Icon(Icons.apps_rounded, size: 32),
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: idle ? () => _pickIcon(i) : null,
                  icon: const Icon(Icons.image_rounded),
                  label: const Text('اختر أيقونة من المعرض'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: idle ? () => _genDesign(i) : null,
              icon: const Icon(Icons.palette_rounded),
              label: const Text('تصميم الواجهات من الوصف'),
            ),
          ),
          if (_hasDesign[i] == true)
            Center(
              child: TextButton.icon(
                onPressed: idle ? () => _showDesign(i) : null,
                icon: const Icon(Icons.visibility_rounded),
                label: const Text('عرض آخر تصميم'),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الأسماء والأيقونات والتصميم')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _spec == null
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'ما في فكرة معتمدة. اعتمد فكرة أو اختار قالب أولاً.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white60, height: 1.7),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TextField(
                      controller: _notes,
                      minLines: 1,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'ملاحظات للتصميم (اختياري)',
                        hintText: 'مثال: ألوان ذهبية، أو أضف شاشة عروض',
                      ),
                    ),
                    const SizedBox(height: 14),
                    for (var i = 0; i < _names.length; i++) _appCard(i),
                    if (_busy != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          children: [
                            const LinearProgressIndicator(),
                            const SizedBox(height: 8),
                            Text(_busy!),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _busy == null
                          ? () async {
                              await _saveNames();
                              _toast('تم حفظ الأسماء');
                            }
                          : null,
                      icon: const Icon(Icons.save_rounded),
                      label: const Text('حفظ الأسماء'),
                    ),
                  ],
                ),
    );
  }
}
