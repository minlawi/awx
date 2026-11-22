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
Make a quick change to `set_hostname.yml` (such as updating the target hostname) and push it to `main`:

```bash
git add set_hostname.yml
git commit -m "test: trigger AWX Job Template via GitHub Webhook and ngrok"
git push origin main
```

*Verification:*
1. **GitHub Webhooks → Recent Deliveries:** Shows a green `202 Accepted` response for the `push` event.
2. **ngrok Terminal:** Logs `POST /api/v2/job_templates/<id>/github/ 202 Accepted`.
3. **AWX Web UI → Views → Jobs:** The Job Template launches automatically without manual intervention, completes with status **Successful**, and updates `R1`'s hostname to `R1-WEBHOOK-TEST`.

> **Limitation Noted for Next Phases:** Free `ngrok` URLs rotate on every restart, and standard GitHub Webhooks fire on *every* push—triggering all linked templates regardless of which file changed. In **Tasks 7**, we resolve both issues using **GitHub Actions** and a **local Self-Hosted Runner**.

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
   ./config.sh --url [https://github.com/](https://github.com/)<your-username>/<your-repo> --token <REGISTRATION_TOKEN>
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

*Verification:* Confirm both `AWX_BASE_URL` and `AWX_API_TOKEN` appear under **Repository secrets**[cite: 11].

---

### 7.3 Create the Matrix-Driven Selective GitHub Actions Workflow
Instead of maintaining a separate workflow file for every playbook, create a single `.github/workflows/trigger-awx.yml` file that maps each playbook to its AWX Job Template ID and uses `git diff` against the previous commit (`HEAD~1`) to launch only modified playbooks[cite: 11]:

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
          - playbook: set_hostname.yml
            template_id: 12 # Get this ID from Step 7.2.2
          # Future playbooks: just add 2 lines (playbook + template_id)

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2

      - name: Check and launch ${{ matrix.playbook }} (Template${{ matrix.template_id }})
        run: |
          if git diff --name-only HEAD~1 HEAD | grep -qx "${{ matrix.playbook }}"; then
            echo "Change detected in ${{ matrix.playbook }} – launching AWX template${{ matrix.template_id }}..."
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
   * Update the hostname inside `set_hostname.yml` and push to `main`:

     ```bash
     git add set_hostname.yml
     git commit -m "test: trigger AWX over LAN via self-hosted GitHub Actions runner"
     git push origin main
     ```

*Verification:*
1. **GitHub → Actions:** `set_hostname.yml` logs `Change detected in set_hostname.yml – launching AWX template 12...`.
2. **AWX Web UI → Views → Jobs:** Only Template `12` (`set_hostname.yml`) launches and completes with status **Successful** over the private LAN, updating `R1`'s hostname to `R1-ACTIONS-LAN` with `ngrok` completely turned off.

---

> [← Back to Project Overview](./README.md)