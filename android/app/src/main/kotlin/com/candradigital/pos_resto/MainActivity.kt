package com.candradigital.pos_resto

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.SystemClock
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.RandomAccessFile

class MainActivity : FlutterActivity() {
    private val channel = "pos/device"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
