package com.zhylee.discipline.mobile

import android.app.Application
import android.content.Intent
import androidx.core.content.ContextCompat
import com.zhylee.discipline.mobile.notification.StatusForegroundService
import com.zhylee.discipline.mobile.notification.StatusNotificationManager
import com.zhylee.discipline.mobile.sync.DisciplineStateRepository
import com.zhylee.discipline.mobile.sync.IncomingMessageProcessor
import com.zhylee.discipline.mobile.sync.PairingManager
import com.zhylee.discipline.mobile.sync.SecurePairingStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

class DisciplineApplication : Application() {
  lateinit var pairingStore: SecurePairingStore
    private set
  lateinit var repository: DisciplineStateRepository
    private set
  lateinit var pairingManager: PairingManager
    private set
  lateinit var incomingMessages: IncomingMessageProcessor
    private set
  val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

  override fun onCreate() {
    super.onCreate()
    val notifications = StatusNotificationManager(this).also { it.createChannels() }
    pairingStore = SecurePairingStore(this)
    repository = DisciplineStateRepository(this, pairingStore, notifications)
    pairingManager = PairingManager(this, pairingStore, repository)
    incomingMessages = IncomingMessageProcessor(pairingStore, repository)
  }

  /** 常驻前台服务：进程保活 + 后台通知更新。只能在 App 处于前台时调用。 */
  fun startStatusService() {
    ContextCompat.startForegroundService(this, Intent(this, StatusForegroundService::class.java))
  }

  fun stopStatusService() {
    stopService(Intent(this, StatusForegroundService::class.java))
  }
}
