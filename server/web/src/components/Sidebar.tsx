import { useMemo, useState } from 'react';
import { NavLink, useNavigate } from 'react-router-dom';
import { useDroppable } from '@dnd-kit/core';
import { CalendarClock, CalendarDays, CalendarRange, CircleCheckBig, Inbox, LogOut, Monitor, Moon, Plus, Search, Sun, Tag } from 'lucide-react';
import { todayIso } from '../lib/dates';
import { projectColour } from '../lib/tasks';
import { useAuth } from '../state/auth';
import { useData } from '../state/data';
import { usePrefs } from '../state/prefs';
import { useUi } from '../state/ui';
import { BrandMark } from './Brand';

const link = ({ isActive }: { isActive: boolean }) => `nav-item${isActive ? ' active' : ''}`;

function ProjectLink({ id, name, colour, count }: { id: string; name: string; colour: string; count: number }) {
  const { setNodeRef, isOver } = useDroppable({ id: `project:${id}`, data: { type: 'project' } });
  return (
    <NavLink ref={setNodeRef} to={`/project/${id}`} className={(s) => `${link(s)}${isOver ? ' drop-over' : ''}`}>
      <span className="dot" style={{ background: colour }} />
      <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{name}</span>
      {count > 0 && <span className="count">{count}</span>}
    </NavLink>
  );
}

function InboxLink({ count, id }: { count: number; id: string }) {
  const { setNodeRef, isOver } = useDroppable({ id: `project:${id}`, data: { type: 'project' } });
  return (
    <NavLink ref={setNodeRef} to="/inbox" className={(s) => `${link(s)}${isOver ? ' drop-over' : ''}`}>
      <Inbox size={17} /> Inbox {count > 0 && <span className="count">{count}</span>}
    </NavLink>
  );
}

export function Sidebar({ open }: { open: boolean }) {
  const { projects, labels, tasks, createProject, inbox } = useData();
  const { userName, signOut } = useAuth();
  const { theme, cycleTheme } = usePrefs();
  const { openQuickAdd, openPalette } = useUi();
  const navigate = useNavigate();
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState('');

  const counts = useMemo(() => {
    const today = todayIso();
    const byProject = new Map<string, number>();
    let due = 0;
    for (const t of tasks) {
      if (t.parent_id) continue;
      byProject.set(t.project_id, (byProject.get(t.project_id) ?? 0) + 1);
      if (t.due && t.due.date <= today) due++;
    }
    return { byProject, due };
  }, [tasks]);

  const ThemeIcon = theme === 'system' ? Monitor : theme === 'light' ? Sun : Moon;

  async function makeProject() {
    const n = name.trim();
    setCreating(false);
    setName('');
    if (!n) return;
    const p = await createProject(n);
    if (p) navigate(`/project/${p.id}`);
  }

  return (
    <nav className={`sidebar ${open ? 'open' : ''}`} aria-label="Navigation">
      <div className="brand">
        <BrandMark />
        ToDoz
      </div>
      <button className="add-btn" onClick={() => openQuickAdd()}>
        <Plus size={18} strokeWidth={2.5} /> Add task <kbd>Q</kbd>
      </button>
      <button className="nav-item" onClick={openPalette}>
        <Search size={17} /> Search <span className="count">Ctrl K</span>
      </button>

      <div className="side-scroll">
        <InboxLink id={inbox?.id ?? 'inbox'} count={counts.byProject.get(inbox?.id ?? 'inbox') ?? 0} />
        <NavLink to="/today" className={link}>
          <CalendarDays size={17} /> Today {counts.due > 0 && <span className="count">{counts.due}</span>}
        </NavLink>
        <NavLink to="/upcoming" className={link}>
          <CalendarRange size={17} /> Upcoming
        </NavLink>
        <NavLink to="/calendar" className={link}>
          <CalendarClock size={17} /> Calendar
        </NavLink>
        <NavLink to="/completed" className={link}>
          <CircleCheckBig size={17} /> Completed
        </NavLink>

        <div className="nav-head">
          <span>Projects</span>
          <button className="icon-btn" aria-label="New project" title="New project" onClick={() => setCreating(true)}>
            <Plus size={16} />
          </button>
        </div>
        {projects
          .filter((p) => !p.is_inbox)
          .map((p) => (
            <ProjectLink key={p.id} id={p.id} name={p.name} colour={projectColour(p)} count={counts.byProject.get(p.id) ?? 0} />
          ))}
        {creating && (
          <input
            className="nav-input"
            autoFocus
            placeholder="Project name"
            value={name}
            maxLength={100}
            onChange={(e) => setName(e.target.value)}
            onBlur={() => void makeProject()}
            onKeyDown={(e) => {
              if (e.key === 'Enter') void makeProject();
              if (e.key === 'Escape') {
                setName('');
                setCreating(false);
              }
            }}
          />
        )}

        {labels.length > 0 && (
          <>
            <div className="nav-head">
              <span>Labels</span>
            </div>
            {labels.map((l) => (
              <NavLink key={l.id} to={`/label/${l.id}`} className={link}>
                <Tag size={16} /> {l.name}
              </NavLink>
            ))}
          </>
        )}
      </div>

      <div className="sidebar-foot">
        <span className="avatar">{(userName.trim()[0] ?? '?').toUpperCase()}</span>
        <span className="who">{userName || 'Signed in'}</span>
        <button className="icon-btn" onClick={cycleTheme} aria-label={`Theme: ${theme}`} title={`Theme: ${theme}`}>
          <ThemeIcon size={16} />
        </button>
        <button className="icon-btn" onClick={() => void signOut()} aria-label="Sign out" title="Sign out">
          <LogOut size={16} />
        </button>
      </div>
    </nav>
  );
}
