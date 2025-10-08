# IMDSv1 Security Lab - fck-nat Cost Optimization

## 💰 AWS Cost Estimate (us-east-1) - Updated with fck-nat

| Branch | Monthly Cost | Key Changes | Savings |
|--------|-------------|-------------|---------|
| **Branch 1-2 (fck-nat)** | **$21.38** | **NAT Gateway → fck-nat (t3.nano)** | **~$28/month** |
| Branch 3-4 (original) | $16.78 | Basic lab setup | Baseline |
| Branch 5 (enterprise) | $41.02 | + RDS + Backend API + Secrets Manager | Full featured |

### fck-nat Cost Breakdown (Branches 1-2)
| Resource | Monthly Cost | Notes |
|----------|-------------|-------|
| **fck-nat (t3.nano)** | **$4.60** | **$3.80 instance + $0.80 storage** |
| EC2 Instances (2x t3.micro) | $16.78 | Bastion + Web Server |
| CloudTrail, CloudWatch, DynamoDB | Variable | Usage-based pricing |
| **vs. NAT Gateway** | **~$32.85** | **$32.40 hourly + data processing** |

### **Cost Optimization Benefits**
- ✅ **90% NAT cost reduction**: $32.85 → $4.60/month  
- ✅ **Same functionality**: Full NAT capabilities with fck-nat AMI
- ✅ **Better security**: Instance-level controls vs managed service
- ✅ **Flexible configuration**: Custom rules and monitoring possible

*Generated with Infracost on 2025-10-08*

---

## Overview
This lab has been **rearchitected** to use **fck-nat** instead of AWS Managed NAT Gateway for significant cost savings while maintaining security and functionality.

## fck-nat Implementation (Branches 1-2)

### What is fck-nat?
- **Feasible Cost Konfigurable NAT**: Open-source NAT instance AMI
- **Built on Amazon Linux 2023**: Always up-to-date with latest security patches  
- **ARM64 & x86_64 support**: Cost-effective on t4g.nano or t3.nano instances
- **5Gbps burst capability**: Handles up to 5Gbps NAT traffic
- **90% cost reduction**: vs AWS Managed NAT Gateway

### Architecture Changes
```diff
- AWS Managed NAT Gateway ($32.85/month)
+ fck-nat instance (t3.nano, $4.60/month)

Network Flow:
Internet → IGW → Public Subnet (fck-nat)
                      ↓
Private Subnet (Web Server) → fck-nat → Internet

Security:
+ IMDSv2 enforced on fck-nat instance
+ Source/destination checks disabled
+ Dedicated security group for NAT traffic
+ Route table configured for private subnet
```

### Security Benefits
- ✅ **Instance-level security controls**: Custom security groups and NACLs
- ✅ **IMDSv2 enforced**: fck-nat instance protected against metadata attacks
- ✅ **Monitoring capability**: CloudWatch logs and custom monitoring possible
- ✅ **Update control**: Manual control over AMI updates and patches

## Current Security Posture (FULLY SECURE)
- ✅ **IMDSv2 enforced** (requires session token, prevents simple SSRF)
- ✅ **SSRF protection implemented** (blocks metadata and private IPs)
- ✅ **VPC Endpoint for DynamoDB** (traffic stays within AWS network)
- ✅ **VPC Endpoint condition in IAM** (credentials only work via endpoint)
- ✅ **Least privilege IAM** (specific resources and actions)
- ✅ **Encryption at rest** (DynamoDB table encrypted)
- ✅ **Security headers** (XSS, clickjacking protection)

## What Changed from Branch 2
```diff
Security Improvements:
+ IMDSv2 enforced (http_tokens = "required")
+ SSRF protection in application code
+ VPC Endpoint for DynamoDB
+ VPC Endpoint condition in IAM policy
+ IP blocking for metadata/private ranges
+ Security headers middleware
+ DynamoDB encryption enabled
+ Input validation and sanitization
```

## Lab Architecture (fck-nat Implementation)
```
Internet 
    |
    ├── Public Subnet (10.0.1.0/24)
    │   ├── Bastion Host (t3.micro)
    │   │   ├── ✅ IMDSv2 enforced 
    │   │   └── ✅ Attack scripts for testing
    │   │
    │   └── fck-nat Instance (t3.nano)
    │       ├── ✅ NAT functionality for private subnet
    │       ├── ✅ IMDSv2 enforced
    │       ├── ✅ source_dest_check = false
    │       └── ✅ $4.60/month vs $32.85 NAT Gateway
    |
    └── Private Subnet (10.0.2.0/24)
        └── Web Server (t3.micro)
            ├── ⚠️ IMDSv1 enabled (vulnerable - branches 1-2)
            ├── ✅ Internet access via fck-nat
            ├── ✅ VPC Endpoint for DynamoDB
            └── ✅ Encrypted DynamoDB storage

Route Tables:
- Public: 0.0.0.0/0 → Internet Gateway
- Private: 0.0.0.0/0 → fck-nat ENI

VPC Endpoint (Gateway)
    └── DynamoDB (AWS Service)
```

## Security Test Scenarios (fck-nat Implementation)

### Prerequisites
Deploy the infrastructure to any branch with fck-nat:
```bash
# Switch to branch with fck-nat implementation
git checkout branch-1-vulnerable  # or branch-2-vpc-conditional

cd terraform
terraform init
terraform apply

# Note the outputs:
# bastion_public_ip = "x.x.x.x" 
# fck_nat_public_ip = "x.x.x.x"
# web_server_private_ip = "10.0.2.x"  # Note: NO public IP (private subnet)
```

### Test 1: IMDS Vulnerability Attack (branch-1-vulnerable)
```bash
# Connect to bastion
ssh -i imdsv1-lab.pem ec2-user@<BASTION_PUBLIC_IP>

# Run the pre-configured attack script
./run-attack.sh http://<WEB_SERVER_PRIVATE_IP>:8080

# Expected results:
# ✓ Credentials stolen via SSRF → IMDS
# ✓ DynamoDB access using stolen credentials
# ✓ Full compromise demonstration
```

### Test 2: Network Connectivity via fck-nat
```bash
# Verify web server can reach internet through fck-nat
ssh -i imdsv1-lab.pem ec2-user@<BASTION_PUBLIC_IP>
ssh <WEB_SERVER_PRIVATE_IP>  # Jump to private instance

# Test internet connectivity
curl -I https://httpbin.org/ip  # Should work via fck-nat
curl -s https://httpbin.org/ip | jq .origin  # Shows fck-nat public IP
```

### Test 3: fck-nat Monitoring and Management  
```bash
# SSH to fck-nat instance for troubleshooting
ssh -i imdsv1-lab.pem ec2-user@<FCK_NAT_PUBLIC_IP>

# Check fck-nat service status
sudo systemctl status fck-nat

# View NAT traffic logs (if configured)
sudo journalctl -u fck-nat -f

# Monitor network traffic
sudo netstat -tuln
```

## Branch Comparison & Migration Guide

### Current Branch Status
| Branch | fck-nat Status | Monthly Cost | Security Level |
|--------|----------------|-------------|----------------|
| **branch-1-vulnerable** | ✅ **Implemented** | **$21.38** | VULNERABLE (IMDSv1) |
| **branch-2-vpc-conditional** | ✅ **Implemented** | **$21.38** | MODERATE (conditional) |
| branch-3-vpc-endpoint | ❌ Original | $16.78 | SECURE (VPC endpoint) |
| branch-4-file-upload | ❌ Original | $16.78 | SECURE (file upload) |
| branch-5-network-segmentation | ❌ Original | $41.02 | ENTERPRISE (full stack) |

### Migration Benefits  
- **Immediate 90% NAT cost reduction** on branches 1-2
- **Same security model** with enhanced instance-level controls
- **Better monitoring capabilities** via CloudWatch and system logs
- **Simplified architecture** without managed service dependencies
- **Educational value** for understanding NAT at instance level

### When to Use Each Branch
- **branch-1**: Learn IMDS attacks with cost-optimized NAT
- **branch-2**: Conditional access patterns with fck-nat
- **branch-3**: VPC endpoint security (original architecture)
- **branch-4**: File upload vulnerabilities (original architecture)  
- **branch-5**: Full enterprise stack with RDS and API backend

### Next Steps
1. Apply fck-nat to remaining branches (3-5) for maximum cost savings
2. Implement custom monitoring for fck-nat instances
3. Consider ARM-based t4g.nano instances for additional savings
4. Set up automated AMI updates for fck-nat instances

### Test 2: IMDSv2 Protection
Even if SSRF protection failed, IMDSv2 prevents credential theft:
```bash
# Old IMDSv1 method (FAILS)
curl http://169.254.169.254/latest/meta-data/
# Result: 401 Unauthorized

# IMDSv2 requires token first
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/
# This works, but SSRF can't perform PUT request for token
```

### Test 3: VPC Endpoint Enforcement
Even if credentials were somehow stolen:
```bash
# Stolen credentials wouldn't work from internet
export AWS_ACCESS_KEY_ID=<any_stolen_key>
export AWS_SECRET_ACCESS_KEY=<any_stolen_secret>
export AWS_SESSION_TOKEN=<any_stolen_token>

# This would fail - requires VPC endpoint
aws dynamodb scan --table-name Products --region us-east-1
# Error: Access denied - must use VPC endpoint
```

### Test 4: Legitimate Access Still Works
```bash
# The application continues to function normally
curl http://<WEB_SERVER_PUBLIC_IP>:8080/api/products
# Returns product list successfully

curl http://<WEB_SERVER_PUBLIC_IP>:8080/api/products/1
# Returns specific product

# DynamoDB access works because:
# 1. Request originates from EC2 in VPC
# 2. Uses VPC endpoint for DynamoDB
# 3. IAM policy allows VPC endpoint access
```

## Security Controls Deep Dive

### 1. SSRF Protection (Application Layer)
```go
// Blocks these IP ranges:
- 169.254.0.0/16    // AWS metadata
- 10.0.0.0/8        // Private network
- 172.16.0.0/12     // Private network
- 192.168.0.0/16    // Private network
- 127.0.0.0/8       // Localhost
```

### 2. IMDSv2 Enforcement (EC2 Configuration)
```hcl
metadata_options {
  http_tokens = "required"  // Must have session token
  http_put_response_hop_limit = 1  // Prevents container escapes
}
```

### 3. VPC Endpoint (Network Layer)
```hcl
# DynamoDB traffic never leaves AWS network
# Endpoint policy restricts access to specific role
# Route table directs DynamoDB traffic to endpoint
```

### 4. IAM Policy (Authorization Layer)
```json
{
  "Condition": {
    "StringEquals": {
      "aws:SourceVpce": "vpce-xxxxx"  // Must use VPC endpoint
    }
  }
}
```

## Attack Surface Analysis

| Attack Vector | Branch 1 (Vulnerable) | Branch 2 (VPC Conditional) | Branch 3 (Secure) |
|--------------|----------------------|---------------------------|-------------------|
| SSRF to IMDS | ✗ Vulnerable | ✗ Vulnerable | ✅ Blocked |
| Credential Theft | ✗ Easy | ✗ Easy | ✅ Prevented |
| Use Stolen Creds | ✗ Works anywhere | ⚠️ VPC only | ✅ VPC Endpoint only |
| Lateral Movement | ✗ Possible | ⚠️ Limited | ✅ Highly restricted |
| Network Traffic | ✗ Internet | ✗ Internet | ✅ VPC Endpoint |

## Best Practices Implemented
1. **Defense in Depth**: Multiple layers of security
2. **Least Privilege**: Minimal required permissions
3. **Network Segmentation**: VPC endpoints isolate traffic
4. **Input Validation**: SSRF protection validates all URLs
5. **Encryption**: Data encrypted at rest and in transit
6. **Monitoring Ready**: CloudTrail can audit VPC endpoint usage

## Security Monitoring

### CloudWatch Logs
Monitor security controls in action:
```bash
# View blocked SSRF attempts
aws logs tail /aws/ec2/imdsv1-lab/web-server --follow --filter-pattern "BLOCKED"

# View all security events
aws logs tail /aws/ec2/imdsv1-lab/web-server --follow --stream-name-prefix ssrf
```

### CloudTrail Audit
Complete audit trail showing all protections working:
```bash
# Verify no credential theft occurs (no AssumeRole from attacker)
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
  --region us-east-1

# Verify DynamoDB only accessed via VPC endpoint
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=Products \
  --region us-east-1 \
  | jq '.Events[] | {time: .EventTime, source: .SourceIPAddress, vpce: .RequestParameters.vpcEndpointId}'

# Export all CloudTrail logs for compliance audit
aws s3 sync s3://imdsv1-lab-cloudtrail-<ACCOUNT_ID> ./cloudtrail-logs/
```

### What Gets Logged
- **CloudWatch**: 
  - All SSRF attempts blocked by IP filtering
  - Application access patterns
  - Security control enforcement
- **CloudTrail**: 
  - No unauthorized AssumeRole events (IMDSv2 + SSRF protection)
  - All DynamoDB access via VPC endpoint only
  - Complete audit trail for compliance

## Cleanup
```bash
terraform destroy
```

## Lessons Learned
- **IMDSv2 is essential**: Always require session tokens
- **Application security matters**: Fix SSRF vulnerabilities
- **Network boundaries help**: VPC endpoints provide isolation
- **IAM conditions add defense**: Restrict credential usage context
- **Layer your security**: No single control is perfect

## Additional Resources
- [AWS IMDSv2 Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)
- [VPC Endpoints for DynamoDB](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-ddb.html)
- [IAM Policy Conditions](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_condition.html)
- [OWASP SSRF Prevention](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)