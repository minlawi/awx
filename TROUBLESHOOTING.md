# Troubleshooting & Lessons Learned

> [← Back to Project Overview](./README.md) | [Setup Guide](./SETUP.md)

A log of real errors encountered while building this multi-vendor AWX + GitOps + TACACS+ pipeline from scratch, why each issue occurred, and how it was resolved.

---

## Quick Index

| # | Component | Error / Symptom | Root Cause |
| :--- | :--- | :--- | :--- |
| 1 | Cisco IOS / AWX EE | `Incompatible ssh peer (no acceptable kex algorithm)` | Default AWX EE lacks `ansible-pylibssh` and falls back to `paramiko`, which rejects legacy Cisco IOS SSH KEX algorithms |

---

## 1. Legacy Cisco IOS SSH Key Exchange Failure (`no acceptable kex algorithm`)

### Error Output
![Cisco IOS SSH KEX Error](./assests/ansible-pyblissh.png)

### Root Cause
By default, Ansible AWX's built-in Execution Environment (`awx-ee`) does not include the `ansible-pylibssh` package. Without it, Ansible automatically falls back to `paramiko` for SSH connections, which rejects the legacy SSH key exchange (`kex`) algorithms and ciphers used by older Cisco IOS images running in EVE-NG.

---

### Solution: Bake a Custom Cisco Execution Environment with Podman

To fix this cleanly at the container level—without hardcoding `pre_tasks` or SSH flags in every playbook—build a custom Execution Environment with `ansible-pylibssh`, the `cisco.ios` collection, and legacy SSH algorithm support baked in.

#### 1. Install Podman
```bash
sudo apt update && sudo apt install -y podman
```
*Verification:* Run `podman --version` to confirm Podman is installed.

#### 2. Create the `Dockerfile` and Build the Custom Image
Create a build directory, generate the `Dockerfile` with `ansible-pylibssh` and container-level legacy SSH settings, and build the image:

```bash
mkdir -p ~/custom-ee && cd ~/custom-ee

cat << 'EOF' > Dockerfile
FROM quay.io/ansible/awx-ee:latest

USER root

# 1. Install ansible-pylibssh for Cisco IOS SSH support
RUN pip3 install --no-cache-dir ansible-pylibssh

# 2. Ensure UID 1000 has a valid home directory so libssh reads ~/.ssh/config
RUN grep -q ":1000:" /etc/passwd || echo "runner:x:1000:0:runner:/home/runner:/bin/bash" >> /etc/passwd && \
    mkdir -p /home/runner/.ssh && \
    printf "Host *\n    KexAlgorithms +diffie-hellman-group1-sha1,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1\n    HostKeyAlgorithms +ssh-rsa\n    PubkeyAcceptedAlgorithms +ssh-rsa\n    Ciphers +aes128-cbc,3des-cbc,aes192-cbc,aes256-cbc\n    StrictHostKeyChecking no\n    UserKnownHostsFile /dev/null\n" | tee /etc/ssh/ssh_config.d/99-legacy-cisco.conf /home/runner/.ssh/config && \
    chown -R 1000:0 /home/runner && \
    chmod 700 /home/runner/.ssh && \
    chmod 600 /home/runner/.ssh/config

# 3. Pre-install Cisco IOS collection globally
RUN ansible-galaxy collection install cisco.ios ansible.netcommon -p /usr/share/ansible/collections

# 4. Bake SSH environment variables globally into the container
ENV HOME=/home/runner \
    ANSIBLE_SSH_ARGS="-o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"

USER 1000
EOF

sudo podman build -t localhost/awx-ee-cisco:latest .
```
*Verification:* Confirm `ansible-pylibssh` and the SSH algorithm config are baked into the image:
```bash
sudo podman run --rm localhost/awx-ee-cisco:latest pip show ansible-pylibssh
sudo podman run --rm localhost/awx-ee-cisco:latest cat /home/runner/.ssh/config
```

#### 3. Import the Image into K3s and Clean Up Podman Storage
Import the image directly into K3s's local containerd registry, then remove the temporary Podman images to free up disk space:

```bash
# Import the custom image into K3s
sudo podman save localhost/awx-ee-cisco:latest | sudo k3s ctr images import -

# Clean up local Podman build images
sudo podman rmi -f localhost/awx-ee-cisco:latest
sudo podman image prune -f
```
*Verification:* Confirm the image is registered in K3s and Podman storage is clean:
```bash
sudo k3s crictl images | grep awx-ee-cisco
sudo podman images
```
*(Expected output: `localhost/awx-ee-cisco` with tag `latest` appears in `crictl images`, and `podman images` shows no leftover images.)*

#### 4. Assign the Custom EE in AWX
1. Open the **AWX Web UI** (`http://<your-server-ip>:32000`) and go to **Administration** → **Execution Environments** → **Add**.
2. Configure the Execution Environment:
   * **Name:** `Custom Cisco EE`
   * **Image:** `localhost/awx-ee-cisco:latest`
   * **Pull:** `Never` *(instructs K3s to use the locally imported image rather than pulling from a remote registry)*
3. Click **Save**.
4. Open your Cisco **Job Template** (e.g., `set_hostname`), select `Custom Cisco EE` under **Execution Environment**, and click **Save**.

*Verification:* Re-run the Job Template—the `ansible-pylibssh` fallback warning disappears and the task completes cleanly against the legacy Cisco IOS router without requiring playbook `pre_tasks`.