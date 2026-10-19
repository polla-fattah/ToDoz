import { useEffect, useState } from 'react';
import { Calendar, Check, ChevronRight, Flag, MessageSquare, Plus, Repeat, Send, Tag, Trash2, X } from 'lucide-react';
import { api } from '../api';
import { dueText, dueTone } from '../lib/dates';
import { useData } from '../state/data';
import { usePrefs } from '../state/prefs';
import { useToast } from '../state/toast';
import { useUi } from '../state/ui';
import { useAutosize } from '../ui/hooks';
import type { Comment } from '../types';
import { DatePopover, LabelsMenu, PRIORITY_NAMES, PriorityMenu, priorityColour, ProjectDot, ProjectMenu } from './pickers';

type Menu = 'project' | 'date' | 'priority' | 'labels' | null;

const initial = (s: string) => (s.trim()[0] ?? '?').toUpperCase();

export function TaskPanel({ id, onClose }: { id: string; onClose: () => void }) {
  const { tasks, ready, projectById, updateTask, completeTask, deleteTask, addSubtask, completing } = useData();
  const { use24h } = usePrefs();
  const { openTask } = useUi();
  const { error } = useToast();
  const task = tasks.find((t) => t.id === id);
  const [title, setTitle] = useState(task?.title ?? '');
  const [desc, setDesc] = useState(task?.description ?? '');
  const [menu, setMenu] = useState<Menu>(null);
  const [anchor, setAnchor] = useState<HTMLElement | null>(null);
  const [comments, setComments] = useState<Comment[] | null>(null);
  const [draft, setDraft] = useState('');
  const [sub, setSub] = useState('');
  const [confirmDelete, setConfirmDelete] = useState(false);
  const titleRef = useAutosize(title);
  const descRef = useAutosize(desc);

  // The task is gone (completed here or elsewhere, or deleted): there is nothing left to show.
  useEffect(() => {
    if (ready && !task) onClose();
  }, [ready, task, onClose]);

  useEffect(() => {
    let alive = true;
    api
      .comments(id)
      .then((c) => alive && setComments(c))
      .catch(() => alive && setComments([]));
    return () => {
      alive = false;
    };
  }, [id]);

  if (!task) return null;
  const project = projectById(task.project_id);
  const subtasks = tasks.filter((t) => t.parent_id === id);
  const done = completing.has(id);
  const open = (kind: Menu) => (e: React.MouseEvent<HTMLElement>) => {
    setAnchor(e.currentTarget);
    setMenu(menu === kind ? null : kind);
  };
  const close = () => setMenu(null);

  const saveTitle = () => {
    const t = title.trim();
    if (!t) return setTitle(task.title);
    if (t !== task.title) void updateTask(id, { title: t });
  };
  const saveDesc = () => desc !== task.description && void updateTask(id, { description: desc });

  async function post() {
    const text = draft.trim();
    if (!text) return;
    setDraft('');
    try {
      const c = await api.createComment(id, text);
      setComments((all) => [...(all ?? []), c]);
    } catch (e) {
      setDraft(text);
      error(e instanceof Error ? e.message : 'Could not post the comment.');
    }
  }

  return (
    <>
      <div className="scrim" onClick={onClose} />
      <aside className="panel" aria-label="Task details">
        <div className="panel-head">
          <button className="prop-btn crumb" onClick={open('project')} style={{ marginLeft: 0 }}>
            <ProjectDot project={project} /> {project?.name ?? 'Inbox'}
          </button>
          <button className="icon-btn" aria-label="Close" onClick={onClose}>
            <X size={18} />
          </button>
        </div>

        <div className="panel-body">
          <div className="title-row">
            <button className={`check p${task.priority} ${done ? 'done' : ''}`} aria-label="Complete task" onClick={() => completeTask(task)}>
              <Check size={14} strokeWidth={3} />
            </button>
            <textarea
              ref={titleRef}
              className="title-input"
              rows={1}
              value={title}
              placeholder="Task name"
              maxLength={500}
              aria-label="Task name"
              onChange={(e) => setTitle(e.target.value.replace(/\n/g, ' '))}
              onBlur={saveTitle}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault();
                  e.currentTarget.blur();
                }
              }}
            />
          </div>
          <textarea
            ref={descRef}
            className="desc-input"
            rows={1}
            value={desc}
            placeholder="Description"
            aria-label="Description"
            onChange={(e) => setDesc(e.target.value)}
            onBlur={saveDesc}
          />

          <div className="props">
            <div className="prop">
              <label>Date</label>
              <button className={`prop-btn ${task.due ? '' : 'empty'}`} onClick={open('date')}>
                {task.due ? (
                  <>
                    {task.due.recurrence ? <Repeat size={15} /> : <Calendar size={15} />}
                    <span className={`chip ${dueTone(task.due.date)}`}>{dueText(task.due, use24h)}</span>
                    {task.due.recurrence && <span style={{ color: 'var(--text-3)' }}>{task.due.recurrence}</span>}
                  </>
                ) : (
                  <>
                    <Calendar size={15} /> Add date
                  </>
                )}
              </button>
            </div>
            <div className="prop">
              <label>Priority</label>
              <button className="prop-btn" onClick={open('priority')}>
                <Flag size={15} color={priorityColour(task.priority)} fill={task.priority === 4 ? 'none' : priorityColour(task.priority)} /> {PRIORITY_NAMES[task.priority]}
              </button>
            </div>
            <div className="prop">
              <label>Labels</label>
              <button className={`prop-btn ${task.labels.length ? '' : 'empty'}`} onClick={open('labels')}>
                <Tag size={15} />
                {task.labels.length ? task.labels.map((l) => `%${l}`).join('  ') : 'Add labels'}
              </button>
            </div>
          </div>

          <div className="section-title">
            Sub-tasks <span className="n">{subtasks.length || ''}</span>
          </div>
          {subtasks.map((s) => (
            <div key={s.id} className="subtask">
              <button className={`check p${s.priority} ${completing.has(s.id) ? 'done' : ''}`} aria-label={`Complete ${s.title}`} onClick={() => completeTask(s)}>
                <Check size={13} strokeWidth={3} />
              </button>
              <span style={{ cursor: 'pointer' }} onClick={() => openTask(s.id)}>
                {s.title}
              </span>
              <ChevronRight size={14} color="var(--text-3)" />
            </div>
          ))}
          <form
            className="subtask"
            style={{ borderBottom: 0 }}
            onSubmit={(e) => {
              e.preventDefault();
              const t = sub.trim();
              if (!t) return;
              setSub('');
              void addSubtask(task, t);
            }}
          >
            <Plus size={16} color="var(--text-3)" />
            <input
              value={sub}
              onChange={(e) => setSub(e.target.value)}
              placeholder="Add sub-task"
              aria-label="Add sub-task"
              maxLength={500}
              style={{ border: 0, background: 'none', outline: 'none', width: '100%' }}
            />
            <span />
          </form>

          <div className="section-title">
            <MessageSquare size={15} /> Comments <span className="n">{comments?.length || ''}</span>
          </div>
          {comments?.map((c) => (
            <div key={c.id} className="comment">
              <span className="avatar">{initial('You')}</span>
              <div className="bubble">
                <time>{new Date(c.posted_at).toLocaleString(undefined, { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</time>
                {c.content}
              </div>
            </div>
          ))}
          <div className="composer-comment">
            <textarea
              value={draft}
              rows={1}
              placeholder="Write a comment"
              aria-label="Write a comment"
              maxLength={5000}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
                  e.preventDefault();
                  void post();
                }
              }}
            />
            <button className="btn btn-primary" aria-label="Post comment" disabled={!draft.trim()} onClick={() => void post()}>
              <Send size={15} />
            </button>
          </div>
        </div>

        <div className="panel-foot">
          <button
            className={`btn btn-ghost ${confirmDelete ? 'btn-danger' : ''}`}
            onClick={() => {
              if (!confirmDelete) return setConfirmDelete(true);
              onClose();
              void deleteTask(task);
            }}
            onBlur={() => setConfirmDelete(false)}
          >
            <Trash2 size={15} /> {confirmDelete ? 'Click again to delete' : 'Delete'}
          </button>
        </div>
      </aside>

      {menu === 'date' && <DatePopover anchor={anchor} due={task.due} onChange={(c) => void updateTask(id, c)} onClose={close} />}
      {menu === 'priority' && <PriorityMenu anchor={anchor} value={task.priority} onPick={(p) => void updateTask(id, { priority: p })} onClose={close} />}
      {menu === 'labels' && <LabelsMenu anchor={anchor} value={task.labels} onChange={(labels) => void updateTask(id, { labels })} onClose={close} />}
      {menu === 'project' && <ProjectMenu anchor={anchor} value={task.project_id} onPick={(pid) => void updateTask(id, { project_id: pid })} onClose={close} />}
    </>
  );
}

