import { describe, expect, it } from 'vitest';
import type { Section, Task } from '../types';
import { addDays, clock, dayLabel, dueText, dueTone, monthGrid, nextMonday, parseIso } from './dates';
import { applyColumns, buildColumns, colKey, findColumn, moveAcross, NONE, planCommit, reorderWithin } from './order';
import { applyPatch, buildTree, groupByDay } from './tasks';

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id, title: id, description: '', project_id: 'p', section_id: null, parent_id: null, priority: 4, labels: [], due: null,
    deadline: null, duration_minutes: null, is_completed: false, completed_at: null, created_at: '', updated_at: '', order: 0, ...over,
  };
}
const section = (id: string, order: number): Section => ({ id, project_id: 'p', name: id, order, is_archived: false });

describe('dates', () => {
  it('adds days across a month end and finds the next Monday', () => {
    expect(addDays('2026-10-31', 1)).toBe('2026-11-01');
    expect(addDays('2026-03-01', -1)).toBe('2026-02-28');
    expect(nextMonday('2026-10-19')).toBe('2026-10-26'); // a Monday: the following one
    expect(nextMonday('2026-10-21')).toBe('2026-10-26');
    expect(nextMonday('2026-10-25')).toBe('2026-10-26'); // a Sunday
  });

  it('labels days the way people say them', () => {
    const today = '2026-10-19';
    expect(dayLabel('2026-10-19', today)).toBe('Today');
    expect(dayLabel('2026-10-20', today)).toBe('Tomorrow');
    expect(dayLabel('2026-10-18', today)).toBe('Yesterday');
    expect(dayLabel('2026-10-23', today)).toBe(parseIso('2026-10-23').toLocaleDateString(undefined, { weekday: 'long' }));
    expect(dayLabel('2026-12-01', today)).not.toMatch(/2026/);
    expect(dayLabel('2027-01-05', today)).toMatch(/2027/);
  });

  it('shows times in 12 or 24 hour form', () => {
    expect(clock('17:05', true)).toBe('17:05');
    expect(clock('17:05', false)).toBe('5:05 PM');
    expect(clock('00:30', false)).toBe('12:30 AM');
    expect(clock('12:00', false)).toBe('12:00 PM');
    expect(dueText({ date: '2026-10-20', time: '09:00', recurrence: null }, true, '2026-10-19')).toBe('Tomorrow 09:00');
  });

  it('colours a date by how soon it is', () => {
    const today = '2026-10-19';
    expect(dueTone('2026-10-18', today)).toBe('overdue');
    expect(dueTone('2026-10-19', today)).toBe('today');
    expect(dueTone('2026-10-20', today)).toBe('tomorrow');
    expect(dueTone('2026-10-25', today)).toBe('soon');
    expect(dueTone('2026-10-26', today)).toBe('later');
  });

  it('builds a 6-week month grid that starts on a Monday and holds the month', () => {
    const cells = monthGrid(2026, 9); // October 2026
    expect(cells).toHaveLength(42);
    expect(parseIso(cells[0]).getDay()).toBe(1);
    expect(cells).toContain('2026-10-01');
    expect(cells).toContain('2026-10-31');
  });
});

describe('columns for drag and drop', () => {
  const sections = [section('a', 0), section('b', 1)];
  const tasks = [
    task('t1', { section_id: 'a', order: 1 }),
    task('t0', { section_id: 'a', order: 0 }),
    task('t2', { section_id: 'b', order: 0 }),
    task('t3', { order: 0 }),
    task('sub', { section_id: 'a', parent_id: 't0' }),
  ];

  it('puts top-level tasks in their section in order, with a column for no section', () => {
    expect(buildColumns(tasks, sections)).toEqual({ [NONE]: ['t3'], 'col:a': ['t0', 't1'], 'col:b': ['t2'] });
  });

  it('keeps empty sections as columns, and shows tasks of a section that is gone', () => {
    expect(buildColumns([], sections)).toEqual({ [NONE]: [], 'col:a': [], 'col:b': [] });
    expect(buildColumns([task('x', { section_id: 'gone' })], sections)['col:gone']).toEqual(['x']);
  });

  it('moves a task into another column before the one it is over, after it when below, last over the column', () => {
    const cols = buildColumns(tasks, sections);
    expect(moveAcross(cols, 't2', 't0')['col:a']).toEqual(['t2', 't0', 't1']);
    expect(moveAcross(cols, 't2', 't0', true)['col:a']).toEqual(['t0', 't2', 't1']);
    expect(moveAcross(cols, 't2', 'col:a')['col:a']).toEqual(['t0', 't1', 't2']);
    expect(moveAcross(cols, 't2', 'col:a')['col:b']).toEqual([]);
    expect(moveAcross(cols, 't0', 't1')).toBe(cols); // same column: unchanged
  });

  it('reorders inside a column', () => {
    const cols = buildColumns(tasks, sections);
    expect(reorderWithin(cols, 't1', 't0')['col:a']).toEqual(['t1', 't0']);
    expect(reorderWithin(cols, 't0', 't0')).toBe(cols);
    expect(reorderWithin(cols, 't0', 't2')).toBe(cols); // different columns: moveAcross's job
  });

  it('plans what to send after a drop', () => {
    const before = buildColumns(tasks, sections);
    const moved = moveAcross(before, 't2', 't0');
    expect(planCommit(before, moved, 't2')).toEqual({ move: { taskId: 't2', sectionId: 'a' }, order: ['t2', 't0', 't1'] });
    expect(planCommit(before, reorderWithin(before, 't1', 't0'), 't1')).toEqual({ move: null, order: ['t1', 't0'] });
    expect(planCommit(before, before, 't1')).toEqual({ move: null, order: null });
    const toNone = moveAcross(before, 't0', NONE);
    expect(planCommit(before, toNone, 't0').move).toEqual({ taskId: 't0', sectionId: null });
  });

  it('finds the column of a task or a column key, and applies columns back to tasks', () => {
    const cols = buildColumns(tasks, sections);
    expect(findColumn(cols, 't2')).toBe('col:b');
    expect(findColumn(cols, 'col:a')).toBe('col:a');
    expect(findColumn(cols, 'nope')).toBeUndefined();
    const after = applyColumns(tasks, moveAcross(cols, 't2', 't0'));
    expect(after.find((t) => t.id === 't2')).toMatchObject({ section_id: 'a', order: 0 });
    expect(after.find((t) => t.id === 't0')).toMatchObject({ section_id: 'a', order: 1 });
    expect(colKey(null)).toBe(NONE);
  });
});

describe('tasks', () => {
  const base = task('a', { due: { date: '2026-10-19', time: '09:00', recurrence: 'every week' }, section_id: 's' });

  it('applies a patch like the server: clearing the date clears its time and repeat', () => {
    expect(applyPatch(base, { due_date: null }).due).toBeNull();
    expect(applyPatch(base, { due_date: '2026-10-25' }).due).toEqual({ date: '2026-10-25', time: '09:00', recurrence: 'every week' });
    expect(applyPatch(base, { due_time: null }).due).toEqual({ date: '2026-10-19', time: null, recurrence: 'every week' });
    expect(applyPatch(task('b'), { due_date: '2026-10-25' }).due).toEqual({ date: '2026-10-25', time: null, recurrence: null });
  });

  it('moving to another project leaves the section unless one is given', () => {
    expect(applyPatch(base, { project_id: 'q' })).toMatchObject({ project_id: 'q', section_id: null });
    expect(applyPatch(base, { project_id: 'q', section_id: 'x' })).toMatchObject({ project_id: 'q', section_id: 'x' });
    expect(applyPatch(base, { section_id: null }).section_id).toBeNull();
    expect(applyPatch(base, { title: 'new', priority: 1, labels: ['x'] })).toMatchObject({ title: 'new', priority: 1, labels: ['x'] });
  });

  it('nests sub-tasks under their parent and keeps orphans at the top', () => {
    const tree = buildTree([task('p1'), task('c1', { parent_id: 'p1' }), task('c2', { parent_id: 'c1' }), task('o', { parent_id: 'missing' })]);
    expect(tree.map((n) => n.task.id)).toEqual(['p1', 'o']);
    expect(tree[0].children[0].children[0].task.id).toBe('c2');
  });

  it('groups by day in date order, by time inside a day, and skips undated tasks', () => {
    const groups = groupByDay([
      task('late', { due: { date: '2026-10-21', time: '08:00', recurrence: null } }),
      task('early', { due: { date: '2026-10-20', time: null, recurrence: null } }),
      task('later-same-day', { due: { date: '2026-10-21', time: '18:00', recurrence: null } }),
      task('none'),
    ]);
    expect(groups.map((g) => g.date)).toEqual(['2026-10-20', '2026-10-21']);
    expect(groups[1].tasks.map((t) => t.id)).toEqual(['late', 'later-same-day']);
  });
});
