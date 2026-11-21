use std::fs::{self, DirBuilder, OpenOptions};
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, bail, ensure};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

#[derive(Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum AnchorKind {
    Line,
    Text,
}

#[derive(Debug, Deserialize, PartialEq, Serialize)]
pub struct Anchor {
    kind: AnchorKind,
    quote: String,
    prefix: String,
    suffix: String,
    digest: String,
    offset: u64,
    line: u64,
}

impl Anchor {
    fn encode(&self) -> Result<String> {
        ensure!(
            self.kind != AnchorKind::Text || !self.quote.is_empty(),
            "Invalid anchor: text selection cannot be empty"
        );
        Ok(serde_json::to_string(self)?)
    }
}

#[derive(Debug, Deserialize, PartialEq, Serialize)]
pub struct Message {
    id: i64,
    author: String,
    body: String,
    created_at: String,
    edited_at: Option<String>,
    revision: i64,
}

#[derive(Debug, Deserialize, PartialEq, Serialize)]
pub struct Thread {
    pub id: String,
    pub path: String,
    anchor: Anchor,
    status: String,
    status_by: Option<String>,
    status_at: Option<String>,
    messages: Vec<Message>,
}

#[derive(Debug, Deserialize, PartialEq, Serialize)]
#[serde(untagged)]
pub enum Snapshot {
    Thread(Box<Thread>),
    Missing(bool),
}

impl Snapshot {
    fn validate(&self, id: &str) -> Result<()> {
        match self {
            Self::Thread(thread) => {
                ensure!(
                    thread.id == id
                        && matches!(thread.status.as_str(), "open" | "resolved")
                        && !thread.messages.is_empty(),
                    "Invalid thread snapshot"
                );
            }
            Self::Missing(false) => {}
            Self::Missing(true) => bail!("Invalid thread snapshot"),
        }
        Ok(())
    }
}

#[derive(Deserialize)]
pub struct Restore {
    pub expected: Snapshot,
    pub replacement: Snapshot,
}

pub fn inbox_path(root: &Path) -> Result<PathBuf> {
    let data = std::env::var_os("XDG_DATA_HOME")
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::home_dir().map(|home| home.join(".local/share")))
        .context("Set XDG_DATA_HOME or HOME to store comments")?;
    let key = Sha256::digest(root.as_os_str().as_encoded_bytes());
    Ok(data
        .join("comment-threads")
        .join(format!("{key:x}.sqlite3")))
}

pub fn connect(path: &Path) -> Result<Connection> {
    let mut directory = DirBuilder::new();
    directory.recursive(true);
    let mut file = OpenOptions::new();
    file.create(true).write(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
        directory.mode(0o700);
        file.mode(0o600);
    }
    directory.create(path.parent().context("Missing inbox directory")?)?;
    drop(file.open(path)?);
    let db = Connection::open(path)?;
    db.busy_timeout(Duration::from_secs(5))?;
    db.pragma_update(None, "foreign_keys", "ON")?;
    db.execute_batch(include_str!("schema.sql"))?;
    Ok(db)
}

pub fn signal_change(path: &Path) -> Result<()> {
    // Replace the marker to notify directory watchers after the commit.
    let file = tempfile::Builder::new()
        .prefix(".notify-")
        .tempfile_in(path.parent().context("Missing inbox directory")?)?;
    file.persist(path.with_extension("changed"))?;
    Ok(())
}

pub fn fetch(
    db: &Connection,
    id: Option<&str>,
    path: Option<&str>,
    status: Option<&str>,
) -> Result<Vec<Thread>> {
    let filters = [("id", id), ("path", path), ("status", status)];
    let conditions: Vec<_> = filters
        .iter()
        .filter(|(_, value)| value.is_some())
        .map(|(column, _)| format!("{column} = ?"))
        .collect();
    let sql = format!(
        "SELECT id, path, anchor, status, status_by, status_at FROM threads {} ORDER BY rowid",
        if conditions.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", conditions.join(" AND "))
        },
    );
    let mut stmt = db.prepare(&sql)?;
    let mut rows = stmt.query(rusqlite::params_from_iter(
        filters.iter().filter_map(|(_, value)| *value),
    ))?;
    let mut messages = db.prepare(
        "SELECT id, author, body, created_at, edited_at, revision
         FROM messages WHERE thread_id = ? ORDER BY id",
    )?;
    let mut threads = Vec::new();
    while let Some(row) = rows.next()? {
        let id: String = row.get(0)?;
        let anchor: String = row.get(2)?;
        let messages = messages
            .query_map([&id], |msg| {
                Ok(Message {
                    id: msg.get(0)?,
                    author: msg.get(1)?,
                    body: msg.get(2)?,
                    created_at: msg.get(3)?,
                    edited_at: msg.get(4)?,
                    revision: msg.get(5)?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?;
        threads.push(Thread {
            id,
            path: row.get(1)?,
            anchor: serde_json::from_str(&anchor)?,
            status: row.get(3)?,
            status_by: row.get(4)?,
            status_at: row.get(5)?,
            messages,
        });
    }
    Ok(threads)
}

pub fn require_thread(db: &Connection, id: &str) -> Result<Thread> {
    match snapshot(db, id)? {
        Snapshot::Thread(thread) => Ok(*thread),
        Snapshot::Missing(_) => bail!("No thread {id}"),
    }
}

pub fn snapshot(db: &Connection, id: &str) -> Result<Snapshot> {
    Ok(fetch(db, Some(id), None, None)?
        .into_iter()
        .next()
        .map_or(Snapshot::Missing(false), |thread| {
            Snapshot::Thread(Box::new(thread))
        }))
}

pub fn create(
    db: &Connection,
    root: &Path,
    path: &Path,
    anchor: &Anchor,
    author: &str,
    body: &str,
) -> Result<Thread> {
    ensure!(
        !path.is_absolute(),
        "Source path must be workspace-relative"
    );
    let resolved = fs::canonicalize(root.join(path)).context("Could not resolve source file")?;
    let relative = resolved
        .strip_prefix(root)
        .ok()
        .filter(|path| !path.as_os_str().is_empty() && resolved.is_file())
        .context("Source must be a file inside the workspace")?;
    let relative = relative.to_str().context("Source path is not UTF-8")?;
    let id = Uuid::new_v4().simple().to_string()[..12].to_owned();
    db.execute(
        "INSERT INTO threads (id, path, anchor) VALUES (?, ?, ?)",
        params![id, relative, anchor.encode()?],
    )?;
    add_message(db, &id, author, body)?;
    require_thread(db, &id)
}

pub fn add_message(db: &Connection, id: &str, author: &str, body: &str) -> Result<()> {
    db.execute(
        "INSERT INTO message_ids VALUES (1, (SELECT coalesce(max(id), 0) + 1 FROM messages))
         ON CONFLICT(singleton) DO UPDATE SET last_id = max(last_id + 1, excluded.last_id)",
        [],
    )?;
    db.execute(
        "INSERT INTO messages (id, thread_id, author, body)
         SELECT last_id, ?, ?, ? FROM message_ids WHERE singleton = 1",
        params![id, author, body],
    )?;
    Ok(())
}

pub fn edit(db: &Connection, id: &str, message: i64, rev: i64, body: &str) -> Result<()> {
    let changed = db.execute(
        "UPDATE messages SET body = ?, edited_at = CURRENT_TIMESTAMP, revision = revision + 1
         WHERE thread_id = ? AND id = ? AND revision = ?",
        params![body, id, message, rev],
    )?;
    ensure!(
        changed == 1,
        "Message changed or was not found. Reopen it before editing."
    );
    Ok(())
}

pub fn delete(db: &Connection, id: &str, message: i64, rev: i64) -> Result<()> {
    db.execute(
        "INSERT OR IGNORE INTO message_ids SELECT 1, coalesce(max(id), 0) FROM messages",
        [],
    )?;
    let deleted = db.execute(
        "DELETE FROM messages WHERE thread_id = ? AND id = ? AND revision = ?",
        params![id, message, rev],
    )?;
    ensure!(
        deleted == 1,
        "Message changed or was not found. Select it again before deleting."
    );
    db.execute(
        "DELETE FROM threads WHERE id = ?1 AND NOT EXISTS (SELECT 1 FROM messages WHERE thread_id = ?1)",
        [id],
    )?;
    Ok(())
}

pub fn status(db: &Connection, id: &str, status: &str, author: &str) -> Result<()> {
    db.execute(
        "UPDATE threads SET status = ?, status_by = ?, status_at = CURRENT_TIMESTAMP WHERE id = ?",
        params![status, author, id],
    )?;
    Ok(())
}

pub fn attach(db: &Connection, id: &str, anchor: &Anchor) -> Result<()> {
    db.execute(
        "UPDATE threads SET anchor = ? WHERE id = ?",
        params![anchor.encode()?, id],
    )?;
    Ok(())
}

pub fn restore(db: &Connection, id: &str, change: Restore) -> Result<Snapshot> {
    change.expected.validate(id)?;
    change.replacement.validate(id)?;
    ensure!(
        snapshot(db, id)? == change.expected,
        "Thread changed since this action. Undo/redo would overwrite newer changes."
    );
    db.execute("DELETE FROM messages WHERE thread_id = ?", [id])?;
    let Snapshot::Thread(thread) = &change.replacement else {
        db.execute("DELETE FROM threads WHERE id = ?", [id])?;
        return Ok(change.replacement);
    };
    db.execute(
        "INSERT INTO threads (id, path, anchor, status, status_by, status_at) VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET path = excluded.path, anchor = excluded.anchor,
           status = excluded.status, status_by = excluded.status_by, status_at = excluded.status_at",
        params![id, thread.path, thread.anchor.encode()?, thread.status, thread.status_by, thread.status_at],
    )?;
    let mut insert = db.prepare(
        "INSERT INTO messages (id, thread_id, author, body, created_at, edited_at, revision)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
    )?;
    for msg in &thread.messages {
        insert.execute(params![
            msg.id,
            id,
            msg.author,
            msg.body,
            msg.created_at,
            msg.edited_at,
            msg.revision
        ])?;
    }
    Ok(change.replacement)
}
