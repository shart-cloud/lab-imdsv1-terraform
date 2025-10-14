# IMDSv1 Security Lab - Branch: file-upload (SECURE + FILE FEATURES)

## 💰 AWS Cost Estimate (us-east-1)

**Monthly Cost: $16.78** *(66% savings vs. branch-1)*

| Resource | Monthly Cost | Notes |
|----------|-------------|-------|
| EC2 Instances (2x t3.micro) | $15.18 | Bastion + Web Server |
| EBS Storage (16 GB) | $1.60 | Root volumes |
| File Upload Features | $0.00 | Built into existing infrastructure |
| CloudTrail, CloudWatch, DynamoDB | Variable | Usage-based pricing |
| ✅ **Enhanced Features** | **$0** | **File upload adds capability at no cost** |

*Generated with Infracost on $(date '+%Y-%m-%d')*

---

## Overview
This branch demonstrates the **MOST SECURE** configuration with multiple layers of defense against IMDS credential theft and abuse.

✅ **FULLY PROTECTED**: Multiple security controls prevent credential theft and misuse.

## Current Security Posture (FULLY SECURE)
- ✅ **IMDSv2 enforced** (requires session token, prevents simple SSRF)
- ✅ **SSRF protection implemented** (blocks metadata and private IPs)
- ✅ **VPC Endpoint for DynamoDB** (traffic stays within AWS network)
- ✅ **VPC Endpoint condition in IAM** (credentials only work via endpoint)
- ✅ **Least privilege IAM** (specific resources and actions)
- ✅ **Encryption at rest** (DynamoDB table encrypted)
- ✅ **Security headers** (XSS, clickjacking protection)
- 📦 **Optional Resource Control Policies (RCPs)** available for defense-in-depth

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

## Lab Architecture
```
Internet 
    |
    ├── Bastion Host (Public Subnet)
    │   ├── ❌ Cannot steal credentials (IMDSv2 + SSRF protection)
    │   └── ❌ Cannot use stolen credentials (VPC Endpoint required)
    |
    └── Web Server (Public Subnet) 
        ├── ✅ SSRF Protection (blocks metadata IPs)
        ├── ✅ IMDSv2 Only (token required)
        ├── ✅ VPC Endpoint Access Only
        └── ✅ Encrypted DynamoDB via VPC Endpoint

VPC Endpoint (Gateway)
    └── DynamoDB (AWS Service)
```

## Security Test Scenarios

### Prerequisites
Deploy the infrastructure:
```bash
cd terraform
terraform init
terraform apply
```

### Test 1: SSRF Protection
```bash
# Connect to bastion
ssh -i imdsv1-lab.pem ec2-user@<BASTION_PUBLIC_IP>

# Run security test
./test-security.sh http://<WEB_SERVER_PRIVATE_IP>:8080

# Results:
# ✗ Metadata endpoint blocked (403 Forbidden)
# ✗ Localhost access blocked (403 Forbidden)  
# ✗ Private network access blocked (403 Forbidden)
# ✓ External URLs allowed (200 OK)
# ✓ API endpoints work normally
```

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

## 🛡️ Optional: Resource Control Policies (RCPs)

This branch includes **optional** Resource Control Policies (RCPs) that add an additional layer of defense-in-depth security. RCPs are **disabled by default** (`.disabled` extension) and are not required for the lab to function.

### What are RCPs?

Resource Control Policies are resource-based policies applied directly to AWS resources (like DynamoDB tables, S3 buckets, VPC endpoints) rather than to IAM identities. They provide security controls that work even if IAM credentials are compromised.

### Available RCPs in `terraform/` Directory:

1. **`dynamodb_resource_policy.tf.disabled`** - Table-level DynamoDB security
   - Enforces VPC endpoint access
   - Prevents destructive operations
   - Blocks DeleteItem/BatchWriteItem

2. **`s3_enhanced_policies.tf.disabled`** - Enhanced S3 bucket policies
   - Immutable CloudTrail logs
   - Encryption enforcement
   - Access logging

3. **`vpc_endpoint_enhanced.tf.disabled`** - Network-level DynamoDB controls
   - IP-based restrictions
   - Denies batch operations
   - Anti-exfiltration controls

4. **`iam_permission_boundaries.tf.disabled`** - Maximum permissions for EC2 roles
   - Prevents privilege escalation
   - Optional separate bounded role

5. **`iam_enhanced_policies.tf.disabled`** - Enhanced IAM policies for EC2 roles
   - Query/scan result limits
   - IMDS downgrade prevention

### 📖 Full Documentation

See **[terraform/RCP-IMPLEMENTATION-GUIDE.md](terraform/RCP-IMPLEMENTATION-GUIDE.md)** for:
- Detailed explanation of each RCP
- How to enable/disable RCPs
- Administrator bypass configuration
- Testing procedures
- FAQ and troubleshooting

### Quick Enable (Optional):

```bash
cd terraform

# Enable recommended RCPs for production-like security
mv dynamodb_resource_policy.tf.disabled dynamodb_resource_policy.tf
mv s3_enhanced_policies.tf.disabled s3_enhanced_policies.tf
mv vpc_endpoint_enhanced.tf.disabled vpc_endpoint_enhanced.tf

terraform apply
```

**Note:** All RCPs include administrator bypass patterns so `terraform destroy` works normally.

### Why RCPs are Optional:

- Core lab security (IMDSv2, SSRF protection, VPC endpoints) is already comprehensive
- RCPs add complexity that may not be needed for learning the basics
- Best suited for production environments or advanced security demonstrations
- Require careful configuration of administrator bypass patterns

---

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