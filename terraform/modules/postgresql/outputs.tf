# Terraform concept: PostgreSQL outputs split into two categories:
#   - Structural outputs (server_id, server_name, database_name,
#     administrator_login) — safe to display; used in CLI commands and
#     downstream resource references.
#   - Credential/connection outputs (server_fqdn, connection_string) —
#     marked sensitive = true because they either reveal the endpoint
#     (facilitates targeted attacks) or embed the password directly.
#     Both are passed to terraform/k8s-post/ to build the K8s app secret.

output "server_id" {
  description = "Full Azure resource ID of the PostgreSQL Flexible Server. Used as a reference by downstream resources (e.g. if a private DNS zone or VNet integration is added in a later step)."
  value       = azurerm_postgresql_flexible_server.this.id
}

output "server_name" {
  description = "Short name of the PostgreSQL server (e.g. \"psql-<prefix>-<suffix>\"). Use with `az postgres flexible-server connect` for ad-hoc queries."
  value       = azurerm_postgresql_flexible_server.this.name
}

output "server_fqdn" {
  description = "Fully-qualified domain name of the server endpoint (e.g. \"psql-<prefix>-<suffix>.postgres.database.azure.com\"). Used as the database host in the application connection string. Marked sensitive to avoid leaking the endpoint in plan output."
  value       = azurerm_postgresql_flexible_server.this.fqdn
  sensitive   = true
}

output "database_name" {
  description = "Name of the application database created inside the server (value of var.database_name). Passed to k8s-post/ to build the DB_NAME entry in the app's K8s Secret."
  value       = azurerm_postgresql_flexible_server_database.app.name
}

output "administrator_login" {
  description = "Username of the PostgreSQL admin account (value of var.administrator_login). Passed to k8s-post/ for the DB_USER entry in the app's K8s Secret."
  value       = azurerm_postgresql_flexible_server.this.administrator_login
}

# Terraform concept: `connection_string` is a computed output that assembles
# the libpq-compatible URI that most PostgreSQL clients (Node.js pg, Python
# psycopg2, Java JDBC) accept. Format:
#   postgresql://<user>:<password>@<host>:5432/<database>?sslmode=require
# `sslmode=require` is mandatory for Azure PostgreSQL Flexible Server — the
# server enforces TLS and rejects plaintext connections.
# Marked sensitive = true because it embeds the administrator password.
output "connection_string" {
  description = "Full libpq-compatible PostgreSQL connection URI, including host, credentials, database name, and sslmode=require (required by Azure). Sensitive — embeds the administrator password. Passed to k8s-post/ to populate the app DB secret."
  value       = "postgresql://${azurerm_postgresql_flexible_server.this.administrator_login}:${var.administrator_password}@${azurerm_postgresql_flexible_server.this.fqdn}:5432/${azurerm_postgresql_flexible_server_database.app.name}?sslmode=require"
  sensitive   = true
}
