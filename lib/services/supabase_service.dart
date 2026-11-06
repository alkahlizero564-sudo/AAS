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

  /// ينفذ SQL على المشروع عن طريق Supabase Management API
  static Future<void> runSql(String sql) async {
    final token = (await SettingsService.get('supabase_token')).trim();
    final ref = (await SettingsService.get('supabase_ref')).trim();
    if (token.isEmpty || ref.isEmpty) {
      throw Exception('أضف Supabase Access Token و Project Ref في الإعدادات');
    }
    final res = await http
        .post(
          Uri.parse('https://api.supabase.com/v1/projects/$ref/database/query'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'query': sql}),
        )
        .timeout(const Duration(seconds: 90));

    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('HTTP ${res.statusCode}\n${utf8.decode(res.bodyBytes)}');
    }
  }
}
