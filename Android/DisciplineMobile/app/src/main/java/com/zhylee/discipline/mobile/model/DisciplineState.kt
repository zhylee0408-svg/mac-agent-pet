package com.zhylee.discipline.mobile.model

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

enum class TaskState(val wireValue: String, val displayName: String) {
  BLOCKED("blocked", "Blocked"),
  NEEDS_INPUT("needs_input", "Needs input"),
  RUNNING("running", "Running"),
  READY("ready", "Ready"),
  IDLE("idle", "Idle"),
}

data class SourceSnapshot(
  val id: String,
  val label: String,
  val online: Boolean,
  val status: TaskState?,
) {
  val displayStatus: String
    get() = if (online) status?.displayName ?: "Idle" else "Offline"
}

data class DisciplineSnapshot(
  val transportOnline: Boolean,
  val sourceId: String?,
  val state: TaskState?,
  val sources: List<SourceSnapshot>,
  val updatedAt: Instant,
) {
  val sourceLabel: String
    get() = if (!transportOnline) "—" else sources.firstOrNull { it.id == sourceId }?.label ?: "—"

  val statusLabel: String
    get() = if (transportOnline) state?.displayName ?: TaskState.IDLE.displayName else "Offline"

  fun notificationLines(zoneId: ZoneId): NotificationLines {
    val local = updatedAt.atZone(zoneId)
    return NotificationLines(
      sourceAndStatus = "Source: $sourceLabel    Status: $statusLabel",
      updated = "Updated: ${TIME_FORMAT.format(local)}    ${DATE_FORMAT.format(local)}",
      sources = sources.map { "${it.label}: ${if (transportOnline) it.displayStatus else "Offline"}" },
    )
  }

  companion object {
    private val TIME_FORMAT = DateTimeFormatter.ofPattern("HH:mm:ss")
    private val DATE_FORMAT = DateTimeFormatter.ofPattern("yyyy-MM-dd")
  }
}

data class NotificationLines(
  val sourceAndStatus: String,
  val updated: String,
  val sources: List<String>,
)

enum class PreviewScenario(val label: String) {
  BLOCKED("Blocked"),
  NEEDS_INPUT("Needs input"),
  RUNNING("Running"),
  READY("Ready"),
  IDLE("Idle"),
  OFFLINE("Offline");

  fun snapshot(now: Instant): DisciplineSnapshot = when (this) {
    BLOCKED -> onlineSnapshot(TaskState.BLOCKED, "dsh", TaskState.RUNNING, TaskState.BLOCKED, now)
    NEEDS_INPUT -> onlineSnapshot(TaskState.NEEDS_INPUT, "dsh", TaskState.RUNNING, TaskState.NEEDS_INPUT, now)
    RUNNING -> onlineSnapshot(TaskState.RUNNING, "codex", TaskState.RUNNING, TaskState.IDLE, now)
    READY -> onlineSnapshot(TaskState.READY, "dsh", TaskState.RUNNING, TaskState.READY, now)
    IDLE -> onlineSnapshot(TaskState.IDLE, "codex", TaskState.IDLE, TaskState.IDLE, now)
    OFFLINE -> DisciplineSnapshot(
      transportOnline = false,
      sourceId = null,
      state = null,
      sources = listOf(
        SourceSnapshot("codex", "Codex", false, null),
        SourceSnapshot("dsh", "DSH", false, null),
      ),
      updatedAt = now,
    )
  }

  private fun onlineSnapshot(
    state: TaskState,
    sourceId: String,
    codexState: TaskState,
    dshState: TaskState,
    now: Instant,
  ) = DisciplineSnapshot(
    transportOnline = true,
    sourceId = sourceId,
    state = state,
    sources = listOf(
      SourceSnapshot("codex", "Codex", true, codexState),
      SourceSnapshot("dsh", "DSH", true, dshState),
    ),
    updatedAt = now,
  )
}

object NotificationPolicy {
  private val audibleStates = setOf(TaskState.READY, TaskState.NEEDS_INPUT, TaskState.BLOCKED)

  fun shouldPlaySound(previous: DisciplineSnapshot?, current: DisciplineSnapshot): Boolean {
    if (previous == null || !current.transportOnline) return false
    val currentState = current.state ?: return false
    if (previous.transportOnline && previous.state == currentState) return false
    return currentState in audibleStates
  }
}
