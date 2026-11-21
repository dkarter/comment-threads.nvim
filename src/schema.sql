CREATE TABLE IF NOT EXISTS threads (
    id TEXT PRIMARY KEY,
    path TEXT NOT NULL,
    anchor TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'open',
    status_by TEXT,
    status_at TEXT
);
CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY,
    thread_id TEXT NOT NULL REFERENCES threads(id),
    author TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    edited_at TEXT,
    revision INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS threads_path ON threads(path);
CREATE INDEX IF NOT EXISTS messages_thread ON messages(thread_id);
CREATE TABLE IF NOT EXISTS message_ids (singleton INTEGER PRIMARY KEY, last_id INTEGER NOT NULL);
