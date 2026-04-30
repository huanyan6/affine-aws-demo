# AFFiNE Demo on AWS — Complete Deployment Guide

**Audience:** Developer with an AWS account, comfortable with a terminal.  
**Goal:** Spin up a working AFFiNE demo at near-zero cost using the AWS Free Tier.  
**Time:** ~20 minutes end-to-end.

---

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [AWS best-practice setup (automated)](#2-aws-best-practice-setup)
3. [Launch EC2 instance (automated)](#3-launch-ec2-instance)
4. [Deploy AFFiNE on the server (automated)](#4-deploy-affine)
5. [Access the application](#5-access-the-application)
6. [Test the application functions](#6-test-the-application)
7. [Cost summary](#7-cost-summary)
8. [Teardown (when done)](#8-teardown)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Prerequisites

### On your local machine

| Requirement | Version | Check |
|---|---|---|
| AWS CLI v2 | 2.x | `aws --version` |
| AWS credentials configured | admin or power user | `aws sts get-caller-identity` |
| `curl`, `openssl` | system default | `which curl openssl` |
| `python3` | 3.8+ | `python3 --version` |
| SSH client | system default | `which ssh` |

**Install AWS CLI (if needed):**
```bash
# macOS
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# Configure with your IAM credentials
aws configure
# Enter: Access Key ID, Secret Access Key, Region (e.g. ap-southeast-2), Output: json
```

### Clone this repository

```bash
git clone <this-repo> affine-aws-demo
cd affine-aws-demo
chmod +x scripts/*.sh
```

---

## 2. AWS best-practice setup

Script `01-aws-bootstrap.sh` creates the following AWS resources following least-privilege and isolation principles:

| Resource | What & why |
|---|---|
| **VPC** `affine-demo-vpc` | Isolated network — don't use the default VPC for projects |
| **Public subnet** | Single subnet in one AZ — sufficient for a demo |
| **Internet Gateway + Route Table** | Allows the EC2 instance to reach the internet |
| **Security Group** `affine-demo-sg` | Port 443 open to world; port 22 SSH restricted to **your IP only** |
| **EC2 Key Pair** | SSH access — private key saved to `~/.ssh/affine-demo-key.pem` |
| **IAM Policy** | Least-privilege S3 access — read/write only to the demo bucket |
| **IAM Group** `affine-demo-group` | Group with the S3 policy attached |
| **IAM User** `affine-demo-deployer` | Non-root user for AFFiNE's S3 credentials |
| **S3 Bucket** | Private bucket for file uploads; public access blocked |
| **Elastic IP** | Static public IP so the address doesn't change on restart |

```bash
# Run once from your local machine
./scripts/01-aws-bootstrap.sh
```

Outputs are saved to `config/bootstrap-outputs.env` (contains secrets — do not commit to git).

> **Region note:** The script defaults to `ap-southeast-2` (Sydney).  
> Override with: `AWS_DEFAULT_REGION=us-east-1 ./scripts/01-aws-bootstrap.sh`

---

## 3. Launch EC2 instance

Script `02-launch-ec2.sh` launches a **t2.micro** (Free Tier eligible) instance and injects a user-data bootstrap that automatically installs:

- Docker Engine
- Docker Compose v2
- Nginx
- Certbot (for optional Let's Encrypt TLS)

```bash
./scripts/02-launch-ec2.sh
```

Wait for the script to complete (~3 minutes). At the end it prints:
```
EC2 ready!  Public IP: 13.x.x.x
SSH: ssh -i ~/.ssh/affine-demo-key.pem ec2-user@13.x.x.x
Next: copy config files and run 03-configure-affine.sh
```

**Wait an additional 2 minutes** for user-data to finish before proceeding. You can verify:
```bash
# Check if user-data finished
ssh -i ~/.ssh/affine-demo-key.pem ec2-user@<EIP> \
  "tail -5 /var/log/affine-setup.log"
# Should end with: === AFFiNE setup complete ===
```

---

## 4. Deploy AFFiNE

### 4a. Copy config to the server

```bash
# Load the EIP from outputs
source config/bootstrap-outputs.env

# Copy the outputs file to the server
scp -i "$KEY_FILE" config/bootstrap-outputs.env \
  ec2-user@${EIP}:/opt/affine/

# Copy the configure script
scp -i "$KEY_FILE" scripts/03-configure-affine.sh \
  ec2-user@${EIP}:/opt/affine/
```

### 4b. SSH in and run the configure script

```bash
ssh -i ~/.ssh/affine-demo-key.pem ec2-user@$EIP
```

Once inside the EC2 instance:

```bash
# Option A — IP only (self-signed cert, browser warning)
chmod +x /opt/affine/03-configure-affine.sh
sudo /opt/affine/03-configure-affine.sh

# Option B — With a real domain (free Let's Encrypt cert, no browser warning)
# First: point your domain's A record to $EIP, wait for DNS to propagate
sudo /opt/affine/03-configure-affine.sh --domain yourdomain.com
```

The script will:
1. Generate a secure `POSTGRES_PASSWORD` and `AFFINE_SECRET`
2. Write `/opt/affine/.env` and `/opt/affine/docker-compose.yml`
3. Configure Nginx as a reverse proxy with WebSocket passthrough
4. Pull and start the AFFiNE stack via Docker Compose
5. Enable the `pgvector` extension in PostgreSQL
6. Optionally obtain a Let's Encrypt TLS certificate

When it finishes, you'll see:
```
AFFiNE is running!
  Access URL: https://13.x.x.x
```

### 4c. What's running inside the instance

```
┌─ Docker Compose stack ────────────────────────────────┐
│                                                        │
│  affine_server   (Node.js, port 3010)                 │
│  affine_postgres (PostgreSQL 16 + pgvector)           │
│  affine_redis    (Redis 7 Alpine)                     │
│                                                        │
│  Nginx (host, port 80 + 443) → proxy to 3010          │
└────────────────────────────────────────────────────────┘
```

### Useful management commands (run on EC2)

```bash
# View all service statuses
docker compose -f /opt/affine/docker-compose.yml ps

# Follow AFFiNE server logs
docker compose -f /opt/affine/docker-compose.yml logs -f affine

# Restart the stack
docker compose -f /opt/affine/docker-compose.yml restart

# Pull latest AFFiNE image and redeploy
docker compose -f /opt/affine/docker-compose.yml pull
docker compose -f /opt/affine/docker-compose.yml up -d

# Access PostgreSQL
docker exec -it affine_postgres psql -U affine -d affine

# Access Redis
docker exec -it affine_redis redis-cli
```

---

## 5. Access the application

### First-time setup

1. Open **`https://<EIP>`** in your browser
   - If using a self-signed cert: click **Advanced → Proceed** (Chrome) or **Accept Risk** (Firefox)
2. You'll see the AFFiNE welcome screen
3. Click **Create account** (first user automatically becomes workspace owner)
4. Enter email + password → click **Sign up**
5. You land on your personal workspace

### Inviting collaborators (demo use)

1. Go to **Settings → Members**
2. Click **Invite member** → enter their email
3. They receive an invite link and can join the same workspace

> **Note:** AFFiNE self-hosted does not include an SMTP server by default.  
> Invite links are shown on-screen — copy and share manually for the demo.

---

## 6. Test the application functions

### 6a. Automated test suite

```bash
# From your local machine
source config/bootstrap-outputs.env
./scripts/04-test-affine.sh --host $EIP --skip-tls-verify

# From inside EC2 (includes Docker + PostgreSQL + Redis checks)
./04-test-affine.sh --host localhost --skip-tls-verify
```

Expected output:
```
[PASS] HTTPS responds
[PASS] HTTP redirects to HTTPS
[PASS] Server info endpoint returns data
[PASS] GraphQL endpoint responds
[PASS] Root page loads
[PASS] Nginx passes WebSocket headers
[PASS] S3 write succeeded
[PASS] PostgreSQL is accessible
[PASS] pgvector extension installed
[PASS] Redis responds to PING

Results: 10 passed  |  0 failed  |  0 skipped
All checks passed! AFFiNE demo is operational.
```

### 6b. Manual function checklist

Work through this list in the browser to validate all major features:

#### Documents
- [ ] Create a new page (click `+` in sidebar)
- [ ] Type using the block editor — headings, bullet lists, checkboxes
- [ ] Use `/` command menu to insert different block types
- [ ] Drag blocks to reorder them

#### Database (Notion-equivalent)
- [ ] Create a new database via `/Database`
- [ ] Switch between **Table**, **Kanban**, **Calendar**, and **Grid** views
- [ ] Add properties (text, number, date, select)
- [ ] Filter and sort rows

#### Whiteboard (AFFiNE's unique feature)
- [ ] Open any page → click **Edgeless** button (top right)
- [ ] Draw shapes on the infinite canvas
- [ ] Add sticky notes and text
- [ ] Embed a page inside the whiteboard
- [ ] Switch back to **Page** mode

#### Real-time collaboration
- [ ] Open the same page in a **second browser tab** (or incognito)
- [ ] Type in tab 1 — confirm it appears in tab 2 within ~1 second
- [ ] Both tabs show the live cursor position

#### File uploads (S3)
- [ ] In any page, drag and drop an image file
- [ ] Confirm the image renders (it's stored in your S3 bucket)
- [ ] Check your S3 bucket in the AWS console — file should appear

#### Workspace settings
- [ ] Go to **Settings** → explore Members, Appearance, Workspace
- [ ] Create a second workspace (workspace switcher, bottom left)

---

## 7. Cost summary

### AWS Free Tier (first 12 months)

| Service | Free Tier allowance | Demo usage | Cost |
|---|---|---|---|
| EC2 t2.micro | 750 hrs/month | ~744 hrs (24/7) | **$0** |
| EBS gp3 20 GB | 30 GB/month | 20 GB | **$0** |
| S3 storage | 5 GB | < 1 GB (demo) | **$0** |
| S3 requests | 20,000 GET/month | Minimal | **$0** |
| Elastic IP | Free while attached | 1 IP | **$0** |
| Data transfer out | 100 GB/month | Minimal | **$0** |
| **Total** | | | **~$0/month** |

### After Free Tier expires (month 13+)

| Service | Monthly cost |
|---|---|
| EC2 t2.micro on-demand | ~$8.50 |
| EBS gp3 20 GB | ~$1.60 |
| S3 (light usage) | < $0.50 |
| **Total** | **~$10.60/month** |

> **Tip:** Stop the EC2 instance when not in use to save on compute costs.  
> `aws ec2 stop-instances --instance-ids $INSTANCE_ID`  
> Note: Elastic IP incurs a small charge (~$0.005/hr) while NOT attached to a running instance.

---

## 8. Teardown

When you're done with the demo, run the teardown script to remove **all** AWS resources and avoid any future charges:

```bash
# From your local machine
./scripts/05-teardown.sh
```

The script will list everything it's about to delete and ask for confirmation before proceeding.

---

## 9. Troubleshooting

### AFFiNE server won't start

```bash
# Check container logs
docker compose -f /opt/affine/docker-compose.yml logs affine

# Common cause: PostgreSQL not ready yet
docker compose -f /opt/affine/docker-compose.yml restart affine
```

### "502 Bad Gateway" from Nginx

```bash
# Check if AFFiNE container is running
docker ps | grep affine_server

# Check AFFiNE health
curl -s http://localhost:3010/info

# Check Nginx error log
sudo tail -50 /var/log/nginx/error.log
```

### Can't connect via SSH

- Verify your IP hasn't changed: `curl https://checkip.amazonaws.com`
- Update the security group inbound rule with your new IP:
  ```bash
  source config/bootstrap-outputs.env
  NEW_IP=$(curl -s https://checkip.amazonaws.com)/32
  # Get the old SSH rule ID
  RULE_ID=$(aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=$SG_ID" \
    --query "SecurityGroupRules[?FromPort==\`22\`].SecurityGroupRuleId" \
    --output text)
  aws ec2 modify-security-group-rules \
    --group-id $SG_ID \
    --security-group-rules \
    "SecurityGroupRuleId=$RULE_ID,SecurityGroupRule={IpProtocol=tcp,FromPort=22,ToPort=22,CidrIpv4=$NEW_IP}"
  ```

### Database migration errors on first boot

```bash
# Re-run the predeploy migration manually
docker exec affine_server sh -c "node ./scripts/self-host-predeploy"
docker compose -f /opt/affine/docker-compose.yml restart affine
```

### Out of memory (t2.micro has 1 GB RAM)

```bash
# Add 1 GB swap to extend available memory
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### Self-signed cert warning in browser

This is expected when running without a domain. Two options:
1. Accept the browser warning (fine for demo)
2. Get a free real domain from [Freenom](https://www.freenom.com) or use a `nip.io` subdomain:
   - Your domain becomes `<EIP>.nip.io` — no DNS setup needed
   - Run: `sudo /opt/affine/03-configure-affine.sh --domain <EIP>.nip.io`
