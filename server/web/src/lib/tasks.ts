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

/** True when a task is due today or earlier. */
export const isDueByToday = (t: Task, today: string) => !!t.due && t.due.date <= today;

export const isUpcoming = (t: Task, today: string) => !!t.due && t.due.date > today;

/** The coming 7 days, as ISO dates starting today. */
export const nextDays = (today: string, n = 7) => Array.from({ length: n }, (_, i) => addDays(today, i));

export const weekdayShort = (iso: string) => parseIso(iso).toLocaleDateString(undefined, { weekday: 'short' });
