# Resource Control Policies (RCP) Implementation Guide

## Overview

This directory contains Resource Control Policies (RCPs) that provide defense-in-depth security beyond IAM policies. These policies are **currently disabled** (`.disabled` extension) and are **not required** for the lab to function.

## What are RCPs?

Resource Control Policies are resource-based policies that apply directly to AWS resources (like DynamoDB tables, S3 buckets, VPC endpoints) rather than to IAM identities. They provide an additional security layer that works even if IAM credentials are compromised.

## Available RCP Files

### 1. `dynamodb_resource_policy.tf.disabled`
**Purpose:** Enforces security controls at the DynamoDB table level

**Key Features:**
- Enforces VPC endpoint access for EC2 roles
- Denies destructive operations (DeleteTable, UpdateTable)
- Prevents DeleteItem and BatchWriteItem operations
- Requires encryption in transit

**Administrator Bypass:** ✅ Configured for Admin*, *Administrator*, and AWSReservedSSO_*Admin* roles

---

### 2. `iam_enhanced_policies.tf.disabled`
**Purpose:** Enhanced IAM policies for EC2 instance roles

**Key Features:**
- VPC endpoint enforcement for DynamoDB access
- Anti-exfiltration controls (query/scan result limits)
- Explicit deny for destructive operations
- IMDS downgrade prevention
- Optional time-based access controls (commented out)

**Administrator Impact:** ❌ None - these policies only attach to EC2 instance roles

---

### 3. `iam_permission_boundaries.tf.disabled`
**Purpose:** Sets maximum permissions for EC2 instance roles

**Key Features:**
- Creates a separate bounded role (`web_server_with_boundary`)
- Prevents privilege escalation
- Blocks IAM, Organizations, and account management operations
- Enforces VPC endpoint for DynamoDB
- Restricts to specific regions
- Prevents metadata service modifications

**Administrator Impact:** ❌ None - creates separate opt-in role, doesn't affect administrators

---

### 4. `s3_enhanced_policies.tf.disabled`
**Purpose:** Enhanced S3 bucket policies for CloudTrail logs

**Key Features:**
- Enforces encryption at rest and in transit
- Creates immutable audit logs (prevents deletion)
- Blocks public ACLs
- Enables access logging to separate bucket
- Implements lifecycle policies for cost optimization

**Administrator Bypass:** ✅ Configured for Admin*, *Administrator*, AWSReservedSSO_*Admin* roles, and root

---

### 5. `vpc_endpoint_enhanced.tf.disabled`
**Purpose:** Enhanced VPC endpoint policy for DynamoDB

**Key Features:**
- Network-level enforcement of security controls
- Denies destructive actions (DeleteTable, DeleteItem, UpdateTable)
- Restricts access to specific subnet IP ranges
- Blocks batch operations (anti-exfiltration)
- Requires encryption in transit

**Administrator Bypass:** ✅ Configured for Admin*, *Administrator*, and AWSReservedSSO_*Admin* roles

---

## Which Branch Should Use RCPs?

### ❌ Branch 1 (branch-1-vulnerable)
**DO NOT enable RCPs here**
- Branch is intentionally vulnerable for demonstration
- RCPs would break the attack scenarios
- RCPs reference resources (VPC endpoints) that don't exist in branch-1

### ❌ Branch 2 (branch-2-vpc-conditional)
**DO NOT enable RCPs here**
- Partial mitigation only (still vulnerable by design)
- Uses IAM policy conditions, not resource policies
- RCPs would break the partial vulnerability demonstration

### ⚠️ Branch 3 (branch-3-vpc-endpoint)
**OPTIONAL - First secure branch**
- Has all infrastructure needed (VPC endpoints, IMDSv2, SSRF protection)
- Could demonstrate RCPs as additional defense-in-depth
- But RCPs add complexity without adding much new security value here

### ✅ Branch 4 (branch-4-file-upload) - **RECOMMENDED**
**BEST CHOICE for enabling RCPs**
- Fully secure infrastructure in place
- Demonstrates production-ready "defense in depth" approach
- Shows layering of multiple security controls:
  - IAM policies
  - VPC endpoints
  - Resource policies (RCPs)
  - Permission boundaries
- File upload feature makes exfiltration prevention more relevant

### ✅ Branch 5 (branch-5-network-segmentation) - **ALSO GOOD**
**Enterprise-grade security demonstration**
- Most complex branch with RDS, backend API, network segmentation
- RCPs fit well in enterprise security posture
- Shows complete production security architecture

---

## How to Enable RCPs

### Option 1: Enable Individual RCPs (Recommended)

Choose which RCPs make sense for your branch and enable them selectively:

```bash
# Example: Enable DynamoDB resource policy only
cd terraform
mv dynamodb_resource_policy.tf.disabled dynamodb_resource_policy.tf
terraform apply
```

### Option 2: Enable All RCPs

```bash
cd terraform
for file in *.disabled; do
  mv "$file" "${file%.disabled}"
done
terraform apply
```

### Integration Steps

1. **Review each file** to understand what it does
2. **Check dependencies**: Ensure referenced resources exist (e.g., `aws_vpc_endpoint.dynamodb`)
3. **Update README**: Document which RCPs are enabled and why
4. **Test with admin role**: Verify administrators can still delete resources
5. **Test with EC2 role**: Verify restrictions work as expected

---

## Administrator Bypass Configuration

All RCPs that could lock out administrators have bypass conditions configured:

### Allowed Administrator Patterns:
- `arn:aws:iam::*:role/Admin*`
- `arn:aws:iam::*:role/*Administrator*`
- `arn:aws:iam::*:user/Admin*`
- `arn:aws:iam::*:role/AWSReservedSSO_*Admin*` (for AWS SSO)
- `arn:aws:iam::*:root` (account root, for S3 policies)

### Testing Administrator Access:

```bash
# Verify you can still delete resources with your admin role
aws dynamodb delete-table --table-name Products --region us-east-1

# Should succeed if your role matches one of the patterns above
# Should fail if testing with the web server EC2 instance role
```

---

## Recommended Configuration for Branch 4/5

### For Branch 4 (file-upload):

Enable these RCPs:
1. ✅ `dynamodb_resource_policy.tf` - Prevents table-level attacks
2. ✅ `s3_enhanced_policies.tf` - Protects CloudTrail logs
3. ✅ `vpc_endpoint_enhanced.tf` - Network-level DynamoDB protection
4. ⚠️ `iam_permission_boundaries.tf` - Optional, adds complexity
5. ⚠️ `iam_enhanced_policies.tf` - Optional, can replace existing policies

### For Branch 5 (network-segmentation):

Enable all RCPs for comprehensive enterprise security demonstration.

---

## Cleanup / Removal

To disable RCPs:

```bash
cd terraform
for file in dynamodb_resource_policy.tf s3_enhanced_policies.tf vpc_endpoint_enhanced.tf iam_permission_boundaries.tf iam_enhanced_policies.tf; do
  if [ -f "$file" ]; then
    mv "$file" "${file}.disabled"
  fi
done
terraform apply
```

---

## FAQ

### Q: Why are RCPs disabled by default?
**A:** They're advanced security controls not needed for the core lab functionality. They add complexity and are most valuable in production environments.

### Q: Will RCPs interfere with terraform destroy?
**A:** No - if your role matches the administrator bypass patterns (Admin*, *Administrator*, AWSReservedSSO_*Admin*), you can destroy resources normally.

### Q: Can I use these in production?
**A:** Yes, but review and customize for your environment. Pay special attention to:
- Administrator bypass patterns
- VPC/subnet CIDR blocks
- Region restrictions
- Encryption requirements

### Q: What if I get locked out?
**A:** Use the root account or create a break-glass admin role matching the bypass patterns. Then you can modify or remove the RCPs.

---

## Learning Objectives

By implementing RCPs, you'll learn:

1. **Defense in Depth**: Multiple layers of security controls
2. **Resource vs Identity Policies**: How resource-based policies differ from IAM
3. **Principle of Least Privilege**: Restricting even compromised credentials
4. **Break-Glass Procedures**: Planning for emergency admin access
5. **Policy Precedence**: How Deny statements override Allow statements

---

## References

- [AWS DynamoDB Resource-Based Policies](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/resource-based-policies.html)
- [AWS S3 Bucket Policies](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-policies.html)
- [AWS VPC Endpoint Policies](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-access.html)
- [AWS IAM Permission Boundaries](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html)
