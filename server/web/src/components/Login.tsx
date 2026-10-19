import { useState } from 'react';
import { ArrowRight } from 'lucide-react';
import { useAuth } from '../state/auth';
import { BrandMark } from './Brand';

export function Login() {
  const { signIn, notice } = useAuth();
  const [code, setCode] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!code.trim() || busy) return;
    setBusy(true);
    setError('');
    const problem = await signIn(code.trim());
    setBusy(false);
    if (problem) setError(problem);
  }

  return (
    <div className="login-wrap">
      <form className="login" onSubmit={submit}>
        <BrandMark />
        <h1>NoteDo</h1>
        <p>Sign in to see your tasks in the browser.</p>
        <input
          autoFocus
          value={code}
          onChange={(e) => setCode(e.target.value)}
          placeholder="ABCD-2345"
          autoComplete="off"
          autoCapitalize="characters"
          spellCheck={false}
          maxLength={20}
          aria-label="One-time code"
        />
        {(error || notice) && <p className="err">{error || notice}</p>}
        <button className="btn btn-primary" type="submit" disabled={!code.trim() || busy}>
          {busy ? 'Signing in…' : 'Sign in'} <ArrowRight size={16} />
        </button>
        <small>
          Ask for a one-time code from the person who runs this server, or make one in the NoteDo app under Settings, Sync. It works once and expires in minutes.
          This web version works online only and keeps nothing offline.
        </small>
      </form>
    </div>
  );
}
