import { HashRouter, Navigate, Route, Routes } from 'react-router-dom';
import { Login } from './components/Login';
import { Layout } from './Layout';
import { AuthProvider, useAuth } from './state/auth';
import { DataProvider } from './state/data';
import { PrefsProvider } from './state/prefs';
import { ToastProvider } from './state/toast';
import { CompletedView, LabelView, TodayView, UpcomingView } from './views/SimpleViews';
import { ProjectView } from './views/ProjectView';

function Signed() {
  return (
    <DataProvider>
      <HashRouter>
        <Routes>
          <Route element={<Layout />}>
            <Route index element={<Navigate to="/today" replace />} />
            <Route path="inbox" element={<ProjectView inbox />} />
            <Route path="today" element={<TodayView />} />
            <Route path="upcoming" element={<UpcomingView />} />
            <Route path="completed" element={<CompletedView />} />
            <Route path="project/:id" element={<ProjectView />} />
            <Route path="label/:id" element={<LabelView />} />
            <Route path="*" element={<Navigate to="/today" replace />} />
          </Route>
        </Routes>
      </HashRouter>
    </DataProvider>
  );
}

function Gate() {
  const { signedIn } = useAuth();
  return signedIn ? <Signed /> : <Login />;
}

export function App() {
  return (
    <PrefsProvider>
      <ToastProvider>
        <AuthProvider>
          <Gate />
        </AuthProvider>
      </ToastProvider>
    </PrefsProvider>
  );
}
