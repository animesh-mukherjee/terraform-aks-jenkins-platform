-- Migration: 001_create_items.sql
-- Creates the items table used by GET/POST /api/items.
-- Applied by db/migrate.js running inside the ACI container (Stage 4).
-- Safe to run multiple times: the migration runner tracks applied files
-- in the _migrations table and skips files that have already run.

CREATE TABLE IF NOT EXISTS items (
  id         SERIAL       PRIMARY KEY,
  name       VARCHAR(255) NOT NULL,
  created_at TIMESTAMP    NOT NULL DEFAULT NOW()
);

-- Index for the ORDER BY created_at DESC query in GET /api/items.
CREATE INDEX IF NOT EXISTS items_created_at_idx ON items (created_at DESC);

-- Seed row so the app returns a non-empty response on first deploy.
INSERT INTO items (name)
SELECT 'Hello from AKS Jenkins Platform!'
WHERE NOT EXISTS (SELECT 1 FROM items LIMIT 1);
