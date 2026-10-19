import { useEffect, useMemo, useRef, useState } from 'react';
import { useDroppable, type DragEndEvent, type DragOverEvent } from '@dnd-kit/core';
import { SortableContext, verticalListSortingStrategy } from '@dnd-kit/sortable';
import { ChevronDown, ChevronRight, KanbanSquare, List, MoreHorizontal, Pencil, Plus, Rows3, Trash2 } from 'lucide-react';
import { useParams } from 'react-router-dom';
import { InlineAdd } from '../components/InlineAdd';
import { EmptyState, PageHeader, Skeleton } from '../components/Page';
import { SortableCard, TaskRow } from '../components/TaskRow';
import { buildColumns, colKey, moveAcross, NONE, reorderWithin, sectionOf, type Columns } from '../lib/order';
import { byOrder } from '../lib/tasks';
import { useData } from '../state/data';
import { usePrefs } from '../state/prefs';
import { useUi } from '../state/ui';
import { Popover } from '../ui/Popover';
import type { Section, Task } from '../types';

/* ---------------------------------------------------------------- the drag logic, shared by list and board */

function useProjectDrag(base: Columns) {
  const ui = useUi();
  const { commitDrop } = useData();
  const [drag, setDrag] = useState<Columns | null>(null);
  const dragRef = useRef<Columns | null>(null);
  const start = useRef<Columns>(base);
  const baseRef = useRef(base);
  baseRef.current = base;

  const set = (c: Columns | null) => {
    dragRef.current = c;
    setDrag(c);
  };

  useEffect(() => {
    const below = (e: DragOverEvent) => {
      const moved = e.active.rect.current.translated;
      return !!moved && !!e.over && moved.top > e.over.rect.top + e.over.rect.height / 2;
    };
    ui.dragHandlers.current = {
      onDragStart: () => {
        start.current = baseRef.current;
        set(baseRef.current);
      },
      onDragOver: (e: DragOverEvent) => {
        if (!e.over || String(e.over.id).startsWith('project:')) return;
        const next = moveAcross(dragRef.current ?? baseRef.current, String(e.active.id), String(e.over.id), below(e));
        if (next !== dragRef.current) set(next);
      },
      onDragEnd: (e: DragEndEvent) => {
        const activeId = String(e.active.id);
        const over = e.over ? String(e.over.id) : null;
        let final = dragRef.current ?? start.current;
        if (over && !over.startsWith('project:')) final = reorderWithin(final, activeId, over);
        const before = start.current;
        set(null);
        if (over && !over.startsWith('project:')) void commitDrop(before, final, activeId);
      },
      onDragCancel: () => set(null),
    };
    return () => {
      ui.dragHandlers.current = {};
    };
  });

  return drag ?? base;
}

/* ---------------------------------------------------------------- sections */

function SectionMenu({ section, onRename }: { section: Section; onRename: () => void }) {
  const { deleteSection } = useData();
  const [open, setOpen] = useState(false);
  const btn = useRef<HTMLButtonElement>(null);
  return (
    <>
      <button ref={btn} className="icon-btn" aria-label={`Section ${section.name} menu`} onClick={() => setOpen((v) => !v)}>
        <MoreHorizontal size={16} />
      </button>
      {open && (
        <Popover anchor={btn.current} onClose={() => setOpen(false)} alignEnd>
          <button
            className="menu-item"
            onClick={() => {
              setOpen(false);
              onRename();
            }}
          >
            <Pencil size={15} /> Rename
          </button>
          <button
            className="menu-item danger"
            onClick={() => {
              setOpen(false);
              void deleteSection(section);
            }}
          >
            <Trash2 size={15} /> Delete section
          </button>
        </Popover>
      )}
    </>
  );
}

function SectionName({ section, editing, setEditing }: { section: Section; editing: boolean; setEditing: (v: boolean) => void }) {
  const { renameSection } = useData();
  const [name, setName] = useState(section.name);
  if (!editing) return <span onDoubleClick={() => setEditing(true)}>{section.name}</span>;
  const done = () => {
    setEditing(false);
    const n = name.trim();
    if (n && n !== section.name) void renameSection(section.id, n);
    else setName(section.name);
  };
  return (
    <input
      className="nav-input"
      style={{ margin: 0, height: 26, width: 200 }}
      autoFocus
      value={name}
      maxLength={100}
      onChange={(e) => setName(e.target.value)}
      onBlur={done}
      onKeyDown={(e) => {
        if (e.key === 'Enter') done();
        if (e.key === 'Escape') {
          setName(section.name);
          setEditing(false);
        }
      }}
    />
  );
}

function NewSection({ projectId, board }: { projectId: string; board?: boolean }) {
  const { createSection } = useData();
  const [open, setOpen] = useState(false);
  const [name, setName] = useState('');
  const commit = () => {
    const n = name.trim();
    setOpen(false);
    setName('');
    if (n) void createSection(projectId, n);
  };
  if (!open)
    return (
      <div className={board ? 'new-col' : ''} style={board ? undefined : { margin: '10px 0' }}>
        <button
          onClick={() => setOpen(true)}
          className={board ? '' : 'add-inline'}
          style={board ? undefined : { paddingLeft: 4 }}
        >
          <Plus size={16} /> Add section
        </button>
      </div>
    );
  return (
    <div className={board ? 'new-col' : ''}>
      <input
        className="nav-input"
        autoFocus
        placeholder="Section name"
        value={name}
        maxLength={100}
        onChange={(e) => setName(e.target.value)}
        onBlur={commit}
        onKeyDown={(e) => {
          if (e.key === 'Enter') commit();
          if (e.key === 'Escape') {
            setName('');
            setOpen(false);
          }
        }}
      />
    </div>
  );
}

/* ---------------------------------------------------------------- list layout */

function RowTree({ task, tasks, depth = 0 }: { task: Task; tasks: Task[]; depth?: number }) {
  const children = tasks.filter((t) => t.parent_id === task.id).sort(byOrder);
  return (
    <>
      <TaskRow task={task} sub={depth > 0} drag={depth === 0 ? 'sortable' : 'none'} />
      {children.map((c) => (
        <RowTree key={c.id} task={c} tasks={tasks} depth={depth + 1} />
      ))}
    </>
  );
}

function ListSection({ id, title, section, ids, tasks, projectId, showHead }: { id: string; title: string; section?: Section; ids: string[]; tasks: Task[]; projectId: string; showHead: boolean }) {
  const { setNodeRef, isOver } = useDroppable({ id, data: { type: 'column' } });
  const [collapsed, setCollapsed] = useState(false);
  const [editing, setEditing] = useState(false);
  const byId = useMemo(() => new Map(tasks.map((t) => [t.id, t])), [tasks]);
  return (
    <div className="group" ref={setNodeRef} style={isOver ? { background: 'color-mix(in srgb, var(--accent) 6%, transparent)', borderRadius: 10 } : undefined}>
      {showHead && (
        <div className="group-head">
          <button className="chev icon-btn" style={{ width: 22, height: 22 }} aria-label={collapsed ? 'Expand' : 'Collapse'} onClick={() => setCollapsed((v) => !v)}>
            {collapsed ? <ChevronRight size={15} /> : <ChevronDown size={15} />}
          </button>
          {section ? <SectionName section={section} editing={editing} setEditing={setEditing} /> : <span>{title}</span>}
          <span className="n">{ids.length || ''}</span>
          <span className="spacer" />
          {section && <SectionMenu section={section} onRename={() => setEditing(true)} />}
        </div>
      )}
      {!collapsed && (
        <>
          <SortableContext items={ids} strategy={verticalListSortingStrategy}>
            {ids.map((tid) => {
              const t = byId.get(tid);
              return t ? <RowTree key={tid} task={t} tasks={tasks} /> : null;
            })}
          </SortableContext>
          <InlineAdd projectId={projectId} sectionId={sectionOf(id)} destination={section?.name} />
        </>
      )}
    </div>
  );
}

/* ---------------------------------------------------------------- board layout */

function BoardColumn({ id, title, section, ids, byId, projectId }: { id: string; title: string; section?: Section; ids: string[]; byId: Map<string, Task>; projectId: string }) {
  const { setNodeRef, isOver } = useDroppable({ id, data: { type: 'column' } });
  const [editing, setEditing] = useState(false);
  return (
    <div className={`col ${isOver ? 'over' : ''}`}>
      <div className="col-head">
        {section ? <SectionName section={section} editing={editing} setEditing={setEditing} /> : <span>{title}</span>}
        <span className="n">{ids.length}</span>
        <span className="spacer" />
        {section && <SectionMenu section={section} onRename={() => setEditing(true)} />}
      </div>
      <div className="col-cards" ref={setNodeRef}>
        <SortableContext items={ids} strategy={verticalListSortingStrategy}>
          {ids.map((tid) => {
            const t = byId.get(tid);
            return t ? <SortableCard key={tid} task={t} /> : null;
          })}
        </SortableContext>
        {ids.length === 0 && <div className="col-empty">Drop tasks here</div>}
      </div>
      <div className="col-add">
        <InlineAdd projectId={projectId} sectionId={sectionOf(id)} destination={section?.name} />
      </div>
    </div>
  );
}

/* ---------------------------------------------------------------- the page */

export function ProjectView({ inbox }: { inbox?: boolean }) {
  const params = useParams();
  const { ready, projects, sections: allSections, tasks, inbox: inboxProject } = useData();
  const { layoutOf, setLayoutOf } = usePrefs();
  const projectId = inbox ? (inboxProject?.id ?? 'inbox') : (params.id ?? '');
  const project = projects.find((p) => p.id === projectId);

  const sections = useMemo(() => allSections.filter((s) => s.project_id === projectId), [allSections, projectId]);
  const projectTasks = useMemo(() => tasks.filter((t) => t.project_id === projectId), [tasks, projectId]);
  const base = useMemo(() => buildColumns(projectTasks, sections), [projectTasks, sections]);
  const cols = useProjectDrag(base);
  const dragging = cols !== base;
  const layout = inbox ? 'list' : layoutOf(projectId);
  const byId = useMemo(() => new Map(projectTasks.map((t) => [t.id, t])), [projectTasks]);
  const sectionById = useMemo(() => new Map(sections.map((s) => [colKey(s.id), s])), [sections]);

  if (!ready) {
    return (
      <div className="scroll">
        <div className="page">
          <Skeleton />
        </div>
      </div>
    );
  }
  if (!project) {
    return (
      <div className="scroll">
        <div className="page">
          <EmptyState icon={Rows3} title="This project is not here">
            It may have been deleted or archived on another device.
          </EmptyState>
        </div>
      </div>
    );
  }

  const open = projectTasks.filter((t) => !t.parent_id).length;
  // Columns in section order; tasks in a section that no longer exists get a column of their own so they are not lost.
  const keys = [NONE, ...sections.map((s) => colKey(s.id)), ...Object.keys(cols).filter((k) => k !== NONE && !sectionById.has(k))];
  const visible = keys.filter((k) => k !== NONE || cols[NONE]?.length > 0 || dragging || sections.length === 0);
  const titleOf = (k: string) => (k === NONE ? (sections.length ? 'No section' : '') : (sectionById.get(k)?.name ?? 'Other'));

  const actions = !inbox && (
    <div className="seg" role="group" aria-label="Layout">
      <button className={layout === 'list' ? 'on' : ''} onClick={() => setLayoutOf(projectId, 'list')}>
        <List size={15} /> List
      </button>
      <button className={layout === 'board' ? 'on' : ''} onClick={() => setLayoutOf(projectId, 'board')}>
        <KanbanSquare size={15} /> Board
      </button>
    </div>
  );

  if (layout === 'board') {
    return (
      <div className="scroll">
        <div className="page" style={{ paddingBottom: 0 }}>
          <PageHeader title={project.name} sub={open ? `${open} task${open === 1 ? '' : 's'}` : ''} actions={actions} />
        </div>
        <div className="board">
          {visible.map((k) => (
            <BoardColumn key={k} id={k} title={k === NONE ? 'No section' : titleOf(k)} section={sectionById.get(k)} ids={cols[k] ?? []} byId={byId} projectId={projectId} />
          ))}
          <NewSection projectId={projectId} board />
        </div>
      </div>
    );
  }

  return (
    <div className="scroll">
      <div className="page">
        <PageHeader title={project.name} sub={open ? `${open} task${open === 1 ? '' : 's'}` : ''} actions={actions} />
        {open === 0 && sections.length === 0 && (
          <EmptyState icon={Rows3} title={inbox ? 'Your inbox is empty' : 'A fresh start'}>
            {inbox ? 'Anything you add without a project lands here.' : 'Add the first task below.'}
          </EmptyState>
        )}
        {visible.map((k) => (
          <ListSection
            key={k}
            id={k}
            title={titleOf(k)}
            section={sectionById.get(k)}
            ids={cols[k] ?? []}
            tasks={projectTasks}
            projectId={projectId}
            showHead={sections.length > 0 || k !== NONE}
          />
        ))}
        {!inbox && <NewSection projectId={projectId} />}
      </div>
    </div>
  );
}

