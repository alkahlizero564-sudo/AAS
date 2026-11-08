import 'dart:convert';
import 'dart:math';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'ai_service.dart';
import 'settings_service.dart';
import 'supabase_service.dart';

class NotifyService {
  static const secretKey = 'notify_secret';
  static const functionSlug = 'notify';

  // ---------- أدوات عامة ----------
  static String _short(http.Response r) {
    final t = utf8.decode(r.bodyBytes);
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

  /// سر مشترك بين قاعدة البيانات والدالة (بيتولد مرة واحدة)
  static Future<String> ensureSecret() async {
    var s = await SettingsService.get(secretKey);
    if (s.isEmpty) {
      final r = Random.secure();
      const chars =
          'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
      s = List.generate(40, (_) => chars[r.nextInt(chars.length)]).join();
      await SettingsService.set(secretKey, s);
    }
    return s;
  }

  /// استعلام SQL بيرجع صفوف
  static Future<List<dynamic>> query(String sql) async {
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
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('HTTP ${res.statusCode}\n${_short(res)}');
    }
    final d = jsonDecode(utf8.decode(res.bodyBytes));
    return d is List ? d : [];
  }

  // ---------- 1) قاعدة البيانات ----------
  static const _migration = r'''
create table if not exists public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  token text not null,
  created_at timestamptz default now()
);
alter table public.device_tokens add column if not exists app_key text;
alter table public.device_tokens add column if not exists updated_at timestamptz default now();
create unique index if not exists device_tokens_token_uidx on public.device_tokens (token);
alter table public.device_tokens enable row level security;
drop policy if exists "device_tokens_own" on public.device_tokens;
create policy "device_tokens_own" on public.device_tokens
  for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create or replace function public.register_device(p_token text, p_app_key text)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null then
    return;
  end if;
  insert into public.device_tokens (user_id, token, app_key)
  values (auth.uid(), p_token, p_app_key)
  on conflict (token) do update
    set user_id = excluded.user_id,
        app_key = excluded.app_key,
        updated_at = now();
end;
$fn$;
revoke all on function public.register_device(text, text) from public, anon;
grant execute on function public.register_device(text, text) to authenticated;

create extension if not exists pg_net with schema extensions;

create or replace function public.notify_users(p_user_ids uuid[], p_title text, p_body text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if p_user_ids is null or coalesce(array_length(p_user_ids, 1), 0) = 0 then
    return;
  end if;
  perform net.http_post(
    url := '__FN_URL__',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret', '__SECRET__'),
    body := jsonb_build_object('user_ids', to_jsonb(p_user_ids), 'title', p_title, 'body', p_body)
  );
end;
$fn$;
revoke all on function public.notify_users(uuid[], text, text) from public, anon, authenticated;
''';

  static Future<String> migrationSql() async {
    final secret = await ensureSecret();
    final base = await SupabaseService.url();
    return _migration
        .replaceAll('__FN_URL__', '$base/functions/v1/$functionSlug')
        .replaceAll('__SECRET__', secret);
  }

  // ---------- 2) دالة الإرسال (Edge Function) ----------
  static const functionCode = r'''
import { createClient } from "npm:@supabase/supabase-js@2";
import { SignJWT, importPKCS8 } from "npm:jose@5";

const sa = JSON.parse(Deno.env.get("FIREBASE_SERVICE_ACCOUNT") ?? "{}");

async function accessToken(): Promise<string> {
  const key = await importPKCS8(sa.private_key, "RS256");
  const jwt = await new SignJWT({
    scope: "https://www.googleapis.com/auth/firebase.messaging",
  })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(sa.client_email)
    .setSubject(sa.client_email)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt()
    .setExpirationTime("1h")
    .sign(key);
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  const j = await r.json();
  if (!j.access_token) throw new Error("oauth failed: " + JSON.stringify(j));
  return j.access_token;
}

Deno.serve(async (req) => {
  if (req.headers.get("x-notify-secret") !== Deno.env.get("NOTIFY_SECRET")) {
    return new Response("forbidden", { status: 403 });
  }
  try {
    const { user_ids, title, body } = await req.json();
    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { data } = await sb
      .from("device_tokens")
      .select("token")
      .in("user_id", user_ids ?? []);
    const tokens = [...new Set((data ?? []).map((d: { token: string }) => d.token))];
    if (tokens.length === 0) return Response.json({ sent: 0, tokens: 0 });

    const at = await accessToken();
    let sent = 0;
    const dead: string[] = [];
    let lastError = "";
    for (const token of tokens) {
      const r = await fetch(
        `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${at}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: { token, notification: { title, body } },
          }),
        },
      );
      if (r.ok) {
        sent++;
      } else {
        const t = await r.text();
        lastError = t.slice(0, 300);
        if (t.includes("UNREGISTERED") || t.includes("NOT_FOUND")) dead.push(token);
      }
    }
    if (dead.length) await sb.from("device_tokens").delete().in("token", dead);
    return Response.json({ sent, tokens: tokens.length, error: lastError });
  } catch (e) {
    return new Response(String(e), { status: 500 });
  }
});
''';

  static Future<void> setSecrets() async {
    final c = await _creds();
    final fb = (await SettingsService.get('firebase_json')).trim();
    if (fb.isEmpty) throw Exception('أضف Firebase JSON في الإعدادات');
    final compact = jsonEncode(jsonDecode(fb));
    final secret = await ensureSecret();
    final res = await http
        .post(
          Uri.parse('https://api.supabase.com/v1/projects/${c['ref']}/secrets'),
          headers: {
            'Authorization': 'Bearer ${c['token']}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode([
            {'name': 'FIREBASE_SERVICE_ACCOUNT', 'value': compact},
            {'name': 'NOTIFY_SECRET', 'value': secret},
          ]),
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('الأسرار: HTTP ${res.statusCode}\n${_short(res)}');
    }
  }

  static Future<void> deployFunction() async {
    final c = await _creds();
    final uri = Uri.parse(
        'https://api.supabase.com/v1/projects/${c['ref']}/functions/deploy?slug=$functionSlug');
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${c['token']}'
      ..fields['metadata'] = jsonEncode({
        'entrypoint_path': 'index.ts',
        'name': functionSlug,
        'verify_jwt': false,
      })
      ..files.add(http.MultipartFile.fromString('file', functionCode,
          filename: 'index.ts'));
    final streamed = await req.send().timeout(const Duration(seconds: 120));
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('النشر: HTTP ${res.statusCode}\n${_short(res)}');
    }
  }

  // ---------- 3) ربط Firebase ----------
  static String packageFor(int i) => 'com.aas.aas_app${i + 1}';

  static Future<Map<String, dynamic>> _json(Future<http.Response> f) async {
    final res = await f.timeout(const Duration(seconds: 60));
    final t = utf8.decode(res.bodyBytes);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(
          'Firebase HTTP ${res.statusCode}: ${t.length > 250 ? t.substring(0, 250) : t}');
    }
    return t.isEmpty ? {} : jsonDecode(t) as Map<String, dynamic>;
  }

  /// يسجل التطبيق في Firebase (لو ما مسجل) ويرجع محتوى google-services.json
  static Future<String> fetchGoogleServices(String package) async {
    final raw = (await SettingsService.get('firebase_json')).trim();
    if (raw.isEmpty) throw Exception('أضف Firebase JSON في الإعدادات');
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final projectId = map['project_id'] as String;
    final client = await clientViaServiceAccount(
      ServiceAccountCredentials.fromJson(map),
      ['https://www.googleapis.com/auth/cloud-platform'],
    );
    try {
      final base = 'https://firebase.googleapis.com/v1beta1/projects/$projectId';
      final list =
          await _json(client.get(Uri.parse('$base/androidApps?pageSize=100')));
      String? appId;
      for (final a in (list['apps'] as List? ?? [])) {
        if (a['packageName'] == package) appId = a['appId'] as String?;
      }
      if (appId == null) {
        final op = await _json(client.post(
          Uri.parse('$base/androidApps'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'packageName': package, 'displayName': package}),
        ));
        final opName = op['name'] as String;
        for (var i = 0; i < 20; i++) {
          await Future.delayed(const Duration(seconds: 3));
          final st = await _json(client
              .get(Uri.parse('https://firebase.googleapis.com/v1beta1/$opName')));
          if (st['done'] == true) {
            appId = (st['response'] as Map?)?['appId'] as String?;
            break;
          }
        }
      }
      if (appId == null) throw Exception('تعذر تسجيل التطبيق في Firebase');
      final cfg =
          await _json(client.get(Uri.parse('$base/androidApps/$appId/config')));
      return utf8.decode(base64Decode(cfg['configFileContents'] as String));
    } finally {
      client.close();
    }
  }

  /// اسم الحزمة داخل google-services.json (أو null لو الملف غير صالح)
  static String? packageOf(String gs) {
    try {
      final m = jsonDecode(gs) as Map<String, dynamic>;
      final c = (m['client'] as List).first as Map;
      return c['client_info']['android_client_info']['package_name'] as String?;
    } catch (_) {
      return null;
    }
  }

  // ---------- 4) قواعد الإشعارات (Triggers) ----------
  static const _trigSystem = r'''
You write PostgreSQL trigger SQL for Supabase that sends push notifications.

A helper function ALREADY exists: public.notify_users(p_user_ids uuid[], p_title text, p_body text). Do NOT create it. Call it with: perform public.notify_users(array[...]::uuid[], 'title', 'body');

You receive JSON: {"schema_sql": "...", "notifications": ["event descriptions"], "roles": ["..."]}.

For each notification event write:
1. A trigger function: language plpgsql, security definer, set search_path = public, that computes the recipient user ids (for example the customer who owns the row, or all profiles whose role is in ('admin','staff')) and calls public.notify_users with a short Arabic title and body.
2. A trigger: drop trigger if exists first, then create trigger ... after insert or update ... for each row execute function ...
   For status changes, fire only when old.status is distinct from new.status.

Rules:
- Only reference tables and columns that exist in schema_sql. If an event cannot be mapped to a real table or column, skip it and add an SQL comment.
- Everything must be idempotent (create or replace function, drop trigger if exists).
- Output ONLY raw SQL (no markdown fences, no explanations).
- NEVER use DROP TABLE, DROP SCHEMA, TRUNCATE, or DELETE without a where clause.
''';

  static Future<String> genTriggersSql(
      Map<String, dynamic> spec, String schemaSql) async {
    final backend = (spec['backend'] as Map?) ?? {};
    final raw = await AiService.ask(
      _trigSystem,
      [
        ChatTurn(
          true,
          jsonEncode({
            'schema_sql': schemaSql,
            'notifications': backend['notifications'] ?? [],
            'roles': backend['roles'] ?? [],
          }),
        ),
      ],
      json: false,
      maxTokens: 10000,
    );
    return raw
        .replaceAll(RegExp(r'^```[a-zA-Z]*[ \t]*\r?\n?', multiLine: true), '')
        .trim();
  }

  // ---------- 5) اختبار ----------
  static Future<String> sendTest(String email) async {
    final e = email.trim().replaceAll("'", "''");
    final rows = await query(
        "select id from auth.users where lower(email) = lower('$e') limit 1;");
    if (rows.isEmpty) {
      throw Exception('ما في مستخدم بهذا البريد. سجّل الدخول في التطبيق أولاً.');
    }
    final id = rows.first['id'];
    final cnt = await query(
        "select count(*) as n from public.device_tokens where user_id = '$id';");
    final n = int.tryParse('${cnt.first['n']}') ?? 0;
    if (n == 0) {
      throw Exception(
          'ما في جهاز مسجل لهذا المستخدم. افتح التطبيق (نسخة فيها Firebase)، سجّل الدخول، وامنح إذن الإشعارات.');
    }

    final base = await SupabaseService.url();
    final secret = await ensureSecret();
    final key = (await SettingsService.get('supabase_key')).trim();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'x-notify-secret': secret,
      if (key.isNotEmpty) 'apikey': key,
      if (key.split('.').length == 3) 'Authorization': 'Bearer $key',
    };
    final res = await http
        .post(
          Uri.parse('$base/functions/v1/$functionSlug'),
          headers: headers,
          body: jsonEncode({
            'user_ids': [id],
            'title': 'اختبار AAS',
            'body': 'الإشعارات شغالة',
          }),
        )
        .timeout(const Duration(seconds: 60));
    return 'HTTP ${res.statusCode}: ${_short(res)}';
  }
}
