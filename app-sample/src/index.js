'use strict';

const express = require('express');

const app = express();

app.use(express.json());
app.use(express.urlencoded({ extended: false }));

// ── Routes ────────────────────────────────────────────────────────────────────
app.use('/health', require('./routes/health'));
app.use('/api/items', require('./routes/items'));

// Feature flags and runtime config — values come from the ConfigMap created
// by the Helm chart (app-sample/helm/app-chart/templates/configmap.yaml),
// which is mounted as envFrom in the pod Deployment.
app.get('/api/config', (_req, res) => {
  res.json({
    darkMode:    process.env.FEATURE_DARK_MODE    === 'true',
    newUserFlow: process.env.FEATURE_NEW_USER_FLOW === 'true',
    logLevel:    process.env.LOG_LEVEL            || 'info',
    environment: process.env.APP_ENVIRONMENT      || 'unknown',
  });
});

// 404 catch-all — returns JSON instead of Express's default HTML error page.
app.use((_req, res) => {
  res.status(404).json({ error: 'Not found' });
});

// ── Server startup (skipped when required as a module in tests) ────────────────
if (require.main === module) {
  const PORT = parseInt(process.env.PORT || '3000', 10);
  const server = app.listen(PORT, () => {
    console.log(`Platform sample app listening on port ${PORT}`);
    console.log(`Environment: ${process.env.APP_ENVIRONMENT || 'unknown'}`);
  });

  // Graceful shutdown: finish in-flight requests before exiting.
  // Kubernetes sends SIGTERM before SIGKILL (after terminationGracePeriodSeconds).
  process.on('SIGTERM', () => {
    console.log('SIGTERM received — shutting down gracefully...');
    server.close(() => {
      console.log('HTTP server closed.');
      process.exit(0);
    });
  });
}

module.exports = app;
