import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/preview_service.dart';
import '../services/settings_service.dart';
import '../services/templates.dart';
import '../widgets/html_preview.dart';
import 'design_screen.dart';

class TemplatesScreen extends StatefulWidget {
  const TemplatesScreen({super.key});

  @override
  State<TemplatesScreen> createState() => _TemplatesScreenState();
}

class _TemplatesScreenState extends State<TemplatesScreen> {
  final Map<String, String> _cache = {};
  String? _busyId;

  void _toast(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _preview(AppTemplate t) async {
    if (_busyId != null) return;
    setState(() => _busyId = t.id);
    try {
      var html = _cache[t.id];
      html ??= await PreviewService.aiHtml(
        'وصف فقط',
        jsonEncode({
          'app': (t.spec['apps'] as List).first,
          'backend': t.spec['backend'],
        }),
      );
      _cache[t.id] = html;
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => HtmlPreviewPage(title: t.title, html: html!),
        ),
      );
    } catch (e) {
      _toast('تعذرت المعاينة: $e');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _use(AppTemplate t) async {
    await SettingsService.set('project_spec', jsonEncode(t.spec));
    if (!mounted) return;
    _toast('تم اختيار قالب ${t.title}');
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DesignScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('القوالب الجاهزة')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Text(
              'اختار قالب وبيتحول لفكرة معتمدة جاهزة (تطبيقين: عميل وإدارة). بعدها غيّر الأسماء والأيقونات وولّد المشروع.',
              style: TextStyle(color: Colors.white60, height: 1.6),
            ),
          ),
          for (final t in templates) _card(t),
        ],
      ),
    );
  }

  Widget _card(AppTemplate t) {
    final apps = t.spec['apps'] as List;
    final busy = _busyId == t.id;

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
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFF0F1630),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(t.icon, color: const Color(0xFFC6F750), size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.title,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      t.subtitle,
                      style:
                          const TextStyle(color: Colors.white60, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in apps)
                Chip(
                  label: Text((a as Map)['name'].toString(),
                      style: const TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busyId == null ? () => _preview(t) : null,
                  icon: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.visibility_rounded),
                  label: const Text('معاينة'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busyId == null ? () => _use(t) : null,
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('استخدم القالب'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
