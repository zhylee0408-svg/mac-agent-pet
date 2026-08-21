package com.zhylee.discipline.mobile.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.zhylee.discipline.mobile.model.DisciplineSnapshot
import com.zhylee.discipline.mobile.model.PreviewScenario
import com.zhylee.discipline.mobile.model.SourceSnapshot
import com.zhylee.discipline.mobile.model.TaskState
import com.zhylee.discipline.mobile.theme.DisciplineTheme
import java.time.Instant
import java.time.ZoneId

@Composable
fun DisciplineScreen(
  paired: Boolean,
  pairing: PairingUiState,
  snapshot: DisciplineSnapshot,
  notificationsAllowed: Boolean,
  onPairingCodeChange: (String) -> Unit,
  onConnect: () -> Unit,
  onUnpair: () -> Unit,
  onPreview: (PreviewScenario) -> Unit,
  onNotificationSettings: () -> Unit,
  modifier: Modifier = Modifier,
) {
  if (!paired) {
    PairingScreen(
      pairing = pairing,
      onPairingCodeChange = onPairingCodeChange,
      onConnect = onConnect,
      modifier = modifier,
    )
    return
  }

  var showUnpairMessage by remember { mutableStateOf(false) }
  Surface(modifier = modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
    LazyColumn(
      modifier = Modifier.safeDrawingPadding().fillMaxSize(),
      contentPadding = androidx.compose.foundation.layout.PaddingValues(20.dp),
      verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
      item { Header(snapshot) }
      item { LampPanel(snapshot) }
      if (!notificationsAllowed) {
        item { NotificationPermissionCard(onNotificationSettings) }
      }
      pairing.error?.let { message -> item { ErrorCard(message) } }
      item { StatusDetails(snapshot) }
      item { SourceDetails(snapshot) }
      item {
        ActionButtons(
          onNotificationSettings = onNotificationSettings,
          onUnpair = { showUnpairMessage = true },
        )
      }
      item { PreviewControls(snapshot, onPreview) }
      item {
        Text(
          text = "End-to-end encrypted · No task content is collected",
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          style = MaterialTheme.typography.labelSmall,
          modifier = Modifier.fillMaxWidth(),
          textAlign = TextAlign.Center,
        )
      }
    }
  }

  if (showUnpairMessage) {
    AlertDialog(
      onDismissRequest = { showUnpairMessage = false },
      title = { Text("Unpair this Mac?") },
      text = { Text("This phone will stop receiving status updates and will need a new pairing code to reconnect.") },
      confirmButton = {
        TextButton(onClick = {
          showUnpairMessage = false
          onUnpair()
        }) { Text("Unpair") }
      },
      dismissButton = {
        TextButton(onClick = { showUnpairMessage = false }) { Text("Cancel") }
      },
    )
  }
}

@Composable
private fun PairingScreen(
  pairing: PairingUiState,
  onPairingCodeChange: (String) -> Unit,
  onConnect: () -> Unit,
  modifier: Modifier = Modifier,
) {
  Surface(modifier = modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
    Column(
      modifier = Modifier.safeDrawingPadding().fillMaxSize().padding(28.dp),
      verticalArrangement = Arrangement.Center,
      horizontalAlignment = Alignment.CenterHorizontally,
    ) {
      Text(
        text = "DISCIPLINE",
        color = MaterialTheme.colorScheme.onBackground,
        fontWeight = FontWeight.Black,
        fontSize = 30.sp,
        letterSpacing = 2.sp,
      )
      Spacer(Modifier.height(8.dp))
      Text(
        text = "Paste the five-minute pairing code from your Mac.",
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.Center,
      )
      Spacer(Modifier.height(28.dp))
      OutlinedTextField(
        value = pairing.code,
        onValueChange = onPairingCodeChange,
        modifier = Modifier.fillMaxWidth(),
        label = { Text("Pairing code") },
        placeholder = { Text("discipline://pair?…") },
        singleLine = true,
        enabled = !pairing.connecting,
      )
      pairing.error?.let { message ->
        Spacer(Modifier.height(10.dp))
        Text(
          text = message,
          color = MaterialTheme.colorScheme.error,
          style = MaterialTheme.typography.bodySmall,
          modifier = Modifier.fillMaxWidth(),
        )
      }
      Spacer(Modifier.height(18.dp))
      Button(
        onClick = onConnect,
        enabled = pairing.code.isNotBlank() && !pairing.connecting,
        modifier = Modifier.fillMaxWidth().height(52.dp),
      ) {
        if (pairing.connecting) {
          CircularProgressIndicator(
            modifier = Modifier.size(20.dp),
            strokeWidth = 2.dp,
            color = MaterialTheme.colorScheme.onPrimary,
          )
        } else {
          Text("Connect")
        }
      }
    }
  }
}

@Composable
private fun Header(snapshot: DisciplineSnapshot) {
  Row(
    modifier = Modifier.fillMaxWidth(),
    horizontalArrangement = Arrangement.SpaceBetween,
    verticalAlignment = Alignment.CenterVertically,
  ) {
    Column {
      Text(
        text = "DISCIPLINE",
        color = MaterialTheme.colorScheme.onBackground,
        fontWeight = FontWeight.Black,
        fontSize = 26.sp,
        letterSpacing = 2.sp,
      )
      Text(
        text = "Mobile status",
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        style = MaterialTheme.typography.bodyMedium,
      )
    }
    Row(
      modifier = Modifier
        .clip(RoundedCornerShape(100.dp))
        .background(MaterialTheme.colorScheme.surfaceVariant)
        .padding(horizontal = 12.dp, vertical = 8.dp),
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
      Box(
        Modifier
          .size(8.dp)
          .clip(CircleShape)
          .background(if (snapshot.transportOnline) ReadyColor else OfflineColor),
      )
      Text(
        text = if (snapshot.transportOnline) "Connected" else "Disconnected",
        color = MaterialTheme.colorScheme.onSurface,
        style = MaterialTheme.typography.labelLarge,
      )
    }
  }
}

@Composable
private fun LampPanel(snapshot: DisciplineSnapshot) {
  Card(
    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    shape = RoundedCornerShape(28.dp),
    modifier = Modifier.fillMaxWidth(),
  ) {
    Column(
      modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 24.dp),
      horizontalAlignment = Alignment.CenterHorizontally,
    ) {
      Text(
        text = snapshot.statusLabel.uppercase(),
        color = if (snapshot.transportOnline) snapshot.state.statusColor() else OfflineColor,
        style = MaterialTheme.typography.labelLarge,
        fontWeight = FontWeight.Bold,
        letterSpacing = 1.5.sp,
      )
      Spacer(Modifier.height(20.dp))
      Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
        TaskState.entries.forEach { state ->
          StatusLamp(state, active = snapshot.transportOnline && snapshot.state == state)
        }
      }
    }
  }
}

@Composable
private fun StatusLamp(state: TaskState, active: Boolean) {
  val color = state.statusColor()
  Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(horizontal = 2.dp)) {
    Canvas(
      modifier = Modifier
        .size(52.dp)
        .semantics { contentDescription = "${state.displayName}, ${if (active) "active" else "inactive"}" },
    ) {
      if (active) {
        drawCircle(color.copy(alpha = 0.10f), radius = size.minDimension * 0.50f)
        drawCircle(color.copy(alpha = 0.22f), radius = size.minDimension * 0.39f)
        drawCircle(color, radius = size.minDimension * 0.27f)
        drawCircle(Color.White.copy(alpha = 0.45f), radius = size.minDimension * 0.08f, center = center.copy(x = center.x - 5.dp.toPx(), y = center.y - 5.dp.toPx()))
      } else {
        drawCircle(color.copy(alpha = 0.09f), radius = size.minDimension * 0.28f)
        drawCircle(color.copy(alpha = 0.30f), radius = size.minDimension * 0.28f, style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.dp.toPx()))
      }
    }
    Text(
      text = when (state) {
        TaskState.NEEDS_INPUT -> "Needs"
        else -> state.displayName
      },
      color = if (active) color else MaterialTheme.colorScheme.onSurfaceVariant,
      fontSize = 10.sp,
      textAlign = TextAlign.Center,
      maxLines = 1,
    )
  }
}

@Composable
private fun NotificationPermissionCard(onNotificationSettings: () -> Unit) {
  Card(
    colors = CardDefaults.cardColors(containerColor = NeedsColor.copy(alpha = 0.11f)),
    shape = RoundedCornerShape(20.dp),
  ) {
    Row(
      modifier = Modifier.fillMaxWidth().padding(16.dp),
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
      Text("!", color = NeedsColor, fontWeight = FontWeight.Black, fontSize = 22.sp)
      Text(
        "Notifications are off. Enable them to test the status-bar light.",
        modifier = Modifier.weight(1f),
        color = MaterialTheme.colorScheme.onSurface,
      )
      TextButton(onClick = onNotificationSettings) { Text("Open") }
    }
  }
}

@Composable
private fun ErrorCard(message: String) {
  Card(
    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
    shape = RoundedCornerShape(20.dp),
  ) {
    Text(
      text = message,
      color = MaterialTheme.colorScheme.onErrorContainer,
      modifier = Modifier.fillMaxWidth().padding(16.dp),
    )
  }
}

@Composable
private fun StatusDetails(snapshot: DisciplineSnapshot) {
  val lines = snapshot.notificationLines(ZoneId.systemDefault())
  InfoCard(title = "Current status") {
    DetailRow("Source", snapshot.sourceLabel)
    DetailRow("Status", snapshot.statusLabel, if (snapshot.transportOnline) snapshot.state.statusColor() else OfflineColor)
    DetailRow("Updated", lines.updated.removePrefix("Updated: "))
  }
}

@Composable
private fun SourceDetails(snapshot: DisciplineSnapshot) {
  InfoCard(title = "Sources") {
    snapshot.sources.forEachIndexed { index, source ->
      SourceRow(source, snapshot.transportOnline)
      if (index != snapshot.sources.lastIndex) {
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.45f))
      }
    }
  }
}

@Composable
private fun InfoCard(title: String, content: @Composable () -> Unit) {
  Card(
    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    shape = RoundedCornerShape(24.dp),
    modifier = Modifier.fillMaxWidth(),
  ) {
    Column(modifier = Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(13.dp)) {
      Text(title, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelLarge)
      content()
    }
  }
}

@Composable
private fun DetailRow(label: String, value: String, valueColor: Color = MaterialTheme.colorScheme.onSurface) {
  Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
    Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Text(value, color = valueColor, fontWeight = FontWeight.SemiBold)
  }
}

@Composable
private fun SourceRow(source: SourceSnapshot, transportOnline: Boolean) {
  val online = transportOnline && source.online
  val color = if (online) source.status.statusColor() else OfflineColor
  Row(
    modifier = Modifier.fillMaxWidth(),
    horizontalArrangement = Arrangement.SpaceBetween,
    verticalAlignment = Alignment.CenterVertically,
  ) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
      Box(Modifier.size(8.dp).clip(CircleShape).background(color))
      Text(source.label, color = MaterialTheme.colorScheme.onSurface, fontWeight = FontWeight.Medium)
    }
    Text(if (online) source.displayStatus else "Offline", color = color, fontWeight = FontWeight.SemiBold)
  }
}

@Composable
private fun ActionButtons(onNotificationSettings: () -> Unit, onUnpair: () -> Unit) {
  Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
    OutlinedButton(onClick = onNotificationSettings, modifier = Modifier.weight(1f)) {
      Text("Notification Settings")
    }
    Button(onClick = onUnpair) { Text("Unpair") }
  }
}

@Composable
private fun PreviewControls(snapshot: DisciplineSnapshot, onPreview: (PreviewScenario) -> Unit) {
  Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
    Text("PREVIEW STATE", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelSmall, letterSpacing = 1.2.sp)
    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
      items(PreviewScenario.entries, key = { it.name }) { scenario ->
        val selected = if (scenario == PreviewScenario.OFFLINE) {
          !snapshot.transportOnline
        } else {
          snapshot.transportOnline && snapshot.state?.displayName == scenario.label
        }
        AssistChip(
          onClick = { onPreview(scenario) },
          label = { Text(scenario.label) },
          leadingIcon = {
            Box(
              Modifier
                .size(if (selected) 9.dp else 7.dp)
                .clip(CircleShape)
                .background(if (scenario == PreviewScenario.OFFLINE) OfflineColor else scenario.taskState().statusColor()),
            )
          },
        )
      }
    }
  }
}

private fun PreviewScenario.taskState(): TaskState? = when (this) {
  PreviewScenario.BLOCKED -> TaskState.BLOCKED
  PreviewScenario.NEEDS_INPUT -> TaskState.NEEDS_INPUT
  PreviewScenario.RUNNING -> TaskState.RUNNING
  PreviewScenario.READY -> TaskState.READY
  PreviewScenario.IDLE -> TaskState.IDLE
  PreviewScenario.OFFLINE -> null
}

@Composable
private fun TaskState?.statusColor(): Color = when (this) {
  TaskState.BLOCKED -> BlockedColor
  TaskState.NEEDS_INPUT -> NeedsColor
  TaskState.RUNNING -> RunningColor
  TaskState.READY -> ReadyColor
  TaskState.IDLE -> IdleColor
  null -> OfflineColor
}

private val BlockedColor = Color(0xFFFF4D5E)
private val NeedsColor = Color(0xFFFFC247)
private val RunningColor = Color(0xFF3D8BFF)
private val ReadyColor = Color(0xFF37D67A)
private val IdleColor = Color(0xFF9097A6)
private val OfflineColor = Color(0xFF5F6570)

@Preview(showBackground = true, backgroundColor = 0xFF090A0D)
@Composable
private fun RunningPreview() {
  DisciplineTheme {
    DisciplineScreen(
      paired = true,
      pairing = PairingUiState(),
      snapshot = PreviewScenario.RUNNING.snapshot(Instant.parse("2026-08-20T06:32:18Z")),
      notificationsAllowed = true,
      onPairingCodeChange = {},
      onConnect = {},
      onUnpair = {},
      onPreview = {},
      onNotificationSettings = {},
    )
  }
}

@Preview(showBackground = true, backgroundColor = 0xFF090A0D)
@Composable
private fun OfflinePreview() {
  DisciplineTheme {
    DisciplineScreen(
      paired = true,
      pairing = PairingUiState(),
      snapshot = PreviewScenario.OFFLINE.snapshot(Instant.parse("2026-08-20T06:32:18Z")),
      notificationsAllowed = true,
      onPairingCodeChange = {},
      onConnect = {},
      onUnpair = {},
      onPreview = {},
      onNotificationSettings = {},
    )
  }
}
