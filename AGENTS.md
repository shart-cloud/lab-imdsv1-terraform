# AGENTS.md - IMDSv1 Security Lab

## Build/Test Commands
```bash
# Go application
go mod download && go mod tidy
go run web-server/main.go
go test ./...

# Terraform
cd terraform && terraform init && terraform validate
terraform plan -var-file=terraform.tfvars
terraform apply -auto-approve
```

## Code Style
- **Go**: Standard formatting with `gofmt`, error handling with explicit checks
- **Terraform**: HCL2 syntax, resource naming: `aws_<type>_<name>`, use data sources
- **Imports**: Group stdlib, external deps, internal packages
- **Security**: Never commit secrets, use IAM roles, implement least privilege
- **Git branches**: branch-1-vulnerable, branch-2-vpc-conditional, branch-3-vpc-endpoint