import { useEffect, useRef, useState } from 'react';
import { Calendar, CornerDownLeft, Flag, Hash, Repeat, Tag, TriangleAlert } from 'lucide-react';
import { api } from '../api';
import { dueText, dueTone, localNow } from '../lib/dates';
import { useData, type AddOptions } from '../state/data';
import { usePrefs } from '../state/prefs';
import { useDebounced } from '../ui/hooks';
import type { Priority, QuickPreview } from '../types';
import { priorityColour } from './pickers';

interface Props extends AddOptions {
  placeholder?: string;
  autoFocus?: boolean;
  /** Stay open for the next task after adding (inline under a section). */
  keepOpen?: boolean;
  onDone?: () => void;
  /** Esc, or Cancel. */
  onCancel?: () => void;
  /** Where the task goes, shown in the hint ("to Inbox"). */
  destination?: string;
}

/** A line of text becomes a task: "Call mum tomorrow 5pm p1 #Home %family". The pills show what each word meant. */
export function QuickAdd({ placeholder, autoFocus, keepOpen, onDone, onCancel, destination, ...options }: Props) {
  const { addQuick } = useData();
  const { use24h } = usePrefs();
  const [text, setText] = useState('');
  const [preview, setPreview] = useState<QuickPreview | null>(null);
  const [busy, setBusy] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const asked = useRef(0);
  const debounced = useDebounced(text, 140);

  useEffect(() => {
    if (autoFocus) input.current?.focus();
  }, [autoFocus]);

  useEffect(() => {
    if (!debounced.trim()) {
      setPreview(null);
      return;
    }
    const mine = ++asked.current;
    api
      .quickPreview(debounced, { projectId: options.projectId, today: localNow() })
      .then((p) => mine === asked.current && setPreview(p))
      .catch(() => mine === asked.current && setPreview(null));
  }, [debounced, options.projectId]);

  async function submit() {
    const line = text.trim();
    if (!line || busy) return;
    setBusy(true);
    const made = await addQuick(line, options);
    setBusy(false);
    if (!made) return; // the error is on screen; keep the text so it is not lost
    setText('');
    setPreview(null);
    if (keepOpen) input.current?.focus();
    else onDone?.();
  }

  const live = text.trim() && preview && debounced === text ? preview : null;
  const tone = live?.due ? dueTone(live.due.date) : 'later';
  // Where it will go: the project typed after #, else the place this was opened from.
  const where = live?.project.typed && live.project.known ? live.project.name : destination;

  return (
    <div className="composer">
      <input
        ref={input}
        value={text}
        placeholder={placeholder ?? 'Task name, e.g. Pay rent tomorrow 5pm p1 #Home'}
        maxLength={2000}
        aria-label="New task"
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter' && !e.nativeEvent.isComposing) {
            e.preventDefault();
            void submit();
          } else if (e.key === 'Escape') {
            e.stopPropagation();
            onCancel?.();
          }
        }}
      />
      <div className="preview">
        {live?.due && (
          <span className={`pill ${tone}`}>
            {live.due.recurrence ? <Repeat size={12} /> : <Calendar size={12} />}
            {dueText(live.due, use24h)}
            {live.due.recurrence ? ` · ${live.due.recurrence}` : ''}
          </span>
        )}
        {live?.priority && live.priority < 4 && (
          <span className={`pill p${live.priority}`}>
            <Flag size={12} fill={priorityColour(live.priority as Priority)} /> P{live.priority}
          </span>
        )}
        {live && live.project.typed && (
          <span className={`pill ${live.project.known ? '' : 'warn'}`}>
            {live.project.known ? <Hash size={12} /> : <TriangleAlert size={12} />}
            {live.project.known ? live.project.name : `No project “${live.project.typed}”: it goes to Inbox`}
          </span>
        )}
        {live?.section && (
          <span className={`pill ${live.section.known ? '' : 'warn'}`}>{live.section.known ? `/ ${live.section.name}` : `No section “${live.section.typed}”`}</span>
        )}
        {live?.labels.map((l) => (
          <span key={l} className="pill">
            <Tag size={12} /> {l}
          </span>
        ))}
        {live?.repeat_error && <span className="pill warn">{live.repeat_error}</span>}
      </div>
      <div className="foot">
        <span className="hint">{where ? `Adds to ${where}` : 'Press Enter to add'}</span>
        {onCancel && (
          <button className="btn btn-sm btn-ghost" onClick={onCancel}>
            Cancel
          </button>
        )}
        <button className="btn btn-sm btn-primary" disabled={!text.trim() || busy} onClick={() => void submit()}>
          Add task <CornerDownLeft size={13} />
        </button>
      </div>
    </div>
  );
}
