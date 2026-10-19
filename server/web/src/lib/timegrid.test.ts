import { describe, expect, it } from 'vitest';
import { blockSpan, dropAt, formatMinutes, daysOf, layoutDay, minutesOf, resizeDuration, shiftAnchor, snap } from './timegrid';

// The cases below are the same as in packages/taskflow_core/test/time_grid_test.dart. Keep them the same.
const p = (id: string, start: number, end: number, column: number, columns: number) => ({ id, start, end, column, columns });
const g = (id: string, start: number, end: number) => ({ id, start, end });

describe('time and snapping', () => {
  it('reads and writes HH:MM', () => {
    expect(minutesOf('09:30')).toBe(570);
    expect(minutesOf('9:05')).toBe(545);
    expect(minutesOf('24:00')).toBeNull();
    expect(minutesOf('12:60')).toBeNull();
    expect(minutesOf('noon')).toBeNull();
    expect(minutesOf(null)).toBeNull();
    expect(formatMinutes(570)).toBe('09:30');
    expect(formatMinutes(0)).toBe('00:00');
    expect(formatMinutes(1440)).toBe('23:59');
  });

  it('snaps to the nearest quarter hour inside the day', () => {
    expect(snap(7)).toBe(0);
    expect(snap(8)).toBe(15);
    expect(snap(22)).toBe(15);
    expect(snap(23)).toBe(30);
    expect(snap(-30)).toBe(0);
    expect(snap(1500)).toBe(1440);
  });

  it('a block lasts its duration, or half an hour, never less than a quarter, never past midnight', () => {
    expect(blockSpan(540, null)).toEqual({ start: 540, end: 570 });
    expect(blockSpan(540, 90)).toEqual({ start: 540, end: 630 });
    expect(blockSpan(540, 5)).toEqual({ start: 540, end: 555 });
    expect(blockSpan(1420, 60)).toEqual({ start: 1420, end: 1440 });
    expect(blockSpan(1439, null)).toEqual({ start: 1425, end: 1440 });
    expect(blockSpan(540, 0)).toEqual({ start: 540, end: 570 });
  });
});

describe('overlapping blocks', () => {
  it('blocks that do not overlap each have a whole column; touching is not overlapping', () => {
    expect(layoutDay([g('a', 540, 600), g('b', 600, 660)])).toEqual([p('a', 540, 600, 0, 1), p('b', 600, 660, 0, 1)]);
  });

  it('two that overlap sit side by side', () => {
    expect(layoutDay([g('a', 540, 630), g('b', 570, 660)])).toEqual([p('a', 540, 630, 0, 2), p('b', 570, 660, 1, 2)]);
  });

  it('a chain of overlaps shares one width, and a freed column is reused', () => {
    expect(layoutDay([g('a', 540, 600), g('b', 570, 630), g('c', 600, 660)])).toEqual([p('a', 540, 600, 0, 2), p('b', 570, 630, 1, 2), p('c', 600, 660, 0, 2)]);
  });

  it('three at the same time get three columns', () => {
    const r = layoutDay([g('a', 540, 600), g('b', 540, 600), g('c', 540, 600)]);
    expect(r.map((x) => x.column)).toEqual([0, 1, 2]);
    expect(r.every((x) => x.columns === 3)).toBe(true);
  });

  it('separate groups are independent', () => {
    expect(layoutDay([g('late2', 870, 930), g('early', 540, 600), g('late1', 840, 900)])).toEqual([
      p('early', 540, 600, 0, 1),
      p('late1', 840, 900, 0, 2),
      p('late2', 870, 930, 1, 2),
    ]);
  });

  it('a long block comes first when two start together', () => {
    const r = layoutDay([g('short', 540, 570), g('long', 540, 660)]);
    expect(r.find((x) => x.id === 'long')!.column).toBe(0);
    expect(r.find((x) => x.id === 'short')!.column).toBe(1);
  });

  it('nothing in, nothing out', () => expect(layoutDay([])).toEqual([]));
});

describe('which days a view shows', () => {
  it('a day, three days, or the six weeks of a month grid', () => {
    expect(daysOf('day', '2026-10-19')).toEqual(['2026-10-19']);
    expect(daysOf('three', '2026-10-30')).toEqual(['2026-10-30', '2026-10-31', '2026-11-01']);
    const monday = daysOf('month', '2026-10-19', 1);
    expect(monday).toHaveLength(42);
    expect(monday[0]).toBe('2026-09-28');
    expect(monday[41]).toBe('2026-11-08');
    expect(daysOf('month', '2026-10-19', 7)[0]).toBe('2026-09-27');
    expect(daysOf('month', '2026-11-15', 1)[0]).toBe('2026-10-26');
  });

  it('a week is the seven days around the anchor, from the first day of the week', () => {
    expect(daysOf('week', '2026-10-21', 1)).toEqual(['2026-10-19', '2026-10-20', '2026-10-21', '2026-10-22', '2026-10-23', '2026-10-24', '2026-10-25']);
    expect(daysOf('week', '2026-10-21', 7)[0]).toBe('2026-10-18');
    expect(daysOf('week', '2026-10-25', 1)[0]).toBe('2026-10-19'); // a Sunday belongs to the week before when weeks start on Monday
    expect(daysOf('week', '2026-11-01', 1)).toContain('2026-10-26');
  });

  it('previous and next move by a day, three days or a month', () => {
    expect(shiftAnchor('day', '2026-10-31', 1)).toBe('2026-11-01');
    expect(shiftAnchor('day', '2026-03-01', -1)).toBe('2026-02-28');
    expect(shiftAnchor('three', '2026-10-29', 1)).toBe('2026-11-01');
    expect(shiftAnchor('three', '2026-10-19', -1)).toBe('2026-10-16');
    expect(shiftAnchor('week', '2026-10-29', 1)).toBe('2026-11-05');
    expect(shiftAnchor('week', '2026-10-05', -1)).toBe('2026-09-28');
    expect(shiftAnchor('month', '2026-10-19', 1)).toBe('2026-11-19');
    expect(shiftAnchor('month', '2026-01-31', 1)).toBe('2026-02-28');
    expect(shiftAnchor('month', '2026-01-15', -1)).toBe('2025-12-15');
  });
});

describe('dropping and resizing', () => {
  it('a drop gives a date and a snapped time, or no time in the all-day row', () => {
    expect(dropAt('2026-10-20', 553)).toEqual({ date: '2026-10-20', time: '09:15' });
    expect(dropAt('2026-10-20', 600)).toEqual({ date: '2026-10-20', time: '10:00' });
    expect(dropAt('2026-10-20')).toEqual({ date: '2026-10-20', time: null });
    expect(dropAt('2026-10-20', 1439)).toEqual({ date: '2026-10-20', time: '23:45' }); // room for a quarter hour
  });

  it('resizing snaps, keeps at least a quarter hour, and stops at midnight', () => {
    expect(resizeDuration(540, 647)).toBe(105);
    expect(resizeDuration(540, 541)).toBe(15);
    expect(resizeDuration(540, 500)).toBe(15);
    expect(resizeDuration(1380, 1500)).toBe(60);
  });
});
