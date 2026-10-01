<div align="center">

# 🏛️ Autonomous FinTech Core Fabric

**A zero-trust, dual-AZ payment processing architecture on AWS, designed against PCI-DSS v4.0 controls and connected to an on-premises core banking site over IPsec/BGP.**

[![AWS](https://img.shields.io/badge/AWS-Multi--AZ-FF9900?style=for-the-badge&logo=amazon-aws&logoColor=white)](https://aws.amazon.com/)
[![PCI-DSS](https://img.shields.io/badge/PCI--DSS_v4.0-Aligned-008559?style=for-the-badge)](#-pci-dss-v40-control-mapping)
[![Zero Trust](https://img.shields.io/badge/Access-Zero--Trust_(SSM)-critical?style=for-the-badge)](#-security-design)
[![KMS](https://img.shields.io/badge/Encryption-KMS_CMK-blue?style=for-the-badge&logo=amazon-aws&logoColor=white)](#-security-design)
[![Transit Gateway](https://img.shields.io/badge/Hybrid-Transit_Gateway_%2B_BGP-8C4FFF?style=for-the-badge)](#-transaction-flow)

[Overview](#-overview) · [Architecture](#-architecture) · [Security](#-security-design) · [PCI-DSS Mapping](#-pci-dss-v40-control-mapping) · [Transaction Flow](#-transaction-flow) · [Verification Gallery](#-verification-gallery) · [Hardening](#-os--kernel-hardening) · [Resilience](#-resilience--failure-modes) · [Sample Service](#-sample-clearing-service) · [Author](#-author)

</div>

---

## 📌 Overview

Perimeter-only defense is not enough for financial workloads. This project implements a reference payment infrastructure built on three principles:

| Principle | What it means here |
| :--- | :--- |
| **Network micro-segmentation** | Compute and data tiers have no route to the internet. The data tier's route table contains only the local VPC route. |
| **Zero standing access** | No bastion hosts, no SSH (port 22), no long-lived credentials. Administration goes through AWS Systems Manager over PrivateLink. |
| **Cryptographic immutability** | Audit records are encrypted with a customer-managed KMS key and stored in a versioned, locked-down S3 vault. |

> **Scope note:** This is a reference architecture and lab deployment. The clearing service is a mock that returns canned responses, and "PCI-DSS aligned" means the design maps to PCI-DSS v4.0 controls. It is **not** a formal compliance attestation.

---

## 🏗️ Architecture

<div align="center">
  <img src="architecture.png" alt="High-level architecture diagram" width="100%">
</div>

### Design highlights

- **Dual-AZ, active/active:** Resources span `eu-west-1a` and `eu-west-1b` behind a cross-zone load balancer.
- **Three-tier subnet model:**
  - **Public tier:** Application Load Balancer and AWS WAF only.
  - **Private tier:** Payment engines with no public IPs and no direct internet path.
  - **Isolated data tier:** Aurora and ElastiCache (Valkey), with route tables containing only `10.100.0.0/16 → local`.
- **Private administration:** SSM, EC2 Messages, and SSM Messages interface endpoints replace SSH and bastions.
- **Hybrid connectivity:** Transit Gateway with IPsec Site-to-Site VPN and BGP (ASN 64512 ↔ 65000) to the on-premises core banking site.

### Component matrix

| Layer | Subnets | Services | High availability | Key controls |
| :--- | :--- | :--- | :--- | :--- |
| **Ingress** | `10.100.1.0/24`, `10.100.2.0/24` | AWS WAF v2, public ALB | Multi-AZ, cross-zone | OWASP Core Rule Set, SQLi rules, rate limiting, HTTPS only |
| **Compute** | `10.100.10.0/24`, `10.100.20.0/24` | EC2, Systems Manager | Multi-AZ, health-checked target group | No public IPs, port 22 closed, SSM via PrivateLink |
| **Data** | `10.100.30.0/24`, `10.100.40.0/24` | Aurora PostgreSQL, ElastiCache (Valkey) | Multi-AZ | Local-only routing |
| **Crypto & audit** | Managed plane | KMS CMK, S3 vault | 11 nines durability (S3) | SSE-KMS, versioning, Block Public Access |
| **Hybrid transit** | Dedicated TGW subnets | Transit Gateway, Site-to-Site VPN | Dual tunnels, BGP | IPsec AES-GCM-256 |

---

## 🔐 Security Design

- **Network isolation:** Private and data tiers have no `0.0.0.0/0` route. Security groups allow port 8080 only from the ALB's security group.
- **Identity-based access:** Instances use an IAM role (`AmazonSSMManagedInstanceCore` plus a scoped inline policy limited to the audit bucket).
- **Encryption at rest:** A dedicated KMS customer-managed key (`alias/fintech-core`) with automatic annual rotation protects the persistence layers.
- **Encryption in transit:** TLS terminates at the ALB; AWS service traffic uses VPC endpoints; the hybrid link uses IPsec.
- **Edge protection:** AWS WAF v2 filters SQLi, XSS, and floods (rate limit: 500 requests/min per client).
- **Tamper-resistant audit trail:** Logs are written to a versioned, SSE-KMS encrypted S3 bucket with all Block Public Access settings enabled.

---

## 🔒 PCI-DSS v4.0 Control Mapping

| Requirement | Control implemented | Evidence |
| :--- | :--- | :--- |
| **1.2** Network segmentation | Three-tier VPC; isolated data tier | Route table audit ([#02](#module-1--network-topology), [#03](#module-1--network-topology)) |
| **2.2** Secure configuration | SSH removed, no inbound admin ports, hardened sysctl profile | Security group review ([#16](#module-4--compute--data-tier)) |
| **3.5** Protect stored data | KMS CMK, SSE-KMS, key rotation | KMS key status ([#06](#module-2--identity--cryptography)) |
| **4.2** Protect data in transit | TLS at ingress, VPC endpoints, IPsec to on-prem | Endpoint status ([#04](#module-1--network-topology)) |
| **6.4** Protect web applications | WAF v2 with OWASP rules attached to the ALB | WAF rules and association ([#11](#module-3--edge--load-balancing), [#12](#module-3--edge--load-balancing)) |
| **10.2 / 10.3** Audit logs | Versioned, encrypted S3 vault; scoped write access | Vault properties ([#07](#module-2--identity--cryptography)) |

> **Note:** Control numbers should be validated against your assessor's reading of the standard before use in any formal document.

---

## 🔄 Transaction Flow

```mermaid
flowchart TD
    C["Client (cardholder / bank)"] -->|"HTTPS, TLS 1.3, 443"| W["AWS WAF v2<br/>SQLi · XSS · rate limit"]
    W --> A["Public ALB (Multi-AZ)<br/>TLS termination"]
    A -->|"8080, from ALB SG only"| E["Private payment engines<br/>eu-west-1a / 1b"]
    E -->|"6379"| D["Isolated data tier<br/>ElastiCache · Aurora"]
    E -->|"VPC endpoint"| S["S3 audit vault (SSE-KMS)"]
    E --> T["Transit Gateway<br/>BGP ASN 64512"]
    T -->|"IPsec tunnels"| H["Cairo HQ core banking<br/>ASN 65000 · mainframe"]
```

1. **Edge filtering:** The client connects over HTTPS; WAF inspects and rate-limits requests.
2. **Reverse proxy:** The ALB terminates TLS and forwards clean traffic to healthy private targets on port 8080.
3. **Processing:** The engine validates the session against the in-memory cache and generates a clearing response.
4. **Audit:** An audit object is written to the S3 vault through the VPC endpoint, without internet access.
5. **Settlement:** Cleared payloads are forwarded over the Transit Gateway and IPsec/BGP tunnels to the on-premises mainframe.

---

## 📸 Verification Gallery

All 20 artifacts below are screenshots from the live deployment.

### Module 1 · Network Topology

| | |
| :---: | :---: |
| **01 · Multi-AZ resource map**<br/><img src="screenshots/01-vpc-resource-map.png" alt="VPC resource map"/><br/>Six subnets across two AZs; nothing sensitive in public subnets. | **02 · Private app route table**<br/><img src="screenshots/02-private-route-table.png" alt="Private route table"/><br/>No `0.0.0.0/0 → igw` route. |
| **03 · Isolated data route table**<br/><img src="screenshots/03-isolated-route-table.png" alt="Isolated route table"/><br/>Only `10.100.0.0/16 → local`. | **04 · VPC endpoints**<br/><img src="screenshots/04-vpc-endpoints-hub.png" alt="VPC endpoints"/><br/>SSM, KMS interface endpoints and S3 gateway endpoint available. |

**05 · Private DNS resolution**
<div align="center"><img src="screenshots/05-ssm-endpoint-dns.png" width="70%" alt="Private DNS resolution"/></div>

Internal lookups of `ssm.eu-west-1.amazonaws.com` resolve to private endpoint IPs.

### Module 2 · Identity & Cryptography

| | |
| :---: | :---: |
| **06 · KMS CMK**<br/><img src="screenshots/06-kms-key-status.png" alt="KMS key status"/><br/>`alias/fintech-core`, rotation enabled. | **07 · S3 vault properties**<br/><img src="screenshots/07-s3-vault-properties.png" alt="S3 vault properties"/><br/>SSE-KMS and versioning enabled. |
| **08 · Block Public Access**<br/><img src="screenshots/08-s3-block-public-access.png" alt="Block Public Access"/><br/>All four settings on. | **09 · IAM role**<br/><img src="screenshots/09-iam-role-policies.png" alt="IAM role policies"/><br/>SSM core policy plus inline policy. |

**10 · Scoped inline policy**
<div align="center"><img src="screenshots/10-iam-inline-policy.png" width="70%" alt="IAM inline policy"/></div>

`PutObject`, `GetObject`, and `ListBucket` restricted to the audit vault ARN.

### Module 3 · Edge & Load Balancing

| | |
| :---: | :---: |
| **11 · WAF rules**<br/><img src="screenshots/11-waf-rules-dashboard.png" alt="WAF rules"/><br/>Core Rule Set and SQLi protections. | **12 · WAF ↔ ALB association**<br/><img src="screenshots/12-waf-alb-association.png" alt="WAF association"/><br/>Web ACL bound to the public ALB. |
| **13 · ALB configuration**<br/><img src="screenshots/13-alb-details.png" alt="ALB details"/><br/>Internet-facing, dual-AZ, dedicated security group. | **14 · Target health**<br/><img src="screenshots/14-target-group-healthy.png" alt="Target group health"/><br/>2/2 targets healthy on port 8080. |

### Module 4 · Compute & Data Tier

| | |
| :---: | :---: |
| **15 · Private instances**<br/><img src="screenshots/15-ec2-private-instances.png" alt="EC2 private instances"/><br/>RFC 1918 addresses only; no public IPv4. | **16 · App security group**<br/><img src="screenshots/16-app-security-group.png" alt="App security group"/><br/>Port 8080 allowed only from the ALB security group. |

**17 · Isolated data tier**
<div align="center"><img src="screenshots/17-isolated-data-tier.png" width="70%" alt="Isolated data tier"/></div>

ElastiCache (Valkey) running inside the isolated subnets.

### Module 5 · Live Execution

**18 · S3 audit write via SSM (no internet)**
<div align="center"><img src="screenshots/18-ssm-s3-audit-upload.png" width="80%" alt="SSM S3 upload"/></div>

| | |
| :---: | :---: |
| **19 · Health check**<br/><img src="screenshots/19-api-health-check.png" alt="API health check"/><br/>`GET /health` through WAF and ALB returns 200. | **20 · Transaction POST**<br/><img src="screenshots/20-api-live-transaction-post.png" alt="Transaction POST"/><br/>`POST /api/v1/transaction` returns an approved response. |

---

## 🛠️ Deployment

- **Provisioning:** AWS Console and AWS CLI (CloudShell).
- **Bootstrap:** EC2 user-data scripts install the service as an unprivileged `systemd` unit and apply the kernel hardening profile below.
- **Validation:** Route table review, port-scan checks, and audit-write tests, followed by resource teardown to control cost.

---

## 🐧 OS & Kernel Hardening

Applied at boot via `/etc/sysctl.d/99-pci-dss-hardening.conf` (aligned with CIS Linux benchmark guidance):

```ini
# Reverse-path filtering (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0

# Nodes must not route traffic
net.ipv4.ip_forward = 0

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096

# Memory protections
fs.suid_dumpable = 0
kernel.randomize_va_space = 2
```

---

## ⚡ Resilience & Failure Modes

Expected behavior for each failure domain. Replace the recovery column with your own measured values if you run fault-injection tests.

| Scenario | Self-healing mechanism | Expected recovery |
| :--- | :--- | :--- |
| AZ failure | ALB health checks remove unhealthy targets; traffic shifts to the surviving AZ | A few health-check cycles |
| Aurora primary failure | Automatic Multi-AZ failover; cluster endpoint DNS points to the new primary | Typically tens of seconds |
| VPN tunnel failure | BGP withdraws the failed path; traffic moves to the second tunnel | Seconds (depends on BGP timers) |
| Compromised instance | No local keys or SSH; revoking the IAM role terminates SSM access | Immediate on revocation |

---

## 💻 Sample Clearing Service

The payment engine is a mock built on the Python 3 standard library only (no third-party packages). It returns canned responses to demonstrate the traffic path; it does not process real payments.

<details>
<summary><b>View source (<code>app/clearing_daemon.py</code>)</b></summary>

```python
#!/usr/bin/env python3
"""Mock financial clearing daemon (standard library only)."""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import socket
import sys


class FinancialClearingHandler(BaseHTTPRequestHandler):
    def _send_response(self, code: int, payload: dict):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Strict-Transport-Security",
                         "max-age=63072000; includeSubDomains")
        self.end_headers()
        self.wfile.write(json.dumps(payload, indent=2).encode("utf-8"))

    def do_GET(self):
        if self.path == "/health":
            self._send_response(200, {
                "status": "HEALTHY",
                "instance_node": socket.gethostname(),
                "tier": "PCI-DSS-Production-App",
                "zero_trust_status": "Strict-Enforced",
            })
        else:
            self._send_response(404, {"error": "Resource Not Found"})

    def do_POST(self):
        if self.path == "/api/v1/transaction":
            self._send_response(200, {
                "transaction_id": "TX-998241",
                "status": "APPROVED",
                "amount": "100,000.00 USD",
                "cleared_via": "Core-Banking-Cairo",
                "transit_route": "AWS-TGW-IPsec-BGP-Active",
                "compliance": "PCI-DSS-v4.0-Level-1",
            })
        else:
            self._send_response(404, {"error": "Invalid Clearing Route"})


def run_server():
    httpd = HTTPServer(("0.0.0.0", 8080), FinancialClearingHandler)
    print("[*] Financial core daemon listening on port 8080...")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] Shutting down...")
        httpd.server_close()
        sys.exit(0)


if __name__ == "__main__":
    run_server()
```

</details>

---

## 👨‍💻 Author

**Mohammed Mostafa Elsaeed**
Cloud Infrastructure & DevOps Engineer · Computer Engineering, Ain Shams University

[![LinkedIn](https://img.shields.io/badge/LinkedIn-Connect-0A66C2?style=for-the-badge&logo=linkedin)](https://www.linkedin.com/in/mohammed-mostafa-elsaeed/)
[![GitHub](https://img.shields.io/badge/GitHub-Profile-181717?style=for-the-badge&logo=github)](https://github.com/MOHAMMED-MOSTAFA-ELSAEED)

- **Certifications:** AWS Certified Solutions Architect – Associate (SAA-C03) · AWS Certified Cloud Practitioner
- **Specialization:** Cloud networking, zero-trust architecture, DevSecOps, enterprise Linux (RHEL)
- **Focus:** Banking-grade infrastructure, hybrid routing, PCI-DSS alignment, key management

---

<div align="center"><sub>Reference architecture for financial cloud infrastructure, designed against PCI-DSS v4.0 controls.</sub></div>
