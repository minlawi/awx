1. Inspect current Vault ConfigMap before scaling
------------------------------------------------------
# Check the live `vault-config` ConfigMap in the `vault` namespace (3-node `retry_join` baseline).
kubectl get cm vault-config -n vault -o yaml


2. Edit `vault-config` to add peers (`vault-3`, `vault-4`) for Scale Up (3 -> 5)
------------------------------------------------------
# Always scale Vault Raft clusters in odd numbers (3 -> 5 -> 7) to maintain quorum.
# Open `vault-config` interactively and add `retry_join` blocks for `vault-3` and `vault-4`
# inside `storage "raft"`, preserving exact YAML/HCL indentation.
kubectl edit cm vault-config -n vault

# Verification: Confirm `vault-3` and `vault-4` are saved inside `storage "raft"`.
kubectl get cm vault-config -n vault -o jsonpath='{.data.vault\.hcl}'


3. Scale up Vault StatefulSet from 3 to 5 replicas
------------------------------------------------------
# Kubernetes automatically provisions `data-vault-3` and `data-vault-4` PVCs via `volumeClaimTemplates`.
kubectl scale statefulset vault -n vault --replicas=5

# Verification: Confirm `vault-3` and `vault-4` reach `1/1 Running`.
kubectl rollout status statefulset/vault -n vault
kubectl get pods -n vault


4. Unseal new pods and verify 5-node Raft quorum
------------------------------------------------------
# Trigger the dynamic auto-unseal script (or wait up to 60s for the cron job) to unseal new pods.
sudo /usr/local/bin/vault-autounseal.sh

# Verification: Confirm all 5 nodes (`vault-0` through `vault-4`) are `voter: true` and `Sealed: false`.
vault operator raft list-peers
vault status


5. Scale down: Check Raft leader and remove departing peers (`vault-4`, `vault-3`)
------------------------------------------------------
# StatefulSets terminate highest-ordinal pods first (`vault-4`, then `vault-3`).
# Remove departing peers from Raft consensus BEFORE scaling down the StatefulSet.
vault operator raft list-peers

# Optional: If `vault-4` or `vault-3` is currently the leader, step down first:
# vault operator step-down

vault operator raft remove-peer vault-4
vault operator raft remove-peer vault-3

# Verification: Confirm only `vault-0`, `vault-1`, and `vault-2` remain in the peer list.
vault operator raft list-peers


6. Scale down Vault StatefulSet from 5 to 3 replicas
------------------------------------------------------
# Reduce replicas back to 3 once `vault-4` and `vault-3` are removed from Raft.
kubectl scale statefulset vault -n vault --replicas=3

# Verification: Confirm `vault-3` and `vault-4` terminate and `vault-0`..`vault-2` are `1/1 Running`.
kubectl rollout status statefulset/vault -n vault
kubectl get pods -n vault


7. Delete orphaned PVCs (`data-vault-4`, `data-vault-3`)
------------------------------------------------------
# StatefulSets intentionally retain PVCs after scale-down to prevent data loss; delete unused ones manually.
kubectl delete pvc data-vault-4 data-vault-3 -n vault

# Verification: Confirm `data-vault-3` and `data-vault-4` are removed and `data-vault-0`..`data-vault-2` remain bound.
kubectl get pvc -n vault


8. Edit `vault-config` to remove `vault-3` and `vault-4` and verify final state
------------------------------------------------------
# Open `vault-config` interactively and remove (or comment out) the `retry_join` blocks for `vault-3` and `vault-4`.
kubectl edit cm vault-config -n vault

# Verification: Confirm 3-node `retry_join` config, 3 healthy Raft voters, `Sealed: false`, and secrets engines intact.
kubectl get cm vault-config -n vault -o jsonpath='{.data.vault\.hcl}'
vault operator raft list-peers
vault status
vault secrets list