package com.zhylee.discipline.mobile.model

import java.time.Instant
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DisciplineStateTest {
  private val first = Instant.parse("2026-08-20T06:32:18Z")
  private val second = Instant.parse("2026-08-20T06:33:18Z")

  @Test
  fun notificationLayoutMatchesApprovedCopy() {
    val lines = PreviewScenario.RUNNING.snapshot(first)
      .notificationLines(ZoneId.of("Asia/Shanghai"))
    assertEquals("Source: Codex    Status: Running", lines.sourceAndStatus)
    assertEquals("Updated: 14:32:18    2026-08-20", lines.updated)
    assertEquals(listOf("Codex: Running", "DSH: Idle"), lines.sources)
  }

  @Test
  fun offlineIsTransportStateRatherThanSixthTaskState() {
    val offline = PreviewScenario.OFFLINE.snapshot(first)
    assertFalse(offline.transportOnline)
    assertNull(offline.state)
    assertEquals("Offline", offline.statusLabel)
    assertEquals(listOf("Codex: Offline", "DSH: Offline"), offline.notificationLines(ZoneId.of("UTC")).sources)
    assertEquals(5, TaskState.entries.size)
  }

  @Test
  fun onlyApprovedSemanticTransitionsPlaySound() {
    val running = PreviewScenario.RUNNING.snapshot(first)
    val ready = PreviewScenario.READY.snapshot(second)
    val needs = PreviewScenario.NEEDS_INPUT.snapshot(second)
    val blocked = PreviewScenario.BLOCKED.snapshot(second)
    val idle = PreviewScenario.IDLE.snapshot(second)
    val offline = PreviewScenario.OFFLINE.snapshot(second)

    assertFalse(NotificationPolicy.shouldPlaySound(null, ready))
    assertTrue(NotificationPolicy.shouldPlaySound(running, ready))
    assertTrue(NotificationPolicy.shouldPlaySound(running, needs))
    assertTrue(NotificationPolicy.shouldPlaySound(running, blocked))
    assertFalse(NotificationPolicy.shouldPlaySound(running, idle))
    assertFalse(NotificationPolicy.shouldPlaySound(running, offline))
    assertFalse(NotificationPolicy.shouldPlaySound(ready, ready.copy(sourceId = "codex")))
    assertFalse(NotificationPolicy.shouldPlaySound(offline, PreviewScenario.RUNNING.snapshot(second)))
    assertTrue(NotificationPolicy.shouldPlaySound(offline, ready))
  }
}
