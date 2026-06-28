'use strict';

const { Router } = require('express');
const { getPool } = require('../db');

const router = Router();

// GET /api/items
// Returns the 100 most-recently created items.
router.get('/', async (_req, res) => {
  try {
    const result = await getPool().query(
      'SELECT id, name, created_at FROM items ORDER BY created_at DESC LIMIT 100'
    );
    res.json({ items: result.rows });
  } catch (err) {
    console.error('GET /api/items error:', err.message);
    res.status(500).json({ error: 'Failed to fetch items' });
  }
});

// GET /api/items/:id
router.get('/:id', async (req, res) => {
  const id = parseInt(req.params.id, 10);
  if (isNaN(id)) {
    return res.status(400).json({ error: 'id must be a number' });
  }
  try {
    const result = await getPool().query(
      'SELECT id, name, created_at FROM items WHERE id = $1',
      [id]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Item not found' });
    }
    res.json({ item: result.rows[0] });
  } catch (err) {
    console.error('GET /api/items/:id error:', err.message);
    res.status(500).json({ error: 'Failed to fetch item' });
  }
});

// POST /api/items
// Body: { "name": "string" }
router.post('/', async (req, res) => {
  const { name } = req.body || {};
  if (!name || typeof name !== 'string' || name.trim().length === 0) {
    return res.status(400).json({ error: 'name is required and must be a non-empty string' });
  }
  try {
    const result = await getPool().query(
      'INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at',
      [name.trim()]
    );
    res.status(201).json({ item: result.rows[0] });
  } catch (err) {
    console.error('POST /api/items error:', err.message);
    res.status(500).json({ error: 'Failed to create item' });
  }
});

// DELETE /api/items/:id
router.delete('/:id', async (req, res) => {
  const id = parseInt(req.params.id, 10);
  if (isNaN(id)) {
    return res.status(400).json({ error: 'id must be a number' });
  }
  try {
    const result = await getPool().query(
      'DELETE FROM items WHERE id = $1 RETURNING id',
      [id]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Item not found' });
    }
    res.status(204).send();
  } catch (err) {
    console.error('DELETE /api/items/:id error:', err.message);
    res.status(500).json({ error: 'Failed to delete item' });
  }
});

module.exports = router;
