package com.personalagent.jarvis_app

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    // 录音保活通道。方法名与参数在两端保持完全一致，平台差异留在原生侧
    // （与 `personal_agent/window` 的同一条约定）。
    MethodChannel(
      flutterEngine.dartExecutor.binaryMessenger,
      CHANNEL,
    ).setMethodCallHandler { call, result ->
      when (call.method) {
        "start" -> {
          startRecordingService()
          result.success(null)
        }
        "stop" -> {
          // stopService 会走到 onDestroy，那里负责撤掉前台通知。
          stopService(Intent(this, RecordingForegroundService::class.java))
          result.success(null)
        }
        else -> result.notImplemented()
      }
    }
  }

  private fun startRecordingService() {
    val intent = Intent(this, RecordingForegroundService::class.java)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      startForegroundService(intent)
    } else {
      startService(intent)
    }
  }

  private companion object {
    const val CHANNEL = "personal_agent/recording_background"
  }
}
