import type { Due } from '../types';

const pad = (n: number) => String(n).padStart(2, '0');

/** YYYY-MM-DD in the browser's own time zone. */
export const isoDate = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;

export const parseIso = (iso: string) => new Date(`${iso}T00:00:00`);

export const todayIso = (now = new Date()) => isoDate(now);

export function addDays(iso: string, n: number): string {
  const d = parseIso(iso);
  d.setDate(d.getDate() + n);
  return isoDate(d);
}

/** The sender's local date and time, as the server's Quick Add wants it: 2026-10-19T14:30. */
export const localNow = (now = new Date()) => `${isoDate(now)}T${pad(now.getHours())}:${pad(now.getMinutes())}`;

/** The coming Monday (never today). */
export function nextMonday(from: string): string {
  const d = parseIso(from);
  const add = ((8 - d.getDay()) % 7) || 7;
  return addDays(from, add);
}

/** "5:00 PM" or "17:00" from a stored HH:MM. */
export function clock(hhmm: string, use24h: boolean): string {
  if (use24h) return hhmm;
  const [h, m] = hhmm.split(':').map(Number);
  return `${h % 12 === 0 ? 12 : h % 12}:${pad(m)} ${h < 12 ? 'AM' : 'PM'}`;
}

/** Today, Tomorrow, Yesterday, a weekday within the week, otherwise "12 Nov" (with the year if it is another one). */
export function dayLabel(iso: string, today = todayIso()): string {
  if (iso === today) return 'Today';
  if (iso === addDays(today, 1)) return 'Tomorrow';
  if (iso === addDays(today, -1)) return 'Yesterday';
  const d = parseIso(iso);
  const diff = Math.round((d.getTime() - parseIso(today).getTime()) / 86400000);
  if (diff > 1 && diff < 7) return d.toLocaleDateString(undefined, { weekday: 'long' });
  const sameYear = d.getFullYear() === parseIso(today).getFullYear();
  return d.toLocaleDateString(undefined, sameYear ? { day: 'numeric', month: 'short' } : { day: 'numeric', month: 'short', year: 'numeric' });
}

export type DueTone = 'overdue' | 'today' | 'tomorrow' | 'soon' | 'later';

/** How urgent a date feels: it picks the colour of its chip. */
export function dueTone(iso: string, today = todayIso()): DueTone {
  if (iso < today) return 'overdue';
  if (iso === today) return 'today';
  if (iso === addDays(today, 1)) return 'tomorrow';
  if (iso <= addDays(today, 6)) return 'soon';
  return 'later';
}

export function dueText(due: Due, use24h = true, today = todayIso()): string {
  return dayLabel(due.date, today) + (due.time ? ` ${clock(due.time, use24h)}` : '');
}

/** "Mon 19 Oct" style heading for a group of tasks on one day. */
export function dayHeading(iso: string, today = todayIso()): { main: string; sub: string } {
  const d = parseIso(iso);
  const rel = dayLabel(iso, today);
  const full = d.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' });
  return rel === 'Today' || rel === 'Tomorrow' ? { main: rel, sub: full } : { main: full, sub: '' };
}

/** The cells of a month grid starting on Monday: 6 weeks of ISO dates. */
export function monthGrid(year: number, month: number): string[] {
  const first = new Date(year, month, 1);
  const offset = (first.getDay() + 6) % 7; // Monday first
  const start = new Date(year, month, 1 - offset);
  return Array.from({ length: 42 }, (_, i) => {
    const d = new Date(start);
    d.setDate(start.getDate() + i);
    return isoDate(d);
  });
}
