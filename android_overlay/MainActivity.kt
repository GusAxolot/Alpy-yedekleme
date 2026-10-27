package com.alpy.alpy_yedekleme

import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val pool = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null

    private val permListener = Shizuku.OnRequestPermissionResultListener { _, grant ->
        pending?.success(grant == PackageManager.PERMISSION_GRANTED)
        pending = null
    }

    private fun status(): String {
        return try {
            if (!Shizuku.pingBinder() || Shizuku.isPreV11()) "notRunning"
            else if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) "ok"
            else "noPermission"
        } catch (e: Throwable) {
            "notRunning"
        }
    }

    private fun runShell(cmd: String): Map<String, Any> {
        return try {
            val m = Shizuku::class.java.getDeclaredMethod(
                "newProcess",
                Array<String>::class.java, Array<String>::class.java, String::class.java
            )
            m.isAccessible = true
            val p = m.invoke(null, arrayOf("sh", "-c", "($cmd) 2>&1"), null, null) as Process
            val out = p.inputStream.bufferedReader().readText()
            val code = p.waitFor()
            mapOf("code" to code, "out" to out)
        } catch (e: Throwable) {
            mapOf("code" to -1, "out" to e.toString())
        }
    }

    private fun iconBytes(d: Drawable): ByteArray {
        val s = 72
        val bmp = Bitmap.createBitmap(s, s, Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, s, s)
        d.draw(Canvas(bmp))
        val o = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 90, o)
        return o.toByteArray()
    }

    private fun listApps(showSystem: Boolean): List<Map<String, Any?>> {
        val pm = packageManager
        return pm.getInstalledApplications(0).filter {
            val sys = (it.flags and ApplicationInfo.FLAG_SYSTEM) != 0 &&
                (it.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) == 0
            it.packageName != packageName && (showSystem || !sys)
        }.map {
            val sys = (it.flags and ApplicationInfo.FLAG_SYSTEM) != 0 &&
                (it.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) == 0
            val ver = try { pm.getPackageInfo(it.packageName, 0).versionName } catch (e: Throwable) { null }
            mapOf(
                "name" to pm.getApplicationLabel(it).toString(),
                "pkg" to it.packageName,
                "version" to (ver ?: ""),
                "system" to sys,
                "icon" to try { iconBytes(pm.getApplicationIcon(it)) } catch (e: Throwable) { null }
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Shizuku.addRequestPermissionResultListener(permListener)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "alpy/native").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(status())
                "requestPermission" -> {
                    if (status() == "noPermission") {
                        pending = result
                        Shizuku.requestPermission(1001)
                    } else result.success(status() == "ok")
                }
                "openShizuku" -> {
                    packageManager.getLaunchIntentForPackage("moe.shizuku.privileged.api")?.let { startActivity(it) }
                    result.success(null)
                }
                "isInstalled" -> {
                    val ok = try { packageManager.getPackageInfo(call.arguments as String, 0); true } catch (e: Throwable) { false }
                    result.success(ok)
                }
                "shell" -> pool.execute {
                    val r = runShell(call.arguments as String)
                    main.post { result.success(r) }
                }
                "listApps" -> pool.execute {
                    val r = listApps(call.arguments as Boolean)
                    main.post { result.success(r) }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        Shizuku.removeRequestPermissionResultListener(permListener)
        super.onDestroy()
    }
}
