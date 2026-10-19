import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from 'react';
import { CircleAlert, Info, X } from 'lucide-react';

interface ToastItem {
  id: number;
  message: string;
  kind: 'info' | 'error';
  action?: { label: string; run: () => void };
}

interface ToastApi {
  toast: (message: string, options?: { action?: ToastItem['action']; kind?: ToastItem['kind'] }) => void;
  error: (message: string) => void;
}

const ToastContext = createContext<ToastApi | null>(null);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([]);
  const next = useRef(1);

  const dismiss = useCallback((id: number) => setItems((all) => all.filter((t) => t.id !== id)), []);

  const toast = useCallback<ToastApi['toast']>(
    (message, options) => {
      const id = next.current++;
      const kind = options?.kind ?? 'info';
      setItems((all) => [...all.slice(-3), { id, message, kind, action: options?.action }]);
      window.setTimeout(() => dismiss(id), kind === 'error' ? 8000 : options?.action ? 7000 : 4000);
    },
    [dismiss],
  );

  const api = useMemo<ToastApi>(() => ({ toast, error: (message) => toast(message, { kind: 'error' }) }), [toast]);

  return (
    <ToastContext.Provider value={api}>
      {children}
      <div className="toasts" role="status" aria-live="polite">
        {items.map((t) => (
          <div key={t.id} className={`toast toast-${t.kind}`}>
            {t.kind === 'error' ? <CircleAlert size={16} /> : <Info size={16} />}
            <span className="toast-text">{t.message}</span>
            {t.action && (
              <button
                className="toast-action"
                onClick={() => {
                  dismiss(t.id);
                  t.action!.run();
                }}
              >
                {t.action.label}
              </button>
            )}
            <button className="icon-btn toast-close" aria-label="Dismiss" onClick={() => dismiss(t.id)}>
              <X size={14} />
            </button>
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}

export function useToast(): ToastApi {
  const value = useContext(ToastContext);
  if (!value) throw new Error('useToast needs a ToastProvider');
  return value;
}
