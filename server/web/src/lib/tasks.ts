import type { Due, Project, Task, TaskPatch } from '../types';
import { addDays, parseIso } from './dates';

export const byWhen = (a: Task, b: Task) =>
  (a.due?.date ?? '9999').localeCompare(b.due?.date ?? '9999') ||
  (a.due?.time ?? '99:99').localeCompare(b.due?.time ?? '99:99') ||
  a.priority - b.priority ||
  a.order - b.order;

export const byOrder = (a: Task, b: Task) => a.order - b.order;

/** A task with a patch applied the way the server will apply it, so the screen can change before the answer comes. */
export function applyPatch(task: Task, patch: TaskPatch): Task {
  const next: Task = { ...task };
  if (patch.title !== undefined) next.title = patch.title;
  if (patch.description !== undefined) next.description = patch.description;
  if (patch.priority !== undefined) next.priority = patch.priority;
  if (patch.labels !== undefined) next.labels = patch.labels;
  if ('duration_minutes' in patch) next.duration_minutes = patch.duration_minutes ?? null;
  if ('due_date' in patch || 'due_time' in patch || 'recurrence' in patch) {
    const date = 'due_date' in patch ? (patch.due_date ?? null) : (task.due?.date ?? null);
    const due: Due | null = date
      ? {
          date,
          time: 'due_time' in patch ? (patch.due_time ?? null) : (task.due?.time ?? null),
          recurrence: 'recurrence' in patch ? (patch.recurrence ?? null) : (task.due?.recurrence ?? null),
        }
      : null;
    next.due = due;
  }
  if (patch.project_id !== undefined && patch.project_id !== task.project_id) {
    next.project_id = patch.project_id;
    next.section_id = patch.section_id ?? null;
  } else if ('section_id' in patch) {
    next.section_id = patch.section_id ?? null;
  }
  return next;
}

/** Sub-tasks nested under their parent, in the order given; a task whose parent is not in the list stands alone. */
export interface TaskNode {
  task: Task;
  children: TaskNode[];
}

export function buildTree(tasks: Task[]): TaskNode[] {
  const nodes = new Map(tasks.map((t) => [t.id, { task: t, children: [] as TaskNode[] }]));
  const roots: TaskNode[] = [];
  for (const t of tasks) {
    const node = nodes.get(t.id)!;
    const parent = t.parent_id ? nodes.get(t.parent_id) : undefined;
    if (parent) parent.children.push(node);
    else roots.push(node);
  }
  return roots;
}

/** How many sub-tasks a task has, and how many of those are open (the list only holds open ones). */
export const subtaskCount = (tasks: Task[], id: string) => tasks.filter((t) => t.parent_id === id).length;

/** Groups of tasks by due day, in date order. */
export function groupByDay(tasks: Task[]): { date: string; tasks: Task[] }[] {
  const days = new Map<string, Task[]>();
  for (const t of [...tasks].sort(byWhen)) {
    if (!t.due) continue;
    const list = days.get(t.due.date) ?? [];
    list.push(t);
    days.set(t.due.date, list);
  }
  return [...days].map(([date, list]) => ({ date, tasks: list }));
}

export const projectColour = (project: Pick<Project, 'color'> | undefined): string => {
  const c = project?.color;
  if (typeof c === 'number') return `#${(c & 0xffffff).toString(16).padStart(6, '0')}`;
  if (typeof c === 'string' && c.startsWith('#')) return c;
  return '#8b8da3';
};

/** Google Calendar's event colours: Tomato, Flamingo, Tangerine, Banana, Sage, Basil, Peacock, Blueberry, Lavender, Grape, Graphite. */
const EVENT_COLOURS = ['#d50000', '#e67c73', '#f4511e', '#f6bf26', '#33b679', '#0b8043', '#039be5', '#3f51b5', '#7986cb', '#8e24aa', '#616161'];

/** The Google event colour closest to a project's colour, so the calendar is drawn in Google's palette. */
export const eventColour = (hex: string): string => {
  const m = /^#([0-9a-f]{6})$/i.exec(hex);
  if (!m) return EVENT_COLOURS[6];
  const rgb = (h: string) => [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)];
  const [r, g, b] = rgb(hex);
  let best = EVENT_COLOURS[0];
  let bestDistance = Infinity;
  for (const e of EVENT_COLOURS) {
    const [er, eg, eb] = rgb(e);
    const d = (er - r) ** 2 + (eg - g) ** 2 + (eb - b) ** 2;
    if (d < bestDistance) {
      best = e;
      bestDistance = d;
    }
  }
  return best;
};

/** Text that stays readable on a filled colour (white on dark colours, near-black on light ones). */
export const onColour = (hex: string): string => {
  const m = /^#([0-9a-f]{6})$/i.exec(hex);
  if (!m) return '#ffffff';
  const n = parseInt(m[1], 16);
  const lin = (v: number) => {
    const s = v / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  };
  const luminance = 0.2126 * lin((n >> 16) & 255) + 0.7152 * lin((n >> 8) & 255) + 0.0722 * lin(n & 255);
  return luminance > 0.4 ? '#202124' : '#ffffff';
};

/** True when a task is due today or earlier. */
export const isDueByToday = (t: Task, today: string) => !!t.due && t.due.date <= today;

export const isUpcoming = (t: Task, today: string) => !!t.due && t.due.date > today;

/** The coming 7 days, as ISO dates starting today. */
export const nextDays = (today: string, n = 7) => Array.from({ length: n }, (_, i) => addDays(today, i));

export const weekdayShort = (iso: string) => parseIso(iso).toLocaleDateString(undefined, { weekday: 'short' });
