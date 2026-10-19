import { useCallback, useMemo, useRef, useState } from 'react';
import { Outlet, useLocation, useNavigate } from 'react-router-dom';
import {
  closestCenter,
  DndContext,
  DragOverlay,
  KeyboardSensor,
  PointerSensor,
  pointerWithin,
  TouchSensor,
  useSensor,
  useSensors,
  type CollisionDetection,
  type DragStartEvent,
} from '@dnd-kit/core';
import { sortableKeyboardCoordinates } from '@dnd-kit/sortable';
import { CommandPalette } from './components/CommandPalette';
import { QuickAdd } from './components/QuickAdd';
import { Sidebar } from './components/Sidebar';
import { DragPreview } from './components/TaskRow';
import { TaskPanel } from './components/TaskPanel';
import { useData, type AddOptions } from './state/data';
import { UiContext, type DragHandlers, type UiApi } from './state/ui';
import { todayIso } from './lib/dates';
import { isTyping, useKeydown } from './ui/hooks';

/** Pointer position first (so a project in the sidebar or an empty column can be hit), then the nearest item. */
const collision: CollisionDetection = (args) => {
  const within = pointerWithin(args);
  return within.length ? within : closestCenter(args);
};

export function Layout() {
  const data = useData();
  const navigate = useNavigate();
  const location = useLocation();
  const [openId, setOpenId] = useState<string | null>(null);
  const [quick, setQuick] = useState<(AddOptions & { label?: string }) | null>(null);
  const [palette, setPalette] = useState(false);
  const [sidebar, setSidebar] = useState(false);
  const [activeId, setActiveId] = useState<string | null>(null);
  const handlers = useRef<DragHandlers>({});
  const resume = useRef<(() => void) | null>(null);
  const goKey = useRef(0); // the time of a "g", for the two-key shortcuts (g then t)

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 220, tolerance: 8 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  );

  const ui = useMemo<UiApi>(
    () => ({
      openTask: (id) => setOpenId(id),
      openQuickAdd: (options) => setQuick(options ?? {}),
      openPalette: () => setPalette(true),
      toggleSidebar: () => setSidebar((v) => !v),
      dragHandlers: handlers,
    }),
    [],
  );

  const closeTask = useCallback(() => setOpenId(null), []);
  const anyModal = !!quick || palette;
  useKeydown((e) => {
    const typing = isTyping(e.target);
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
      e.preventDefault();
      setPalette((v) => !v);
      return;
    }
    if (e.key === 'Escape') {
      if (anyModal) {
        setQuick(null);
        setPalette(false);
      } else if (openId) setOpenId(null);
      else if (sidebar) setSidebar(false);
      return;
    }
    if (typing || e.ctrlKey || e.metaKey || e.altKey || anyModal) return;
    if (e.key === 'q' || e.key === 'a') {
      e.preventDefault();
      setQuick({});
    } else if (e.key === '/') {
      e.preventDefault();
      setPalette(true);
    } else if (e.key === 'g') {
      goKey.current = Date.now();
    } else if (Date.now() - goKey.current < 1200) {
      const to = { i: '/inbox', t: '/today', u: '/upcoming', c: '/calendar', d: '/completed' }[e.key];
      if (to) {
        goKey.current = 0;
        navigate(to);
      }
    }
  });

  const onDragStart = (e: DragStartEvent) => {
    setActiveId(String(e.active.id));
    resume.current = data.pauseRefresh();
    handlers.current.onDragStart?.(e);
  };
  const stop = () => {
    setActiveId(null);
    resume.current?.();
    resume.current = null;
  };

  // The page a task is added from decides where it goes: a project page adds to that project, Today to today.
  const addDefaults = useMemo(() => {
    const m = location.pathname.match(/^\/project\/([^/]+)/);
    return m ? { projectId: m[1] } : location.pathname === '/inbox' ? { projectId: data.inbox?.id } : {};
  }, [location.pathname, data.inbox?.id]);
  const activeTask = activeId ? data.tasks.find((t) => t.id === activeId) : undefined;

  return (
    <UiContext.Provider value={ui}>
      <DndContext
        sensors={sensors}
        collisionDetection={collision}
        onDragStart={onDragStart}
        onDragOver={(e) => handlers.current.onDragOver?.(e)}
        onDragEnd={(e) => {
          const over = e.over ? String(e.over.id) : '';
          if (over.startsWith('project:')) {
            handlers.current.onDragCancel?.();
            void data.moveToProject(String(e.active.id), over.slice(8));
          } else handlers.current.onDragEnd?.(e);
          stop();
        }}
        onDragCancel={() => {
          handlers.current.onDragCancel?.();
          stop();
        }}
      >
        <div className="shell">
          <Sidebar open={sidebar} />
          <main className="main" onClick={() => sidebar && setSidebar(false)}>
            {data.error && (
              <div className="banner" role="alert">
                {data.error}
                <button onClick={() => void data.refresh()}>Try again</button>
              </div>
            )}
            <Outlet />
          </main>
        </div>
        <DragOverlay dropAnimation={{ duration: 180, easing: 'cubic-bezier(0.2, 0.7, 0.2, 1)' }}>{activeTask ? <DragPreview task={activeTask} /> : null}</DragOverlay>
      </DndContext>

      {openId && <TaskPanel key={openId} id={openId} onClose={closeTask} />}

      {quick && (
        <div className="modal-wrap" onMouseDown={(e) => e.target === e.currentTarget && setQuick(null)}>
          <div className="modal" role="dialog" aria-label="Add task">
            <QuickAdd
              {...addDefaults}
              dueDate={location.pathname === '/today' ? todayIso() : undefined}
              {...quick}
              autoFocus
              onDone={() => setQuick(null)}
              onCancel={() => setQuick(null)}
              destination={quick.label ?? (addDefaults.projectId ? data.projectById(addDefaults.projectId)?.name : 'Inbox')}
            />
          </div>
        </div>
      )}

      {palette && <CommandPalette onClose={() => setPalette(false)} onAddTask={() => setQuick({})} onOpenTask={(id) => setOpenId(id)} />}
    </UiContext.Provider>
  );
}
