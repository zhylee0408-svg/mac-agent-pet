package com.zhylee.discipline.mobile

import android.Manifest
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.zhylee.discipline.mobile.notification.StatusNotificationManager
import com.zhylee.discipline.mobile.theme.DisciplineTheme
import com.zhylee.discipline.mobile.ui.DisciplineScreen
import com.zhylee.discipline.mobile.ui.DisciplineViewModel

class MainActivity : ComponentActivity() {
  private lateinit var statusNotifications: StatusNotificationManager

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    statusNotifications = StatusNotificationManager(this)
    statusNotifications.createChannels()
    enableEdgeToEdge(
      statusBarStyle = SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT),
      navigationBarStyle = SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT),
    )
    setContent {
      DisciplineTheme {
        DisciplineApp(statusNotifications)
      }
    }
  }
}

@Composable
private fun DisciplineApp(statusNotifications: StatusNotificationManager) {
  val context = LocalContext.current
  val lifecycleOwner = LocalLifecycleOwner.current
  val viewModel: DisciplineViewModel = viewModel()
  val snapshot by viewModel.snapshot.collectAsStateWithLifecycle()
  val paired by viewModel.paired.collectAsStateWithLifecycle()
  val pairing by viewModel.pairing.collectAsStateWithLifecycle()
  var notificationsAllowed by remember { mutableStateOf(statusNotifications.notificationsAllowed()) }

  val notificationPermission = rememberLauncherForActivityResult(
    ActivityResultContracts.RequestPermission(),
  ) { granted ->
    notificationsAllowed = granted && statusNotifications.notificationsAllowed()
    if (notificationsAllowed) viewModel.refreshNotification()
  }

  DisposableEffect(lifecycleOwner) {
    val observer = LifecycleEventObserver { _, event ->
      if (event == Lifecycle.Event.ON_RESUME) {
        notificationsAllowed = statusNotifications.notificationsAllowed()
        if (notificationsAllowed) viewModel.refreshNotification()
        // 已配对则确保前台服务在跑（进程保活 + 后台通知更新）。
        if (viewModel.paired.value) {
          (context.applicationContext as DisciplineApplication).startStatusService()
        }
      }
    }
    lifecycleOwner.lifecycle.addObserver(observer)
    onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
  }

  androidx.compose.runtime.LaunchedEffect(Unit) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !notificationsAllowed) {
      notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
  }

  DisciplineScreen(
    paired = paired,
    pairing = pairing,
    snapshot = snapshot,
    notificationsAllowed = notificationsAllowed,
    onPairingCodeChange = viewModel::updatePairingCode,
    onConnect = viewModel::connect,
    onUnpair = viewModel::unpair,
    onPreview = viewModel::preview,
    onNotificationSettings = {
      context.startActivity(statusNotifications.notificationSettingsIntent())
    },
  )
}
