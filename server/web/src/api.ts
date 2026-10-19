import type { Comment, CompletedItem, Label, Project, QuickPreview, Section, Task, TaskPatch } from './types';

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

let token = '';
let unauthorizedHandler: (() => void) | null = null;

export function setToken(value: string) {
  token = value;
}

/** Called when the server says the sign-in is no longer good. */
export function onUnauthorized(handler: (() => void) | null) {
  unauthorizedHandler = handler;
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  let res: Response;
  try {
    res = await fetch(path, {
      method,
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new ApiError('Cannot reach the server. NoteDo for the web needs a connection.', 0);
  }
  if (res.status === 401 && token) {
    unauthorizedHandler?.();
    throw new ApiError('Your sign-in ended. Sign in again with a new code.', 401);
  }
  if (res.status === 204) return undefined as T;
  let json: unknown = null;
  try {
    json = await res.json();
  } catch {
    /* no body */
  }
  if (!res.ok) {
    const message = json && typeof json === 'object' && 'message' in json ? String((json as { message: unknown }).message) : `The server answered ${res.status}`;
    throw new ApiError(message, res.status);
  }
  return json as T;
}

const enc = encodeURIComponent;

export const api = {
  /** Swaps a one-time code for a sign-in token. */
  async login(code: string, name: string): Promise<{ token: string; userName: string }> {
    return request('POST', '/web/login', { code, name });
  },
  signOut: () => request<void>('DELETE', '/api/v1/session'),

  projects: () => request<{ projects: Project[] }>('GET', '/api/v1/projects').then((r) => r.projects),
  sections: () => request<{ sections: Section[] }>('GET', '/api/v1/sections').then((r) => r.sections),
  labels: () => request<{ labels: Label[] }>('GET', '/api/v1/labels').then((r) => r.labels),
  tasks: () => request<{ tasks: Task[] }>('GET', '/api/v1/tasks').then((r) => r.tasks),
  completed: (limit = 100) => request<{ items: CompletedItem[] }>('GET', `/api/v1/completed?limit=${limit}`).then((r) => r.items),
  comments: (taskId: string) => request<{ comments: Comment[] }>('GET', `/api/v1/comments?task_id=${enc(taskId)}`).then((r) => r.comments),

  quickAdd: (text: string, opts: { projectId?: string; today: string }) =>
    request<Task>('POST', '/api/v1/quick-add', { text, project_id: opts.projectId, today: opts.today }),
  quickPreview: (text: string, opts: { projectId?: string; today: string }) =>
    request<QuickPreview>('POST', '/api/v1/quick-add/parse', { text, project_id: opts.projectId, today: opts.today }),

  createTask: (body: TaskPatch & { title: string }) => request<Task>('POST', '/api/v1/tasks', body),
  updateTask: (id: string, patch: TaskPatch) => request<Task>('POST', `/api/v1/tasks/${enc(id)}`, patch),
  closeTask: (id: string) => request<Task>('POST', `/api/v1/tasks/${enc(id)}/close`, {}),
  reopenTask: (id: string) => request<Task>('POST', `/api/v1/tasks/${enc(id)}/reopen`, {}),
  deleteTask: (id: string) => request<void>('DELETE', `/api/v1/tasks/${enc(id)}`),
  reorderTasks: (ids: string[]) => request<void>('POST', '/api/v1/tasks/reorder', { ids }),

  createComment: (taskId: string, content: string) => request<Comment>('POST', '/api/v1/comments', { task_id: taskId, content }),
  deleteComment: (id: string) => request<void>('DELETE', `/api/v1/comments/${enc(id)}`),

  createProject: (name: string) => request<Project>('POST', '/api/v1/projects', { name }),
  createSection: (projectId: string, name: string) => request<Section>('POST', '/api/v1/sections', { project_id: projectId, name }),
  renameSection: (id: string, name: string) => request<Section>('POST', `/api/v1/sections/${enc(id)}`, { name }),
  deleteSection: (id: string) => request<void>('DELETE', `/api/v1/sections/${enc(id)}`),
  reorderSections: (ids: string[]) => request<void>('POST', '/api/v1/sections/reorder', { ids }),
};
