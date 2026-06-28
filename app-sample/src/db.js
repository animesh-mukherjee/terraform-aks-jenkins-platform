'use strict';

const { Pool } = require('pg');

// Singleton pool — created once, reused across all requests.
// Using a pool (not a single client) handles connection drops and
// ensures multiple concurrent requests share a bounded connection count.
let pool = null;

function getPool() {
  if (!pool) {
    pool = new Pool({
      // DATABASE_URL is injected from the app-db-credentials K8s Secret
      // (created by terraform/k8s-post/ in the dev/staging namespaces).
      // Format: postgresql://user:password@host:5432/dbname?sslmode=require
      connectionString: process.env.DATABASE_URL,

      // AKS → Azure PostgreSQL Flexible Server requires SSL.
      // rejectUnauthorized: false accepts the self-signed CA cert on KK;
      // in production set this to true and mount the CA cert.
      ssl: process.env.DB_SSL === 'require' ? { rejectUnauthorized: false } : false,

      max: parseInt(process.env.DB_MAX_CONNECTIONS || '5', 10),
      idleTimeoutMillis:    30000,
      connectionTimeoutMillis: 5000,
    });

    pool.on('error', (err) => {
      console.error('PostgreSQL pool error (client evicted):', err.message);
    });
  }
  return pool;
}

module.exports = { getPool };
