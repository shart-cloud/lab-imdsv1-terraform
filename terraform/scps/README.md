# Service Control Policies (SCPs) for AWS Organizations

This directory contains Service Control Policies (SCPs) that can be applied at the AWS Organizations level to enforce security guardrails across all accounts in your organization.

## What are SCPs?

Service Control Policies (SCPs) are organization-level policies that set the maximum permissions for accounts in your organization. Even if an IAM policy grants a permission, an SCP can override and deny that permission.

## Important Notes

- SCPs require **AWS Organizations** to be set up
- SCPs affect **all principals** in the account, including the root user (except for specific management account actions)
- SCPs use **deny-by-default** logic - you must explicitly allow actions
- SCPs do **not grant permissions** - they only limit what IAM policies can grant

## Applying SCPs

### Using AWS Console

1. Navigate to AWS Organizations → Policies → Service control policies
2. Create a new policy
3. Copy the JSON content from the desired SCP file
4. Attach the policy to the desired OU (Organizational Unit) or account

### Using AWS CLI

```bash
# Create the SCP
aws organizations create-policy \
  --content file://enforce_imdsv2.json \
  --description "Enforce IMDSv2 on all EC2 instances" \
  --name "EnforceIMDSv2" \
  --type SERVICE_CONTROL_POLICY

# Attach to an organizational unit or account
aws organizations attach-policy \
  --policy-id p-xxxxxxxx \
  --target-id ou-xxxx-xxxxxxxx  # or account ID
```

### Using Terraform

```hcl
resource "aws_organizations_policy" "enforce_imdsv2" {
  name        = "EnforceIMDSv2"
  description = "Enforce IMDSv2 on all EC2 instances"
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/scps/enforce_imdsv2.json")
}

resource "aws_organizations_policy_attachment" "enforce_imdsv2" {
  policy_id = aws_organizations_policy.enforce_imdsv2.id
  target_id = "ou-xxxx-xxxxxxxx"  # Your OU or account ID
}
```

## Available SCPs

### 1. enforce_imdsv2.json
**Purpose:** Prevents launching EC2 instances without IMDSv2 enforcement
**Impact:** Blocks IMDSv1-enabled instances across all accounts
**Severity:** HIGH - Prevents credential theft via SSRF

### 2. prevent_vpc_endpoint_deletion.json
**Purpose:** Prevents deletion or modification of VPC endpoints
**Impact:** Protects network isolation controls
**Severity:** HIGH - Prevents bypass of VPC endpoint security

### 3. prevent_encryption_disable.json
**Purpose:** Enforces encryption on DynamoDB and RDS
**Impact:** All data stores must use encryption at rest
**Severity:** HIGH - Protects sensitive data

### 4. prevent_cloudtrail_tampering.json
**Purpose:** Prevents deletion or disabling of CloudTrail
**Impact:** Ensures audit logs cannot be tampered with
**Severity:** CRITICAL - Required for compliance and incident response

### 5. restrict_regions.json
**Purpose:** Limits AWS service usage to approved regions
**Impact:** Prevents resource creation in unapproved regions
**Severity:** MEDIUM - Reduces attack surface and compliance complexity

### 6. prevent_security_group_changes.json
**Purpose:** Restricts creation and modification of security groups
**Impact:** Prevents unauthorized network access changes
**Severity:** MEDIUM - Protects network boundaries

## Recommended Application Strategy

### Development/Test Accounts
Apply these SCPs:
- enforce_imdsv2.json
- prevent_cloudtrail_tampering.json
- prevent_encryption_disable.json

### Production Accounts
Apply all SCPs:
- enforce_imdsv2.json
- prevent_vpc_endpoint_deletion.json
- prevent_encryption_disable.json
- prevent_cloudtrail_tampering.json
- restrict_regions.json
- prevent_security_group_changes.json

### Sandbox Accounts
Apply minimal SCPs:
- prevent_cloudtrail_tampering.json (for audit purposes)

## Testing SCPs

Before applying to production:

1. **Test in a sandbox account first**
2. **Verify existing workloads** won't be impacted
3. **Document exceptions** needed for specific use cases
4. **Create bypass procedures** for emergency break-glass scenarios

## Break-Glass Procedures

If you need to temporarily bypass an SCP:

1. Detach the SCP from the account
2. Perform the necessary action
3. Re-attach the SCP immediately
4. Document the exception in your security log

**WARNING:** Only use break-glass procedures in genuine emergencies with proper authorization and documentation.

## Monitoring SCP Violations

Set up CloudWatch Event Rules to detect SCP denials:

```json
{
  "source": ["aws.organizations"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "errorCode": ["AccessDenied"],
    "errorMessage": [{
      "prefix": "You are not authorized"
    }]
  }
}
```

## References

- [AWS SCP Documentation](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html)
- [SCP Examples](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps_examples.html)
- [SCP Best Practices](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps_best-practices.html)
