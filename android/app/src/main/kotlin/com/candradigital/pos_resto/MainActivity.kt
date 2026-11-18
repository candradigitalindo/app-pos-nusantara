package com.candradigital.pos_resto

import android.app.ActivityManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.StatFs
import android.os.SystemClock
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile

class MainActivity : FlutterActivity() {
    private val channel = "pos/device"
    private var updateChannel: MethodChannel? = null

    companion object {
        private const val UPDATE_CHANNEL = "pos/app_update"
        private const val ACTION_INSTALL_STATUS = "com.candradigital.pos_resto.INSTALL_STATUS"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Activity bisa dibuat ulang oleh PendingIntent status pemasangan.
        if (handleInstallStatus(intent)) {
            setIntent(Intent(this, MainActivity::class.java).setAction(Intent.ACTION_MAIN))
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleInstallStatus(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        configureAppUpdateChannel(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Penyimpanan internal (bytes) untuk telemetri heartbeat.
                    "storage" -> {
                        try {
                            val stat = StatFs(Environment.getDataDirectory().path)
                            result.success(
                                mapOf("total" to stat.totalBytes, "free" to stat.availableBytes)
                            )
                        } catch (e: Exception) {
                            result.error("STORAGE_ERR", e.message, null)
                        }
                    }
                    // Kondisi CPU & RAM untuk telemetri heartbeat.
                    // Dijalankan di background thread karena %CPU butuh 2x sampling
                    // dengan jeda singkat (TIDAK boleh menahan main thread → ANR).
                    "resources" -> {
                        Thread {
                            // collectResources() tak pernah melempar (semua di-try);
                            // result.success dibungkus try agar aman bila channel/
                            // activity sudah hancur saat callback tiba.
                            val map = try {
                                collectResources()
                            } catch (e: Throwable) {
                                HashMap<String, Any?>()
                            }
                            runOnUiThread {
                                try {
                                    result.success(map)
                                } catch (e: Throwable) {
                                    // channel sudah tidak aktif — abaikan
                                }
                            }
                        }.start()
                    }
                    // Identitas perangkat (model, manufaktur, versi Android).
                    "deviceInfo" -> {
                        result.success(
                            mapOf(
                                "manufacturer" to Build.MANUFACTURER,
                                "model" to Build.MODEL,
                                "android_release" to Build.VERSION.RELEASE,
                                "sdk_int" to Build.VERSION.SDK_INT
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ── Pembaruan dalam-aplikasi ─────────────────────────────────────────────

    private fun configureAppUpdateChannel(flutterEngine: FlutterEngine) {
        updateChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL)
        updateChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // Sudah diizinkan "Instal aplikasi tak dikenal" untuk POS?
                "canInstall" -> result.success(canInstallPackages())
                "openInstallSettings" -> {
                    try {
                        openInstallSettings()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SETTINGS_ERR", e.message, null)
                    }
                }
                "install" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("ARG", "path wajib diisi", null)
                    } else {
                        installApk(path, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun canInstallPackages(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                )
            )
        }
    }

    /// Pasang APK lewat sesi PackageInstaller. Paket dikunci ke aplikasi ini
    /// (setAppPackageName) dan Android sendiri menolak APK bertanda tangan lain,
    /// jadi hanya pembaruan POS yang sah yang bisa terpasang. Penulisan APK
    /// (puluhan MB) di thread latar agar UI tidak macet (ANR).
    private fun installApk(path: String, result: MethodChannel.Result) {
        val file = File(path)
        if (!file.isFile) {
            result.error("NO_FILE", "File pembaruan tidak ditemukan", null)
            return
        }
        Thread {
            try {
                val installer = packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(
                    PackageInstaller.SessionParams.MODE_FULL_INSTALL
                )
                params.setAppPackageName(packageName)
                params.setSize(file.length())
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    // Android 12+: pembaruan diri sendiri boleh tanpa ketukan bila
                    // syarat sistem terpenuhi; bila tidak, Android tetap meminta
                    // konfirmasi (STATUS_PENDING_USER_ACTION).
                    params.setRequireUserAction(
                        PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED
                    )
                }
                val sessionId = installer.createSession(params)
                installer.openSession(sessionId).use { session ->
                    file.inputStream().use { input ->
                        session.openWrite("pos-update.apk", 0, file.length()).use { output ->
                            input.copyTo(output)
                            session.fsync(output)
                        }
                    }
                    val statusIntent = Intent(this, MainActivity::class.java)
                        .setAction(ACTION_INSTALL_STATUS)
                        .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    var flags = PendingIntent.FLAG_UPDATE_CURRENT
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        flags = flags or PendingIntent.FLAG_MUTABLE
                    }
                    val pending = PendingIntent.getActivity(this, sessionId, statusIntent, flags)
                    session.commit(pending.intentSender)
                }
                runOnUiThread {
                    try {
                        result.success("committed")
                    } catch (e: Throwable) {
                        // channel sudah tidak aktif — abaikan
                    }
                }
            } catch (e: Throwable) {
                runOnUiThread {
                    try {
                        result.error("INSTALL_FAILED", e.message ?: e.javaClass.simpleName, null)
                    } catch (ignored: Throwable) {
                    }
                }
            }
        }.start()
    }

    /// Status sesi pemasangan dari sistem. true bila intent memang status
    /// pemasangan (sudah ditangani).
    private fun handleInstallStatus(intent: Intent?): Boolean {
        if (intent == null || intent.action != ACTION_INSTALL_STATUS) return false
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                if (confirm == null) {
                    reportInstall("failure", "Dialog pemasangan Android tidak tersedia")
                } else {
                    try {
                        startActivity(confirm)
                        reportInstall("pending_user_action", null)
                    } catch (e: Exception) {
                        reportInstall("failure", e.message)
                    }
                }
            }
            PackageInstaller.STATUS_SUCCESS -> reportInstall("success", null)
            else -> reportInstall(
                "failure",
                intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
            )
        }
        return true
    }

    private fun reportInstall(status: String, message: String?) {
        try {
            updateChannel?.invokeMethod(
                "installStatus",
                mapOf("status" to status, "message" to message)
            )
        } catch (e: Throwable) {
            // Dart belum siap / channel sudah dilepas — abaikan
        }
    }

    /// Kumpulkan RAM + CPU. RAM selalu ada. %CPU dari selisih dua sampling
    /// (~300ms): utamakan /proc/stat (CPU sistem); bila diblok SELinux, fallback
    /// ke /proc/self/stat (CPU proses app). Semua I/O pakai `use{}` → file selalu
    /// ditutup walau parsing gagal (cegah kebocoran file descriptor).
    private fun collectResources(): HashMap<String, Any?> {
        val map = HashMap<String, Any?>()

        // — RAM (selalu tersedia) —
        try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val mi = ActivityManager.MemoryInfo()
            am.getMemoryInfo(mi)
            map["ram_total"] = mi.totalMem
            map["ram_avail"] = mi.availMem
            map["ram_low"] = mi.lowMemory
        } catch (e: Exception) {
            // field RAM cukup dilewati
        }

        val cores = Runtime.getRuntime().availableProcessors()
        map["cpu_cores"] = cores

        // — %CPU: dua sampling dengan jeda ~300ms —
        val stat1 = readCpuStat()
        val self1 = readSelfJiffies()
        val startMs = SystemClock.elapsedRealtime()
        try {
            Thread.sleep(300)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        val stat2 = readCpuStat()
        val self2 = readSelfJiffies()
        val elapsedMs = SystemClock.elapsedRealtime() - startMs

        if (stat1 != null && stat2 != null) {
            // CPU sistem (paling akurat)
            val dTotal = stat2[0] - stat1[0]
            val dIdle = stat2[1] - stat1[1]
            if (dTotal > 0L) {
                val usage = (dTotal - dIdle).toDouble() / dTotal.toDouble() * 100.0
                map["cpu_used_percent"] = round1(usage.coerceIn(0.0, 100.0))
                map["cpu_source"] = "system"
            }
        } else if (self1 != null && self2 != null && elapsedMs > 0) {
            // Fallback: CPU proses app terhadap kapasitas total (semua core).
            // clock tick Android biasanya 100 Hz (sysconf _SC_CLK_TCK).
            val clkTck = 100.0
            val cpuSeconds = (self2 - self1).toDouble() / clkTck
            val wallSeconds = elapsedMs / 1000.0
            if (wallSeconds > 0 && cores > 0) {
                val usage = cpuSeconds / (wallSeconds * cores) * 100.0
                map["cpu_used_percent"] = round1(usage.coerceIn(0.0, 100.0))
                map["cpu_source"] = "app"
            }
        }

        // — Load average (best-effort) —
        try {
            RandomAccessFile("/proc/loadavg", "r").use { la ->
                val line = la.readLine()
                if (line != null) {
                    val p = line.trim().split(Regex("\\s+"))
                    p.getOrNull(0)?.toDoubleOrNull()?.let { map["load_1m"] = it }
                    p.getOrNull(1)?.toDoubleOrNull()?.let { map["load_5m"] = it }
                    p.getOrNull(2)?.toDoubleOrNull()?.let { map["load_15m"] = it }
                }
            }
        } catch (e: Exception) {
            // lewati
        }

        return map
    }

    /// Baris "cpu ..." dari /proc/stat → [total, idleAll]. null bila diblok/gagal.
    private fun readCpuStat(): LongArray? = try {
        RandomAccessFile("/proc/stat", "r").use { raf ->
            val line = raf.readLine()
            if (line == null || !line.startsWith("cpu")) {
                null
            } else {
                val t = line.trim().split(Regex("\\s+"))
                val user = t.getOrNull(1)?.toLongOrNull() ?: 0L
                val nice = t.getOrNull(2)?.toLongOrNull() ?: 0L
                val system = t.getOrNull(3)?.toLongOrNull() ?: 0L
                val idle = t.getOrNull(4)?.toLongOrNull() ?: 0L
                val iowait = t.getOrNull(5)?.toLongOrNull() ?: 0L
                val irq = t.getOrNull(6)?.toLongOrNull() ?: 0L
                val softirq = t.getOrNull(7)?.toLongOrNull() ?: 0L
                val steal = t.getOrNull(8)?.toLongOrNull() ?: 0L
                val idleAll = idle + iowait
                val total = user + nice + system + idleAll + irq + softirq + steal
                longArrayOf(total, idleAll)
            }
        }
    } catch (e: Exception) {
        null
    }

    /// Jiffies CPU proses ini (utime+stime) dari /proc/self/stat. Selalu terbaca
    /// (proses sendiri). null bila gagal parse.
    private fun readSelfJiffies(): Long? = try {
        RandomAccessFile("/proc/self/stat", "r").use { raf ->
            val line = raf.readLine()
            if (line == null) {
                null
            } else {
                // Nama proses (field 2) dalam tanda kurung & bisa memuat spasi →
                // parse setelah ')' terakhir. Field 14=utime, 15=stime.
                val rparen = line.lastIndexOf(')')
                if (rparen < 0) {
                    null
                } else {
                    val rest = line.substring(rparen + 1).trim().split(Regex("\\s+"))
                    // rest[0]=field 3 (state); utime=field 14→rest[11]; stime=15→rest[12]
                    val utime = rest.getOrNull(11)?.toLongOrNull() ?: 0L
                    val stime = rest.getOrNull(12)?.toLongOrNull() ?: 0L
                    utime + stime
                }
            }
        }
    } catch (e: Exception) {
        null
    }

    private fun round1(v: Double): Double = Math.round(v * 10) / 10.0
}
