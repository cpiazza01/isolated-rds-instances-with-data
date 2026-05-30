# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Optional features

All are off by default (`false`) and do not affect existing deploys.

**Bastion host** — SSH tunnel from a local machine to RDS:
```hcl
enable_bastion        = true
bastion_ssh_key_name  = "my-existing-key-pair"   # must already exist in AWS
bastion_allowed_cidrs = ["1.2.3.4/32"]           # your public IP
```

**AWS Client VPN** — native VPN so your machine joins the private VPC network directly (no SSH needed):

Cost: **$0.10/hr per subnet association** (2 AZs ≈ $144/month, even idle) plus $0.05/hr per active client. Run `terraform destroy -target='module.client_vpn'` when not in use.

Two certificate paths are available:

**Option A — auto-generated certs (dev/test only):** Terraform generates the full PKI and imports it into ACM. One certificate/key pair is created per entry in `client_vpn_client_names` — remove a name and re-apply to revoke that user. **Private keys are stored in Terraform state**, so restrict state access accordingly.
```hcl
enable_client_vpn              = true
client_vpn_cidr                = "172.16.0.0/22"   # must not overlap vpc_cidr
client_vpn_create_certificates = true
client_vpn_client_names        = ["alice", "bob"]  # one cert/key pair per entry
```

**Option B — BYO certs (production-grade):** Generate certs with EasyRSA, import them into ACM, then pass the ARNs. Private keys never touch Terraform state.
```hcl
enable_client_vpn          = true
client_vpn_cidr            = "172.16.0.0/22"
client_vpn_server_cert_arn = "arn:aws:acm:us-east-1:123456789012:certificate/server"
client_vpn_root_cert_arn   = "arn:aws:acm:us-east-1:123456789012:certificate/ca"
```

EasyRSA certificate generation (one-time):
```bash
git clone https://github.com/OpenVPN/easy-rsa.git
cd easy-rsa/easyrsa3
./easyrsa init-pki
./easyrsa build-ca nopass
./easyrsa --san=DNS:server build-server-full server nopass
./easyrsa build-client-full client1 nopass

# Import into ACM (region must match your deployment)
aws acm import-certificate \
  --certificate fileb://pki/issued/server.crt \
  --private-key fileb://pki/private/server.key \
  --certificate-chain fileb://pki/ca.crt
aws acm import-certificate \
  --certificate fileb://pki/ca.crt \
  --private-key fileb://pki/private/ca.key
# Use the returned ARNs as client_vpn_server_cert_arn and client_vpn_root_cert_arn
```

**After `terraform apply`, connect a client:**
```bash
# 1. Download the .ovpn base config
$(terraform output -raw client_vpn_config_cmd)

# 2a. If using auto-generated certs (Option A), embed per-user values from the output maps:
CLIENT=alice   # replace with the name from client_vpn_client_names
printf "<cert>\n%s\n</cert>\n" "$(terraform output -json client_vpn_client_cert_pem | jq -r --arg c "$CLIENT" '.[$c]')" >> client-config.ovpn
printf "<key>\n%s\n</key>\n"   "$(terraform output -json client_vpn_client_key_pem  | jq -r --arg c "$CLIENT" '.[$c]')" >> client-config.ovpn

# 2b. If using BYO certs (Option B), embed from your EasyRSA files:
printf "<cert>\n%s\n</cert>\n" "$(cat pki/issued/client1.crt)" >> client-config.ovpn
printf "<key>\n%s\n</key>\n"   "$(cat pki/private/client1.key)" >> client-config.ovpn

# 3. Import client-config.ovpn into the AWS VPN Client app (or Tunnelblick/OpenVPN)
# Once connected, the RDS hostname resolves and is reachable directly:
psql -h <db_host> -p 5432 -U dbadmin -d appdb
```

**Databricks VPC peering** — private network link to a Databricks workspace:
```hcl
enable_databricks_peering      = true
databricks_vpc_id              = "vpc-0abc123"
databricks_vpc_cidr            = "10.1.0.0/16"
databricks_peering_auto_accept = false  # true only if same AWS account
```

**Seeder** — three knobs control seeder behaviour:

```hcl
enable_seeder  = false  # don't deploy the Lambda at all
seed_on_apply  = false  # deploy the Lambda but don't auto-invoke on apply
snapshot_identifier = "snap-xxx"  # deploy the Lambda but skip auto-invoke (snapshot takes precedence)
```

| `enable_seeder` | `seed_on_apply` | `snapshot_identifier` | Lambda deployed | Auto-invoked |
|---|---|---|---|---|
| `true` | `true` | `null` | ✓ | ✓ default |
| `true` | `false` | `null` | ✓ | ✗ manual only |
| `true` | `true` | set | ✓ | ✗ snapshot takes precedence |
| `false` | — | — | ✗ | ✗ |

## Loading real data

Two ways to populate the RDS instance with data from an existing database.

**Option A — RDS snapshot restore (bootstraps a new instance from a snapshot):**

Set `snapshot_identifier` before the first `terraform apply`. AWS creates the instance from the snapshot; `db_name` and `db_username` are inherited from the snapshot, not from the corresponding variables.

```hcl
snapshot_identifier = "arn:aws:rds:us-east-1:123456789012:snapshot:my-snapshot"
# or a manual snapshot ID: "my-snapshot-id"
```

The snapshot must be in the same AWS region and accessible to this account (either owned by it or explicitly shared). Changing `snapshot_identifier` after initial apply replaces the RDS instance (destructive — Terraform will warn before proceeding).

**Option B — pg_dump / mysqldump into an existing instance (no Terraform changes needed):**

First establish a network path to RDS using either the bastion SSH tunnel or Client VPN (see Optional features above), then use standard dump/restore tools.

Via bastion:
```bash
# Open tunnel (keep this terminal open)
ssh -N -L 5432:$(terraform output -raw db_host):5432 ec2-user@$(terraform output -raw bastion_public_ip)

# In another terminal — dump from source, restore through tunnel
pg_dump -h <source-host> -U <source-user> -d <source-db> | \
  psql -h localhost -p 5432 -U dbadmin -d appdb

# MySQL equivalent
mysqldump -h <source-host> -u <source-user> -p <source-db> | \
  mysql -h 127.0.0.1 -P 3306 -u dbadmin -p appdb
```

Via Client VPN (once connected, the RDS hostname resolves directly):
```bash
pg_dump -h <source-host> -U <source-user> -d <source-db> | \
  psql -h $(terraform output -raw db_host) -U dbadmin -d appdb
```

## Commands

```bash
# Validate and format
terraform fmt -recursive          # fix formatting in-place
terraform fmt -check -recursive   # CI-style check (non-destructive)
terraform init -backend=false     # download providers, skip remote state
terraform validate                # type-check all modules (no AWS creds needed)

# Deploy / teardown
terraform apply                   # full deploy — RDS takes ~10 min to provision
terraform destroy                 # tears down everything

# Re-seed without a full apply (uses the seeder Lambda already deployed)
aws lambda invoke \
  --function-name <name_prefix>-seeder \
  --region <aws_region> \
  response.json && cat response.json

# Retrieve the RDS master password from Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw db_secret_arn)" \
  --query SecretString --output text | python -m json.tool

# Trigger a manual release (patch / minor / major)
# GitHub Actions → Release → Run workflow → pick version_part
```

## Testing

Tests use Terraform's built-in test framework (requires Terraform >= 1.9.0). All providers are mocked — no AWS credentials or real infrastructure needed.

```bash
terraform test                                                    # run all test files
terraform test -verbose                                           # show pass/fail for every assertion
terraform test -filter=tests/unit.tftest.hcl                     # root module only
terraform test -filter=tests/rds.tftest.hcl                      # RDS module only
terraform test -filter=tests/vpc.tftest.hcl                      # VPC module only
terraform test -filter=tests/client_vpn.tftest.hcl               # Client VPN module only
```

Test files all live in `tests/` so a single `terraform test` from the root runs everything:

| File | What it covers |
|---|---|
| `tests/unit.tftest.hcl` | Variable validation, conditional resource counts (bastion/client VPN/peering on/off), name prefix propagation |
| `tests/rds.tftest.hcl` | Parameter group family derivation (`postgres16`, `mysql8.0`, etc.), SG port, dynamic CIDR ingress — targets `modules/rds` directly via `module { source = "..." }` |
| `tests/vpc.tftest.hcl` | IGW + public subnet conditional creation, CIDR index layout — targets `modules/vpc` directly |
| `tests/client_vpn.tftest.hcl` | BYO vs auto-generated certs, cert count per `client_names`, network associations per subnet, split tunnel default, connection logging on/off, name prefix propagation — targets `modules/client_vpn` directly |

The module-targeted files use Terraform's `module { source = "../modules/X" }` test block so tests run against each module's plan without going through the root.

Static analysis:
```bash
tflint --init       # download AWS ruleset (needs GITHUB_TOKEN or internet access)
tflint --recursive  # lint root + all modules
```

## Architecture

### Five-module design with a root-level dependency break

The root `main.tf` wires five child modules — `vpc`, `rds`, `seeder` (always deployed) and `bastion`, `client_vpn` (conditional on feature flags) — but **also creates one resource directly**: `aws_security_group.seeder_lambda`. This is intentional and load-bearing.

There is a circular dependency between `rds` and `seeder`:
- `modules/rds` needs the seeder Lambda's SG ID to write its ingress rule before RDS exists.
- `modules/seeder` needs `module.rds.db_host` and `module.rds.db_instance_id`, which don't exist until after RDS is created.

The break: the Lambda SG is created at the root level and its ID is passed as a plain input variable to both child modules, so Terraform can resolve the graph without a cycle.

### Lambda package build flow

The seeder Lambda is built locally during `terraform apply` via two chained resources:

1. `terraform_data.build_package` — fires when `seed.py` or `requirements.txt` changes (detected via MD5 trigger). Runs `scripts/build.py`, which pip-installs `pg8000` and `pymysql` into `lambda/package/` and copies `seed.py` there.
2. `data.archive_file.lambda_zip` — zips `lambda/package/`. Has `depends_on = [terraform_data.build_package]`, which defers it to apply time (Terraform 1.3+ behaviour), guaranteeing the pip install runs first.

The `lambda/package/` directory exists in the repo with a `.gitkeep` so `archive_file` doesn't error during the first plan before any build has run.

### Password never touches Terraform

`manage_master_user_password = true` on `aws_db_instance` tells RDS to generate and own the password. Terraform only ever receives the Secrets Manager secret ARN (`master_user_secret[0].secret_arn`), never the value. There is no `db_password` variable anywhere.

At Lambda runtime, `seed.py` calls `boto3.client("secretsmanager").get_secret_value(SecretId=DB_SECRET_ARN)` and extracts `["password"]` from the JSON response.

### Secrets Manager VPC endpoint

The Lambda runs inside a fully private VPC (no NAT gateway). Without a VPC endpoint it cannot reach the public Secrets Manager API. `modules/vpc/main.tf` creates an `aws_vpc_endpoint` of type `Interface` for `com.amazonaws.<region>.secretsmanager` with `private_dns_enabled = true`, so `boto3` resolves the standard hostname to a private ENI without any code changes.

### Seeder invocation

After the Lambda is deployed, `terraform_data.invoke_seeder` runs `aws lambda invoke` synchronously via `local-exec`. The `aws` CLI must be on `PATH` and configured with credentials when running `terraform apply`. The response is written to `modules/seeder/invoke_response.json` (gitignored).

`terraform_data.invoke_seeder` re-runs (re-seeds) if any of its triggers change: `row_count`, `db_instance_id`, `function_name`, or the Lambda zip hash. Because `seed.py` uses `TRUNCATE` before inserting, re-runs produce a clean, exact dataset rather than appending rows.

### Release pipeline

Commits must follow [Conventional Commits](https://www.conventionalcommits.org/). The release workflow (`feat:`, `fix:`, `refactor:` prefixes) auto-releases on push to `main`; `chore:` and `docs:` do not. `bump-my-version` rewrites the `VERSION` file; `git-cliff` regenerates `CHANGELOG.md` from commit history using `cliff.toml`. Both land in a single `chore: release vX.Y.Z [skip ci]` commit.

### Bastion host

When `enable_bastion = true`, the VPC module creates an internet gateway and public subnets (CIDR indices 100+ to avoid the private subnet range). The bastion module deploys a t3.nano EC2 (Amazon Linux 2023) with a dynamic public IP in the first public subnet. The bastion's SG is added to `module.rds.allowed_security_group_ids` via a `for` expression over `module.bastion` (a list of 0 or 1) rather than index access — this prevents errors when `count = 0`. Stop the instance when not in use; it costs ~$0.0052/hr running, ~$0.08/month stopped.

SSH tunnel pattern:
```bash
ssh -N -L 5432:<rds_host>:5432 ec2-user@<bastion_public_ip>
# then connect DB client to localhost:5432
```

### Databricks VPC peering

When `enable_databricks_peering = true`, the root module creates `aws_vpc_peering_connection.databricks` and `aws_route.to_databricks` (pointing the private route table at the Databricks CIDR). The RDS security group gets a separate `dynamic "ingress"` block for CIDR-based rules (used here because Databricks cluster SGs live in a different account and can't be referenced directly). The Databricks side must independently add a return route and accept the peering if `auto_accept = false`.

### Engine-specific behaviour

`db_engine` (`"postgres"` or `"mysql"`) is the single input that fans out into several derived decisions: the port (`5432`/`3306` in root `locals`), the RDS engine string, the parameter group family (derived in `modules/rds/main.tf` by splitting the version string), and which Python driver `seed.py` imports at runtime. Changing `db_engine` after initial apply replaces the RDS instance.
