/**
 * The rules of the calendar views (Day, 3 Days, Month) as plain functions. This is the same logic as
 * packages/taskflow_core/lib/time_grid.dart, with the same test cases, so every device behaves the same.
 * Change both together.
 */
import { addDays, isoDate, parseIso } from './dates';

export const MINUTES_PER_DAY = 1440;
/** A task with a time but no length is drawn this long. */
export const DEFAULT_BLOCK = 30;
/** Blocks are never drawn shorter than this. */
export const MIN_BLOCK = 15;
/** Moving and resizing snap to this. */
export const SNAP = 15;

/** `week` is for wide screens (web and desktop); phones show day, three and month. */
export type CalendarMode = 'day' | 'three' | 'week' | 'month';

/** "09:30" to 570; null for anything else. */
export function minutesOf(hhmm: string | null | undefined): number | null {
  const m = /^(\d{1,2}):(\d{2})$/.exec(hhmm ?? '');
  if (!m) return null;
  const h = Number(m[1]);
  const min = Number(m[2]);
  return h < 24 && min < 60 ? h * 60 + min : null;
}

/** 570 to "09:30" (1440 and over give the last minute of the day, never "24:00"). */
export function formatMinutes(minutes: number): string {
  const m = Math.min(Math.max(minutes, 0), MINUTES_PER_DAY - 1);
  return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
}

const clamp = (n: number, lo: number, hi: number) => Math.min(Math.max(n, lo), hi);

/** The nearest multiple of [step], kept inside the day. */
export const snap = (minutes: number, step = SNAP) => clamp(Math.round(minutes / step) * step, 0, MINUTES_PER_DAY);

/** Where a task is drawn: from its start for its duration (or half an hour), at least a quarter hour, never past midnight. */
export function blockSpan(start: number, duration: number | null | undefined): { start: number; end: number } {
  const s = clamp(start, 0, MINUTES_PER_DAY - MIN_BLOCK);
  const length = duration == null || duration < 1 ? DEFAULT_BLOCK : duration;
  const e = Math.min(Math.max(s + length, s + MIN_BLOCK), MINUTES_PER_DAY);
  return { start: s, end: e };
}

export interface GridItem {
  id: string;
  start: number;
  end: number;
}

export interface PlacedItem extends GridItem {
  /** Which column of its group (0 is leftmost) and how many columns the group has. */
  column: number;
  columns: number;
}

/** Lays the blocks of one day side by side where they overlap; touching blocks do not overlap. */
export function layoutDay(items: GridItem[]): PlacedItem[] {
  const sorted = [...items].sort((a, b) => a.start - b.start || b.end - a.end);
  const out: PlacedItem[] = [];
  let group: { item: GridItem; column: number }[] = [];
  let columnEnds: number[] = [];
  let groupEnd = -1;

  const flush = () => {
    for (const g of group) out.push({ ...g.item, column: g.column, columns: columnEnds.length });
    group = [];
    columnEnds = [];
    groupEnd = -1;
  };

  for (const item of sorted) {
    if (group.length > 0 && item.start >= groupEnd) flush();
    let column = columnEnds.findIndex((end) => end <= item.start);
    if (column < 0) {
      column = columnEnds.length;
      columnEnds.push(item.end);
    } else {
      columnEnds[column] = item.end;
    }
    group.push({ item, column });
    if (item.end > groupEnd) groupEnd = item.end;
  }
  flush();
  return out;
}

/** The days a view shows: one, three from the anchor, the week around it, or the six weeks of a month grid (weekStart: 1 = Monday ... 7 = Sunday). */
export function daysOf(mode: CalendarMode, anchor: string, weekStart = 1): string[] {
  if (mode === 'day') return [anchor];
  if (mode === 'three') return [0, 1, 2].map((i) => addDays(anchor, i));
  const a = parseIso(anchor);
  if (mode === 'week') {
    const weekday = a.getDay() === 0 ? 7 : a.getDay();
    const back = (weekday - weekStart + 7) % 7;
    return Array.from({ length: 7 }, (_, i) => isoDate(new Date(a.getFullYear(), a.getMonth(), a.getDate() - back + i)));
  }
  const first = new Date(a.getFullYear(), a.getMonth(), 1);
  const weekday = first.getDay() === 0 ? 7 : first.getDay();
  const back = (weekday - weekStart + 7) % 7;
  return Array.from({ length: 42 }, (_, i) => isoDate(new Date(first.getFullYear(), first.getMonth(), 1 - back + i)));
}

/** The anchor after Previous (-1) or Next (+1): a day, three days, or a month (same day of month, or the last of a shorter one). */
export function shiftAnchor(mode: CalendarMode, anchor: string, direction: 1 | -1): string {
  if (mode === 'day') return addDays(anchor, direction);
  if (mode === 'three') return addDays(anchor, 3 * direction);
  if (mode === 'week') return addDays(anchor, 7 * direction);
  const a = parseIso(anchor);
  const first = new Date(a.getFullYear(), a.getMonth() + direction, 1);
  const last = new Date(first.getFullYear(), first.getMonth() + 1, 0).getDate();
  return isoDate(new Date(first.getFullYear(), first.getMonth(), Math.min(a.getDate(), last)));
}

/** What dropping a task somewhere means: its new date, and its time (null in the all-day row). */
export function dropAt(day: string, minutes?: number | null): { date: string; time: string | null } {
  if (minutes == null) return { date: day, time: null };
  return { date: day, time: formatMinutes(clamp(snap(minutes), 0, MINUTES_PER_DAY - MIN_BLOCK)) };
}

/** The duration after dragging the bottom edge of a block that starts at [start] to [endMinutes]. */
export function resizeDuration(start: number, endMinutes: number): number {
  const end = clamp(snap(endMinutes), start + MIN_BLOCK, MINUTES_PER_DAY);
  return end - start;
}
