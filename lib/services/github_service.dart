import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'settings_service.dart';

class RepoFile {
  final String path;
  final String? text;
  final Uint8List? bytes;
  RepoFile.text(this.path, this.text) : bytes = null;
  RepoFile.bytes(this.path, this.bytes) : text = null;
}

class GithubService {
  static Future<Map<String, String>> _cfg() async {
    final token = (await SettingsService.get('github_token')).trim();
    final repo = (await SettingsService.get('github_repo')).trim();
    if (token.isEmpty || !repo.contains('/')) {
      throw Exception('أضف GitHub Token والمستودع بصيغة username/AAS في الإعدادات');
    }
    return {'token': token, 'repo': repo};
  }

  static Future<dynamic> _call(String method, String path,
      {Object? body}) async {
    final c = await _cfg();
    final uri = Uri.parse('https://api.github.com/repos/${c['repo']}$path');
    final headers = {
      'Authorization': 'Bearer ${c['token']}',
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
    };
    final Future<http.Response> f = switch (method) {
      'GET' => http.get(uri, headers: headers),
      'POST' => http.post(uri, headers: headers, body: jsonEncode(body)),
      'PATCH' => http.patch(uri, headers: headers, body: jsonEncode(body)),
      _ => throw ArgumentError(method),
    };
    final res = await f.timeout(const Duration(seconds: 90));
    final text = utf8.decode(res.bodyBytes);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final short = text.length > 250 ? text.substring(0, 250) : text;
      throw Exception('GitHub ${res.statusCode}: $short');
    }
    if (text.isEmpty) return null;
    return jsonDecode(text);
  }

  static Future<Map<String, dynamic>> repoInfo() async =>
      Map<String, dynamic>.from(await _call('GET', '') as Map);

  /// يرفع الملفات في commit واحد. pruneUnder: مسارات يتم حذف الملفات الغايبة منها.
  static Future<String> push(
    List<RepoFile> files, {
    required String message,
    List<String> pruneUnder = const [],
  }) async {
    final info = await repoInfo();
    final branch = (info['default_branch'] ?? 'main').toString();

    final ref = await _call('GET', '/git/ref/heads/$branch');
    final headSha = ref['object']['sha'] as String;
    final commit = await _call('GET', '/git/commits/$headSha');
    final baseTree = commit['tree']['sha'] as String;

    final entries = <Map<String, dynamic>>[];
    for (final f in files) {
      if (f.bytes != null) {
        final blob = await _call('POST', '/git/blobs', body: {
          'content': base64Encode(f.bytes!),
          'encoding': 'base64',
        });
        entries.add({
          'path': f.path,
          'mode': '100644',
          'type': 'blob',
          'sha': blob['sha'],
        });
      } else {
        entries.add({
          'path': f.path,
          'mode': '100644',
          'type': 'blob',
          'content': f.text ?? '',
        });
      }
    }

    if (pruneUnder.isNotEmpty) {
      final tree = await _call('GET', '/git/trees/$baseTree?recursive=1');
      final keep = files.map((f) => f.path).toSet();
      for (final t in (tree['tree'] as List)) {
        final p = (t['path'] ?? '').toString();
        final under = pruneUnder.any((pre) => p.startsWith(pre));
        if (t['type'] == 'blob' && under && !keep.contains(p)) {
          entries.add({
            'path': p,
            'mode': '100644',
            'type': 'blob',
            'sha': null,
          });
        }
      }
    }

    final newTree = await _call('POST', '/git/trees', body: {
      'base_tree': baseTree,
      'tree': entries,
    });
    final newCommit = await _call('POST', '/git/commits', body: {
      'message': message,
      'tree': newTree['sha'],
      'parents': [headSha],
    });
    await _call('PATCH', '/git/refs/heads/$branch', body: {
      'sha': newCommit['sha'],
    });
    return newCommit['sha'] as String;
  }

  /// يبدأ بناء تطبيق، ويرجع وقت البدء
  static Future<DateTime> dispatchBuild({
    required String appDir,
    required String appKey,
    required String appName,
  }) async {
    final info = await repoInfo();
    final branch = (info['default_branch'] ?? 'main').toString();
    final started = DateTime.now().toUtc();
    Object? lastErr;
    for (var i = 0; i < 6; i++) {
      try {
        await _call('POST', '/actions/workflows/build-app.yml/dispatches',
            body: {
              'ref': branch,
              'inputs': {
                'app_dir': appDir,
                'app_key': appKey,
                'app_name': appName,
              },
            });
        return started;
      } catch (e) {
        lastErr = e;
        await Future.delayed(const Duration(seconds: 5));
      }
    }
    throw Exception('تعذر بدء البناء: $lastErr');
  }

  static Future<Map<String, dynamic>?> findRun(DateTime after) async {
    final data = await _call('GET',
        '/actions/workflows/build-app.yml/runs?event=workflow_dispatch&per_page=5');
    for (final r in (data['workflow_runs'] as List)) {
      final created = DateTime.parse(r['created_at'] as String);
      if (!created.isBefore(after.subtract(const Duration(seconds: 60)))) {
        return Map<String, dynamic>.from(r as Map);
      }
    }
    return null;
  }

  static Future<Map<String, dynamic>> getRun(int id) async =>
      Map<String, dynamic>.from(await _call('GET', '/actions/runs/$id') as Map);
}
