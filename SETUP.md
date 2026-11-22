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

## 2. GitHub SSH Authentication & AWX Project Sync

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