import { createContext, useContext, type MutableRefObject } from 'react';
import type { DragEndEvent, DragOverEvent, DragStartEvent } from '@dnd-kit/core';

/** What the open view wants to happen while something is dragged (the page owns the DndContext, the view the columns). */
export interface DragHandlers {
  onDragStart?: (e: DragStartEvent) => void;
  onDragOver?: (e: DragOverEvent) => void;
  onDragEnd?: (e: DragEndEvent) => void;
  onDragCancel?: () => void;
}

export interface UiApi {
  openTask: (id: string) => void;
  openQuickAdd: () => void;
  openPalette: () => void;
  toggleSidebar: () => void;
  /** Where a view puts its drag handlers. */
  dragHandlers: MutableRefObject<DragHandlers>;
}

export const UiContext = createContext<UiApi | null>(null);

export function useUi(): UiApi {
  const value = useContext(UiContext);
  if (!value) throw new Error('useUi needs the page layout');
  return value;
}
