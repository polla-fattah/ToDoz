import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { CalendarClock, CalendarDays, CalendarRange, CircleCheckBig, CornerDownLeft, Hash, Inbox, LogOut, Moon, Plus, Search, Tag } from 'lucide-react';
import { dueText } from '../lib/dates';
import { projectColour } from '../lib/tasks';
import { useAuth } from '../state/auth';
import { useData } from '../state/data';
import { usePrefs } from '../state/prefs';

interface Item {
  id: string;
  group: 'Actions' | 'Go to' | 'Projects' | 'Labels' | 'Tasks';
  label: string;
  where?: string;
  icon: React.ReactNode;
  run: () => void;
}

const rank = (label: string, q: string) => (label.toLowerCase().startsWith(q) ? 0 : label.toLowerCase().split(/\s+/).some((w) => w.startsWith(q)) ? 1 : 2);

/** Ctrl+K: jump anywhere, find a task, or do something, from the keyboard. */
export function CommandPalette({ onClose, onAddTask, onOpenTask }: { onClose: () => void; onAddTask: () => void; onOpenTask: (id: string) => void }) {
  const { projects, labels, tasks, projectById } = useData();
  const { cycleTheme, use24h } = usePrefs();
  const { signOut } = useAuth();
  const navigate = useNavigate();
  const [q, setQ] = useState('');
  const [active, setActive] = useState(0);
  const list = useRef<HTMLDivElement>(null);

  const items = useMemo<Item[]>(() => {
    const go = (to: string) => () => {
      onClose();
      navigate(to);
    };
    const all: Item[] = [
      { id: 'add', group: 'Actions', label: 'Add task', icon: <Plus size={16} />, run: () => { onClose(); onAddTask(); } },
      { id: 'theme', group: 'Actions', label: 'Change theme (system, light, dark)', icon: <Moon size={16} />, run: () => { cycleTheme(); onClose(); } },
      { id: 'out', group: 'Actions', label: 'Sign out', icon: <LogOut size={16} />, run: () => void signOut() },
      { id: 'inbox', group: 'Go to', label: 'Inbox', icon: <Inbox size={16} />, run: go('/inbox') },
      { id: 'today', group: 'Go to', label: 'Today', icon: <CalendarDays size={16} />, run: go('/today') },
      { id: 'upcoming', group: 'Go to', label: 'Upcoming', icon: <CalendarRange size={16} />, run: go('/upcoming') },
      { id: 'calendar', group: 'Go to', label: 'Calendar', icon: <CalendarClock size={16} />, run: go('/calendar') },
      { id: 'completed', group: 'Go to', label: 'Completed', icon: <CircleCheckBig size={16} />, run: go('/completed') },
      ...projects.filter((p) => !p.is_inbox).map<Item>((p) => ({ id: `p${p.id}`, group: 'Projects', label: p.name, icon: <Hash size={16} color={projectColour(p)} />, run: go(`/project/${p.id}`) })),
      ...labels.map<Item>((l) => ({ id: `l${l.id}`, group: 'Labels', label: l.name, icon: <Tag size={16} />, run: go(`/label/${l.id}`) })),
    ];
    const needle = q.trim().toLowerCase();
    if (!needle) return all.filter((i) => i.group !== 'Labels');
    const taskItems = tasks
      .filter((t) => `${t.title} ${t.description}`.toLowerCase().includes(needle))
      .slice(0, 30)
      .map<Item>((t) => ({
        id: `t${t.id}`,
        group: 'Tasks',
        label: t.title,
        where: [t.due ? dueText(t.due, use24h) : '', projectById(t.project_id)?.name ?? ''].filter(Boolean).join(' · '),
        icon: <Search size={16} />,
        run: () => {
          onClose();
          onOpenTask(t.id);
        },
      }));
    return [...all.filter((i) => i.label.toLowerCase().includes(needle)).sort((a, b) => rank(a.label, needle) - rank(b.label, needle)), ...taskItems].slice(0, 40);
  }, [q, projects, labels, tasks, projectById, use24h, navigate, onClose, onAddTask, onOpenTask, cycleTheme, signOut]);

  useEffect(() => setActive(0), [q]);
  useEffect(() => {
    list.current?.querySelector('[data-active="true"]')?.scrollIntoView({ block: 'nearest' });
  }, [active]);

  const groups = items.reduce<Record<string, { item: Item; index: number }[]>>((acc, item, index) => {
    (acc[item.group] ??= []).push({ item, index });
    return acc;
  }, {});

  return (
    <div className="modal-wrap" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal" role="dialog" aria-label="Command palette">
        <div className="palette-input">
          <Search size={18} />
          <input
            autoFocus
            value={q}
            placeholder="Search tasks, jump to a project, or run a command…"
            onChange={(e) => setQ(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'ArrowDown') {
                e.preventDefault();
                setActive((a) => Math.min(a + 1, items.length - 1));
              } else if (e.key === 'ArrowUp') {
                e.preventDefault();
                setActive((a) => Math.max(a - 1, 0));
              } else if (e.key === 'Enter') {
                e.preventDefault();
                items[active]?.run();
              } else if (e.key === 'Escape') {
                onClose();
              }
            }}
          />
        </div>
        <div className="palette-list" ref={list}>
          {items.length === 0 && <div className="palette-empty">Nothing matches “{q}”.</div>}
          {Object.entries(groups).map(([group, rows]) => (
            <div key={group}>
              <div className="palette-group">{group}</div>
              {rows.map(({ item, index }) => (
                <button key={item.id} className={`palette-item ${index === active ? 'active' : ''}`} data-active={index === active} onMouseMove={() => setActive(index)} onClick={item.run}>
                  {item.icon}
                  <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{item.label}</span>
                  {item.where && <span className="where">{item.where}</span>}
                </button>
              ))}
            </div>
          ))}
        </div>
        <div className="palette-foot">
          <span><kbd>↑</kbd> <kbd>↓</kbd> to move</span>
          <span><kbd><CornerDownLeft size={10} /></kbd> to open</span>
          <span><kbd>Esc</kbd> to close</span>
        </div>
      </div>
    </div>
  );
}
