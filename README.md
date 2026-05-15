# AFFiNE Demo on AWS

Self-host [AFFiNE](https://affine.pro) (open-source Notion alternative) on AWS Free Tier.

## Versions

| Version | Tag | Description |
|---|---|---|
| v3.0 | `v3.0` | **Terraform rewrite** — single `terraform apply` / `terraform destroy`; pure user-data, no SSH provisioner |
| v2.0 | `v2.0` | CIS baseline verification (Prowler, Lynis, docker-bench) on top of v1.0 |
| v1.0 | `v1.0` | Core deployment — VPC, EC2, Docker stack, functional tests via shell scripts |

## Quick start (v3.0 — recommended)

### Prerequisites

- AWS CLI configured (`aws sts get-caller-identity` works)
- [Terraform ≥ 1.5](https://developer.hashicorp.com/terraform/install)

```bash
cd terraform

terraform init
cp terraform.tfvars.example terraform.tfvars   # edit region/domain if needed
terraform apply                                 # ~3 min to provision

# Monitor AFFiNE startup (takes ~10 min after apply):
$(terraform output -raw setup_log_command)

# Validate:
cd .. && ./scripts/test-affine.sh --skip-tls-verify

# Teardown:
cd terraform && terraform destroy
```

### Key variables (`terraform.tfvars`)

| Variable | Default | Notes |
|---|---|---|
| `aws_region` | `ap-southeast-2` | Change to your preferred region |
| `affine_domain` | `""` | Set for Let's Encrypt HTTPS; leave empty for self-signed cert |
| `ec2_instance_type` | `t2.micro` | Free Tier eligible |

## Repository layout

```
affine-aws-demo/
├── terraform/                       # v3.0 — Terraform root module (recommended)
│   ├── main.tf                      # VPC, IGW, subnet, route table, security group
│   ├── ec2.tf                       # Key pair, secrets, AMI, EC2, EIP
│   ├── iam.tf                       # IAM user/group/policy for S3
│   ├── s3.tf                        # S3 bucket + public access block
│   ├── outputs.tf                   # public_ip, access_url, ssh_command, etc.
│   ├── variables.tf                 # All inputs with defaults
│   ├── versions.tf                  # Provider pins
│   ├── terraform.tfvars.example     # Copy → terraform.tfvars to customise
│   └── templates/
│       └── user_data.sh.tpl         # Cloud-init: Docker, Nginx, AFFiNE stack
├── scripts/                         # v1–v2 shell-script deployment (legacy)
│   ├── 01-aws-bootstrap.sh          # VPC, IAM, S3, Elastic IP
│   ├── 02-launch-ec2.sh             # Launch t2.micro with Docker
│   ├── 03-configure-affine.sh       # Deploy AFFiNE stack via SSH
│   ├── test-affine.sh               # Automated health + function tests (v2 & v3)
│   └── 05-teardown.sh               # Tag-based resource sweep
├── cis/                             # CIS verification (v2.0)
│   ├── cis-01-install-prowler.sh
│   ├── cis-02-run-checks.sh
│   ├── cis-03-remediate.sh
│   └── cis-04-enable-securityhub.sh
├── config/                          # Runtime outputs (git-ignored)
└── docs/
    ├── DEPLOYMENT_GUIDE.md
    └── CIS_VERIFICATION_GUIDE.md
```

## Estimated cost

**~$0/month** on AWS Free Tier (first 12 months of account).

## Legacy quick start (v2.0 shell scripts)

```bash
./scripts/01-aws-bootstrap.sh
./scripts/02-launch-ec2.sh
./scripts/03-configure-affine.sh
./scripts/test-affine.sh

# CIS verification:
# (see docs/CIS_VERIFICATION_GUIDE.md)

# Teardown:
./scripts/05-teardown.sh
```

See [docs/DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md) for the full shell-script guide.  
See [docs/CIS_VERIFICATION_GUIDE.md](docs/CIS_VERIFICATION_GUIDE.md) for CIS coverage details.
