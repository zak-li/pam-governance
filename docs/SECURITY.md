# Security

The platform follows a Zero-Trust model. Every resource requires a proven
identity, nothing is reachable anonymously, and each layer adds its own
control so that a single failure does not expose the system.

## Identity and authorization

Authentication is federated to Auth0 over OpenID Connect, with multi-factor
authentication enforced on every login. The weak email one-time-password factor
is disabled in favor of an authenticator app, and recovery codes are available.
Sessions are deliberately short, with an eight hour absolute lifetime and a
thirty minute idle timeout.

Authorization in Vault is scoped rather than global. The administrator policy
grants access only to the specific engines it manages and never receives a
blanket `path "*"` grant or `sudo`. The default OIDC role is the read-only
operator, which can read secrets and request short-lived SSH certificates but
nothing more. Escalation to administrator requires the `PAM_Administrator` group
claim, which an Auth0 post-login Action attaches only to members of that role,
so a successful login is never by itself a grant of privilege.

## Secrets

Vault issues secrets dynamically instead of distributing static keys. A signing
certificate authority mints short-lived SSH certificates for privileged host
access with a ten minute time to live, a database engine produces on-demand
database credentials, a transit engine offers encryption as a service, and a
versioned key-value store holds application secrets. Because credentials are
generated on request and expire quickly, there is no long-lived secret to leak.

The Vault unseal keys and the root token are never left on the machine. During
bootstrap they are pushed into Azure Key Vault through the virtual machine
managed identity and then shredded from local disk, which keeps break-glass
material off the host while an authorized operator can still recover it.

## Network and transport

The network is closed by default. The security group denies all inbound traffic
except from an allow-listed administrator address, and it carries an explicit
deny rule as a defense-in-depth backstop. The virtual machine accepts key-based
SSH only, with password authentication disabled. Inside the cluster, Kubernetes
network policy restricts ingress to the Kong gateway and the Istio control
plane, and Istio encrypts pod-to-pod traffic with mutual TLS. Vault is served
over TLS 1.2 or later, and the Kong gateway redirects all traffic to HTTPS and
applies rate limiting at the edge.

## Containers

The frontend container runs unprivileged. It listens on port 8080 as a non-root
user on a read-only root filesystem, drops all Linux capabilities, runs under
the default seccomp profile, and does not mount a service account token.

## Frontend

The single-page app is hardened for a hostile browser. It forces HTTPS and sets
HSTS, ships a strict Content Security Policy that forbids framing and inline
objects and upgrades insecure requests, and pins its one external script with
subresource integrity. Tokens are held in memory rather than local storage, and
a no-store cache policy together with a page-show revalidation prevents the
browser back button from restoring an authenticated view after logout.

## Audit and SIEM

Vault writes every request to a file audit device, which Splunk tails into a
dedicated `pam_audit` index alongside the host authentication and system logs.
A forensic dashboard ships preinstalled so that privileged activity, denied
requests, and dynamic secret issuance can be reviewed at a glance.

## Operational security

Vault re-seals whenever the virtual machine reboots, because it uses file
storage with no auto-unseal. To unlock it, read three of the five unseal keys
from Key Vault and pass them to Vault.

```bash
az keyvault secret show --vault-name <kv> -n vault-unseal-keys --query value -o tsv
# then run: vault operator unseal <key>   (three times)
```

The root token is escrowed as `vault-root-token` for break-glass use. For a
zero standing root posture, revoke it and regenerate it on demand with
`vault operator generate-root` and the unseal keys. Administrator access for a
user is granted by assigning the `PAM_Administrator` role in Auth0.

The Terraform state contains plaintext secrets such as the Vault TLS key, the VM
password, and the SSH private key, so it must never be committed. The included
`.gitignore` covers it, and a production deployment should move the state to an
encrypted remote backend such as an Azure Storage Account.

## Known limitations

The TLS certificate is self-signed because the platform is reached by public IP
with no domain name, which is why a browser shows a warning. Adding a domain
lets cert-manager and Let's Encrypt issue a trusted certificate on the cluster.
If the Google social connection is re-enabled it uses shared Auth0 development
keys, which should be replaced with the operator own Google OAuth credentials.
Vault has no auto-unseal, which an `azurekeyvault` seal stanza would provide.
The AKS cluster runs a single node to fit the student subscription quota, and a
production deployment would use a multi-node pool across availability zones.
