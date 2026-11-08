import 'dart:io';
import 'package:open_filex/open_filex.dart';

// ignore_for_file: constant_identifier_names
enum OtaStatus {
  DOWNLOADING,
  INSTALLING,
  DOWNLOAD_ERROR,
  INTERNAL_ERROR,
}

class OtaEvent {
  final OtaStatus status;
  final String? value;
  OtaEvent(this.status, this.value);
}

class OtaUpdate {
  /// ينزّل الملف ويفتح مثبّت أندرويد. value أثناء التنزيل = النسبة (0 إلى 100).
  Stream<OtaEvent> execute(String url, {String? destinationFilename}) async* {
    final file = File(
        '${Directory.systemTemp.path}/${destinationFilename ?? 'update.apk'}');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);

    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) {
        yield OtaEvent(OtaStatus.DOWNLOAD_ERROR, 'HTTP ${res.statusCode}');
        return;
      }
      final sink = file.openWrite();
      final total = res.contentLength;
      var got = 0;
      var last = -1;
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) {
          final p = got * 100 ~/ total;
          if (p != last) {
            last = p;
            yield OtaEvent(OtaStatus.DOWNLOADING, '$p');
          }
        }
      }
      await sink.close();
    } catch (e) {
      yield OtaEvent(OtaStatus.DOWNLOAD_ERROR, '$e');
      return;
    } finally {
      client.close();
    }

    yield OtaEvent(OtaStatus.INSTALLING, null);
    try {
      final r = await OpenFilex.open(
        file.path,
        type: 'application/vnd.android.package-archive',
      );
      if (r.type != ResultType.done) {
        yield OtaEvent(OtaStatus.INTERNAL_ERROR, r.message);
      }
    } catch (e) {
      yield OtaEvent(OtaStatus.INTERNAL_ERROR, '$e');
    }
  }
}
