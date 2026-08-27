#!/usr/bin/env node
/**
 * tgbridge — Telegram <-> pi agent bridge (TypeScript port of tgbridge.py)
 *
 * Pure Node (>=24, native TS type-stripping). No npm dependencies.
 *
 * Flow:
 *   getUpdates (long poll) -> allowed chat? -> spawn `pi -p --no-session`
 *   with the message as prompt -> reply via sendMessage (split at 4000).
 *
 * Config: ~/.pi/agent/tg.json
 *   { "token": "...", "allowed": [12345, 45678] }
 *   Unknown chats get logged to tg-pending.log and told they're not listed.
 *
 * Kindness rules (900 MiB Pi):
 *   - One pi process in flight; further messages queued in memory.
 *   - Lockfile (O_EXCL) so only one bridge runs.
 */
import { appendFileSync, existsSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import dns from "node:dns";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

// Happy-eyeballs (family autoselection) times out at 250ms — far too short for
// this slow Pi: it prefers unreachable IPv6 then fails the whole connect.
try {
  net.setDefaultAutoSelectFamily?.(false);
  dns.setDefaultResultOrder("ipv4first"); // no working IPv6 here
} catch {
  /* older node */
}

// ---------- paths / constants ----------
const AGENT = path.join(os.homedir(), ".pi", "agent");
const CONFIG = path.join(AGENT, "tg.json");
const LOG = path.join(AGENT, "tg.log");
const PENDING = path.join(AGENT, "tg-pending.log");
const LOCK = path.join(AGENT, "tgbridge.lock");
const HISTORY = path.join(AGENT, "tg-history.jsonl");

const PI_BIN =
  process.env.PI_BIN ?? path.join(os.homedir(), ".local/share/mise/installs/node/lts/bin/pi");

const API = (token: string, method: string) => `https://api.telegram.org/bot${token}/${method}`;
const POLL_TIMEOUT_S = 60;
const PI_TIMEOUT_MS = 600_000; // full agent session on a small Pi needs headroom
const MAX_MSG = 4000; // telegram hard limit 4096
const HISTORY_MAX = 20;

type TgConfig = { token: string; allowed: number[] };
type TgUpdate = { update_id: number; message?: TgMessage };
type TgMessage = { chat: { id: number }; from?: { first_name?: string }; text?: string };

// local time like the python version did (YYYY-MM-DD HH:MM:SS)
function log(msg: string): void {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  const ts = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  try {
    appendFileSync(LOG, `[${ts}] ${msg}\n`);
  } catch {
    /* best effort */
  }
}

function loadConfig(): TgConfig {
  if (!existsSync(CONFIG)) {
    console.error(`FATAL: no config at ${CONFIG}`);
    process.exit(1);
  }
  return JSON.parse(readFileSync(CONFIG, "utf8")) as TgConfig;
}

async function tg(token: string, method: string, params: Record<string, unknown> = {}): Promise<any> {
  const body = new URLSearchParams(Object.entries(params).map(([k, v]) => [k, String(v)]));
  const timeoutMs = method === "getUpdates" ? (POLL_TIMEOUT_S + 10) * 1000 : 30_000;
  const res = await fetch(API(token, method), {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
    signal: AbortSignal.timeout(timeoutMs),
  });
  const out = await res.json();
  if (!out.ok) log(`API error ${method}: ${JSON.stringify(out)}`);
  return out;
}

async function send(cfg: TgConfig, chatId: number, text: string): Promise<void> {
  for (let i = 0; i < text.length; i += MAX_MSG) {
    try {
      await tg(cfg.token, "sendMessage", { chat_id: chatId, text: text.slice(i, i + MAX_MSG) });
    } catch (e) {
      log(`sendMessage failed: ${e}`);
    }
  }
}

// ---------- rolling chat history ----------
function historyTail(): Array<{ ts: string; role: string; name: string; text: string }> {
  try {
    return readFileSync(HISTORY, "utf8")
      .split("\n")
      .filter((l) => l.trim())
      .slice(-HISTORY_MAX)
      .map((l) => JSON.parse(l));
  } catch {
    return [];
  }
}

function historyAppend(role: string, name: string, text: string): void {
  try {
    const old = historyTail().slice(-(HISTORY_MAX - 1));
    const entry = {
      ts: new Date().toISOString().replace("T", " ").slice(0, 16),
      role,
      name,
      text: text.slice(0, 400),
    };
    const lines = [...old.map((e) => JSON.stringify(e)), JSON.stringify(entry)];
    writeFileSync(HISTORY, lines.join("\n") + "\n");
  } catch (e) {
    log(`history write failed: ${e}`);
  }
}

// ---------- pi ----------
function stamp(): string {
  return new Date().toISOString().replace(/[-:T]/g, "").slice(0, 15); // YYYYMMDD-HHMMSS
}

function runPi(prompt: string): string {
  const hist = historyTail();
  let ctx = "";
  if (hist.length > 0) {
    ctx =
      "[Recent Telegram chat history, oldest first - use for context; " +
      "the last message is the human's new one.]\n" +
      hist.map((h) => `${h.ts} ${h.name} (${h.role}): ${h.text}`).join("\n") +
      "\n[End of history]\n\n";
  }
  const proc = spawnSync(PI_BIN, ["-p", "--no-session", "--name", `tg-${stamp()}`, ctx + prompt], {
    encoding: "utf8",
    timeout: PI_TIMEOUT_MS,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      PATH: `${path.dirname(PI_BIN)}:${process.env.PATH ?? ""}`,
    },
  });
  if (proc.error && (proc.error as NodeJS.ErrnoException).code === "ETIMEDOUT") {
    throw new Error("timeout");
  }
  const out = (proc.stdout ?? "").trim() || (proc.stderr ?? "").trim() || "(no output)";
  return out;
}

// ---------- dashboard status hook ----------
function dashStatus(text: string, severity: string = "info"): void {
  try {
    spawnSync(
      "python3",
      [path.join(import.meta.dirname ?? ".", "dash.py"), "status", `text=${text}`, `status=${severity}`],
      { timeout: 10_000, stdio: "ignore" },
    );
  } catch {
    /* dashboard is best-effort */
  }
}

// ---------- handling ----------
interface HandleState {
  cfg: TgConfig;
  refreshAllowed: () => number[];
}

async function handle(st: HandleState, msg: TgMessage): Promise<void> {
  const chatId = msg.chat.id;
  const name = msg.from?.first_name ?? "?";
  const text = (msg.text ?? "").trim();
  if (!text) return;

  log(`MSG ${chatId} ${name}: ${text.slice(0, 120)}`);
  const allowed = st.refreshAllowed().includes(chatId);
  if (allowed) historyAppend("user", name, text);

  if (!allowed) {
    try {
      appendFileSync(PENDING, `${new Date().toISOString()} ${chatId} ${name}: ${text.slice(0, 80)}\n`);
    } catch {}
    log(`  DENIED chat ${chatId} (${name}) - logged to pending`);
    await send(
      st.cfg,
      chatId,
      "Hi! I'm a private agent. This chat isn't on my allowlist yet — ask my human to add you.",
    );
    return;
  }

  const lower = text.split(" ")[0]!.toLowerCase();
  if (text.startsWith("/")) {
    if (lower === "/start" || lower === "/help") {
      await send(
        st.cfg,
        chatId,
        "Hi! 🫐 Send me anything and I'll think about it with a full pi session. One message at a time, please — I'm a little Pi.",
      );
      return;
    }
    if (lower === "/ping") {
      await send(st.cfg, chatId, "pong 🫐");
      return;
    }
    // other slash commands fall through to pi as normal prompts
  }

  dashStatus(`${name} via Telegram: ${text.slice(0, 55)}`, "info");
  let reply: string;
  try {
    reply = runPi(text);
  } catch (e: any) {
    log(`  pi error: ${e?.message ?? e}`);
    dashStatus("Telegram reply failed", "warn");
    const reason = e?.message === "timeout";
    await send(
      st.cfg,
      chatId,
      reason ? "I timed out thinking about that (600s). Try again?" : `Something broke on my end: ${e?.message ?? e}`,
    );
    return;
  }

  log(`REPLY ${chatId}: ${reply.slice(0, 120)}`);
  historyAppend("assistant", name === "?" ? "Agent" : "Agent", reply);
  await send(st.cfg, chatId, reply);
}

// ---------- main loop ----------
async function main(): Promise<void> {
  // single instance via O_EXCL lockfile + pid
  if (existsSync(LOCK)) {
    try {
      const pid = parseInt(readFileSync(LOCK, "utf8").trim(), 10);
      process.kill(pid, 0); // still alive?
      console.log("tgbridge already running");
      process.exit(0);
    } catch {
      rmSync(LOCK); // stale lock
    }
  }
  try {
    writeFileSync(LOCK, String(process.pid), { flag: "wx" });
  } catch {
    console.log("tgbridge already running");
    process.exit(0);
  }
  for (const sig of ["exit", "SIGINT", "SIGTERM"] as const) {
    process.on(sig, () => {
      try {
        rmSync(LOCK);
      } catch {}
      if (sig !== "exit") process.exit(0);
    });
  }

  const cfg = loadConfig();
  log("tgbridge starting (long poll)");
  let offset: number | undefined;
  const queue: TgMessage[] = [];

  const st: HandleState = {
    cfg,
    refreshAllowed: () => {
      try {
        return (JSON.parse(readFileSync(CONFIG, "utf8")) as TgConfig).allowed ?? [];
      } catch {
        return [];
      }
    },
  };

  while (true) {
    let updates: TgUpdate[] = [];
    try {
      const params: Record<string, unknown> = { timeout: POLL_TIMEOUT_S, allowed_updates: JSON.stringify(["message"]) };
      if (offset !== undefined) params.offset = offset;
      const out = await tg(cfg.token, "getUpdates", params);
      updates = out.result ?? [];
    } catch (e) {
      log(`getUpdates error: ${e} - backing off 10s`);
      await new Promise((r) => setTimeout(r, 10_000));
      continue;
    }

    for (const upd of updates) {
      offset = upd.update_id + 1;
      if (upd.message) queue.push(upd.message);
    }

    while (queue.length > 0) {
      const msg = queue.shift()!;
      try {
        await handle(st, msg);
      } catch (e) {
        log(`handle error: ${e}`);
      }
    }
  }
}

// Don't auto-run when imported (allows smoke tests / embedding);
// only runs when executed directly.
if (!process.env.TGBRIDGE_NO_MAIN) main();
