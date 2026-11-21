mod store;

use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use anyhow::{Context, Result, ensure};
use clap::{Parser, Subcommand, ValueEnum};
use rusqlite::{Connection, TransactionBehavior};
use serde::Deserialize;
use serde_json::{Value, json, to_value};

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    /// Override the Git worktree root (or current directory)
    #[arg(long)]
    root: Option<PathBuf>,
    #[arg(long, hide = true)]
    record: bool,
    #[command(subcommand)]
    action: Action,
}

#[derive(Clone, Copy, ValueEnum)]
enum Status {
    Open,
    Resolved,
}

impl Status {
    fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Resolved => "resolved",
        }
    }
}

#[derive(Subcommand)]
enum Action {
    /// List threads and their messages (open threads by default)
    List {
        #[arg(long, conflicts_with = "status")]
        all: bool,
        #[arg(long, value_enum)]
        status: Option<Status>,
        /// Match a workspace-relative source path
        #[arg(long)]
        path: Option<String>,
    },
    /// Show one thread and its messages
    Show { id: String },
    /// Post a reply (read stdin if --body is omitted)
    Reply {
        id: String,
        #[arg(long, value_parser = author)]
        author: String,
        #[arg(long, allow_hyphen_values = true)]
        body: Option<String>,
    },
    /// Edit a message at the given revision
    Edit {
        id: String,
        message: i64,
        #[arg(long)]
        revision: i64,
        #[arg(long, allow_hyphen_values = true)]
        body: Option<String>,
    },
    /// Delete a message at the given revision
    Delete {
        id: String,
        message: i64,
        #[arg(long)]
        revision: i64,
    },
    /// Resolve a thread without removing its history
    Resolve {
        id: String,
        #[arg(long, value_parser = author)]
        author: String,
    },
    /// Reopen a resolved thread
    Reopen {
        id: String,
        #[arg(long, value_parser = author)]
        author: String,
    },
    #[command(hide = true)]
    Attach { id: String },
    #[command(hide = true)]
    Restore { id: String },
    #[command(hide = true)]
    Create {
        #[arg(long, value_parser = author)]
        author: String,
    },
}

impl Action {
    fn id(&self) -> Option<&str> {
        match self {
            Self::List { .. } | Self::Create { .. } => None,
            Self::Show { id }
            | Self::Reply { id, .. }
            | Self::Edit { id, .. }
            | Self::Delete { id, .. }
            | Self::Resolve { id, .. }
            | Self::Reopen { id, .. }
            | Self::Attach { id }
            | Self::Restore { id } => Some(id),
        }
    }

    fn read_only(&self) -> bool {
        matches!(self, Self::List { .. } | Self::Show { .. })
    }

    fn input(&self) -> Result<String> {
        let mut input = String::new();
        if matches!(
            self,
            Self::Reply { body: None, .. }
                | Self::Edit { body: None, .. }
                | Self::Create { .. }
                | Self::Attach { .. }
                | Self::Restore { .. }
        ) {
            io::stdin().read_to_string(&mut input)?;
        }
        Ok(input)
    }
}

#[derive(Deserialize)]
struct NewThread {
    path: PathBuf,
    body: String,
    anchor: store::Anchor,
}

fn author(value: &str) -> Result<String, &'static str> {
    let value = value.trim();
    if value.is_empty() || value.contains(['\r', '\n']) {
        Err("Author must be a nonempty single line")
    } else {
        Ok(value.to_owned())
    }
}

fn nonempty_body(body: &str) -> Result<&str> {
    ensure!(!body.trim().is_empty(), "Comment text cannot be empty");
    Ok(body)
}

fn workspace(root: Option<&Path>) -> Result<PathBuf> {
    if let Some(root) = root {
        return root.canonicalize().context("Could not resolve workspace");
    }
    if let Ok(output) = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        && output.status.success()
    {
        let path = output.stdout.strip_suffix(b"\n").unwrap_or(&output.stdout);
        #[cfg(unix)]
        let path = {
            use std::os::unix::ffi::OsStrExt;
            Path::new(std::ffi::OsStr::from_bytes(path))
        };
        #[cfg(not(unix))]
        let path = Path::new(std::str::from_utf8(path)?);
        return path
            .canonicalize()
            .context("Could not resolve Git worktree");
    }
    Ok(std::env::current_dir()?.canonicalize()?)
}

fn apply(db: &Connection, root: &Path, action: &Action, input: &str) -> Result<Value> {
    match action {
        Action::List { all, status, path } => {
            let status = (!all).then(|| status.unwrap_or(Status::Open).as_str());
            return Ok(to_value(store::fetch(db, None, path.as_deref(), status)?)?);
        }
        Action::Create { author } => {
            let new: NewThread = serde_json::from_str(input)?;
            return Ok(to_value(store::create(
                db,
                root,
                &new.path,
                &new.anchor,
                author,
                nonempty_body(&new.body)?,
            )?)?);
        }
        Action::Restore { id } => {
            return Ok(to_value(store::restore(
                db,
                id,
                serde_json::from_str(input)?,
            )?)?);
        }
        Action::Show { .. } => {}
        Action::Reply { id, author, body } => {
            store::add_message(
                db,
                id,
                author,
                nonempty_body(body.as_deref().unwrap_or(input))?,
            )?;
        }
        Action::Edit {
            id,
            message,
            revision,
            body,
        } => {
            store::edit(
                db,
                id,
                *message,
                *revision,
                nonempty_body(body.as_deref().unwrap_or(input))?,
            )?;
        }
        Action::Delete {
            id,
            message,
            revision,
        } => {
            store::delete(db, id, *message, *revision)?;
            return Ok(json!({"deleted": true}));
        }
        Action::Resolve { id, author } => store::status(db, id, "resolved", author)?,
        Action::Reopen { id, author } => store::status(db, id, "open", author)?,
        Action::Attach { id } => store::attach(db, id, &serde_json::from_str(input)?)?,
    }
    Ok(to_value(store::require_thread(
        db,
        action.id().context("Missing thread ID")?,
    )?)?)
}

fn run(cli: Cli) -> Result<Value> {
    let root = workspace(cli.root.as_deref())?;
    let db_path = store::inbox_path(&root)?;
    let action = cli.action;
    if matches!(action, Action::List { .. }) && !db_path.try_exists()? {
        return Ok(json!([]));
    }
    let input = action.input()?;
    let mut db = store::connect(&db_path)?;
    if action.read_only() {
        return apply(&db, &root, &action, &input);
    }
    let transaction = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let record = cli.record && !matches!(action, Action::Restore { .. });
    let before = if record && let Some(id) = action.id() {
        store::snapshot(&transaction, id)?
    } else {
        store::Snapshot::Missing(false)
    };
    let result = apply(&transaction, &root, &action, &input)?;
    let change = if record {
        let id = action
            .id()
            .or_else(|| result["id"].as_str())
            .context("Missing thread ID")?;
        // Delete returns an acknowledgement rather than the updated thread.
        let after = if matches!(action, Action::Delete { .. }) {
            Some(store::snapshot(&transaction, id)?)
        } else {
            None
        };
        Some((id, before, after))
    } else {
        None
    };
    transaction.commit()?;
    if let Err(err) = store::signal_change(&db_path) {
        eprintln!("comment-threads: saved, but could not notify Neovim: {err:#}");
    }
    if let Some((id, before, after)) = change {
        let after = after.map_or_else(|| Ok(result.clone()), to_value)?;
        Ok(json!({
            "result": result,
            "change": { "id": id, "before": before, "after": after },
        }))
    } else {
        Ok(result)
    }
}

fn main() -> ExitCode {
    if let Err(err) = run(Cli::parse()).and_then(|value| {
        let mut out = io::stdout().lock();
        serde_json::to_writer_pretty(&mut out, &value)?;
        writeln!(out)?;
        Ok(())
    }) {
        eprintln!("comment-threads: {err:#}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}
