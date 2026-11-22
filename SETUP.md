# Setup & Implementation Guide

## 1. Install Ansible AWX on K3s

### 1.1 Update the System
```bash
sudo apt update && sudo apt upgrade -y
```

### 1.2 Install K3s
```bash
curl -sfL https://get.k3s.io | sh -
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
In your local Git repository, create a simple `set_hostname.yml` playbook inside `playbooks/` targeting the `cisco_routers` group and push it to `main`:

```bash
mkdir -p playbooks

cat << 'EOF' > playbooks/set_hostname.yml
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

git add playbooks/set_hostname.yml
git commit -m "feat: add initial Cisco IOS set_hostname playbook"
git push origin main
```

*Verification:* Confirm `playbooks/set_hostname.yml` appears in your GitHub repository under the `main` branch.

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
   * **Playbook:** `playbooks/set_hostname.yml`
   * **Credentials:** Select `Cisco Local Credentials`
3. Click **Save**, then click **Launch** to run the job manually.

---

### 3.5 Expected Failure & Resolution
When running against an older Cisco IOS image in EVE-NG using the **Default Execution Environment**, AWX syncs the project cleanly, matches `R1` under `cisco_routers`, and fails during the SSH handshake:

### Error Output
![Cisco IOS SSH KEX Error](./ERROR/ansible-pyblissh.png)

> **How to Fix This Issue:** Follow **[1. Legacy Cisco IOS SSH Key Exchange Failure (`no acceptable kex algorithm`)](./TROUBLESHOOTING.md#1-legacy-cisco-ios-ssh-key-exchange-failure-no-acceptable-kex-algorithm)** in `TROUBLESHOOTING.md` to bake a custom Cisco Execution Environment (`localhost/awx-ee-cisco:latest`), assign it to this Job Template, and re-run the job.

*Verification:* Once the custom Execution Environment is assigned and the Job Template is re-launched, the job finishes with status **Successful** (green) and `show running-config | include hostname` on the router confirms `hostname R1-AUTOMATED`.

> [← Back to Project Overview](./README.md)

## 4. Configure TARANAC (TACACS+) and Verify Direct SSH Authentication

Before integrating TACACS+ with Ansible AWX, we configure **TARANAC** (deployed via the official OVA appliance), apply AAA on the target Cisco IOS router, and verify direct SSH login from the Ubuntu VM to confirm centralized authentication works end-to-end.

> **Prerequisite:** Deploy the TARANAC OVA virtual appliance on your hypervisor with L3 reachability to your EVE-NG routers and AWX VM. Download the official OVA file from **[taranac.pro/download](https://taranac.pro/download/)**.

---

### 4.1 Configure Identity, Network Objects, Devices, and AAA Policy in TARANAC Web UI
Log in to the **TARANAC Web UI** (`https://<TARANAC_SERVER_IP>`) and complete the following six steps:

1. **Create User** (`INFRASTRUCTURE` → `Identity` → `Users` → `New User`)
   * **Username:** `<tacacs-username>` *(e.g., `tacacs_admin`)*
   * **Email:** `<user-email>` *(e.g., `tacacs_admin@example.com`)*
   * **Password:** `<tacacs-user-password>`
   * Click **Create User**.

2. **Create Group** (`INFRASTRUCTURE` → `Identity` → `Groups` → `New Group`)
   * **Name:** `<group-name>` *(e.g., `Network-Admins`)*
   * Toggle **Admin group** ON.
   * **Enable Password → Mode:** Select `Login Password`.
   * **Members:** Click **+ Add Members** and add the user created in **Step 1**.
   * Click **Create Group**.

3. **Create Network Object** (`INFRASTRUCTURE` → `Network` → `Network Objects` → `New Network Object`)
   * **Name:** `<object-name>` *(e.g., `R1-IP`)*
   * **Entry Type:** `Host (single IP)`
   * **IP Address:** `192.168.50.186` *(your EVE-NG Cisco router management IP)*
   * Click **Create Network Object**.

4. **Create Device Group** (`INFRASTRUCTURE` → `Network` → `Device Groups` → `New Device Group`)
   * **Name:** `<device-group-name>` *(e.g., `Cisco-Routers`)*
   * **TACACS+ Key:** `<your-shared-secret>` *(must match the router AAA config)*
   * Click **Create Device Group**.

5. **Create Device** (`INFRASTRUCTURE` → `Network` → `Devices` → `New Device`)
   * **Name:** `R1`
   * **Hostname:** `<router-hostname>` *(e.g., `R1`)*
   * **Network Object:** Click **+ Select...** and choose the Network Object created in **Step 3**.
   * **Device Groups:** Click **+ Add** and select the Device Group created in **Step 4**.
   * **Protocol Support:** Enable **TACACS+** only *(leave `RADIUS` and `NAC` disabled)*.
   * **TACACS+ Key:** `<your-shared-secret>` *(must match the router AAA config)*.
   * Click **Create Device**.

6. **Create AAA Policy** (`AAA` → `Policies` → `Policy Table` → `New Policy Rule`)
   * **Description:** Enter a rule description (e.g., `Network Admins -> TACACS+ General Full Access (priv 15)`) and ensure **Enabled** is toggled ON.
   * **Match Conditions:**
     * **Who:** Click **+ Add** under **Users** and **Groups** to add the user and group from **Steps 1–2**.
     * **Where:** Click **+ Add** under **Devices** and **Device Groups** to add the device and device group from **Steps 4–5**.
     * **Source → Source Networks:** Click **+ Add** to add your allowed source network(s).
   * **Protocol Actions:**
     * **TACACS+ → Mode:** `Profile`
     * **Profile:** `General Full Access (priv 15)` *(Cisco IOS / IOS-XE)*
     * **RADIUS → Mode:** `None`
   * Save the policy rule.

*Verification:* Confirm there are no pending undeployed changes on the TARANAC dashboard and that the new rule appears as **Enabled** in `AAA` → `Policies` → `Policy Table`.

---

### 4.2 Configure TACACS+ AAA on the Cisco IOS Router
> **Reference:** Official [TARANAC Cisco IOS / IOS-XE Configuration Guide](https://taranac.pro/docs/devices/cisco-ios/)

Connect to `R1` via console or your existing local SSH session and apply the AAA configuration below. Always keep `local` as a fallback method so you do not get locked out if the TACACS+ appliance is unreachable.

```ios
enable

configure terminal

hostname R1

no ip domain lookup
ip domain name test.com

service password-encryption
password encryption aes

enable secret P@ssw0rd123
username admin privilege 15 secret P@ssw0rd123

crypto key generate rsa modulus 2048
ip tacacs source-interface <source-interface>
ip ssh version 2

aaa new-model

tacacs server TARANAC-01
 address ipv4 <tacacs-server-ip>
 key <tacacs-secret>

aaa group server tacacs+ TARANAC-GRP
 server name TARANAC-01

aaa authentication login default group TARANAC-GRP local
aaa authentication login CONSOLE local
aaa authentication enable default group TARANAC-GRP enable

aaa authorization config-commands
aaa authorization exec default group TARANAC-GRP local
aaa authorization commands 0  default group TARANAC-GRP local
aaa authorization commands 1  default group TARANAC-GRP local
aaa authorization commands 15 default group TARANAC-GRP local

aaa accounting exec default start-stop group TARANAC-GRP
aaa accounting commands 0  default start-stop group TARANAC-GRP
aaa accounting commands 1  default start-stop group TARANAC-GRP
aaa accounting commands 15 default start-stop group TARANAC-GRP

line vty 0 4
 login authentication default
 transport input ssh
```

---

### 4.3 Verify Direct TACACS+ Authentication (Without AWX)

#### Step 1: Test AAA Directly from the Cisco Router
From `R1`'s privileged EXEC prompt, test the TACACS+ credentials directly against TARANAC:
```ios
R1# test aaa group TARANAC-GRP tacacs_admin <tacacs-user-password> legacy
```
*Expected Output:*
```text
Attempting authentication test to server-group TARANAC-GRP using tacacs+
User was successfully authenticated.
```

#### Step 2: Verify Direct SSH Login from the Ubuntu VM
From your Ubuntu terminal (without AWX), SSH into `R1` using the TARANAC account. Configure `~/.ssh/config` on Ubuntu to permanently allow `legacy SSH algorithms` for your lab subnet `192.168.50.*`:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh

cat << 'EOF' >> ~/.ssh/config
Host 192.168.50.*
    KexAlgorithms +diffie-hellman-group1-sha1,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
    Ciphers +aes128-cbc,3des-cbc,aes192-cbc,aes256-cbc
EOF

chmod 600 ~/.ssh/config
```

Now you can connect cleanly with a standard SSH command:
```bash
ssh tacacs_admin@192.168.50.186
```

*Verification:*
1. You successfully log in to `R1#` using the `tacacs_admin` password.
2. Run `show privilege` on `R1` and confirm it returns `Current privilege level is 15`.
3. Open the **TARANAC Web UI** → **AAA Logs** (Authentication & Session/Accounting logs) and confirm a successful login entry for `tacacs_admin` from `192.168.50.186`.

> [← Back to Project Overview](./README.md)

## 5. Verify AWX Job Template Authentication via TACACS+

Now that direct SSH login against TARANAC is working, we replace the local router credentials in AWX with the centralized TACACS+ account and confirm that AWX Job Templates authenticate, authorize, and log commands through TARANAC.

### 5.1 Create a TACACS+ Machine Credential in AWX
1. Log in to the **AWX Web UI** (`http://<your-server-ip>:32000`).
2. Navigate to **Resources** → **Credentials** → **Add**.
3. Configure the TACACS+ credential:
   * **Name:** `Cisco TACACS+ Credentials`
   * **Credential Type:** `Machine`
   * **Username:** `tacacs_admin` *(the user created in TARANAC during Step 4.1)*
   * **Password:** `<tacacs-user-password>`
   * *(Optional)* **Privilege Escalation Method:** `enable` and **Privilege Escalation Password:** `<tacacs-user-password>` *(only needed if your TARANAC profile does not land directly in privilege level 15)*
4. Click **Save**.

*Verification:* Confirm `Cisco TACACS+ Credentials` appears in **Resources** → **Credentials** with type `Machine`.

---

### 5.2 Update the Job Template to Use TACACS+ Credentials
1. Go to **Resources** → **Templates** and open your existing Cisco Job Template (`Test - Set Hostname (Local Auth)`), then click **Edit**.
   *(Optional: Rename the template to `Set Hostname (TACACS+ Auth)` to reflect the new authentication method.)*
2. Under **Credentials**, click the **×** next to `Cisco Local Credentials` to remove it, then select `Cisco TACACS+ Credentials`.
3. Confirm **Execution Environment** is still set to `Custom Cisco EE` (`localhost/awx-ee-cisco:latest`).
4. Click **Save**.

*Verification:* Open the template's **Details** tab and confirm only `Cisco TACACS+ Credentials` is attached.

---

### 5.3 Launch the Job Template and Verify End-to-End
1. Click **Launch** on the Job Template to run `set_hostname.yml` against `R1`.
2. Watch the job output under **Views** → **Jobs**.

*Verification:*
1. **AWX Job Output:** The job completes with status **Successful** (green) and zero authentication or SSH algorithm errors.
2. **TARANAC AAA Logs:** Open the **TARANAC Web UI** (`https://<TARANAC_SERVER_IP>`) → **LOGGING & REPORTS** → **AAA Logs**:
   * **Authentication Logs:** Confirm a **PASS** entry for `tacacs_admin` authenticating on `R1` (`192.168.50.186`) from the AWX VM's IP address.
   * **Accounting / Command Logs:** Confirm the configuration commands pushed by Ansible (`configure terminal`, `hostname ...`) are logged under `tacacs_admin`, proving AWX authenticated via TACACS+ rather than falling back to local credentials.

---

> [← Back to Project Overview](./README.md)

## 6. Configure GitHub Webhooks with ngrok HTTPS Tunnel

In this phase, we move from manual job execution to event-driven automation. Because AWX runs on a private LAN IP (`http://<your-server-ip>:32000`), GitHub's cloud webhook servers cannot reach it directly. We use **ngrok** to create a temporary public HTTPS tunnel to AWX and wire up a GitHub Webhook so every `git push` automatically triggers the AWX Job Template.

---

### 6.1 Install and Start `ngrok` on the AWX VM
1. Create a free account at [ngrok.com](https://ngrok.com/) and copy your **Authtoken** from the dashboard.
2. Install `ngrok` on your Ubuntu AWX VM and configure your token:
   ```bash
   wget https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz
   ```
   ```bash
   sudo tar xvzf ./ngrok-v3-stable-linux-amd64.tgz -C /usr/local/bin
   ```
   ```bash
   ngrok config add-authtoken <NGROK_AUTHTOKEN>
   ```
3. Start an HTTPS tunnel forwarding to AWX's NodePort (`32000`):

   ```bash
   ngrok http 32000
   ```

*Verification:* Copy the **Forwarding** HTTPS URL displayed in the terminal (e.g., `https://<random-id>.ngrok-free.app`) and open it in a browser to confirm the AWX login page loads.

---

### 6.2 Enable GitHub Webhooks on the AWX Job Template
1. Open the **AWX Web UI using your `ngrok` HTTPS URL** (`https://<random-id>.ngrok-free.app`) instead of your private LAN IP. *(Accessing AWX through the `ngrok` link ensures AWX automatically generates the **Webhook URL** with your public `ngrok` domain.)*
2. Navigate to **Resources** → **Templates**.
3. Open your Job Template (e.g., `Set Hostname (TACACS+ Auth)`) and click **Edit**.
4. Under **Options**, check **Enable Webhook**.
5. Set **Webhook Service** to `GitHub`.
6. *(Optional)* Leave **Webhook Credential** blank unless you want AWX to post commit status checks back to GitHub.
7. Click **Save**.
8. On the template's **Details** tab, copy both generated values:
   * **Webhook URL** *(e.g., `https://<random-id>.ngrok-free.app/api/v2/job_templates/<id>/github/`)*
   * **Webhook Key** *(the secret token used to sign webhook payloads)*

*Verification:* Confirm the **Webhook URL** starts with `https://<random-id>.ngrok-free.app` and that both **Webhook URL** and **Webhook Key** are visible on the Job Template's **Details** tab.

---

### 6.3 Add the Webhook in Your GitHub Repository
1. Open your GitHub repository and navigate to **Settings** → **Webhooks** → **Add webhook**.
2. Configure the webhook fields:
   * **Payload URL:** Replace the private AWX host/port in AWX's Webhook URL with your `ngrok` HTTPS URL:
     ```text
     https://<random-id>.ngrok-free.app/api/v2/job_templates/<id>/github/
     ```
   * **Content type:** `application/json`
   * **Secret:** Paste the **Webhook Key** copied from AWX.
   * **SSL verification:** `Enable SSL verification`
   * **Which events would you like to trigger this webhook?** Select `Just the push event`.
   * Ensure **Active** is checked.
3. Click **Add webhook**.

*Verification:* Click on the newly created webhook, open the **Recent Deliveries** tab, and confirm the initial `ping` event shows a green checkmark (`200 OK` or `202 Accepted`).

---

### 6.4 Test Automatic Triggering on `git push`
Make a quick change to `playbooks/set_hostname.yml` (such as updating the target hostname) and push it to `main`:

```bash
git add playbooks/set_hostname.yml
git commit -m "test: trigger AWX Job Template via GitHub Webhook and ngrok"
git push origin main
```

*Verification:*
1. **GitHub Webhooks → Recent Deliveries:** Shows a green `202 Accepted` response for the `push` event.
2. **ngrok Terminal:** Logs `POST /api/v2/job_templates/<id>/github/ 202 Accepted`.
3. **AWX Web UI → Views → Jobs:** The Job Template launches automatically without manual intervention, completes with status **Successful**, and updates `R1`'s hostname to `R1-WEBHOOK-TEST`.

> **Limitation Noted for Next Phases:** Free `ngrok` URLs rotate on every restart, and standard GitHub Webhooks fire on *every* push—triggering all linked templates regardless of which file changed. In **Task 7**, we resolve both issues using **GitHub Actions** and a **local Self-Hosted Runner**.

---

> [← Back to Project Overview](./README.md)

## 7. Deploy GitHub Self-Hosted Runner and Configure Selective GitHub Actions (CI/CD)

To eliminate `ngrok` and stop every `git push` from triggering all AWX Job Templates at once, we deploy a **GitHub Self-Hosted Runner** directly on the AWX VM and use **GitHub Actions** to call the AWX REST API over the local LAN only when a specific playbook changes.

---

### 7.1 Deploy the GitHub Self-Hosted Runner on the AWX VM
1. In your GitHub repository, navigate to **Settings** → **Actions** → **Runners** → **New self-hosted runner**.
2. Select **Linux** and **x64**.
3. On your AWX VM, run the download and configuration commands provided by GitHub:

   ```bash
   mkdir -p ~/actions-runner && cd ~/actions-runner

   # Download and extract the runner package (use the latest URL from GitHub UI)
   curl -o actions-runner-linux-x64.tar.gz -L <GITHUB_RUNNER_DOWNLOAD_URL>
   tar xzf ./actions-runner-linux-x64.tar.gz

   # Register the runner with your repository
   ./config.sh --url https://github.com/<your-username>/<your-repo> --token <REGISTRATION_TOKEN>
   ```
   *(Accept the default runner group, name, and labels—including `self-hosted`—when prompted.)*

4. Install and start the runner as a background `systemd` service so it stays online across reboots:
   ```bash
   sudo ./svc.sh install
   sudo ./svc.sh start
   sudo ./svc.sh status
   ```

*Verification:* Return to GitHub **Settings** → **Actions** → **Runners** and confirm your runner is listed with a green **Idle** status.

---

### 7.2 Create an AWX API Token and Add GitHub Repository Secrets
1. **Generate an AWX Personal Access Token (PAT):**
   * Open the **AWX Web UI** (`http://<your-server-ip>:32000`).
   * Go to **Access** → **Users** → click your admin user → open the **Tokens** tab → click **Add**.
   * Set **Scope** to `Write`, click **Save**, and copy the generated token immediately.
2. **Find Your Job Template IDs:**
   * Open each Job Template in AWX and note its ID from the browser URL (e.g., `/#/templates/job_template/12/details` → `12` for `set_hostname.yml`).
3. **Store Credentials in GitHub Secrets:**
   * In your GitHub repository, go to **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.
   * Add the following secrets:
     * `AWX_BASE_URL`: `http://<your-server-ip>:32000` *(no trailing slash)*
     * `AWX_API_TOKEN`: `<your-awx-personal-access-token>`

*Verification:* Confirm both `AWX_BASE_URL` and `AWX_API_TOKEN` appear under **Repository secrets**.

---

### 7.3 Create the Matrix-Driven Selective GitHub Actions Workflow
Instead of maintaining a separate workflow file for every playbook, create a single `.github/workflows/trigger-awx.yml` file that maps each playbook to its AWX Job Template ID and uses `git diff` against the previous commit (`HEAD~1`) to launch only modified playbooks:

> **Note:** This CI workflow code was generated using **Gemini – Neon Model**.

```bash
mkdir -p .github/workflows

cat << 'EOF' > .github/workflows/trigger-awx.yml
name: Trigger AWX on Modified Playbook

on:
  push:
    branches: [main]

jobs:
  trigger:
    runs-on: self-hosted
    strategy:
      fail-fast: false
      matrix:
        include:
          - playbook: playbooks/set_hostname.yml
            template_id: 12 # Get this ID from Step 7.2.2
          # Future playbooks: just add 2 lines (playbook + template_id)

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2

      - name: Check and launch ${{ matrix.playbook }} (Template ${{ matrix.template_id }})
        run: |
          if git diff --name-only HEAD~1 HEAD | grep -qx "${{ matrix.playbook }}"; then
            echo "Change detected in ${{ matrix.playbook }} – launching AWX template ${{ matrix.template_id }}..."
            curl -fsS -X POST "${{ secrets.AWX_BASE_URL }}/api/v2/job_templates/${{ matrix.template_id }}/launch/" \
              -H "Authorization: Bearer ${{ secrets.AWX_API_TOKEN }}" \
              -H "Content-Type: application/json"
          else
            echo "No changes in ${{ matrix.playbook }} – skipping."
          fi
EOF
```

Push the workflow to GitHub:
```bash
git add .github/workflows/trigger-awx.yml
git commit -m "ci: add matrix-based AWX trigger workflow for self-hosted runner"
git push origin main
```

---

### 7.4 Verify Selective Triggering Over LAN (Without `ngrok`)
1. Stop `ngrok` if it is still running, and delete or disable the old GitHub Webhook under **Settings** → **Webhooks**.
2. **Test 1 — Unrelated File Change (Should Skip All Templates):**
   * Edit `README.md` and push to `main`.
   * Open **GitHub → Actions → Trigger AWX on Modified Playbook** and confirm both matrix jobs log `No changes in <playbook> – skipping.`
3. **Test 2 — Single Playbook Change (Should Trigger Only That Template):**
   * Update the hostname inside `playbooks/set_hostname.yml` and push to `main`:

     ```bash
     git add playbooks/set_hostname.yml
     git commit -m "test: trigger AWX over LAN via self-hosted GitHub Actions runner"
     git push origin main
     ```

*Verification:*
1. **GitHub → Actions:** `playbooks/set_hostname.yml` logs `Change detected in playbooks/set_hostname.yml – launching AWX template 12...`.
2. **AWX Web UI → Views → Jobs:** Only Template `12` (`set_hostname.yml`) launches and completes with status **Successful** over the private LAN, updating `R1`'s hostname to `R1-ACTIONS-LAN` with `ngrok` completely turned off.

---

> [← Back to Project Overview](./README.md)

## 8. Migrate to Modular Git-Backed Source of Truth

Instead of managing hosts manually inside the AWX UI and hardcoding device settings inside playbooks, we move all inventory and device configuration data into Git (`hosts.ini`, `group_vars`, and `host_vars`). Playbooks become reusable templates, AWX syncs its inventory directly from GitHub, and GitHub Actions triggers only the Job Template whose playbook or variable file changed.

---

### 8.1 Create the Modular Source of Truth Directory Structure
Organize your repository so connection parameters live in `group_vars` and device-specific configurations live in per-feature YAML files under `host_vars/<device>/`:

Create the files locally:

```bash
mkdir -p inventory/group_vars inventory/host_vars/CR1

# 1. Define the inventory hosts and groups
cat << 'EOF' > inventory/hosts.ini
[cisco_routers]
CR1 ansible_host=192.168.50.186
EOF

# 2. Define shared Cisco IOS connection variables
cat << 'EOF' > inventory/group_vars/cisco_routers.yml
---
ansible_network_os: cisco.ios.ios
ansible_connection: ansible.netcommon.network_cli
EOF

# 3. Define device-specific hostname variable
cat << 'EOF' > inventory/host_vars/CR1/hostname.yml
---
router_hostname: CR1-SOT-PROD
EOF

# 4. Define device-specific loopback interface variables
cat << 'EOF' > inventory/host_vars/CR1/loopback_interfaces.yml
---
loopback_interfaces:
  - name: Loopback0
    description: Managed by Ansible SOT
    ipv4: 10.100.100.1 255.255.255.255
EOF
```

*Verification:* Run `tree inventory/` (or `find inventory/`) and confirm all four files are in place.

---

### 8.2 Refactor Playbooks to Be Dynamic and Variable-Driven
Update `playbooks/set_hostname.yml` and `playbooks/create_loopback.yml` so they pull values dynamically from `host_vars` rather than hardcoding them:

```bash
mkdir -p playbooks

cat << 'EOF' > playbooks/set_hostname.yml
---
- name: Configure Cisco IOS Hostname from Source of Truth
  hosts: cisco_routers
  gather_facts: false

  tasks:
    - name: Merge hostname configuration on the router
      cisco.ios.ios_hostname:
        config:
          hostname: "{{ router_hostname }}"
        state: merged
EOF
```
```bash
cat << 'EOF' > playbooks/create_loopback.yml
---
- name: Configure Cisco IOS Loopback Interfaces from Source of Truth
  hosts: cisco_routers
  gather_facts: false

  tasks:
    - name: Configure loopback interface description and state
      cisco.ios.ios_interfaces:
        config:
          - name: "{{ item.name }}"
            description: "{{ item.description }}"
            enabled: true
        state: merged
      loop: "{{ loopback_interfaces }}"

    - name: Configure loopback IPv4 address
      cisco.ios.ios_l3_interfaces:
        config:
          - name: "{{ item.name }}"
            ipv4:
              - address: "{{ item.ipv4 }}"
        state: merged
      loop: "{{ loopback_interfaces }}"
EOF
```

---

### 8.3 Configure a Git-Backed Inventory Source in AWX
Replace the manually created hosts in AWX with a dynamic inventory sourced directly from your GitHub repository:

1. Open the **AWX Web UI** (`http://<your-server-ip>:32000`) and go to **Resources** → **Inventories** → **Add** → **Add inventory**.
   * **Name:** `Git-SOT-Inventory`
   * Click **Save**.
2. Open the **Sources** tab inside `Git-SOT-Inventory` and click **Add**:
   * **Name:** `GitHub-Hosts-INI`
   * **Source:** `Sourced from a Project`
   * **Project:** `Network-Automation-SOT`
   * **Inventory file:** `inventory/hosts.ini`
   * **Update options:** Check **Overwrite**, **Overwrite variables**, and **Update on launch**.
   * Click **Save**, then click **Sync**.
3. Update both Job Templates (`set_hostname.yml` — Template `12`, and `create_loopback.yml` — Template `13`) to use `Git-SOT-Inventory` as their **Inventory**.

*Verification:* Open `Git-SOT-Inventory` → **Groups** → `cisco_routers` → **Hosts** and confirm `CR1` is synced automatically with its `group_vars` and `host_vars` loaded.

---

### 8.4 Update GitHub Actions for Variable-Aware Selective Triggering
Update `.github/workflows/trigger-awx.yml` so each matrix entry maps a playbook **and** its corresponding `host_vars` filename to an AWX Job Template ID. When a commit modifies either the playbook or its matching variable file inside `host_vars/<device>/`, only that Job Template launches.

> **Note:** This CI workflow code was generated using **Gemini – Neon Model**.

```bash
cat << 'EOF' > .github/workflows/trigger-awx.yml
# Workflow name displayed in the GitHub Actions tab
name: Trigger AWX Selectively

# Run this workflow whenever code is pushed to the main branch
on:
  push:
    branches:
      - main

jobs:
  trigger:
    # Use the local runner hosted on the AWX VM so we can reach AWX over LAN
    runs-on: self-hosted

    strategy:
      # Continue checking other templates even if one fails
      fail-fast: false
      # Map each playbook and its corresponding host_vars filename to an AWX Job Template ID
      matrix:
        include:
          - playbook: playbooks/set_hostname.yml
            var_file: hostname.yml
            template_id: 12 # Replace with your actual template_id
          - playbook: playbooks/create_loopback.yml
            var_file: loopback_interfaces.yml
            template_id: 13 # Replace with your actual template_id

    steps:
      # Download the repository with the last 2 commits so git diff can compare HEAD vs HEAD~1
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 2

      # Check if the playbook or its matching variable file changed, then trigger AWX via API
      - name: Check changes and launch AWX
        env:
          AWX_URL: ${{ secrets.AWX_BASE_URL }}
          AWX_TOKEN: ${{ secrets.AWX_API_TOKEN }}
        run: |
          # Get the list of files modified in the latest commit
          CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD)

          # Match either the playbook in playbooks/ or its variable file inside host_vars/<device>/
          if echo "$CHANGED_FILES" | grep -qE "(^${{ matrix.playbook }}$|/${{ matrix.var_file }}$)"; then
            echo "Launching Template ID ${{ matrix.template_id }}..."
            curl -f -s -S -X POST "$AWX_URL/api/v2/job_templates/${{ matrix.template_id }}/launch/" \
              -H "Authorization: Bearer $AWX_TOKEN" \
              -H "Content-Type: application/json"
          else
            echo "Skipping ${{ matrix.playbook }} - no changes."
          fi
EOF
```

Commit and push all changes:
```bash
git add inventory/ playbooks/set_hostname.yml playbooks/create_loopback.yml .github/workflows/trigger-awx.yml
git commit -m "feat: migrate to modular Git-backed SOT with variable-aware AWX triggers"
git push origin main
```

---

### 8.5 Verify Variable-Driven Selective Automation
Test that editing a single Source of Truth file triggers only its matching AWX Job Template:

```bash
git add inventory/host_vars/CR1/hostname.yml
git commit -m "change(CR1): update hostname in Source of Truth"
git push origin main
```

*Verification:*
1. **GitHub → Actions (`Trigger AWX Selectively`):**
   * `playbooks/set_hostname.yml` logs `Launching Template ID 12...`
   * `playbooks/create_loopback.yml` logs `Skipping playbooks/create_loopback.yml - no changes.`
2. **AWX Web UI → Views → Jobs:** `Git-SOT-Inventory` syncs automatically, Template `12` completes with status **Successful**, and `show running-config | include hostname` on `CR1` confirms the updated hostname.

---

> [← Back to Project Overview](./README.md)

## 9. Multi-Vendor Support (Juniper Junos) and Custom Execution Environment

To support both legacy **Cisco IOS** routers and **Juniper Junos** routers cleanly in AWX, we bake a single multi-vendor **Custom Execution Environment (EE)**. This container image bakes in legacy SSH algorithms for Cisco IOS alongside the PyEZ/NETCONF libraries and the official `juniper.device` collection for Juniper Junos.

> **Why `juniper.device` instead of `junipernetworks.junos`?**  
> The legacy `junipernetworks.junos` collection is deprecated. **`juniper.device`** is officially maintained by Juniper Networks and uses **NETCONF/PyEZ** (`junos-eznc`), providing native candidate-config commits, automatic diffs, and full compatibility with modern Ansible-core releases.

---

### 9.1 Bake the Multi-Vendor Custom Execution Environment (Podman + K3s)
Build a custom EE image that resolves legacy Cisco IOS SSH KEX/cipher/host-key negotiation globally inside the container and pre-installs all Juniper Junos dependencies:

```bash
mkdir -p ~/custom-ee && cd ~/custom-ee

cat << 'EOF' > Dockerfile
FROM quay.io/ansible/awx-ee:latest

USER root

# 1. Install build tools and Python network libraries
RUN dnf install -y gcc python3-devel libxml2-devel libxslt-devel libssh-devel openssl-devel && \
    pip3 install --no-cache-dir --upgrade pip && \
    pip3 install --no-cache-dir ansible-pylibssh junos-eznc ncclient && \
    dnf clean all

# 2. Ensure UID 1000 exists in /etc/passwd with a valid home directory so libssh reads SSH configs
RUN grep -q ":1000:" /etc/passwd || echo "runner:x:1000:0:runner:/home/runner:/bin/bash" >> /etc/passwd && \
    mkdir -p /home/runner/.ssh && \
    printf "Host *\n    KexAlgorithms +diffie-hellman-group14-sha1\n    HostKeyAlgorithms +ssh-rsa\n    PubkeyAcceptedAlgorithms +ssh-rsa\n    StrictHostKeyChecking no\n    UserKnownHostsFile /dev/null\n" | tee /etc/ssh/ssh_config /home/runner/.ssh/config && \
    chown -R 1000:0 /home/runner && \
    chmod 700 /home/runner/.ssh && \
    chmod 600 /home/runner/.ssh/config

# 3. Pre-install Cisco and Juniper collections globally
RUN ansible-galaxy collection install cisco.ios juniper.device ansible.netcommon -p /usr/share/ansible/collections

# 4. Bake SSH arguments globally into the container environment
ENV HOME=/home/runner \
    ANSIBLE_SSH_ARGS="-o KexAlgorithms=+diffie-hellman-group14-sha1 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"

USER 1000
EOF
```
```bash
# Build the multi-vendor EE image
sudo podman build -t localhost/awx-ee-multivendor:latest .
```
```bash
# Import into K3s containerd and clean up local Podman cache
sudo podman save localhost/awx-ee-multivendor:latest | sudo k3s ctr images import -
sudo podman rmi -f localhost/awx-ee-multivendor:latest
sudo podman image prune -f
```

*Verification:* Confirm the image is registered in K3s:
```bash
sudo k3s crictl images | grep awx-ee-multivendor
```

---

### 9.2 Register the Custom EE in AWX
1. Open the **AWX Web UI** (`http://<your-server-ip>:32000`) and go to **Administration** → **Execution Environments** → **Add**.
2. Configure the EE:
   * **Name:** `Multi-Vendor Network EE`
   * **Image:** `localhost/awx-ee-multivendor:latest`
   * **Pull:** `Never`
3. Click **Save**.
4. Update your Job Templates (`set_hostname.yml` — Template `12`, and `create_loopback.yml` — Template `13`) to use `Multi-Vendor Network EE`.

*Verification:* Confirm both Job Templates show `Multi-Vendor Network EE` under **Details** → **Execution Environment**.

---

### 9.3 Enable NETCONF over SSH on the Juniper Router (`JR1`)
Because `juniper.device` communicates over NETCONF (TCP port `830`), enable NETCONF over SSH on `JR1`:

```junos
configure

set system host-name JR1-CORE-SG
set system domain-name test.com

set interfaces em0 unit 0 family inet address 192.168.50.200/24

set system authentication-order tacplus
set system authentication-order password
set system root-authentication encrypted-password "P@ssw0rd123"

set system tacplus-server 192.168.50.201 secret "$9$ahJjkq.fznCmfcleK8LGDiHqfTz3/Ap5T"
set system tacplus-server 192.168.50.201 source-address 192.168.50.200

set system accounting events login
set system accounting events change-log
set system accounting events interactive-commands

set system accounting destination tacplus server 192.168.50.201 secret "$9$cZhSKW8L7Vs4X7.5TQn6revM87-Vw2oJN-"
set system accounting destination tacplus server 192.168.50.201 source-address 192.168.50.200

set system login user admin uid 2000
set system login user admin class super-user
set system login user admin authentication encrypted-password "P@ssw0rd123"

set system login user remote full-name "TACACS+ Remote User"
set system login user remote uid 2001
set system login user remote class super-user

set system services ssh protocol-version v2
set system services netconf ssh

commit and-quit
```

*Verification:* From the AWX VM, confirm TCP port `830` is reachable on `JR1`:
```bash
nc -zv <JR1_MGMT_IP> 830
```

---

### 9.4 Add Juniper (`JR1`) to the Modular Source of Truth
Onboard `JR1` into `inventory/` using the same per-feature `host_vars` structure (`hostname.yml` and `loopback_interfaces.yml`). Standardize Juniper loopbacks around `lo0` with logical `unit` numbers:

```bash
mkdir -p inventory/host_vars/JR1

# 1. Add juniper_routers group to inventory/hosts.ini
cat << 'EOF' >> inventory/hosts.ini

[juniper_routers]
JR1 ansible_host=192.168.50.200
EOF

# 2. Define shared Juniper Junos connection variables
cat << 'EOF' > inventory/group_vars/juniper_routers.yml
---
ansible_network_os: juniper.device.junos
ansible_connection: ansible.netcommon.netconf
EOF

# 3. Define JR1 hostname variable
cat << 'EOF' > inventory/host_vars/JR1/hostname.yml
---
router_hostname: JR1-SOT-PROD
EOF

# 4. Define JR1 standardized lo0 logical unit loopback variables
cat << 'EOF' > inventory/host_vars/JR1/loopback_interfaces.yml
loopback_interfaces:
  - name: lo0
    description: Router-ID
    ipv4: 10.255.10.3/32
    unit: 0
EOF
```

---

### 9.5 Update Playbooks for Multi-Vendor Execution

**Add this task in `playbooks/set_hostname.yml`:**

```yaml
    # --- JUNIPER JUNOS TASKS ---
    - name: Set hostname on Juniper JUNOS devices
      juniper.device.junos_hostname:
        config:
          hostname: "{{ router_hostname }}"
        state: merged
      when: ansible_network_os == 'juniper.device.junos'
```

**Add this task in `playbooks/create_loopback.yml`:**

```yaml
    # --- JUNIPER JUNOS TASKS ---
    - name: Configure Juniper JUNOS Loopback description and status
      juniper.device.junos_interfaces:
        config:
          - name: "{{ item.name }}"
            description: "{{ item.description }}"
            enabled: true
        state: merged
      loop: "{{ loopback_interfaces }}"
      when: ansible_network_os == 'juniper.device.junos'

    - name: Configure Juniper JUNOS Loopback IPv4 address
      juniper.device.junos_l3_interfaces:
        config:
          - name: "{{ item.name }}"
            unit: "{{ item.unit }}"
            ipv4:
              - address: "{{ item.ipv4 }}"
        state: merged
      loop: "{{ loopback_interfaces }}"
      when: ansible_network_os == 'juniper.device.junos'
```

---

### 9.6 Verify Multi-Vendor Automation End-to-End
Commit and push the Juniper Source of Truth and playbook updates (no changes are needed in `.github/workflows/trigger-awx.yml` because it already matches `*/hostname.yml` and `*/loopback_interfaces.yml`):

```bash
git add inventory/ playbooks/set_hostname.yml playbooks/create_loopback.yml
git commit -m "feat: add Juniper Junos support via juniper.device and multi-vendor custom EE"
git push origin main
```

*Verification:*
1. **AWX Web UI → Views → Jobs:** `Git-SOT-Inventory` syncs `JR1` under `juniper_routers`. Both `set_hostname.yml` (Template `12`) and `create_loopback.yml` (Template `13`) succeed against **both** `CR1` (Cisco IOS, without `pre_tasks`) and `JR1` (Juniper Junos via NETCONF).
2. **Juniper Router (`JR1`):** Confirm the hostname and `lo0.0` configuration were committed:
   ```junos
   show configuration system host-name
   show configuration interfaces lo0
   ```
3. **Feature-Level Trigger Test:** Edit only `inventory/host_vars/JR1/loopback_interfaces.yml`, push to `main`, and confirm GitHub Actions launches only Template `13` (`create_loopback.yml`) while skipping Template `12`.

---

> [← Back to Project Overview](./README.md)

## 10. Refactor to Master `site.yml` and Dynamic Tag-Based CI/CD

To scale Day 2 operations without manually editing `.github/workflows/trigger-awx.yml` or creating new AWX Job Templates for every new network feature, we consolidate execution behind a single root `site.yml` dispatcher and a single master AWX Job Template. GitHub Actions dynamically extracts Ansible tags from modified filenames and passes them to AWX via the REST API.

---

### 10.1 Align Playbook Filenames with `host_vars`
Rename the playbooks inside `playbooks/` so their base filenames match the corresponding per-feature files in `inventory/host_vars/<device>/`:

```bash
git mv playbooks/set_hostname.yml playbooks/hostname.yml
git mv playbooks/create_loopback.yml playbooks/loopback_interfaces.yml
```

*Verification:* Run `ls playbooks/` and confirm it contains `hostname.yml` and `loopback_interfaces.yml`.

---

### 10.2 Create the Master `site.yml` Dispatcher
Create `site.yml` at the repository root to import each feature playbook and assign a tag matching its filename (without `.yml`):

```bash
cat << 'EOF' > site.yml
---
- name: Configure Hostnames
  ansible.builtin.import_playbook: playbooks/hostname.yml
  tags:
    - hostname

- name: Configure Loopback Interfaces
  ansible.builtin.import_playbook: playbooks/loopback_interfaces.yml
  tags:
    - loopback_interfaces
EOF
```

Commit and push the new structure so AWX can detect `site.yml`:

```bash
git add playbooks/ site.yml
git commit -m "refactor: align playbook names and add root site.yml master dispatcher"
git push origin main
```

*Verification:* Confirm `site.yml`, `playbooks/hostname.yml`, and `playbooks/loopback_interfaces.yml` appear on the `main` branch in GitHub.

---

### 10.3 Create the Master Job Template in AWX
1. Open the **AWX Web UI** (`http://<your-server-ip>:32000`), go to **Resources** → **Projects**, and trigger a sync on `Network-Automation-SOT` so AWX pulls `site.yml`.
2. Navigate to **Resources** → **Templates** → **Add** → **Add job template**.
3. Configure the master template:
   * **Name:** `Master-Network-Deploy`
   * **Job Type:** `Run`
   * **Inventory:** `Git-SOT-Inventory`
   * **Project:** `Network-Automation-SOT`
   * **Execution Environment:** `Multi-Vendor Network EE`
   * **Playbook:** `site.yml`
   * **Credentials:** Select your TACACS+ Machine Credential
   * **Job Tags:** Leave the input field blank and check **Prompt on launch** *(required so GitHub Actions can pass `job_tags` in the API payload)*
4. Click **Save** and note the numeric **Template ID** from the browser URL (e.g., `/#/templates/job_template/15/details` → `15`).

*Verification:* Confirm `Master-Network-Deploy` is saved with `site.yml` selected and **Prompt on launch** enabled on **Job Tags**.

---

### 10.4 Update GitHub Actions for Dynamic Tag-Based Dispatch
Replace the hardcoded matrix in `.github/workflows/trigger-awx.yml` with a single job that reads `git diff`, extracts unique feature tags from changed files under `playbooks/`, `inventory/host_vars/<device>/`, or `inventory/group_vars/all/`, and launches the master Job Template with `job_tags`. Replace `<MASTER_TEMPLATE_ID>` with the ID from Step 10.3 (e.g., `17`):

```bash
cat << 'EOF' > .github/workflows/trigger-awx.yml
# Workflow name displayed in the GitHub Actions tab
name: Trigger AWX Selectively

# Run this workflow whenever code is pushed to the main branch
on:
  push:
    branches:
      - main

jobs:
  trigger:
    # Use the local runner hosted on the AWX VM so we can reach AWX over LAN
    runs-on: self-hosted

    steps:
      # Download the repository with the last 2 commits so git diff can compare HEAD vs HEAD~1
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 2

      # Detect modified playbooks or variable files, extract matching tags, and trigger the master AWX template
      - name: Detect changed features and launch AWX
        env:
          AWX_URL: ${{ secrets.AWX_BASE_URL }}
          AWX_TOKEN: ${{ secrets.AWX_API_TOKEN }}
          TEMPLATE_ID: <MASTER_TEMPLATE_ID> # Master-Network-Deploy (site.yml) Job Template ID
        run: |
          # Compare the latest commit against the previous one and extract unique feature names as Ansible tags
          # Watches: playbooks/, inventory/host_vars/<device>/, and inventory/group_vars/all/
          TAGS=$(git diff --name-only HEAD~1 HEAD \
            | grep -E '^(playbooks/|inventory/host_vars/[^/]+/|inventory/group_vars/all/).*\.yml$' \
            | xargs -r -n1 basename \
            | sed 's/\.yml$//' \
            | sort -u \
            | paste -sd, -)

          # Only call the AWX API if at least one network playbook or variable file changed
          if [ -n "$TAGS" ]; then
            echo "Detected feature changes. Launching Template $TEMPLATE_ID with tags:$TAGS"
            curl -f -s -S -X POST "$AWX_URL/api/v2/job_templates/$TEMPLATE_ID/launch/" \
              -H "Authorization: Bearer $AWX_TOKEN" \
              -H "Content-Type: application/json" \
              -d "{\"job_tags\": \"$TAGS\"}"
          else
            # Skip AWX cleanly for docs or unrelated repo changes
            echo "No playbook, host_vars, or global group_vars changes detected. Skipping AWX."
          fi
EOF
```

Commit and push the workflow update:

```bash
git add .github/workflows/trigger-awx.yml
git commit -m "ci: switch AWX trigger workflow to dynamic tag-based dispatch"
git push origin main
```

*Verification:* In **GitHub → Actions**, confirm the workflow runs and logs `No playbook or host_vars changes detected. Skipping AWX.`

---

### 10.5 Verify Dynamic Tag-Based Automation End-to-End
1. **Feature-Level Trigger Test:** Edit a single feature variable file (such as `inventory/host_vars/JR1/loopback_interfaces.yml`), commit, and push to `main`.
2. **GitHub → Actions:** Confirm the job logs `Detected feature changes. Launching Template <MASTER_TEMPLATE_ID> with tags: loopback_interfaces`.
3. **AWX Web UI → Views → Jobs:** Confirm `Master-Network-Deploy` runs a `Source Control Update`, launches with **Job Tags** set to `loopback_interfaces`, executes only `playbooks/loopback_interfaces.yml`, and skips `playbooks/hostname.yml`.
4. *(Optional Cleanup)* Delete the legacy per-playbook Job Templates (`12` and `13`) in AWX now that all deployments route through `Master-Network-Deploy`.

> **Day 2 Scalability:** Adding a new feature in the future (e.g., `bgp.yml`) only requires creating `playbooks/bgp.yml`, adding `inventory/host_vars/<device>/bgp.yml`, and appending a 4-line import block to `site.yml`—no changes to GitHub Actions or AWX are needed.

---

> [← Back to Project Overview](./README.md)