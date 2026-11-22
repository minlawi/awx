# Multi-Vendor Network Automation CI/CD Pipeline (AWX, GitOps & TACACS+)

This project automates network configuration updates for Cisco IOS and Juniper Junos devices. It uses a Git repository as the single source of truth—whenever changes are pushed, a local GitHub Actions runner checks what was modified over the LAN and triggers only the specific Ansible AWX Job Template needed for that playbook or feature variable file. This approach stops manual configuration drift and avoids running unnecessary playbooks, all while keeping deployments secure with centralized TACACS+ authentication and custom Execution Environments.

> **Note:** This project is built from scratch for learning purposes to explore how each tool and workflow step fits together, and is not intended for direct production use. Hopefully, it gives you a clear starting point for your own lab!

## Prerequisites

| Category | Component | Requirement / Details |
| :--- | :--- | :--- |
| **Control Node & AWX** | Linux VM & Kubernetes | **Ubuntu Server** VM running **K3s** with **Ansible AWX** deployed as containers, plus a local **GitHub Self-Hosted Runner** for LAN triggering |
| **Version Control & CI/CD** | GitHub Private Repo | **SSH key-based authentication** configured between the private GitHub repository (Single Source of Truth) and the AWX server |
| **Network Lab & Devices** | EVE-NG & Target Routers | **EVE-NG** hosting virtual **Cisco IOS** (management via **SSH**) and **Juniper Junos** (management via **NETCONF**) routers with L3 reachability to AWX |
| **Authentication (AAA)** | TACACS+ Server | **TARANAC** (formerly known as **tacacsgui**) deployed and reachable by all target network devices for centralized AAA authentication |

## Project Milestones & Progress

1. [Installed AWX (open-source Ansible Tower) on K3s](./SETUP.md#1-install-ansible-awx-on-k3s) – **Completed**
2. [Set up SSH key-based authentication between AWX and the private GitHub repository](./SETUP.md#2-github-ssh-authentication--awx-project-sync) – **Completed**
3. [Ran a playbook in Ansible AWX using target device local username and password authentication](./SETUP.md#3-target-device-credentials-local--tacacs) – **Completed**
4. [Verified direct SSH login authentication against the TARANAC (TACACS+) server without AWX](./SETUP.md#3-target-device-credentials-local--tacacs) – **Completed**
5. [Verified AWX Job Template authentication against the target Cisco router via the TACACS+ server](./SETUP.md#3-target-device-credentials-local--tacacs) – **Completed**
6. [Configured AWX project auto-sync on job launch to pull the latest code pushed to GitHub](./SETUP.md#2-github-ssh-authentication--awx-project-sync) – **Completed**
7. [Configured GitHub Webhooks with an ngrok HTTPS tunnel to automatically trigger AWX Job Templates on code push](./SETUP.md#4-cicd-evolution-webhooks-to-local-self-hosted-runner) – **Completed**
8. [Configured GitHub Actions (CI/CD) to selectively trigger AWX Job Templates only when their specific playbook changes](./SETUP.md#4-cicd-evolution-webhooks-to-local-self-hosted-runner) – **Completed**
9. [Deployed a local GitHub self-hosted runner on the AWX VM to trigger AWX directly over LAN without ngrok](./SETUP.md#4-cicd-evolution-webhooks-to-local-self-hosted-runner) – **Completed**
10. [Migrated inventories and device configurations to a modular Git-backed Source of Truth (`hosts.ini`, `group_vars`, `host_vars`) with dynamic variable-driven playbooks and inventory-aware GitHub Actions triggers](./SETUP.md#5-modular-source-of-truth--feature-level-triggers) – **Completed**
11. [Tested Juniper devices using the `juniper.device` collection and resolved legacy Cisco IOS SSH algorithm issues by baking a custom Execution Environment, eliminating the need for playbook `pre_tasks`](./SETUP.md#6-custom-execution-environment--multi-vendor-support) – **Completed**
12. [Split `host_vars` into per-feature YAML files (`hostname.yml`, `loopback_interfaces.yml`) so GitHub Actions triggers only the matching AWX playbook based on the specific variable changed in the Source of Truth, and standardized Juniper `lo0` logical unit loopback configurations](./SETUP.md#5-modular-source-of-truth--feature-level-triggers) – **Completed**