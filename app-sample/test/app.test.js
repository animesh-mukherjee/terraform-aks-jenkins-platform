'use strict';

// =============================================================================
// test/app.test.js
//
// Unit tests for the Express app. All database calls are stubbed so these
// tests run WITHOUT a live PostgreSQL connection.
//
// Run: npm test
// CI:  npm run test:ci  (outputs JUnit XML to test-results/)
// =============================================================================

const assert   = require('assert');
const request  = require('supertest');

// ── Stub the database pool BEFORE requiring the app ──────────────────────────
// The db module exports { getPool }. We replace getPool with a function that
// returns a mock pool whose `query` method is controlled per-test.
// This works because Node.js module require() is cached — all modules that
// `require('../src/db')` get the same object, so replacing getPool here
// affects all route handlers that call getPool() at request time.
const db = require('../src/db');
let queryStub;
db.getPool = () => ({
  query: (...args) => queryStub(...args),
  on:    () => {},
});

// Require the app after stubbing (so routes get the stub when they call getPool)
const app = require('../src/index');

// ── /health ───────────────────────────────────────────────────────────────────
describe('GET /health', () => {
  it('returns 200 and status=ok when DATABASE_URL is not set', async () => {
    const saved = process.env.DATABASE_URL;
    delete process.env.DATABASE_URL;

    const res = await request(app).get('/health');

    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.body.status, 'ok');
    assert.ok(res.body.timestamp);

    process.env.DATABASE_URL = saved;
  });

  it('returns 200 and db=ok when DB ping succeeds', async () => {
    process.env.DATABASE_URL = 'postgresql://fake';
    queryStub = async () => ({ rows: [{ '?column?': 1 }] });

    const res = await request(app).get('/health');

    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.body.db, 'ok');

    delete process.env.DATABASE_URL;
  });

  it('returns 503 and db=error when DB ping fails', async () => {
    process.env.DATABASE_URL = 'postgresql://fake';
    queryStub = async () => { throw new Error('connection refused'); };

    const res = await request(app).get('/health');

    assert.strictEqual(res.status, 503);
    assert.strictEqual(res.body.db, 'error');

    delete process.env.DATABASE_URL;
  });
});

// ── GET /api/items ─────────────────────────────────────────────────────────────
describe('GET /api/items', () => {
  it('returns 200 with an items array', async () => {
    queryStub = async () => ({
      rows: [
        { id: 1, name: 'Alpha', created_at: new Date() },
        { id: 2, name: 'Beta',  created_at: new Date() },
      ],
    });

    const res = await request(app).get('/api/items');

    assert.strictEqual(res.status, 200);
    assert.ok(Array.isArray(res.body.items));
    assert.strictEqual(res.body.items.length, 2);
    assert.strictEqual(res.body.items[0].name, 'Alpha');
  });

  it('returns 500 when the DB throws', async () => {
    queryStub = async () => { throw new Error('query failed'); };

    const res = await request(app).get('/api/items');

    assert.strictEqual(res.status, 500);
    assert.ok(res.body.error);
  });
});

// ── GET /api/items/:id ─────────────────────────────────────────────────────────
describe('GET /api/items/:id', () => {
  it('returns 200 with the item when found', async () => {
    queryStub = async () => ({ rows: [{ id: 1, name: 'Alpha', created_at: new Date() }] });

    const res = await request(app).get('/api/items/1');

    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.body.item.id, 1);
  });

  it('returns 404 when item does not exist', async () => {
    queryStub = async () => ({ rows: [] });

    const res = await request(app).get('/api/items/999');

    assert.strictEqual(res.status, 404);
  });

  it('returns 400 for a non-numeric id', async () => {
    const res = await request(app).get('/api/items/notanumber');

    assert.strictEqual(res.status, 400);
  });
});

// ── POST /api/items ────────────────────────────────────────────────────────────
describe('POST /api/items', () => {
  it('returns 201 with the created item', async () => {
    queryStub = async () => ({
      rows: [{ id: 3, name: 'New Item', created_at: new Date() }],
    });

    const res = await request(app)
      .post('/api/items')
      .send({ name: 'New Item' });

    assert.strictEqual(res.status, 201);
    assert.strictEqual(res.body.item.name, 'New Item');
  });

  it('returns 400 when name is missing', async () => {
    const res = await request(app).post('/api/items').send({});
    assert.strictEqual(res.status, 400);
  });

  it('returns 400 when name is blank whitespace', async () => {
    const res = await request(app).post('/api/items').send({ name: '   ' });
    assert.strictEqual(res.status, 400);
  });

  it('returns 400 when name is not a string', async () => {
    const res = await request(app).post('/api/items').send({ name: 42 });
    assert.strictEqual(res.status, 400);
  });
});

// ── DELETE /api/items/:id ──────────────────────────────────────────────────────
describe('DELETE /api/items/:id', () => {
  it('returns 204 when the item is deleted', async () => {
    queryStub = async () => ({ rows: [{ id: 1 }] });

    const res = await request(app).delete('/api/items/1');
    assert.strictEqual(res.status, 204);
  });

  it('returns 404 when the item does not exist', async () => {
    queryStub = async () => ({ rows: [] });

    const res = await request(app).delete('/api/items/999');
    assert.strictEqual(res.status, 404);
  });
});

// ── GET /api/config ─────────────────────────────────────────────────────────────
describe('GET /api/config', () => {
  it('returns feature flags from environment variables', async () => {
    process.env.FEATURE_DARK_MODE    = 'true';
    process.env.FEATURE_NEW_USER_FLOW = 'false';
    process.env.APP_ENVIRONMENT       = 'test';

    const res = await request(app).get('/api/config');

    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.body.darkMode,    true);
    assert.strictEqual(res.body.newUserFlow, false);
    assert.strictEqual(res.body.environment, 'test');

    delete process.env.FEATURE_DARK_MODE;
    delete process.env.FEATURE_NEW_USER_FLOW;
    delete process.env.APP_ENVIRONMENT;
  });
});

// ── 404 handler ────────────────────────────────────────────────────────────────
describe('Unknown routes', () => {
  it('returns 404 JSON for unknown paths', async () => {
    const res = await request(app).get('/does/not/exist');
    assert.strictEqual(res.status, 404);
    assert.ok(res.body.error);
  });
});
