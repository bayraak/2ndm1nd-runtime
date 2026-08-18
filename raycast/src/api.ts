// Shared client for the local BrainServer (127.0.0.1:4517).
// The bearer token is written 0600 by the app; we read it directly so there's
// no preference to configure.
import { homedir } from "os";
import { readFileSync } from "fs";
import { join } from "path";

const PORT = 4517;
const TOKEN_PATH = join(homedir(), "Library", "Application Support", "2ndMind", "server-token");

export function baseURL(): string {
  return `http://127.0.0.1:${PORT}`;
}

function token(): string {
  try {
    return readFileSync(TOKEN_PATH, "utf8").trim();
  } catch {
    throw new Error("2ndMind not running (token file missing). Start it: make v2-up");
  }
}

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`${baseURL()}${path}`, {
    headers: { Authorization: `Bearer ${token()}` },
  });
  if (!res.ok) throw new Error(`BrainServer ${res.status}: ${await res.text()}`);
  return (await res.json()) as T;
}

export async function getNow(): Promise<string> {
  const j = await get<{ now: string }>("/now");
  return j.now;
}

export interface Span {
  t0: number;
  t1: number;
  minutes: number;
  activity: string;
  app: string;
  project: string;
}

export async function getSpans(date?: string): Promise<{ day: string; spans: Span[] }> {
  const q = date ? `?date=${date}` : "";
  return get<{ day: string; spans: Span[] }>(`/spans${q}`);
}

export interface SearchHit {
  id: number;
  ts: number;
  source: string;
  kind: string;
  app: string;
  snippet: string;
}

export async function search(q: string, limit = 30): Promise<SearchHit[]> {
  const j = await get<{ results: SearchHit[] }>(`/search?q=${encodeURIComponent(q)}&limit=${limit}`);
  return j.results;
}

export async function ask(question: string): Promise<string> {
  const res = await fetch(`${baseURL()}/ask`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
    body: JSON.stringify({ q: question }),
  });
  if (!res.ok) throw new Error(`BrainServer ${res.status}: ${await res.text()}`);
  const j = (await res.json()) as { answer: string };
  return j.answer;
}

export function fmtTime(ts: number): string {
  return new Date(ts * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}
