/**
 * Device Memory Extension
 *
 * Appends one JSONL line per ended session to `~/.pi/agent/memories.txt`.
 *
 * - session_start: nudges the agent (via a non-interrupting steer) to read
 *   AGENTS.md/SOUL.md (identity/instructions) and memories.txt (memory) for
 *   context, and notifies the user that memory is loaded. No write.
 * - session_shutdown (on quit / new / fork): appends a single JSON line to
 *   memories.txt noting the session ended, how many turns happened, and the
 *   first line of the last assistant message as a hint of what was done.
 *
 * Substantive notes (decisions, preferences, setup changes) are appended
 * during the session by the agent itself, per ~/.pi/agent/AGENTS.md. This hook
 * is a safety net so an exit record is always captured — and because it's a
 * pure append (no read-modify-write), it can't corrupt past entries.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { homedir } from "node:os";
import { join } from "node:path";
import { appendFile } from "node:fs/promises";

const MEMORIES_FILE = join(homedir(), ".pi", "agent", "memories.txt");

function dateStamp(): string {
  return new Date().toISOString().slice(0, 10); // YYYY-MM-DD
}

function lastAssistantHint(entries: any[]): string {
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    if (entry?.type === "message" && entry.message?.role === "assistant") {
      const content = entry.message.content;
      const text = Array.isArray(content)
        ? content
            .filter((c): c is { type: "text"; text: string } => c?.type === "text")
            .map((c) => c.text)
            .join("\n")
            .trim()
        : typeof content === "string"
          ? content.trim()
          : "";
      const first = text.split("\n").find((l) => l.trim().length > 0) ?? "";
      return first.slice(0, 120);
    }
  }
  return "";
}

function countTurns(entries: any[]): number {
  let turns = 0;
  for (const entry of entries) {
    if (entry?.type === "message" && entry.message?.role === "user") turns++;
  }
  return turns;
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async (event, ctx) => {
    // Only nudge on fresh starts / resumes, not on every reload.
    if (ctx.hasUI) {
      ctx.ui.notify("🫐 memories.txt loaded — catch me up if anything changed", "info");
    }
    // Steer the agent to keep memory in mind this turn. Non-interrupting.
    if (event.reason === "startup" || event.reason === "resume" || event.reason === "new") {
      pi.sendMessage(
        {
          customType: "device.memory.reminder",
          content:
            "[memory] Session started. Read ~/.pi/agent/SOUL.md (identity) and ~/.pi/agent/memories.txt (append-only memory log) for context. If something worth keeping happens this session (decisions, new setup, preferences, resolved TODOs), append one JSON line to memories.txt — never edit old lines.",
          display: false,
        },
        { triggerTurn: false, deliverAs: "nextTurn" }
      );
    }
  });

  pi.on("session_shutdown", async (event, ctx) => {
    // Don't log on reload (no real exit) or on resume-to-another (handled by
    // that session). Log on quit, new, fork.
    const reason = event.reason;
    if (reason !== "quit" && reason !== "new" && reason !== "fork") return;

    let turns = 0;
    let hint = "";
    try {
      const entries = ctx.sessionManager.getEntries();
      turns = countTurns(entries);
      hint = lastAssistantHint(entries);
    } catch {
      // ignore — best effort
    }

    const record = {
      date: dateStamp(),
      reason,
      turns,
      last: hint || null,
    };
    const line = JSON.stringify(record) + "\n";

    try {
      await appendFile(MEMORIES_FILE, line, "utf8");
      if (ctx.hasUI) {
        ctx.ui.notify("🫐 memories.txt appended on exit", "info");
      }
    } catch (err) {
      if (ctx.hasUI) {
        ctx.ui.notify(`🫐 memory append failed: ${String(err)}`, "warning");
      }
    }
  });
}
