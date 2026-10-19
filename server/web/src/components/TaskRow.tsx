import { useRef, useState, type CSSProperties, type HTMLAttributes } from 'react';
import { useDraggable } from '@dnd-kit/core';
import { useSortable } from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import { Calendar, Check, GripVertical, ListTree, Pencil, Repeat, Tag } from 'lucide-react';
import { dueText, dueTone } from '../lib/dates';
import { useData } from '../state/data';
import { usePrefs } from '../state/prefs';
import { useUi } from '../state/ui';
import type { Task } from '../types';
import { DatePopover, ProjectDot } from './pickers';

export type DragKind = 'sortable' | 'draggable' | 'none';

interface RowProps {
  task: Task;
  /** Show which project the task is in (lists that mix projects). */
  showProject?: boolean;
  sub?: boolean;
  drag?: DragKind;
  /** The marker above the row where a dropped task would land. */
  className?: string;
}

/** What a task's chips say: date, repeat, sub-tasks, labels and (optionally) the project. */
function Meta({ task, showProject }: { task: Task; showProject?: boolean }) {
  const { tasks, projectById } = useData();
  const { use24h } = usePrefs();
  const subs = tasks.filter((t) => t.parent_id === task.id).length;
  const project = projectById(task.project_id);
  const has = task.due || subs || task.labels.length || showProject;
  if (!has) return null;
  return (
    <div className="meta">
      {task.due && (
        <span className={`chip ${dueTone(task.due.date)}`}>
          {task.due.recurrence ? <Repeat size={12} /> : <Calendar size={12} />}
          {dueText(task.due, use24h)}
        </span>
      )}
      {subs > 0 && (
        <span className="chip">
          <ListTree size={12} /> {subs}
        </span>
      )}
      {task.labels.map((l) => (
        <span key={l} className="chip">
          <Tag size={12} /> {l}
        </span>
      ))}
      {showProject && project && (
        <span className="chip">
          <ProjectDot project={project} /> {project.name}
        </span>
      )}
    </div>
  );
}

interface ViewProps extends RowProps {
  rootProps?: HTMLAttributes<HTMLDivElement> & { style?: CSSProperties };
  setNodeRef?: (el: HTMLElement | null) => void;
  handleProps?: Record<string, unknown>;
  dragging?: boolean;
}

function RowView({ task, showProject, sub, className = '', rootProps, setNodeRef, handleProps, dragging }: ViewProps) {
  const { completeTask, updateTask, completing } = useData();
  const { openTask } = useUi();
  const dateBtn = useRef<HTMLButtonElement>(null);
  const [dateOpen, setDateOpen] = useState(false);
  const done = completing.has(task.id);

  return (
    <div
      ref={setNodeRef}
      {...rootProps}
      className={`task-row ${sub ? 'sub' : ''} ${done ? 'completing' : ''} ${dragging ? 'dragging' : ''} ${className}`}
      data-task={task.id}
    >
      <span className="handle" aria-label="Drag to move" {...(handleProps ?? {})} style={{ visibility: handleProps ? 'visible' : 'hidden' }}>
        <GripVertical size={15} />
      </span>
      <button className={`check p${task.priority}`} aria-label={`Complete ${task.title}`} onClick={() => completeTask(task)}>
        <Check size={13} strokeWidth={3} />
      </button>
      <div className="task-main" onClick={() => openTask(task.id)}>
        <div className="task-title">{task.title}</div>
        {task.description && <div className="task-desc">{task.description.split('\n')[0]}</div>}
        <Meta task={task} showProject={showProject} />
      </div>
      <div className="row-actions">
        <button ref={dateBtn} className="icon-btn" aria-label="Change date" title="Change date" onClick={() => setDateOpen((v) => !v)}>
          <Calendar size={15} />
        </button>
        <button className="icon-btn" aria-label="Open" title="Open" onClick={() => openTask(task.id)}>
          <Pencil size={15} />
        </button>
      </div>
      {dateOpen && (
        <DatePopover
          anchor={dateBtn.current}
          due={task.due}
          onChange={(c) => void updateTask(task.id, c)}
          onClose={() => setDateOpen(false)}
        />
      )}
    </div>
  );
}

function SortableRow(props: RowProps) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id: props.task.id, data: { type: 'task' } });
  const style: CSSProperties = { transform: CSS.Transform.toString(transform), transition };
  return <RowView {...props} setNodeRef={setNodeRef} rootProps={{ style }} handleProps={{ ...attributes, ...listeners }} dragging={isDragging} />;
}

function DraggableRow(props: RowProps) {
  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({ id: props.task.id, data: { type: 'task' } });
  return <RowView {...props} setNodeRef={setNodeRef} handleProps={{ ...attributes, ...listeners }} dragging={isDragging} />;
}

/** One task in a list. [drag] says whether it can be put in a different place (sortable) or only dropped on a project (draggable). */
export function TaskRow(props: RowProps) {
  const kind = props.drag ?? 'none';
  if (kind === 'sortable') return <SortableRow {...props} />;
  if (kind === 'draggable') return <DraggableRow {...props} />;
  return <RowView {...props} />;
}

/* ---------------------------------------------------------------- board card */

function CardView({ task, setNodeRef, rootProps, handleProps, dragging, overlay }: { task: Task; setNodeRef?: (el: HTMLElement | null) => void; rootProps?: HTMLAttributes<HTMLDivElement>; handleProps?: Record<string, unknown>; dragging?: boolean; overlay?: boolean }) {
  const { completeTask, completing } = useData();
  const { openTask } = useUi();
  const done = completing.has(task.id);
  return (
    <div
      ref={setNodeRef}
      {...rootProps}
      className={`card ${dragging ? 'dragging' : ''} ${done ? 'completing' : ''} ${overlay ? 'overlay-card' : ''}`}
      onClick={() => !overlay && openTask(task.id)}
    >
      <button
        className={`check p${task.priority}`}
        aria-label={`Complete ${task.title}`}
        onClick={(e) => {
          e.stopPropagation();
          completeTask(task);
        }}
      >
        <Check size={13} strokeWidth={3} />
      </button>
      <div>
        <div className="card-title">{task.title}</div>
        <Meta task={task} />
      </div>
      {handleProps && (
        <span className="handle" aria-label="Drag to move" onClick={(e) => e.stopPropagation()} {...handleProps}>
          <GripVertical size={15} />
        </span>
      )}
    </div>
  );
}

export function SortableCard({ task }: { task: Task }) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id: task.id, data: { type: 'task' } });
  const style: CSSProperties = { transform: CSS.Transform.toString(transform), transition };
  return <CardView task={task} setNodeRef={setNodeRef} rootProps={{ style }} handleProps={{ ...attributes, ...listeners }} dragging={isDragging} />;
}

/** The copy of a task that follows the pointer while it is dragged. */
export function DragPreview({ task }: { task: Task }) {
  return <CardView task={task} overlay />;
}
