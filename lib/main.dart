import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';

import 'linux_ytdlp.dart';

// Jembatan ke Kotlin (MainActivity.kt) yang menjalankan yt-dlp di dalam app.
const _ch = MethodChannel('yt_audio/ytdlp');

// ── Android: lewat Kotlin (MethodChannel). Linux: lewat Process (LinuxYt). ──
LinuxYt? _linux;

Future<T?> _native<T>(String method, [Map<String, dynamic>? args]) {
  final l = _linux;
  if (l != null) return l.call(method, args ?? {}).then((v) => v as T?);
  return _ch.invokeMethod<T>(method, args);
}

/// Folder data app. Di Linux jangan pakai ~/Documents; pakai folder data app.
Future<Directory> appBase() => Platform.isLinux
    ? getApplicationSupportDirectory()
    : getApplicationDocumentsDirectory();

/// Folder cache sementara (unduhan untuk diputar).
Future<Directory> cacheBase() =>
    Platform.isLinux ? getApplicationCacheDirectory() : getTemporaryDirectory();

// ── Saklar fitur (nyalakan satu per satu untuk mencari penyebab macet) ──
// Default = sama seperti versi awal yang sudah terbukti bisa memutar.
const kEnableEq =
    true; // equalizer + tone control (AndroidEqualizer di audio pipeline)
const kStream =
    false; // streaming langsung (butuh method 'streamUrl' di Kotlin)

const _bg = Color(0xFF0E0E12);
const _card = Color(0xFF16161C);
const _panel = Color(0xFF22222B);

// ───────────────────────── Model ─────────────────────────

class Track {
  final String id;
  final String title;
  final String channel;
  final int? seconds;
  Track(this.id, this.title, this.channel, this.seconds);

  factory Track.fromJson(Map<String, dynamic> j) => Track(
    j['id'] as String,
    (j['title'] ?? j['id']) as String,
    (j['channel'] ?? '') as String,
    (j['seconds'] as num?)?.toInt(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'channel': channel,
    'seconds': seconds,
  };

  String get thumb => 'https://i.ytimg.com/vi/$id/mqdefault.jpg';
  String get url => 'https://www.youtube.com/watch?v=$id';
}

/// Playlist buatan user (disimpan di playlists.json).
class Playlist {
  final String id;
  String name;
  final List<Track> tracks;
  Playlist(this.id, this.name, [List<Track>? tracks]) : tracks = tracks ?? [];

  factory Playlist.fromJson(Map<String, dynamic> j) =>
      Playlist(j['id'] as String, (j['name'] ?? 'Playlist') as String, [
        for (final t in (j['tracks'] as List? ?? []))
          Track.fromJson(Map<String, dynamic>.from(t as Map)),
      ]);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'tracks': tracks.map((t) => t.toJson()).toList(),
  };
}

/// Satu item di antrian (bisa dari hasil pencarian atau file tersimpan).
class QItem {
  final String id;
  final String title;
  final String artist;
  final String? thumb;
  final Track? track;
  final File? file;
  QItem({
    required this.id,
    required this.title,
    required this.artist,
    this.thumb,
    this.track,
    this.file,
  });

  factory QItem.fromTrack(Track t) => QItem(
    id: t.id,
    title: t.title,
    artist: t.channel,
    thumb: t.thumb,
    track: t,
  );

  factory QItem.fromFile(File f) {
    final vid = videoIdOf(f);
    return QItem(
      id: vid ?? f.path,
      title: labelOf(f),
      artist: 'Tersimpan',
      thumb: vid == null ? null : 'https://i.ytimg.com/vi/$vid/mqdefault.jpg',
      file: f,
    );
  }
}

String _fileName(File f) => f.path.split(Platform.pathSeparator).last;

String labelOf(File f) =>
    _fileName(f).replaceFirst(RegExp(r'\s*\[[^\]]*\]\.\w+$'), '');

String? videoIdOf(File f) =>
    RegExp(r'\[([^\[\]]+)\]\.\w+$').firstMatch(_fileName(f))?.group(1);

String fmtDur(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

Widget artImage(String? url, {double? size, double radius = 8}) {
  final fallback = Container(
    width: size,
    height: size,
    color: const Color(0xFF26262E),
    child: const Icon(Icons.music_note_rounded, color: Colors.white38),
  );
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: url == null
        ? fallback
        : Image.network(
            url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback,
          ),
  );
}

// ───────────────────── Audio handler (notifikasi & tombol media) ─────────────────────

/// Pemegang AudioPlayer + jembatan ke Android: notifikasi, lockscreen, dan
/// tombol earphone/TWS. Next/prev dilempar balik ke antrian di Home.
class YtAudioHandler extends BaseAudioHandler with SeekHandler {
  final AndroidEqualizer eq = AndroidEqualizer();
  late final AudioPlayer player = AudioPlayer(
    audioPipeline: kEnableEq ? AudioPipeline(androidAudioEffects: [eq]) : null,
  );

  VoidCallback? onNext;
  VoidCallback? onPrev;

  YtAudioHandler() {
    player.playbackEventStream.listen(
      (_) => _broadcast(),
      onError: (Object e, StackTrace st) => debugPrint('[YT] playback: $e'),
    );
    player.playingStream.listen((_) => _broadcast());
    player.durationStream.listen((d) {
      final m = mediaItem.value;
      if (m != null && d != null && m.duration != d) {
        mediaItem.add(m.copyWith(duration: d));
      }
    });
  }

  bool _loading = false;
  MediaItem? _base;

  /// Status "memuat" di notifikasi/lockscreen (sinkron dengan loading di app).
  void setLoading(bool v) {
    if (_loading == v) return;
    _loading = v;
    _broadcast();
  }

  /// Ganti lagu yang tampil di notifikasi.
  void setTrack(MediaItem item) {
    _base = item;
    mediaItem.add(item);
  }

  /// Teks tahap pemuatan; tampil di baris artis notifikasi selama memuat.
  void setStatus(String text) {
    final b = _base;
    if (b == null) return;
    final d = mediaItem.value?.id == b.id
        ? mediaItem.value?.duration
        : b.duration;
    mediaItem.add(
      b.copyWith(artist: text.isEmpty ? b.artist : text, duration: d),
    );
  }

  void _broadcast() {
    final playing = player.playing;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          // Tombol tutup (X) di panel notifikasi -> stop() -> app ditutup.
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
          MediaAction.stop,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: _loading
            ? AudioProcessingState.loading
            : const {
                ProcessingState.idle: AudioProcessingState.idle,
                ProcessingState.loading: AudioProcessingState.loading,
                ProcessingState.buffering: AudioProcessingState.buffering,
                ProcessingState.ready: AudioProcessingState.ready,
                ProcessingState.completed: AudioProcessingState.completed,
              }[player.processingState]!,
        playing: playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
      ),
    );
  }

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  /// Dipanggil dari tombol X di notifikasi/lockscreen: hentikan musik,
  /// hapus notifikasi, lalu tutup aplikasi sepenuhnya.
  @override
  Future<void> stop() async {
    try {
      await player.stop();
    } catch (_) {}
    try {
      await super.stop(); // menghentikan service & menghapus notifikasi
    } catch (_) {}
    try {
      await SystemNavigator.pop(); // tutup activity
    } catch (_) {}
    // Beri waktu sebentar agar notifikasi benar-benar hilang, lalu matikan proses.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    exit(0);
  }

  Timer? _clickTimer;
  int _clicks = 0;

  // Tombol earphone (HEADSETHOOK): 1x = play/pause, 2x = next, 3x = prev.
  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    if (button != MediaButton.media) return super.click(button);
    _clicks++;
    _clickTimer?.cancel();
    _clickTimer = Timer(const Duration(milliseconds: 450), () {
      final n = _clicks;
      _clicks = 0;
      debugPrint('[YT] klik earphone: $n');
      if (n == 1) {
        player.playing ? pause() : play();
      } else if (n == 2) {
        onNext?.call();
      } else if (n >= 3) {
        onPrev?.call();
      }
    });
  }

  // Tombol next/prev di notifikasi, lockscreen, dan earphone/TWS.
  @override
  Future<void> skipToNext() async => onNext?.call();

  @override
  Future<void> skipToPrevious() async => onPrev?.call();
}

late YtAudioHandler _handler;

// ───────────────────────── App ─────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isLinux) {
    // Linux: pemutar lewat libmpv; tanpa audio_service (notifikasi Android).
    JustAudioMediaKit.ensureInitialized(
      linux: true,
      windows: false,
      android: false,
      iOS: false,
      macOS: false,
    );
    _handler = YtAudioHandler();
  } else {
    _handler = await AudioService.init(
      builder: () => YtAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.yt_audio.channel.audio',
        androidNotificationChannelName: 'Pemutaran audio',
        androidNotificationOngoing: true,
      ),
    );
    // Android 13+: tanpa izin ini notifikasi player tidak tampil.
    try {
      final st = await Permission.notification.request();
      debugPrint('[YT] izin notifikasi: $st');
    } catch (e) {
      debugPrint('[YT] izin notifikasi gagal: $e');
    }
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: Colors.redAccent,
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'Compo.',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: _bg,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: _card,
          indicatorColor: scheme.primary.withAlpha(60),
          height: 68,
          labelTextStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        sliderTheme: const SliderThemeData(
          trackHeight: 3,
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
        ),
      ),
      home: const SplashGate(),
    );
  }
}

// ───────────────────────── Splash (logo + branding) ─────────────────────────

/// Splash dari sisi Flutter: logo + teks branding ~2 detik, lalu memudar ke Home.
/// (Android 12+ hanya menampilkan ikon di splash native, jadi teks ditampilkan di sini.)
/// Home dibangun di bawah splash, jadi yt-dlp & init lain jalan selama splash tampil.
class SplashGate extends StatefulWidget {
  const SplashGate({super.key});

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  bool _done = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Home(),
        IgnorePointer(
          ignoring: _done,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: _done
                ? const SizedBox.expand(key: ValueKey('gone'))
                : Container(
                    key: const ValueKey('splash'),
                    color: _bg,
                    width: double.infinity,
                    height: double.infinity,
                    child: SafeArea(
                      child: Center(
                        child: Image.asset(
                          'assets/icon/splash_branding.png',
                          width: 280,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  // Equalizer harus dibuat sebelum player & dimasukkan ke audio pipeline.
  AndroidEqualizer get _eq => _handler.eq;
  AudioPlayer get _player => _handler.player;
  final _q = TextEditingController();
  StreamSubscription<ProcessingState>? _sub;

  // VU meter (level audio untuk pemutar layar penuh)
  final _vu = VuService();
  StreamSubscription<int?>? _sessSub;
  StreamSubscription<bool>? _playSub;

  int _tab = 0;
  bool _loading = false;
  bool _ready = false;
  bool _updating = false;
  bool _checkingOta = false;
  bool _full = false; // layar pemutar penuh
  bool _repeat = false; // ulangi antrian
  String? _error;
  List<Track> _results = [];
  List<File> _saved = [];
  final Map<String, double> _dl = {}; // id -> progress 0..1 (0 = belum mulai)

  // Pencarian bertahap (infinite scroll)
  final _scroll = ScrollController();
  String _lastQuery = '';
  int _nextStart = 1; // nomor hasil berikutnya yang mau diambil
  bool _loadingMore = false;
  bool _hasMore = true;
  static const _pageSize = 15;

  // Playlist
  List<Playlist> _playlists = [];
  String? _plOpen; // id playlist yang sedang dibuka (null = daftar playlist)

  // Mode pemutaran: false = audio saja, true = audio + video.
  // Audio tetap dipegang just_audio (notifikasi/background jalan); video_player
  // hanya menampilkan gambar (volume 0) yang disinkronkan ke posisi audio.
  bool _videoMode = false;
  VideoPlayerController? _vc;
  Timer? _syncTimer;

  // Format file saat menyimpan (tombol unduh). Memutar tetap pakai format asli.
  String _fmtSave = 'original';
  static const _formats = <String, String>{
    'original': 'Asli (tanpa konversi)',
    'opus': 'Opus',
    'mp3': 'MP3',
    'flac': 'FLAC',
    'wav': 'WAV',
  };

  // Antrian pemutaran
  List<QItem> _queue = [];
  int _index = -1;
  int _gen = 0; // untuk membatalkan pemutaran lama kalau user ganti lagu cepat
  final Map<String, Future<File>> _inflight = {};
  final Set<String> _cancellable =
      {}; // id yang sedang diunduh untuk diputar/prefetch
  final Map<String, String> _urlCache =
      {}; // id -> direct audio url (streaming)
  bool _streamOk = true; // false kalau Kotlin belum punya method 'streamUrl'
  String? _loadingId; // lagu yang sedang dimuat untuk diputar
  String _status = ''; // tahap pemutaran (layar + notifikasi)
  String _stBase = ''; // teks tahap tanpa persen
  int _lastPct = -10; // persen terakhir yang dikirim ke notifikasi

  QItem? get _cur =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;

  @override
  void initState() {
    super.initState();
    if (Platform.isLinux) {
      _linux = LinuxYt(
        (id, p) => _onNative(MethodCall('progress', {'id': id, 'progress': p})),
      );
    }
    _ch.setMethodCallHandler(_onNative);
    _handler.onNext = () => _next();
    _handler.onPrev = _prev;
    _scroll.addListener(_onScroll);
    _loadFormat();
    _loadSearch();
    _loadPlayMode();
    _loadPlaylists();
    EqualizerSheet.load(_eq);
    OtaService.initVersion();
    // Auto play next: saat lagu selesai, lanjut ke lagu berikutnya.
    _sub = _player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) _next(auto: true);
    });
    _initEngine();
    // VU meter: ikuti audio session player & status play/pause.
    _sessSub = _player.androidAudioSessionIdStream.listen(_vu.attach);
    _playSub = _player.playingStream.listen(_vu.setPlaying);
    _migrateOld().then((_) => _loadSaved());
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) _checkOtaUpdate(manual: false);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sessSub?.cancel();
    _playSub?.cancel();
    _vu.dispose();
    _syncTimer?.cancel();
    _vc?.dispose();
    _scroll.dispose();
    _handler.onNext = null;
    _handler.onPrev = null;
    _q.dispose();
    super.dispose();
  }

  // ───────── Native bridge ─────────

  Future<dynamic> _onNative(MethodCall call) async {
    if (call.method == 'progress') {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final id = args['id'] as String;
      final p = ((args['progress'] as num).toDouble() / 100).clamp(0.0, 1.0);
      if (mounted && _dl.containsKey(id)) setState(() => _dl[id] = p);
      // Persen unduhan ikut tampil di mini player & notifikasi (hemat update).
      if (id == _loadingId && _stBase.startsWith('Mengunduh')) {
        final pct = (p * 100).round();
        if (pct - _lastPct >= 3 || pct == 100) {
          _lastPct = pct;
          _pushStatus('$_stBase $pct%');
        }
      }
    }
  }

  Future<void> _initEngine() async {
    try {
      await _native('init');
      debugPrint('[YT] yt-dlp siap');
      if (mounted) {
        setState(() => _ready = true);
      }
      _update(auto: true); // otomatis, maksimal sekali per 24 jam
    } catch (e) {
      debugPrint('[YT] init gagal: $e');
      if (mounted) setState(() => _error = 'Gagal menyiapkan yt-dlp: $e');
    }
  }

  /// Update yt-dlp. [auto] = dijalankan otomatis saat app dibuka: dibatasi
  /// sekali per 24 jam dan diam-diam (snackbar hanya kalau benar-benar terupdate).
  Future<void> _update({bool auto = false}) async {
    if (_updating) return;
    final base = await appBase();
    final stamp = File('${base.path}/last_update.txt');
    final now = DateTime.now().millisecondsSinceEpoch;
    if (auto) {
      try {
        final last = stamp.existsSync()
            ? int.tryParse(stamp.readAsStringSync().trim()) ?? 0
            : 0;
        if (now - last < const Duration(hours: 24).inMilliseconds) return;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _updating = true);
    try {
      final r = await _native<String>('update') ?? '';
      try {
        await stamp.writeAsString('$now'); // hanya dicatat kalau berhasil
      } catch (_) {}
      final updated = r.toUpperCase().contains('DONE');
      if (!auto) {
        _snack('Update yt-dlp: $r');
      } else if (updated) {
        _snack('yt-dlp diperbarui otomatis');
      }
      debugPrint('[YT] update (auto=$auto): $r');
    } catch (e) {
      debugPrint('[YT] update gagal (auto=$auto): $e');
      if (!auto) _snack('Update gagal: $e');
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  /// Toast cantik. Ikon & warna dipilih otomatis dari isi pesan:
  /// gagal/error = merah, tersimpan/ditambahkan = hijau, lainnya = warna tema.
  void _snack(String m, {IconData? icon, Color? color}) {
    if (!mounted) return;
    final low = m.toLowerCase();
    final err = low.contains('gagal') || low.contains('error');
    final ok =
        low.contains('tersimpan') ||
        low.contains('ditambahkan') ||
        low.contains('dibuat') ||
        low.contains('diperbarui') ||
        low.contains('disalin') ||
        low.contains('diacak');
    final c =
        color ??
        (err
            ? const Color(0xFFFF5C6C)
            : ok
            ? const Color(0xFF3DDC97)
            : Theme.of(context).colorScheme.primary);
    final ic =
        icon ??
        (err
            ? Icons.error_rounded
            : ok
            ? Icons.check_circle_rounded
            : Icons.info_rounded);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.transparent,
          elevation: 0,
          padding: EdgeInsets.zero,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          duration: const Duration(milliseconds: 2600),
          content: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.withAlpha(90)),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black54,
                  blurRadius: 16,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: c.withAlpha(40),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(ic, color: c, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    m,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
  }

  String _fmt(int? s) => s == null ? 'LIVE' : fmtDur(Duration(seconds: s));

  // ───────── Penyimpanan (internal storage app) ─────────

  Future<File> _fmtFile() async {
    final base = await appBase();
    return File('${base.path}/save_format.txt');
  }

  Future<void> _loadFormat() async {
    try {
      final f = await _fmtFile();
      if (!await f.exists()) return;
      final v = (await f.readAsString()).trim();
      if (_formats.containsKey(v) && mounted) setState(() => _fmtSave = v);
    } catch (_) {}
  }

  Future<File> _modeFile() async {
    final base = await appBase();
    return File('${base.path}/play_mode.txt');
  }

  Future<void> _loadPlayMode() async {
    if (Platform.isLinux) return;
    try {
      final f = await _modeFile();
      if (!await f.exists()) return;
      final v = (await f.readAsString()).trim() == 'video';
      if (mounted) setState(() => _videoMode = v);
    } catch (_) {}
  }

  Future<void> _setVideoMode(bool v) async {
    if (Platform.isLinux && v) {
      _snack('Mode video belum didukung di Linux');
      return;
    }
    setState(() => _videoMode = v);
    try {
      await (await _modeFile()).writeAsString(v ? 'video' : 'audio');
    } catch (_) {}
    _snack(
      v ? 'Mode video: diputar dengan gambar' : 'Mode audio saja',
      icon: v ? Icons.videocam_rounded : Icons.headphones_rounded,
    );
    // Lagu yang sedang jalan dimuat ulang dengan mode baru, posisi dipertahankan.
    if (_cur != null) {
      _playIndex(_index, resume: _player.position);
    }
  }

  // ───────── Playlist: simpan & aksi ─────────

  Future<File> _plFile() async {
    final base = await appBase();
    return File('${base.path}/playlists.json');
  }

  Future<void> _loadPlaylists() async {
    try {
      final f = await _plFile();
      if (!await f.exists()) return;
      final list = jsonDecode(await f.readAsString()) as List;
      final pls = [
        for (final p in list)
          Playlist.fromJson(Map<String, dynamic>.from(p as Map)),
      ];
      if (mounted) setState(() => _playlists = pls);
    } catch (e) {
      debugPrint('[YT] load playlist gagal: $e');
    }
  }

  Future<void> _savePlaylists() async {
    try {
      final data = jsonEncode(_playlists.map((p) => p.toJson()).toList());
      await (await _plFile()).writeAsString(data);
    } catch (e) {
      debugPrint('[YT] simpan playlist gagal: $e');
    }
  }

  Future<String?> _askName(String title, {String initial = ''}) async {
    final c = TextEditingController(text: initial);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Nama playlist'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    final n = r?.trim();
    return (n == null || n.isEmpty) ? null : n;
  }

  /// Buat playlist baru (opsional langsung diisi satu lagu).
  Future<void> _newPlaylist({Track? first}) async {
    final name = await _askName('Playlist baru');
    if (name == null || !mounted) return;
    final pl = Playlist(
      DateTime.now().microsecondsSinceEpoch.toString(),
      name,
      first == null ? null : [first],
    );
    setState(() => _playlists.add(pl));
    _savePlaylists();
    _snack(
      first == null ? 'Playlist "$name" dibuat' : 'Ditambahkan ke "$name"',
    );
  }

  Future<void> _addToPlaylist(Track t) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                'Tambah ke playlist',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('Playlist baru'),
              onTap: () => Navigator.pop(ctx, '__new__'),
            ),
            for (final p in _playlists)
              ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${p.tracks.length} lagu'),
                trailing: p.tracks.any((x) => x.id == t.id)
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(ctx, p.id),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == '__new__') {
      await _newPlaylist(first: t);
      return;
    }
    final p = _playlists.firstWhere((x) => x.id == choice);
    if (p.tracks.any((x) => x.id == t.id)) {
      _snack('Sudah ada di "${p.name}"');
      return;
    }
    setState(() => p.tracks.add(t));
    _savePlaylists();
    _snack('Ditambahkan ke "${p.name}"');
  }

  void _addFileToPlaylist(File f) {
    final vid = videoIdOf(f);
    if (vid == null) {
      _snack('File ini tidak punya ID video, tidak bisa masuk playlist');
      return;
    }
    _addToPlaylist(Track(vid, labelOf(f), '', null));
  }

  Future<void> _renamePlaylist(Playlist p) async {
    final name = await _askName('Ganti nama', initial: p.name);
    if (name == null || !mounted) return;
    setState(() => p.name = name);
    _savePlaylists();
  }

  Future<void> _deletePlaylist(Playlist p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hapus "${p.name}"?'),
        content: const Text(
          'Lagu di dalamnya tidak ikut terhapus dari penyimpanan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _playlists.removeWhere((x) => x.id == p.id);
      if (_plOpen == p.id) _plOpen = null;
    });
    _savePlaylists();
  }

  Future<File> _searchFile() async {
    final base = await appBase();
    return File('${base.path}/last_search.json');
  }

  /// Simpan query + hasil pencarian terakhir supaya muncul lagi saat app dibuka.
  Future<void> _saveSearch() async {
    try {
      final data = {
        'q': _lastQuery,
        'next': _nextStart,
        'hasMore': _hasMore,
        'results': [
          for (final t in _results)
            {
              'id': t.id,
              'title': t.title,
              'channel': t.channel,
              'seconds': t.seconds,
            },
        ],
      };
      await (await _searchFile()).writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  Future<void> _loadSearch() async {
    try {
      final f = await _searchFile();
      if (!await f.exists()) return;
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final list = [
        for (final e in (m['results'] as List? ?? []))
          Track(
            (e as Map)['id'] as String,
            e['title'] as String,
            e['channel'] as String,
            (e['seconds'] as num?)?.toInt(),
          ),
      ];
      if (!mounted || _results.isNotEmpty) return; // user sudah cari duluan
      setState(() {
        _lastQuery = (m['q'] as String?) ?? '';
        _q.text = _lastQuery;
        _results = list;
        _nextStart = (m['next'] as num?)?.toInt() ?? list.length + 1;
        _hasMore = (m['hasMore'] as bool?) ?? false;
      });
    } catch (_) {}
  }

  Future<void> _setFormat(String v) async {
    setState(() => _fmtSave = v);
    try {
      await (await _fmtFile()).writeAsString(v);
    } catch (_) {}
    _snack('Format simpan: ${_formats[v]}');
  }

  /// Folder penyimpanan internal app (privat, tidak butuh izin storage).
  Future<Directory> _dir() async {
    final base = await appBase();
    final d = Directory('${base.path}/audio');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Pindahkan file lama dari external app-storage ke internal storage.
  Future<void> _migrateOld() async {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext == null) return;
      final old = Directory('${ext.path}/audio');
      if (!await old.exists()) return;
      final dst = await _dir();
      for (final f in old.listSync().whereType<File>()) {
        final name = _fileName(f);
        if (name.endsWith('.part') || name.endsWith('.ytdl')) continue;
        try {
          await f.copy('${dst.path}/$name');
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _loadSaved() async {
    final d = await _dir();
    final files =
        d
            .listSync()
            .whereType<File>()
            .where(
              (f) => !f.path.endsWith('.part') && !f.path.endsWith('.ytdl'),
            )
            .toList()
          ..sort(
            (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
          );
    if (mounted) setState(() => _saved = files);
  }

  /// Salin file ke folder Music/Compo di penyimpanan HP (terlihat di file
  /// manager & app musik). Lewat MediaStore (method native 'export' di Kotlin)
  /// karena Android 10+ melarang File.copy langsung ke /storage/emulated/0.
  Future<void> _export(File f) async {
    try {
      await _native('export', {'path': f.path, 'name': _fileName(f)});
      _snack('Disalin ke Music/Compo');
    } catch (e) {
      debugPrint('[YT] export gagal: $e');
      _snack('Gagal ekspor: $e');
    }
  }

  File? _findFile(Directory d, String id) {
    if (!d.existsSync()) return null;
    for (final e in d.listSync()) {
      if (e is File &&
          e.path.contains('[$id]') &&
          !e.path.endsWith('.part') &&
          !e.path.endsWith('.ytdl')) {
        // File kosong = sisa unduhan yang gagal; buang, jangan dipakai.
        if (e.lengthSync() == 0) {
          try {
            e.deleteSync();
          } catch (_) {}
          continue;
        }
        return e;
      }
    }
    return null;
  }

  // Pakai file yang sudah ada di [dir]; kalau belum, unduh lewat yt-dlp.
  // Unduhan yang sama (mis. prefetch + play) digabung agar tidak dobel.
  Future<File> _fetch(Track t, Directory dir, {String? fmt}) {
    final key = '${dir.path}|${t.id}|${fmt ?? ''}';
    return _inflight[key] ??= _doFetch(t, dir, fmt).whenComplete(() {
      // Pakai blok {} — kalau pakai "=> remove(key)" Future-nya ikut ditunggu
      // dan jadi menunggu dirinya sendiri (deadlock, loader muter terus).
      _inflight.remove(key);
    });
  }

  Future<File> _doFetch(Track t, Directory dir, String? fmt) async {
    final existing = _findFile(dir, t.id);
    if (existing != null) return existing;
    await _native('download', {
      'url': t.url,
      'dir': dir.path,
      'id': t.id,
      'format': fmt, // null = format asli
    });
    final f = _findFile(dir, t.id);
    if (f == null) throw Exception('File hasil tidak ditemukan');
    return f;
  }

  // ───────── Pencarian ─────────

  /// Ambil satu halaman hasil mulai dari nomor [start].
  /// Mengembalikan (daftar track valid, jumlah entri mentah dari yt-dlp).
  Future<(List<Track>, int)> _fetchPage(String q, int start) async {
    final out =
        await _native<String>('search', {
          'query': q,
          'start': start,
          'count': start + _pageSize - 1,
        }) ??
        '';
    final i = out.indexOf('{');
    final data =
        jsonDecode(i >= 0 ? out.substring(i) : '{}') as Map<String, dynamic>;
    final entries = (data['entries'] as List?) ?? [];
    final tracks = <Track>[];
    for (final e in entries) {
      if (e is! Map || e['id'] == null) continue;
      tracks.add(
        Track(
          e['id'] as String,
          (e['title'] ?? e['id']) as String,
          (e['channel'] ?? e['uploader'] ?? '') as String,
          (e['duration'] as num?)?.toInt(),
        ),
      );
    }
    return (tracks, entries.length);
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _lastQuery = q;
      _hasMore = true;
    });
    try {
      final (tracks, raw) = await _fetchPage(q, 1);
      if (mounted) {
        setState(() {
          _results = tracks;
          _nextStart = 1 + raw;
          _hasMore = raw >= _pageSize;
        });
      }
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _saveSearch();
    } catch (e) {
      debugPrint('[YT] search gagal: $e');
      if (mounted) setState(() => _error = 'Pencarian gagal: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onScroll() {
    if (_scroll.hasClients && _scroll.position.extentAfter < 400) _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _lastQuery.isEmpty) return;
    final q = _lastQuery;
    setState(() => _loadingMore = true);
    try {
      final (more, raw) = await _fetchPage(q, _nextStart);
      // user sudah cari yang lain
      if (!mounted || q != _lastQuery) {
        return;
      }
      final have = _results.map((t) => t.id).toSet();
      setState(() {
        _results = [..._results, ...more.where((t) => !have.contains(t.id))];
        _nextStart += raw;
        _hasMore = raw >= _pageSize;
      });
      _saveSearch();
    } catch (e) {
      debugPrint('[YT] load more gagal: $e');
      _snack('Gagal memuat lagi: $e');
      // hentikan loop kalau error
      if (mounted) {
        setState(() => _hasMore = false);
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  // ───────── Pemutaran & antrian ─────────

  Future<void> _playQueue(List<QItem> items, int i) {
    _queue = items;
    return _playIndex(i);
  }

  void _st(String m) {
    _stBase = m.replaceAll('...', '');
    _lastPct = -10;
    _pushStatus(m);
  }

  /// Tampilkan status di layar dan di notifikasi sekaligus.
  void _pushStatus(String m) {
    _handler.setStatus(m.length > 50 ? '${m.substring(0, 50)}…' : m);
    if (mounted) setState(() => _status = m);
  }

  Future<void> _playIndex(int i, {Duration? resume}) async {
    if (i < 0 || i >= _queue.length) return;
    final item = _queue[i];
    final gen = ++_gen;

    // Batalkan proses muat lagu sebelumnya supaya tidak rebutan bandwidth.
    for (final id in _cancellable.toList()) {
      if (id != item.id) {
        _native('cancel', {'id': id}).catchError((_) => null);
      }
    }
    setState(() {
      // spinner lama hilang
      if (_loadingId != null) {
        _dl.remove(_loadingId);
      }
      _loadingId = item.id;
      _index = i;
      _dl[item.id] = 0;
    });
    _detachVideo();

    final tag = MediaItem(
      id: item.id,
      title: item.title,
      artist: item.artist,
      artUri: item.thumb == null ? null : Uri.parse(item.thumb!),
      duration: item.track?.seconds == null
          ? null
          : Duration(seconds: item.track!.seconds!),
    );
    _handler.setTrack(tag); // judul & cover di notifikasi
    _handler.setLoading(true);
    EqualizerSheet.apply(_eq);
    _st('Menyiapkan...');

    try {
      AudioSource src;
      var streamed = false;
      File? videoFile;
      File? local = item.file;
      if (_videoMode && item.track != null) {
        // Mode video: unduh mp4; audionya dipakai just_audio, gambarnya video_player.
        _st('Mengunduh video...');
        try {
          videoFile = await _downloadVideo(item.track!);
          local = videoFile;
        } catch (e) {
          if (gen != _gen) return;
          debugPrint('[YT] video gagal: $e');
          _snack('Video gagal, diputar audio saja');
          videoFile = null;
        }
      }
      local ??= _findFile(await _dir(), item.id);
      local ??= _findFile(await _videoDir(), item.id);

      if (local != null) {
        src = AudioSource.file(local.path);
      } else {
        // 1) Coba streaming langsung (mulai main dalam hitungan detik)
        if (kStream && _streamOk) _st('Mengambil URL stream...');
        final url = (kStream && _streamOk) ? await _urlFor(item.track!) : null;
        if (url != null) {
          src = AudioSource.uri(Uri.parse(url));
          streamed = true;
          debugPrint(
            '[YT] stream ${item.id}: ${url.length > 60 ? url.substring(0, 60) : url}',
          );
        } else {
          // 2) Fallback: unduh dulu
          _st('Mengunduh audio...');
          final f = await _downloadForPlay(item.track!);
          src = AudioSource.file(f.path);
        }
      }
      // user sudah pindah lagu
      if (gen != _gen) {
        return;
      }

      _st('Memuat ke player...');
      try {
        final load = _player.setAudioSource(src);
        // Stream yang macet/ditolak (403) tidak melempar error -> beri batas waktu
        await load.timeout(Duration(seconds: streamed ? 15 : 20));
      } catch (e) {
        if (!streamed || gen != _gen) rethrow;
        debugPrint('[YT] stream gagal, fallback unduh: $e');
        _streamOk = false; // streaming bermasalah -> pakai unduhan sampai app dibuka ulang
        _urlCache.remove(item.id);
        final f = await _downloadForPlay(item.track!);
        if (gen != _gen) return;
        await _player.setAudioSource(AudioSource.file(f.path));
      }
      if (gen != _gen) return;
      if (resume != null && resume > Duration.zero) {
        await _player.seek(resume);
      }
      if (videoFile != null) await _attachVideo(videoFile, gen);
      if (gen != _gen) return;
      _st('');
      _player.play();
      _prefetch(i + 1);
    } catch (e) {
      debugPrint('[YT] play gagal: $e');
      if (gen == _gen) {
        _st('Error: $e');
        _snack('Gagal memutar: $e');
      }
    } finally {
      if (gen == _gen) _handler.setLoading(false);
      if (gen == _gen && mounted) {
        setState(() {
          _dl.remove(item.id);
          _loadingId = null;
        });
      }
    }
  }

  /// Ambil URL audio langsung via yt-dlp (method native 'streamUrl').
  Future<String?> _urlFor(Track t) async {
    final c = _urlCache[t.id];
    if (c != null) return c;
    try {
      final u = await _native<String>('streamUrl', {
        'url': t.url,
      }).timeout(const Duration(seconds: 25));
      final first = u?.trim().split('\n').first.trim();
      if (first == null || !first.startsWith('http')) return null;
      return _urlCache[t.id] = first;
    } on MissingPluginException {
      _streamOk = false; // Kotlin belum diupdate -> pakai unduhan
      return null;
    } catch (e) {
      debugPrint('[YT] streamUrl gagal: $e');
      return null;
    }
  }

  // ───────── Video ─────────

  Future<Directory> _videoDir() async {
    final d = Directory('${(await cacheBase()).path}/video');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Unduh video mp4 ke cache (folder terpisah dari audio). Hanya 1 lagu disimpan.
  Future<File> _downloadVideo(Track t) async {
    _cancellable.add(t.id);
    try {
      final dir = await _videoDir();
      try {
        for (final e in dir.listSync()) {
          if (e is File && !e.path.contains('[${t.id}]')) {
            try {
              e.deleteSync();
            } catch (_) {}
          }
        }
      } catch (_) {}
      return await _fetch(t, dir, fmt: 'video');
    } finally {
      _cancellable.remove(t.id);
    }
  }

  Future<void> _attachVideo(File f, int gen) async {
    try {
      final c = VideoPlayerController.file(
        f,
        // Jangan rebut audio focus dari just_audio.
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      await c.initialize();
      await c.setVolume(0);
      if (gen != _gen || !mounted) {
        await c.dispose();
        return;
      }
      await c.seekTo(_player.position);
      _vc = c;
      _syncTimer?.cancel();
      _syncTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _syncVideo(),
      );
      setState(() {});
    } catch (e) {
      debugPrint('[YT] video init gagal: $e');
    }
  }

  bool _syncing = false;

  /// Samakan video dengan audio (audio = acuan).
  /// Pakai posisi segar dari platform (`await c.position`): `c.value.position`
  /// hanya diperbarui kasar (~500 ms) sehingga drift palsu memicu seek terus-menerus
  /// dan gambar jadi patah-patah.
  Future<void> _syncVideo() async {
    final c = _vc;
    if (c == null || !c.value.isInitialized || _syncing) return;
    _syncing = true;
    try {
      final playing =
          _player.playing && _player.processingState == ProcessingState.ready;
      if (playing) {
        final vp = await c.position ?? Duration.zero;
        if (_vc != c) return;
        final drift = (vp - _player.position).inMilliseconds.abs();
        if (drift > 700) {
          await c.seekTo(_player.position);
        }
        if (!c.value.isPlaying) {
          await c.play();
        }
      } else if (c.value.isPlaying) {
        await c.pause();
      }
    } catch (_) {
    } finally {
      _syncing = false;
    }
  }

  void _detachVideo() {
    _syncTimer?.cancel();
    _syncTimer = null;
    final old = _vc;
    if (old == null) return;
    _vc = null;
    if (mounted) setState(() {});
    // Dispose setelah frame, supaya widget VideoPlayer lama tidak memakai controller mati.
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  Widget _videoView(QItem? cur) {
    final c = _vc;
    if (c != null && c.value.isInitialized) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: VideoPlayer(c),
      );
    }
    return artImage(cur?.thumb, radius: 24);
  }

  Future<File> _downloadForPlay(Track t) async {
    _cancellable.add(t.id);
    try {
      return await _fetch(t, await cacheBase());
    } finally {
      _cancellable.remove(t.id);
    }
  }

  /// Siapkan URL lagu berikutnya (hanya mode streaming; tidak mengunduh apa pun).
  Future<void> _prefetch(int i) async {
    if (!kStream || !_streamOk) return;
    if (i < 0 || i >= _queue.length) return;
    final t = _queue[i].track;
    if (t == null) return;
    try {
      if (_findFile(await _dir(), t.id) != null) return;
      await _urlFor(t);
    } catch (_) {}
  }

  void _next({bool auto = false}) {
    if (_queue.isEmpty) return;
    final n = _index + 1;
    if (n < _queue.length) {
      _playIndex(n);
    } else if (_repeat) {
      _playIndex(0);
    } else if (!auto) {
      _snack('Ini lagu terakhir di antrian');
    }
  }

  void _prev() {
    if (_queue.isEmpty) return;
    if (_player.position.inSeconds > 3 || _index <= 0) {
      _player.seek(Duration.zero);
    } else {
      _playIndex(_index - 1);
    }
  }

  /// Acak sisa antrian; lagu yang sedang diputar tetap di posisi pertama.
  void _shuffleQueue() {
    if (_queue.length < 2 || _cur == null) return;
    final cur = _queue[_index];
    final rest = [..._queue]..removeAt(_index);
    rest.shuffle();
    setState(() {
      _queue = [cur, ...rest];
      _index = 0;
    });
    _snack('Antrian diacak', icon: Icons.shuffle_rounded);
  }

  Future<void> _download(Track t) async {
    if (_dl.containsKey(t.id)) return;
    setState(() => _dl[t.id] = 0);
    try {
      final dir = await _dir();
      final conv = _fmtSave != 'original';
      // Format asli + sudah pernah diputar (ada di cache) -> cukup disalin.
      // Kalau minta konversi, selalu unduh ulang lewat yt-dlp + ffmpeg.
      final tmp = conv ? null : _findFile(await cacheBase(), t.id);
      if (tmp != null) {
        await tmp.copy('${dir.path}/${_fileName(tmp)}');
      } else {
        await _fetch(t, dir, fmt: conv ? _fmtSave : null);
      }
      _snack('Tersimpan: ${t.title}');
      await _loadSaved();
    } catch (e) {
      debugPrint('[YT] download gagal: $e');
      _snack('Gagal menyimpan: $e');
    } finally {
      if (mounted) setState(() => _dl.remove(t.id));
    }
  }

  Future<void> _delete(File f) async {
    await f.delete();
    await _loadSaved();
  }

  // ───────── Equalizer & Pengaturan ─────────

  void _openEq() {
    if (!kEnableEq) {
      _snack('Equalizer dimatikan (kEnableEq = false)');
      return;
    }
    if (!Platform.isAndroid) {
      _snack('Equalizer hanya tersedia di Android');
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => EqualizerSheet(eq: _eq),
    );
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.8,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scroll) => SafeArea(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
            children: [
              Row(
                children: [
                  const Icon(Icons.settings_rounded, size: 28),
                  const SizedBox(width: 12),
                  Text(
                    'Pengaturan',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'AUDIO & SUARA',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white54,
                ),
              ),
              const SizedBox(height: 8),
              Material(
                color: _panel,
                borderRadius: BorderRadius.circular(16),
                child: Column(
                  children: [
                    ListTile(
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary.withAlpha(40),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.equalizer_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      title: const Text('Equalizer Global'),
                      subtitle: const Text('Preset suara, bass boost, treble, dan 5-band gain'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () {
                        Navigator.pop(ctx);
                        _openEq();
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'UNDUHAN & PENYIMPANAN',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white54,
                ),
              ),
              const SizedBox(height: 8),
              Material(
                color: _panel,
                borderRadius: BorderRadius.circular(16),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.audio_file_rounded),
                      title: const Text('Format Simpan Audio'),
                      subtitle: Text(_formats[_fmtSave] ?? _fmtSave),
                      trailing: PopupMenuButton<String>(
                        icon: const Icon(Icons.arrow_drop_down_circle_outlined),
                        color: _panel,
                        onSelected: (v) {
                          _setFormat(v);
                          Navigator.pop(ctx);
                        },
                        itemBuilder: (_) => [
                          for (final e in _formats.entries)
                            PopupMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'PEMBARUAN APLIKASI (OTA)',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white54,
                ),
              ),
              const SizedBox(height: 8),
              Material(
                color: _panel,
                borderRadius: BorderRadius.circular(16),
                child: Column(
                  children: [
                    ListTile(
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary.withAlpha(35),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.system_update_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      title: const Text('Periksa Update Aplikasi'),
                      subtitle: const Text('Cek rilis OTA terbaru dari GitHub'),
                      trailing: _checkingOta
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_download_outlined),
                      onTap: _checkingOta
                          ? null
                          : () {
                              Navigator.pop(ctx);
                              _checkOtaUpdate(manual: true);
                            },
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.source_rounded),
                      title: const Text('Repository GitHub'),
                      subtitle: FutureBuilder<String>(
                        future: OtaService.getRepo(),
                        builder: (_, snap) => Text(snap.data ?? OtaService.defaultRepo),
                      ),
                      trailing: const Icon(Icons.edit_outlined, size: 20),
                      onTap: () {
                        Navigator.pop(ctx);
                        _editOtaRepo();
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'MESIN YT-DLP',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white54,
                ),
              ),
              const SizedBox(height: 8),
              Material(
                color: _panel,
                borderRadius: BorderRadius.circular(16),
                child: ListTile(
                  leading: const Icon(Icons.system_update_alt_rounded),
                  title: const Text('Perbarui Mesin yt-dlp'),
                  subtitle: Text(_updating ? 'Sedang memperbarui...' : 'Cek dan update binary extractor'),
                  trailing: _updating
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  onTap: _updating
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          if (_ready) _update();
                        },
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'LAINNYA',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white54,
                ),
              ),
              const SizedBox(height: 8),
              Material(
                color: _panel,
                borderRadius: BorderRadius.circular(16),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.help_outline_rounded),
                      title: const Text('Bantuan & Panduan'),
                      subtitle: const Text('Cara penggunaan, mode pemutaran & fitur'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () {
                        Navigator.pop(ctx);
                        _openHelp();
                      },
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.info_outline_rounded),
                      title: const Text('Tentang Aplikasi'),
                      subtitle: const Text('Versi, pengembang, dan informasi lisensi'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () {
                        Navigator.pop(ctx);
                        _openAbout();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openHelp() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scroll) => SafeArea(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary.withAlpha(35),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.help_outline_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Bantuan & Panduan',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _helpItem(
                Icons.search_rounded,
                'Pencarian & Pemutaran Musik',
                'Ketik judul lagu, artis, atau tempel link video YouTube langsung pada kolom pencarian. Ketuk lagu untuk mulai memutar.',
              ),
              const SizedBox(height: 12),
              _helpItem(
                Icons.headphones_rounded,
                'Mode Audio & Mode Video',
                'Gunakan tombol headset/kamera di bagian atas untuk beralih antara mendengarkan audio hemat kuota di latar belakang (background) atau memutar dengan video.',
              ),
              const SizedBox(height: 12),
              _helpItem(
                Icons.equalizer_rounded,
                'Equalizer Global',
                'Atur preset suara (Bass, Vokal, Rock, Pop), tone bass/treble, serta 5-band frequency gain. Pengaturan berlaku global dan otomatis disimpan.',
              ),
              const SizedBox(height: 12),
              _helpItem(
                Icons.file_download_outlined,
                'Unduh & Pemutaran Offline',
                'Ketuk ikon unduh pada hasil pencarian untuk menyimpan lagu ke memori lokal. Lagu tersimpan dapat diputar kapan saja tanpa koneksi internet di tab "Tersimpan".',
              ),
              const SizedBox(height: 12),
              _helpItem(
                Icons.queue_music_rounded,
                'Playlist Kustom',
                'Kelola koleksi lagu favoritmu dengan membuat playlist sendiri di tab "Playlist". Kamu bisa menambah, menyusun urutan, maupun mengganti nama playlist.',
              ),
              const SizedBox(height: 12),
              _helpItem(
                Icons.system_update_alt_rounded,
                'Pembaruan Mesin Ekstraktor',
                'Jika pencarian atau pemutaran mengalami kendala, buka Pengaturan lalu ketuk "Perbarui Mesin yt-dlp" untuk memperbarui scraper YouTube ke versi terbaru.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _helpItem(IconData icon, String title, String desc) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 24, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  desc,
                  style: const TextStyle(fontSize: 12.5, color: Colors.white70, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editOtaRepo() async {
    final current = await OtaService.getRepo();
    final ctrl = TextEditingController(text: current);
    if (!mounted) return;
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Repository GitHub OTA'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Format: owner/repository (misal: sutanto/yt_audio)',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(
                filled: true,
                fillColor: _panel,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                hintText: 'owner/repository',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    if (res != null && res.isNotEmpty) {
      await OtaService.setRepo(res);
      _snack('Repo update diubah: $res');
    }
  }

  Future<void> _checkOtaUpdate({bool manual = false}) async {
    if (_checkingOta) return;
    setState(() => _checkingOta = true);
    try {
      final release = await OtaService.checkUpdate();
      if (!mounted) return;
      if (release == null) {
        if (manual) _snack('Belum ada rilis update di GitHub');
        return;
      }

      final cmp = OtaService.compareSemVer(release.version, OtaService.currentVersion);
      if (cmp > 0) {
        _showOtaDialog(release);
      } else {
        if (manual) _snack('Aplikasi sudah versi terbaru (v${OtaService.currentVersion})');
      }
    } catch (e) {
      if (manual && mounted) _snack('Gagal memeriksa update: $e');
    } finally {
      if (mounted) setState(() => _checkingOta = false);
    }
  }

  void _showOtaDialog(OtaRelease release) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        double dlProgress = 0.0;
        int receivedBytes = 0;
        int totalBytes = release.size;
        bool downloading = false;
        String? errorMsg;

        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final mb = (release.size / 1048576).toStringAsFixed(1);
            final recMb = (receivedBytes / 1048576).toStringAsFixed(1);
            final totMb = (totalBytes / 1048576).toStringAsFixed(1);

            return AlertDialog(
              backgroundColor: _card,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary.withAlpha(40),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.system_update_rounded, color: Theme.of(context).colorScheme.primary),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Pembaruan Tersedia',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Versi baru: v${release.version} (Saat ini: v${OtaService.currentVersion})',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 13,
                      ),
                    ),
                    if (release.size > 0)
                      Text('Ukuran: $mb MB', style: const TextStyle(fontSize: 12, color: Colors.white60)),
                    const SizedBox(height: 12),
                    if (release.notes.isNotEmpty) ...[
                      const Text(
                        'Catatan Rilis:',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxHeight: 140),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: _panel,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: SingleChildScrollView(
                          child: Text(
                            release.notes,
                            style: const TextStyle(fontSize: 12, color: Colors.white70),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    if (downloading) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(value: dlProgress, minHeight: 8),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('${(dlProgress * 100).toStringAsFixed(0)}%', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                          Text('$recMb / $totMb MB', style: const TextStyle(fontSize: 11, color: Colors.white60)),
                        ],
                      ),
                    ],
                    if (errorMsg != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(errorMsg!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                      ),
                  ],
                ),
              ),
              actions: [
                if (!downloading)
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx),
                    child: const Text('Nanti Saja'),
                  ),
                FilledButton.icon(
                  icon: Icon(downloading ? Icons.hourglass_top_rounded : Icons.download_rounded),
                  label: Text(downloading ? 'Mengunduh...' : 'Update Sekarang'),
                  onPressed: downloading
                      ? null
                      : () async {
                          setDialogState(() {
                            downloading = true;
                            errorMsg = null;
                          });
                          try {
                            final apkFile = await OtaService.downloadRelease(
                              release: release,
                              onProgress: (p, rec, tot) {
                                setDialogState(() {
                                  dlProgress = p;
                                  receivedBytes = rec;
                                  totalBytes = tot;
                                });
                              },
                            );

                            if (!dialogCtx.mounted) return;
                            Navigator.pop(dialogCtx);

                            if (Platform.isAndroid) {
                              _snack('Unduhan selesai, membuka installer...');
                              final ok = await _native<bool>('installApk', {'filePath': apkFile.path});
                              if (ok != true) {
                                _snack('Gagal membuka paket installer');
                              }
                            } else {
                              _snack('Paket terunduh di: ${apkFile.path}');
                            }
                          } catch (e) {
                            setDialogState(() {
                              downloading = false;
                              errorMsg = 'Gagal mengunduh: $e';
                            });
                          }
                        },
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _openAbout() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black45,
                      blurRadius: 16,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset(
                    'assets/icon/app_icon.png',
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.album_rounded,
                      size: 64,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Compo',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .4,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Versi ${OtaService.currentVersion}',
                style: const TextStyle(color: Colors.white60, fontSize: 13),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _panel,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text(
                  'Compo adalah pemutar musik dan audio YouTube yang ringan, bebas iklan audio mengganggu, mendukung pemutaran latar belakang (background audio), equalizer global, playlist, serta penyimpanan offline.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.white70, height: 1.45),
                ),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: _panel,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.code_rounded, size: 20, color: Colors.white60),
                    const SizedBox(width: 12),
                    const Text('Ditenagai oleh', style: TextStyle(fontSize: 13, color: Colors.white70)),
                    const Spacer(),
                    Text(
                      'yt-dlp & just_audio',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Tutup'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────── Widget kecil ─────────

  Widget _empty(IconData icon, String title, String sub) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 72, color: Colors.white24),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            sub,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54),
          ),
        ],
      ),
    ),
  );

  Widget _playPause({double size = 30}) {
    final cs = Theme.of(context).colorScheme;
    return StreamBuilder<PlayerState>(
      stream: _player.playerStateStream,
      builder: (_, snap) {
        final s = snap.data;
        final loadingCur = _cur != null && _dl.containsKey(_cur!.id);
        final busy =
            loadingCur ||
            s?.processingState == ProcessingState.loading ||
            s?.processingState == ProcessingState.buffering;
        if (busy) {
          return SizedBox(
            width: size + 20,
            height: size + 20,
            child: Padding(
              padding: EdgeInsets.all(size / 3),
              child: const CircularProgressIndicator(strokeWidth: 2.5),
            ),
          );
        }
        final playing = s?.playing ?? false;
        final completed = s?.processingState == ProcessingState.completed;
        void toggle() {
          if (completed) {
            _player.seek(Duration.zero);
            _player.play();
          } else if (playing) {
            _player.pause();
          } else {
            _player.play();
          }
        }

        final icon = Icon(
          playing && !completed
              ? Icons.pause_rounded
              : Icons.play_arrow_rounded,
        );
        if (size > 40) {
          return Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [cs.primary, cs.tertiary]),
              boxShadow: [
                BoxShadow(color: cs.primary.withAlpha(110), blurRadius: 24),
              ],
            ),
            child: IconButton(
              iconSize: size,
              color: Colors.white,
              icon: icon,
              onPressed: toggle,
            ),
          );
        }
        return IconButton(iconSize: size, icon: icon, onPressed: toggle);
      },
    );
  }

  // ───────── Halaman Cari ─────────

  Widget _searchPage() {
    final savedIds = _saved.map(videoIdOf).whereType<String>().toSet();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: _q,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _ready ? _search() : null,
            decoration: InputDecoration(
              hintText: _ready
                  ? 'Cari lagu di YouTube'
                  : 'Menyiapkan yt-dlp...',
              filled: true,
              fillColor: const Color(0xFF1B1B22),
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward_rounded),
                onPressed: _ready ? _search : null,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (_loading || !_ready) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: _results.isEmpty
              ? (_loading
                    ? const SizedBox.shrink()
                    : _empty(
                        Icons.ondemand_video_rounded,
                        'Cari lagu favoritmu',
                        'Ketik judul atau nama artis, lalu ketuk hasilnya untuk memutar.',
                      ))
              : ListView.separated(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: _results.length + (_loadingMore ? 1 : 0),
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    if (i >= _results.length) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        ),
                      );
                    }
                    return _trackTile(
                      _results[i],
                      i,
                      savedIds.contains(_results[i].id),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _trackTile(Track t, int i, bool isSaved) {
    final cs = Theme.of(context).colorScheme;
    final playing = _cur?.id == t.id;
    final p = _dl[t.id];
    return Material(
      color: playing ? cs.primary.withAlpha(35) : _card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _playQueue(_results.map(QItem.fromTrack).toList(), i),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Stack(
                children: [
                  SizedBox(
                    width: 96,
                    height: 54,
                    child: artImage(t.thumb, radius: 8),
                  ),
                  if (playing)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.equalizer_rounded,
                          color: cs.primary,
                          size: 28,
                        ),
                      ),
                    ),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _fmt(t.seconds),
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: playing ? cs.primary : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      t.channel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (p != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      value: p > 0 ? p : null,
                      strokeWidth: 3,
                    ),
                  ),
                )
              else if (isSaved)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Icon(Icons.check_circle_rounded, color: cs.primary),
                )
              else
                IconButton(
                  tooltip: 'Simpan',
                  icon: const Icon(Icons.download_rounded),
                  onPressed: () => _download(t),
                ),
              IconButton(
                tooltip: 'Tambah ke playlist',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.playlist_add_rounded),
                onPressed: () => _addToPlaylist(t),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────── Halaman Playlist ─────────

  Widget _playlistPage() {
    final open = _plOpen == null
        ? null
        : _playlists.where((p) => p.id == _plOpen).firstOrNull;
    if (open != null) return _playlistDetail(open);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Text(
                '${_playlists.length} playlist',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.add_rounded),
                label: const Text('Playlist baru'),
                onPressed: () => _newPlaylist(),
              ),
            ],
          ),
        ),
        Expanded(
          child: _playlists.isEmpty
              ? _empty(
                  Icons.queue_music_rounded,
                  'Belum ada playlist',
                  'Ketuk "Playlist baru", atau ikon + di hasil pencarian untuk menambah lagu.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: _playlists.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final p = _playlists[i];
                    return Material(
                      color: _card,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => setState(() => _plOpen = p.id),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 56,
                                height: 56,
                                child: artImage(
                                  p.tracks.isEmpty
                                      ? null
                                      : p.tracks.first.thumb,
                                  size: 56,
                                  radius: 10,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      p.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      '${p.tracks.length} lagu',
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'rename') _renamePlaylist(p);
                                  if (v == 'delete') _deletePlaylist(p);
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: Text('Ganti nama'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Hapus playlist'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _playlistDetail(Playlist pl) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 8, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Kembali',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => setState(() => _plOpen = null),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pl.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${pl.tracks.length} lagu',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Acak',
                icon: const Icon(Icons.shuffle_rounded),
                onPressed: pl.tracks.isEmpty
                    ? null
                    : () {
                        final q = pl.tracks.map(QItem.fromTrack).toList()
                          ..shuffle();
                        _playQueue(q, 0);
                      },
              ),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Putar'),
                onPressed: pl.tracks.isEmpty
                    ? null
                    : () => _playQueue(
                        pl.tracks.map(QItem.fromTrack).toList(),
                        0,
                      ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'rename') _renamePlaylist(pl);
                  if (v == 'delete') _deletePlaylist(pl);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Ganti nama')),
                  PopupMenuItem(value: 'delete', child: Text('Hapus playlist')),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: pl.tracks.isEmpty
              ? _empty(
                  Icons.library_music_outlined,
                  'Playlist masih kosong',
                  'Cari lagu lalu ketuk ikon + untuk menambahkannya ke sini.',
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: pl.tracks.length,
                  onReorderItem: (o, n) {
                    setState(() => pl.tracks.insert(n, pl.tracks.removeAt(o)));
                    _savePlaylists();
                  },
                  itemBuilder: (_, i) {
                    final t = pl.tracks[i];
                    final playing = _cur?.id == t.id;
                    return Padding(
                      key: ValueKey('${pl.id}|${t.id}'),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color: playing ? cs.primary.withAlpha(35) : _card,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => _playQueue(
                            pl.tracks.map(QItem.fromTrack).toList(),
                            i,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
                            child: Row(
                              children: [
                                Stack(
                                  children: [
                                    SizedBox(
                                      width: 96,
                                      height: 54,
                                      child: artImage(t.thumb, radius: 8),
                                    ),
                                    if (playing)
                                      Positioned.fill(
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Colors.black54,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Icon(
                                            Icons.equalizer_rounded,
                                            color: cs.primary,
                                            size: 28,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        t.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: playing ? cs.primary : null,
                                        ),
                                      ),
                                      if (t.channel.isNotEmpty)
                                        Text(
                                          t.channel,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Hapus dari playlist',
                                  icon: const Icon(Icons.close_rounded),
                                  onPressed: () {
                                    setState(() => pl.tracks.removeAt(i));
                                    _savePlaylists();
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ───────── Halaman Tersimpan ─────────

  Widget _savedPage() {
    if (_saved.isEmpty) {
      return _empty(
        Icons.library_music_outlined,
        'Belum ada audio tersimpan',
        'Ketuk ikon unduh di hasil pencarian untuk menyimpan lagu.',
      );
    }
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Text(
                '${_saved.length} lagu',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Putar semua'),
                onPressed: () =>
                    _playQueue(_saved.map(QItem.fromFile).toList(), 0),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            itemCount: _saved.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final f = _saved[i];
              final item = QItem.fromFile(f);
              final playing = _cur?.id == item.id;
              final mb = (f.lengthSync() / 1048576).toStringAsFixed(1);
              return Material(
                color: playing ? cs.primary.withAlpha(35) : _card,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () =>
                      _playQueue(_saved.map(QItem.fromFile).toList(), i),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
                    child: Row(
                      children: [
                        Stack(
                          children: [
                            SizedBox(
                              width: 56,
                              height: 56,
                              child: artImage(item.thumb, size: 56, radius: 10),
                            ),
                            if (playing)
                              Positioned.fill(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(
                                    Icons.equalizer_rounded,
                                    color: cs.primary,
                                    size: 26,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: playing ? cs.primary : null,
                                ),
                              ),
                              Text(
                                '$mb MB',
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'playlist') _addFileToPlaylist(f);
                            if (v == 'export') _export(f);
                            if (v == 'delete') _delete(f);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'playlist',
                              child: Text('Tambah ke playlist'),
                            ),
                            PopupMenuItem(
                              value: 'export',
                              child: Text('Salin ke folder Music'),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Hapus'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ───────── Mini player ─────────

  Widget _miniPlayer() {
    final cur = _cur;
    if (cur == null) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () => setState(() => _full = true),
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(0xFF1F1F27),
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 4, 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: artImage(cur.thumb, size: 48, radius: 10),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          cur.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          _status.isNotEmpty ? _status : cur.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_previous_rounded),
                    onPressed: _prev,
                  ),
                  _playPause(size: 30),
                  IconButton(
                    icon: const Icon(Icons.skip_next_rounded),
                    onPressed: () => _next(),
                  ),
                ],
              ),
            ),
            StreamBuilder<Duration>(
              stream: _player.positionStream,
              builder: (_, snap) {
                final pos = snap.data ?? Duration.zero;
                final dur = _player.duration ?? Duration.zero;
                final v = dur.inMilliseconds > 0
                    ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                    : 0.0;
                return LinearProgressIndicator(value: v, minHeight: 2.5);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ───────── Pemutar layar penuh ─────────

  Widget _fullPlayer() {
    final cur = _cur;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [cs.primary.withAlpha(90), _bg],
            stops: const [0, 0.65],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      iconSize: 32,
                      onPressed: () => setState(() => _full = false),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          const Text(
                            'SEDANG DIPUTAR',
                            style: TextStyle(fontSize: 11, letterSpacing: 1.5),
                          ),
                          if (_queue.isNotEmpty)
                            Text(
                              '${_index + 1} / ${_queue.length}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white54,
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: _videoMode ? 'Mode video' : 'Mode audio saja',
                      icon: Icon(
                        _videoMode
                            ? Icons.videocam_rounded
                            : Icons.headphones_rounded,
                      ),
                      onPressed: () => _setVideoMode(!_videoMode),
                    ),
                    IconButton(
                      tooltip: 'Equalizer',
                      icon: const Icon(Icons.equalizer_rounded),
                      onPressed: _openEq,
                    ),
                  ],
                ),
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: (_vc != null && _vc!.value.isInitialized)
                          ? _vc!.value.aspectRatio
                          : 1,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black54,
                              blurRadius: 24,
                              offset: Offset(0, 10),
                            ),
                          ],
                        ),
                        child: _videoView(cur),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    cur?.title ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _status.isNotEmpty ? _status : (cur?.artist ?? ''),
                    style: const TextStyle(color: Colors.white60),
                  ),
                ),
                const SizedBox(height: 8),
                VuMeter(vu: _vu),
                const SizedBox(height: 4),
                SeekBar(player: _player),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      tooltip: 'Ulangi antrian',
                      icon: Icon(
                        _repeat
                            ? Icons.repeat_on_rounded
                            : Icons.repeat_rounded,
                        color: _repeat ? cs.primary : Colors.white54,
                      ),
                      onPressed: () => setState(() => _repeat = !_repeat),
                    ),
                    IconButton(
                      iconSize: 40,
                      icon: const Icon(Icons.skip_previous_rounded),
                      onPressed: _prev,
                    ),
                    _playPause(size: 48),
                    IconButton(
                      iconSize: 40,
                      icon: const Icon(Icons.skip_next_rounded),
                      onPressed: () => _next(),
                    ),
                    IconButton(
                      tooltip: 'Acak antrian',
                      icon: const Icon(
                        Icons.shuffle_rounded,
                        color: Colors.white54,
                      ),
                      onPressed: _shuffleQueue,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ───────── Build ─────────

  @override
  Widget build(BuildContext context) {
    if (_full) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (_, _) => setState(() => _full = false),
        child: _fullPlayer(),
      );
    }
    final scaffold = Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset(
              'assets/icon/app_icon.png',
              width: 36,
              height: 36,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.album_rounded, size: 28),
            ),
            const SizedBox(width: 10),
            const Text(
              'Compo',
              style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: .3),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _videoMode
                ? 'Mode video (ketuk untuk audio saja)'
                : 'Mode audio saja (ketuk untuk video)',
            icon: Icon(
              _videoMode ? Icons.videocam_rounded : Icons.headphones_rounded,
            ),
            onPressed: () => _setVideoMode(!_videoMode),
          ),
          IconButton(
            tooltip: 'Pengaturan',
            icon: const Icon(Icons.settings_rounded),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: _tab == 0
            ? _searchPage()
            : _tab == 1
            ? _savedPage()
            : _playlistPage(),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _miniPlayer(),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) {
              setState(() => _tab = i);
              if (i == 1) _loadSaved();
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.search_outlined),
                selectedIcon: Icon(Icons.search_rounded),
                label: 'Cari',
              ),
              NavigationDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music_rounded),
                label: 'Tersimpan',
              ),
              NavigationDestination(
                icon: Icon(Icons.queue_music_outlined),
                selectedIcon: Icon(Icons.queue_music_rounded),
                label: 'Playlist',
              ),
            ],
          ),
        ],
      ),
    );
    return PopScope(
      canPop: !(_tab == 2 && _plOpen != null),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _plOpen = null);
      },
      child: scaffold,
    );
  }
}

// ───────────────────────── Seek bar ─────────────────────────

class SeekBar extends StatefulWidget {
  final AudioPlayer player;
  const SeekBar({super.key, required this.player});

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      builder: (_, ds) {
        final dur = ds.data ?? player.duration ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: player.positionStream,
          builder: (_, ps) {
            final pos = ps.data ?? Duration.zero;
            final max = dur.inMilliseconds.toDouble();
            final raw = _drag ?? pos.inMilliseconds.toDouble();
            final v = max > 0 ? raw.clamp(0.0, max).toDouble() : 0.0;
            return Column(
              children: [
                Slider(
                  value: v,
                  max: max > 0 ? max : 1,
                  onChanged: (x) => setState(() => _drag = x),
                  onChangeEnd: (x) {
                    player.seek(Duration(milliseconds: x.toInt()));
                    setState(() => _drag = null);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(
                        fmtDur(Duration(milliseconds: v.toInt())),
                        style: const TextStyle(fontSize: 12),
                      ),
                      const Spacer(),
                      Text(fmtDur(dur), style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

// ───────────────────────── VU meter ─────────────────────────

/// Level audio 0..1 (skala dB). Android: dari Visualizer (Kotlin, channel
/// 'yt_audio/vu'). Kalau native belum ada / izin ditolak / Linux, meter
/// memakai gerak simulasi selama lagu diputar (hanya hiasan).
class VuService {
  static const _m = MethodChannel('yt_audio/vu');
  static const _e = EventChannel('yt_audio/vu_stream');

  final level = ValueNotifier<double>(0);
  final peak = ValueNotifier<double>(0);

  StreamSubscription? _sub;
  Timer? _tick;
  bool _real = false;
  bool _playing = false;
  int? _session;
  double _target = 0;
  double _t = 0;
  int _hold = 0;

  VuService() {
    _tick = Timer.periodic(const Duration(milliseconds: 33), _onTick);
  }

  void setPlaying(bool v) => _playing = v;

  Future<void> attach(int? session) async {
    if (!Platform.isAndroid || session == null || session == 0) return;
    if (_session == session) return;
    _session = session;
    try {
      if (!await Permission.microphone.isGranted) {
        final st = await Permission.microphone.request();
        if (!st.isGranted) {
          _real = false;
          return;
        }
      }
      await _m.invokeMethod('start', {'session': session});
      _sub ??= _e.receiveBroadcastStream().listen(
        _onData,
        onError: (_) => _real = false,
      );
      _real = true;
    } catch (e) {
      debugPrint('[YT] VU native gagal: $e');
      _real = false;
    }
  }

  void _onData(dynamic v) {
    final rms = (v as num).toDouble().clamp(1e-5, 1.0);
    final db = 20 * math.log(rms) / math.ln10; // -100 .. 0 dB
    _target = ((db + 42) / 42).clamp(0.0, 1.0); // -42 dB = kosong, 0 dB = penuh
  }

  void _onTick(Timer _) {
    if (!_playing && level.value < 0.001 && peak.value < 0.001) return;
    double target;
    if (!_playing) {
      target = 0;
    } else if (_real) {
      target = _target;
    } else {
      _t += 0.033;
      target =
          (0.5 +
                  0.22 * math.sin(_t * 7) +
                  0.15 * math.sin(_t * 13.3) +
                  0.08 * math.sin(_t * 3.1))
              .clamp(0.0, 1.0);
    }
    final cur = level.value;
    // naik cepat, turun pelan (seperti VU asli)
    level.value = cur + (target - cur) * (target > cur ? 0.6 : 0.12);
    if (level.value >= peak.value) {
      peak.value = level.value;
      _hold = 18; // tahan ~0.6 detik
    } else if (_hold > 0) {
      _hold--;
    } else {
      peak.value = math.max(0, peak.value - 0.02);
    }
  }

  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    if (Platform.isAndroid) {
      _m.invokeMethod('stop').catchError((_) => null);
    }
    level.dispose();
    peak.dispose();
  }
}

class VuMeter extends StatelessWidget {
  final VuService vu;
  const VuMeter({super.key, required this.vu});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text(
          'VU',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w700,
            color: Colors.white54,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SizedBox(
            height: 18,
            child: AnimatedBuilder(
              animation: Listenable.merge([vu.level, vu.peak]),
              builder: (_, _) => CustomPaint(
                painter: _VuPainter(vu.level.value, vu.peak.value),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _VuPainter extends CustomPainter {
  final double level;
  final double peak;
  _VuPainter(this.level, this.peak);

  static const _n = 32;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 3.0;
    final w = (size.width - gap * (_n - 1)) / _n;
    final lit = (level * _n).round();
    final pk = (peak * _n).round().clamp(1, _n) - 1;
    for (var i = 0; i < _n; i++) {
      final f = i / (_n - 1);
      final base = f < 0.65
          ? const Color(0xFF3DDC97)
          : f < 0.85
          ? const Color(0xFFFFC857)
          : const Color(0xFFFF5C6C);
      final on = i < lit || (i == pk && peak > 0.02);
      final paint = Paint()..color = on ? base : Colors.white12;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * (w + gap), 0, w, size.height),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_VuPainter o) => o.level != level || o.peak != peak;
}

// ───────────────────────── OTA Update Service ─────────────────────────

class OtaRelease {
  final String version;
  final String title;
  final String notes;
  final String downloadUrl;
  final String fileName;
  final int size;

  const OtaRelease({
    required this.version,
    required this.title,
    required this.notes,
    required this.downloadUrl,
    required this.fileName,
    required this.size,
  });

  static OtaRelease? fromJson(Map<String, dynamic> json) {
    try {
      final tag = (json['tag_name'] as String?)?.replaceAll('v', '').trim() ?? '';
      final name = (json['name'] as String?) ?? 'Compo v$tag';
      final body = (json['body'] as String?) ?? '';
      final assets = (json['assets'] as List?) ?? [];

      Map<String, dynamic>? targetAsset;
      for (final a in assets) {
        if (a is Map) {
          final aname = (a['name'] as String?)?.toLowerCase() ?? '';
          if (Platform.isAndroid && aname.endsWith('.apk')) {
            targetAsset = Map<String, dynamic>.from(a);
            break;
          } else if (Platform.isLinux && aname.endsWith('.deb')) {
            targetAsset = Map<String, dynamic>.from(a);
            break;
          }
        }
      }

      if (targetAsset == null && assets.isNotEmpty && assets.first is Map) {
        targetAsset = Map<String, dynamic>.from(assets.first as Map);
      }

      if (targetAsset == null) return null;

      final url = (targetAsset['browser_download_url'] as String?) ?? '';
      final fName = (targetAsset['name'] as String?) ?? (Platform.isAndroid ? 'update.apk' : 'update.deb');
      final size = (targetAsset['size'] as num?)?.toInt() ?? 0;

      if (url.isEmpty) return null;

      return OtaRelease(
        version: tag,
        title: name,
        notes: body,
        downloadUrl: url,
        fileName: fName,
        size: size,
      );
    } catch (_) {
      return null;
    }
  }
}

class OtaService {
  static String currentVersion = '1.0.2';
  static const defaultRepo = 'blackhousing/compo-update';

  static Future<void> initVersion() async {
    try {
      final yamlStr = await rootBundle.loadString('pubspec.yaml');
      for (final line in yamlStr.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.startsWith('version:')) {
          final v = trimmed.substring('version:'.length).trim();
          if (v.isNotEmpty) {
            currentVersion = v.split('+').first.trim();
          }
          break;
        }
      }
    } catch (_) {}
  }

  static Future<File> _repoFile() async {
    final base = await appBase();
    return File('${base.path}/ota_github_repo.txt');
  }

  static Future<String> getRepo() async {
    try {
      final f = await _repoFile();
      if (await f.exists()) {
        final r = (await f.readAsString()).trim();
        if (r.isNotEmpty) return r;
      }
    } catch (_) {}
    return defaultRepo;
  }

  static Future<void> setRepo(String repo) async {
    try {
      final f = await _repoFile();
      await f.writeAsString(repo.trim());
    } catch (_) {}
  }

  static int compareSemVer(String v1, String v2) {
    List<int> parse(String v) =>
        v.replaceAll(RegExp(r'[^0-9.]'), '').split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final p1 = parse(v1);
    final p2 = parse(v2);
    final len = math.max(p1.length, p2.length);
    for (var i = 0; i < len; i++) {
      final a = i < p1.length ? p1[i] : 0;
      final b = i < p2.length ? p2[i] : 0;
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  static Future<OtaRelease?> checkUpdate() async {
    final repo = await getRepo();
    final url = Uri.parse('https://api.github.com/repos/$repo/releases/latest');
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(url);
      req.headers.set('User-Agent', 'Compo-Music-Player');
      req.headers.set('Accept', 'application/vnd.github.v3+json');
      final resp = await req.close();
      if (resp.statusCode == 200) {
        final bodyStr = await resp.transform(utf8.decoder).join();
        final map = jsonDecode(bodyStr) as Map<String, dynamic>;
        return OtaRelease.fromJson(map);
      }
      return null;
    } catch (e) {
      debugPrint('[OTA] checkUpdate error: $e');
      rethrow;
    } finally {
      client.close();
    }
  }

  static Future<File> downloadRelease({
    required OtaRelease release,
    required void Function(double progress, int received, int total) onProgress,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final targetFile = File('${tempDir.path}/${release.fileName}');
    if (await targetFile.exists()) {
      await targetFile.delete();
    }

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(release.downloadUrl));
      req.headers.set('User-Agent', 'Compo-Music-Player');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw Exception('Gagal mengunduh: HTTP ${resp.statusCode}');
      }

      final total = resp.contentLength > 0 ? resp.contentLength : release.size;
      var received = 0;
      final sink = targetFile.openWrite();

      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress((received / total).clamp(0.0, 1.0), received, total);
        }
      }
      await sink.flush();
      await sink.close();
      return targetFile;
    } finally {
      client.close();
    }
  }
}

// ───────────────────────── Equalizer + Tone ─────────────────────────

class EqualizerSheet extends StatefulWidget {
  final AndroidEqualizer eq;
  const EqualizerSheet({super.key, required this.eq});

  static const presets = <String, List<double>>{
    'Flat': [0, 0, 0, 0, 0],
    'Bass': [0.7, 0.45, 0, -0.1, 0],
    'Vokal': [-0.3, 0, 0.5, 0.4, -0.1],
    'Treble': [0, 0, 0, 0.5, 0.8],
    'Rock': [0.5, 0.2, -0.2, 0.3, 0.5],
    'Pop': [-0.2, 0.3, 0.5, 0.2, -0.2],
  };

  // Frekuensi band default (Hz) bila audio session native belum siap
  static const defaultFreqs = [60.0, 230.0, 910.0, 3600.0, 14000.0];
  static const double minDb = -15.0;
  static const double maxDb = 15.0;

  static List<double> _base = [0, 0, 0, 0, 0];
  static double _bass = 0; // dB
  static double _treble = 0; // dB
  static bool _enabled = true;
  static bool _loaded = false;

  static Future<File> _file() async {
    final base = await appBase();
    return File('${base.path}/equalizer_settings.json');
  }

  static Future<void> load(AndroidEqualizer eq) async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        _enabled = (data['enabled'] as bool?) ?? true;
        _bass = (data['bass'] as num?)?.toDouble() ?? 0.0;
        _treble = (data['treble'] as num?)?.toDouble() ?? 0.0;
        if (data['bands'] is List && (data['bands'] as List).isNotEmpty) {
          _base = (data['bands'] as List).map((x) => (x as num).toDouble()).toList();
        }
      }
    } catch (_) {}
    _loaded = true;
    if (Platform.isAndroid && kEnableEq) {
      apply(eq);
    }
  }

  static Future<void> save() async {
    try {
      final f = await _file();
      final data = {
        'enabled': _enabled,
        'bass': _bass,
        'treble': _treble,
        'bands': _base,
      };
      await f.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  static double sample(List<double> p, int i, int n) {
    if (n <= 1) return p.first;
    final pos = i / (n - 1) * (p.length - 1);
    final lo = pos.floor();
    final hi = pos.ceil();
    return p[lo] + (p[hi] - p[lo]) * (pos - lo);
  }

  static double tone(int i, int n) {
    final t = n <= 1 ? 0.0 : i / (n - 1);
    return _bass * (1 - t) * (1 - t) + _treble * t * t;
  }

  /// Terapkan gain ke hardware jika audio session aktif
  static Future<void> apply(AndroidEqualizer eq) async {
    if (!Platform.isAndroid || !kEnableEq) return;
    try {
      await eq.setEnabled(_enabled);
      final p = await eq.parameters.timeout(const Duration(milliseconds: 350));
      final n = p.bands.length;
      if (_base.length != n) {
        final old = List<double>.from(_base);
        _base = [for (var i = 0; i < n; i++) sample(old, i, n)];
      }
      for (var i = 0; i < n; i++) {
        final g = (_base[i] + tone(i, n))
            .clamp(p.minDecibels, p.maxDecibels)
            .toDouble();
        await p.bands[i].setGain(g);
      }
    } catch (_) {}
  }

  @override
  State<EqualizerSheet> createState() => _EqualizerSheetState();
}

class _EqualizerSheetState extends State<EqualizerSheet> {
  AndroidEqualizer get eq => widget.eq;
  AndroidEqualizerParameters? _params;
  bool _probing = true;

  @override
  void initState() {
    super.initState();
    _probeParams();
  }

  Future<void> _probeParams() async {
    if (Platform.isAndroid && kEnableEq) {
      try {
        final p = await eq.parameters.timeout(const Duration(milliseconds: 500));
        if (mounted) {
          setState(() {
            _params = p;
            _probing = false;
            final n = p.bands.length;
            if (EqualizerSheet._base.length != n) {
              EqualizerSheet._base = [for (final x in p.bands) x.gain];
            }
          });
          return;
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _probing = false);
  }

  static String _hz(double f) => f >= 1000
      ? '${(f / 1000).toStringAsFixed(f % 1000 == 0 ? 0 : 1)}k'
      : '${f.round()}';

  double _tone(int i, int n) => EqualizerSheet.tone(i, n);

  void _push() {
    final p = _params;
    final n = p != null ? p.bands.length : EqualizerSheet._base.length;
    if (p != null) {
      for (var i = 0; i < n; i++) {
        final g = (EqualizerSheet._base[i] + _tone(i, n))
            .clamp(p.minDecibels, p.maxDecibels)
            .toDouble();
        p.bands[i].setGain(g);
      }
      eq.setEnabled(EqualizerSheet._enabled);
    }
    EqualizerSheet.save();
    setState(() {});
  }

  void _preset(List<double> curve) {
    final n = _params != null ? _params!.bands.length : EqualizerSheet._base.length;
    final maxD = _params?.maxDecibels ?? EqualizerSheet.maxDb;
    EqualizerSheet._base = [
      for (var i = 0; i < n; i++) EqualizerSheet.sample(curve, i, n) * maxD,
    ];
    EqualizerSheet._bass = 0;
    EqualizerSheet._treble = 0;
    _push();
  }

  Widget _toneSlider(
    String label,
    IconData icon,
    double value,
    double minDb,
    double maxDb,
    ValueChanged<double> onChanged,
  ) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.white70),
        const SizedBox(width: 8),
        SizedBox(
          width: 52,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Expanded(
          child: Slider(
            min: minDb,
            max: maxDb,
            value: value.clamp(minDb, maxDb).toDouble(),
            onChanged: (v) {
              onChanged(v);
              _push();
            },
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)} dB',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 11, color: Colors.white60),
          ),
        ),
      ],
    );
  }

  Widget _bandWidget(int i, int n, double freq, double minDb, double maxDb) {
    final baseGain = i < EqualizerSheet._base.length ? EqualizerSheet._base[i] : 0.0;
    final g = (baseGain + _tone(i, n)).clamp(minDb, maxDb).toDouble();

    return Column(
      children: [
        Text(
          '${g >= 0 ? '+' : ''}${g.toStringAsFixed(0)}',
          style: const TextStyle(fontSize: 11),
        ),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: Slider(
              min: minDb,
              max: maxDb,
              value: g,
              onChanged: (v) {
                if (i < EqualizerSheet._base.length) {
                  EqualizerSheet._base[i] = v - _tone(i, n);
                  _push();
                }
              },
            ),
          ),
        ),
        Text(
          _hz(freq),
          style: const TextStyle(fontSize: 11, color: Colors.white60),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid || !kEnableEq) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text('Equalizer Global', style: Theme.of(context).textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Icon(Icons.equalizer_rounded, size: 56, color: Colors.white24),
              const SizedBox(height: 16),
              const Text(
                'Equalizer hanya didukung di platform Android.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      );
    }

    final p = _params;
    final minDb = p?.minDecibels ?? EqualizerSheet.minDb;
    final maxDb = p?.maxDecibels ?? EqualizerSheet.maxDb;
    final bandCount = p != null ? p.bands.length : EqualizerSheet._base.length;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Equalizer Global',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        p != null
                            ? 'Aktif (terhubung ke mesin audio)'
                            : 'Global Preset (otomatis aktif saat lagu diputar)',
                        style: TextStyle(
                          fontSize: 11,
                          color: p != null ? Theme.of(context).colorScheme.primary : Colors.white54,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Switch(
                    value: EqualizerSheet._enabled,
                    onChanged: (v) {
                      EqualizerSheet._enabled = v;
                      eq.setEnabled(v);
                      EqualizerSheet.save();
                      setState(() {});
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final e in EqualizerSheet.presets.entries)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                          label: Text(e.key),
                          onPressed: () => _preset(e.value),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text(
                    'TONE',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white54,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      EqualizerSheet._bass = 0;
                      EqualizerSheet._treble = 0;
                      _push();
                    },
                    child: const Text('Reset tone'),
                  ),
                ],
              ),
              _toneSlider(
                'Bass',
                Icons.graphic_eq_rounded,
                EqualizerSheet._bass,
                minDb,
                maxDb,
                (v) => EqualizerSheet._bass = v,
              ),
              _toneSlider(
                'Treble',
                Icons.surround_sound_rounded,
                EqualizerSheet._treble,
                minDb,
                maxDb,
                (v) => EqualizerSheet._treble = v,
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 230,
                child: Row(
                  children: [
                    for (var i = 0; i < bandCount; i++)
                      Expanded(
                        child: _bandWidget(
                          i,
                          bandCount,
                          p != null ? p.bands[i].centerFrequency : EqualizerSheet.defaultFreqs[i % EqualizerSheet.defaultFreqs.length],
                          minDb,
                          maxDb,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
