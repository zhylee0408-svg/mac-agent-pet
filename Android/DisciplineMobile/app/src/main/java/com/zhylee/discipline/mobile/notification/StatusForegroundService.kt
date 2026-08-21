package com.zhylee.discipline.mobile.notification

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.ServiceCompat
import com.zhylee.discipline.mobile.DisciplineApplication
import com.zhylee.discipline.mobile.model.DisciplineSnapshot
import com.zhylee.discipline.mobile.sync.StatusPollingReceiver
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 常驻前台服务：让 ColorOS 等激进系统不杀进程，并保证后台也能更新状态通知。
 *
 * - 启动时用当前快照 startForeground（特殊用途类型，Android 15 无 6 小时限制）。
 * - 订阅 repository.snapshot，每次状态变化都重新 startForeground → 后台自动换灯。
 * - 每 5 秒向中继「拉」最新状态（拉取制，绕开 ColorOS 的 FCM 后台不投递问题），
 *   拉到的 envelope 走与 FCM 相同的解密/去重/更新路径。
 * - 通知 ID 与普通状态通知相同（4101），前台通知即状态红绿灯。
 */
class StatusForegroundService : Service() {
  private var collectionJob: Job? = null
  private var pollJob: Job? = null
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
    pollJob = app.applicationScope.launch {
      while (true) {
        runCatching {
          val payload = app.pairingManager.fetchLatestState()
          if (payload != null) app.incomingMessages.process("state", payload)
        }
        delay(5_000)
      }
    }
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val app = application as DisciplineApplication
    startForegroundStatus(app.repository.snapshot.value)
    // 闹钟唤醒轮询：即使进程被 ColorOS 冻结，系统闹钟也会叫醒接收器拉取状态。
    StatusPollingReceiver.scheduleNext(this)
    return START_STICKY
  }

  override fun onDestroy() {
    collectionJob?.cancel()
    pollJob?.cancel()
    StatusPollingReceiver.cancel(this)
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
