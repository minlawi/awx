# Architecture Evolution: Problems Solved, Improvements & Limitations

This document traces how each milestone improved or expanded on the previous stage, highlighting **what was solved**, the **key improvements**, and the **current limitations** from **Task 2 through Task 17**.

> **Note:** **Task 1** (installing AWX on K3s) establishes the baseline control plane, so comparisons begin at **Task 2**.

## Quick Comparison Matrix

| Progression | Key Milestone | What We Solved | Key Improvement |
| :--- | :--- | :--- | :--- |
| **Task&nbsp;2&nbsp;(Enhances&nbsp;Task&nbsp;1)** | GitHub SSH Deploy Key + Auto-Sync | Manual playbook transfers & stale runs | Read-only repo-scoped `ed25519` key (no personal credentials) |
| **Task&nbsp;3&nbsp;(Enhances&nbsp;Task&nbsp;2)** | Live Cisco Playbook Run + Custom EE | Validating end-to-end device push & legacy SSH KEX | Custom Execution Environment fixes legacy SSH algorithm mismatches |
| **Task&nbsp;4&nbsp;(Enhances&nbsp;Task&nbsp;3)** | TARANAC (TACACS+) Direct SSH AAA | Per-device local password management | Centralized AuthN/AuthZ/Accounting with local fallback |
| **Task&nbsp;5&nbsp;(Enhances&nbsp;Task&nbsp;4)** | AWX Jobs via TACACS+ Credentials | Split human vs. automation AAA paths | Full command-level auditing of Ansible changes in TARANAC |
| **Task&nbsp;6&nbsp;(Enhances&nbsp;Task&nbsp;5)** | GitHub Webhooks + `ngrok` Tunnel | Manual AWX Job Template launches | Automated AWX job triggers directly on `git push` |
| **Task&nbsp;7&nbsp;(Enhances&nbsp;Task&nbsp;6)** | Self-Hosted Runner + Selective Actions | Rotating `ngrok` URLs & noisy full-repo triggers | Eliminated inbound exposure; LAN-only API calls via least-privilege local `github-actions-bot` token in GitHub Secrets |
| **Task&nbsp;8&nbsp;(Enhances&nbsp;Task&nbsp;7)** | Modular Git-Backed Source of Truth | Manual AWX inventory edits & hardcoded playbooks | Git-versioned configs, PR review gates, and `git revert` rollback |
| **Task&nbsp;9&nbsp;(Expands&nbsp;Task&nbsp;8)** | Juniper Junos (NETCONF) + Multi-Vendor EE | Single-vendor device coverage (Cisco IOS only) | Multi-vendor support (Cisco SSH + Juniper NETCONF) on a hardened local EE (`Pull: Never`) |
| **Task&nbsp;10&nbsp;(Enhances&nbsp;Tasks&nbsp;8&nbsp;&amp;&nbsp;9)** | Master `site.yml` + Dynamic Tag CI/CD | Manually adding new AWX templates & editing CI for every new feature | Only changed features run (lower risk of breaking other configs) from one master AWX template |
| **Task&nbsp;11&nbsp;(Enhances&nbsp;Task&nbsp;10)** | LLDAP Directory + TARANAC Sync | Managing local user accounts manually inside TARANAC | Read-only `taranac_bind` account & centralized access revocation via `netadmins` group sync |
| **Task&nbsp;12&nbsp;(Enhances&nbsp;Task&nbsp;11)** | HashiCorp Vault LDAP Rotation + AWX Lookup | Manual password rotation & updating static secrets in AWX | Automated 24h LLDAP rotation (`ldap_ansible`), zero static passwords in AWX, AppRole JIT lookup & real-time Vault audit logs |
| **Task&nbsp;13&nbsp;(Enhances&nbsp;Task&nbsp;12)** | Open Policy Agent (Conftest) CI/CD Gate | Accidental duplicate IPs or wrong `/32` masks pushed straight to routers | Pre-flight Policy-as-Code gate blocks non-compliant Git SOT changes before AWX is ever called |
| **Task&nbsp;14&nbsp;(Enhances&nbsp;Tasks&nbsp;2&nbsp;&amp;&nbsp;12)** | Vault GitHub App Plugin + Ephemeral HTTPS Sync | Static SSH Deploy Keys stored permanently in AWX & GitHub | Zero-standing GitHub credentials; 1-hour read-only `ghs_...` tokens minted on demand via isolated `awx-github-vault-approle` |
| **Task&nbsp;15&nbsp;(Enhances&nbsp;Tasks&nbsp;12&nbsp;&amp;&nbsp;14)** | 3-Node Vault Raft Cluster (`StatefulSet`) | Single-pod Vault `file` storage SPOF & no HA failover | Zero-data-loss migration (`file` → `raft`), 3-node quorum with automatic leader election & cluster-aware auto-unseal |
| **Task&nbsp;16&nbsp;(Enhances&nbsp;Task&nbsp;15)** | Vault Monitoring (Prometheus + Grafana `25314`) | Manual CLI checks to see if Vault pods are sealed or healthy | Live dashboard tracking unsealed nodes, active leader, leases, and API success rates with persistent Grafana & disk-safe Prometheus storage |
| **Task&nbsp;17&nbsp;(Enhances&nbsp;Tasks&nbsp;11,&nbsp;15&nbsp;&amp;&nbsp;16)** | Centralized LDAP Admin UI Sign-In (Vault, AWX, TARANAC & Grafana) | Separate local admin passwords & daily Vault root token usage across 4 UIs | Unified LLDAP sign-in using per-service `lldap_strict_readonly` bind accounts & dedicated admin groups, isolated from router automation & CI/CD bot |

---

## Milestone-by-Milestone Comparison

### Task 2 (Enhances Task 1): GitHub SSH Authentication & Project Auto-Sync
* **What We Solved:** Eliminated manual file transfers to the AWX VM and prevented configuration drift caused by running outdated playbooks via **Update Revision on Launch**.
* **Key Improvement:** Uses a dedicated, **read-only GitHub Deploy Key** (`ed25519`) scoped to a single repository rather than personal credentials or over-privileged tokens.
* **Current Limitations:** Playbooks are synced, but no live network devices are managed or validated yet.

### Task 3 (Enhances Task 2): Manual Playbook Execution with Local Credentials
* **What We Solved:** Proved end-to-end automation against live target Cisco IOS devices (running inside `EVE-NG` lab environment) and permanently fixed legacy SSH algorithm mismatches (`no acceptable kex algorithm`) via a custom Execution Environment.
* **Key Improvement:** Packaged required vendor collections and SSH compatibility settings into a reusable Execution Environment for repeatable playbook runs.
* **Current Limitations:** Relies on static **local router accounts**—rotating passwords requires touching every device, and shared local credentials provide zero per-user accountability.

### Task 4 (Enhances Task 3): TARANAC (TACACS+) Direct SSH Authentication
* **What We Solved:** Replaced per-device local password management by centralizing user, group, and privilege-level management in TARANAC while preserving `local` fallback on routers to prevent lockouts during AAA outages.
* **Key Improvement:** Enforces centralized **Authentication, Authorization (privilege 15 profiles), and Command Accounting** for every interactive SSH session.
* **Current Limitations:** Human logins are audited via TACACS+, but AWX still authenticates with local router credentials.

### Task 5 (Enhances Tasks 3 & 4): AWX Job Authentication via TACACS+
* **What We Solved:** Eliminated split human vs. automation AAA paths so credential updates only occur centrally rather than across individual routers.
* **Key Improvement:** Every configuration command pushed by Ansible is authenticated and logged in TARANAC's AAA accounting logs, closing the automation audit blind spot.
* **Current Limitations:** Deployments still require manual job launches in the AWX Web UI.

### Task 6 (Enhances Task 5): GitHub Webhooks with `ngrok` HTTPS Tunnel
* **What We Solved:** Eliminated manual UI clicks by automating AWX job execution directly on `git push`.
* **Key Improvement:** Established event-driven network automation triggered immediately from Git commits.
* **Current Limitations:**
  * **Public Attack Surface:** Exposes the internal AWX API (`:32000`) to the public internet through a third-party tunnel.
  * **Operational Fragility:** Free `ngrok` URLs rotate on restart, breaking webhooks; standard webhooks also fire indiscriminately on unrelated commits (e.g., docs edits).

### Task 7 (Enhances Task 6): Self-Hosted Runner & Selective GitHub Actions
* **What We Solved:** Replaced fragile tunnels with a persistent `systemd` runner on the AWX VM and used `git diff` to trigger only modified playbooks.
* **Key Improvement:** Completely removes inbound internet exposure—the runner polls GitHub over **outbound HTTPS** and calls AWX strictly over the **private LAN**, authenticating with a dedicated least-privilege local **`github-actions-bot`** (`Execute`-only on target templates, decoupled from LDAP) stored in GitHub Secrets.
* **Current Limitations:** Device inventory is still maintained manually in the AWX UI, and configuration values remain hardcoded in playbooks.

### Task 8 (Enhances Task 7): Modular Git-Backed Source of Truth (SOT)
* **What We Solved:** Eliminated manual AWX inventory edits and hardcoded playbook values by separating reusable playbooks from device data (`inventory/hosts.ini`, `group_vars/`, per-feature `host_vars/<device>/`) and syncing AWX inventory directly from Git on launch.
* **Key Improvement:** Enforces full Git change tracking, enables Pull Request approval gates before network changes merge, and allows immediate rollback via `git revert`.
* **Current Limitations:** Single-vendor device coverage (Cisco IOS only), and every new feature still requires a separate AWX Job Template and CI matrix entry.

### Task 9 (Expands Task 8): Multi-Vendor Device Coverage (Juniper Junos) & Custom EE
* **What We Solved:** Expanded device coverage beyond Cisco IOS (SSH/22) by onboarding Juniper Junos (NETCONF/830 via `juniper.device`) into the existing Task 8 Git-backed inventory structure and bundling all vendor collections into one Multi-Vendor Execution Environment.
* **Key Improvement:** Standardizes multi-vendor automation under one unified inventory layout and an immutable, pre-baked local container image (`Pull: Never`), avoiding unverified runtime downloads from external registries during production job runs.
* **Current Limitations:** Scaling to many features (NTP, Syslog, BGP, ACLs) still causes Job Template sprawl and repetitive CI workflow edits.

### Task 10 (Enhances Tasks 8 & 9): Master `site.yml` & Dynamic Tag-Based CI/CD
* **What We Solved:** Eliminated Job Template sprawl and repetitive CI edits by consolidating all deployments into a single `site.yml` dispatcher and one `Master-Network-Deploy` template, while supporting global settings (`inventory/group_vars/all/ntp.yml`). Adding future features requires zero AWX or GitHub Actions changes.
* **Key Improvement:** Limits deployment blast radius by passing exact Ansible tags (`job_tags`) only for modified files and reduces misconfiguration surface to a single controlled Job Template.
* **Current Limitations:** User accounts and group memberships are still managed locally inside TARANAC.

### Task 11 (Enhances Tasks 4, 5 & 10): LLDAP + TARANAC Directory Integration
* **What We Solved:** Replaced manual local user management in TARANAC by centralizing user identity and group lifecycle in **LLDAP** on K3s (`30389` / `31717`). Adding or removing users from `netadmins` automatically propagates to TARANAC on sync (via **Deactivate missing users** or **Remove stale users**).
* **Key Improvement:**
  * Uses a least-privilege read-only bind account (`taranac_bind` in `lldap_strict_readonly`) with zero write rights and no router access.
  * **Selective Group Sync** imports only `netadmins`, keeping LLDAP internal admin groups isolated from TARANAC.
  * Automated offboarding immediately revokes router access when an account is removed from LLDAP.
* **Current Limitations:**
  * AWX still stores a static password for its LDAP service account *(Addressed in Task 12)*.
  * Lab LDAP uses plain `ldap://` (`30389`) instead of `ldaps://` *(Future Production Hardening)*.

### Task 12 (Enhances Task 11): HashiCorp Vault Automated Credential Rotation & Runtime Lookup
* **What We Solved:** Eliminated manual password rotation and removed static passwords from AWX completely. Vault's **LDAP Secrets Engine** (`ldap/static-role/vault-ldap-secret-role`) automatically rotates the `awx` password in LLDAP every 24 hours using a router-safe `network-cli-policy` password policy, while AWX fetches the current password dynamically at job runtime. A native host Vault CLI (`VAULT_ADDR` in `/etc/profile.d/vault.sh`) and a lab auto-unseal cron job keep Vault operational across VM reboots without manual `kubectl exec` commands.
* **Key Improvement:**
  * **Zero Static Passwords in AWX:** AWX never stores the `awx` password in its database; it authenticates via a scoped **AppRole** (`awx-read-ldap` policy, restricted solely to `read` on `ldap/static-cred/vault-ldap-secret-role`) using **HashiCorp Vault Secret Lookup** (`API Version: v1`).
  * **Separation of Duties:** `vault_bind` (member of `lldap_password_manager`) is dedicated to password rotation and has no router login rights, while `awx` (member of `netadmins`) handles router automation and has no directory admin rights.
  * **End-to-End Auditability:** Real-time Vault audit logging (`file_path=stdout`) records every `auth/approle/login`, `ldap/static-cred/vault-ldap-secret-role` read, and `ldap/rotate-role/vault-ldap-secret-role` rotation, correlating directly with TARANAC's AAA command accounting logs.
* **Current Limitations (Future Production Hardening):**
  * **Transport Security:** Lab Vault (`http://:30820`) and LLDAP (`ldap://:30389`) run over plaintext on the private LAN; production environments should enforce TLS (`https://` and `ldaps://`) with trusted CA certificates.
  * **Auto-Unseal Mechanism:** Storing the unseal key in a root-only host file (`/root/.vault-unseal-key`) for cron auto-unseal is a lab-only convenience; production clusters should use Cloud KMS or Vault Transit Auto-Unseal.

### Task 13 (Enhances Tasks 7, 8 & 10): Open Policy Agent (Conftest) Policy-as-Code CI/CD Gate
* **What We Solved:** Prevented human copy-paste mistakes in the Git Source of Truth—such as assigning an existing router's loopback IP to a newly onboarded device or configuring a non-`/32` mask on Router-ID interfaces (`Lo0` / `Loopback0`)—from being automatically pushed to live Cisco and Juniper routers.
* **Key Improvement:**
  * **Shift-Left Guardrail:** Evaluates `policies/loopback.rego` across `inventory/hosts.ini`, `host_vars/`, and `group_vars/` on the self-hosted runner **before** calling the AWX REST API (`POST /launch/`). Any policy violation fails the GitHub Actions run and aborts deployment with zero router impact.
  * **Version-Controlled Policy-as-Code:** Validation rules live alongside network data in Git with full commit history and consistent enforcement across Cisco (`255.255.255.255`) and Juniper (`/32`) syntax.
* **Current Limitations (Future Production Hardening):**
  * **Policy Tampering Protection:** Keeping `policies/` inside the same repository allows an engineer with direct push access to edit the policy alongside inventory changes; production pipelines protect `policies/` with GitHub `CODEOWNERS` / branch protection or pull policies from a separate read-only security repository.
  * **UI Bypass Coverage:** Manual Job Template launches directly inside the AWX Web UI skip the GitHub Actions gate; runtime policy validation (e.g., querying an OPA service inside K3s during `site.yml`) can close this gap.
  * **Outage Resilience:** Break-glass fallback workflows for Vault, TARANAC, and LLDAP outages remain to be built in **Task 18**.

### Task 14 (Enhances Tasks 2 & 12): Ephemeral GitHub App Tokens via HashiCorp Vault
* **What We Solved:** Eliminated static GitHub SSH Deploy Keys (`ed25519`) from both AWX and GitHub so engineers no longer manage or manually rotate standing repository keys. Every AWX Project Sync and Inventory Sync dynamically pulls the latest commits over HTTPS (`https://github.com/minlawi/awx.git`) using a freshly minted token.
* **Key Improvement:**
  * **Zero-Standing Source Control Credentials:** Unlike LDAP password rotation, `github/token/awx-github-app` stores no standing token in Vault or AWX. Vault signs a short-lived JWT with the GitHub App's `.pem` private key (`AppID: xxxxxxx`) and requests a brand-new, **1-hour read-only installation token (`ghs_...`)** scoped strictly to `minlawi/awx` (`InstallationID: yyyyyyyyy`), which AWX injects in memory via `GIT_ASKPASS` and discards immediately.
  * **Blast-Radius Isolation:** Source Control authentication (`awx-github-vault-approle` → `awx-read-github`) is strictly isolated from Network AAA authentication (`awx-ldap-vault-approle` → `awx-read-ldap`), ensuring a compromised lookup credential in one domain cannot access secrets in the other.
* **Current Limitations (Future Production Hardening):**
  * **Master Signing Key Rotation:** While `ghs_...` tokens expire after 1 hour, the GitHub App `.pem` private key stored in Vault (`github/config`) remains static and should be rotated periodically (e.g., every 90 days) in production.
  * **Outage Resilience:** Break-glass fallback workflows for Vault, TARANAC, and LLDAP outages remain to be built in **Task 18**.

### Task 15 (Enhances Tasks 12 & 14): 3-Node HashiCorp Vault Raft Cluster (`StatefulSet`)
* **What We Solved:** Eliminated the single-pod Vault `file` storage limitation (`HA Enabled: false`) by migrating Vault to a **3-node High-Availability Raft `StatefulSet`** (`vault-0`, `vault-1`, `vault-2`) via `vault operator migrate` with zero data loss—preserving all existing `ldap/` and `github/` secrets engines, AppRoles, policies, the GitHub plugin (`v2.3.2`), and the `:30820` NodePort Service.
* **Key Improvement:**

  | Feature | `file` Storage (Tasks 12–14) | `raft` Integrated Storage (Task 15) |
  | :--- | :--- | :--- |
  | **Kubernetes Workload** | Single-replica `Deployment` | 3-replica `StatefulSet` + headless Service (`vault-internal`) |
  | **High Availability (HA)** | Not supported (`HA Enabled: false`) | Native HA (`HA Enabled: true`, 1 Leader + 2 Standby Voters) |
  | **Data Replication** | None (single local PVC) | Automatic Raft consensus replication across 3 per-pod PVCs |
  | **Pod Failover** | Downtime until single pod restarts | Automatic leader election; tolerates 1 pod failure without outage |
  | **Backups** | Manual offline filesystem tarball | Built-in online snapshots (`vault operator raft snapshot save`) |

  * **Cluster-Aware Auto-Unseal:** Upgraded `/usr/local/bin/vault-autounseal.sh` with `flock` locking to inspect and unseal all pods in order (`vault-0` first for leader election, then followers) after restarts or pod deletions.
* **Current Limitations (Future Production Hardening):**
  * **Single Underlying Host:** Because all Raft pods run on the same single-node K3s VM, pod-level failover works cleanly, but a host VM failure still takes down all replicas; production clusters spread Raft peers across separate nodes/availability zones.
  * **Auto-Unseal & Transport:** Still relies on the host-level Shamir cron script and plaintext HTTP (`:30820`) on the lab LAN; production clusters should use Cloud KMS/Transit Auto-Unseal and end-to-end TLS.
  * **Outage Resilience:** Break-glass fallback workflows for Vault, TARANAC, and LLDAP outages remain to be built in **Task 18**.

### Task 16 (Enhances Task 15): Vault Monitoring with Prometheus & Grafana
* **What We Solved:** Removed the need to run manual CLI checks (`vault status`, `vault operator raft list-peers`) to know if Vault pods are sealed, down, or failing API requests.
* **Key Improvement:**
  * **Full-Cluster Visibility:** Deployed `kube-prometheus-stack` on K3s and used a `ServiceMonitor` (`vault-raft-metrics`) against `svc/vault-internal` so Prometheus scrapes every Raft pod individually—whether it is the active leader, a standby follower, or sealed—with `prometheus_retention_time = "24h"` preserving sealed-node metrics.
  * **Ready-to-Use Dashboard & Persistent Storage:** Imported Grafana Dashboard ID **`25314`** (`Vault / Overview`) to track unsealed nodes, total nodes, scrape health, active leases, and API response rates (`2xx` / `4xx` / `5xx`) in real time, backed by a `1Gi` `local-path` PVC so dashboards persist across pod restarts and Helm upgrades.
  * **Disk-Safe Storage:** Configured Prometheus with `5d` retention, a `2GB` size cap, and a `3Gi` PVC so monitoring data never fills up the K3s host disk.
* **Current Limitations (Future Production Hardening):**
  * **Service Coverage:** Monitoring currently covers HashiCorp Vault and K3s; AWX (`/api/v2/metrics/`), TARANAC, and LLDAP probes (`blackbox_exporter`) will be added next.
  * **Alerting & Auth:** Alertmanager notification routing (Slack/Telegram/Email) is not configured yet, and Vault metrics use `unauthenticated_metrics_access = true` over plain HTTP on the lab network instead of a scoped Prometheus token over HTTPS.

### Task 17 (Enhances Tasks 11, 15 & 16): Centralized LDAP Sign-In for Admin UIs (Vault, AWX, TARANAC & Grafana)
* **What We Solved:** Eliminated daily reliance on separate local `admin` passwords and the Vault root token by connecting all four management interfaces (**Vault**, **AWX**, **TARANAC**, and **Grafana**) to **LLDAP** for unified human administrator sign-in.
* **Key Improvement:**
  * **Least-Privilege Bind Isolation:** Each platform uses a dedicated read-only bind account in `lldap_strict_readonly` (`vault_auth_bind`, `awx_auth_bind`, `grafana_auth_bind`, and existing `taranac_bind`)—strictly separated from `vault_bind` (`lldap_password_manager`) so login configs never hold password-reset rights.
  * **Role-Based Admin Group Isolation:** Dedicated LLDAP admin groups (`vault_admin_groups`, `awx_admins`, `taranac_admins`, `grafana_admins`) grant administrative roles (including AWX `NetworkAutomation` org membership + `is_superuser`, TARANAC `Admin group`, and Grafana Server Admin) while keeping router automation accounts (`netadmins`) locked out of management UIs.
  * **Resilient CI/CD Decoupling:** Automated GitHub Actions API calls remain bound to the local least-privilege `github-actions-bot` (`Execute`-only) rather than an LDAP user, preventing directory outages or personal account changes from breaking deployments.
* **Current Limitations (Future Production Hardening):**
  * **Transport Security:** Admin UI LDAP binds run over plain `ldap://` (`30389` / `3890`) on the lab LAN/cluster network; production setups should enforce `ldaps://` or StartTLS.
  * **Outage Resilience:** Break-glass fallback workflows for Vault, TARANAC, and LLDAP outages remain to be built in **Task 18**.

---

> [← Back to Project Overview](./README.md)