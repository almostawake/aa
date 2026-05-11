#!/usr/bin/env node
// UserPromptSubmit hook: assigns a color emoji and decorates session title.
//
// Two paths:
//
//   1. Prompt starts with "#"  → explicit naming on the first prompt of a
//      session. Pick color, log it, set sessionTitle to the stripped prompt,
//      tell the LLM (via additionalContext) to acknowledge briefly.
//
//   2. Prompt doesn't start with "#" → auto-decorate path.
//      First prompt: pick color and log it (so my-color works immediately),
//      but don't set sessionTitle yet — we wait for Claude Code's auto-titler.
//      Next prompt: read the auto-generated `name` from
//      ~/.claude/sessions/<pid>.json and decorate it using the logged color.
//
// Color is the one in POOL not used in the most recent (POOL.length - 1)
// log entries globally, so consecutive sessions look distinct.

import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const POOL = ['🟦', '🟩', '🟧', '🟪', '🟥', '🟨'];
const LOG_PATH = join(__dirname, 'session-colors.log');
const SESSIONS_DIR = join(homedir(), '.claude', 'sessions');

async function main() {
  let input = '';
  process.stdin.setEncoding('utf8');
  for await (const chunk of process.stdin) input += chunk;

  let evt;
  try {
    evt = JSON.parse(input);
  } catch {
    return;
  }

  const prompt = String(evt.prompt ?? '').trim();
  const sessionId = String(evt.session_id ?? evt.sessionId ?? '');
  if (!prompt || !sessionId) return;

  const entries = readLog();
  const existing = entries.find(([id]) => id === sessionId);
  const isHash = prompt.startsWith('#');

  if (isHash) {
    if (existing) return;
    const title = prompt.replace(/^#+\s*/, '').trim();
    if (!title) return;
    const pick = pickColor(entries);
    logEntry(sessionId, pick);
    emit({
      sessionTitle: `${pick} ${title.toUpperCase()} ${pick}`,
      additionalContext:
        '[session-namer] The user prompt was a "#"-prefixed session-naming gesture, not a task. ' +
        'Respond with one short line acknowledging the name (e.g. "Named — what would you like to work on?") and stop. ' +
        'Do not interpret the title as a request for work.',
    });
    return;
  }

  if (!existing) {
    const pick = pickColor(entries);
    logEntry(sessionId, pick);
    return;
  }

  const [, emoji] = existing;
  const meta = findSessionMeta(sessionId);
  const name = String(meta?.name ?? '').trim();
  if (name && POOL.some((e) => name.startsWith(e))) return;
  const baseTitle = name || readLatestAiTitle(sessionId);
  if (!baseTitle) return;
  emit({ sessionTitle: `${emoji} ${baseTitle.toUpperCase()} ${emoji}` });
}

function readLog() {
  const raw = existsSync(LOG_PATH) ? readFileSync(LOG_PATH, 'utf8') : '';
  return raw
    .split('\n')
    .filter(Boolean)
    .map((l) => l.split('\t'));
}

function pickColor(entries) {
  // Hard-exclude colors held by currently-alive sessions so concurrent sessions
  // never collide. If every color is taken (>=POOL.length live), fall through
  // to the full pool.
  const activeColors = activeSessionColors(entries);
  const candidates = POOL.filter((e) => !activeColors.has(e));
  const pool = candidates.length > 0 ? candidates : POOL;

  // LRU within candidates: never-picked first, else oldest log timestamp.
  const lastUse = new Map();
  for (const [, emoji, ts] of entries) lastUse.set(emoji, ts);
  return pool.slice().sort((a, b) => {
    const ta = lastUse.get(a);
    const tb = lastUse.get(b);
    if (!ta && !tb) return 0;
    if (!ta) return -1;
    if (!tb) return 1;
    return ta.localeCompare(tb);
  })[0];
}

function activeSessionColors(entries) {
  const active = new Set();
  try {
    const colorBySid = new Map(entries.map(([sid, e]) => [sid, e]));
    const files = readdirSync(SESSIONS_DIR).filter((f) => f.endsWith('.json'));
    for (const f of files) {
      try {
        const meta = JSON.parse(readFileSync(join(SESSIONS_DIR, f), 'utf8'));
        const e = colorBySid.get(meta.sessionId);
        if (e) active.add(e);
      } catch {}
    }
  } catch {}
  return active;
}

function logEntry(sessionId, emoji) {
  mkdirSync(dirname(LOG_PATH), { recursive: true });
  appendFileSync(
    LOG_PATH,
    `${sessionId}\t${emoji}\t${new Date().toISOString()}\n`,
  );
}

function emit(hookSpecificOutput) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: { hookEventName: 'UserPromptSubmit', ...hookSpecificOutput },
    }),
  );
}

function findSessionMeta(sessionId) {
  try {
    const files = readdirSync(SESSIONS_DIR).filter((f) => f.endsWith('.json'));
    for (const f of files) {
      try {
        const meta = JSON.parse(readFileSync(join(SESSIONS_DIR, f), 'utf8'));
        if (meta.sessionId === sessionId) return meta;
      } catch {}
    }
  } catch {}
  return null;
}

function readLatestAiTitle(sessionId) {
  try {
    const projectsDir = join(homedir(), '.claude', 'projects');
    const dirs = readdirSync(projectsDir);
    for (const d of dirs) {
      const p = join(projectsDir, d, sessionId + '.jsonl');
      if (!existsSync(p)) continue;
      const lines = readFileSync(p, 'utf8').split('\n').filter(Boolean);
      let latest = '';
      for (const l of lines) {
        try {
          const obj = JSON.parse(l);
          if (obj.type === 'ai-title' && obj.aiTitle) {
            latest = String(obj.aiTitle).trim();
          }
        } catch {}
      }
      return latest;
    }
  } catch {}
  return '';
}

main().catch(() => {});
