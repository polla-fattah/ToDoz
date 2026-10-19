import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { useOutside } from './hooks';

interface PopoverProps {
  /** The button that opened it: the popover sits under it, and clicking it again is not "outside". */
  anchor: HTMLElement | null;
  onClose: () => void;
  children: ReactNode;
  className?: string;
  /** Open to the left of the anchor's left edge instead of the right. */
  alignEnd?: boolean;
}

/** A small floating panel anchored to a button; closes on Escape or a click elsewhere. */
export function Popover({ anchor, onClose, children, className = '', alignEnd = false }: PopoverProps) {
  const ref = useRef<HTMLDivElement>(null);
  const [style, setStyle] = useState<CSSProperties>({ visibility: 'hidden' });

  useOutside(ref, onClose, [anchor]);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el || !anchor) return;
    const a = anchor.getBoundingClientRect();
    const w = el.offsetWidth;
    const h = el.offsetHeight;
    let left = alignEnd ? a.right - w : a.left;
    left = Math.max(8, Math.min(left, window.innerWidth - w - 8));
    let top = a.bottom + 6;
    if (top + h > window.innerHeight - 8) top = Math.max(8, a.top - h - 6); // flip above when there is no room below
    setStyle({ left, top, visibility: 'visible' });
  }, [anchor, alignEnd, children]);

  useEffect(() => {
    const on = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        onClose();
      }
    };
    window.addEventListener('keydown', on, true);
    return () => window.removeEventListener('keydown', on, true);
  }, [onClose]);

  return createPortal(
    <div ref={ref} className={`popover ${className}`} style={style} role="dialog">
      {children}
    </div>,
    document.body,
  );
}
