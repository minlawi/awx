# Architecture Evolution: Day 2 Pain Points & Security Comparison

This document traces how each milestone enhanced the previous stage, highlighting the **Day 2 operational pain points** solved and the **security concerns** addressed (or remaining) from **Task 2 through Task 12**.

> **Note:** **Task 1** (installing AWX on K3s) establishes the baseline control plane, so comparisons begin at **Task 2**.

## Quick Comparison Matrix

| Progression | Key Enhancement | Day 2 Pain Point Solved | Security Impact |
| :--- | :--- | :--- | :--- |
| **Task&nbsp;2&nbsp;→&nbsp;Task&nbsp;1** | GitHub SSH Deploy Key + Auto-Sync | Manual playbook transfers & stale runs | Read-only repo-scoped `ed25519` key (no personal credentials) |
| **Task&nbsp;3&nbsp;→&nbsp;Task&nbsp;2** | Live Cisco Playbook Run + Custom EE | Validated end-to-end device push & legacy SSH KEX | Exposed local credential sprawl & lack of audit trail |
| **Task&nbsp;4&nbsp;→&nbsp;Task&nbsp;3** | TARANAC (TACACS+) Direct SSH AAA | Per-device local password management | Centralized AuthN/AuthZ/Accounting with local fallback |
| **Task&nbsp;5&nbsp;→&nbsp;Task&nbsp;4** | AWX Jobs via TACACS+ Credentials | Split human vs. automation AAA paths | Full command-level auditing of Ansible changes in TARANAC |
| **Task&nbsp;6&nbsp;→&nbsp;Task&nbsp;5** | GitHub Webhooks + `ngrok` Tunnel | Manual AWX Job Template launches | Introduced public internet exposure to private AWX control plane |
| **Task&nbsp;7&nbsp;→&nbsp;Task&nbsp;6** | Self-Hosted Runner + Selective Actions | Rotating `ngrok` URLs & noisy full-repo triggers | Eliminated inbound exposure; LAN-only API calls via GitHub Secrets |
| **Task&nbsp;8&nbsp;→&nbsp;Task&nbsp;7** | Modular Git-Backed Source of Truth | Manual AWX inventory edits & hardcoded playbooks | Git-versioned configs, PR review gates, and `git revert` rollback |
| **Task&nbsp;9&nbsp;→&nbsp;Task&nbsp;8** | Juniper Junos (NETCONF) + Multi-Vendor EE | Vendor-specific toolchains & legacy collections | Hardened local container (`Pull: Never`), eliminating runtime pulls |
| **Task&nbsp;10&nbsp;→&nbsp;Task&nbsp;9** | Master `site.yml` + Dynamic Tag CI/CD | Manually adding new AWX templates & editing CI for every new feature | Only changed features run (lower risk of breaking other configs) from one master AWX template |
| **Task&nbsp;11&nbsp;→&nbsp;Task&nbsp;10** | LLDAP Directory + TARANAC Sync | Managing local user accounts manually inside TARANAC | Read-only `taranac_bind` account & centralized access revocation via `netadmins` group sync |
| **Task&nbsp;12&nbsp;→&nbsp;Task&nbsp;11** | HashiCorp Vault LDAP Rotation + AWX Lookup | Manual password rotation & updating static secrets in AWX | Automated 24h LLDAP rotation (`ldap_ansible`), zero static passwords in AWX, AppRole JIT lookup & real-time Vault audit logs |

---

## Milestone-by-Milestone Comparison

### Task 2 (Enhances Task 1): GitHub SSH Authentication & Project Auto-Sync
* **Day 2 Pain Point Solved:** Eliminates manual file transfers to the AWX VM and prevents configuration drift caused by running outdated playbooks via **Update Revision on Launch**.
* **Security Improvement:** Uses a dedicated, **read-only GitHub Deploy Key** (`ed25519`) scoped to a single repository rather than personal credentials or over-privileged tokens.
* **Remaining Gap:** Playbooks are synced, but no live network devices are managed or validated yet.

### Task 3 (Enhances Task 2): Manual Playbook Execution with Local Credentials
* **Day 2 Pain Point Solved:** Proves end-to-end automation against live target Cisco IOS devices (running inside `EVE-NG` lab environment) and permanently fixes legacy SSH algorithm mismatches (`no acceptable kex algorithm`) via a custom Execution Environment.
* **Security Concern (Day 2 Risk):** Relies on static **local router accounts**. Rotating passwords requires touching every device, and shared local credentials provide zero per-user accountability.

### Task 4 (Enhances Task 3): TARANAC (TACACS+) Direct SSH Authentication
* **Day 2 Pain Point Solved:** Centralizes user, group, and privilege-level management in TARANAC while preserving `local` fallback on routers to prevent lockouts during AAA outages.
* **Security Improvement:** Enforces centralized **Authentication, Authorization (privilege 15 profiles), and Command Accounting** for every interactive SSH session.
* **Remaining Gap:** Human logins are audited via TACACS+, but AWX still authenticates with local router credentials.

### Task 5 (Enhances Tasks 3 & 4): AWX Job Authentication via TACACS+
* **Day 2 Pain Point Solved:** Unifies human and automation AAA workflows so credential updates only occur centrally rather than across individual routers.
* **Security Improvement:** Every configuration command pushed by Ansible is authenticated and logged in TARANAC's AAA accounting logs, closing the automation audit blind spot.
* **Remaining Gap:** Deployments still require manual job launches in the AWX Web UI.

### Task 6 (Enhances Task 5): GitHub Webhooks with `ngrok` HTTPS Tunnel
* **Day 2 Pain Point Solved:** Automates AWX job execution directly on `git push`, removing manual UI clicks.
* **Day 2 & Security Concerns:**
  * **Public Attack Surface:** Exposes the internal AWX API (`:32000`) to the public internet through a third-party tunnel.
  * **Operational Fragility:** Free `ngrok` URLs rotate on restart, breaking webhooks; standard webhooks also fire indiscriminately on unrelated commits (e.g., docs edits).

### Task 7 (Enhances Task 6): Self-Hosted Runner & Selective GitHub Actions
* **Day 2 Pain Point Solved:** Replaces fragile tunnels with a persistent `systemd` runner on the AWX VM and uses `git diff` to trigger only modified playbooks.
* **Security Improvement:** Completely removes inbound internet exposure—the runner polls GitHub over **outbound HTTPS** and calls AWX strictly over the **private LAN**, with API tokens protected in GitHub Secrets.
* **Remaining Gap:** Device inventory is still maintained manually in the AWX UI, and configuration values remain hardcoded in playbooks.

### Task 8 (Enhances Task 7): Modular Git-Backed Source of Truth (SOT)
* **Day 2 Pain Point Solved:** Decouples reusable playbooks from device data (`inventory/hosts.ini`, `group_vars/`, per-feature `host_vars/<device>/`) and syncs AWX inventory directly from Git on launch.
* **Security Improvement:** Enforces full Git change tracking, enables Pull Request approval gates before network changes merge, and allows immediate rollback via `git revert`.
* **Remaining Gap:** Single-vendor (Cisco IOS only), and every new feature still requires a separate AWX Job Template and CI matrix entry.

### Task 9 (Enhances Task 8): Multi-Vendor Support (Juniper Junos) & Custom EE
* **Day 2 Pain Point Solved:** Standardizes Cisco IOS (SSH/22) and Juniper Junos (NETCONF/830 via `juniper.device`) under one inventory structure and one unified Multi-Vendor Execution Environment.
* **Security Improvement:** Uses an immutable, pre-baked local container image (`Pull: Never`), avoiding unverified runtime downloads from external registries during production job runs.
* **Remaining Gap:** Scaling to many features (NTP, Syslog, BGP, ACLs) still causes Job Template sprawl and repetitive CI workflow edits.

### Task 10 (Enhances Tasks 8 & 9): Master `site.yml` & Dynamic Tag-Based CI/CD
* **Day 2 Pain Point Solved:** Consolidates all deployments into a single `site.yml` dispatcher and one `Master-Network-Deploy` template, while supporting global settings (`inventory/group_vars/all/ntp.yml`). Adding future features requires zero AWX or GitHub Actions changes.
* **Security Improvement:** Limits deployment blast radius by passing exact Ansible tags (`job_tags`) only for modified files and reduces misconfiguration surface to a single controlled Job Template.
* **Remaining Gap:** User accounts and group memberships are still managed locally inside TARANAC.

### Task 11 (Enhances Tasks 4, 5 & 10): LLDAP + TARANAC Directory Integration
* **Day 2 Pain Point Solved:** Centralizes user identity and group lifecycle in **LLDAP** on K3s (`30389` / `31717`). Adding or removing users from `netadmins` automatically propagates to TARANAC on sync (via **Deactivate missing users** or **Remove stale users**).
* **Security Improvement:**
  * Uses a least-privilege read-only bind account (`taranac_bind` in `lldap_strict_readonly`) with zero write rights and no router access.
  * **Selective Group Sync** imports only `netadmins`, keeping LLDAP internal admin groups isolated from TARANAC.
  * Automated offboarding immediately revokes router access when an account is removed from LLDAP.
* **Remaining Gaps:**
  * AWX still stores a static password for its LDAP service account *(Addressed in Task 12)*.
  * Lab LDAP uses plain `ldap://` (`30389`) instead of `ldaps://` *(Future Production Hardening)*.

### Task 12 (Enhances Task 11): HashiCorp Vault Automated Credential Rotation & Runtime Lookup
* **Day 2 Pain Point Solved:** Eliminates manual password rotation and removes static passwords from AWX completely. Vault's **LDAP Secrets Engine** (`ldap/static-role/ldap-ansible-role`) automatically rotates the `ldap_ansible` password in LLDAP every 24 hours using a router-safe `network-cli` password policy, while AWX fetches the current password dynamically at job runtime. A native host Vault CLI (`VAULT_ADDR` in `/etc/profile.d/vault.sh`) and a lab auto-unseal cron job keep Vault operational across VM reboots without manual `kubectl exec` commands.
* **Security Improvement:**
  * **Zero Static Passwords in AWX:** AWX never stores the `ldap_ansible` password in its database; it authenticates via a scoped **AppRole** (`awx-ldap-read` policy, restricted solely to `read` on `ldap/static-cred/ldap-ansible-role`) using **HashiCorp Vault Secret Lookup** (`API Version: v1`).
  * **Separation of Duties:** `vault_bind` (member of `lldap_password_manager`) is dedicated to password rotation and has no router login rights, while `ldap_ansible` (member of `netadmins`) handles router automation and has no directory admin rights.
  * **End-to-End Auditability:** Real-time Vault audit logging (`file_path=stdout`) records every `auth/approle/login`, `ldap/static-cred/ldap-ansible-role` read, and `ldap/rotate-role/ldap-ansible-role` rotation, correlating directly with TARANAC's AAA command accounting logs.
* **Remaining Gaps (Future Production Hardening):**
  * **Transport Security:** Lab Vault (`http://:30820`) and LLDAP (`ldap://:30389`) run over plaintext on the private LAN; production environments should enforce TLS (`https://` and `ldaps://`) with trusted CA certificates.
  * **Auto-Unseal Mechanism:** Storing the unseal key in a root-only host file (`/root/.vault-unseal-key`) for cron auto-unseal is a lab-only convenience; production clusters should use Cloud KMS or Vault Transit Auto-Unseal.

---

> [← Back to Project Overview](./README.md)