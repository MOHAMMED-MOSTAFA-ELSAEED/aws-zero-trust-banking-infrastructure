#!/bin/bash
set -xe

# 1. Update & Base Setup
dnf update -y
dnf install -y python3

# 2. Kernel Hardening for FinTech PCI-DSS
cat << 'EOF' > /etc/sysctl.d/99-fintech.conf
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_forward = 0
EOF
sysctl --system

# 3. Deploy Mock Payment Gateway Service
mkdir -p /opt/fintech-core
cat << 'EOF' > /opt/fintech-core/app.py
#!/usr/bin/env python3
from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import socket

class PaymentHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "HEALTHY",
                "instance": socket.gethostname(),
                "tier": "PCI-DSS-Production-App",
                "zero_trust": "Enforced"
            }).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == '/api/v1/transaction':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                "transaction_id": "TX-998241",
                "status": "APPROVED",
                "amount": "100,000.00 USD",
                "cleared_via": "Core-Banking-Cairo",
                "compliance": "PCI-DSS-Level-1"
            }).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == '__main__':
    HTTPServer(('0.0.0.0', 8080), PaymentHandler).serve_forever()
EOF

chmod +x /opt/fintech-core/app.py

# 4. Create Systemd Unit
cat << 'EOF' > /etc/systemd/system/fintech-core.service
[Unit]
Description=FinTech Core Transaction Processing Daemon
After=network.target

[Service]
Type=simple
User=ec2-user
ExecStart=/usr/bin/python3 /opt/fintech-core/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now fintech-core.service