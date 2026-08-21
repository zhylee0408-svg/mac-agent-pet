package com.zhylee.discipline.mobile.sync

import android.annotation.SuppressLint
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.zhylee.discipline.mobile.DisciplineApplication
import kotlinx.coroutines.launch

// The FCM installation-ID API replaces the legacy token callback when
// firebase_messaging_installation_id_enabled is true. Current Android Lint
// still expects onNewToken(), so document and suppress that stale check.
@SuppressLint("MissingFirebaseInstanceTokenRefresh")
class DisciplineMessagingService : FirebaseMessagingService() {
  override fun onMessageReceived(message: RemoteMessage) {
    val application = application as DisciplineApplication
    application.incomingMessages.process(message.data["kind"], message.data["payload"])
  }

  override fun onRegistered(installationId: String) {
    val application = application as DisciplineApplication
    application.applicationScope.launch {
      runCatching { application.pairingManager.updatePushToken(installationId) }
    }
  }
}
