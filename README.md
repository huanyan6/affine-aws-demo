# AFFiNE Demo on AWS

Self-host [AFFiNE](https://affine.pro) (open-source Notion alternative) on AWS Free Tier.

## Versions

| Version | Tag | Description |
|---|---|---|
| v1.0 | `v1.0` | Core deployment — VPC, EC2, Docker stack, functional tests |
| v2.0 | `v2.0` | v1.0 + CIS baseline verification (Prowler, Lynis, docker-bench) |

## Repository layout

```
affine-aws-demo/
├── scripts/                        # Core deployment (v1.0+)
│   ├── 01-aws-bootstrap.sh         # VPC, IAM, S3, Elastic IP
│   ├── 02-launch-ec2.sh            # Launch t2.micro with Docker pre-installed
│   ├── 03-configure-affine.sh      # Deploy AFFiNE stack via Docker Compose
│   ├── 04-test-affine.sh           # Automated health + function tests
│   └── 05-teardown.sh              # Destroy all AWS resources
├── cis/                            # CIS verification (v2.0+)
│   ├── cis-01-install-prowler.sh   # Install Prowler OSS, Lynis, docker-bench
│   ├── cis-02-run-checks.sh        # Run all 3 CIS layers (AWS + OS + Docker)
│   ├── cis-03-remediate.sh         # Apply safe CIS hardening fixes
│   └── cis-04-enable-securityhub.sh# Optional: AWS Security Hub 30-day trial
├── config/                         # Runtime outputs (git-ignored secrets)
└── docs/
    ├── DEPLOYMENT_GUIDE.md         # Full deployment walkthrough
    └── CIS_VERIFICATION_GUIDE.md   # CIS verification and remediation guide
```

## Quick start (v2.0)

```bash
# 1. Bootstrap AWS resources
./scripts/01-aws-bootstrap.sh

# 2. Launch EC2
./scripts/02-launch-ec2.sh

# 3. Deploy AFFiNE
source config/bootstrap-outputs.env
scp -i "$KEY_FILE" config/bootstrap-outputs.env scripts/03-configure-affine.sh \
  ec2-user@${EIP}:/opt/affine/
ssh -i "$KEY_FILE" ec2-user@${EIP} \
  "chmod +x /opt/affine/03-configure-affine.sh && sudo /opt/affine/03-configure-affine.sh"

# 4. Test
./scripts/04-test-affine.sh --host $EIP --skip-tls-verify

# 5. CIS verification (v2.0)
scp -i "$KEY_FILE" cis/*.sh ec2-user@${EIP}:/opt/affine/
ssh -i "$KEY_FILE" ec2-user@${EIP} \
  "chmod +x /opt/affine/cis-*.sh && /opt/affine/cis-01-install-prowler.sh"
ssh -i "$KEY_FILE" ec2-user@${EIP} "/opt/affine/cis-02-run-checks.sh"

# 6. Teardown when done
./scripts/05-teardown.sh
```

## Estimated cost

**~$0/month** on AWS Free Tier (first 12 months of account).

See [docs/DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md) for the full guide.  
See [docs/CIS_VERIFICATION_GUIDE.md](docs/CIS_VERIFICATION_GUIDE.md) for CIS coverage details.

## Cleanup

```bash
./scripts/05-teardown.sh
```
