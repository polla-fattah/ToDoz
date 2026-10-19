import { useState } from 'react';
import { Plus } from 'lucide-react';
import type { AddOptions } from '../state/data';
import { QuickAdd } from './QuickAdd';

/** "+ Add task" that turns into a composer in place (under a section, a day, or a board column). */
export function InlineAdd({ label = 'Add task', destination, ...options }: AddOptions & { label?: string; destination?: string }) {
  const [open, setOpen] = useState(false);
  if (!open)
    return (
      <button className="add-inline" onClick={() => setOpen(true)}>
        <span className="plus">
          <Plus size={14} />
        </span>
        {label}
      </button>
    );
  return <QuickAdd {...options} autoFocus keepOpen destination={destination} onCancel={() => setOpen(false)} />;
}
