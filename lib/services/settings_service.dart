import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SettingField {
  final String key;
  final String label;
  final String hint;
  final String group;
  final bool multiline;
  final bool plain;

  const SettingField(
    this.key,
    this.label,
    this.hint,
    this.group, {
    this.multiline = false,
    this.plain = false,
  });
}

class SettingsService {
  static const _storage = FlutterSecureStorage();
  static const modelKey = 'gemini_model';

  static const fields = <SettingField>[
    SettingField('gemini_key_1', 'Gemini API Key 1', 'AIza...', 'Gemini'),
    SettingField('gemini_key_2', 'Gemini API Key 2', 'AIza...', 'Gemini'),
    SettingField('gemini_key_3', 'Gemini API Key 3', 'AIza...', 'Gemini'),
    SettingField('gemini_key_4', 'Gemini API Key 4', 'AIza...', 'Gemini'),
    SettingField('claude_key', 'Claude API Key', 'sk-ant-...', 'Claude'),
    SettingField('github_token', 'GitHub Access Token', 'ghp_...', 'GitHub'),
    SettingField('github_repo', 'المستودع (GitHub Repo)', 'username/AAS', 'GitHub',
        plain: true),
    SettingField('supabase_token', 'Personal Access Token (من الحساب)',
        'sbp_...', 'Supabase'),
    SettingField('supabase_ref', 'Project Ref (من رابط المشروع)',
        'abcdefghijklmn', 'Supabase',
        plain: true),
    SettingField('supabase_key', 'Publishable key (من API Keys)',
        'sb_publishable_... أو مفتاح anon', 'Supabase'),
    SettingField('smtp_host', 'SMTP: الخادم (اختياري)',
        'smtp-relay.brevo.com', 'Supabase',
        plain: true),
    SettingField('smtp_port', 'SMTP: المنفذ', '587', 'Supabase', plain: true),
    SettingField('smtp_user', 'SMTP: اسم المستخدم', 'xxxx@smtp-brevo.com',
        'Supabase',
        plain: true),
    SettingField('smtp_pass', 'SMTP: كلمة المرور', '', 'Supabase'),
    SettingField('smtp_sender', 'SMTP: عنوان المرسل', 'you@gmail.com',
        'Supabase',
        plain: true),
    SettingField('firebase_json', 'Firebase JSON Key', '{ ... }', 'Firebase',
        multiline: true),
  ];

  static List<SettingField> group(String g) =>
      fields.where((f) => f.group == g).toList();

  static Future<String> get(String key) async =>
      await _storage.read(key: key) ?? '';

  static Future<void> set(String key, String value) async {
    final v = value.trim();
    if (v.isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: v);
    }
  }
}
