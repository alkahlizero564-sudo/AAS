import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import 'generate_screen.dart';
import 'idea_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _filled = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var n = 0;
    for (final f in SettingsService.fields) {
      if ((await SettingsService.get(f.key)).isNotEmpty) n++;
    }
    if (mounted) setState(() => _filled = n);
  }

  Future<void> _open(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    _load();
  }

  Widget _navCard(IconData icon, String title, String sub, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1A2347),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            children: [
              Icon(icon),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(sub, style: const TextStyle(color: Colors.white60)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_left_rounded),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = SettingsService.fields.length;
    const card = Color(0xFF1A2347);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'AAS',
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2),
        ),
        actions: [
          IconButton(
            onPressed: () => _open(const SettingsScreen()),
            icon: const Icon(Icons.settings_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: card,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'مصنع التطبيقات',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                const Text(
                  'اكتب فكرة تطبيقك ونحن نبنيه.',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => _open(const IdeaScreen()),
                  icon: const Icon(Icons.auto_awesome_rounded),
                  label: const Text('تطبيق جديد'),
                ),
              ],
            ),
          ),
          _navCard(
            Icons.storage_rounded,
            'توليد المشروع',
            'قاعدة البيانات وكود التطبيقات',
            () => _open(const GenerateScreen()),
          ),
          InkWell(
            onTap: () => _open(const SettingsScreen()),
            borderRadius: BorderRadius.circular(24),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: card,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.key_rounded),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'الإعدادات والمفاتيح',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700),
                        ),
                      ),
                      Text('$_filled / $total'),
                    ],
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: total == 0 ? 0 : _filled / total,
                      minHeight: 8,
                    ),
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
