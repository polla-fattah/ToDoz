import type { ReactNode } from 'react';
import { Menu, type LucideIcon } from 'lucide-react';
import { useData } from '../state/data';
import { useUi } from '../state/ui';

/** The title row of a page, with the menu button on small screens and room for the page's own controls. */
export function PageHeader({ title, sub, actions }: { title: string; sub?: string; actions?: ReactNode }) {
  const { toggleSidebar } = useUi();
  return (
    <>
      <div className="topbar" style={{ padding: 0, height: 'auto', margin: '14px 0 6px' }}>
        <button className="icon-btn menu-btn" aria-label="Menu" onClick={toggleSidebar}>
          <Menu size={20} />
        </button>
        <div className="page-head" style={{ margin: 0, flex: 1, minWidth: 0 }}>
          <h1 style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{title}</h1>
          {sub && <span className="sub">{sub}</span>}
        </div>
        {actions}
      </div>
    </>
  );
}

export function EmptyState({ icon: Icon, title, children }: { icon: LucideIcon; title: string; children?: ReactNode }) {
  return (
    <div className="empty-state">
      <Icon size={44} strokeWidth={1.5} />
      <strong>{title}</strong>
      {children && <span>{children}</span>}
    </div>
  );
}

/** Grey bars where the tasks will be, while the first load is under way. */
export function Skeleton() {
  return (
    <div aria-busy="true" aria-label="Loading">
      {[70, 52, 84, 60].map((w, i) => (
        <div key={i} className="skeleton-row" style={{ width: `${w}%` }} />
      ))}
    </div>
  );
}

export function useReady(): boolean {
  return useData().ready;
}
