# Isolated RDS Instances with Data

A Terraform module that spins up a fully private RDS instance inside its own
VPC and automatically seeds it with a configurable number of dummy rows — all
in a single `terraform apply`.

Useful for spinning up realistic development databases, load-testing datasets,
or integration-test fixtures without any manual SQL work.

---

## What it creates

| Resource | Purpose |
|---|---|
| VPC | Private network; private subnets have no internet route |
| 2× private subnets | One per AZ; used by RDS, the seeder Lambda, and the Secrets Manager VPC endpoint |
| Private route table | Local-only; keeps RDS and Lambda traffic inside the VPC |
| Secrets Manager VPC endpoint | Allows Lambda to fetch the DB password without leaving the VPC |
| RDS instance | PostgreSQL or MySQL, encrypted gp3 storage, not publicly accessible |
| DB subnet group | Registers the private subnets with RDS |
| DB parameter group | Dedicated config group so future tuning stays in Terraform |
| 2× security groups (always) | RDS, VPC endpoints |
| *(conditional)* Seeder Lambda security group | Created when `enable_seeder = true` (the default) |
| *(optional)* Bastion security group | Created when `enable_bastion = true` |
| *(optional)* Client VPN security group | Created when `enable_client_vpn = true` |
| IAM role + policy | Lambda execution role; VPC access + scoped Secrets Manager read |
| Lambda function | Python 3.12; connects to RDS and inserts rows in batches of 500 |
| 2× null_resource resources | Build the Lambda package locally; invoke it after RDS is ready |
| *(optional)* Internet gateway + public subnets | Created when `enable_bastion = true` |
| *(optional)* Bastion EC2 (t3.nano) | SSH jump host for local-machine → RDS tunnelling |
| *(optional)* Client VPN endpoint + network associations | Created when `enable_client_vpn = true`; lets clients connect directly to the private VPC |
| *(optional)* ACM certificates (CA, server, per-user client) | Created when `client_vpn_create_certificates = true`; private keys stored in Terraform state |
| *(optional)* CloudWatch log group | Created when `client_vpn_enable_connection_logging = true`; 90-day retention |
| *(optional)* VPC peering connection + route | Private link to a Databricks workspace VPC |

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  VPC  (10.0.0.0/16, no IGW)                             │
│                                                         │
│  ┌──────────────────┐    ┌──────────────────────────┐  │
│  │  Private subnet  │    │     Private subnet       │  │
│  │  us-east-1a      │    │     us-east-1b           │  │
│  │  10.0.0.0/24     │    │     10.0.1.0/24          │  │
│  └────────┬─────────┘    └────────────┬─────────────┘  │
│           │                           │                 │
│    ┌──────▼────────────────────────── ▼──────┐          │
│    │         Lambda  (seeder)                │          │
│    │         python3.12 / 512 MB / 15 min    │          │
│    │         SG: egress → RDS port + HTTPS    │          │
│    └──────────────────┬──────────────────────┘          │
│                       │ TCP 5432 / 3306                  │
│    ┌──────────────────▼──────────────────────┐          │
│    │         RDS instance                    │          │
│    │         postgres or mysql               │          │
│    │         SG: ingress from allowed SGs/CIDRs │        │
│    └─────────────────────────────────────────┘          │
└─────────────────────────────────────────────────────────┘

  Terraform apply (local machine)
    │
    ├─ null_resource:  pip install → lambda/package/
    ├─ archive_file:   zip lambda/package/ → lambda_package.zip
    └─ null_resource:  aws lambda invoke  ───────────────────▶ Lambda runs
                                                              └─ INSERT x rows
```

The seeder Lambda runs **inside the VPC** so it can reach the RDS private
endpoint. The `aws lambda invoke` call on your local machine is the only
outbound network action — it talks to the Lambda API endpoint over the public
internet using your AWS credentials, while the Lambda itself talks to RDS
entirely within the VPC.

---

## Prerequisites

- Terraform >= 1.9.0
- Python 3.12 on the machine running `terraform apply` (used to build the
  Lambda package — the build script enforces this version to match the Lambda runtime)
- AWS CLI configured with credentials that have permission to create the
  resources listed above
- The `aws` CLI available on `PATH` (used to invoke the Lambda after deploy)

---

## Quick start

```hcl
module "isolated_rds" {
  source = "path/to/this/module"

  aws_region  = "us-east-1"
  name_prefix = "my-db"

  db_engine   = "postgres"
  db_name     = "appdb"
  db_username = "dbadmin"

  row_count = 10000
}
```

```bash
terraform init
terraform apply
```

No password variable required. RDS generates a strong random password and
stores it in AWS Secrets Manager automatically — it never passes through
Terraform and never appears in the state file. To retrieve it after apply:

```bash
aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw db_secret_arn)" \
  --region    "$(terraform output -raw aws_region)" \
  --query SecretString --output text | jq .
```

A working example lives in [examples/basic/](examples/basic/).

---

## Input variables

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | `string` | `"isolated-rds"` | Prefix for all resource names and tags |
| `aws_region` | `string` | `"us-east-1"` | AWS region to deploy into |
| `availability_zones` | `list(string)` | `["us-east-1a","us-east-1b"]` | AZs for subnets — must be at least two |
| `vpc_cidr` | `string` | `"10.0.0.0/16"` | CIDR block for the VPC |
| `db_engine` | `string` | `"postgres"` | `"postgres"` or `"mysql"` |
| `db_engine_version` | `string` | `null` | Engine version; `null` uses the module default (postgres 16.3 / mysql 8.0.35) |
| `db_instance_class` | `string` | `"db.t3.micro"` | RDS instance size |
| `db_name` | `string` | `"appdb"` | Database name created on the instance |
| `db_username` | `string` | `"dbadmin"` | Master username |
| `db_storage_gb` | `number` | `20` | Allocated storage in GiB (gp3, cannot be shrunk after creation) |
| `lambda_permission_boundary_arn` | `string` | `null` | ARN of an IAM permissions boundary for the seeder Lambda execution role — required in accounts that enforce a boundary on all IAM role creation |
| `enable_seeder` | `bool` | `true` | Deploy and invoke the seeder Lambda — set `false` to skip seeding entirely (e.g. when loading data manually or restoring from a snapshot) |
| `seed_on_apply` | `bool` | `true` | Auto-invoke the seeder on every apply — set `false` to deploy the Lambda without running it automatically (manual control over when seeding happens) |
| `snapshot_identifier` | `string` | `null` | RDS snapshot ARN or identifier to restore from — when set, `db_name` and `db_username` are inherited from the snapshot and the seeder Lambda is deployed but not auto-invoked |
| `skip_final_snapshot` | `bool` | `true` | Skip snapshot on destroy — set `false` for production-like stacks |
| `row_count` | `number` | `1000` | Rows to seed into the `users` table (1 – 1,000,000) |
| `db_deletion_protection` | `bool` | `false` | Prevent accidental deletion of the RDS instance — set `true` for staging/production |
| `enable_bastion` | `bool` | `false` | Deploy a bastion EC2 for SSH-tunnel access to RDS |
| `bastion_ssh_key_name` | `string` | `null` | Existing EC2 key pair name — required when `enable_bastion = true` |
| `bastion_allowed_cidrs` | `list(string)` | `[]` | CIDRs allowed to SSH to the bastion (e.g. `["1.2.3.4/32"]`) |
| `enable_client_vpn` | `bool` | `false` | Deploy an AWS Client VPN endpoint for private-network access to RDS (~$0.10/hr per subnet when idle) |
| `client_vpn_cidr` | `string` | `"172.16.0.0/22"` | CIDR for VPN client IPs — must not overlap with `vpc_cidr` |
| `client_vpn_create_certificates` | `bool` | `false` | Auto-generate PKI certs via the `tls` provider — private keys stored in Terraform state |
| `client_vpn_client_names` | `list(string)` | `["client"]` | One cert/key pair generated per name when `client_vpn_create_certificates = true` |
| `client_vpn_server_cert_arn` | `string` | `null` | ACM server certificate ARN — required when `client_vpn_create_certificates = false` |
| `client_vpn_root_cert_arn` | `string` | `null` | ACM CA certificate ARN for client validation — required when `client_vpn_create_certificates = false` |
| `client_vpn_split_tunnel` | `bool` | `true` | Route only VPC traffic through the VPN; clients keep normal internet for everything else |
| `client_vpn_enable_connection_logging` | `bool` | `false` | Write connect/disconnect events to CloudWatch Logs (90-day retention) |
| `enable_databricks_peering` | `bool` | `false` | Create a VPC peering connection to a Databricks workspace VPC |
| `databricks_vpc_id` | `string` | `null` | Databricks VPC ID — required when `enable_databricks_peering = true` |
| `databricks_vpc_cidr` | `string` | `null` | Databricks VPC CIDR — required when `enable_databricks_peering = true` |
| `databricks_peering_auto_accept` | `bool` | `false` | Auto-accept the peering — only valid when the Databricks VPC is in the same AWS account |

---

## Outputs

| Name | Description |
|---|---|
| `aws_region` | AWS region the stack is deployed into |
| `vpc_id` | ID of the private VPC |
| `private_subnet_ids` | List of private subnet IDs |
| `db_instance_id` | RDS instance identifier |
| `db_endpoint` | Connection endpoint in `host:port` format |
| `db_host` | RDS hostname (private DNS) |
| `db_port` | RDS port (5432 or 3306) |
| `seeder_lambda_name` | Name of the seeder Lambda function |
| `db_secret_arn` | ARN of the Secrets Manager secret holding the RDS master password |
| `vpc_cidr` | VPC CIDR block — needed as the return-route destination for Databricks peering |
| `bastion_public_ip` | Public IP of the bastion host (`null` when `enable_bastion = false`) |
| `bastion_instance_id` | EC2 instance ID — use to start/stop the bastion from the CLI |
| `bastion_ssh_tunnel_command` | Complete SSH tunnel command, ready to paste (`null` when `enable_bastion = false`) |
| `client_vpn_endpoint_id` | Client VPN endpoint ID (`null` when `enable_client_vpn = false`) |
| `client_vpn_dns_name` | Client VPN endpoint DNS name (`null` when `enable_client_vpn = false`) |
| `client_vpn_config_cmd` | Ready-to-run command to download the `.ovpn` client config (`null` when `enable_client_vpn = false`) |
| `client_vpn_client_cert_pem` | *(sensitive)* Map of client name → certificate PEM (`null` when `enable_client_vpn = false`; empty when `client_vpn_create_certificates = false`) |
| `client_vpn_client_key_pem` | *(sensitive)* Map of client name → private key PEM (`null` when `enable_client_vpn = false`; empty when `client_vpn_create_certificates = false`) |
| `databricks_peering_id` | VPC peering connection ID (`null` when `enable_databricks_peering = false`) |

---

## Seeded data

The Lambda creates a `users` table and inserts the requested number of rows.

**Schema (PostgreSQL)**
```sql
CREATE TABLE users (
    id         SERIAL PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    email      VARCHAR(200) NOT NULL UNIQUE,
    created_at TIMESTAMP DEFAULT NOW()
);
```

**Schema (MySQL)**
```sql
CREATE TABLE users (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    email      VARCHAR(200) NOT NULL UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

**Sample rows**
```
 id |      name      |              email               |       created_at
----+----------------+----------------------------------+------------------------
  1 | Alice Smith    | alice.smith.0@example.com        | 2024-01-15 10:23:41
  2 | Bob Jones      | bob.jones.1@test.org             | 2024-01-15 10:23:41
  3 | Carol Williams | carol.williams.2@demo.net        | 2024-01-15 10:23:41
```

Names are drawn from a fixed list of 24 first names and 20 last names.
Emails use a `firstname.lastname.<index>@<domain>` pattern that guarantees
uniqueness across all rows. Rows are inserted in batches of 500 to keep
individual transactions fast.

---

## How re-seeding works

The `invoke_seeder` null_resource re-runs whenever any of its trigger
values change. This means the Lambda is automatically re-invoked if you:

- Change `row_count`
- Replace the RDS instance (e.g. change `db_engine` or `db_instance_class`)
- Modify `seed.py` or `requirements.txt`

The Lambda runs `CREATE TABLE IF NOT EXISTS` followed by `TRUNCATE`, so every
seed run produces a clean, exact dataset with precisely the requested number of
rows. Existing data is always replaced, not appended.

You can also invoke the seeder manually at any time without a full apply:

```bash
aws lambda invoke \
  --function-name "$(terraform output -raw seeder_lambda_name)" \
  --region "$(terraform output -raw aws_region)" \
  response.json && cat response.json
```

---

## Changing the engine

To switch from PostgreSQL to MySQL, update two variables:

```hcl
db_engine         = "mysql"
db_engine_version = "8.0.35"
```

The parameter group family, security group port, and the Python DB driver
imported by the Lambda handler are all derived from `db_engine` automatically.

**Note:** changing `db_engine` after initial apply replaces the RDS instance
(a destructive change). Terraform will warn you before proceeding.

---

## Controlling the seeder

Three variables control seeder behaviour independently:

| `enable_seeder` | `seed_on_apply` | `snapshot_identifier` | Lambda deployed | Auto-invoked on apply |
|---|---|---|---|---|
| `true` | `true` | `null` | ✓ | ✓ default |
| `true` | `false` | `null` | ✓ | ✗ manual only |
| `true` | `true` | set | ✓ | ✗ snapshot takes precedence |
| `false` | — | — | ✗ | ✗ |

**Skip seeding entirely** (no Lambda, no IAM role, no SG):
```hcl
enable_seeder = false
```

**Deploy the Lambda but invoke manually** (useful when you control timing of seed runs):
```hcl
seed_on_apply = false
```
Invoke manually at any time:
```bash
aws lambda invoke --function-name $(terraform output -raw seeder_lambda_name) \
  --region <aws_region> response.json && cat response.json
```

---

## Loading real data

Two ways to populate the RDS instance with data from an existing database.

### Option A — RDS snapshot restore

Set `snapshot_identifier` before the first `terraform apply`. AWS creates the instance from the snapshot; `db_name` and `db_username` are inherited from the snapshot rather than from the corresponding variables.

```hcl
snapshot_identifier = "arn:aws:rds:us-east-1:123456789012:snapshot:my-snapshot"
# or a manual snapshot ID: "my-snapshot-id"
```

The snapshot must be in the same AWS region and accessible to this account (owned by it or explicitly shared). Changing `snapshot_identifier` on an already-deployed instance replaces it — Terraform will show a destructive plan and require confirmation before proceeding.

### Option B — pg_dump / mysqldump

No Terraform changes needed. First establish a network path using either the bastion SSH tunnel or Client VPN (see [Optional features](#optional-features) in CLAUDE.md), then use standard dump/restore tools.

**Via bastion SSH tunnel:**
```bash
# Open the tunnel (keep this terminal open)
ssh -N -L 5432:$(terraform output -raw db_host):5432 \
  ec2-user@$(terraform output -raw bastion_public_ip)

# Dump from source, restore through tunnel
pg_dump -h <source-host> -U <source-user> -d <source-db> | \
  psql -h localhost -p 5432 -U dbadmin -d appdb

# MySQL equivalent
mysqldump -h <source-host> -u <source-user> -p <source-db> | \
  mysql -h 127.0.0.1 -P 3306 -u dbadmin -p appdb
```

**Via Client VPN** (once connected, the RDS hostname resolves directly):
```bash
pg_dump -h <source-host> -U <source-user> -d <source-db> | \
  psql -h $(terraform output -raw db_host) -U dbadmin -d appdb
```

---

## Module structure

```
.
├── main.tf                        # Root: provider, locals, module wiring
├── variables.tf                   # All input variables with descriptions
├── outputs.tf                     # Useful post-apply values
├── versions.tf                    # Provider version pins
│
├── examples/
│   └── basic/
│       ├── main.tf                # Minimal working example
│       ├── versions.tf            # Provider declarations for the example
│       └── terraform.tfvars.example
│
└── modules/
    ├── vpc/
    │   ├── main.tf                # VPC, subnets, route table + associations
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── rds/
    │   ├── main.tf                # Security group, subnet group, parameter
    │   │                          #   group, and DB instance
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── bastion/
    │   ├── main.tf                # EC2 (t3.nano, Amazon Linux 2023), SG, AMI data source
    │   ├── variables.tf
    │   └── outputs.tf
    │
    └── seeder/
        ├── main.tf                # IAM role, build step, Lambda, invocation
        ├── variables.tf
        ├── outputs.tf
        ├── lambda/
        │   ├── seed.py            # Handler: connects to DB, inserts rows
        │   ├── requirements.txt   # pg8000, pymysql
        │   └── package/           # Populated at apply time by build.py
        │       └── .gitkeep
        └── scripts/
            └── build.py           # pip install + copy handler into package/
```

---

## Design notes

**Why is the seeder Lambda inside the VPC?**
The RDS instance has `publicly_accessible = false`, so its DNS name only
resolves to a private IP. The Lambda must run inside the same VPC to reach
that private IP. For ongoing human access, the optional bastion host
(`enable_bastion = true`) provides an SSH tunnel path.

**Why is the seeder security group created in the root module?**
There is a circular dependency between the RDS and seeder child modules:
RDS needs the Lambda's SG ID to write its ingress rule, while the seeder needs
RDS's hostname and instance ID. Creating the SG one level up in root breaks
the cycle — both child modules receive the already-known SG ID as a plain
input variable.

**Why `depends_on` on `archive_file`?**
By default, Terraform evaluates data sources at plan time. The `archive_file`
data source reads `lambda/package/`, which is empty until `null_resource.build_package`
runs `pip install`. Setting `depends_on = [null_resource.build_package]`
defers the data source to apply time (Terraform 1.3+), ensuring the directory
is fully populated before the zip is created.

**Why is there no `db_password` variable?**
The module uses RDS's `manage_master_user_password` feature. RDS generates a
strong random password itself and stores it directly in AWS Secrets Manager —
Terraform never sees the value, so it cannot appear in the state file. The
seeder Lambda retrieves the password at runtime by calling
`secretsmanager:GetSecretValue` via an IAM policy scoped to that one secret
ARN. A VPC interface endpoint for Secrets Manager routes this call privately
within the VPC so no internet access is needed.

**Why pure-Python DB drivers?**
`pg8000` (PostgreSQL) and `pymysql` (MySQL) are written entirely in Python
and install cleanly with pip on any platform, including the Windows machine
running Terraform. Drivers like `psycopg2` have compiled C extensions that
require platform-specific build tools and would break on machines where those
tools aren't present.

---

## CI/CD and versioning

### Workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | Every PR and push to `main` | `terraform fmt -check -recursive` + `terraform validate` + `terraform test` + `tflint` |
| `release.yml` | After CI passes on `main`, or manual dispatch | Bumps version, updates `CHANGELOG.md`, creates a GitHub Release |
| `claude-code-review.yml` | PR opened / updated | Posts an automated Claude code review as a PR comment |
| `claude.yml` | `@claude` in any issue or PR comment | Lets Claude respond to questions and requests in-repo |

### Release process

Releases are driven by [Conventional Commits](https://www.conventionalcommits.org/).

**Automatic** — push to `main` with at least one `feat:`, `fix:`, `refactor:`, or `perf:` commit since the last tag:
```
git commit -m "feat: add support for db.t4g instance classes"
git push origin main   # release workflow fires automatically
```

**Manual** — trigger via GitHub Actions → Release → Run workflow, then pick `patch`, `minor`, or `major`. Use this for `chore:` or `docs:` changes that you still want to tag.

The workflow:
1. Bumps the `VERSION` file via `bump-my-version`
2. Regenerates `CHANGELOG.md` via `git-cliff` using `cliff.toml`
3. Commits both files as `chore: release vX.Y.Z [skip ci]`
4. Creates an annotated git tag `vX.Y.Z`
5. Creates a GitHub Release with auto-generated release notes

### Commit types and their effect

| Prefix | Changelog group | Triggers auto-release? |
|---|---|---|
| `feat:` | Added | Yes |
| `fix:` | Fixed | Yes |
| `refactor:` | Changed | Yes |
| `perf:` | Changed | Yes |
| `docs:` | Documentation | No — use manual dispatch |
| `chore:` | Maintenance | No — use manual dispatch |
| `ci:`, `test:`, `style:` | *(skipped)* | No |

### Required secrets

| Secret | Used by | How to get it |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | `claude.yml`, `claude-code-review.yml` | Generate at [claude.ai/settings](https://claude.ai/settings) under API keys |

`GITHUB_TOKEN` is provided automatically by GitHub Actions — no setup needed.

---

## Limitations

- **Seeder is optional:** Set `enable_seeder = false` to deploy RDS without the seeder Lambda. Combine with `snapshot_identifier` to restore from an existing snapshot, or use `enable_bastion`/`enable_client_vpn` to load data manually via `pg_dump`/`mysqldump`.
- **Lambda timeout:** AWS Lambda has a hard maximum of 15 minutes. At 500
  rows per batch, roughly 500,000 rows can be inserted before the timeout is
  reached. For larger datasets, consider running the seeder Lambda multiple
  times or replacing it with a bulk-load approach (e.g. `COPY` from S3).
- **Private subnets have no internet access:** The Lambda and RDS live in private
  subnets with no NAT gateway. They cannot make outbound calls to the internet;
  only the Secrets Manager VPC endpoint is reachable. When `enable_bastion = true`,
  the public subnets gain internet access via the IGW, but private resources
  are unaffected.
- **Single-AZ:** `multi_az = false` keeps costs low. The RDS instance is
  placed in one AZ and will have downtime during maintenance events or AZ
  failures.
- **Secrets Manager VPC endpoint cost:** The interface endpoint injects an ENI
  into each private subnet. AWS charges ~$0.01/hr per AZ — with the default
  two AZs that is ~$14.40/month on top of the RDS instance cost. This is
  unavoidable as long as the Lambda needs Secrets Manager access without a NAT
  gateway.
- **Engine version defaults become stale:** The module defaults to postgres 16.3
  and mysql 8.0.35. When AWS eventually ends support for those minor versions,
  `terraform apply` will fail. Pin `db_engine_version` explicitly to the current
  minor version and keep it updated. Check available versions with:
  `aws rds describe-db-engine-versions --engine postgres --query 'DBEngineVersions[].EngineVersion'`
- **invoke_response.json:** The Lambda invocation writes a response file to
  `modules/seeder/invoke_response.json` on the machine running Terraform.
  This file is local-only and is excluded by `.gitignore`.
