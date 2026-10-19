import { useEffect, useMemo, useRef, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { ChevronDown, ChevronLeft, ChevronRight, Plus } from 'lucide-react';
import { MonthGrid } from '../components/MonthGrid';
import { Skeleton } from '../components/Page';
import { TimeGrid } from '../components/TimeGrid';
import { parseIso, todayIso } from '../lib/dates';
import { daysOf, shiftAnchor, type CalendarMode } from '../lib/timegrid';
import { useData } from '../state/data';
import { usePrefs } from '../state/prefs';
import { useUi } from '../state/ui';
import { isTyping, useKeydown } from '../ui/hooks';
import type { Task } from '../types';

const LABELS: Record<CalendarMode, string> = { day: 'Day', three: '3 days', week: 'Week', month: 'Month' };
const KEYS: Record<CalendarMode, string> = { day: 'D', three: '3', week: 'W', month: 'M' };

/** A phone-sized window has no room for a week. */
function useWide() {
  const [wide, setWide] = useState(() => window.matchMedia('(min-width: 900px)').matches);
  useEffect(() => {
    const q = window.matchMedia('(min-width: 900px)');
    const on = () => setWide(q.matches);
    q.addEventListener('change', on);
    return () => q.removeEventListener('change', on);
  }, []);
  return wide;
}

/** As Google's header does: the month (or both months) and the year; a single day is written out. */
function titleFor(mode: CalendarMode, days: string[], anchor: string): string {
  const first = parseIso(days[0]);
  const last = parseIso(days[days.length - 1]);
  if (mode === 'month') return parseIso(anchor).toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
  if (mode === 'day') return first.toLocaleDateString(undefined, { day: 'numeric', month: 'long', year: 'numeric' });
  if (first.getFullYear() !== last.getFullYear()) {
    const a = first.toLocaleDateString(undefined, { month: 'short', year: 'numeric' });
    const b = last.toLocaleDateString(undefined, { month: 'short', year: 'numeric' });
    return `${a} – ${b}`;
  }
  if (first.getMonth() !== last.getMonth()) {
    const a = first.toLocaleDateString(undefined, { month: 'short' });
    const b = last.toLocaleDateString(undefined, { month: 'short', year: 'numeric' });
    return `${a} – ${b}`;
  }
  return first.toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
}

/** The view picker: one button that opens a short list, with the keyboard shortcuts beside each view. */
function ViewMenu<T extends string>({ value, options, labels, keys, onPick }: { value: T; options: T[]; labels: Record<T, string>; keys: Record<T, string>; onPick: (v: T) => void }) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const away = (e: PointerEvent) => !box.current?.contains(e.target as Node) && setOpen(false);
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false);
    window.addEventListener('pointerdown', away);
    window.addEventListener('keydown', esc);
    return () => {
      window.removeEventListener('pointerdown', away);
      window.removeEventListener('keydown', esc);
    };
  }, [open]);
  return (
    <div className="view-menu" ref={box}>
      <button className="cal-pill" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
        {labels[value]}
        <ChevronDown size={16} />
      </button>
      {open && (
        <div className="view-list" role="menu">
          {options.map((o) => (
            <button
              key={o}
              role="menuitemradio"
              aria-checked={o === value}
              className={o === value ? 'on' : ''}
              onClick={() => {
                onPick(o);
                setOpen(false);
              }}
            >
              <span>{labels[o]}</span>
              <kbd>{keys[o]}</kbd>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/** Calendar: Day, 3 Days, Week (wide screens only) and Month, over every open task that has a date. */
export function CalendarView({ tasksOverride, title }: { tasksOverride?: Task[]; title?: string }) {
  const { ready, tasks: all } = useData();
  const { calendarMode, setCalendarMode, weekStart } = usePrefs();
  const { openQuickAdd } = useUi();
  const wide = useWide();
  const [params, setParams] = useSearchParams();
  const today = todayIso();
  const stored = params.get('date');
  const anchor = stored && /^\d{4}-\d{2}-\d{2}$/.test(stored) ? stored : today;
  const mode: CalendarMode = calendarMode === 'week' && !wide ? 'three' : calendarMode;
  const days = useMemo(() => daysOf(mode, anchor, weekStart), [mode, anchor, weekStart]);
  const tasks = tasksOverride ?? all;

  const go = (date: string) => setParams((p) => { const n = new URLSearchParams(p); if (date === today) n.delete('date'); else n.set('date', date); return n; }, { replace: true });
  const step = (dir: 1 | -1) => go(shiftAnchor(mode, anchor, dir));
  const pickDay = (d: string) => {
    setCalendarMode('day');
    go(d);
  };

  useKeydown((e) => {
    if (isTyping(e.target) || e.ctrlKey || e.metaKey || e.altKey || document.querySelector('.modal-wrap, .panel, .popover')) return;
    if (e.key === 'ArrowLeft') step(-1);
    else if (e.key === 'ArrowRight') step(1);
    else if (e.key === 't') go(today);
    else if (e.key === 'd') setCalendarMode('day');
    else if (e.key === '3') setCalendarMode('three');
    else if (e.key === 'w' && wide) setCalendarMode('week');
    else if (e.key === 'm') setCalendarMode('month');
    else return;
    e.preventDefault();
  });

  const modes = (['day', 'three', 'week', 'month'] as CalendarMode[]).filter((m) => m !== 'week' || wide);
  const month = parseIso(anchor).getMonth();

  return (
    <div className="scroll cal-page">
      <div className="cal-bar">
        <button className="cal-pill" onClick={() => go(today)}>
          Today
        </button>
        <span className="nav-pair">
          <button className="cal-round" aria-label="Previous" onClick={() => step(-1)}>
            <ChevronLeft size={20} />
          </button>
          <button className="cal-round" aria-label="Next" onClick={() => step(1)}>
            <ChevronRight size={20} />
          </button>
        </span>
        <h1 className="cal-title">
          {title && <span className="cal-scope">{title}</span>}
          {titleFor(mode, days, anchor)}
        </h1>
        <span className="spacer" />
        <ViewMenu value={mode} options={modes} labels={LABELS} keys={KEYS} onPick={setCalendarMode} />
        <button className="cal-add" onClick={() => openQuickAdd({ dueDate: days.includes(today) ? today : days[0], label: 'the calendar' })}>
          <Plus size={18} /> Add
        </button>
      </div>
      {!ready ? (
        <div className="page">
          <Skeleton />
        </div>
      ) : mode === 'month' ? (
        <MonthGrid days={days} month={month} tasks={tasks} onPickDay={pickDay} />
      ) : (
        <TimeGrid days={days} tasks={tasks} onPickDay={pickDay} />
      )}
    </div>
  );
}

