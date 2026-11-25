1. Generate a new unseal key and root token for Vault
------------------------------------------------------
# Initialize Vault with 1 key share and 1 key threshold (home-lab setup).
# Save the printed Unseal Key and Initial Root Token securely (never commit plaintext secrets to Git).
vault operator init -key-shares=1 -key-threshold=1


2. Unseal Vault
------------------------------------------------------
# Vault starts in a sealed state after initialization or pod restart.
# Provide the unseal key from Step 1 to decrypt Vault's storage backend.
vault operator unseal <UNSEAL_KEY_1>

# Verification: Confirm `Initialized: true` and `Sealed: false`.
vault status


3. Login to Vault using the root token
------------------------------------------------------
# Authenticate the Vault CLI with the Initial Root Token so you can configure engines and policies.
vault login <VAULT_ROOT_TOKEN>
# Tip: You can also run `vault login` with no arguments and paste the token interactively.


4. Enable the LDAP secrets engine
------------------------------------------------------
# Mount Vault's built-in LDAP secrets engine at the default `ldap/` path.
vault secrets enable ldap

# Verification: Confirm `ldap/` appears in the enabled secrets engines list.
vault secrets list


5. Create password policy (network-cli-policy) for LDAP users
------------------------------------------------------
# Define a 24-character password policy using router-CLI-safe special characters
# so rotated passwords never break Cisco IOS/Juniper Junos SSH or TACACS+ parsing.
vault write sys/policies/password/network-cli-policy policy=- << 'EOF'
length = 24
rule "charset" { charset = "abcdefghijklmnopqrstuvwxyz" min-chars = 1 }
rule "charset" { charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ" min-chars = 1 }
rule "charset" { charset = "0123456789" min-chars = 1 }
rule "charset" { charset = "!@#%^&*-_=+" min-chars = 1 }
EOF

# Verification: List all password policies, read back the rules, and test generating a sample password.
vault list sys/policies/password
vault read sys/policies/password/network-cli-policy
vault read sys/policies/password/network-cli-policy/generate


6. Connect Vault to the LLDAP server
------------------------------------------------------
# Configure Vault to bind to LLDAP using `vault_bind` (member of `lldap_password_manager`)
# and attach `network-cli-policy` for all automated password rotations.
# Replace `<VAULT_BIND_PASSWORD>` with the `vault_bind` password from LLDAP.
vault write ldap/config \
  binddn="uid=vault_bind,ou=people,dc=lab,dc=local" \
  bindpass="<VAULT_BIND_PASSWORD>" \
  url="ldap://192.168.50.243:30389" \
  userdn="ou=people,dc=lab,dc=local" \
  userattr="uid" \
  schema="openldap" \
  password_policy="network-cli-policy"

# Verification: Confirm LLDAP URL, binddn, schema, and password_policy are saved (bindpass is hidden).
vault read ldap/config


7. Create a Vault static role (vault-ldap-secret-role) for LDAP user (awx)
------------------------------------------------------
# Bind the existing LLDAP automation user (`uid=awx`) to a static role with 24-hour auto-rotation.
# Vault immediately rotates the password on creation and every 24h thereafter.
vault write ldap/static-role/vault-ldap-secret-role \
  dn="uid=awx,ou=people,dc=lab,dc=local" \
  username="awx" \
  rotation_period="24h"

# Verification: Confirm the role exists and returns the current rotated password and TTL.
vault list ldap/static-role
vault read ldap/static-role/vault-ldap-secret-role
vault read ldap/static-cred/vault-ldap-secret-role

# Optional manual rotation & verification:
# vault write -f ldap/rotate-role/vault-ldap-secret-role
# vault read ldap/static-cred/vault-ldap-secret-role


8. Validate the rotated LDAP credentials directly against LLDAP
------------------------------------------------------
# Verify that the password returned by Vault in Step 7 successfully authenticates against LLDAP.
# Use `-W` to enter the password interactively when prompted.
ldapwhoami -x -H ldap://192.168.50.243:30389 \
  -D "uid=awx,ou=people,dc=lab,dc=local" \
  -W
# Expected output: dn:uid=awx,ou=people,dc=lab,dc=local


9. Enable AppRole authentication method
------------------------------------------------------
# Enable AppRole auth so AWX can authenticate programmatically using Role ID + Secret ID.
# (Skip if `approle/` is already enabled from your GitHub AppRole setup.)
vault auth enable approle

# Verification: Confirm `approle/` appears in the enabled auth methods list.
vault auth list


10. Create a scoped ACL policy (awx-read-ldap) for AWX
------------------------------------------------------
# Grant least-privilege `read` access strictly to `ldap/static-cred/vault-ldap-secret-role`.
# This isolates LDAP access from GitHub token paths and all other Vault engines.
vault policy write awx-read-ldap - << 'EOF'
path "ldap/static-cred/vault-ldap-secret-role" {
  capabilities = ["read"]
}
EOF

# Verification: Confirm `awx-read-ldap` is listed and contains the exact path rule.
vault policy list
vault policy read awx-read-ldap

# Cleanup reference (DO NOT run during setup; only use if removing this policy):
# vault policy delete awx-read-ldap


11. Create the LDAP AppRole (awx-ldap-vault-approle)
------------------------------------------------------
# Create the dedicated AppRole for AWX's `Vault-LDAP-Lookup` credential,
# issuing short-lived 15-minute Vault client tokens (max 1h) scoped only to `awx-read-ldap`.
vault write auth/approle/role/awx-ldap-vault-approle \
  token_policies="awx-read-ldap" \
  token_ttl="15m" \
  token_max_ttl="1h"

# Verification: Confirm the role appears in the list with `token_policies: [awx-read-ldap]`.
vault list auth/approle/role
vault read auth/approle/role/awx-ldap-vault-approle


12. Generate Role ID and Secret ID for AWX
------------------------------------------------------
# Read the static Role ID and generate a fresh Secret ID (`-f` is required because no data payload is sent).
vault read auth/approle/role/awx-ldap-vault-approle/role-id
vault write -f auth/approle/role/awx-ldap-vault-approle/secret-id

# Note: Paste both UUIDs into AWX -> Resources -> Credentials -> Vault-LDAP-Lookup (API Version: v1).
# Secret IDs cannot be read back later; if you generate a new one, update AWX to match.


13. Validate AppRole login & least-privilege secret read
------------------------------------------------------
# Step A: Simulate AWX logging in to Vault via AppRole and capture the temporary client token.
LDAP_VAULT_TOKEN=$(vault write -field=token auth/approle/login \
  role_id="<ROLE_ID>" \
  secret_id="<SECRET_ID>")

# Step B: Use that scoped token to read the rotated `awx` password (expects 24-char password).
VAULT_TOKEN="$LDAP_VAULT_TOKEN" vault read ldap/static-cred/vault-ldap-secret-role

# Step C (Optional isolation test): Confirm this token is blocked from GitHub tokens (expects 403 permission denied).
VAULT_TOKEN="$LDAP_VAULT_TOKEN" vault read github/token/awx-github-app