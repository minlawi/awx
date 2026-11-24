1. Generate a new unseal key and root token for Vault
------------------------------------------------------
vault operator init -key-shares=1 -key-threshold=1

# Save the printed Unseal Key and Initial Root Token securely (do not commit plaintext secrets to Git).

2. Unseal Vault
------------------------------------------------------
vault operator unseal <UNSEAL_KEY_1>

Verification command:
vault status

3. Login to Vault using the root token
------------------------------------------------------
vault login <VAULT_ROOT_TOKEN>
# Or run `vault login` and paste the token when prompted.

4. Enable the LDAP secrets engine
------------------------------------------------------
vault secrets enable ldap

Verification command:
vault secrets list

5. Create password policy (network-cli) for LDAP users
------------------------------------------------------
vault write sys/policies/password/network-cli policy=- << 'EOF'
length = 20
rule "charset" {
  charset = "abcdefghijklmnopqrstuvwxyz"
  min-chars = 4
}
rule "charset" {
  charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  min-chars = 4
}
rule "charset" {
  charset = "0123456789"
  min-chars = 4
}
rule "charset" {
  charset = "!@#%^&*-_+="
  min-chars = 2
}
EOF

Verification commands:
vault read sys/policies/password/network-cli
vault read sys/policies/password/network-cli/generate

6. Connect Vault to LDAP server
------------------------------------------------------
vault write ldap/config \
  binddn="uid=vault_bind,ou=people,dc=lab,dc=local" \
  bindpass="<VAULT_BIND_PASSWORD>" \
  url="ldap://192.168.50.243:30389" \
  userdn="ou=people,dc=lab,dc=local" \
  userattr="uid" \
  schema="openldap" \
  password_policy="network-cli"

Verification command:
vault read ldap/config

7. Create a Vault static role (ldap-ansible-role) for LDAP user (ldap_ansible)
------------------------------------------------------
vault write ldap/static-role/ldap-ansible-role \
  username="ldap_ansible" \
  rotation_period="24h"

Verification commands:
vault read ldap/static-role/ldap-ansible-role
vault read ldap/static-cred/ldap-ansible-role

Manual rotation & verification:
vault write -f ldap/rotate-role/ldap-ansible-role
vault read ldap/static-cred/ldap-ansible-role

8. Validate the LDAP role credentials against the LDAP server
------------------------------------------------------
ldapwhoami -x -H ldap://192.168.50.243:30389 \
  -D "uid=ldap_ansible,ou=people,dc=lab,dc=local" \
  -W "<PASSWORD>"
# Enter the password returned by `vault read ldap/static-cred/ldap-ansible-role` when prompted.

9. Create a policy (awx-ldap-read) for AWX to read the LDAP role credentials
------------------------------------------------------
vault policy write awx-ldap-read - << 'EOF'
path "ldap/static-cred/ldap-ansible-role" {
  capabilities = ["read"]
}
EOF

Verification command:
vault policy read awx-ldap-read

10. Enable Auth Method (AppRole) and create awx-role
------------------------------------------------------
vault auth enable approle

vault write auth/approle/role/awx-role \
  token_policies="awx-ldap-read" \
  token_ttl="15m" \
  token_max_ttl="1h"

Verification command:
vault read auth/approle/role/awx-role

11. Generate Role ID and Secret ID for AWX
------------------------------------------------------
vault read auth/approle/role/awx-role/role-id
vault write -f auth/approle/role/awx-role/secret-id

# Note: Only run `vault write -f` once per Secret ID you plan to use.
# Secret IDs cannot be read back later; if rotated, update AWX's Vault-LDAP-Lookup credential.

12. Validate AppRole authentication
------------------------------------------------------
vault write auth/approle/login \
  role_id="<ROLE_ID>" \
  secret_id="<SECRET_ID>"

# Confirm a token is returned under `token` / `token_policies: ["awx-ldap-read"]`.