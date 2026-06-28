'use strict';

// =============================================================================
// db/migrate.js
//
// Lightweight migration runner — no ORM, no framework, no external deps
// beyond `pg`. Designed to run once inside the ACI container group and exit.
//
// Algorithm:
//   1. Connect to PostgreSQL using DATABASE_URL env var
//   2. Create _migrations table if it doesn't exist (idempotent)
//   3. Read all *.sql files from db/migrations/ in lexicographic order
//   4. Skip files already recorded in _migrations
//   5. Execute each pending file in a transaction
//   6. Record each executed file in _migrations
//   7. Exit 0 on success; exit 1 on any error
//
// Env vars (injected by Jenkinsfile.build Stage 4 via az container create):
//   DATABASE_URL — full libpq URI
//   DB_SSL       — "require" to enable TLS (always required for Azure PostgreSQL)
// =============================================================================

const { Client } = require('pg');
const fs         = require('fs');
const path       = require('path');

const MIGRATIONS_DIR = path.join(__dirname, 'migrations');

async function run() {
  const client = new Client({
    connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'require' ? { rejectUnauthorized: false } : false,
  });

  try {
    await client.connect();
    console.log('Connected to PostgreSQL.');

    // ── Create tracking table ───────────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS _migrations (
        id         SERIAL PRIMARY KEY,
        filename   VARCHAR(255) NOT NULL UNIQUE,
        applied_at TIMESTAMP   DEFAULT NOW()
      )
    `);

    // ── Read migration files ────────────────────────────────────────────────
    const files = fs.readdirSync(MIGRATIONS_DIR)
      .filter(f => f.endsWith('.sql'))
      .sort();

    if (files.length === 0) {
      console.log('No migration files found in db/migrations/');
      return;
    }

    // ── Check which migrations have already run ─────────────────────────────
    const { rows } = await client.query('SELECT filename FROM _migrations');
    const applied  = new Set(rows.map(r => r.filename));

    const pending = files.filter(f => !applied.has(f));
    if (pending.length === 0) {
      console.log('All migrations are up to date.');
      return;
    }

    console.log(`Pending migrations: ${pending.join(', ')}`);

    // ── Run each pending migration in its own transaction ─────────────────────
    for (const file of pending) {
      const filepath = path.join(MIGRATIONS_DIR, file);
      const sql      = fs.readFileSync(filepath, 'utf8');

      console.log(`Applying ${file}...`);
      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query(
          'INSERT INTO _migrations (filename) VALUES ($1)',
          [file]
        );
        await client.query('COMMIT');
        console.log(`  ✓ ${file} applied.`);
      } catch (err) {
        await client.query('ROLLBACK');
        throw new Error(`Migration ${file} failed: ${err.message}`);
      }
    }

    console.log(`All ${pending.length} migration(s) applied successfully.`);

  } finally {
    await client.end();
  }
}

run().catch(err => {
  console.error('Migration failed:', err.message);
  process.exit(1);
});
