#!/usr/bin/env node
// Print this session's color emoji to stdout. Exit 1 if no Claude Code
// session pid found in the process tree.
//
// Walks up from process.ppid looking for a sessions/<pid>.json metadata
// file, then looks up that session's emoji in the session-colors log
// (co-located with this script and hook-session-namer.mjs).

import { execSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const SESSIONS_DIR = join(homedir(), '.claude', 'sessions');
const LOG_PATH = join(__dirname, 'session-colors.log');

function parentPid(pid) {
  try {
    const out = execSync(`ps -p ${pid} -o ppid=`, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    const ppid = Number(out);
    return Number.isFinite(ppid) && ppid > 0 ? ppid : 0;
  } catch {
    return 0;
  }
}

function sessionIdFromPid(pid) {
  const meta = join(SESSIONS_DIR, `${pid}.json`);
  if (!existsSync(meta)) return null;
  try {
    return JSON.parse(readFileSync(meta, 'utf8')).sessionId ?? null;
  } catch {
    return null;
  }
}

function emojiForSession(sessionId) {
  if (!existsSync(LOG_PATH)) return null;
  let last = null;
  for (const line of readFileSync(LOG_PATH, 'utf8').split('\n')) {
    if (!line) continue;
    const [sid, emoji] = line.split('\t');
    if (sid === sessionId && emoji) last = emoji;
  }
  return last;
}

let pid = process.ppid;
while (pid > 1) {
  const sid = sessionIdFromPid(pid);
  if (sid) {
    const emoji = emojiForSession(sid);
    if (emoji) process.stdout.write(emoji + '\n');
    process.exit(0);
  }
  pid = parentPid(pid);
}
process.exit(1);
