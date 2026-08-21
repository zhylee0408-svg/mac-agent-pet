package com.zhylee.discipline.mobile.notification

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.ServiceCompat
import com.zhylee.discipline.mobile.DisciplineApplication
import com.zhylee.discipline.mobile.model.DisciplineSnapshot
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * 常驻前台服务：让 ColorOS 等激进系统不杀进程，并保证后台也能更新状态通知。
 *
 * - 启动时用当前快照 startForeground（特殊用途类型，Android 15 无 6 小时限制）。
 * - 订阅 repository.snapshot，每次状态变化都重新 startForeground → 后台自动换灯。
 * - 通知 ID 与普通状态通知相同（4101），前台通知即状态红绿灯。
 */
class StatusForegroundService : Service() {
  private var collectionJob: Job? = null
  private val notifications by lazy { StatusNotificationManager(this) }

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onCreate() {
    super.onCreate()
    val app = application as DisciplineApplication
    startForegroundStatus(app.repository.snapshot.value)
    collectionJob = app.applicationScope.launch {
      app.repository.snapshot.collect { snapshot ->
        startForegroundStatus(snapshot)
      }
    }
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val app = application as DisciplineApplication
    startForegroundStatus(app.repository.snapshot.value)
    return START_STICKY
  }

  override fun onDestroy() {
    collectionJob?.cancel()
    super.onDestroy()
  }

  private fun startForegroundStatus(snapshot: DisciplineSnapshot) {
    val notification = notifications.build(snapshot, playSound = false, ongoing = true)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
      ServiceCompat.startForeground(
        this,
        StatusNotificationManager.STATUS_NOTIFICATION_ID,
        notification,
        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
      )
    } else {
      startForeground(StatusNotificationManager.STATUS_NOTIFICATION_ID, notification)
    }
  }
}
