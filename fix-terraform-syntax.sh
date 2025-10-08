#!/bin/bash

# Script to fix terraform syntax issues across all branches

echo "Fixing terraform syntax issues across all branches..."

# Function to fix bash variable escaping in terraform files
fix_terraform_syntax() {
    local branch=$1
    echo "Fixing syntax in branch: $branch"
    
    # Switch to branch
    git checkout $branch
    
    # Fix bash variable escaping in main.tf
    if [ -f terraform/main.tf ]; then
        # Fix bash variables in heredoc blocks
        sed -i 's/\${1:/\$${1:/g' terraform/main.tf
        sed -i 's/\${TARGET/\$$TARGET/g' terraform/main.tf
        sed -i 's/\${ROLE/\$$ROLE/g' terraform/main.tf
        sed -i 's/\${CREDS/\$$CREDS/g' terraform/main.tf
        sed -i 's/\${ACCESS_KEY/\$$ACCESS_KEY/g' terraform/main.tf
        sed -i 's/\${SECRET_KEY/\$$SECRET_KEY/g' terraform/main.tf
        sed -i 's/\${SESSION_TOKEN/\$$SESSION_TOKEN/g' terraform/main.tf
        sed -i 's/\$(curl/\$$(curl/g' terraform/main.tf
        sed -i 's/\$(echo/\$$(echo/g' terraform/main.tf
        sed -i 's/\$(date)/\$$(date)/g' terraform/main.tf
        sed -i 's/\$(whoami)/\$$(whoami)/g' terraform/main.tf
        sed -i 's/"\$@"/"\$$@"/g' terraform/main.tf
        sed -i "s/| jq '/| jq \"/g" terraform/main.tf
    fi
    
    # Add missing db_password variable if not exists
    if [ -f terraform/variables.tf ]; then
        if ! grep -q "db_password" terraform/variables.tf; then
            cat >> terraform/variables.tf << 'EOF'

variable "db_password" {
  description = "Password for the RDS PostgreSQL database"
  type        = string
  sensitive   = true
}
EOF
        fi
    fi
    
    # Fix templatefile reference in backend.tf if it exists
    if [ -f terraform/backend.tf ]; then
        # Add db_password to templatefile variables if missing
        if grep -q "templatefile.*backend_api.sh" terraform/backend.tf; then
            if ! grep -A3 "templatefile.*backend_api.sh" terraform/backend.tf | grep -q "db_password"; then
                sed -i '/region.*= var.region/a\    db_password   = var.db_password' terraform/backend.tf
            fi
        fi
    fi
    
    # Initialize terraform and check syntax
    cd terraform
    terraform init -upgrade > /dev/null 2>&1
    
    if terraform validate > /dev/null 2>&1; then
        echo "✅ Syntax fixed for $branch"
        cd ..
        git add .
        git commit -m "Fix terraform syntax issues in $branch" || true
    else
        echo "❌ Syntax still has issues in $branch"
        terraform validate
        cd ..
    fi
}

# List of branches to fix
branches=("branch-1-vulnerable" "branch-2-vpc-conditional" "branch-3-vpc-endpoint" "branch-4-file-upload" "branch-5-network-segmentation")

# Fix each branch
for branch in "${branches[@]}"; do
    fix_terraform_syntax $branch
done

echo "Terraform syntax fixing complete!"