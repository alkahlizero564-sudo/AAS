import 'dart:convert';
import 'package:http/http.dart' as http;

class GeminiService {
  /// يجلب كل نماذج Gemini اللي تدعم generateContent
  static Future<List<String>> listModels(String apiKey) async {
    final res = await http
        .get(
          Uri.parse(
              'https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000'),
          headers: {'x-goog-api-key': apiKey},
        )
        .timeout(const Duration(seconds: 20));

    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final out = <String>[];
    for (final m in (data['models'] as List? ?? [])) {
      final methods = (m['supportedGenerationMethods'] as List? ?? []);
      if (methods.contains('generateContent')) {
        out.add((m['name'] as String).replaceFirst('models/', ''));
      }
    }
    out.sort();
    return out;
  }
}
