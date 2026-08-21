package com.zhylee.discipline.mobile.sync

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import com.zhylee.discipline.mobile.DisciplineApplication

/**
 * 闹钟唤醒轮询：ColorOS 的 HANS 会冻结后台进程，协程轮询会随之中断。
 * 改用系统闹钟（exact + allow-while-idle）定时唤醒本接收器，唤醒后拉取最新状态、
 * 更新快照/通知，并调度下一次闹钟。对已在电池白名单的应用，ColorOS 基本放行。
 */
class StatusPollingReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    val pendingResult = goAsync()
    val app = context.applicationContext as DisciplineApplication
    app.applicationScope.launch {
      try {
        val payload = app.pairingManager.fetchLatestState()
        if (payload != null) app.incomingMessages.process("state", payload)
      } finally {
        scheduleNext(context)
        pendingResult.finish()
      }
    }
  }

  companion object {
    private const val POLL_ACTION = "com.zhylee.discipline.mobile.POLL"
    private const val POLL_INTERVAL_MS = 15_000L

    private fun alarmIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
      context,
      0,
      Intent(context, StatusPollingReceiver::class.java).setAction(POLL_ACTION),
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    fun scheduleNext(context: Context) {
      val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
      val triggerAt = SystemClock.elapsedRealtime() + POLL_INTERVAL_MS
      // USE_EXACT_ALARM 已声明（侧载应用自动授予），多数 ColorOS 上可用精确闹钟；
      // 若不可用（canScheduleExactAlarms=false）则退化为 allow-while-idle 非精确闹钟。
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !alarms.canScheduleExactAlarms()) {
        alarms.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, alarmIntent(context))
      } else {
        alarms.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, alarmIntent(context))
      }
    }

    fun cancel(context: Context) {
      val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
      alarms.cancel(alarmIntent(context))
    }
  }
}
