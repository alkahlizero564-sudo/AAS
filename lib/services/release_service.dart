import 'github_service.dart';
import 'project_store.dart';

class ReleaseService {
  // ---------------------------------------------------------------
  // .github/workflows/build-apk.yml  (بناء AAS نفسو)
  // ---------------------------------------------------------------
  static const workflowFactory = r'''
name: Build AAS APK

on:
  workflow_dispatch:
  push:
    branches: [main]
    paths-ignore:
      - 'apps/**'

permissions:
  contents: write

env:
  APP_NAME: AAS
  KS_PASS: ${{ secrets.KS_PASS }}

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'

      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - name: Create android platform files
        run: |
          if [ ! -d android ]; then
            flutter create --platforms=android --project-name aas --org com.aas .
          fi
          rm -rf test

      - name: Patch android
        run: python3 tools/patch_android.py .

      - run: flutter pub get

      - name: Build
        run: flutter build apk --release --build-number=${{ github.run_number }} --dart-define=BUILD_NUMBER=${{ github.run_number }}

      - name: Sign apk
        run: bash tools/sign_apk.sh build/app/outputs/flutter-apk/app-release.apk "$APP_NAME.apk" signing/factory.keystore.enc

      - name: Commit keystore if new
        run: |
          if [ -n "$(git status --porcelain signing)" ]; then
            git config user.name "aas-bot"
            git config user.email "aas-bot@users.noreply.github.com"
            git add signing
            git commit -m "chore: add signing keystore"
            git pull --rebase origin ${{ github.ref_name }}
            git push origin HEAD:${{ github.ref_name }}
          fi

      - uses: actions/upload-artifact@v4
        with:
          name: ${{ env.APP_NAME }}-apk
          path: ${{ env.APP_NAME }}.apk

      - uses: softprops/action-gh-release@v2
        with:
          tag_name: build-${{ github.run_number }}
          name: ${{ env.APP_NAME }} build ${{ github.run_number }}
          files: ${{ env.APP_NAME }}.apk
''';

  // ---------------------------------------------------------------
  // .github/workflows/build-app.yml  (بناء التطبيقات المولّدة)
  // ---------------------------------------------------------------
  static const workflowApp = r'''
name: Build Generated App

on:
  workflow_dispatch:
    inputs:
      app_dir:
        description: 'مثل apps/app1'
        required: true
        type: string
      app_key:
        description: 'مثل app1'
        required: true
        type: string
      app_name:
        description: 'اسم التطبيق'
        required: true
        type: string

permissions:
  contents: write

env:
  KS_PASS: ${{ secrets.KS_PASS }}
  APP_DIR: ${{ inputs.app_dir }}
  APP_KEY: ${{ inputs.app_key }}
  APP_NAME: ${{ inputs.app_name }}

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'

      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - name: Create android platform files
        run: |
          cd "$APP_DIR"
          flutter create --platforms=android --project-name "aas_$APP_KEY" --org com.aas .
          rm -rf test

      - name: Patch android
        run: python3 tools/patch_android.py "$APP_DIR"

      - name: Build
        run: |
          cd "$APP_DIR"
          flutter pub get
          flutter build apk --release --build-number=${{ github.run_number }} --dart-define=BUILD_NUMBER=${{ github.run_number }}

      - name: Sign apk
        run: bash tools/sign_apk.sh "$APP_DIR/build/app/outputs/flutter-apk/app-release.apk" "$APP_KEY.apk" "$APP_DIR/signing/release.keystore.enc"

      - name: Commit keystore if new
        run: |
          if [ -n "$(git status --porcelain "$APP_DIR/signing")" ]; then
            git config user.name "aas-bot"
            git config user.email "aas-bot@users.noreply.github.com"
            git add "$APP_DIR/signing"
            git commit -m "chore: add signing keystore for $APP_KEY"
            git pull --rebase origin ${{ github.ref_name }}
            git push origin HEAD:${{ github.ref_name }}
          fi

      - uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ inputs.app_key }}-v${{ github.run_number }}
          name: ${{ inputs.app_name }} (${{ github.run_number }})
          files: ${{ inputs.app_key }}.apk
''';

  // ---------------------------------------------------------------
  // tools/sign_apk.sh : توقيع ثابت (المفتاح مشفر في الريبو بكلمة KS_PASS)
  // ---------------------------------------------------------------
  static const signScript = r'''
#!/usr/bin/env bash
# usage: sign_apk.sh <input.apk> <output.apk> <keystore.enc>
set -euo pipefail
IN="$1"; OUT="$2"; ENC="$3"
: "${KS_PASS:?أضف Secret باسم KS_PASS في إعدادات الريبو}"

WORK="$(mktemp -d)"
KS="$WORK/release.keystore"

if [ -f "$ENC" ]; then
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -in "$ENC" -out "$KS" -pass env:KS_PASS
else
  keytool -genkeypair -keystore "$KS" -storepass "$KS_PASS" -keypass "$KS_PASS" \
    -alias aas -keyalg RSA -keysize 2048 -validity 36500 -dname "CN=AAS, O=AAS, C=SD"
  mkdir -p "$(dirname "$ENC")"
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -in "$KS" -out "$ENC" -pass env:KS_PASS
fi

BT="$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -1)"
"$BT/zipalign" -f -p 4 "$IN" "$WORK/aligned.apk"
"$BT/apksigner" sign --ks "$KS" --ks-key-alias aas \
  --ks-pass env:KS_PASS --key-pass env:KS_PASS \
  --out "$OUT" "$WORK/aligned.apk"
"$BT/apksigner" verify "$OUT"
rm -rf "$WORK"
''';

  // ---------------------------------------------------------------
  // tools/patch_android.py : صلاحيات + اسم + minSdk + أيقونة
  // ---------------------------------------------------------------
  static const patchScript = r'''
import os
import re
import subprocess
import sys

root = sys.argv[1] if len(sys.argv) > 1 else '.'
name = os.environ.get('APP_NAME', 'App')

# 1) AndroidManifest: صلاحيات + اسم التطبيق
manifest = os.path.join(root, 'android/app/src/main/AndroidManifest.xml')
s = open(manifest, encoding='utf-8').read()
label = (name.replace('&', '&amp;').replace('<', '&lt;')
             .replace('>', '&gt;').replace('"', '&quot;'))
perms = ''
for p in ('INTERNET', 'REQUEST_INSTALL_PACKAGES'):
    if 'android.permission.' + p not in s:
        perms += '    <uses-permission android:name="android.permission.%s"/>\n' % p
if perms:
    s = s.replace('<application', perms + '    <application', 1)
s = re.sub(r'android:label="[^"]*"', lambda m: 'android:label="%s"' % label, s, count=1)
open(manifest, 'w', encoding='utf-8').write(s)

# 2) minSdk = 23
for f in ('android/app/build.gradle', 'android/app/build.gradle.kts'):
    p = os.path.join(root, f)
    if os.path.exists(p):
        g = open(p, encoding='utf-8').read()
        g = re.sub(r'minSdk(?:Version)?\s*=?\s*flutter\.minSdkVersion', 'minSdk = 23', g)
        open(p, 'w', encoding='utf-8').write(g)

# 3) الأيقونة (لو في icon.png)
icon = os.path.join(root, 'icon.png')
if os.path.exists(icon):
    try:
        from PIL import Image
    except ImportError:
        subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--quiet',
                               '--break-system-packages', 'pillow'])
        from PIL import Image
    img = Image.open(icon).convert('RGBA')
    sizes = (('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192))
    for d, size in sizes:
        out = os.path.join(root, 'android/app/src/main/res/mipmap-' + d)
        os.makedirs(out, exist_ok=True)
        img.resize((size, size), Image.LANCZOS).save(os.path.join(out, 'ic_launcher.png'))
print('patched', root)
''';

  // ---------------------------------------------------------------
  // lib/update_gate.dart : بتتضاف لكل تطبيق مولّد
  // ---------------------------------------------------------------
  static const updateGate = r'''
import 'package:flutter/material.dart';
import 'package:ota_update/ota_update.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const int kBuildNumber = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);

class UpdateGate extends StatefulWidget {
  final String appKey;
  final Widget child;
  const UpdateGate({super.key, required this.appKey, required this.child});

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final row = await Supabase.instance.client
          .from('app_versions')
          .select()
          .eq('app_key', widget.appKey)
          .maybeSingle();
      if (row == null) return;
      final code = (row['version_code'] as num).toInt();
      if (code > kBuildNumber && mounted) {
        showDialog(
          context: context,
          builder: (_) => _UpdateDialog(
            url: row['apk_url'] as String,
            fileName: '${widget.appKey}.apk',
            notes: row['notes'] as String?,
          ),
        );
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _UpdateDialog extends StatefulWidget {
  final String url;
  final String fileName;
  final String? notes;
  const _UpdateDialog({required this.url, required this.fileName, this.notes});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _started = false;
  double? _p;
  String _status = '';

  void _start() {
    setState(() {
      _started = true;
      _status = 'جاري التنزيل...';
    });
    try {
      OtaUpdate()
          .execute(widget.url, destinationFilename: widget.fileName)
          .listen((e) {
        if (!mounted) return;
        final n = e.status.name;
        setState(() {
          if (n == 'DOWNLOADING') {
            final v = double.tryParse(e.value ?? '') ?? 0;
            _p = v / 100;
            _status = 'جاري التنزيل ${v.toStringAsFixed(0)}%';
          } else if (n == 'INSTALLING') {
            _p = null;
            _status = 'جاري التثبيت...';
          } else if (n.endsWith('ERROR')) {
            _p = null;
            _started = false;
            _status = 'تعذر التحديث ($n). حاول مرة أخرى.';
          }
        });
      }, onError: (_) {
        if (!mounted) return;
        setState(() {
          _started = false;
          _status = 'تعذر التنزيل. تأكد من الاتصال.';
        });
      });
    } catch (_) {
      setState(() {
        _started = false;
        _status = 'تعذر بدء التحديث.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('هذا التطبيق يحتاج تحديث'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.notes ?? 'يتوفر إصدار جديد من التطبيق.'),
          if (_started) ...[
            const SizedBox(height: 14),
            LinearProgressIndicator(value: _p),
          ],
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(_status),
          ],
        ],
      ),
      actions: [
        if (!_started)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('لاحقاً'),
          ),
        FilledButton(
          onPressed: _started ? null : _start,
          child: const Text('تحديث الآن'),
        ),
      ],
    );
  }
}
''';

  // ---------------------------------------------------------------
  // أدوات
  // ---------------------------------------------------------------
  static List<RepoFile> toolFiles() => [
        RepoFile.text('.github/workflows/build-app.yml', workflowApp),
        RepoFile.text('.github/workflows/build-apk.yml', workflowFactory),
        RepoFile.text('tools/sign_apk.sh', signScript),
        RepoFile.text('tools/patch_android.py', patchScript),
      ];

  static String _patchPubspec(String t) {
    if (t.contains('ota_update')) return t;
    return t.replaceFirst('  supabase_flutter: ^2.8.0',
        '  supabase_flutter: ^2.8.0\n  ota_update: ^6.0.0');
  }

  static String _patchMain(String t, String key) {
    if (t.contains('UpdateGate(')) return t;
    var r = t.replaceFirst("import 'app_home.dart';",
        "import 'app_home.dart';\nimport 'update_gate.dart';");
    r = r.replaceFirst('const AppHome()',
        "UpdateGate(appKey: '$key', child: const AppHome())");
    return r;
  }

  /// يجمع ملفات تطبيق من الذاكرة ويجهزها للرفع تحت apps/appN
  static Future<List<RepoFile>> collectApp(int i) async {
    final dir = 'app${i + 1}';
    final out = <RepoFile>[];
    for (final rel in await ProjectStore.list()) {
      if (!rel.startsWith('$dir/')) continue;
      var text = await ProjectStore.read(rel);
      if (text == null || text.isEmpty) continue;
      final sub = rel.substring(dir.length + 1);
      if (sub == 'pubspec.yaml') text = _patchPubspec(text);
      if (sub == 'lib/main.dart') text = _patchMain(text, dir);
      out.add(RepoFile.text('apps/$dir/$sub', text));
    }
    out.add(RepoFile.text('apps/$dir/lib/update_gate.dart', updateGate));
    final icon = await ProjectStore.readBytes('meta/${dir}_icon.png');
    if (icon != null) out.add(RepoFile.bytes('apps/$dir/icon.png', icon));
    return out;
  }

  static String apkUrl(String repo, String key, int run) =>
      'https://github.com/$repo/releases/download/$key-v$run/$key.apk';

  /// SQL ينشر رقم الإصدار الجديد (التطبيقات المثبتة بتقراه وتطلب التحديث)
  static String versionSql(String key, int code, String url, String notes) {
    String q(String s) => s.replaceAll("'", "''");
    return '''
create table if not exists public.app_versions (
  app_key text primary key,
  version_code int not null,
  apk_url text not null,
  notes text,
  updated_at timestamptz default now()
);
alter table public.app_versions enable row level security;
drop policy if exists "app_versions_read" on public.app_versions;
create policy "app_versions_read" on public.app_versions
  for select to anon, authenticated using (true);
insert into public.app_versions (app_key, version_code, apk_url, notes)
values ('${q(key)}', $code, '${q(url)}', '${q(notes)}')
on conflict (app_key) do update set
  version_code = excluded.version_code,
  apk_url = excluded.apk_url,
  notes = excluded.notes,
  updated_at = now();
''';
  }
}
