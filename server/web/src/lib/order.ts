/**
 * The arithmetic of drag and drop, kept apart from the screen so it can be tested.
 *
 * Tasks sit in "columns": the sections of a project, plus one for tasks that are in no section. A column is
 * an ordered list of task ids; its key is `col:<sectionId>` or `col:none`.
 */
import type { Section, Task } from '../types';

export type Columns = Record<string, string[]>;

export const NONE = 'col:none';
export const colKey = (sectionId: string | null | undefined) => (sectionId ? `col:${sectionId}` : NONE);
export const sectionOf = (key: string): string | null => (key === NONE ? null : key.slice(4));
export const isColumnKey = (id: string) => id.startsWith('col:');

/** The columns of a project, in section order, holding that project's top-level open tasks in their order. */
export function buildColumns(tasks: Task[], sections: Section[]): Columns {
  const cols: Columns = { [NONE]: [] };
  for (const s of sections) cols[colKey(s.id)] = [];
  const top = tasks.filter((t) => !t.parent_id).sort((a, b) => a.order - b.order);
  for (const t of top) {
    const key = colKey(t.section_id);
    (cols[key] ??= []).push(t.id); // a task in a section that was archived or removed still shows up
  }
  return cols;
}

export function findColumn(cols: Columns, id: string): string | undefined {
  if (isColumnKey(id)) return id in cols ? id : undefined;
  return Object.keys(cols).find((k) => cols[k].includes(id));
}

/**
 * While dragging: the active task moves into the column under the pointer, before the task it is over (or last
 * when it is over the column itself or below the last task).
 */
export function moveAcross(cols: Columns, activeId: string, overId: string, below = false): Columns {
  const from = findColumn(cols, activeId);
  const to = findColumn(cols, overId);
  if (!from || !to || from === to) return cols;
  const next: Columns = { ...cols, [from]: cols[from].filter((id) => id !== activeId) };
  const target = [...cols[to]];
  let index = isColumnKey(overId) ? target.length : target.indexOf(overId) + (below ? 1 : 0);
  if (index < 0) index = target.length;
  target.splice(index, 0, activeId);
  next[to] = target;
  return next;
}

/** On drop within one column: the active task takes the place of the one it was dropped on. */
export function reorderWithin(cols: Columns, activeId: string, overId: string): Columns {
  const col = findColumn(cols, activeId);
  if (!col || col !== findColumn(cols, overId) || activeId === overId || isColumnKey(overId)) return cols;
  const list = [...cols[col]];
  const from = list.indexOf(activeId);
  const to = list.indexOf(overId);
  list.splice(to, 0, list.splice(from, 1)[0]);
  return { ...cols, [col]: list };
}

export interface CommitPlan {
  /** The task changed column: set its section (null for none). */
  move: { taskId: string; sectionId: string | null } | null;
  /** The ids of the column it ended in, in order: send them to put the task where it was dropped. */
  order: string[] | null;
}

/** What to tell the server after a drop, given the columns before the drag and after it. */
export function planCommit(before: Columns, after: Columns, activeId: string): CommitPlan {
  const from = findColumn(before, activeId);
  const to = findColumn(after, activeId);
  if (!from || !to) return { move: null, order: null };
  const move = from !== to ? { taskId: activeId, sectionId: sectionOf(to) } : null;
  const same = before[to].length === after[to].length && before[to].every((id, i) => id === after[to][i]);
  return { move, order: move || !same ? after[to] : null };
}

/** The columns after a successful commit, for showing at once. */
export const applyColumns = (tasks: Task[], cols: Columns): Task[] =>
  tasks.map((t) => {
    const key = findColumn(cols, t.id);
    if (!key) return t;
    const index = cols[key].indexOf(t.id);
    return { ...t, section_id: sectionOf(key), order: index };
  });
