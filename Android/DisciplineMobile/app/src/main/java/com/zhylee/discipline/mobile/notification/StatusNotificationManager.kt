package com.zhylee.discipline.mobile.notification

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.provider.Settings
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.zhylee.discipline.mobile.MainActivity
import com.zhylee.discipline.mobile.R
import com.zhylee.discipline.mobile.model.DisciplineSnapshot
import com.zhylee.discipline.mobile.model.TaskState
import java.time.ZoneId

class StatusNotificationManager(private val context: Context) {
  private val manager = NotificationManagerCompat.from(context)

  fun createChannels() {
    val systemManager = context.getSystemService(NotificationManager::class.java)
    val silent = NotificationChannel(
      SILENT_CHANNEL,
      context.getString(R.string.notification_channel_status),
      NotificationManager.IMPORTANCE_LOW,
    ).apply {
      description = context.getString(R.string.notification_channel_status_description)
      setSound(null, null)
      enableVibration(false)
      setShowBadge(false)
    }
    val alerts = NotificationChannel(
      ALERT_CHANNEL,
      context.getString(R.string.notification_channel_alerts),
      NotificationManager.IMPORTANCE_DEFAULT,
    ).apply {
      description = context.getString(R.string.notification_channel_alerts_description)
      setSound(
        RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
        AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).build(),
      )
      enableVibration(false)
      vibrationPattern = null
      setShowBadge(false)
    }
    systemManager.createNotificationChannels(listOf(silent, alerts))
    // Preview builds briefly used one notification ID per state. Remove those
    // stale records once after an in-place upgrade; all current states use 4101.
    LEGACY_NOTIFICATION_IDS.forEach(manager::cancel)
  }

  fun notificationsAllowed(): Boolean {
    if (!manager.areNotificationsEnabled()) return false
    return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
      ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
  }

  fun cancel() {
    manager.cancel(STATUS_NOTIFICATION_ID)
  }

  fun build(snapshot: DisciplineSnapshot, playSound: Boolean, ongoing: Boolean = false): Notification {
    val channel = if (playSound) ALERT_CHANNEL else SILENT_CHANNEL
    val icon = smallIcon(snapshot)
    val compact = remoteView(R.layout.notification_compact, snapshot, expanded = false)
    val expanded = remoteView(R.layout.notification_expanded, snapshot, expanded = true)
    val openApp = PendingIntent.getActivity(
      context,
      0,
      Intent(context, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
      },
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    val lines = snapshot.notificationLines(ZoneId.systemDefault())
    return NotificationCompat.Builder(context, channel)
      .setSmallIcon(icon)
      .setColor(stateColor(snapshot))
      .setContentTitle(context.getString(R.string.app_name))
      .setContentText(lines.sourceAndStatus)
      .setSubText(lines.updated)
      .setCustomContentView(compact)
      .setCustomBigContentView(expanded)
      .setStyle(NotificationCompat.DecoratedCustomViewStyle())
      .setContentIntent(openApp)
      .setCategory(NotificationCompat.CATEGORY_STATUS)
      .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
      .setPriority(if (playSound) NotificationCompat.PRIORITY_DEFAULT else NotificationCompat.PRIORITY_LOW)
      .setSilent(!playSound)
      .setOnlyAlertOnce(!playSound)
      .setAutoCancel(false)
      .setOngoing(ongoing)
      .setShowWhen(false)
      .build()
  }

  fun show(snapshot: DisciplineSnapshot, playSound: Boolean) {
    if (!notificationsAllowed()) return
    val notification = build(snapshot, playSound)
    notification.flags = notification.flags and Notification.FLAG_ONGOING_EVENT.inv()
    if (
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
      ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
      PackageManager.PERMISSION_GRANTED
    ) {
      return
    }
    try {
      manager.notify(STATUS_NOTIFICATION_ID, notification)
    } catch (_: SecurityException) {
      // Permission can be revoked between the explicit check and this call.
    }
  }

  fun notificationSettingsIntent(): Intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
    putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
  }

  private fun remoteView(layout: Int, snapshot: DisciplineSnapshot, expanded: Boolean): RemoteViews {
    val lines = snapshot.notificationLines(ZoneId.systemDefault())
    return RemoteViews(context.packageName, layout).apply {
      setTextViewText(R.id.notification_title, styledTitle(snapshot))
      setTextViewText(R.id.notification_source_status, lines.sourceAndStatus)
      setTextViewText(R.id.notification_updated, lines.updated)
      if (expanded) {
        setTextViewText(R.id.notification_codex, lines.sources.getOrElse(0) { "Codex: Offline" })
        setTextViewText(R.id.notification_dsh, lines.sources.getOrElse(1) { "DSH: Offline" })
      }
    }
  }

  private fun styledTitle(snapshot: DisciplineSnapshot): CharSequence {
    val symbol = if (snapshot.transportOnline) "●  Discipline" else "◌  Discipline"
    return SpannableString(symbol).apply {
      setSpan(
        ForegroundColorSpan(stateColor(snapshot)),
        0,
        1,
        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
      )
    }
  }

  private fun smallIcon(snapshot: DisciplineSnapshot): Int {
    if (!snapshot.transportOnline) return R.drawable.ic_status_offline
    return when (snapshot.state) {
      TaskState.BLOCKED -> R.drawable.ic_status_blocked
      TaskState.NEEDS_INPUT -> R.drawable.ic_status_needs_input
      TaskState.RUNNING -> R.drawable.ic_status_running
      TaskState.READY -> R.drawable.ic_status_ready
      TaskState.IDLE, null -> R.drawable.ic_status_idle
    }
  }

  private fun stateColor(snapshot: DisciplineSnapshot): Int {
    if (!snapshot.transportOnline) return COLOR_OFFLINE
    return when (snapshot.state) {
      TaskState.BLOCKED -> COLOR_BLOCKED
      TaskState.NEEDS_INPUT -> COLOR_NEEDS_INPUT
      TaskState.RUNNING -> COLOR_RUNNING
      TaskState.READY -> COLOR_READY
      TaskState.IDLE, null -> COLOR_IDLE
    }
  }

  companion object {
    const val STATUS_NOTIFICATION_ID = 4101
    private val LEGACY_NOTIFICATION_IDS = 4102..4106
    const val SILENT_CHANNEL = "discipline_status_silent_v1"
    const val ALERT_CHANNEL = "discipline_status_alerts_v1"

    const val COLOR_BLOCKED = 0xFFFF4D5E.toInt()
    const val COLOR_NEEDS_INPUT = 0xFFFFC247.toInt()
    const val COLOR_RUNNING = 0xFF3D8BFF.toInt()
    const val COLOR_READY = 0xFF37D67A.toInt()
    const val COLOR_IDLE = 0xFF9097A6.toInt()
    const val COLOR_OFFLINE = 0xFF5F6570.toInt()
  }
}
