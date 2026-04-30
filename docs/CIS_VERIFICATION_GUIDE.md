# CIS Baseline Verification Guide — AFFiNE Demo on AWS

## Overview

This guide covers CIS baseline verification for the three layers of the AFFiNE demo:

| Layer | Scope | Tool | Cost |
|---|---|---|---|
| AWS foundations | IAM, VPC, S3, EC2, CloudTrail | Prowler OSS | $0 |
| OS hardening | Amazon Linux 2023 | Lynis | $0 |
| Docker containers | AFFiNE, PostgreSQL, Redis, Nginx | docker-bench-security | $0 |
| AWS native (optional) | CIS v5.0 continuous monitoring | AWS Security Hub | $0 for 30 days, then ~$2/mo |

---

## Quick start (all three layers)

```bash
# 1. Copy CIS scripts to the EC2 instance
source config/bootstrap-outputs.env
scp -i "$KEY_FILE" cis/*.sh ec2-user@${EIP}:/opt/affine/

# 2. SSH in
ssh -i "$KEY_FILE" ec2-user@${EIP}

# 3. Install tools (run once)
chmod +x /opt/affine/cis-*.sh
/opt/affine/cis-01-install-prowler.sh

# 4. Run all three layers
/opt/affine/cis-02-run-checks.sh --layer all

# 5. Apply safe remediations
/opt/affine/cis-03-remediate.sh

# 6. Re-scan to verify fixes
/opt/affine/cis-02-run-checks.sh --quick

# 7. Copy reports back to local machine
exit
scp -r -i "$KEY_FILE" ec2-user@${EIP}:/opt/affine/cis-reports ./
```

---

## Layer 1 — AWS Foundations (Prowler CIS)

Prowler checks the CIS AWS Foundations Benchmark v4.0/v5.0, covering:

### What gets checked

| CIS section | Controls | Examples |
|---|---|---|
| 1. IAM | 1.1–1.20 | Root MFA, password policy, access key rotation, unused credentials |
| 2. Storage | 2.1–2.7 | S3 public access block, versioning, encryption |
| 3. Logging | 3.1–3.11 | CloudTrail enabled, log validation, S3 logging |
| 4. Monitoring | 4.1–4.16 | CloudWatch alarms for root usage, config changes |
| 5. Networking | 5.1–5.6 | VPC flow logs, security group rules, default VPC |

### Run options

```bash
# Full CIS Level 1 scan (recommended)
prowler aws --compliance cis_level1_aws \
  --services iam,s3,ec2,vpc,cloudtrail \
  --output-formats html,json \
  --output-directory /opt/affine/cis-reports

# CIS Level 2 (stricter — more findings expected)
prowler aws --compliance cis_level2_aws ...

# Only critical findings (fast)
prowler aws --compliance cis_level1_aws --severity critical,high ...

# View results in terminal
prowler aws --compliance cis_level1_aws --no-banner 2>&1 | tee report.txt
```

### Expected findings for demo (acceptable)

| Finding | CIS control | Why acceptable for demo |
|---|---|---|
| CloudTrail not enabled | 3.1 | No log retention budget; enable for production |
| Root MFA not enforced | 1.5 | Root account not used; enable for production |
| Config recorder off | 3.5 | Costs ~$1/mo; enable in production |
| GuardDuty not enabled | — | Costs ~$4/mo; not required for demo |
| Password policy not set | 1.9 | No human IAM users except deployer |
| VPC flow logs off | 5.4 | Skipped for cost; optional S3 storage |

---

## Layer 2 — OS Hardening (Lynis)

Lynis performs a local system audit mapping to CIS Linux Benchmark Level 1/2.

```bash
# Standard audit
sudo lynis audit system

# Generate machine-readable report
sudo lynis audit system --quiet --report-file /opt/affine/cis-reports/lynis.txt

# Audit only specific categories
sudo lynis audit system --tests-category "authentication,filesystems,networking"
```

### Hardening index targets

| Score | Assessment |
|---|---|
| 0–49 | Poor — needs significant hardening |
| 50–64 | Fair — basic hardening present |
| 65–79 | Good — acceptable for demo |
| 80–100 | Strong — production-ready |

A fresh Amazon Linux 2023 instance typically scores 55–65. After running `cis-03-remediate.sh`, expect 68–75.

### Key areas Lynis checks

- Authentication (SSH config, PAM, password policies)
- File system (mount options, permissions, SUID binaries)
- Logging (syslog, auditd, log rotation)
- Networking (firewall, kernel parameters, port listening)
- Software (outdated packages, unused services)
- Malware scanning (if tools present)

---

## Layer 3 — Docker CIS Benchmark

docker-bench-security checks the CIS Docker Benchmark against the AFFiNE container stack.

```bash
cd /opt/prowler/docker-bench-security

# Scan all running containers
sudo sh docker-bench-security.sh

# Scope to AFFiNE containers only
sudo sh docker-bench-security.sh \
  -c container_images,container_runtime \
  -t affine_server,affine_postgres,affine_redis

# Output formats
sudo sh docker-bench-security.sh -f json -l /tmp/docker-bench.json
```

### CIS Docker benchmark sections

| Section | Description |
|---|---|
| 1 | Host configuration |
| 2 | Docker daemon configuration |
| 3 | Docker daemon configuration files |
| 4 | Container images and build files |
| 5 | Container runtime |
| 6 | Docker security operations |
| 7 | Docker Swarm configuration |

### Expected findings for AFFiNE demo

| Finding | Why |
|---|---|
| Containers run as root | AFFiNE default — harden in production by adding `user: 1000:1000` in compose |
| No read-only rootfs | AFFiNE requires write access for local storage |
| icc disabled (after remediation) | Inter-container communication locked down |
| No resource limits set | Add `mem_limit`, `cpus` to compose for production |

---

## Optional: AWS Security Hub (30-day free trial)

For continuous, automatic CIS monitoring via the AWS console:

```bash
# Enable (run from LOCAL machine)
./cis/cis-04-enable-securityhub.sh

# View findings in AWS console:
# https://console.aws.amazon.com/securityhub/home#/standards

# Disable before day 30 (to avoid charges)
./cis/cis-04-enable-securityhub.sh --disable
```

Security Hub provides:
- 40 automated controls against CIS AWS Foundations Benchmark v5.0
- Continuous monitoring (checks re-run every 12–24 hours)
- Remediation guidance per control
- A perpetual free tier of 10,000 finding ingestion events per month after the trial

Cost after trial for this demo (1 account, 1 region, ~250 checks/month):
- Security Hub CSPM: ~$1–2/month
- AWS Config (required): ~$0.50–1/month
- Total: ~$2–3/month

---

## Cost summary

| Approach | Monthly cost | Coverage |
|---|---|---|
| Prowler + Lynis + docker-bench (recommended) | **$0** | All 3 layers |
| Add Security Hub trial | **$0** for 30 days | + continuous AWS monitoring |
| Security Hub after trial | **~$2–3/mo** | AWS layer continuous |
| Full production stack (+ GuardDuty + Config) | **~$8–12/mo** | Enterprise grade |

---

## Interpreting and acting on results

### Priority order for a demo

1. Fix any `CRITICAL` or `HIGH` Prowler findings first — these represent real risk
2. Accept all "known acceptable" findings documented above
3. Aim for Lynis score ≥ 65
4. Review Docker warnings — most are acceptable for dev/demo

### Before going to production

Replace "demo-acceptable" findings with:
- CloudTrail enabled in all regions
- GuardDuty enabled
- MFA on all IAM users
- Container users set to non-root
- Resource limits on all containers
- VPC flow logs enabled
- AWS Config recorder running
