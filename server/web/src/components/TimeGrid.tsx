import { useLayoutEffect, useMemo, useRef, useState } from 'react';
import { Check } from 'lucide-react';
import { clock, dayLabel, parseIso, todayIso } from '../lib/dates';
import { dropAt, formatMinutes, layoutDay, minutesOf, blockSpan, resizeDuration, MIN_BLOCK } from '../lib/timegrid';
import { eventColour, onColour, projectColour } from '../lib/tasks';
import { useData } from '../state/data';
import { usePrefs } from '../state/prefs';
import { useUi } from '../state/ui';
import { useNow } from '../ui/hooks';
import type { Task } from '../types';

const HOUR = 56; // pixels per hour
const PX = HOUR / 60;

interface Drag {
  kind: 'move' | 'resize';
  id: string;
  day: string;
  /** Move: the start of the block; resize: where its end is now. */
  minutes: number;
  allDay: boolean;
}

const spanOf = (t: Task) => blockSpan(minutesOf(t.due?.time) ?? 0, t.duration_minutes);

/** The time zone the grid is drawn in, as Google's grid shows it (GMT+3, GMT+5:30). */
function zoneLabel(now: Date): string {
  const off = -now.getTimezoneOffset();
  const h = Math.floor(Math.abs(off) / 60);
  const m = Math.abs(off) % 60;
  return `GMT${off < 0 ? '-' : '+'}${h}${m ? `:${String(m).padStart(2, '0')}` : ''}`;
}

/**
 * One or more days side by side on a time grid. Timed tasks are blocks (drag to move, drag the bottom edge to
 * change the length, click to open); tasks with a date but no time sit in the all-day row; click an empty spot to
 * add a task there. The rules (overlap, snapping, what a drop means) are in lib/timegrid.ts.
 */
export function TimeGrid({ days, tasks, onPickDay }: { days: string[]; tasks: Task[]; onPickDay: (day: string) => void }) {
  const { updateTask, completeTask, completing, projectById } = useData();
  const { openTask, openQuickAdd } = useUi();
  const { use24h } = usePrefs();
  const now = useNow(30000);
  const today = todayIso(now);
  const scroller = useRef<HTMLDivElement>(null);
  const cols = useRef(new Map<string, HTMLDivElement>());
  const allDayRow = useRef<HTMLDivElement>(null);
  const [drag, setDrag] = useState<Drag | null>(null);
  const dragRef = useRef<Drag | null>(null);
  const byId = useMemo(() => new Map(tasks.map((t) => [t.id, t])), [tasks]);

  const perDay = useMemo(() => {
    const map = new Map<string, { allDay: Task[]; placed: ReturnType<typeof layoutDay> }>();
    for (const d of days) {
      const mine = tasks.filter((t) => t.due?.date === d);
      const timed = mine.filter((t) => minutesOf(t.due?.time) != null);
      map.set(d, {
        allDay: mine.filter((t) => minutesOf(t.due?.time) == null),
        placed: layoutDay(timed.map((t) => ({ id: t.id, ...spanOf(t) }))),
      });
    }
    return map;
  }, [days, tasks]);

  // Start at the current time (when today is shown), otherwise at the morning.
  const first = days[0];
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const n = new Date();
    const target = days.includes(todayIso(n)) ? n.getHours() * 60 + n.getMinutes() - 90 : 7 * 60;
    el.scrollTop = Math.max(0, target * PX);
    // only when the set of days changes
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [first, days.length]);

  function setDragBoth(d: Drag | null) {
    dragRef.current = d;
    setDrag(d);
  }

  /** Which day and minute the pointer is over (days are columns; the all-day row has no minute). */
  function target(x: number, y: number, grab: number, kind: Drag['kind'], start: number): Pick<Drag, 'day' | 'minutes' | 'allDay'> {
    let best = days[0];
    let bestDist = Infinity;
    for (const d of days) {
      const r = cols.current.get(d)?.getBoundingClientRect();
      if (!r) continue;
      const dist = x < r.left ? r.left - x : x > r.right ? x - r.right : 0;
      if (dist < bestDist) {
        best = d;
        bestDist = dist;
      }
    }
    const col = cols.current.get(best)?.getBoundingClientRect();
    const row = allDayRow.current?.getBoundingClientRect();
    if (kind === 'move' && row && y >= row.top && y <= row.bottom) return { day: best, minutes: start, allDay: true };
    const minutes = col ? (y - col.top - grab) / PX : start;
    return kind === 'move' ? { day: best, minutes, allDay: false } : { day: best, minutes, allDay: false };
  }

  function begin(e: React.PointerEvent, task: Task, kind: Drag['kind']) {
    if (e.button !== 0) return;
    e.stopPropagation();
    const touch = e.pointerType === 'touch';
    const startX = e.clientX;
    const startY = e.clientY;
    const span = spanOf(task);
    const hasTime = minutesOf(task.due?.time) != null;
    const rect = (e.currentTarget as HTMLElement).closest<HTMLElement>('[data-block]')?.getBoundingClientRect();
    const grab = kind === 'move' && rect && hasTime ? e.clientY - rect.top : 0;
    let active = false;
    let timer: number | undefined;

    const begun = () => {
      active = true;
      document.body.classList.add('is-dragging');
      setDragBoth({ kind, id: task.id, day: task.due!.date, minutes: kind === 'move' ? span.start : span.end, allDay: !hasTime });
    };
    const stopTouchScroll = (ev: TouchEvent) => active && ev.cancelable && ev.preventDefault();
    const cleanup = () => {
      window.clearTimeout(timer);
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
      window.removeEventListener('pointercancel', cancel);
      window.removeEventListener('touchmove', stopTouchScroll);
      document.body.classList.remove('is-dragging');
    };
    const cancel = () => {
      cleanup();
      setDragBoth(null);
    };
    const move = (ev: PointerEvent) => {
      if (!active) {
        if (Math.hypot(ev.clientX - startX, ev.clientY - startY) < (touch ? 9 : 4)) return;
        if (touch) return cancel(); // the finger is scrolling, not dragging
        begun();
      }
      ev.preventDefault();
      setDragBoth({ kind, id: task.id, ...target(ev.clientX, ev.clientY, grab, kind, span.start) });
    };
    const up = () => {
      const d = dragRef.current;
      cleanup();
      setDragBoth(null);
      if (!active || !d) {
        if (kind === 'move') openTask(task.id); // a click, not a drag
        return;
      }
      if (d.kind === 'resize') {
        const duration = resizeDuration(span.start, d.minutes);
        if (duration !== (task.duration_minutes ?? 30)) void updateTask(task.id, { duration_minutes: duration });
        return;
      }
      const drop = d.allDay ? dropAt(d.day) : dropAt(d.day, d.minutes);
      if (drop.date !== task.due!.date || drop.time !== (task.due!.time ?? null)) void updateTask(task.id, { due_date: drop.date, due_time: drop.time });
    };

    window.addEventListener('pointermove', move, { passive: false });
    window.addEventListener('pointerup', up);
    window.addEventListener('pointercancel', cancel);
    window.addEventListener('touchmove', stopTouchScroll, { passive: false });
    if (touch) timer = window.setTimeout(begun, 320); // a finger must rest first, so scrolling still works
  }

  function addAt(day: string, e: React.MouseEvent<HTMLDivElement>) {
    if (e.target !== e.currentTarget) return;
    const r = e.currentTarget.getBoundingClientRect();
    const m = Math.max(0, Math.floor((e.clientY - r.top) / PX / 15) * 15);
    openQuickAdd({ dueDate: day, dueTime: formatMinutes(m), label: `${dayLabel(day, today)} at ${clock(formatMinutes(m), use24h)}` });
  }

  const nowMinutes = now.getHours() * 60 + now.getMinutes();
  const colours = (t: Task) => {
    const c = eventColour(projectColour(projectById(t.project_id)));
    return { ['--c' as string]: c, ['--fg' as string]: onColour(c) };
  };
  const dragged = drag ? byId.get(drag.id) : undefined;
  const ghost = (day: string) => {
    if (!drag || !dragged || drag.allDay || drag.day !== day) return null;
    const s = spanOf(dragged);
    const start = drag.kind === 'move' ? dropAtMinutes(drag.minutes) : s.start;
    const end = drag.kind === 'move' ? Math.min(start + (s.end - s.start), 1440) : s.start + resizeDuration(s.start, drag.minutes);
    return { start, end };
  };

  return (
    <div className="cal">
      <div className="cal-head" style={{ gridTemplateColumns: `52px repeat(${days.length}, minmax(0, 1fr))` }}>
        <span className="zone">{zoneLabel(now)}</span>
        {days.map((d) => {
          const date = parseIso(d);
          return (
            <button key={d} className={`cal-dayhead ${d === today ? 'today' : ''}`} onClick={() => onPickDay(d)} aria-label={`Show ${d}`}>
              <span className="dow">{date.toLocaleDateString(undefined, { weekday: 'short' })}</span>
              <span className="num">{date.getDate()}</span>
            </button>
          );
        })}
      </div>

      <div ref={allDayRow} className={`cal-allday ${drag?.allDay ? 'target' : ''}`} style={{ gridTemplateColumns: `52px repeat(${days.length}, minmax(0, 1fr))` }}>
        <span className="gutter-label" />

        {days.map((d) => (
          <div
            key={d}
            className={`allday-cell ${drag?.allDay && drag.day === d ? 'over' : ''}`}
            onClick={(e) => e.target === e.currentTarget && openQuickAdd({ dueDate: d, label: dayLabel(d, today) })}
          >
            {perDay.get(d)!.allDay.map((t) => (
              <div
                key={t.id}
                className={`chip-task ${completing.has(t.id) ? 'completing' : ''} ${drag?.id === t.id ? 'dragging' : ''}`}
                style={colours(t)}
                data-block
                onPointerDown={(e) => begin(e, t, 'move')}
              >
                <button
                  className="mini-check"
                  aria-label={`Complete ${t.title}`}
                  onPointerDown={(e) => e.stopPropagation()}
                  onClick={(e) => {
                    e.stopPropagation();
                    completeTask(t);
                  }}
                >
                  <Check size={10} strokeWidth={3.5} />
                </button>
                <span>{t.title}</span>
              </div>
            ))}
          </div>
        ))}
      </div>

      <div className="cal-scroll" ref={scroller}>
        <div className="cal-body" style={{ height: HOUR * 24, gridTemplateColumns: `52px repeat(${days.length}, minmax(0, 1fr))` }}>
          <div className="cal-gutter">
            {Array.from({ length: 23 }, (_, i) => i + 1).map((h) => (
              <span key={h} className="hour-label" style={{ top: h * HOUR - 8 }}>
                {clock(formatMinutes(h * 60), use24h)}
              </span>
            ))}
          </div>
          {days.map((d) => {
            const g = ghost(d);
            return (
              <div
                key={d}
                ref={(el) => {
                  if (el) cols.current.set(d, el);
                  else cols.current.delete(d);
                }}
                className={`cal-col ${d === today ? 'today' : ''}`}
                data-day={d}
                onClick={(e) => addAt(d, e)}
              >
                {perDay.get(d)!.placed.map((p) => {
                  const t = byId.get(p.id)!;
                  const tall = (p.end - p.start) * PX;
                  const isDrag = drag?.id === t.id;
                  return (
                    <div
                      key={p.id}
                      data-block
                      className={`block p${t.priority} ${isDrag ? 'dragging' : ''} ${completing.has(t.id) ? 'completing' : ''} ${tall < 34 ? 'tight' : ''}`}
                      style={{
                        top: p.start * PX,
                        height: tall - 2,
                        left: `calc(${(p.column / p.columns) * 100}% + 2px)`,
                        width: `calc(${100 / p.columns}% - 4px)`,
                        ...colours(t),
                      }}
                      onPointerDown={(e) => begin(e, t, 'move')}
                    >
                      <button
                        className="mini-check"
                        aria-label={`Complete ${t.title}`}
                        onPointerDown={(e) => e.stopPropagation()}
                        onClick={(e) => {
                          e.stopPropagation();
                          completeTask(t);
                        }}
                      >
                        <Check size={10} strokeWidth={3.5} />
                      </button>
                      <div className="block-text">
                        <div className="block-title">
                          {t.title}
                          {tall < 34 && <span className="block-start">, {clock(formatMinutes(p.start), use24h)}</span>}
                        </div>
                        {tall >= 44 && (
                          <div className="block-time">
                            {clock(formatMinutes(p.start), use24h)} – {clock(formatMinutes(Math.min(p.end, 1439)), use24h)}
                          </div>
                        )}
                      </div>
                      <div className="resize" onPointerDown={(e) => begin(e, t, 'resize')} aria-hidden="true" />
                    </div>
                  );
                })}
                {g && (
                  <div className="block ghost" style={{ top: g.start * PX, height: Math.max(g.end - g.start, MIN_BLOCK) * PX - 2, left: 2, right: 2 }}>
                    <div className="block-time">
                      {clock(formatMinutes(g.start), use24h)} – {clock(formatMinutes(Math.min(g.end, 1439)), use24h)}
                    </div>
                  </div>
                )}
                {d === today && (
                  <div className="now-line" style={{ top: nowMinutes * PX }}>
                    <span />
                  </div>
                )}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

/** The snapped start while a block is being moved. */
const dropAtMinutes = (m: number) => minutesOf(dropAt('x', m).time) ?? 0;

