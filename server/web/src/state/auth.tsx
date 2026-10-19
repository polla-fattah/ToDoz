import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { api, ApiError, onUnauthorized, setToken } from '../api';
import { todayIso } from '../lib/dates';

const TOKEN_KEY = 'notedo.token';
const USER_KEY = 'notedo.user';

const read = (key: string) => {
  try {
    return localStorage.getItem(key) ?? '';
  } catch {
    return '';
  }
};
const write = (key: string, value: string | null) => {
  try {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch {
    /* private mode: the sign-in lasts until the tab closes */
  }
};

interface AuthApi {
  signedIn: boolean;
  userName: string;
  /** Why the person was signed out (their sign-in ended, say), shown on the sign-in page. */
  notice: string;
  signIn: (code: string) => Promise<string | null>;
  signOut: () => Promise<void>;
}

const AuthContext = createContext<AuthApi | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [token, setTokenState] = useState(() => {
    const saved = read(TOKEN_KEY);
    setToken(saved); // before the first request
    return saved;
  });
  const [userName, setUserName] = useState(() => read(USER_KEY));
  const [notice, setNotice] = useState('');

  const forget = useCallback((why: string) => {
    setToken('');
    write(TOKEN_KEY, null);
    setTokenState('');
    setNotice(why);
  }, []);

  useEffect(() => {
    onUnauthorized(() => forget('Your sign-in ended. Sign in again with a new code.'));
    return () => onUnauthorized(null);
  }, [forget]);

  const signIn = useCallback(async (code: string) => {
    try {
      const r = await api.login(code, `Web browser ${todayIso()}`);
      setToken(r.token);
      write(TOKEN_KEY, r.token);
      write(USER_KEY, r.userName);
      setUserName(r.userName);
      setNotice('');
      setTokenState(r.token);
      return null;
    } catch (e) {
      return e instanceof ApiError ? e.message : 'That did not work.';
    }
  }, []);

  const signOut = useCallback(async () => {
    try {
      await api.signOut();
    } catch {
      /* signing out here anyway */
    }
    forget('');
  }, [forget]);

  const value = useMemo<AuthApi>(() => ({ signedIn: !!token, userName, notice, signIn, signOut }), [token, userName, notice, signIn, signOut]);
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthApi {
  const value = useContext(AuthContext);
  if (!value) throw new Error('useAuth needs an AuthProvider');
  return value;
}
