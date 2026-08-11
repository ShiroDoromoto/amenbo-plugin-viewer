package work.amenbo.viewer

import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The Android half of "where did this copy come from".
 *
 * Android remembers which package installed this one, and that is as far as the answer goes: Play
 * installed it, or something else did. **The listing and a testing track are both Play**, with
 * nothing in the record to separate them — so this reports Play and stops there rather than
 * dressing a guess up as an answer.
 *
 * No installing package at all is a build put on the phone by hand, which is what a debug build
 * and anything sideloaded look like. Any other installer is a store this app knows nothing about,
 * and is reported as unknown.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "read" -> result.success(origin())
                    else -> result.notImplemented()
                }
            }
    }

    /** One of the words the Dart side knows. */
    private fun origin(): String {
        val installer =
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    packageManager.getInstallSourceInfo(packageName).installingPackageName
                } else {
                    @Suppress("DEPRECATION")
                    packageManager.getInstallerPackageName(packageName)
                }
            } catch (e: PackageManager.NameNotFoundException) {
                return "unknown"
            } catch (e: IllegalArgumentException) {
                return "unknown"
            }
        return when (installer) {
            PLAY -> "play"
            null -> "none"
            else -> "unknown"
        }
    }

    private companion object {
        const val CHANNEL = "work.amenbo.viewer/build_origin"

        /**
         * Play's own package, which is what an app installed from the store — or from any of its
         * testing tracks — records as its installer.
         */
        const val PLAY = "com.android.vending"
    }
}
