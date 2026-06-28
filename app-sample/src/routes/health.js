'use strict';

const { Router } = require('express');
const { getPool } = require('../db');

const router = Router();

// GET /health
// Returns 200 OK with a JSON body when the app is ready to serve traffic.
// Returns 503 if the database is unavailable (pod fails readiness probe).
//
// Used by:
//   - Kubernetes readinessProbe and livenessProbe (Helm chart deployment.yaml)
//   - Jenkinsfile.build Stage 6 smoke test
//   - Jenkinsfile.deploy smoke test
router.get('/', async (_req, res) => {
  const status = {
    status:    'ok',
    timestamp: new Date().toISOString(),
    version:   process.env.npm_package_version || '1.0.0',
  };

  if (process.env.DATABASE_URL) {
    try {
      await getPool().query('SELECT 1');
      status.db = 'ok';
    } catch (err) {
      console.error('Health check DB ping failed:', err.message);
      status.status = 'degraded';
      status.db     = 'error';
      return res.status(503).json(status);
    }
  }

  res.json(status);
});

module.exports = router;
