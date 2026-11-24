# Multi-Vendor Network Automation CI/CD Pipeline (AWX, GitOps, TACACS+ & Vault)

This project automates network configuration updates for Cisco IOS and Juniper Junos devices. It uses a Git repository as the single source of truth—whenever changes are pushed, a local GitHub Actions runner detects modified playbooks or feature variable files over the LAN, extracts the corresponding Ansible tags, and triggers a single master Ansible AWX Job Template (`site.yml`) so only the changed features run. This approach stops manual configuration drift, scales cleanly without manual CI/CD or AWX template updates, and keeps deployments secure with centralized LLDAP + TACACS+ authentication, automated 24-hour credential rotation via HashiCorp Vault, and custom Execution Environments.

> **Note:** This project is built from scratch for learning purposes to explore how each tool and workflow step fits together, and is not intended for direct production use. Hopefully, it gives you a clear starting point for your own lab!

## Prerequisites

| Category | Component | Requirement / Details |
| :--- | :--- | :--- |
| **Control Node & AWX** | Linux VM & Kubernetes | **Ubuntu Server** VM running **K3s** with **Ansible AWX**, **LLDAP**, and **HashiCorp Vault** deployed as containers, plus a local **GitHub Self-Hosted Runner** for LAN triggering |
| **Version Control & CI/CD** | GitHub Private Repo | **SSH key-based authentication** configured between the private GitHub repository (Single Source of Truth) and the AWX server |
| **Network Lab & Devices** | EVE-NG & Target Routers | **EVE-NG** hosting virtual **Cisco IOS** (management via **SSH**) and **Juniper Junos** (management via **NETCONF**) routers with L3 reachability to AWX |
| **Authentication (AAA)** | TARANAC & LLDAP | **TARANAC** (formerly known as **tacacsgui**) integrated with **LLDAP** over LDAP for centralized directory-backed TACACS+ authentication |
| **Secrets Management** | HashiCorp Vault | **HashiCorp Vault** on K3s using the LDAP Secrets Engine for automated 24-hour password rotation in LLDAP and AppRole-based runtime lookup from AWX |

## Architecture Topology
![Multi-Vendor Network Automation Topology](./ERROR/architecture.png)

## Project Notes
[![View Notes on Excalidraw](https://img.shields.io/badge/Project_Notes-Excalidraw-6965DB?style=for-the-badge&logo=excalidraw&logoColor=white)](https://app.excalidraw.com/s/1GkvF5YK7dJ/8NU2mcP2T52)

## Project Milestones & Progress

1. [Installed AWX (open-source Ansible Tower) on K3s](./SETUP.md#1-install-ansible-awx-on-k3s) – **Completed**
2. [Set up SSH key-based authentication between AWX and the private GitHub repository with project auto-sync on job launch](./SETUP.md#2-github-ssh-authentication--awx-project-auto-sync) – **Completed**
3. [Ran a playbook manually in Ansible AWX using target device local username and password authentication](./SETUP.md#3-run-playbook-manually-using-target-device-local-credentials) – **Completed**
4. [Verified direct SSH login authentication against the TARANAC (TACACS+) server without AWX](./SETUP.md#4-configure-taranac-tacacs-and-verify-direct-ssh-authentication) – **Completed**
5. [Verified AWX Job Template authentication against the target Cisco router via the TACACS+ server](./SETUP.md#5-verify-awx-job-template-authentication-via-tacacs) – **Completed**
6. [Configured GitHub Webhooks with an ngrok HTTPS tunnel to automatically trigger AWX Job Templates on code push](./SETUP.md#6-configure-github-webhooks-with-ngrok-https-tunnel) – **Completed**
7. [Deployed a local GitHub self-hosted runner on the AWX VM and configured GitHub Actions (CI/CD) to selectively trigger AWX Job Templates over LAN without ngrok](./SETUP.md#7-deploy-github-self-hosted-runner-and-configure-selective-github-actions-cicd) – **Completed**
8. [Migrated inventories and device configurations to a modular Git-backed Source of Truth (`hosts.ini`, `group_vars`, and per-feature `host_vars` YAML files) with variable-driven playbooks and feature-level GitHub Actions triggers](./SETUP.md#8-migrate-to-modular-git-backed-source-of-truth) – **Completed**
9. [Tested Juniper devices using the juniper.device collection and resolved legacy Cisco IOS SSH algorithm issues by baking a custom Execution Environment](./SETUP.md#9-multi-vendor-support-juniper-junos-and-custom-execution-environment) – **Completed**
10. [Refactored playbooks into `playbooks/` with a root `site.yml` master dispatcher and dynamic tag-based GitHub Actions triggering for a single master AWX Job Template](./SETUP.md#10-refactor-to-master-siteyml-and-dynamic-tag-based-cicd) – **Completed**
11. [Deployed LLDAP on K3s and integrated it with TARANAC for centralized directory-backed AAA authentication](./SETUP.md#11-integrate-lldap-with-taranac-for-directory-backed-aaa) – **Completed**
12. [Implemented automated 24-hour LLDAP credential rotation and AWX runtime secret lookup with HashiCorp Vault](./SETUP.md#12-automated-credential-rotation-and-runtime-lookup-with-hashicorp-vault) – **Completed**