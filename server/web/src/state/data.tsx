import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { api, ApiError } from '../api';
import { dueText, localNow } from '../lib/dates';
import { applyColumns, planCommit, type Columns } from '../lib/order';
import { applyPatch } from '../lib/tasks';
import type { Label, Project, Section, Task, TaskPatch } from '../types';
import { usePrefs } from './prefs';
import { useToast } from './toast';

interface Snapshot {
  ready: boolean;
  error: string | null;
  projects: Project[];
  sections: Section[];
  labels: Label[];
  tasks: Task[];
  /** Tasks that were just ticked: shown struck through for a moment before they leave the list. */
  completing: ReadonlySet<string>;
}

export interface AddOptions {
  projectId?: string;
  sectionId?: string | null;
  /** When the line names no date, make it due on this day (adding from the Today page or under a day). */
  dueDate?: string;
}

export interface DataApi extends Snapshot {
  refresh: () => Promise<void>;
  /** Stops background refreshes while something is being dragged or edited. Call the result to let them go on. */
  pauseRefresh: () => () => void;

  addQuick: (text: string, options?: AddOptions) => Promise<Task | null>;
  addSubtask: (parent: Task, title: string) => Promise<void>;
  updateTask: (id: string, patch: TaskPatch) => Promise<void>;
  completeTask: (task: Task) => void;
  reopenTask: (taskId: string) => Promise<void>;
  deleteTask: (task: Task) => Promise<void>;
  commitDrop: (before: Columns, after: Columns, activeId: string) => Promise<void>;
  moveToProject: (taskId: string, projectId: string) => Promise<void>;

  createProject: (name: string) => Promise<Project | null>;
  createSection: (projectId: string, name: string) => Promise<void>;
  renameSection: (id: string, name: string) => Promise<void>;
  deleteSection: (section: Section) => Promise<void>;

  projectById: (id: string | null | undefined) => Project | undefined;
  inbox: Project | undefined;
}

const DataContext = createContext<DataApi | null>(null);

const byOrder = <T extends { order: number; name: string }>(a: T, b: T) => a.order - b.order || a.name.localeCompare(b.name);
const message = (e: unknown) => (e instanceof Error ? e.message : 'Something went wrong.');

export function DataProvider({ children }: { children: ReactNode }) {
  const { toast, error } = useToast();
  const { use24h } = usePrefs();
  const [snap, setSnap] = useState<Snapshot>({ ready: false, error: null, projects: [], sections: [], labels: [], tasks: [], completing: new Set() });
  const snapRef = useRef(snap);
  snapRef.current = snap;
  const inFlight = useRef(0); // writes under way: a refresh now could bring back old values
  const paused = useRef(0);

  const refresh = useCallback(async () => {
    if (inFlight.current > 0 || paused.current > 0) return;
    try {
      const [projects, sections, labels, tasks] = await Promise.all([api.projects(), api.sections(), api.labels(), api.tasks()]);
      if (inFlight.current > 0 || paused.current > 0) return; // a write started while we were asking
      setSnap((s) => ({
        ...s,
        ready: true,
        error: null,
        projects: projects.filter((p) => !p.is_archived).sort(byOrder),
        sections: sections.filter((x) => !x.is_archived).sort(byOrder),
        labels: [...labels].sort((a, b) => a.name.localeCompare(b.name)),
        tasks,
      }));
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) return;
      setSnap((s) => ({ ...s, error: message(e) }));
    }
  }, []);

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(), 30000);
    const onVisible = () => document.visibilityState === 'visible' && void refresh();
    document.addEventListener('visibilitychange', onVisible);
    window.addEventListener('online', onVisible);
    return () => {
      window.clearInterval(timer);
      document.removeEventListener('visibilitychange', onVisible);
      window.removeEventListener('online', onVisible);
    };
  }, [refresh]);

  const pauseRefresh = useCallback(() => {
    paused.current++;
    let done = false;
    return () => {
      if (done) return;
      done = true;
      paused.current--;
    };
  }, []);

  /** A write: nothing refreshes over it while it runs. */
  const write = useCallback(async <T,>(run: () => Promise<T>): Promise<T> => {
    inFlight.current++;
    try {
      return await run();
    } finally {
      inFlight.current--;
    }
  }, []);

  const setTasks = useCallback((change: (tasks: Task[]) => Task[]) => setSnap((s) => ({ ...s, tasks: change(s.tasks) })), []);
  const replaceTask = useCallback((fresh: Task) => setTasks((all) => all.map((t) => (t.id === fresh.id ? fresh : t))), [setTasks]);

  /** Reload everything after a failed write, so the screen shows what is really on the server. */
  const recover = useCallback(
    async (e: unknown) => {
      error(message(e));
      await refresh();
    },
    [error, refresh],
  );

  const addQuick = useCallback<DataApi['addQuick']>(
    async (text, options = {}) => {
      try {
        const made = await write(async () => {
          let t = await api.quickAdd(text, { projectId: options.projectId, today: localNow() });
          if (options.sectionId && t.project_id === options.projectId && !t.section_id) t = await api.updateTask(t.id, { section_id: options.sectionId });
          if (options.dueDate && !t.due) t = await api.updateTask(t.id, { due_date: options.dueDate });
          return t;
        });
        setTasks((all) => [...all.filter((t) => t.id !== made.id), made]);
        return made;
      } catch (e) {
        error(message(e));
        return null;
      }
    },
    [write, setTasks, error],
  );

  const addSubtask = useCallback<DataApi['addSubtask']>(
    async (parent, title) => {
      try {
        const made = await write(() => api.createTask({ title, parent_id: parent.id }));
        setTasks((all) => [...all.filter((t) => t.id !== made.id), made]);
      } catch (e) {
        error(message(e));
      }
    },
    [write, setTasks, error],
  );

  const updateTask = useCallback<DataApi['updateTask']>(
    async (id, patch) => {
      const before = snapRef.current.tasks.find((t) => t.id === id);
      if (!before) return;
      replaceTask(applyPatch(before, patch));
      try {
        replaceTask(await write(() => api.updateTask(id, patch)));
      } catch (e) {
        replaceTask(before);
        error(message(e));
      }
    },
    [write, replaceTask, error],
  );

  const reopenTask = useCallback(
    async (taskId: string) => {
      try {
        await write(() => api.reopenTask(taskId));
      } catch (e) {
        error(message(e));
      }
      await refresh();
    },
    [write, error, refresh],
  );

  const completeTask = useCallback<DataApi['completeTask']>(
    (task) => {
      setSnap((s) => ({ ...s, completing: new Set(s.completing).add(task.id) }));
      const done = () => setSnap((s) => ({ ...s, completing: new Set([...s.completing].filter((id) => id !== task.id)) }));
      void (async () => {
        try {
          const result = await write(() => api.closeTask(task.id));
          if (result.is_completed) {
            window.setTimeout(() => {
              setTasks((all) => all.filter((t) => t.id !== task.id));
              done();
            }, 380);
            toast(`Completed “${task.title}”`, { action: { label: 'Undo', run: () => void reopenTask(task.id) } });
          } else {
            replaceTask(result); // a repeating task moves to its next date
            done();
            toast(result.due ? `Next: ${dueText(result.due, use24h)}` : 'Done');
          }
        } catch (e) {
          done();
          error(message(e));
        }
      })();
    },
    [write, setTasks, replaceTask, toast, error, reopenTask, use24h],
  );

  const deleteTask = useCallback<DataApi['deleteTask']>(
    async (task) => {
      setTasks((all) => all.filter((t) => t.id !== task.id && t.parent_id !== task.id));
      try {
        await write(() => api.deleteTask(task.id));
        toast(`Deleted “${task.title}”`);
      } catch (e) {
        await recover(e);
      }
    },
    [write, setTasks, toast, recover],
  );

  const commitDrop = useCallback<DataApi['commitDrop']>(
    async (before, after, activeId) => {
      const plan = planCommit(before, after, activeId);
      if (!plan.move && !plan.order) return;
      setTasks((all) => applyColumns(all, after));
      try {
        await write(async () => {
          if (plan.move) await api.updateTask(plan.move.taskId, { section_id: plan.move.sectionId });
          if (plan.order) await api.reorderTasks(plan.order);
        });
      } catch (e) {
        await recover(e);
      }
    },
    [write, setTasks, recover],
  );

  const moveToProject = useCallback<DataApi['moveToProject']>(
    async (taskId, projectId) => {
      const task = snapRef.current.tasks.find((t) => t.id === taskId);
      if (!task || task.project_id === projectId) return;
      const target = snapRef.current.projects.find((p) => p.id === projectId);
      setTasks((all) => all.filter((t) => t.id !== taskId && t.parent_id !== taskId).concat([]));
      try {
        await write(() => api.updateTask(taskId, { project_id: projectId }));
        toast(`Moved to ${target?.name ?? 'project'}`, {
          action: {
            label: 'Undo',
            run: () => void write(() => api.updateTask(taskId, { project_id: task.project_id, section_id: task.section_id })).then(refresh).catch(recover),
          },
        });
        await refresh();
      } catch (e) {
        await recover(e);
      }
    },
    [write, setTasks, toast, refresh, recover],
  );

  const createProject = useCallback<DataApi['createProject']>(
    async (name) => {
      try {
        const p = await write(() => api.createProject(name));
        await refresh();
        return p;
      } catch (e) {
        error(message(e));
        return null;
      }
    },
    [write, refresh, error],
  );

  const createSection = useCallback<DataApi['createSection']>(
    async (projectId, name) => {
      try {
        await write(() => api.createSection(projectId, name));
      } catch (e) {
        error(message(e));
      }
      await refresh();
    },
    [write, refresh, error],
  );

  const renameSection = useCallback<DataApi['renameSection']>(
    async (id, name) => {
      setSnap((s) => ({ ...s, sections: s.sections.map((x) => (x.id === id ? { ...x, name } : x)) }));
      try {
        await write(() => api.renameSection(id, name));
      } catch (e) {
        await recover(e);
      }
    },
    [write, recover],
  );

  const deleteSection = useCallback<DataApi['deleteSection']>(
    async (section) => {
      try {
        await write(() => api.deleteSection(section.id));
        toast(`Deleted section “${section.name}”`);
      } catch (e) {
        error(message(e));
      }
      await refresh();
    },
    [write, toast, error, refresh],
  );

  const value = useMemo<DataApi>(
    () => ({
      ...snap,
      refresh,
      pauseRefresh,
      addQuick,
      addSubtask,
      updateTask,
      completeTask,
      reopenTask,
      deleteTask,
      commitDrop,
      moveToProject,
      createProject,
      createSection,
      renameSection,
      deleteSection,
      projectById: (id) => snap.projects.find((p) => p.id === id),
      inbox: snap.projects.find((p) => p.is_inbox),
    }),
    [snap, refresh, pauseRefresh, addQuick, addSubtask, updateTask, completeTask, reopenTask, deleteTask, commitDrop, moveToProject, createProject, createSection, renameSection, deleteSection],
  );
  return <DataContext.Provider value={value}>{children}</DataContext.Provider>;
}

export function useData(): DataApi {
  const value = useContext(DataContext);
  if (!value) throw new Error('useData needs a DataProvider');
  return value;
}
