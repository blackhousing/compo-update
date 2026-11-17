import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Pengganti MainActivity.kt untuk desktop Linux.
/// Menjalankan `yt-dlp` (dan `ffmpeg` untuk konversi/gabung video) yang terpasang
/// di sistem lewat Process. Nama method & argumennya sama dengan channel Android.
class LinuxYt {
  LinuxYt(this.onProgress);

  /// Dipanggil tiap ada kemajuan unduhan: (id lagu, persen 0..100).
  final void Function(String id, double percent) onProgress;

  static const _clients = ['default', 'android_vr', 'tv', 'mweb'];
  static const _videoFormat =
      'bv*[height<=480][ext=mp4]+ba[ext=m4a]/b[height<=480][ext=mp4]/18';

  // App yang dibuka dari menu/.deb tidak mewarisi PATH terminal, jadi yt-dlp
  // (pip --user -> ~/.local/bin) dan deno (~/.deno/bin) tidak ketemu. Cari manual.
  static final String _home = Platform.environment['HOME'] ?? '';
  static List<String> get _extraDirs => [
    '$_home/.local/bin',
    '$_home/.deno/bin',
    '$_home/bin',
    '/usr/local/bin',
    '/usr/bin',
    '/snap/bin',
  ];

  static Map<String, String> get _env => {
    'PATH':
        '${_extraDirs.join(':')}:${Platform.environment['PATH'] ?? '/usr/bin:/bin'}',
  };

  static String? _resolved;
  static String _bin() {
    final r = _resolved;
    if (r != null && File(r).existsSync()) return r;
    final dirs = [
      ..._extraDirs,
      ...(Platform.environment['PATH'] ?? '').split(':'),
    ];
    for (final d in dirs) {
      if (d.isEmpty) continue;
      final f = File('$d/yt-dlp');
      if (f.existsSync()) return _resolved = f.path;
    }
    return 'yt-dlp';
  }

  String? _lastGood;
  final Map<String, Process> _procs = {};
  final Set<String> _cancelled = {};

  Future<dynamic> call(String method, Map<String, dynamic> a) async {
    switch (method) {
      case 'init':
        return _init();
      case 'update':
        return _update();
      case 'search':
        return _search(
          a['query'] as String,
          (a['count'] as int?) ?? 12,
          (a['start'] as int?) ?? 1,
        );
      case 'download':
        return _download(
          a['url'] as String,
          a['dir'] as String,
          a['id'] as String,
          a['format'] as String?,
        );
      case 'streamUrl':
        return _streamUrl(a['url'] as String);
      case 'export':
        return _export(a['path'] as String, a['name'] as String);
      case 'installApk':
        return true;
      case 'cancel':
        final id = a['id'] as String;
        _cancelled.add(id);
        _procs[id]?.kill();
        return null;
      default:
        throw MissingPluginException('Tidak ada method $method');
    }
  }

  // ───────── Inti: jalankan yt-dlp dengan fallback client ─────────

  List<String> _ordered() {
    final g = _lastGood;
    return (g != null && _clients.contains(g))
        ? [g, ..._clients.where((c) => c != g)]
        : _clients;
  }

  Future<String> _run(List<String> base, {String? id}) async {
    final errors = <String>[];
    final pct = RegExp(r'\[download\]\s+([\d.]+)%');
    for (final c in _ordered()) {
      if (id != null && _cancelled.contains(id)) {
        throw Exception('Dibatalkan');
      }
      final args = <String>[
        ...base,
        if (c != 'default') ...['--extractor-args', 'youtube:player_client=$c'],
        '--socket-timeout',
        '15',
        '--retries',
        '2',
        '--newline',
      ];
      Process p;
      try {
        p = await Process.start(_bin(), args, environment: _env);
      } on ProcessException {
        throw Exception(
          'yt-dlp tidak ditemukan. Pasang: pip install -U yt-dlp '
          '(atau unduh binary dari GitHub yt-dlp).',
        );
      }
      if (id != null) _procs[id] = p;
      final out = StringBuffer();
      final err = StringBuffer();
      final f1 = p.stdout.transform(utf8.decoder).forEach((chunk) {
        out.write(chunk);
        if (id != null) {
          final ms = pct.allMatches(chunk);
          if (ms.isNotEmpty) {
            final v = double.tryParse(ms.last.group(1)!);
            if (v != null) onProgress(id, v);
          }
        }
      });
      final f2 = p.stderr.transform(utf8.decoder).forEach(err.write);
      final code = await p.exitCode;
      await Future.wait([f1, f2]);
      if (id != null) _procs.remove(id);

      if (code == 0) {
        _lastGood = c;
        return out.toString();
      }
      if (id != null && _cancelled.contains(id)) {
        throw Exception('Dibatalkan');
      }
      errors.add('[$c] ${_short(err.toString())}');
    }
    throw Exception(_explain(errors));
  }

  String _short(String m) {
    final lines = m.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final s = lines.lastWhere(
      (l) => l.contains('ERROR'),
      orElse: () => lines.isEmpty ? 'tidak ada pesan' : lines.last,
    );
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }

  String _explain(List<String> errors) {
    final all = errors.join('\n');
    final low = all.toLowerCase();
    final hint = low.contains('not a bot') || low.contains('sign in')
        ? 'IP kena flag bot. Pakai proxy/WARP atau cookies.'
        : all.contains('429')
        ? 'HTTP 429: terlalu banyak request, tunggu atau ganti IP.'
        : all.contains('403')
        ? 'HTTP 403: ditolak YouTube (IP/client).'
        : (low.contains('not available') ||
              low.contains('challenge') ||
              low.contains('javascript') ||
              low.contains('js runtime'))
        ? 'Format/JS challenge gagal. Update yt-dlp dan pasang runtime JS (deno atau nodejs).'
        : 'Gagal, semua client sudah dicoba.';
    return '$hint\n$all';
  }

  // ───────── Operasi ─────────

  Future<bool> _init() async {
    try {
      final r = await Process.run(_bin(), ['--version'], environment: _env);
      if (r.exitCode != 0) {
        throw Exception('yt-dlp error (${_bin()}): ${r.stderr}');
      }
    } on ProcessException {
      throw Exception(
        'yt-dlp tidak ditemukan. Pasang: pip install -U yt-dlp '
        '(atau unduh binary dari GitHub yt-dlp).',
      );
    }
    return true;
  }

  Future<String> _update() async {
    try {
      final r = await Process.run(_bin(), ['-U'], environment: _env);
      final lines = '${r.stdout}\n${r.stderr}'
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      final last = lines.isEmpty ? 'selesai' : lines.last.trim();
      return last.toLowerCase().contains('updated') ? 'DONE: $last' : last;
    } on ProcessException {
      throw Exception('yt-dlp tidak ditemukan');
    }
  }

  Future<String> _search(String query, int count, int start) => _run([
    'ytsearch$count:$query',
    if (start > 1) ...['--playlist-items', '$start-$count'],
    '--flat-playlist',
    '--dump-single-json',
    '--no-warnings',
  ]);

  Future<String> _streamUrl(String url) async => (await _run([
    url,
    '--no-playlist',
    '-f',
    'ba[ext=webm]/ba',
    '-g',
    '--no-warnings',
  ])).trim();

  Future<String> _download(
    String url,
    String dir,
    String id,
    String? format,
  ) async {
    await Directory(dir).create(recursive: true);
    _cancelled.remove(id);
    final video = format == 'video';
    final conv = !video && format != null && format != 'original';
    await _run([
      url,
      '--no-playlist',
      if (video) ...[
        '-f',
        _videoFormat,
        '--merge-output-format',
        'mp4',
      ] else ...[
        '-f',
        'ba[ext=webm]/ba',
      ],
      '-o',
      '$dir/%(title).100B [%(id)s].%(ext)s',
      if (conv) ...[
        '-x',
        '--audio-format',
        format!,
        if (format == 'mp3') ...['--audio-quality', '0'],
      ],
    ], id: id);

    final files = Directory(dir)
        .listSync()
        .whereType<File>()
        .where(
          (f) =>
              f.path.contains('[$id]') &&
              !f.path.endsWith('.part') &&
              !f.path.endsWith('.ytdl'),
        )
        .toList();
    if (files.isEmpty) throw Exception('File hasil tidak ditemukan');
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files.first.path;
  }

  /// Linux tidak punya scoped storage: salin langsung ke ~/Music/Compo.
  Future<String> _export(String path, String name) async {
    final home = Platform.environment['HOME'] ?? '.';
    final d = Directory('$home/Music/Compo');
    await d.create(recursive: true);
    await File(path).copy('${d.path}/$name');
    return 'OK';
  }
}
