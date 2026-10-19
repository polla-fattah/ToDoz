import { useMemo, useState } from 'react';
import { Ban, CalendarDays, CalendarPlus, Check, ChevronLeft, ChevronRight, Flag, Hash, Inbox, Plus, Sofa, Sun } from 'lucide-react';
import { addDays, isoDate, monthGrid, nextMonday, parseIso, todayIso } from '../lib/dates';
import { projectColour, weekdayShort } from '../lib/tasks';
import { Popover } from '../ui/Popover';
import { useData } from '../state/data';
import type { Due, Priority, Project } from '../types';

export const PRIORITY_NAMES: Record<Priority, string> = { 1: 'Priority 1', 2: 'Priority 2', 3: 'Priority 3', 4: 'Priority 4' };
export const priorityColour = (p: Priority) => `var(--p${p})`;

/* ---------------------------------------------------------------- date */

const REPEATS: [string, string][] = [
  ['', 'Does not repeat'],
  ['every day', 'Every day'],
  ['every workday', 'Every workday'],
  ['every week', 'Every week'],
  ['every month', 'Every month'],
  ['every year', 'Every year'],
];

export interface DateChange {
  due_date?: string | null;
  due_time?: string | null;
  recurrence?: string | null;
}

export function DatePopover({ anchor, due, onChange, onClose }: { anchor: HTMLElement | null; due: Due | null; onChange: (c: DateChange) => void; onClose: () => void }) {
  const today = todayIso();
  const shown = due ? parseIso(due.date) : new Date();
  const [month, setMonth] = useState({ y: shown.getFullYear(), m: shown.getMonth() });
  const cells = useMemo(() => monthGrid(month.y, month.m), [month]);
  const title = new Date(month.y, month.m, 1).toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
  const step = (n: number) => setMonth(({ y, m }) => ({ y: m + n < 0 ? y - 1 : m + n > 11 ? y + 1 : y, m: (m + n + 12) % 12 }));
  const pick = (iso: string | null) => {
    onChange({ due_date: iso });
    onClose();
  };
  const mondayAfter = nextMonday(today);
  const weekend = (() => {
    const d = parseIso(today);
    return isoDate(new Date(d.getFullYear(), d.getMonth(), d.getDate() + ((6 - d.getDay() + 7) % 7 || 7)));
  })();
  const customRepeat = due?.recurrence && !REPEATS.some(([v]) => v === due.recurrence);

  return (
    <Popover anchor={anchor} onClose={onClose} className="date-pop">
      <button className="quick-date" onClick={() => pick(today)}>
        <Sun size={16} color="var(--ok)" /> Today <span className="right">{weekdayShort(today)}</span>
      </button>
      <button className="quick-date" onClick={() => pick(addDays(today, 1))}>
        <CalendarPlus size={16} color="var(--warn)" /> Tomorrow <span className="right">{weekdayShort(addDays(today, 1))}</span>
      </button>
      <button className="quick-date" onClick={() => pick(weekend)}>
        <Sofa size={16} color="var(--accent-text)" /> This weekend <span className="right">{weekdayShort(weekend)}</span>
      </button>
      <button className="quick-date" onClick={() => pick(mondayAfter)}>
        <CalendarDays size={16} color="var(--accent-text)" /> Next week <span className="right">{weekdayShort(mondayAfter)}</span>
      </button>
      {due && (
        <button className="quick-date" onClick={() => pick(null)}>
          <Ban size={16} color="var(--text-3)" /> No date
        </button>
      )}
      <div className="menu-sep" />
      <div className="cal-head">
        <span>{title}</span>
        <span>
          <button className="icon-btn" aria-label="Previous month" onClick={() => step(-1)}>
            <ChevronLeft size={16} />
          </button>
          <button className="icon-btn" aria-label="Next month" onClick={() => step(1)}>
            <ChevronRight size={16} />
          </button>
        </span>
      </div>
      <div className="cal-grid">
        {['M', 'T', 'W', 'T', 'F', 'S', 'S'].map((d, i) => (
          <span key={i} className="cal-dow">
            {d}
          </span>
        ))}
        {cells.map((iso) => {
          const d = parseIso(iso);
          const cls = ['cal-day', d.getMonth() !== month.m ? 'dim' : '', iso === today ? 'today' : '', iso === due?.date ? 'sel' : ''].join(' ');
          return (
            <button key={iso} className={cls} onClick={() => pick(iso)} aria-label={iso}>
              {d.getDate()}
            </button>
          );
        })}
      </div>
      <div className="date-extras">
        <div className="row">
          <span>Time</span>
          <input
            type="time"
            value={due?.time ?? ''}
            disabled={!due}
            onChange={(e) => onChange({ due_time: e.target.value || null })}
            aria-label="Time"
          />
        </div>
        <div className="row">
          <span>Repeat</span>
          <select value={due?.recurrence ?? ''} disabled={!due} onChange={(e) => onChange({ recurrence: e.target.value || null })} aria-label="Repeat">
            {REPEATS.map(([v, label]) => (
              <option key={v} value={v}>
                {label}
              </option>
            ))}
            {customRepeat && <option value={due!.recurrence!}>{due!.recurrence}</option>}
          </select>
        </div>
      </div>
    </Popover>
  );
}

/* ---------------------------------------------------------------- priority */

export function PriorityMenu({ anchor, value, onPick, onClose }: { anchor: HTMLElement | null; value: Priority; onPick: (p: Priority) => void; onClose: () => void }) {
  return (
    <Popover anchor={anchor} onClose={onClose}>
      {([1, 2, 3, 4] as Priority[]).map((p) => (
        <button
          key={p}
          className="menu-item prio-opt"
          onClick={() => {
            onPick(p);
            onClose();
          }}
        >
          <Flag size={16} color={priorityColour(p)} fill={p === 4 ? 'none' : priorityColour(p)} /> {PRIORITY_NAMES[p]}
          {p === value && <Check size={15} className="right" />}
        </button>
      ))}
    </Popover>
  );
}

/* ---------------------------------------------------------------- project */

export function ProjectDot({ project }: { project: Project | undefined }) {
  return project?.is_inbox ? <Inbox size={14} color="var(--accent-text)" /> : <span className="dot" style={{ background: projectColour(project) }} />;
}

export function ProjectMenu({ anchor, value, onPick, onClose }: { anchor: HTMLElement | null; value: string; onPick: (id: string) => void; onClose: () => void }) {
  const { projects } = useData();
  const [q, setQ] = useState('');
  const list = projects.filter((p) => p.name.toLowerCase().includes(q.trim().toLowerCase()));
  return (
    <Popover anchor={anchor} onClose={onClose}>
      <input className="menu-input" autoFocus placeholder="Move to project…" value={q} onChange={(e) => setQ(e.target.value)} />
      <div className="menu-list">
        {list.map((p) => (
          <button
            key={p.id}
            className="menu-item"
            onClick={() => {
              onPick(p.id);
              onClose();
            }}
          >
            {p.is_inbox ? <Inbox size={15} color="var(--accent-text)" /> : <Hash size={15} color={projectColour(p)} />} {p.name}
            {p.id === value && <Check size={15} className="right" />}
          </button>
        ))}
        {!list.length && <div className="palette-empty">No project like that.</div>}
      </div>
    </Popover>
  );
}

/* ---------------------------------------------------------------- labels */

export function LabelsMenu({ anchor, value, onChange, onClose }: { anchor: HTMLElement | null; value: string[]; onChange: (labels: string[]) => void; onClose: () => void }) {
  const { labels } = useData();
  const [q, setQ] = useState('');
  const has = (name: string) => value.some((v) => v.toLowerCase() === name.toLowerCase());
  const toggle = (name: string) => onChange(has(name) ? value.filter((v) => v.toLowerCase() !== name.toLowerCase()) : [...value, name]);
  const typed = q.trim().replace(/^[%@]/, '');
  const shown = labels.filter((l) => l.name.toLowerCase().includes(typed.toLowerCase()));
  const canCreate = typed && !labels.some((l) => l.name.toLowerCase() === typed.toLowerCase());
  return (
    <Popover anchor={anchor} onClose={onClose}>
      <input
        className="menu-input"
        autoFocus
        placeholder="Find or create a label…"
        value={q}
        onChange={(e) => setQ(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter' && typed) {
            toggle(shown.find((l) => l.name.toLowerCase() === typed.toLowerCase())?.name ?? typed);
            setQ('');
          }
        }}
      />
      <div className="menu-list">
        {shown.map((l) => (
          <button key={l.id} className="menu-item" onClick={() => toggle(l.name)}>
            <span style={{ color: 'var(--text-3)' }}>%</span> {l.name}
            {has(l.name) && <Check size={15} className="right" />}
          </button>
        ))}
        {canCreate && (
          <button
            className="menu-item"
            onClick={() => {
              toggle(typed);
              setQ('');
            }}
          >
            <Plus size={15} /> Create “{typed}”
          </button>
        )}
        {!shown.length && !canCreate && <div className="palette-empty">No labels yet. Type a name to make one.</div>}
      </div>
    </Popover>
  );
}
