import { useCallback, useEffect, useMemo, useState } from 'react';
import { useParams } from 'react-router-dom';
import { Check, CircleCheckBig, Coffee, Tag } from 'lucide-react';
import { api } from '../api';
import { InlineAdd } from '../components/InlineAdd';
import { EmptyState, PageHeader, Skeleton } from '../components/Page';
import { ProjectDot } from '../components/pickers';
import { TaskRow } from '../components/TaskRow';
import { clock, dayHeading, dayLabel, isoDate, todayIso } from '../lib/dates';
import { byWhen, isDueByToday, nextDays } from '../lib/tasks';
import { useData } from '../state/data';
import { usePrefs } from '../state/prefs';
import type { CompletedItem, Task } from '../types';

function Page({ children }: { children: React.ReactNode }) {
  return (
    <div className="scroll">
      <div className="page">{children}</div>
    </div>
  );
}

function Rows({ tasks, showProject = true }: { tasks: Task[]; showProject?: boolean }) {
  return (
    <>
      {tasks.map((t) => (
        <TaskRow key={t.id} task={t} showProject={showProject} drag="draggable" />
      ))}
    </>
  );
}

const plural = (n: number, one: string) => `${n} ${one}${n === 1 ? '' : 's'}`;

export function TodayView() {
  const { ready, tasks } = useData();
  const today = todayIso();
  const due = useMemo(() => tasks.filter((t) => isDueByToday(t, today)).sort(byWhen), [tasks, today]);
  const late = due.filter((t) => t.due!.date < today);
  const now = due.filter((t) => t.due!.date === today);
  const sub = new Date().toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' });

  if (!ready)
    return (
      <Page>
        <PageHeader title="Today" sub={sub} />
        <Skeleton />
      </Page>
    );
  return (
    <Page>
      <PageHeader title="Today" sub={due.length ? `${sub} · ${plural(due.length, 'task')}` : sub} />
      {late.length > 0 && (
        <div className="group">
          <div className="group-head overdue">
            <span>Overdue</span> <span className="n">{late.length}</span>
          </div>
          <Rows tasks={late} />
        </div>
      )}
      <div className="group">
        {late.length > 0 && (
          <div className="group-head">
            <span>Today</span> <span className="n">{now.length || ''}</span>
          </div>
        )}
        <Rows tasks={now} />
        <InlineAdd dueDate={today} destination="Today" />
      </div>
      {due.length === 0 && (
        <EmptyState icon={Coffee} title="Nothing due today">
          Enjoy the quiet, or add something above.
        </EmptyState>
      )}
    </Page>
  );
}

export function UpcomingView() {
  const { ready, tasks } = useData();
  const today = todayIso();
  const groups = useMemo(() => {
    const byDay = new Map<string, Task[]>();
    for (const t of [...tasks].sort(byWhen)) {
      if (!t.due || t.due.date <= today) continue;
      byDay.set(t.due.date, [...(byDay.get(t.due.date) ?? []), t]);
    }
    // The coming week always shows, even for empty days, so there is somewhere to add a task.
    for (const d of nextDays(today, 8).slice(1)) if (!byDay.has(d)) byDay.set(d, []);
    return [...byDay].sort(([a], [b]) => a.localeCompare(b));
  }, [tasks, today]);
  const count = groups.reduce((n, [, l]) => n + l.length, 0);

  return (
    <Page>
      <PageHeader title="Upcoming" sub={count ? plural(count, 'task') : ''} />
      {!ready && <Skeleton />}
      {ready &&
        groups.map(([date, list]) => {
          const h = dayHeading(date, today);
          return (
            <div className="group" key={date}>
              <div className="group-head">
                <span>{h.main}</span>
                {h.sub && <span className="sub">{h.sub}</span>}
                <span className="n">{list.length || ''}</span>
              </div>
              <Rows tasks={list} />
              <InlineAdd dueDate={date} destination={dayLabel(date, today)} />
            </div>
          );
        })}
    </Page>
  );
}

export function LabelView() {
  const { id } = useParams();
  const { ready, labels, tasks } = useData();
  const label = labels.find((l) => l.id === id);
  const list = useMemo(() => (label ? tasks.filter((t) => t.labels.some((n) => n.toLowerCase() === label.name.toLowerCase())).sort(byWhen) : []), [tasks, label]);
  if (!ready)
    return (
      <Page>
        <Skeleton />
      </Page>
    );
  if (!label)
    return (
      <Page>
        <EmptyState icon={Tag} title="This label is not here" />
      </Page>
    );
  return (
    <Page>
      <PageHeader title={`%${label.name}`} sub={list.length ? plural(list.length, 'task') : ''} />
      <Rows tasks={list} />
      {list.length === 0 && (
        <EmptyState icon={Tag} title="No tasks with this label">
          Add the label to a task and it shows up here.
        </EmptyState>
      )}
    </Page>
  );
}

export function CompletedView() {
  const { projectById, reopenTask, tasks } = useData();
  const { use24h } = usePrefs();
  const [items, setItems] = useState<CompletedItem[] | null>(null);
  const load = useCallback(() => api.completed(150).then(setItems).catch(() => setItems([])), []);
  useEffect(() => void load(), [load]);

  const groups = useMemo(() => {
    const byDay = new Map<string, CompletedItem[]>();
    for (const c of items ?? []) {
      const day = isoDate(new Date(c.completed_at));
      byDay.set(day, [...(byDay.get(day) ?? []), c]);
    }
    return [...byDay];
  }, [items]);
  const open = new Set(tasks.map((t) => t.id));

  return (
    <Page>
      <PageHeader title="Completed" sub={items?.length ? `Last ${plural(items.length, 'completion')}` : ''} />
      {items === null && <Skeleton />}
      {items?.length === 0 && (
        <EmptyState icon={CircleCheckBig} title="Nothing completed yet">
          Finished tasks collect here.
        </EmptyState>
      )}
      {groups.map(([day, list]) => {
        const h = dayHeading(day);
        return (
          <div className="group" key={day}>
            <div className="group-head">
              <span>{h.main}</span> {h.sub && <span className="sub">{h.sub}</span>}
            </div>
            {list.map((c) => {
              const t = new Date(c.completed_at);
              return (
                <div key={c.id} className="task-row" style={{ gridTemplateColumns: '22px 22px minmax(0,1fr)' }}>
                  <span />
                  <button
                    className="check done"
                    title={open.has(c.task_id) ? 'Already open again' : 'Mark as not done'}
                    aria-label="Mark as not done"
                    onClick={async () => {
                      await reopenTask(c.task_id);
                      void load();
                    }}
                  >
                    <Check size={13} strokeWidth={3} />
                  </button>
                  <div className="task-main" style={{ cursor: 'default' }}>
                    <div className="task-title" style={{ color: 'var(--text-3)', textDecoration: 'line-through' }}>
                      {c.title ?? 'A task that was deleted'}
                    </div>
                    <div className="meta">
                      <span className="chip">{clock(`${String(t.getHours()).padStart(2, '0')}:${String(t.getMinutes()).padStart(2, '0')}`, use24h)}</span>
                      {c.project_id && (
                        <span className="chip">
                          <ProjectDot project={projectById(c.project_id)} /> {projectById(c.project_id)?.name}
                        </span>
                      )}
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        );
      })}
    </Page>
  );
}

