// DSH live-status plugin (方案 A)
//
// Subscribes to DSH session events and writes a status file that the
// Discipline pet (macOS 桌宠) polls:
//   $DSH_HOME/live-status.json   (default ~/.dsh/live-status.json)
//
// The file carries:
//   state      — idle | running | needs | ready | blocked (aggregated across sessions)
//   detail     — one-line state description (pet detail row)
//   diagnostic — source-level granularity (turn number, approval counts)
//   updatedAt  — last session EVENT time (ms): "recent activity"
//   heartbeatAt— last plugin WRITE time (ms): "plugin alive"
//
// The pet treats `heartbeatAt` freshness as "DSH online" and `updatedAt`
// freshness as "DSH working", which lets it distinguish a live-but-idle DSH
// from a stopped one, and drive activity-preemption vs Codex.
//
// Install: copy to <profile>/live-status.mjs and add a patch row:
//   - insert:
//       - id: live-status
//         name: './live-status.mjs'
//         config: {}
// Restart dsh afterwards (profile rows load at boot).

import { writeFile, rename, mkdir } from "node:fs/promises";
import { writeFileSync, renameSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";

export const name = "dsh-live-status";
export const inject = [];

// ── constants ────────────────────────────────────────────────────────────
const ACTIVE_RECENT_MS = 30 * 60_000; // running/needs considered recent
const HEARTBEAT_INTERVAL_MS = 5_000;  // rewrite even when idle
// ready / blocked 的停留时长改为可配置（config.readyWindowMs / config.blockedWindowMs），
// 默认 20s / 30s —— 太短容易错过，太长会掩盖下一个 turn 的开始。

// Event types that can change the derived state (file writes happen on these
// only; lastEventAt still refreshes on every event).
const STATE_EVENTS = new Set([
  "session",
  "turn/start",
  "turn/end",
  "approval/asked",
  "approval/decided"
]);

const ERROR_REASONS = new Set([
  "error",
  "aborted",
  "interrupted",
  "halted",
  "failed",
  "rejected",
  "blocked",
  "cancelled",
  "max-tokens"
]);

function defaultStatusPath() {
  const home = process.env.DSH_HOME ?? join(homedir(), ".dsh");
  return join(home, "live-status.json");
}

// 停机标记：DSH 进程退出（SIGINT/SIGTERM/exit）前同步写入，把 heartbeatAt 置 0。
// 桌宠下一次轮询即判定 DSH 离线并丢弃其最后状态——Ctrl+C 退出不会被显示成 blocked。
// 注意：这是进程级「临终标记」，不区分 Stop/Ctrl+C 的事件——点 Stop 时进程没死，
// 本函数不会触发，blocked 照常显示；Ctrl+C 时进程要死，本函数举手说「我没了」。
function writeShutdownMarker(statusPath) {
  try {
    mkdirSync(dirname(statusPath), { recursive: true });
    const marker = {
      source: "dsh",
      state: "idle",
      detail: "DSH stopped",
      diagnostic: "",
      updatedAt: Date.now(),
      heartbeatAt: 0, // 关键：0 → 桌宠判定心跳过期 → DSH 离线
      sessions: []
    };
    const tmp = `${statusPath}.tmp`;
    writeFileSync(tmp, JSON.stringify(marker, null, 2));
    renameSync(tmp, statusPath);
  } catch (err) {
    /* 尽力而为：写失败不影响退出；桌宠会靠 30s 心跳过期兜底 */
  }
}

function blankSession(id) {
  return {
    id,
    state: "idle",
    stateAt: 0,
    lastEventAt: 0,
    turn: 0,
    pendingApproval: false
  };
}

export function apply(ctx, config) {
  // Cordis 协议：config 作为第二个参数传入，不能读 ctx.config（需显式 inject）。
  const statusPath = config?.path ?? defaultStatusPath();
  const readyWindowMs = config?.readyWindowMs ?? 60_000; // 绿色 ready 停留时长（默认 60s，config 可改）
  // blocked 是「粘住」状态：不因时间过期，直到恢复事件（turn/start / approval/asked / 新 session）才切换。
  const sessions = new Map(); // sessionId -> session state row
  let lastEventTime = 0;      // most recent event across all sessions
  let writeChain = Promise.resolve();

  function onEvent(session, event) {
    const id = session?.id;
    if (!id) return;
    const time = typeof event.time === "number" ? event.time : Date.now();
    if (time > lastEventTime) lastEventTime = time;

    const s = sessions.get(id) ?? blankSession(id);
    s.lastEventAt = time;

    let changed = false;
    switch (event.type) {
      case "session":
        s.state = "idle";
        s.stateAt = time;
        s.turn = 0;
        s.pendingApproval = false;
        changed = true;
        break;
      case "turn/start":
        if (typeof event.data?.turn === "number") s.turn = event.data.turn;
        s.state = "running";
        s.stateAt = time;
        changed = true;
        break;
      case "approval/asked":
        s.pendingApproval = true;
        s.state = "needs";
        s.stateAt = time;
        changed = true;
        break;
      case "approval/decided":
        s.pendingApproval = false;
        if (s.state === "needs") {
          s.state = "running";
          s.stateAt = time;
          changed = true;
        }
        break;
      case "turn/end": {
        const kind = event.data?.reason?.kind;
        if (kind === "completed") {
          s.state = "ready";
        } else if (typeof kind === "string" && ERROR_REASONS.has(kind)) {
          s.state = "blocked";
        } else {
          s.state = "idle";
        }
        s.stateAt = time;
        changed = true;
        break;
      }
      default:
        break;
    }

    sessions.set(id, s);
    if (changed) scheduleWrite();
  }

  function effectiveState() {
    const now = Date.now();
    const rows = [];
    let needs = null, blocked = null, active = null, ready = null;
    let needsCount = 0, runningCount = 0, maxTurn = 0, maxActiveTurn = 0;

    for (const s of sessions.values()) {
      const age = now - s.stateAt;
      const recent = now - s.lastEventAt < ACTIVE_RECENT_MS;
      let eff = s.state;
      if (s.state === "ready" && age > readyWindowMs) eff = "idle";
      // blocked：粘住，不因时间过期；只有恢复事件（turn/start 等）才切换
      if ((s.state === "running" || s.state === "needs") && !recent) eff = "idle";

      rows.push({
        id: s.id,
        state: eff,
        stateAt: s.stateAt,
        lastEventAt: s.lastEventAt,
        turn: s.turn,
        pendingApproval: s.pendingApproval
      });

      if (eff === "needs") {
        needsCount += 1;
        maxTurn = Math.max(maxTurn, s.turn);
        if (needs === null) needs = s;
      } else if (eff === "running") {
        runningCount += 1;
        maxActiveTurn = Math.max(maxActiveTurn, s.turn);
        if (active === null) active = s;
      } else if (eff === "blocked" && blocked === null) {
        blocked = s;
        maxTurn = Math.max(maxTurn, s.turn);
      } else if (eff === "ready" && ready === null) {
        ready = s;
        maxTurn = Math.max(maxTurn, s.turn);
      }
    }

    let state = "idle";
    let detail = "No active tasks";
    let diagnostic = "";

    if (needs !== null) {
      state = "needs";
      detail = needsCount === 1 ? "A task needs input" : `${needsCount} tasks need input`;
      diagnostic = `turn ${maxTurn} · ${needsCount} approval pending`;
    } else if (blocked !== null) {
      state = "blocked";
      detail = "A turn errored";
      diagnostic = `turn ${maxTurn} errored`;
    } else if (active !== null) {
      state = "running";
      detail = runningCount === 1 ? "1 turn running" : `${runningCount} turns running`;
      diagnostic = `turn ${maxActiveTurn} · ${runningCount} turn${runningCount > 1 ? "s" : ""} active`;
    } else if (ready !== null) {
      state = "ready";
      detail = "A turn completed";
      diagnostic = `turn ${maxTurn} completed`;
    }

    return {
      source: "dsh",
      state,
      detail,
      diagnostic,
      updatedAt: lastEventTime,
      heartbeatAt: now,
      sessions: rows
    };
  }

  async function doWrite() {
    try {
      const payload = JSON.stringify(effectiveState(), null, 2);
      await mkdir(dirname(statusPath), { recursive: true });
      const tmp = `${statusPath}.tmp`;
      await writeFile(tmp, payload);
      await rename(tmp, statusPath);
    } catch (err) {
      // Non-fatal: the pet sees a stale/absent file and falls back to Codex.
    }
  }

  function scheduleWrite() {
    writeChain = writeChain.then(doWrite).catch(() => {});
  }

  ctx.on("session/event", onEvent);
  const timer = setInterval(scheduleWrite, HEARTBEAT_INTERVAL_MS);

  // 进程退出信号 → 写停机标记（尽力而为；kill -9 捕获不到时靠桌宠侧 30s 心跳过期兜底）
  const onShutdown = () => writeShutdownMarker(statusPath);
  process.once("SIGINT", onShutdown);
  process.once("SIGTERM", onShutdown);
  process.once("exit", onShutdown);

  return () => {
    clearInterval(timer);
    process.removeListener("SIGINT", onShutdown);
    process.removeListener("SIGTERM", onShutdown);
    process.removeListener("exit", onShutdown);
  };
}
