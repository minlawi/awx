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
![Cisco IOS SSH KEX Error](./assests/ansible-pyblissh.png)

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

![Juniper Collections](./assests/juniper-collections.png)

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
4. Click **Save** and note the numeric **Template ID** from the browser URL (e.g., `/#/templates/job_template/17/details` → `17`).

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
            echo "Detected feature changes. Launching Template $TEMPLATE_ID with tags: $TAGS"
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

*Verification:* In **GitHub → Actions**, confirm the workflow runs and logs `No playbook, host_vars, or global group_vars changes detected. Skipping AWX.`

---

### 10.5 Verify Dynamic Tag-Based Automation End-to-End
1. **Feature-Level Trigger Test:** Edit a single feature variable file (such as `inventory/host_vars/JR1/loopback_interfaces.yml`), commit, and push to `main`.
2. **GitHub → Actions:** Confirm the job logs `Detected feature changes. Launching Template <MASTER_TEMPLATE_ID> with tags: loopback_interfaces`.
3. **AWX Web UI → Views → Jobs:** Confirm `Master-Network-Deploy` runs a `Source Control Update`, launches with **Job Tags** set to `loopback_interfaces`, executes only `playbooks/loopback_interfaces.yml`, and skips `playbooks/hostname.yml`.
4. *(Optional Cleanup)* Delete the legacy per-playbook Job Templates (`12` and `13`) in AWX now that all deployments route through `Master-Network-Deploy`.

---

### 10.6 Add a Global Multi-Vendor Feature (`inventory/group_vars/all/ntp.yml`)
For settings shared across every router (such as NTP, Syslog, or login banners), store per-feature variable files under `inventory/group_vars/all/` instead of duplicating them in each device's `host_vars/` directory.

1. **Create the global NTP variable file:**
   ```bash
   mkdir -p inventory/group_vars/all

   cat << 'EOF' > inventory/group_vars/all/ntp.yml
   ---
   ntp_servers:
     - server: 162.159.200.1
       prefer: true
     - server: 162.159.200.123
   EOF
   ```

2. **Create the multi-vendor NTP playbook (`playbooks/ntp.yml`):**
   ```bash
   cat << 'EOF' > playbooks/ntp.yml
   ---
   - name: Configure NTP Servers from Source of Truth
     hosts: "{{ target_hosts | default('all') }}"
     gather_facts: false

     tasks:
       # --- CISCO IOS TASKS ---
       - name: Configure NTP servers on Cisco IOS devices
         cisco.ios.ios_ntp_global:
           config:
             servers: "{{ ntp_servers }}"
           state: merged
         when: ansible_network_os == 'cisco.ios.ios'

       # --- JUNIPER JUNOS TASKS ---
       - name: Configure NTP servers on Juniper Junos devices
         juniper.device.junos_ntp_global:
           config:
             servers: "{{ ntp_servers }}"
           state: merged
         when: ansible_network_os == 'juniper.device.junos'
   EOF
   ```

3. **Register `ntp.yml` in `site.yml`:**
   ```yaml
   - name: Configure NTP Servers
     ansible.builtin.import_playbook: playbooks/ntp.yml
     tags:
       - ntp
   ```

4. **Commit, push, and verify:**
   ```bash
   git add inventory/group_vars/all/ntp.yml playbooks/ntp.yml site.yml
   git commit -m "feat: add multi-vendor NTP playbook and global group_vars/all/ntp.yml"
   git push origin main
   ```

*Verification:*
1. **GitHub → Actions:** Confirms `Detected feature changes. Launching Template <MASTER_TEMPLATE_ID> with tags: ntp`.
2. **AWX Web UI → Views → Jobs:** `Master-Network-Deploy` runs only the `ntp` tag and succeeds on `CR1`, `CR2`, and `JR1`.
3. **Routers:** Verify with `show running-config | include ntp` (Cisco IOS) and `show configuration system ntp` (Juniper Junos).

> **Day 2 Scalability:** Adding a new feature only requires creating `playbooks/<feature>.yml`, adding its variable file in either `inventory/host_vars/<device>/<feature>.yml` (per-device) or `inventory/group_vars/all/<feature>.yml` (global), and appending a 4-line import block to `site.yml`—no changes to GitHub Actions or AWX are needed.

---

> [← Back to Project Overview](./README.md)

## 11. Integrate LLDAP with TARANAC for Directory-Backed AAA

Instead of managing static local users inside TARANAC, we deploy **LLDAP** (Lightweight LDAP) as a lightweight pod on the existing AWX K3s cluster, connect TARANAC to it over LDAP, and authenticate both direct router SSH logins and Ansible AWX jobs against centralized directory accounts.

---

### 11.1 Deploy LLDAP on the AWX K3s Cluster
Running LLDAP on the AWX K3s cluster (~20 MB RAM, <100 MB disk) avoids installing Docker on EVE-NG and prevents `iptables` `FORWARD` chain conflicts with `pnet0`.

```bash
mkdir -p ~/lldap-k3s && cd ~/lldap-k3s

cat << 'EOF' > lldap.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: lldap
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: lldap-data
  namespace: lldap
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lldap
  namespace: lldap
spec:
  replicas: 1
  selector:
    matchLabels:
      app: lldap
  template:
    metadata:
      labels:
        app: lldap
    spec:
      containers:
        - name: lldap
          image: lldap/lldap:stable
          ports:
            - containerPort: 3890
              name: ldap
            - containerPort: 17170
              name: http
          env:
            - name: TZ
              value: "Asia/Singapore"
            - name: LLDAP_JWT_SECRET
              value: "replace_with_random_32char_secret_1"
            - name: LLDAP_KEY_SEED
              value: "replace_with_random_32char_secret_2"
            - name: LLDAP_LDAP_BASE_DN
              value: "dc=lab,dc=local"
            - name: LLDAP_LDAP_USER_PASS
              value: "P@ssw0rd123"
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: lldap-data
---
apiVersion: v1
kind: Service
metadata:
  name: lldap
  namespace: lldap
spec:
  type: NodePort
  selector:
    app: lldap
  ports:
    - name: ldap
      port: 3890
      targetPort: 3890
      nodePort: 30389
    - name: http
      port: 17170
      targetPort: 17170
      nodePort: 31717
EOF

kubectl apply -f lldap.yaml
```

*Verification:* Run `kubectl get pods,svc -n lldap` and confirm the `lldap` pod shows `1/1 Running` and exposes NodePorts `30389` (LDAP) and `31717` (Web UI).

---

### 11.2 Create Directory Groups and Accounts in LLDAP
Open the LLDAP Web UI at `http://<AWX_VM_IP>:31717` and log in with `admin` / `P@ssw0rd123`:

1. **Create the `netadmins` Group:**
   * Go to **Groups** → **Create a group** → Name: `netadmins` → **Submit**.
2. **Create a Least-Privilege Bind Account (for TARANAC only):**
   * Go to **Users** → **Create a user** → User ID: `taranac_bind`, Email: `taranac_bind@lab.local`, Password: `<bind-password>`.
   * Open `taranac_bind` and add it to the built-in **`lldap_strict_readonly`** group *(grants read-only directory search access without write privileges or router login rights)*.
3. **Create the Directory Network User (for SSH & AWX):**
   * Go to **Users** → **Create a user** → User ID: `awx_ldap_admin`, Email: `awx_ldap_admin@lab.local`, Password: `<ldap-user-password>`.
   * Open `awx_ldap_admin` and add it to the **`netadmins`** group.

*Verification:* Under **Groups** → `netadmins`, confirm `awx_ldap_admin` is listed; under `lldap_strict_readonly`, confirm `taranac_bind` is listed.

---

### 11.3 Validate LDAP Connectivity from the CLI
Before configuring TARANAC, verify that `taranac_bind` can authenticate and query `awx_ldap_admin` over NodePort `30389` (use `-W` to prompt interactively so Bash does not expand special characters in the password):

```bash
sudo apt install -y ldap-utils

ldapsearch -x -H ldap://<AWX_VM_IP>:30389 \
  -D "uid=taranac_bind,ou=people,dc=lab,dc=local" \
  -W \
  -b "dc=lab,dc=local" "(uid=awx_ldap_admin)"
```

*Verification:* Returns `dn: uid=awx_ldap_admin,ou=people,dc=lab,dc=local` and ends with `result: 0 Success`.

---

### 11.4 Configure LLDAP Integration in TARANAC
Open the **TARANAC Web UI** → **Settings** → **LDAP** → **New LDAP Configuration** → select **OpenLDAP** *(LLDAP uses the standard OpenLDAP schema: `posixAccount`/`uid` for users and `groupOfNames`/`cn`/`member` for groups)*.

1. **Connection & Search:**
   * **Config ID / Display Name:** `lldap-lab` / `LLDAP Lab`
   * **Domain Suffix:** `lab.local`
   * **Server URIs:** `ldap://<AWX_VM_IP>:30389`
   * **Bind DN:** `uid=taranac_bind,ou=people,dc=lab,dc=local`
   * **Bind Password:** `<bind-password>`
   * **STARTTLS / Validate TLS:** Both **OFF** *(plain `ldap://`)*
   * **Search Bases:** Add `dc=lab,dc=local`
   * **User / Group Search Filters:** Leave OpenLDAP defaults (`(&(objectClass=posixAccount)(uid={username}))` and `(objectClass=groupOfNames)`)

2. **Synchronization & Attribute Mapping:**
   * **Enable Auto Sync:** Toggle **ON**
   * **Mode:** `Groups → Users`
   * **Create users:** **ON**
   * **User Lifecycle Cleanup:** Toggle **ON** either **Deactivate missing users** *(recommended—disables access while preserving audit/MFA history)* or **Remove stale users** *(hard-deletes the user from TARANAC when removed from LLDAP)*
   * **Attribute Mapping:** Leave all defaults (`uid`, `mail`, `cn`, `member`) unchanged

3. **Selective Group Sync:**
   * Add `cn=netadmins,ou=groups,dc=lab,dc=local` *(note lowercase `ou=groups`)* so only `netadmins` and its members are imported.
   * Click **Create Config**.

4. **Run Initial Sync:**
   * Click **Test Connection** and **Sync Now** on `LLDAP Lab`.
   * *Verification:* **Sync History** shows `completed`, and both `netadmins` (under **Identity → Groups**) and `awx_ldap_admin` (under **Identity → Users**) appear in TARANAC.

---

### 11.5 Map `netadmins` to the TARANAC AAA Policy
1. Go to **AAA** → **Policies** → **Policy Table**.
2. Edit your existing Cisco/Juniper policy rule (or add a new one) to include the synced LDAP group **`netadmins`** under **Who → Groups**, mapped to **TACACS+ Profile:** `General Full Access (priv 15)`.
3. Save and deploy any pending changes.

*Verification:* The rule shows **Enabled** in the Policy Table with no pending deployments on the dashboard.

---

### 11.6 End-to-End Verification (SSH, AWX & User Offboarding)
1. **Direct SSH Test:**
   ```bash
   ssh awx_ldap_admin@192.168.50.186
   ```
   *Verification:* You land directly on `CR1#` (`show privilege` returns `15`), and **TARANAC → LOGGING & REPORTS → AAA Logs** records a **PASS** entry for `awx_ldap_admin`.

2. **AWX Job Test:**
   * In AWX (**Resources** → **Credentials**), update your TACACS+ Machine Credential (or create `LDAP TACACS+ Credentials`) with `awx_ldap_admin` and `<ldap-user-password>`, then attach it to `Master-Network-Deploy`.
   * Launch `Master-Network-Deploy` with **Job Tags:** `ntp`.
   * *Verification:* The job completes with status **Successful** across `CR1`, `CR2`, and `JR1`, and TARANAC logs the configuration session under `awx_ldap_admin`.

3. **User Offboarding Test (Optional):**
   * Delete a test user in LLDAP and click **Sync Now** in TARANAC.
   * *Verification:* The user is removed from `netadmins` and deactivated or deleted in TARANAC according to your Step 11.4 lifecycle setting, immediately revoking router SSH access.

---

> [← Back to Project Overview](./README.md)

## 12. Automated Credential Rotation and Runtime Lookup with HashiCorp Vault

To eliminate static passwords inside AWX and automate credential rotation, we pre-configure dedicated service accounts in **LLDAP**, deploy **HashiCorp Vault** on K3s, configure its **LDAP Secrets Engine** to rotate the `ldap_ansible` service account every 24 hours, and wire AWX to fetch the live password at job runtime using an **AppRole** credential lookup.

### How the Vault LDAP Rotation Chain Works
1. **Secrets Engine (`ldap/`):** Mounts Vault's LDAP plugin.
2. **Password Policy (`network-cli`):** Enforces router-CLI-safe characters so rotated passwords never break Cisco/Juniper SSH or TACACS+ authentication.
3. **LDAP Connection Config (`ldap/config`):** Stores LLDAP's address (`:30389`), search base (`ou=people,dc=lab,dc=local`), the privileged `vault_bind` account, and references the `network-cli` policy.
4. **Static Role (`ldap/static-role/ldap-ansible-role`):** Maps 1-to-1 to the existing `ldap_ansible` user with `rotation_period="24h"`. Every 24 hours (or on manual trigger), Vault binds to LLDAP as `vault_bind`, updates `ldap_ansible`'s password, and serves the live secret to AWX at `ldap/static-cred/ldap-ansible-role`.

---

### 12.1 Pre-Configure LLDAP Service Accounts & Groups
Before deploying Vault, create dedicated LLDAP service accounts for **Vault** and **AWX** to enforce strict separation of duties across directory management, TACACS+ sync, and router automation:

| LLDAP Service Account | Assigned LLDAP Group | Purpose & Least-Privilege Scope |
| :--- | :--- | :--- |
| `taranac_bind` *(from Step 11.2)* | `lldap_strict_readonly` | Read-only directory search for TARANAC LDAP sync (no write rights, no router access) |
| **`vault_bind`** *(new)* | **`lldap_password_manager`** | Privileged bind account for HashiCorp Vault to reset/rotate user passwords in LLDAP (no router login access, not synced to TARANAC) |
| **`ldap_ansible`** *(new)* | **`netadmins`** | Managed automation account synced to TARANAC for AWX router SSH/NETCONF logins; password automatically rotated every 24h by Vault |

Open the **LLDAP Web UI** (`http://<AWX_VM_IP>:31717`) and log in as `admin`:

1. **Verify the `netadmins` Group Exists:**
   * Go to **Groups** and confirm `netadmins` (created in Step 11.2) is present, alongside LLDAP's built-in **`lldap_password_manager`** group.
2. **Create the Vault Bind Service Account (`vault_bind`):**
   * Go to **Users** → **Create a user**:
     * **User ID:** `vault_bind`
     * **Email:** `vault_bind@lab.local`
     * **Password:** `<vault-bind-password>` *(use a strong static password; Vault stores this encrypted inside `ldap/config`)*
     * Click **Submit**.
   * Open the `vault_bind` user profile → under **Group memberships**, add **`lldap_password_manager`**. *(Do **not** add `vault_bind` to `netadmins`.)*
3. **Create the AWX Automation Service Account (`ldap_ansible`):**
   * Go to **Users** → **Create a user**:
     * **User ID:** `ldap_ansible`
     * **Email:** `ldap_ansible@lab.local`
     * **Password:** `<temporary-initial-password>` *(any temporary password—Vault will immediately rotate it once bound to the static role)*
     * Click **Submit**.
   * Open the `ldap_ansible` user profile → under **Group memberships**, add **`netadmins`**. *(Do **not** add `ldap_ansible` to any `lldap_*` admin groups.)*
4. **Sync the New Automation Account into TARANAC:**
   * Open the **TARANAC Web UI** → **Settings** → **LDAP** → **`LLDAP Lab`** and click **Sync Now**.
   * Confirm **`ldap_ansible`** appears under **INFRASTRUCTURE → Identity → Users** as a member of **`netadmins`**, while **`vault_bind`** is excluded by Selective Group Sync (`cn=netadmins,ou=groups,dc=lab,dc=local`).
5. **Validate `vault_bind` Authentication & Lookup from CLI:**
   ```bash
   ldapsearch -x -H ldap://<AWX_VM_IP>:30389 \
     -D "uid=vault_bind,ou=people,dc=lab,dc=local" \
     -W \
     -b "ou=people,dc=lab,dc=local" "(uid=ldap_ansible)"
   ```

*Verification:* `ldapsearch` returns `dn: uid=ldap_ansible,ou=people,dc=lab,dc=local` and ends with `result: 0 Success`, confirming `vault_bind` can authenticate to LLDAP and locate `ldap_ansible` before Vault is configured.

---

### 12.2 Deploy HashiCorp Vault on K3s
Deploy Vault in a dedicated `vault` namespace using persistent `local-path` file storage, an init container for volume permissions, and NodePort `30820`:

```bash
mkdir -p ~/vault-k3s && cd ~/vault-k3s

cat << 'EOF' > vault.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vault
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vault-data
  namespace: vault
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-config
  namespace: vault
data:
  vault.hcl: |
    ui = true
    disable_mlock = true

    storage "file" {
      path = "/vault/file"
    }

    listener "tcp" {
      address     = "0.0.0.0:8200"
      tls_disable = 1
    }

    api_addr = "http://<AWX_VM_IP>:30820"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault
  namespace: vault
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vault
  template:
    metadata:
      labels:
        app: vault
    spec:
      enableServiceLinks: false
      securityContext:
        fsGroup: 1000
      initContainers:
        - name: fix-permissions
          image: busybox:1.36
          command: ["sh", "-c", "chown -R 100:1000 /vault/file"]
          volumeMounts:
            - name: vault-data
              mountPath: /vault/file
      containers:
        - name: vault
          image: hashicorp/vault:latest
          args: ["server"]
          ports:
            - containerPort: 8200
              name: http
          env:
            - name: VAULT_ADDR
              value: "http://127.0.0.1:8200"
          volumeMounts:
            - name: vault-data
              mountPath: /vault/file
            - name: vault-config
              mountPath: /vault/config
      volumes:
        - name: vault-data
          persistentVolumeClaim:
            claimName: vault-data
        - name: vault-config
          configMap:
            name: vault-config
---
apiVersion: v1
kind: Service
metadata:
  name: vault
  namespace: vault
spec:
  type: NodePort
  selector:
    app: vault
  ports:
    - name: http
      port: 8200
      targetPort: 8200
      nodePort: 30820
EOF

kubectl apply -f vault.yaml
```

*Verification:* Run `kubectl get pods,svc -n vault` and confirm the `vault` pod is `1/1 Running` and exposed on NodePort `30820`.

---

### 12.3 Install Native Vault CLI, Persist `VAULT_ADDR`, and Initialize Vault
Install the native `vault` CLI on the Ubuntu host so you can manage Vault directly without wrapping every command in `kubectl exec`:

```bash
sudo apt-get update && sudo apt-get install -y gpg wget lsb-release

wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt-get update && sudo apt-get install -y vault
```

Set `VAULT_ADDR` globally for all users (`lawi` and `root`):

```bash
echo 'export VAULT_ADDR="http://<AWX_VM_IP>:30820"' | sudo tee /etc/profile.d/vault.sh
source /etc/profile.d/vault.sh
```

Initialize Vault (using 1 key share/threshold for home-lab simplicity), save the printed **Unseal Key** and **Initial Root Token**, then unseal and log in:

```bash
vault operator init -key-shares=1 -key-threshold=1
vault operator unseal <UNSEAL_KEY>
vault login <INITIAL_ROOT_TOKEN>
```

*Verification:* Run `vault status` and confirm `Initialized: true` and `Sealed: false`.

---

### 12.4 Configure Automatic Unseal for Lab Reboots (Root Cron Job)
> **Lab-Only Caveat:** Storing the unseal key on the same VM is a convenience trade-off for a single-node home lab. Production deployments should use Cloud KMS or Vault Transit Auto-Unseal.

1. **Store the unseal key in a root-only file:**
   ```bash
   echo '<UNSEAL_KEY>' | sudo tee /root/.vault-unseal-key > /dev/null
   sudo chmod 600 /root/.vault-unseal-key
   sudo chown root:root /root/.vault-unseal-key
   ```

2. **Create the auto-unseal script:**
   ```bash
   sudo tee /usr/local/bin/vault-autounseal.sh > /dev/null << 'EOF'
   #!/usr/bin/env bash
   set -euo pipefail

   VAULT_URL="http://<AWX_VM_IP>:30820"
   KEY_FILE="/root/.vault-unseal-key"

   # Exit quietly if Vault is not up yet
   STATUS=$(curl -s --max-time 3 "${VAULT_URL}/v1/sys/seal-status" || true)
   [ -z "$STATUS" ] && exit 0

   # Unseal only if Vault reports sealed=true
   if echo "$STATUS" | grep -q '"sealed":true'; then
     UNSEAL_KEY=$(cat "$KEY_FILE")
     curl -s --max-time 5 -X PUT \
       -d "{\"key\": \"${UNSEAL_KEY}\"}" \
       "${VAULT_URL}/v1/sys/unseal" > /dev/null
     logger -t vault-autounseal "Vault was sealed; auto-unseal triggered."
   fi
   EOF

   sudo chmod 700 /usr/local/bin/vault-autounseal.sh
   ```

3. **Schedule the 1-minute root cron job:**
   ```bash
   (sudo crontab -l 2>/dev/null | grep -v 'vault-autounseal.sh'; echo '* * * * * /usr/local/bin/vault-autounseal.sh') | sudo crontab -
   ```

4. **Test auto-unseal live:**
   ```bash
   vault operator seal
   vault status   # Confirm Sealed: true
   sleep 65
   vault status   # Confirm Sealed: false
   grep vault-autounseal /var/log/syslog | tail -n 3
   ```

*Verification:* `vault status` returns `Sealed: false` within 60 seconds, and `/var/log/syslog` logs `Vault was sealed; auto-unseal triggered.`

---

### 12.5 Configure Vault LDAP Secrets Engine, Password Policy & Static Role
Run the following four steps in order from your authenticated host shell:

1. **Enable the LDAP Secrets Engine:**
   ```bash
   vault secrets enable ldap
   ```

2. **Create a Router-Safe Password Policy (`network-cli`):**
   *(Avoids special characters such as `?`, quotes, or shell-breaking symbols that can disrupt Cisco IOS/Juniper Junos CLI or TACACS+ parsing.)*
   ```bash
   vault write sys/policies/password/network-cli-policy policy=- << 'EOF'
   length = 20
   rule "charset" { charset = "abcdefghijklmnopqrstuvwxyz", min-chars = 4 }
   rule "charset" { charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ", min-chars = 4 }
   rule "charset" { charset = "0123456789", min-chars = 4 }
   rule "charset" { charset = "!@#%^_-+=", min-chars = 2 }
   EOF
   ```

3. **Connect Vault to LLDAP (`ldap/config`):**
   ```bash
   vault write ldap/config \
     binddn="uid=vault_bind,ou=people,dc=lab,dc=local" \
     bindpass="<vault-bind-password>" \
     url="ldap://<AWX_VM_IP>:30389" \
     userdn="ou=people,dc=lab,dc=local" \
     userattr="uid" \
     schema="openldap" \
     password_policy="network-cli-policy"
   ```

4. **Bind `awx` to a 24-Hour Static Role (`vault-ldap-secret-role`):**
   *(Each LDAP static role maps 1-to-1 to a single existing LDAP account; to manage additional service accounts such as EDA, create a separate static role per user.)*
   ```bash
   vault write ldap/static-role/vault-ldap-secret-role \
     dn="uid=awx,ou=people,dc=lab,dc=local" \
     username="awx" \
     rotation_period="24h"
   ```

*Verification:* Read the managed credential from Vault and confirm it returns `username: awx`, a generated 20-character `password`, and `ttl` counting down from `24h`:
```bash
vault read ldap/static-cred/vault-ldap-secret-role
```

---

### 12.6 Configure Scoped Vault Policy & AppRole for AWX
Grant AWX least-privilege read access strictly to the `vault-ldap-secret-role` credential path using **AppRole** authentication:

```bash
# 1. Create a read-only policy scoped to ldap-ansible-role
vault policy write awx-read-ldap - << 'EOF'
path "ldap/static-cred/vault-ldap-secret-role" {
  capabilities = ["read"]
}
EOF

# 2. Enable AppRole auth and bind awx-role to the policy
vault auth enable approle
vault write auth/approle/role/awx-ldap-vault-approle \
  token_policies="awx-read-ldap" \
  token_ttl=10m \
  token_max_ttl=30m

# 3. Retrieve Role ID and generate a Secret ID for AWX
vault read auth/approle/role/awx-ldap-vault-approle/role-id
vault write -f auth/approle/role/awx-ldap-vault-approle/secret-id
```

*Verification:* Save the printed `role_id` and `secret_id` UUIDs for the AWX configuration in Step 12.7.

---

### 12.7 Configure HashiCorp Vault Secret Lookup in AWX

#### Step 1: Create the External Vault Lookup Credential
1. Open the **AWX Web UI** (`http://<AWX_VM_IP>:32000`) and go to **Resources** → **Credentials** → **Add**.
2. Fill in the **HashiCorp Vault Secret Lookup** fields:
   * **Name:** `Vault-LDAP-Lookup`
   * **Credential Type:** `HashiCorp Vault Secret Lookup`
   * **Server URL:** `http://<AWX_VM_IP>:30820`
   * **AppRole Role ID:** `<ROLE_ID>` *(from Step 12.6)*
   * **AppRole Secret ID:** `<SECRET_ID>` *(from Step 12.6)*
   * **Path to Auth:** *(Leave blank—defaults to `approle`)*
   * **API Version:** **`v1`** *(Critical: selecting `v2` inserts `/data/` into the URL and fails with `404` against the LDAP secrets engine)*
3. Click **Save**, then click **Test** and enter:
   * **Name of Secret Backend:** `ldap`
   * **Path to Secret:** `static-cred/vault-ldap-secret-role`
   * **Path to Auth:** *(Leave blank)*
   * **Key Name:** `password`
   * **Secret Version (v2 only):** *(Leave blank)*
4. Click **Run** and confirm the green **Test passed** notification appears.

#### Step 2: Link the Dynamic Lookup to Your Router Machine Credential
1. Go to **Resources** → **Credentials** → **Add** (or edit your existing `LDAP_Credential`).
   * **Name:** `LDAP_Credential`
   * **Credential Type:** `Machine`
   * **Username:** `ldap_ansible`
2. Click the **Key** icon next to the **Password** field:
   * Select **`Vault-LDAP-Lookup`** and click **Next**.
   * **Name of Secret Backend:** `ldap`
   * **Path to Secret:** `static-cred/vault-ldap-secret-role`
   * **Key Name:** `password`
   * Click **Test** to verify **Test passed**, click **OK**, and click **Save**.
3. Attach `LDAP_Credential` to **`Master-Network-Deploy`** (removing any older static credentials).

*Verification:* On `LDAP_Credential`, the **Password** field displays the linked `Vault-LDAP-Lookup` badge rather than a static encrypted value.

---

### 12.8 Enable Real-Time Audit Logging & Verify Live Rotation End-to-End
Enable Vault's `file` audit backend directed to `stdout` so every secret access and rotation is streamed live through Kubernetes pod logs:

```bash
vault audit enable file file_path=stdout
```
*(If Vault returns `path already in use`, run `vault audit list -detailed` to verify `file_path:stdout` is already active.)*

1. **Terminal 1 — Stream live Vault audit events:**
   ```bash
   kubectl logs -n vault deploy/vault -f | grep --line-buffered -E "approle/login|static-cred/ldap-ansible-role|rotate-role"
   ```

2. **Terminal 2 — Trigger an immediate password rotation in LLDAP:**
   ```bash
   vault write -f ldap/rotate-role/ldap-ansible-role
   ```

3. **AWX Web UI — Launch `Master-Network-Deploy` (e.g., with Job Tags: `ntp`):**

*Verification:*
1. **Terminal 1 (Vault Audit Stream):** Logs `"path":"ldap/rotate-role/ldap-ansible-role"`, followed immediately by `"path":"auth/approle/login"` and `"path":"ldap/static-cred/ldap-ansible-role"` when AWX launches the job.
2. **AWX Web UI → Views → Jobs:** `Master-Network-Deploy` completes with status **Successful** across `CR1`, `CR2`, and `JR1` using the freshly rotated password without any manual credential edits.
3. **TARANAC Web UI → AAA Logs:** Records a **PASS** authentication and full command accounting session for `ldap_ansible` validated live against LLDAP.

---

> [← Back to Project Overview](./README.md)

## 13. Policy-as-Code CI/CD Gate with Open Policy Agent (Conftest)

Before GitHub Actions calls the AWX REST API (`POST /launch/`), we place an automated **Open Policy Agent (OPA)** validation gate using **Conftest** on the self-hosted runner. On every push to `main`, Conftest evaluates all inventory files together (`inventory/hosts.ini`, `host_vars/`, and `group_vars/`) against `policies/loopback.rego` to enforce `/32` masks on Router-ID loopbacks (`Lo0` / `Loopback0`) and block duplicate or conflicting loopback IP addresses before AWX ever touches a router.

---

### 13.1 Install Conftest on the Self-Hosted Runner (AWX VM)
Install the latest Linux binary on the Ubuntu AWX VM so the local GitHub Actions runner can execute `conftest` directly:

```bash
LATEST_VERSION=$(curl -s https://api.github.com/repos/open-policy-agent/conftest/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')

wget "https://github.com/open-policy-agent/conftest/releases/download/v${LATEST_VERSION}/conftest_${LATEST_VERSION}_Linux_x86_64.tar.gz"
tar xzf "conftest_${LATEST_VERSION}_Linux_x86_64.tar.gz"
sudo mv conftest /usr/local/bin/
rm -f "conftest_${LATEST_VERSION}_Linux_x86_64.tar.gz" LICENSE README.md
```

*Verification:* Run `conftest --version` and confirm the installed version is printed.

---

### 13.2 Create the OPA Rego Policy (`policies/loopback.rego`)
Create a `policies/` directory at the repository root with three validation rules covering both Cisco (`10.100.100.1 255.255.255.255`) and Juniper (`10.255.10.3/32`) address formats:

1. **Router-ID `/32` Enforcement:** Any `Lo0`, `lo0`, `Loopback0`, or `Loopback 0` interface must end with `/32` or `255.255.255.255`.
2. **No Duplicate Loopback IPs:** No two loopback interfaces across any device may share the same IPv4 address.
3. **No Cross-Inventory Conflicts:** No loopback IP may conflict with an IP already defined in `inventory/hosts.ini` or any other YAML file under `inventory/`.

```bash
mkdir -p policies

cat << 'EOF' > policies/loopback.rego
package main

import rego.v1

# Helper 1: Match Lo0, lo0, Loopback0, or "Loopback 0"
is_lo0(name) if {
	replace(lower(name), " ", "") in {"lo0", "loopback0"}
}

# Helper 2: Get just the IP address (works for both Cisco and Juniper formats)
# "10.100.100.1 255.255.255.255" -> "10.100.100.1"
# "10.255.10.3/32"               -> "10.255.10.3"
get_ip(raw) := split(split(trim_space(raw), " ")[0], "/")[0]

# Rule 1: Lo0 / Loopback 0 must use a /32 mask
deny contains msg if {
	some file in input
	some iface in file.contents.loopback_interfaces
	is_lo0(iface.name)

	ip_str := trim_space(iface.ipv4)
	not endswith(ip_str, "/32")
	not endswith(ip_str, " 255.255.255.255")

	msg := sprintf("%s (%s): '%s' must use a /32 or 255.255.255.255 mask", [
		file.path, iface.name, iface.ipv4,
	])
}

# Rule 2: Fail if two loopback interfaces share the same IP
deny contains msg if {
	some file1 in input
	some file2 in input
	some i, iface1 in file1.contents.loopback_interfaces
	some j, iface2 in file2.contents.loopback_interfaces

	# Avoid comparing an interface to itself or reporting the same pair twice
	sprintf("%s:%d", [file1.path, i]) < sprintf("%s:%d", [file2.path, j])

	ip := get_ip(iface1.ipv4)
	ip == get_ip(iface2.ipv4)

	msg := sprintf("Duplicate loopback IP '%s' in %s (%s) and %s (%s)", [
		ip, file1.path, iface1.name, file2.path, iface2.name,
	])
}

# Rule 3: Fail if a loopback IP conflicts with hosts.ini or any other inventory file
deny contains msg if {
	some lb_file in input
	some iface in lb_file.contents.loopback_interfaces
	ip := get_ip(iface.ipv4)

	some other_file in input
	other_file.path != lb_file.path
	not other_file.contents.loopback_interfaces

	walk(other_file.contents, [_, val])
	is_string(val)
	get_ip(val) == ip

	msg := sprintf("Conflict: loopback IP '%s' in %s is already used in %s", [
		ip, lb_file.path, other_file.path,
	])
}
EOF
```

*Verification:* Confirm `policies/loopback.rego` exists at the repository root alongside `inventory/` and `playbooks/`.

---

### 13.3 Integrate the OPA Gate into `.github/workflows/trigger-awx.yml`
Insert the **OPA Policy Check** step immediately after `actions/checkout@v4` and **before** the AWX API trigger step. Because `inventory/hosts.ini` uses Ansible INI syntax, the step extracts its active IPv4 addresses into a temporary YAML list (`/tmp/hosts.ini.yml`) and passes it alongside all `inventory/` YAML files to `conftest test --combine`:

```yaml
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

      # Run OPA policy checks first; if any rule fails, the job aborts and AWX is never called
      - name: OPA Policy Check (Loopback /32 & Duplicate IPs)
        run: |
          # Turn IPs from hosts.ini into a simple YAML list for Conftest
          echo "hosts_ini_ips:" > /tmp/hosts.ini.yml
          { grep -v '^\s*#' inventory/hosts.ini | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || true; } | sed 's/^/  - /' >> /tmp/hosts.ini.yml

          # Check hosts.ini + all YAML files under inventory/
          conftest test --combine -p policies/ /tmp/hosts.ini.yml $(find inventory -name '*.yml' -o -name '*.yaml')

      # Detect modified playbooks or variable files, extract matching tags, and trigger the master AWX template
      - name: Detect changed features and launch AWX
        env:
          AWX_URL: ${{ secrets.AWX_BASE_URL }}
          AWX_TOKEN: ${{ secrets.AWX_API_TOKEN }}
          TEMPLATE_ID: 17 # Master-Network-Deploy (site.yml) Job Template ID
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
            echo "Detected feature changes. Launching Template $TEMPLATE_ID with tags: $TAGS"
            curl -f -s -S -X POST "$AWX_URL/api/v2/job_templates/$TEMPLATE_ID/launch/" \
              -H "Authorization: Bearer $AWX_TOKEN" \
              -H "Content-Type: application/json" \
              -d "{\"job_tags\": \"$TAGS\"}"
          else
            # Skip AWX cleanly for docs or unrelated repo changes
            echo "No playbook, host_vars, or global group_vars changes detected. Skipping AWX."
          fi
```

*(Note: Because the dynamic tag regex only watches `playbooks/`, `inventory/host_vars/<device>/`, and `inventory/group_vars/all/`, commits that only modify `policies/` cleanly skip AWX.)*

---

### 13.4 Verify Policy Enforcement Locally & End-to-End

1. **Test the clean Source of Truth locally (Linux or Windows Git Bash):**
   *(If running `conftest.exe` locally from your project folder on Windows, add `conftest.exe` to `.gitignore` and invoke `./conftest.exe`.)*
   ```bash
   echo "hosts_ini_ips:" > /tmp/hosts.ini.yml
   { grep -v '^\s*#' inventory/hosts.ini | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || true; } | sed 's/^/  - /' >> /tmp/hosts.ini.yml
   conftest test --combine -p policies/ /tmp/hosts.ini.yml $(find inventory -name '*.yml' -o -name '*.yaml')
   ```
   *Expected Output:* `1 test, 1 passed, 0 warnings, 0 failures, 0 exceptions` (exit code `0`).

2. **Test Failure Scenarios (Commit & Push to Verify CI Gate):**
   * **Non-`/32` Mask Test:** Change a router's `Loopback0` or `lo0` mask to `/24` or `255.255.255.0`.
   * **Duplicate IP Test:** Assign `CR1`'s loopback IP (`10.100.100.1`) to a new or existing router's `loopback_interfaces.yml`.
   * **Inventory Conflict Test:** Assign an existing `ansible_host` IP from `inventory/hosts.ini` to a loopback interface.

*Verification:*
1. **GitHub → Actions (`Trigger AWX Selectively`):** The **OPA Policy Check** step exits with status `1` and prints the exact `FAIL - Combined - main - ...` violation message from `policies/loopback.rego`.
2. **AWX Web UI → Views → Jobs:** The **Detect changed features and launch AWX** step is skipped completely—no job is triggered in AWX and live routers remain untouched.
3. **Recovery:** Correct the IP or mask in the variable file and push again; **OPA Policy Check** passes and AWX automatically launches `Master-Network-Deploy` with `job_tags: loopback_interfaces`.

---

> [← Back to Project Overview](./README.md)

## 14. Ephemeral GitHub App Tokens with HashiCorp Vault

To eliminate static GitHub SSH Deploy Keys from AWX and achieve zero-standing Source Control credentials, we register a scoped **GitHub App**, update the Vault Kubernetes manifest (`vault.yaml`) to download and mount `vault-plugin-secrets-github` via an init container, roll out Vault on K3s, configure a read-only permission set and isolated AppRole (`awx-github-vault-approle`), and migrate AWX from SSH to HTTPS synchronization.

---

### 14.1 Create & Install the GitHub App on GitHub
1. **Register a New GitHub App:**
   * Open GitHub **Settings** → **Developer settings** → **GitHub Apps** → **New GitHub App**.
   * **GitHub App name:** `<your-unique-app-name>` *(e.g., `awx-sot-vault-sync`)*
   * **Homepage URL:** `https://github.com/<your-username>/<your-repo>`
   * **Webhook:** Uncheck **Active** *(Vault only calls GitHub outbound to mint tokens; no inbound webhook is needed)*.
   * **Permissions → Repository permissions:**
     * **Contents:** `Read-only` *(all other permissions remain `No access`)*
   * **Where can this GitHub App be installed?** Select **Only on this account**.
   * Click **Create GitHub App**.
2. **Record the App ID & Generate a Private Key:**
   * On the app's **General** page, copy the numeric **App ID** (e.g., `5920246`).
   * Scroll to **Private keys** and click **Generate a private key**. Save the downloaded `.pem` file securely.
3. **Install the App on Your Repository & Record the Installation ID:**
   * Click **Install App** in the left sidebar → select your account.
   * Choose **Only select repositories** and pick your SOT repository (e.g., `minlawi/awx`) → click **Install**.
   * Copy the numeric **Installation ID** from the browser URL (`https://github.com/settings/installations/<INSTALLATION_ID>`, e.g., `185748030`).
4. **Copy the Private Key to the AWX VM for Vault Upload:**
   ```bash
   # From your workstation, copy the .pem file to /tmp/ on the AWX VM
   scp ~/Downloads/<your-app>.private-key.pem <user>@<AWX_VM_IP>:/tmp/github-app.pem
   ```

*Verification:* Confirm `/tmp/github-app.pem` exists on the AWX VM and you have noted both your **App ID** and **Installation ID**.

---

### 14.2 Update `vault.yaml` for the GitHub Secrets Plugin
Update `~/vault-k3s/vault.yaml` to:
1. Add `plugin_directory = "/vault/plugins"` inside the `vault-config` `ConfigMap`.
2. Add a `download-github-plugin` init container that downloads the `vault-plugin-secrets-github` binary into a shared `/vault/plugins` volume on pod startup.
3. Mount the `vault-plugins` volume into both the init container and the main `vault` container.

```bash
cd ~/vault-k3s

cat << 'EOF' > vault.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vault
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vault-data
  namespace: vault
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-config
  namespace: vault
data:
  vault.hcl: |
    ui = true
    disable_mlock = true
    plugin_directory = "/vault/plugins"

    storage "file" {
      path = "/vault/file"
    }

    listener "tcp" {
      address     = "0.0.0.0:8200"
      tls_disable = 1
    }

    api_addr = "http://<AWX_VM_IP>:30820"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault
  namespace: vault
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vault
  template:
    metadata:
      labels:
        app: vault
    spec:
      enableServiceLinks: false
      securityContext:
        fsGroup: 1000
      initContainers:
        - name: fix-permissions
          image: busybox:1.36
          command: ["sh", "-c", "chown -R 100:1000 /vault/file"]
          volumeMounts:
            - name: vault-data
              mountPath: /vault/file
        - name: download-github-plugin
          image: alpine:3.19
          command:
            - sh
            - -c
            - |
              set -e
              PLUGIN_VER="2.1.0"
              wget -qO /tmp/plugin.tar.gz "https://github.com/martinbaillie/vault-plugin-secrets-github/releases/download/v${PLUGIN_VER}/vault-plugin-secrets-github_${PLUGIN_VER}_linux_amd64.tar.gz"
              tar -xzf /tmp/plugin.tar.gz -C /vault/plugins vault-plugin-secrets-github
              chmod 755 /vault/plugins/vault-plugin-secrets-github
              rm -f /tmp/plugin.tar.gz
          volumeMounts:
            - name: vault-plugins
              mountPath: /vault/plugins
      containers:
        - name: vault
          image: hashicorp/vault:latest
          args: ["server"]
          ports:
            - containerPort: 8200
              name: http
          env:
            - name: VAULT_ADDR
              value: "http://127.0.0.1:8200"
          volumeMounts:
            - name: vault-data
              mountPath: /vault/file
            - name: vault-config
              mountPath: /vault/config
            - name: vault-plugins
              mountPath: /vault/plugins
      volumes:
        - name: vault-data
          persistentVolumeClaim:
            claimName: vault-data
        - name: vault-config
          configMap:
            name: vault-config
        - name: vault-plugins
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: vault
  namespace: vault
spec:
  type: NodePort
  selector:
    app: vault
  ports:
    - name: http
      port: 8200
      targetPort: 8200
      nodePort: 30820
EOF
```

---

### 14.3 Roll Out the Updated Vault Deployment & Verify Plugin Binary
Apply the updated manifest, force a clean rollout so the `ConfigMap` change (`plugin_directory`) takes effect, and confirm the plugin binary is mounted and Vault is unsealed:

```bash
# 1. Apply the updated manifest
kubectl apply -f ~/vault-k3s/vault.yaml

# 2. Restart the Deployment so the pod picks up the updated vault.hcl ConfigMap
kubectl rollout restart -n vault deploy/vault

# 3. Watch the rollout complete
kubectl rollout status -n vault deploy/vault
kubectl get pods -n vault
```

Verify the plugin binary inside the running pod and confirm Vault is unsealed (either automatically by the Step 12.4 cron job within 60 seconds, or manually via `vault operator unseal`):

```bash
kubectl exec -n vault deploy/vault -c vault -- ls -lh /vault/plugins/vault-plugin-secrets-github
vault status
```

*Verification:* `kubectl get pods -n vault` shows `1/1 Running`, `ls -lh` displays the executable `/vault/plugins/vault-plugin-secrets-github` binary, and `vault status` reports `Sealed: false`.

---

### 14.4 Register & Enable the Vault GitHub Secrets Plugin
Capture the plugin's SHA-256 checksum directly from the pod, register it in Vault's plugin catalog, and enable the `github` secrets engine:

```bash
PLUGIN_SHA=$(kubectl exec -n vault deploy/vault -c vault -- sha256sum /vault/plugins/vault-plugin-secrets-github | awk '{print $1}')
echo "$PLUGIN_SHA"

vault plugin register \
  -sha256="${PLUGIN_SHA}" \
  -command="vault-plugin-secrets-github" \
  secret github

vault secrets enable -path=github github
```

*Verification:* Run `vault secrets list` and confirm `github/` is enabled.

---

### 14.5 Configure the GitHub App Signing Key & Permission Set
Upload the GitHub App ID (`5920246`) and private key (`/tmp/github-app.pem`) into Vault, securely shred the temporary `.pem` file from disk, and create a read-only permission set scoped strictly to `minlawi/awx` (`InstallationID: 185748030`):

```bash
vault write github/config \
  app_id="5920246" \
  prv_key=@./tmp/github-app.pem

shred -u /tmp/github-app.pem

vault write github/permissionset/awx-github-app - << 'EOF'
{
  "installation_id": 185748030,
  "repositories": ["awx"],
  "permissions": {
    "contents": "read"
  }
}
EOF
```

*Verification:* Test dynamic 1-hour token minting directly from the CLI:
```bash
vault read github/token/awx-github-app
```
Confirm Vault returns a fresh `ghs_...` token with `permissions: map[contents:read]`.

---

### 14.6 Create the Scoped Vault Policy & Isolated AppRole
Create a dedicated policy (`awx-read-github`) and AppRole (`awx-github-vault-approle`) completely isolated from the LDAP AppRole:

```bash
vault policy write awx-read-github - << 'EOF'
path "github/token/awx-github-app" {
  capabilities = ["read"]
}
EOF

vault write auth/approle/role/awx-github-vault-approle \
  token_policies="awx-read-github" \
  token_ttl=10m \
  token_max_ttl=30m

vault read auth/approle/role/awx-github-vault-approle/role-id
vault write -f auth/approle/role/awx-github-vault-approle/secret-id
```

*Verification:* Save the printed `role_id` and `secret_id` UUIDs for AWX.

---

### 14.7 Configure AWX Lookup & Switch Project to HTTPS
1. **Create `Vault-GitHub-Lookup` (`Resources` → `Credentials` → `Add`):**
   * **Credential Type:** `HashiCorp Vault Secret Lookup`
   * **Server URL:** `http://<AWX_VM_IP>:30820`
   * **AppRole Role ID / Secret ID:** Paste values from Step 14.6
   * **API Version:** **`v1`**
   * Save and click **Test** with **Backend:** `github`, **Path:** `token/awx-github-app`, **Key Name:** `token` → confirm **Test passed**.
2. **Create `GitHub App Ephemeral Token` (`Resources` → `Credentials` → `Add`):**
   * **Credential Type:** `Source Control`
   * **Username:** `x-access-token`
   * **Password:** Click the **Key** icon → link **`Vault-GitHub-Lookup`** (`github` / `token/awx-github-app` / `token`) → Save.
3. **Update `Network-Automation-SOT` (`Resources` → `Projects` → `Edit`):**
   * **Source Control URL:** `https://github.com/minlawi/awx.git`
   * **Source Control Credential:** `GitHub App Ephemeral Token`
   * Ensure **Update Revision on Launch** is checked and click **Save**.
4. **Remove Legacy SSH Keys:** Delete the old Deploy Key from GitHub (**Settings** → **Deploy keys**) and remove `GitHub SSH Key` from AWX (**Resources** → **Credentials**).

*Verification:* Confirm **Source Control Update** on `Network-Automation-SOT`, **Sync** on `Git-SOT-Inventory`, and a full `Master-Network-Deploy` run all finish **Successful** (green), while `kubectl logs -n vault deploy/vault -f` logs `auth/approle/login` followed by `github/token/awx-github-app`.

---

> [← Back to Project Overview](./README.md)

## 15. Migrate Single-Node Vault (File) to a 3-Node Raft Cluster on K3s

To transition HashiCorp Vault from a single-node `Deployment` (`storage "file"`) to a 3-node High-Availability `StatefulSet` (`storage "raft"`) with **zero data loss**, we use `vault operator migrate` to copy all existing secrets engines (`ldap/`, `github/`), AppRoles, policies, and Shamir seal configuration directly into Raft integrated storage while preserving the GitHub plugin (`v2.3.2`) and existing `:30820` NodePort Service.

---

### 15.1 Pre-Migration Checks & Full Backup
Verify your current Vault state, StorageClass, and available disk space before making changes:

```bash
kubectl get all,pvc,cm -n vault
vault status
kubectl get sc
df -h /var/lib/rancher/k3s/storage
```

Retrieve the exact host directory backing `pvc/vault-data` by querying both `.spec.local.path` and `.spec.hostPath.path` (which handles both K3s `local-path` PV formats automatically):

```bash
PV_NAME=$(kubectl get pvc vault-data -n vault -o jsonpath='{.spec.volumeName}')
PVC_DIR=$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.local.path}{.spec.hostPath.path}')
echo "$PVC_DIR"
```

*Verification:* Confirm `echo "$PVC_DIR"` prints a single valid host path (e.g., `/var/lib/rancher/k3s/storage/pvc-..._vault_vault-data`) and `sudo ls -la "$PVC_DIR"` shows Vault's subdirectories (`audit`, `auth`, `core`, `logical`, `sys`).

Back up your Kubernetes manifests and the raw `/vault/file` data:

```bash
mkdir -p ~/vault-file-backup
kubectl get deploy,cm,svc,pvc -n vault -o yaml > ~/vault-file-backup/vault-k8s-backup.yaml
sudo tar -czf ~/vault-file-backup/vault-file-data.tar.gz -C "$PVC_DIR" .
ls -lh ~/vault-file-backup/
```

*Verification:* Confirm both `vault-k8s-backup.yaml` and `vault-file-data.tar.gz` exist and are non-empty.

---

### 15.2 Stop the Existing Single-Node Vault
Scale `deploy/vault` to `0` so no writes occur to `/vault/file` during migration:

```bash
kubectl scale deploy/vault -n vault --replicas=0
kubectl get pods -n vault
```

*Verification:* Confirm no Vault pods are running.

---

### 15.3 Create the Headless Service & Pre-Create `data-vault-0` PVC
* `publishNotReadyAddresses: true` allows Raft peers to resolve `vault-0.vault-internal` even while sealed.
* Pre-creating `data-vault-0` (matching the `StatefulSet` `volumeClaimTemplates` naming convention `<template-name>-<pod-name>`) lets us migrate data into it before `vault-0` starts.

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: vault-internal
  namespace: vault
  labels:
    app: vault
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  ports:
    - name: http
      port: 8200
      targetPort: 8200
    - name: internal
      port: 8201
      targetPort: 8201
  selector:
    app: vault
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-vault-0
  namespace: vault
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
EOF
```

---

### 15.4 Run `vault operator migrate` (`file` → `raft`)
> **Important Gotcha:** Do **not** mount `/vault/file` with `readOnly: true`. Vault writes a temporary lock file (`/vault/file/core/_migration...`) to the source backend during migration, which fails with `read-only file system` if mounted read-only. If you ever need to retry this pod, ensure `/vault/data/*` is wiped first (`rm -rf /vault/data/*`) so partial Raft state does not block the retry.

Deploy the one-shot migration pod:

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: vault-migrate
  namespace: vault
spec:
  restartPolicy: Never
  securityContext:
    fsGroup: 1000
  initContainers:
    - name: fix-permissions
      image: busybox:1.36
      command: ["sh", "-c", "rm -rf /vault/data/* && chown -R 100:1000 /vault/data"]
      volumeMounts:
        - name: raft-data
          mountPath: /vault/data
  containers:
    - name: migrate
      image: hashicorp/vault:latest
      securityContext:
        runAsUser: 100
        runAsGroup: 1000
      command:
        - sh
        - -c
        - |
          cat << 'HCL' > /tmp/migrate.hcl
          storage_source "file" {
            path = "/vault/file"
          }
          storage_destination "raft" {
            path    = "/vault/data"
            node_id = "vault-0"
          }
          cluster_addr = "http://vault-0.vault-internal:8201"
          HCL
          vault operator migrate -config=/tmp/migrate.hcl
      volumeMounts:
        - name: old-file-data
          mountPath: /vault/file
        - name: raft-data
          mountPath: /vault/data
  volumes:
    - name: old-file-data
      persistentVolumeClaim:
        claimName: vault-data
    - name: raft-data
      persistentVolumeClaim:
        claimName: data-vault-0
EOF
```

Watch the logs until it prints `Success! All of the keys have been migrated.`, then delete the temporary pod:

```bash
kubectl logs -n vault -f vault-migrate
kubectl delete pod vault-migrate -n vault
```

*Verification:* Migration logs confirm all `auth/`, `logical/`, `sys/`, and `audit/` paths were copied into Raft and `vault-migrate` is deleted.

---

### 15.5 Update `vault-config` & Deploy the 3-Node `StatefulSet`
Each pod shares the same `vault.hcl` ConfigMap while receiving its unique `VAULT_RAFT_NODE_ID`, `VAULT_API_ADDR`, and `VAULT_CLUSTER_ADDR` via environment variables. Both `fix-permissions` and `download-github-plugin` (`v2.3.2`) initContainers are preserved.

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-config
  namespace: vault
data:
  vault.hcl: |
    ui = true
    disable_mlock = true
    plugin_directory = "/vault/plugins"

    storage "raft" {
      path = "/vault/data"
      retry_join {
        leader_api_addr = "http://vault-0.vault-internal:8200"
      }
      retry_join {
        leader_api_addr = "http://vault-1.vault-internal:8200"
      }
      retry_join {
        leader_api_addr = "http://vault-2.vault-internal:8200"
      }
    }

    listener "tcp" {
      address         = "0.0.0.0:8200"
      cluster_address = "0.0.0.0:8201"
      tls_disable     = 1
    }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: vault
  namespace: vault
spec:
  serviceName: vault-internal
  replicas: 3
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app: vault
  template:
    metadata:
      labels:
        app: vault
    spec:
      enableServiceLinks: false
      securityContext:
        fsGroup: 1000
      initContainers:
        - name: fix-permissions
          image: busybox:1.36
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c", "chown -R 100:1000 /vault/data"]
          volumeMounts:
            - name: data
              mountPath: /vault/data
        - name: download-github-plugin
          image: curlimages/curl:8.10.1
          imagePullPolicy: IfNotPresent
          command:
            - sh
            - -c
            - |
              curl -fsSL -o /vault/plugins/vault-plugin-secrets-github \
                https://github.com/martinbaillie/vault-plugin-secrets-github/releases/download/v2.3.2/vault-plugin-secrets-github-linux-amd64
              chmod 755 /vault/plugins/vault-plugin-secrets-github
          volumeMounts:
            - name: vault-plugins
              mountPath: /vault/plugins
      containers:
        - name: vault
          image: hashicorp/vault:latest
          imagePullPolicy: IfNotPresent
          args: ["server"]
          env:
            - name: HOSTNAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: VAULT_ADDR
              value: "http://127.0.0.1:8200"
            - name: VAULT_RAFT_NODE_ID
              value: "$(HOSTNAME)"
            - name: VAULT_API_ADDR
              value: "http://$(HOSTNAME).vault-internal:8200"
            - name: VAULT_CLUSTER_ADDR
              value: "http://$(HOSTNAME).vault-internal:8201"
          ports:
            - containerPort: 8200
              name: http
            - containerPort: 8201
              name: internal
          volumeMounts:
            - name: data
              mountPath: /vault/data
            - name: vault-config
              mountPath: /vault/config
            - name: vault-plugins
              mountPath: /vault/plugins
      volumes:
        - name: vault-config
          configMap:
            name: vault-config
        - name: vault-plugins
          emptyDir: {}
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes:
          - ReadWriteOnce
        storageClassName: local-path
        resources:
          requests:
            storage: 1Gi
EOF
```

Wait until all three pods are `1/1 Running`:

```bash
kubectl get pods -n vault -w
```

---

### 15.6 Unseal the Cluster & Verify Quorum
Unseal `vault-0` first using your existing Shamir unseal key so it elects itself as the Raft leader, wait ~5 seconds, then unseal `vault-1` and `vault-2`:

```bash
kubectl exec -n vault vault-0 -- vault operator unseal '<YOUR_UNSEAL_KEY>'
sleep 5
kubectl exec -n vault vault-1 -- vault operator unseal '<YOUR_UNSEAL_KEY>'
kubectl exec -n vault vault-2 -- vault operator unseal '<YOUR_UNSEAL_KEY>'
```

Verify Raft quorum, HA status, and migrated secrets engines:

```bash
vault status
vault operator raft list-peers
vault secrets list
```

*Verification:*
* `vault status` shows `Storage Type: raft`, `HA Enabled: true`, `Sealed: false`.
* `vault operator raft list-peers` lists `vault-0` (`leader`), `vault-1` (`follower`), and `vault-2` (`follower`), all `voter: true`.
* `vault secrets list` shows `ldap/` and `github/` intact.

---

### 15.7 Upgrade the Host Auto-Unseal Cron Script for Raft (Dynamic Pod Discovery)
Replace `/usr/local/bin/vault-autounseal.sh` so the existing root cronjob (`* * * * * /usr/local/bin/vault-autounseal.sh`) dynamically discovers all running pods labeled `app=vault` in natural order (`vault-0`, `vault-1`, ...), using `flock` to avoid overlapping runs. Because pod names are discovered dynamically, no script edits are required when scaling the `StatefulSet` up or down:

```bash
sudo cp /usr/local/bin/vault-autounseal.sh /usr/local/bin/vault-autounseal.sh.bak

sudo tee /usr/local/bin/vault-autounseal.sh > /dev/null << 'EOF'
#!/usr/bin/env bash
set -uo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin"
export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

NAMESPACE="vault"
LABEL_SELECTOR="app=vault"
KEY_FILE="/root/.vault-unseal-key"
LOCK_FILE="/var/run/vault-autounseal.lock"

# Prevent overlapping cron runs
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

[[ -r "$KEY_FILE" ]] || exit 1
UNSEAL_KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
[[ -n "$UNSEAL_KEY" ]] || exit 1

# Dynamically discover all Running Vault pods, sorted in natural order (vault-0, vault-1, ...)
mapfile -t PODS < <(
  kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | sort -V
)

[[ ${#PODS[@]} -gt 0 ]] || exit 0

for pod in "${PODS[@]}"; do
  [[ -n "$pod" ]] || continue

  # vault status exit codes: 0 = unsealed, 2 = sealed, 1 = error
  kubectl exec -n "$NAMESPACE" "$pod" -- vault status >/dev/null 2>&1
  rc=$?

  if [[ $rc -eq 2 ]]; then
    kubectl exec -n "$NAMESPACE" "$pod" -- vault operator unseal "$UNSEAL_KEY" >/dev/null 2>&1
    logger -t vault-autounseal "Unsealed $pod"

    # Give vault-0 a moment to establish Raft leadership before unsealing followers
    if [[ "$pod" == "vault-0" ]]; then
      sleep 5
    fi
  fi
done
EOF

sudo chmod 700 /usr/local/bin/vault-autounseal.sh
sudo /usr/local/bin/vault-autounseal.sh
```

*Verification:* Confirm exit code is `0` (`echo $?`). You can also test failover by sealing or deleting a follower (`kubectl delete pod vault-2 -n vault`), waiting ~1 minute, and running `journalctl -t vault-autounseal -n 5` to confirm it automatically discovers and unseals the pod.

---

### 15.8 Post-Migration Cleanup
Once AWX lookups (`:30820`) and a pod-deletion failover test succeed, remove the old scaled-down `Deployment`:

```bash
kubectl delete deploy/vault -n vault
```

*(Keep `pvc/vault-data` and `~/vault-file-backup/` for a few days as a rollback safety net before deleting them.)*

---

> [← Back to Project Overview](./README.md)