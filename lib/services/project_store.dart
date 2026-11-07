import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

class ProjectStore {
  static Future<Directory> root() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/aas_project');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<void> write(String relPath, String content) async {
    final d = await root();
    final f = File('${d.path}/$relPath');
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
  }

  static Future<void> writeBytes(String relPath, Uint8List bytes) async {
    final d = await root();
    final f = File('${d.path}/$relPath');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
  }

  static Future<String?> read(String relPath) async {
    final d = await root();
    final f = File('${d.path}/$relPath');
    if (!await f.exists()) return null;
    return f.readAsString();
  }

  static Future<Uint8List?> readBytes(String relPath) async {
    final d = await root();
    final f = File('${d.path}/$relPath');
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  /// يحذف ملف أو فولدر
  static Future<void> remove(String rel) async {
    final d = await root();
    final p = '${d.path}/$rel';
    if (await FileSystemEntity.isDirectory(p)) {
      await Directory(p).delete(recursive: true);
    } else if (await FileSystemEntity.isFile(p)) {
      await File(p).delete();
    }
  }

  static Future<List<String>> list() async {
    final d = await root();
    final out = <String>[];
    await for (final e in d.list(recursive: true)) {
      if (e is File) out.add(e.path.substring(d.path.length + 1));
    }
    out.sort();
    return out;
  }
}
