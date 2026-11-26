1. Extract the GitHub plugin SHA-256 checksum from the Vault pod
------------------------------------------------------
# Compute the SHA-256 hash of the mounted plugin binary inside the running Vault container.
# Vault requires this checksum to verify plugin integrity before registration.
PLUGIN_SHA=$(kubectl exec -n vault deploy/vault -c vault -- sha256sum /vault/plugins/vault-plugin-secrets-github | awk '{print $1}')

# Verification: Confirm a 64-character hex SHA-256 hash is printed.
echo "$PLUGIN_SHA"

2. Register the GitHub secrets plugin in Vault
------------------------------------------------------
# Register `vault-plugin-secrets-github` in Vault's plugin catalog under the name `github`.
vault plugin register \
  -sha256="${PLUGIN_SHA}" \
  -command="vault-plugin-secrets-github" \
  secret github

# Verification: Confirm `github` appears under registered secret plugins.
vault plugin list secret

3. Enable the GitHub secrets engine
------------------------------------------------------
# Mount the registered `github` secrets plugin at the `github/` path.
vault secrets enable -path=github github

# Verification: Confirm `github/` is listed among enabled secrets engines.
vault secrets list

4. Configure the GitHub App signing key & shred the local .pem file
------------------------------------------------------
# Upload your GitHub App ID and private key (.pem) into Vault so Vault can sign JWTs.
# Ensure the .pem file is located at `/tmp/github-app.pem` before running.
vault write github/config \
  app_id="5920246" \
  prv_key=@./tmp/github-app.pem

# Verification: Confirm `app_id` is stored cleanly (private key is not echoed back).
vault read github/config

# Security cleanup: Permanently overwrite and delete the local .pem private key from disk.
shred -u /tmp/github-app.pem

5. Create the GitHub permission set (awx-github-app)
------------------------------------------------------
# Define a read-only permission set scoped strictly to the `awx` repository
# under GitHub App Installation ID `185748030`.
vault write github/permissionset/awx-github-app - << 'EOF'
{
  "installation_id": 185748030,
  "repositories": ["awx"],
  "permissions": {
    "contents": "read"
  }
}
EOF

# Verification: Confirm the permission set is saved and listed.
vault read github/permissionset/awx-github-app
vault list github/permissionset

6. Test dynamic 1-hour GitHub token minting
------------------------------------------------------
# Reading `github/token/awx-github-app` does not read a stored secret—it triggers Vault
# to mint a brand-new 1-hour read-only installation token (`ghs_...`) on demand from GitHub.
vault read github/token/awx-github-app

# Optional live Git test: Verify the minted token can query `minlawi/awx` over HTTPS.
# GH_TOKEN=$(vault read -field=token github/token/awx-github-app)
# git ls-remote "https://x-access-token:${GH_TOKEN}@github.com/minlawi/awx.git" HEAD

7. Enable AppRole authentication method
------------------------------------------------------
# Enable AppRole auth so AWX can authenticate using Role ID + Secret ID.
# (Skip if `approle/` is already enabled from your LDAP AppRole setup.)
vault auth enable approle

# Verification: Confirm `approle/` appears in the enabled auth methods list.
vault auth list

8. Create a scoped ACL policy (awx-read-github) for AWX
------------------------------------------------------
# Grant least-privilege `read` access strictly to `github/token/awx-github-app`.
# This isolates GitHub token minting from LDAP router credentials and all other Vault paths.
vault policy write awx-read-github - << 'EOF'
path "github/token/awx-github-app" {
  capabilities = ["read"]
}
EOF

# Verification: Confirm `awx-read-github` is listed and contains the exact path rule.
vault policy list
vault policy read awx-read-github

# Cleanup reference (DO NOT run during setup; only use if removing this policy):
# vault policy delete awx-read-github

9. Create the GitHub AppRole (awx-github-vault-approle)
------------------------------------------------------
# Create the dedicated AppRole for AWX's `Vault-GitHub-Lookup` credential,
# issuing short-lived 10-minute Vault client tokens (max 30m) scoped only to `awx-read-github`.
vault write auth/approle/role/awx-github-vault-approle \
  token_policies="awx-read-github" \
  token_ttl=10m \
  token_max_ttl=30m

# Verification: Confirm the role appears in the list with `token_policies: [awx-read-github]`.
vault list auth/approle/role
vault read auth/approle/role/awx-github-vault-approle

10. Generate Role ID and Secret ID for AWX
------------------------------------------------------
# Read the static Role ID and generate a fresh Secret ID (`-f` is required because no data payload is sent).
vault read auth/approle/role/awx-github-vault-approle/role-id
vault write -f auth/approle/role/awx-github-vault-approle/secret-id

# Note: Paste both UUIDs into AWX -> Resources -> Credentials -> Vault-GitHub-Lookup (API Version: v1).
# Secret IDs cannot be read back later; if you generate a new one, update AWX to match.

11. Validate AppRole login, dynamic token minting & cross-role isolation
------------------------------------------------------
# Step A: Simulate AWX logging in to Vault via AppRole and capture the temporary client token.
GH_VAULT_TOKEN=$(vault write -field=token auth/approle/login \
  role_id="<ROLE_ID>" \
  secret_id="<SECRET_ID>")

# Step B: Use that scoped token to mint a fresh 1-hour GitHub token (expects `ghs_...`).
VAULT_TOKEN="$GH_VAULT_TOKEN" vault read -field=token github/token/awx-github-app

# Step C (Isolation test): Confirm this token is blocked from LDAP router passwords (expects 403 permission denied).
VAULT_TOKEN="$GH_VAULT_TOKEN" vault read ldap/static-cred/vault-ldap-secret-role