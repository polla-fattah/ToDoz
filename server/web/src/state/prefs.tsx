import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { CalendarMode } from '../lib/timegrid';

export type Theme = 'system' | 'light' | 'dark';
export type Layout = 'list' | 'board';

const get = (key: string): string | null => {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
};
const set = (key: string, value: string) => {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* kept for this visit only */
  }
};

interface PrefsApi {
  theme: Theme;
  setTheme: (theme: Theme) => void;
  cycleTheme: () => void;
  use24h: boolean;
  /** 1 = Monday ... 7 = Sunday: the first day of the week in this browser's language. */
  weekStart: number;
  calendarMode: CalendarMode;
  setCalendarMode: (mode: CalendarMode) => void;
  layoutOf: (projectId: string) => Layout;
  setLayoutOf: (projectId: string, layout: Layout) => void;
}

const PrefsContext = createContext<PrefsApi | null>(null);

function applyTheme(theme: Theme) {
  const root = document.documentElement;
  if (theme === 'system') root.removeAttribute('data-theme');
  else root.setAttribute('data-theme', theme);
}

export function PrefsProvider({ children }: { children: ReactNode }) {
  const [theme, setThemeState] = useState<Theme>(() => {
    const saved = get('notedo.theme');
    return saved === 'light' || saved === 'dark' ? saved : 'system';
  });
  const [layouts, setLayouts] = useState<Record<string, Layout>>(() => {
    try {
      return JSON.parse(get('notedo.layouts') ?? '{}') as Record<string, Layout>;
    } catch {
      return {};
    }
  });
  const [calendarMode, setCalendarModeState] = useState<CalendarMode>(() => {
    const saved = get('notedo.calendar');
    return saved === 'day' || saved === 'three' || saved === 'week' || saved === 'month' ? saved : window.innerWidth >= 900 ? 'week' : 'three';
  });
  const setCalendarMode = useCallback((m: CalendarMode) => {
    set('notedo.calendar', m);
    setCalendarModeState(m);
  }, []);
  const weekStart = useMemo(() => {
    try {
      const info = (new Intl.Locale(navigator.language) as unknown as { weekInfo?: { firstDay?: number }; getWeekInfo?: () => { firstDay?: number } });
      return info.getWeekInfo?.().firstDay ?? info.weekInfo?.firstDay ?? 1;
    } catch {
      return 1;
    }
  }, []);
  const use24h = useMemo(() => !new Intl.DateTimeFormat(undefined, { hour: 'numeric' }).resolvedOptions().hour12, []);

  useEffect(() => applyTheme(theme), [theme]);

  const setTheme = useCallback((t: Theme) => {
    set('notedo.theme', t);
    setThemeState(t);
  }, []);

  const cycleTheme = useCallback(() => setTheme(theme === 'system' ? 'light' : theme === 'light' ? 'dark' : 'system'), [theme, setTheme]);

  const layoutOf = useCallback((projectId: string): Layout => layouts[projectId] ?? 'list', [layouts]);
  const setLayoutOf = useCallback((projectId: string, layout: Layout) => {
    setLayouts((all) => {
      const next = { ...all, [projectId]: layout };
      set('notedo.layouts', JSON.stringify(next));
      return next;
    });
  }, []);

  const value = useMemo<PrefsApi>(() => ({ theme, setTheme, cycleTheme, use24h, weekStart, calendarMode, setCalendarMode, layoutOf, setLayoutOf }), [theme, setTheme, cycleTheme, use24h, weekStart, calendarMode, setCalendarMode, layoutOf, setLayoutOf]);
  return <PrefsContext.Provider value={value}>{children}</PrefsContext.Provider>;
}

export function usePrefs(): PrefsApi {
  const value = useContext(PrefsContext);
  if (!value) throw new Error('usePrefs needs a PrefsProvider');
  return value;
}
