import 'ai_service.dart';

class PreviewService {
  static const languages = <String>[
    'HTML / CSS / JS',
    'React',
    'Flutter',
    'Kotlin',
    'Python',
    'PHP',
    'وصف فقط',
  ];

  static bool isDirect(String lang) =>
      lang == 'HTML / CSS / JS' || lang == 'React';

  static const _mockSystem = r'''
You convert a mobile app description or source code (Flutter, Kotlin, Python, PHP, React or plain text) into ONE self-contained HTML file that visually previews the app's main screens.

Rules:
- Output ONLY the HTML document. No markdown fences, no explanations.
- Inline CSS and JavaScript only. No external files, fonts, images or CDN links (use CSS shapes, emoji and inline SVG).
- Mobile layout: max-width 420px, centered, <html lang="ar" dir="rtl">, viewport meta tag.
- Modern luxurious look: dark navy background #0F1630, cards #1A2347, lime accent #C6F750, large rounded corners, generous spacing, soft shadows.
- Include a bottom navigation bar. Make the tabs and main buttons clickable with simple JavaScript to switch between 2 to 4 screens, with realistic sample data in Arabic.
- For Python or PHP or other code without a UI, render a clean terminal-style or API-response screen showing what the program would print or return for a sample input.
''';

  static String wrapHtml(String code) {
    if (code.toLowerCase().contains('<html')) return code;
    return '<!DOCTYPE html><html lang="ar" dir="rtl"><head>'
        '<meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '</head><body>$code</body></html>';
  }

  static const _reactTpl = r'''<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{margin:0;font-family:system-ui,sans-serif}</style>
<script src="https://cdnjs.cloudflare.com/ajax/libs/react/18.3.1/umd/react.production.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/react-dom/18.3.1/umd/react-dom.production.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/babel-standalone/7.24.7/babel.min.js"></script>
</head>
<body>
<div id="root"></div>
<script>
window.useState=React.useState;window.useEffect=React.useEffect;window.useRef=React.useRef;
window.useMemo=React.useMemo;window.useCallback=React.useCallback;window.useReducer=React.useReducer;
window.useContext=React.useContext;window.createContext=React.createContext;
window.addEventListener('error',function(e){document.body.insertAdjacentHTML('beforeend','<pre style="color:#f66;white-space:pre-wrap;padding:12px">'+e.message+'</pre>');});
</script>
<script type="text/babel">
__CODE__
const __C = (typeof __NAME__ !== 'undefined') ? __NAME__ : function(){ return 'لم أجد مكوّن React باسم __NAME__'; };
ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(__C));
</script>
</body>
</html>''';

  static String wrapReact(String code) {
    final m1 = RegExp(r'export\s+default\s+(?:function|class)\s+(\w+)')
        .firstMatch(code);
    final m2 = RegExp(r'export\s+default\s+(\w+)\s*;?\s*$', multiLine: true)
        .firstMatch(code);
    final name = m1?.group(1) ?? m2?.group(1) ?? 'App';

    final c = code
        .replaceAll(RegExp(r'''import[\s\S]*?from\s+['"][^'"]+['"];?'''), '')
        .replaceAll(RegExp(r'''import\s+['"][^'"]+['"];?'''), '')
        .replaceAll(
            RegExp(r'export\s+default\s+(\w+)\s*;?\s*$', multiLine: true), '')
        .replaceAll(RegExp(r'export\s+default\s+(?=function|class)'), '')
        .replaceAll(RegExp(r'export\s+default\s+'), 'const App = ')
        .replaceAll(RegExp(r'export\s+(?=const|function|class)'), '');

    return _reactTpl.replaceAll('__NAME__', name).replaceAll('__CODE__', c);
  }

  static String _extractHtml(String raw) {
    var t = raw
        .replaceAll(RegExp(r'^```[a-zA-Z]*[ \t]*\r?\n?', multiLine: true), '')
        .trim();
    final low = t.toLowerCase();
    final i = low.indexOf('<!doctype');
    final j = low.indexOf('<html');
    final s = i >= 0 ? i : j;
    if (s > 0) t = t.substring(s);
    return t;
  }

  static Future<String> aiHtml(String language, String text) async {
    final raw = await AiService.ask(
      _mockSystem,
      [ChatTurn(true, 'Source type: $language\n\n$text')],
      json: false,
      maxTokens: 12000,
    );
    final html = _extractHtml(raw);
    if (!html.toLowerCase().contains('<')) {
      throw Exception('الذكاء الاصطناعي ما رجّع HTML صالح. حاول مرة أخرى.');
    }
    return html;
  }

  static Future<String> build(String language, String text) async {
    if (language == 'HTML / CSS / JS') return wrapHtml(text);
    if (language == 'React') return wrapReact(text);
    return aiHtml(language, text);
  }
}
