import 'dart:convert';
import 'package:http/http.dart' as http;
import 'settings_service.dart';

class SupabaseService {
  static Future<String> url() async {
    final ref = (await SettingsService.get('supabase_ref')).trim();
    return 'https://$ref.supabase.co';
  }

  /// يرجع رسالة لو المفتاح سري (service_role) وما ينفع يتحط في تطبيق
  static String? keyProblem(String key) {
    if (key.startsWith('sb_secret_')) {
      return 'ده مفتاح سري. استخدم مفتاح anon أو publishable في الإعدادات.';
    }
    try {
      final parts = key.split('.');
      if (parts.length == 3) {
        final payload =
            utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
        final role = (jsonDecode(payload) as Map)['role'];
        if (role == 'service_role') {
          return 'ده مفتاح service_role وخطر يتحط جوه تطبيق. استخدم مفتاح anon في الإعدادات.';
        }
      }
    } catch (_) {}
    return null;
  }

  /// يرجع رسالة لو الـ SQL فيهو أوامر مدمرة
  static String? sqlProblem(String sql) {
    final s = sql.toLowerCase();
    if (RegExp(r'\bdrop\s+(table|schema|database)\b').hasMatch(s)) {
      return 'الـ SQL فيهو DROP لجدول أو مخطط. ما بنفذو.';
    }
    if (RegExp(r'\btruncate\b').hasMatch(s)) {
      return 'الـ SQL فيهو TRUNCATE. ما بنفذو.';
    }
    return null;
  }

  static String _short(http.Response res) {
    final t = utf8.decode(res.bodyBytes);
    return t.length > 300 ? '${t.substring(0, 300)}...' : t;
  }

  static Future<Map<String, String>> _creds() async {
    final token = (await SettingsService.get('supabase_token')).trim();
    final ref = (await SettingsService.get('supabase_ref')).trim();
    if (token.isEmpty || ref.isEmpty) {
      throw Exception('أضف Personal Access Token و Project Ref في الإعدادات');
    }
    return {'token': token, 'ref': ref};
  }

  /// ينفذ SQL على المشروع عن طريق Supabase Management API
  static Future<void> runSql(String sql) async {
    final c = await _creds();
    final res = await http
        .post(
          Uri.parse(
              'https://api.supabase.com/v1/projects/${c['ref']}/database/query'),
          headers: {
            'Authorization': 'Bearer ${c['token']}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'query': sql}),
        )
        .timeout(const Duration(seconds: 90));

    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('HTTP ${res.statusCode}\n${_short(res)}');
    }
  }

  static Future<void> _patchAuth(Map<String, dynamic> body) async {
    final c = await _creds();
    final res = await http
        .patch(
          Uri.parse(
              'https://api.supabase.com/v1/projects/${c['ref']}/config/auth'),
          headers: {
            'Authorization': 'Bearer ${c['token']}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}\n${_short(res)}');
    }
  }

  static Future<Map<String, dynamic>> _getAuthConfig() async {
    final c = await _creds();
    final res = await http.get(
      Uri.parse('https://api.supabase.com/v1/projects/${c['ref']}/config/auth'),
      headers: {'Authorization': 'Bearer ${c['token']}'},
    ).timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}\n${_short(res)}');
    }
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  /// يطبق إعدادات SMTP وقوالب الإيميل، ثم يقرا الإعدادات للتأكد
  static Future<List<String>> applyAndVerifyEmailConfig() async {
    final host = (await SettingsService.get('smtp_host')).trim();
    final port = (await SettingsService.get('smtp_port')).trim();
    final user = (await SettingsService.get('smtp_user')).trim();
    final pass = (await SettingsService.get('smtp_pass')).trim();
    final sender = (await SettingsService.get('smtp_sender')).trim();
    final lines = <String>[];

    if (host.isEmpty) {
      lines.add(
          'ما في SMTP: Supabase بيستخدم خدمتو الافتراضية (رموز قليلة في الساعة ولعناوين فريقك فقط).');
    } else {
      if (port.isEmpty || user.isEmpty || pass.isEmpty || sender.isEmpty) {
        throw Exception('أكمل كل حقول SMTP (المنفذ، المستخدم، كلمة المرور، المرسل)');
      }
      await _patchAuth({
        'external_email_enabled': true,
        'smtp_host': host,
        'smtp_port': port,
        'smtp_user': user,
        'smtp_pass': pass,
        'smtp_admin_email': sender,
        'smtp_sender_name': 'AAS',
      });
      lines.add('تم تطبيق إعدادات SMTP');
    }

    try {
      const body =
          '<h2>رمز التأكيد</h2><p>رمزك هو: <b>{{ .Token }}</b></p>';
      await _patchAuth({
        'mailer_otp_length': 6,
        'mailer_subjects_confirmation': 'رمز التأكيد',
        'mailer_subjects_magic_link': 'رمز الدخول',
        'mailer_templates_confirmation_content': body,
        'mailer_templates_magic_link_content': body,
      });
      lines.add('تم ضبط قوالب الإيميل لتعرض الرمز');
    } catch (e) {
      lines.add('تعذر ضبط القوالب (ضيف {{ .Token }} يدوياً من Dashboard): $e');
    }

    if (host.isNotEmpty) {
      final cfg = await _getAuthConfig();
      final h = cfg['smtp_host'];
      final p = cfg['smtp_port'];
      final u = cfg['smtp_user'];
      final a = cfg['smtp_admin_email'];
      lines.add('المخزن في Supabase: $h : $p\nالمستخدم: $u\nالمرسل: $a');
    }
    return lines;
  }

  /// يرسل رمز دخول حقيقي لبريد الاختبار ويرجع رد Supabase
  static Future<String> sendTestOtp(String email) async {
    final key = (await SettingsService.get('supabase_key')).trim();
    if (key.isEmpty) throw Exception('أضف Publishable key في الإعدادات');
    final kp = keyProblem(key);
    if (kp != null) throw Exception(kp);

    final base = await url();
    final res = await http
        .post(
          Uri.parse('$base/auth/v1/otp'),
          headers: {'apikey': key, 'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'create_user': true}),
        )
        .timeout(const Duration(seconds: 30));

    if (res.statusCode >= 200 && res.statusCode < 300) {
      return 'تم الإرسال (HTTP ${res.statusCode}). افحص بريدك (وفولدر السبام).';
    }
    return 'رد Supabase: HTTP ${res.statusCode}\n${_short(res)}';
  }
}
