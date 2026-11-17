package com.example.yt_audio

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import com.ryanheise.audioservice.AudioServiceActivity
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import com.yausername.youtubedl_android.YoutubeDLResponse
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Collections
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private val channelName = "yt_audio/ytdlp"
    private val pool = Executors.newCachedThreadPool()
    private val ui = Handler(Looper.getMainLooper())
    private lateinit var channel: MethodChannel

    // ── Konfigurasi anti-blokir ─────────────────────────────────────
    // Client dicoba berurutan sampai ada yang lolos. "default" = pilihan yt-dlp sendiri.
    // Daftar client yang awet berubah-ubah; cek wiki yt-dlp (extractor-args YouTube).
    private val clients = listOf("default", "android_vr", "tv", "mweb")

    // Client yang terakhir berhasil, dicoba duluan di request berikutnya.
    @Volatile private var lastGood: String? = null

    // Proxy khusus yt-dlp (bukan seluruh HP). Contoh WARP mode proxy:
    // "socks5://127.0.0.1:40000". Biarkan null kalau tidak dipakai.
    private val proxy: String? = null

    // Path cookies.txt (opsional, pakai akun cadangan!). Contoh:
    // "${filesDir.absolutePath}/cookies.txt"
    private val cookiesPath: String? = null

    // Format video untuk mode "play dengan video": maks 480p, mp4 (h264+aac,
    // digabung ffmpeg tanpa encode ulang). Fallback ke itag 18 (360p, sudah gabungan).
    // Ubah angka 480 kalau mau lebih tajam/lebih hemat kuota.
    private val videoFormat =
        "bv*[height<=480][ext=mp4]+ba[ext=m4a]/b[height<=480][ext=mp4]/18"

    // id lagu yang dibatalkan user -> jangan lanjut coba client lain.
    private val cancelled: MutableSet<String> =
        Collections.synchronizedSet(mutableSetOf())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> background(result) {
                    YoutubeDL.getInstance().init(applicationContext)
                    // ffmpeg dibutuhkan untuk konversi (mp3/flac/wav/opus).
                    // Kalau gagal, unduhan format asli tetap jalan.
                    try {
                        FFmpeg.getInstance().init(applicationContext)
                    } catch (e: Throwable) {
                        Log.d("YT", "ffmpeg init gagal: ${e.message}")
                    }
                    Log.d("YT", "yt-dlp version: " +
                        YoutubeDL.getInstance().version(applicationContext))
                    true
                }
                "update" -> background(result) {
                    // NIGHTLY lebih cepat mengikuti perubahan YouTube daripada STABLE.
                    val status = YoutubeDL.getInstance()
                        .updateYoutubeDL(applicationContext, YoutubeDL.UpdateChannel.NIGHTLY)
                    Log.d("YT", "update status: $status, version: " +
                        YoutubeDL.getInstance().version(applicationContext))
                    status?.toString() ?: "sudah terbaru"
                }
                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath == null) {
                        result.error("INVALID_PATH", "Path APK tidak valid", null)
                    } else {
                        try {
                            val apkFile = File(filePath)
                            if (!apkFile.exists()) {
                                result.error("FILE_NOT_FOUND", "File APK tidak ditemukan", null)
                            } else {
                                val uri: Uri = FileProvider.getUriForFile(
                                    applicationContext,
                                    "${applicationContext.packageName}.fileprovider",
                                    apkFile
                                )
                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, "application/vnd.android.package-archive")
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                applicationContext.startActivity(intent)
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            Log.e("YT", "Gagal install APK: ${e.message}", e)
                            result.error("INSTALL_FAILED", e.message, null)
                        }
                    }
                }
                "search" -> {
                    val q = call.argument<String>("query") ?: ""
                    val n = call.argument<Int>("count") ?: 12
                    val start = call.argument<Int>("start") ?: 1
                    background(result) { search(q, n, start) }
                }
                "download" -> {
                    val url = call.argument<String>("url") ?: ""
                    val dir = call.argument<String>("dir") ?: ""
                    val id = call.argument<String>("id") ?: ""
                    val format = call.argument<String>("format") // null/"original" = tanpa konversi
                    background(result) { download(url, dir, id, format) }
                }
                // Hanya dipakai kalau kStream = true di Dart.
                "streamUrl" -> {
                    val url = call.argument<String>("url") ?: ""
                    background(result) { streamUrl(url) }
                }
                // Salin file ke Music/Compo lewat MediaStore (aman untuk Android 10+).
                "export" -> {
                    val path = call.argument<String>("path") ?: ""
                    val name = call.argument<String>("name") ?: ""
                    background(result) { exportToMusic(path, name) }
                }
                "cancel" -> {
                    val id = call.argument<String>("id") ?: ""
                    cancelled.add(id)
                    try {
                        YoutubeDL.getInstance().destroyProcessById(id)
                    } catch (e: Throwable) {
                        Log.d("YT", "cancel gagal: ${e.message}")
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        pool.execute {
            try {
                val r = block()
                ui.post { result.success(r) }
            } catch (e: Throwable) {
                ui.post { result.error("ytdlp", e.message ?: e.toString(), null) }
            }
        }
    }

    // ── Ekspor ke folder Music (MediaStore) ─────────────────────────

    private fun exportToMusic(path: String, rawName: String): String {
        val src = File(path)
        if (!src.exists()) throw Exception("File sumber tidak ada")

        // MediaStore menolak "audio/webm". Isi .webm dari yt-dlp adalah audio Opus,
        // jadi diekspor sebagai .opus (audio/ogg) -- pemutar membaca isi file, bukan ekstensi.
        val name = if (rawName.lowercase().endsWith(".webm"))
            rawName.dropLast(5) + ".opus" else rawName

        val ext = name.substringAfterLast('.', "").lowercase()
        val mime = when (ext) {
            "mp3" -> "audio/mpeg"
            "opus", "ogg" -> "audio/ogg"
            "m4a" -> "audio/mp4"
            "flac" -> "audio/flac"
            "wav" -> "audio/x-wav"
            "mp4" -> "audio/mp4"
            else -> "audio/*"
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "Music/Compo")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw Exception("MediaStore insert gagal")
            try {
                resolver.openOutputStream(uri)!!.use { out ->
                    src.inputStream().use { it.copyTo(out) }
                }
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Throwable) {
                // Jangan tinggalkan entri setengah jadi.
                try { resolver.delete(uri, null, null) } catch (_: Throwable) {}
                throw e
            }
        } else {
            // Android 9 ke bawah: tulis langsung (butuh WRITE_EXTERNAL_STORAGE di manifest).
            @Suppress("DEPRECATION")
            val dir = File(
                android.os.Environment.getExternalStoragePublicDirectory(
                    android.os.Environment.DIRECTORY_MUSIC
                ),
                "Compo"
            )
            dir.mkdirs()
            src.copyTo(File(dir, name), overwrite = true)
        }
        return "OK"
    }

    // ── Inti anti-blokir ────────────────────────────────────────────

    private fun orderedClients(): List<String> {
        val g = lastGood
        return if (g != null && g in clients) listOf(g) + clients.filter { it != g } else clients
    }

    /**
     * Jalankan request hasil [build] dengan tiap client sampai ada yang berhasil.
     * [build] dipanggil ulang per percobaan karena YoutubeDLRequest tidak bisa dipakai ulang.
     */
    private fun runWithFallback(
        build: () -> YoutubeDLRequest,
        processId: String? = null,
        onProgress: ((Float) -> Unit)? = null,
    ): YoutubeDLResponse {
        val errors = mutableListOf<String>()
        for (client in orderedClients()) {
            if (processId != null && cancelled.contains(processId)) {
                throw Exception("Dibatalkan")
            }
            val req = build()
            if (client != "default") {
                req.addOption("--extractor-args", "youtube:player_client=$client")
            }
            proxy?.let { req.addOption("--proxy", it) }
            cookiesPath?.let { if (File(it).exists()) req.addOption("--cookies", it) }
            req.addOption("--socket-timeout", "15")
            req.addOption("--retries", "2")
            try {
                val res = if (processId != null && onProgress != null) {
                    YoutubeDL.getInstance().execute(req, processId) { p, _, _ -> onProgress(p) }
                } else {
                    YoutubeDL.getInstance().execute(req)
                }
                lastGood = client
                Log.d("YT", "berhasil dengan client=$client")
                return res
            } catch (e: Throwable) {
                if (processId != null && cancelled.contains(processId)) {
                    throw Exception("Dibatalkan")
                }
                val msg = shorten(e.message)
                Log.d("YT", "client=$client gagal: $msg")
                errors.add("[$client] $msg")
            }
        }
        throw Exception(explain(errors))
    }

    // Ambil baris ERROR terakhir dari stderr yt-dlp.
    private fun shorten(m: String?): String {
        val lines = (m ?: "").lines().filter { it.isNotBlank() }
        val s = lines.lastOrNull { it.contains("ERROR") } ?: lines.lastOrNull() ?: "tidak ada pesan"
        return if (s.length > 200) s.take(200) + "…" else s
    }

    // Ubah error mentah jadi petunjuk yang gampang dibaca di layar.
    private fun explain(errors: List<String>): String {
        val all = errors.joinToString("\n")
        val hint = when {
            all.contains("not a bot", true) || all.contains("Sign in", true) ->
                "IP kena flag bot. Pakai proxy/WARP atau cookies."
            all.contains("429") -> "HTTP 429: terlalu banyak request, tunggu atau ganti IP."
            all.contains("403") -> "HTTP 403: ditolak YouTube (IP/client)."
            all.contains("not available", true) || all.contains("challenge", true) ->
                "Format/JS challenge gagal. Update yt-dlp (tombol update) & library."
            else -> "Gagal, semua client sudah dicoba."
        }
        return "$hint\n$all"
    }

    // ── Operasi yt-dlp ──────────────────────────────────────────────

    // Cari di YouTube; hasilnya JSON mentah, diurai di Dart.
    // [count] = nomor hasil terakhir, [start] = nomor hasil pertama (untuk "muat lagi").
    private fun search(query: String, count: Int, start: Int = 1): String =
        runWithFallback({
            YoutubeDLRequest("ytsearch$count:$query").apply {
                if (start > 1) addOption("--playlist-items", "$start-$count")
                addOption("--flat-playlist")
                addOption("--dump-single-json")
                addOption("--no-warnings")
            }
        }).out

    // URL audio langsung (tanpa mengunduh) untuk streaming.
    private fun streamUrl(url: String): String =
        runWithFallback({
            YoutubeDLRequest(url).apply {
                addOption("--no-playlist")
                addOption("-f", "ba[ext=webm]/ba")
                addOption("-g")
                addOption("--no-warnings")
            }
        }).out.trim()

    // Unduh audio ke [dir] dan kirim progress ke Dart. Mengembalikan path file.
    private fun download(url: String, dir: String, id: String, format: String?): String {
        File(dir).mkdirs()
        cancelled.remove(id)
        val video = format == "video"
        runWithFallback({
            YoutubeDLRequest(url).apply {
                addOption("--no-playlist")
                if (video) {
                    addOption("-f", videoFormat)
                    addOption("--merge-output-format", "mp4")
                } else {
                    addOption("-f", "ba[ext=webm]/ba")
                }
                addOption("-o", "$dir/%(title).100B [%(id)s].%(ext)s")
                if (!video && format != null && format != "original") {
                    addOption("-x")
                    addOption("--audio-format", format) // opus | mp3 | flac | wav
                    if (format == "mp3") addOption("--audio-quality", "0")
                }
            }
        }, id) { progress ->
            ui.post {
                channel.invokeMethod(
                    "progress",
                    mapOf("id" to id, "progress" to progress.toDouble())
                )
            }
        }
        val file = File(dir).listFiles()
            ?.filter { it.name.contains("[$id]") && !it.name.endsWith(".part") }
            ?.maxByOrNull { it.lastModified() }
            ?: throw Exception("File hasil tidak ditemukan")
        return file.absolutePath
    }
}