package com.personalagent.jarvis_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 录音期间的前台服务（只保活，不碰音频）。
 *
 * 采集始终在 Flutter 侧由 `record` 持有 AudioRecord；Android 8.0 起后台进程
 * 会被降权，没有前台服务时切后台 / 锁屏后 AudioRecord 会被系统掐断，表现为
 * "锁屏那段时间一个字都没录到"。这里挂一条 microphone 类型的常驻通知，
 * 让进程在后台保持前台优先级。
 *
 * 生命周期由 Dart 侧（`recording_foreground.dart`）在录音开始 / 暂停 / 停止时
 * 显式 startService / stopService，不在原生侧自行启停。
 */
class RecordingForegroundService : Service() {
  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    startForeground(NOTIFICATION_ID, buildNotification())
    // 进程被系统回收后不要自动重建：那时 Flutter 侧已经不存在，服务留着只会
    // 变成"有通知、没在录"的假象。被中断的录音由下次启动的账本恢复接管。
    return START_NOT_STICKY
  }

  override fun onDestroy() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      stopForeground(STOP_FOREGROUND_REMOVE)
    } else {
      @Suppress("DEPRECATION")
      stopForeground(true)
    }
    super.onDestroy()
  }

  private fun buildNotification(): Notification {
    ensureChannel()

    val openApp = Intent(this, MainActivity::class.java).apply {
      flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
    }
    val contentIntent = PendingIntent.getActivity(
      this,
      0,
      openApp,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      Notification.Builder(this, CHANNEL_ID)
    } else {
      @Suppress("DEPRECATION")
      Notification.Builder(this)
    }

    return builder
      .setContentTitle("正在录音")
      .setContentText("录音笔记正在采集音频，锁屏或切后台都不会中断")
      // 系统内置的麦克风图标：通知小图标必须是纯白剪影，用启动图会糊成一团。
      .setSmallIcon(android.R.drawable.ic_btn_speak_now)
      .setContentIntent(contentIntent)
      .setOngoing(true)
      .setShowWhen(false)
      .setCategory(Notification.CATEGORY_SERVICE)
      .build()
  }

  /** 渠道重复创建是空操作，系统不会重复提示；放这里省得漏建导致通知不显示。 */
  private fun ensureChannel() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
      return
    }
    val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    val channel = NotificationChannel(
      CHANNEL_ID,
      "录音笔记",
      NotificationManager.IMPORTANCE_LOW,
    ).apply {
      description = "录音进行中的常驻提示"
      setShowBadge(false)
      enableVibration(false)
      setSound(null, null)
    }
    manager.createNotificationChannel(channel)
  }

  private companion object {
    const val CHANNEL_ID = "recording_foreground"
    const val NOTIFICATION_ID = 0x9A42
  }
}
