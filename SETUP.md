# Setup & Implementation Guide

## 1. Install Ansible AWX on K3s

### 1.1 Update the System
```bash
sudo apt update && sudo apt upgrade -y
```

### 1.2 Install K3s
```bash
curl -sfL [https://get.k3s.io](https://get.k3s.io) | sh -
```

### 1.3 Grant Non-Root User Access to K3s Config
```bash
sudo chown $USER:$USER /etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
source ~/.bashrc
```

### 1.4 Verify the Kubernetes Cluster
```bash
kubectl version
kubectl get nodes
kubectl get pods -A
```

### 1.5 Install Kustomize
```bash
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin
```

### 1.6 Create the Deployment Directory
```bash
mkdir -p ~/awx-deploy && cd ~/awx-deploy
```

### 1.7 Create `kustomization.yaml`
Create `kustomization.yaml` to deploy the AWX Operator (`2.19.1`):

```bash
cat << 'EOF' > kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: awx

resources:
  - github.com/ansible/awx-operator/config/default?ref=2.19.1

images:
  - name: quay.io/ansible/awx-operator
    newTag: 2.19.1
  - name: gcr.io/kubebuilder/kube-rbac-proxy
    newName: quay.io/brancz/kube-rbac-proxy
    newTag: v0.15.0
EOF
```

### 1.8 Deploy the AWX Operator
```bash
kubectl apply -k .
```

### 1.9 Verify the Operator Pod is Running
```bash
kubectl get pods -n awx
```
*(Wait until `awx-operator-controller-manager` shows `2/2 Running` before proceeding.)*

### 1.10 Create the AWX Instance (`awx-demo.yaml`)
```bash
cat << 'EOF' > awx-demo.yaml
---
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx-demo
spec:
  service_type: nodeport
  nodeport_port: 32000
EOF
```

### 1.11 Add the AWX Instance to `kustomization.yaml`
Update `kustomization.yaml` to include `awx-demo.yaml`:

```bash
cat << 'EOF' > kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - github.com/ansible/awx-operator/config/default?ref=2.19.1
  - awx-demo.yaml

images:
  - name: quay.io/ansible/awx-operator
    newTag: 2.19.1
  - name: gcr.io/kubebuilder/kube-rbac-proxy
    newName: quay.io/brancz/kube-rbac-proxy
    newTag: v0.15.0

namespace: awx
EOF
```

### 1.12 Apply the Updated Configuration
```bash
kubectl apply -k .
```

### 1.13 Monitor AWX Pod Deployment
```bash
kubectl get pods -n awx -w
```
*(Wait until `awx-demo-postgres`, `awx-demo-task`, and `awx-demo-web` all reach `Running` status—this typically takes 3–5 minutes.)*

### 1.14 Watch Operator Deployment Logs (Optional)
```bash
kubectl logs -f deployment/awx-operator-controller-manager -c awx-manager -n awx
```

### 1.15 Retrieve the Default `admin` Password
```bash
kubectl get secret awx-demo-admin-password -n awx -o jsonpath="{.data.password}" | base64 --decode ; echo
```

### 1.16 Access the AWX Web UI
* **URL:** `http://<your-server-ip>:32000`
* **Username:** `admin`
* **Password:** *(Output from Step 15)*

> [← Back to Project Overview](./README.md)

## 2. GitHub SSH Authentication & AWX Project Auto-Sync

### 2.1 Generate an SSH Key Pair on the AWX Server
Generate a dedicated `ed25519` SSH key pair without a passphrase so AWX can pull from GitHub automatically:

```bash
ssh-keygen -t ed25519 -C "awx-github-deploy" -f ~/.ssh/awx_github_key -N ""
```

Display and copy the **public key** (`awx_github_key.pub`) and **private key** (`awx_github_key`):

```bash
# Public key (paste into GitHub)
cat ~/.ssh/awx_github_key.pub

# Private key (paste into AWX)
cat ~/.ssh/awx_github_key
```

---

### 2.2 Add the Public Key to GitHub (Deploy Key)
1. Open your private repository on **GitHub** and navigate to **Settings** → **Deploy keys** → **Add deploy key**.
2. Enter a title (e.g., `AWX Server Read-Only`).
3. Paste the contents of `~/.ssh/awx_github_key.pub` into the **Key** field.
4. Leave **Allow write access** unchecked (AWX only needs read access to pull playbooks and inventory).
5. Click **Add key**.

*(Optional)* Verify SSH connectivity from the AWX server:
```bash
ssh -i ~/.ssh/awx_github_key -T git@github.com
# Expected output: Hi <username>/<repo>! You've successfully authenticated, but GitHub does not provide shell access.
```

---

### 2.3 Create a Source Control Credential in AWX
1. Log in to the **AWX Web UI** (`http://<your-server-ip>:32000`).
2. Go to **Resources** → **Credentials** → **Add**.
3. Fill in the credential details:
   * **Name:** `GitHub SSH Key`
   * **Credential Type:** `Source Control`
   * **SCM Private Key:** Paste the full contents of `~/.ssh/awx_github_key` (including `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END OPENSSH PRIVATE KEY-----`).
4. Click **Save**.

---

### 2.4 Link the GitHub Repository as an AWX Project
1. Go to **Resources** → **Projects** → **Add**.
2. Configure the project settings:
   * **Name:** `Projet Name`
   * **Source Control Type:** `Git`
   * **Source Control URL:** `git@github.com:<your-username>/<your-private-repo>.git`
   * **Source Control Branch/Tag/Commit:** `main`
   * **Source Control Credential:** Select `GitHub SSH Key`
   * **Options:** Check **Update Revision on Launch** *(ensures AWX always pulls the latest commit from GitHub before running any Job Template)*
3. Click **Save**.

**Verification:** AWX immediately starts a Project Sync job. Confirm the **Status** changes to **Successful** (green) under **Views** → **Jobs**.

> [← Back to Project Overview](./README.md)

## 3. Run Playbook Manually Using Target Device Local Credentials

In this phase, we push a simple `set_hostname.yml` playbook to GitHub, create the matching inventory group and local credentials in AWX, and run the Job Template manually using AWX's **Default Execution Environment** to reproduce the legacy Cisco IOS SSH algorithm error before applying our custom EE fix.

### 3.1 Push `set_hostname.yml` to Your GitHub Repository
In your local Git repository, create a simple `set_hostname.yml` playbook targeting the `cisco_routers` group and push it to `main`:

```bash
cat << 'EOF' > set_hostname.yml
---
- name: Configure Cisco IOS Hostname
  hosts: cisco_routers
  gather_facts: false

  tasks:
    - name: Merged the hostname configuration on the router
      cisco.ios.ios_hostname:
        config:
          hostname: R1-AUTOMATED
        state: merged
EOF

git add set_hostname.yml
git commit -m "feat: add initial Cisco IOS set_hostname playbook"
git push origin main
```

*Verification:* Confirm `set_hostname.yml` appears in your GitHub repository under the `main` branch.

---

### 3.2 Create a Machine Credential in AWX
1. Log in to the **AWX Web UI** (`http://<your-server-ip>:32000`).
2. Navigate to **Resources** → **Credentials** → **Add**.
3. Enter the local router login details:
   * **Name:** `Cisco Local Credentials`
   * **Credential Type:** `Machine`
   * **Username:** `<router-local-username>` *(e.g., `admin`)*
   * **Password:** `<router-local-password>`
   * **Privilege Escalation Method:** `enable` *(if the local user does not land directly in privilege level 15)*
   * **Privilege Escalation Password:** `<router-enable-password>` *(if required)*
4. Click **Save**.

*Verification:* Confirm `Cisco Local Credentials` appears in the **Credentials** list with type `Machine`.

---

### 3.3 Create an Inventory, Group, and Host in AWX
The AWX group name **must match** the `hosts:` pattern defined in `set_hostname.yml` (`cisco_routers`); otherwise, AWX will skip the host with a pattern mismatch warning.

1. Go to **Resources** → **Inventories** → **Add** → **Add inventory**.
2. Set **Name** to `EVE-NG Lab Inventory` and click **Save**.
3. **Create the Matching Group:**
   * Open the **Groups** tab inside `EVE-NG Lab Inventory` and click **Add**.
   * Set **Name** to `cisco_routers` *(matches `hosts: cisco_routers` in `set_hostname.yml`)* and click **Save**.
4. **Add the Host Inside the `cisco_routers` Group:**
   * Click on `cisco_routers` → open its **Hosts** tab → click **Add** → **Add new host**.
   * **Name:** `R1`
   * **Variables (YAML):**
     ```yaml
     ansible_network_os: cisco.ios.ios
     ansible_connection: ansible.netcommon.network_cli
     ansible_become: yes
     ansible_become_method: enable
     ```
   * Click **Save**.

*Verification:* Open `EVE-NG Lab Inventory` → **Groups** → `cisco_routers` → **Hosts** and confirm `R1` is listed and toggled **On**.

---

### 3.4 Create and Launch the Job Template (Using Default EE)
1. Go to **Resources** → **Templates** → **Add** → **Add job template**.
2. Configure the template using the built-in **Default Execution Environment**:
   * **Name:** `Test - Set Hostname (Local Auth)`
   * **Job Type:** `Run`
   * **Inventory:** `EVE-NG Lab Inventory`
   * **Project:** `Network-Automation-SOT` *(because `Update Revision on Launch` is enabled, AWX automatically pulls `set_hostname.yml` from GitHub)*
   * **Execution Environment:** `Default execution environment` *(intentionally selected first to reproduce the legacy SSH error)*
   * **Playbook:** `set_hostname.yml`
   * **Credentials:** Select `Cisco Local Credentials`
3. Click **Save**, then click **Launch** to run the job manually.

---

### 3.5 Expected Failure & Resolution
When running against an older Cisco IOS image in EVE-NG using the **Default Execution Environment**, AWX syncs the project cleanly, matches `R1` under `cisco_routers`, and fails during the SSH handshake:

### Error Output
![Cisco IOS SSH KEX Error](./ERROR/ansible-pyblissh.png)

> **How to Fix This Issue:** Follow **[1. Legacy Cisco IOS SSH Key Exchange Failure (`no acceptable kex algorithm`)](./TROUBLESHOOTING.md#1-legacy-cisco-ios-ssh-key-exchange-failure-no-acceptable-kex-algorithm)** in `TROUBLESHOOTING.md` to bake a custom Cisco Execution Environment (`localhost/awx-ee-cisco:latest`), assign it to this Job Template, and re-run the job.

*Verification:* Once the custom Execution Environment is assigned and the Job Template is re-launched, the job finishes with status **Successful** (green) and `show running-config | include hostname` on the router confirms `hostname R1-AUTOMATED`.