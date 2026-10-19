import { useMemo, useRef, useState } from 'react';
import { clock, dayLabel, parseIso, todayIso } from '../lib/dates';
import { eventColour, onColour, projectColour } from '../lib/tasks';
import { minutesOf } from '../lib/timegrid';
import { useData } from '../state/data';
import { usePrefs } from '../state/prefs';
import { useUi } from '../state/ui';
import type { Task } from '../types';

const MAX_CHIPS = 3;
const chipColours = (c: string) => ({ ['--c' as string]: c, ['--fg' as string]: onColour(c) });

/** A month as six weeks. Tasks are chips in their day; drag one onto another day to move it (its time stays). */
export function MonthGrid({ days, month, tasks, onPickDay }: { days: string[]; month: number; tasks: Task[]; onPickDay: (day: string) => void }) {
  const { updateTask, projectById } = useData();
  const { openTask, openQuickAdd } = useUi();
  const { use24h } = usePrefs();
  const today = todayIso();
  const [drag, setDrag] = useState<{ id: string; over: string | null } | null>(null);
  const dragRef = useRef<typeof drag>(null);

  const byDay = useMemo(() => {
    const map = new Map<string, Task[]>();
    for (const t of tasks) {
      if (!t.due) continue;
      map.set(t.due.date, [...(map.get(t.due.date) ?? []), t]);
    }
    for (const list of map.values()) list.sort((a, b) => (a.due!.time ?? '').localeCompare(b.due!.time ?? '') || a.priority - b.priority);
    return map;
  }, [tasks]);

  const set = (d: typeof drag) => {
    dragRef.current = d;
    setDrag(d);
  };

  function begin(e: React.PointerEvent, task: Task) {
    if (e.button !== 0) return;
    e.stopPropagation();
    const touch = e.pointerType === 'touch';
    const sx = e.clientX;
    const sy = e.clientY;
    let active = false;
    let timer: number | undefined;
    const dayAt = (x: number, y: number) => document.elementFromPoint(x, y)?.closest<HTMLElement>('[data-day]')?.dataset.day ?? null;
    const begun = () => {
      active = true;
      document.body.classList.add('is-dragging');
      set({ id: task.id, over: task.due!.date });
    };
    const noScroll = (ev: TouchEvent) => active && ev.cancelable && ev.preventDefault();
    const cleanup = () => {
      window.clearTimeout(timer);
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
      window.removeEventListener('pointercancel', cancel);
      window.removeEventListener('touchmove', noScroll);
      document.body.classList.remove('is-dragging');
    };
    const cancel = () => {
      cleanup();
      set(null);
    };
    const move = (ev: PointerEvent) => {
      if (!active) {
        if (Math.hypot(ev.clientX - sx, ev.clientY - sy) < (touch ? 9 : 4)) return;
        if (touch) return cancel();
        begun();
      }
      ev.preventDefault();
      set({ id: task.id, over: dayAt(ev.clientX, ev.clientY) });
    };
    const up = () => {
      const d = dragRef.current;
      cleanup();
      set(null);
      if (!active) return openTask(task.id);
      if (d?.over && d.over !== task.due!.date) void updateTask(task.id, { due_date: d.over });
    };
    window.addEventListener('pointermove', move, { passive: false });
    window.addEventListener('pointerup', up);
    window.addEventListener('pointercancel', cancel);
    window.addEventListener('touchmove', noScroll, { passive: false });
    if (touch) timer = window.setTimeout(begun, 320);
  }

  const first = parseIso(days[0]);
  const names = Array.from({ length: 7 }, (_, i) => new Date(first.getFullYear(), first.getMonth(), first.getDate() + i).toLocaleDateString(undefined, { weekday: 'short' }));

  return (
    <div className="month">
      <div className="month-dow">
        {names.map((n) => (
          <span key={n}>{n}</span>
        ))}
      </div>
      <div className="month-grid">
        {days.map((d) => {
          const date = parseIso(d);
          const list = byDay.get(d) ?? [];
          const shown = list.slice(0, list.length > MAX_CHIPS ? MAX_CHIPS - 1 : MAX_CHIPS);
          const more = list.length - shown.length;
          return (
            <div
              key={d}
              data-day={d}
              className={`month-cell ${date.getMonth() !== month ? 'dim' : ''} ${d === today ? 'today' : ''} ${drag?.over === d ? 'over' : ''}`}
              onClick={(e) => e.target === e.currentTarget && openQuickAdd({ dueDate: d, label: dayLabel(d, today) })}
            >
              <button className="month-num" onClick={() => onPickDay(d)} aria-label={`Show ${d}`}>
                {date.getDate() === 1 ? date.toLocaleDateString(undefined, { day: 'numeric', month: 'short' }) : date.getDate()}
              </button>
              {shown.map((t) => (
                <div
                  key={t.id}
                  className={`month-chip ${minutesOf(t.due?.time) != null ? 'timed' : 'filled'} ${drag?.id === t.id ? 'dragging' : ''}`}
                  style={chipColours(eventColour(projectColour(projectById(t.project_id))))}
                  onPointerDown={(e) => begin(e, t)}
                  title={t.title}
                >
                  {minutesOf(t.due?.time) != null && <i className="dot" />}
                  {t.due?.time && minutesOf(t.due.time) != null && <span className="t">{clock(t.due.time, use24h)}</span>}
                  <span className="title">{t.title}</span>
                </div>
              ))}
              {more > 0 && (
                <button className="month-more" onClick={() => onPickDay(d)}>
                  +{more} more
                </button>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
