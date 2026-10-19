/** What the server's REST API (/api/v1) sends. */

export type Priority = 1 | 2 | 3 | 4;

export interface Due {
  date: string; // YYYY-MM-DD
  time: string | null; // HH:MM
  recurrence: string | null;
}

export interface Task {
  id: string;
  title: string;
  description: string;
  project_id: string;
  section_id: string | null;
  parent_id: string | null;
  priority: Priority;
  labels: string[];
  due: Due | null;
  deadline: string | null;
  duration_minutes: number | null;
  is_completed: boolean;
  completed_at: string | null;
  created_at: string;
  updated_at: string;
  order: number;
}

export interface Project {
  id: string;
  name: string;
  color: number | string | null;
  parent_id: string | null;
  is_favorite: boolean;
  is_archived: boolean;
  is_inbox: boolean;
  order: number;
}

export interface Section {
  id: string;
  project_id: string;
  name: string;
  order: number;
  is_archived: boolean;
}

export interface Label {
  id: string;
  name: string;
  color: number | string | null;
  is_favorite: boolean;
}

export interface Comment {
  id: string;
  task_id: string;
  content: string;
  posted_at: string;
}

export interface CompletedItem {
  id: string;
  task_id: string;
  title: string | null;
  project_id: string | null;
  completed_at: string;
  due_date: string | null;
  due_time: string | null;
}

/** The fields of a task that can be changed (the same names the server takes). */
export interface TaskPatch {
  title?: string;
  description?: string;
  priority?: Priority;
  project_id?: string;
  section_id?: string | null;
  parent_id?: string | null;
  due_date?: string | null;
  due_time?: string | null;
  recurrence?: string | null;
  labels?: string[];
  duration_minutes?: number | null;
}

export interface QuickToken {
  kind: 'date' | 'time' | 'repeat' | 'deadline' | 'reminder' | 'priority' | 'label' | 'project' | 'section' | 'assignee';
  start: number;
  end: number;
}

/** What a Quick Add line means (POST /api/v1/quick-add/parse). */
export interface QuickPreview {
  title: string;
  priority: number | null;
  due: Due | null;
  deadline: string | null;
  labels: string[];
  project: { id: string; name: string | null; typed: string | null; known: boolean };
  section: { id: string | null; name: string | null; typed: string; known: boolean } | null;
  repeat_error: string | null;
  tokens: QuickToken[];
}
