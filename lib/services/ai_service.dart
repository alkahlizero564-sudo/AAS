import 'dart:convert';
import 'package:http/http.dart' as http;
import 'settings_service.dart';

class ChatTurn {
  final bool user;
  final String text;
  const ChatTurn(this.user, this.text);
}

class AiService {
  static const _defaultGemini = 'gemini-2.5-flash';
  static const _claudeModel = 'claude-sonnet-5-5';

  /// يرجع نص الرد (JSON) من Gemini أو Claude
  static Future<String> ask(String system, List<ChatTurn> turns) async {
    final errors = <String>[];

    var model = await SettingsService.get(SettingsService.modelKey);
    if (model.isEmpty) model = _defaultGemini;

    for (var i = 1; i <= 4; i++) {
      final key = await SettingsService.get('gemini_key_$i');
      if (key.isEmpty) continue;
      try {
        return await _gemini(key, model, system, turns);
      } catch (e) {
        errors.add('Gemini $i: $e');
      }
    }

    final claude = await SettingsService.get('claude_key');
    if (claude.isNotEmpty) {
      try {
        return await _claude(claude, system, turns);
      } catch (e) {
        errors.add('Claude: $e');
      }
    }

    if (errors.isEmpty) {
      throw Exception('أضف مفتاح Gemini أو Claude في الإعدادات');
    }
    throw Exception(errors.join('\n'));
  }

  static Future<String> _gemini(
    String key,
    String model,
    String system,
    List<ChatTurn> turns,
  ) async {
    final res = await http
        .post(
          Uri.parse(
              'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
          headers: {
            'x-goog-api-key': key,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'systemInstruction': {
              'parts': [
                {'text': system}
              ]
            },
            'contents': [
              for (final t in turns)
                {
                  'role': t.user ? 'user' : 'model',
                  'parts': [
                    {'text': t.text}
                  ],
                }
            ],
            'generationConfig': {
              'responseMimeType': 'application/json',
              'temperature': 0.7,
            },
          }),
        )
        .timeout(const Duration(seconds: 60));

    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    final parts = data['candidates'][0]['content']['parts'] as List;
    return parts.map((p) => p['text'] ?? '').join();
  }

  static Future<String> _claude(
    String key,
    String system,
    List<ChatTurn> turns,
  ) async {
    final res = await http
        .post(
          Uri.parse('https://api.anthropic.com/v1/messages'),
          headers: {
            'x-api-key': key,
            'anthropic-version': '2023-06-01',
            'content-type': 'application/json',
          },
          body: jsonEncode({
            'model': _claudeModel,
            'max_tokens': 2500,
            'system': system,
            'messages': [
              for (final t in turns)
                {
                  'role': t.user ? 'user' : 'assistant',
                  'content': t.text,
                }
            ],
          }),
        )
        .timeout(const Duration(seconds: 60));

    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    return (data['content'] as List).map((b) => b['text'] ?? '').join();
  }

  /// يحول رد الذكاء الاصطناعي إلى Map (يتعامل مع ```json وأي نص زائد)
  static Map<String, dynamic>? parseJson(String raw) {
    var t = raw.trim();
    t = t
        .replaceAll(RegExp(r'^```(?:json)?'), '')
        .replaceAll(RegExp(r'```$'), '')
        .trim();
    try {
      final v = jsonDecode(t);
      if (v is Map<String, dynamic>) return v;
    } catch (_) {}
    final s = t.indexOf('{');
    final e = t.lastIndexOf('}');
    if (s >= 0 && e > s) {
      try {
        final v = jsonDecode(t.substring(s, e + 1));
        if (v is Map<String, dynamic>) return v;
      } catch (_) {}
    }
    return null;
  }
}
