// SQLite schema inside the DO. Append new migrations to MIGRATIONS; never edit existing entries

const MIGRATIONS: string[] = [
  `
  CREATE TABLE packages (
    package      TEXT NOT NULL,
    version      TEXT NOT NULL,
    arch         TEXT NOT NULL,
    filename     TEXT NOT NULL,
    size         INTEGER NOT NULL,
    md5          TEXT NOT NULL,
    sha1         TEXT NOT NULL,
    sha256       TEXT NOT NULL,
    control      TEXT NOT NULL,          -- control paragraph as JSON
    changelog    TEXT,
    yanked       INTEGER NOT NULL DEFAULT 0,
    published_at INTEGER NOT NULL,
    actor        TEXT NOT NULL,
    PRIMARY KEY (package, version, arch)
  );
  CREATE TABLE meta (
    package    TEXT PRIMARY KEY,
    data       TEXT NOT NULL,            -- PackageMeta as JSON
    updated_at INTEGER NOT NULL
  );
  CREATE TABLE snapshots (
    gen        INTEGER PRIMARY KEY,
    created_at INTEGER NOT NULL,
    reason     TEXT NOT NULL,
    entries    TEXT NOT NULL,            -- JSON list of "package|version|arch" in the snapshot, used for rollback
    packages_sha256 TEXT NOT NULL
  );
  CREATE TABLE audit (
    id     INTEGER PRIMARY KEY AUTOINCREMENT,
    at     INTEGER NOT NULL,
    actor  TEXT NOT NULL,
    action TEXT NOT NULL,
    target TEXT NOT NULL,
    detail TEXT
  );
  `,
]

export function migrate(sql: SqlStorage): void {
  sql.exec('CREATE TABLE IF NOT EXISTS _schema (version INTEGER NOT NULL)')
  const row = sql.exec<{ version: number }>('SELECT version FROM _schema').toArray()[0]
  let version = row?.version ?? 0
  if (!row) sql.exec('INSERT INTO _schema (version) VALUES (0)')

  for (; version < MIGRATIONS.length; version++) {
    sql.exec(MIGRATIONS[version]!)
    sql.exec('UPDATE _schema SET version = ?', version + 1)
  }
}
