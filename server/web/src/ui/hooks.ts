import { useEffect, useLayoutEffect, useRef, useState } from 'react';

/** True when the key press is going into a text field. */
export function isTyping(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  return target.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName);
}

/** Calls [handler] for every key press on the page. */
export function useKeydown(handler: (e: KeyboardEvent) => void) {
  const ref = useRef(handler);
  ref.current = handler;
  useEffect(() => {
    const on = (e: KeyboardEvent) => ref.current(e);
    window.addEventListener('keydown', on);
    return () => window.removeEventListener('keydown', on);
  }, []);
}

export function useDebounced<T>(value: T, ms: number): T {
  const [v, setV] = useState(value);
  useEffect(() => {
    const t = window.setTimeout(() => setV(value), ms);
    return () => window.clearTimeout(t);
  }, [value, ms]);
  return v;
}

/** The current time, refreshed every [ms]. */
export function useNow(ms: number): Date {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const t = window.setInterval(() => setNow(new Date()), ms);
    return () => window.clearInterval(t);
  }, [ms]);
  return now;
}

/** Makes a textarea as tall as its text. */
export function useAutosize(value: string) {
  const ref = useRef<HTMLTextAreaElement>(null);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.style.height = '0px';
    el.style.height = `${el.scrollHeight}px`;
  }, [value]);
  return ref;
}

/** Calls [onOutside] when the mouse goes down outside [ref]'s element (and the elements in [also]). */
export function useOutside(ref: React.RefObject<HTMLElement | null>, onOutside: () => void, also: (HTMLElement | null)[] = []) {
  const cb = useRef(onOutside);
  cb.current = onOutside;
  useEffect(() => {
    const on = (e: MouseEvent) => {
      const t = e.target as Node;
      if (ref.current?.contains(t) || also.some((el) => el?.contains(t))) return;
      cb.current();
    };
    document.addEventListener('mousedown', on);
    return () => document.removeEventListener('mousedown', on);
  });
}
