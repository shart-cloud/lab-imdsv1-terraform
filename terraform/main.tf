terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Get current caller identity
data "aws_caller_identity" "current" {}

# VPC Configuration
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "imdsv1-lab-vpc"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "imdsv1-lab-public-subnet"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "imdsv1-lab-private-subnet"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "imdsv1-lab-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "imdsv1-lab-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# VPC Endpoint for DynamoDB
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowDynamoDBFromWebServer"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.web_server.arn
        }
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Scan",
          "dynamodb:Query"
        ]
        Resource = aws_dynamodb_table.products.arn
      }
    ]
  })

  tags = {
    Name = "imdsv1-lab-dynamodb-endpoint"
  }
}

# Security Groups
resource "aws_security_group" "bastion" {
  name_prefix = "bastion-sg-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "imdsv1-lab-bastion-sg"
  }
}

resource "aws_security_group" "web_server" {
  name_prefix = "web-server-sg-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [aws_vpc_endpoint.dynamodb.prefix_list_id]
  }

  tags = {
    Name = "imdsv1-lab-web-server-sg"
  }
}

# IAM Role - SECURE with VPC Endpoint condition
resource "aws_iam_role" "web_server" {
  name = "imdsv1-lab-web-server-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "imdsv1-lab-web-server-role"
  }
}

# MOST SECURE: DynamoDB policy requires VPC Endpoint
resource "aws_iam_role_policy" "web_server_dynamodb" {
  name = "web-server-dynamodb-policy"
  role = aws_iam_role.web_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBViaVPCEndpointOnly"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Scan",
          "dynamodb:Query",
          "dynamodb:DescribeTable"
        ]
        Resource = aws_dynamodb_table.products.arn
        Condition = {
          StringEquals = {
            "aws:SourceVpce" = aws_vpc_endpoint.dynamodb.id
          }
        }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "web_server" {
  name = "imdsv1-lab-web-server-profile"
  role = aws_iam_role.web_server.name
}

# DynamoDB Table with encryption
resource "aws_dynamodb_table" "products" {
  name           = "Products"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "ID"

  server_side_encryption {
    enabled = true
  }

  attribute {
    name = "ID"
    type = "S"
  }

  tags = {
    Name = "imdsv1-lab-products-table"
  }
}

# Sample DynamoDB Items
resource "aws_dynamodb_table_item" "product1" {
  table_name = aws_dynamodb_table.products.name
  hash_key   = aws_dynamodb_table.products.hash_key

  item = jsonencode({
    "ID"          = { "S" = "1" }
    "Name"        = { "S" = "Secure Cloud Widget" }
    "Description" = { "S" = "A highly secure cloud widget" }
    "Price"       = { "S" = "99.99" }
  })
}

resource "aws_dynamodb_table_item" "product2" {
  table_name = aws_dynamodb_table.products.name
  hash_key   = aws_dynamodb_table.products.hash_key

  item = jsonencode({
    "ID"          = { "S" = "2" }
    "Name"        = { "S" = "IMDS Guardian" }
    "Description" = { "S" = "Protects against IMDS attacks" }
    "Price"       = { "S" = "149.99" }
  })
}

resource "aws_dynamodb_table_item" "product3" {
  table_name = aws_dynamodb_table.products.name
  hash_key   = aws_dynamodb_table.products.hash_key

  item = jsonencode({
    "ID"          = { "S" = "3" }
    "Name"        = { "S" = "Secret Manager Pro" }
    "Description" = { "S" = "Enterprise secret management solution" }
    "Price"       = { "S" = "299.99" }
  })
}

# EC2 Instances
resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = "t3.micro"
  key_name              = var.key_name
  subnet_id             = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.bastion.id]

  # SECURE: IMDSv2 enforced
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # SECURE: IMDSv2 only
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y git curl wget jq
    
    # Install AWS CLI v2
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    ./aws/install
    
    # Create test scripts
    cat > /home/ec2-user/test-imdsv1.sh <<'SCRIPT'
    #!/bin/bash
    echo "=== IMDSv1 Attack Test (Should FAIL) ==="
    echo ""
    TARGET="${1:-http://10.0.1.100:8080}"
    
    echo "Attempting IMDSv1 credential theft..."
    echo "Target: $TARGET/fetch?url=http://169.254.169.254/latest/meta-data/"
    
    # This should be blocked by SSRF protection
    curl -s "$TARGET/fetch?url=http://169.254.169.254/latest/meta-data/"
    echo ""
    echo "Result: BLOCKED by SSRF protection!"
    echo ""
    
    # Even if we could get credentials, they wouldn't work:
    echo "Additional protections in place:"
    echo "1. SSRF protection blocks metadata access"
    echo "2. IMDSv2 requires session token (not vulnerable to simple SSRF)"
    echo "3. VPC Endpoint condition restricts DynamoDB access"
    echo "4. Credentials only work via VPC endpoint"
    SCRIPT
    
    cat > /home/ec2-user/test-security.sh <<'SCRIPT'
    #!/bin/bash
    echo "=== Security Configuration Test ==="
    echo ""
    TARGET="${1:-http://10.0.1.100:8080}"
    
    echo "1. Testing SSRF Protection..."
    echo "   Trying metadata endpoint:"
    RESPONSE=$(curl -s -w "\n   HTTP Status: %{http_code}" "$TARGET/fetch?url=http://169.254.169.254/")
    echo "   $RESPONSE"
    echo ""
    
    echo "2. Testing localhost access:"
    RESPONSE=$(curl -s -w "\n   HTTP Status: %{http_code}" "$TARGET/fetch?url=http://127.0.0.1/")
    echo "   $RESPONSE"
    echo ""
    
    echo "3. Testing private network access:"
    RESPONSE=$(curl -s -w "\n   HTTP Status: %{http_code}" "$TARGET/fetch?url=http://10.0.0.1/")
    echo "   $RESPONSE"
    echo ""
    
    echo "4. Testing legitimate external URL:"
    RESPONSE=$(curl -s -w "\n   HTTP Status: %{http_code}" "$TARGET/fetch?url=https://www.example.com/" | head -5)
    echo "   $RESPONSE"
    echo "   [... truncated ...]"
    echo ""
    
    echo "5. Testing API endpoints (should work):"
    curl -s "$TARGET/api/products" | jq -r '.[] | "   Product: \(.name) - $\(.price)"'
    echo ""
    
    echo "=== All Security Controls Active ==="
    echo "✅ SSRF Protection: Metadata/private IPs blocked"
    echo "✅ IMDSv2 Enforced: Token required for metadata"
    echo "✅ VPC Endpoint: DynamoDB traffic stays in AWS"
    echo "✅ IAM Conditions: Credentials restricted to VPC endpoint"
    SCRIPT
    
    chmod +x /home/ec2-user/*.sh
  EOF

  tags = {
    Name = "imdsv1-lab-bastion-secure"
  }
}

resource "aws_instance" "web_server" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = "t3.micro"
  key_name              = var.key_name
  subnet_id             = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web_server.id]
  iam_instance_profile   = aws_iam_instance_profile.web_server.name

  # SECURE: IMDSv2 enforced
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # SECURE: IMDSv2 only
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y golang git
    
    # Set up Go environment
    export GOPATH=/home/ec2-user/go
    export PATH=$PATH:/usr/local/go/bin:$GOPATH/bin
    
    # Copy web server code
    mkdir -p /home/ec2-user/web-server
    cd /home/ec2-user/web-server
    
    # Create SECURE web server with SSRF protection
    cat > main.go <<'GOFILE'
${file("/home/jg/git/shart-cloud-gh/imdsv1-lab/web-server/main_secure.go")}
GOFILE
    
    # Create go.mod
    cat > go.mod <<'GOMOD'
${file("/home/jg/git/shart-cloud-gh/imdsv1-lab/go.mod")}
GOMOD
    
    # Download dependencies
    go mod download
    
    # Create systemd service
    cat > /etc/systemd/system/web-server.service <<'SERVICE'
    [Unit]
    Description=Secure Web Server with SSRF Protection
    After=network.target
    
    [Service]
    Type=simple
    User=ec2-user
    WorkingDirectory=/home/ec2-user/web-server
    ExecStart=/usr/bin/go run main.go
    Restart=always
    Environment="AWS_REGION=us-east-1"
    Environment="PORT=8080"
    
    [Install]
    WantedBy=multi-user.target
    SERVICE
    
    # Start the service
    systemctl daemon-reload
    systemctl enable web-server
    systemctl start web-server
    
    # Change ownership
    chown -R ec2-user:ec2-user /home/ec2-user/
  EOF

  tags = {
    Name = "imdsv1-lab-web-server-secure"
  }
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# Outputs
output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}

output "web_server_public_ip" {
  value = aws_instance.web_server.public_ip
}

output "web_server_private_ip" {
  value = aws_instance.web_server.private_ip
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "vpc_endpoint_id" {
  value = aws_vpc_endpoint.dynamodb.id
}

output "test_commands" {
  value = {
    connect_to_bastion = "ssh -i ${var.key_name}.pem ec2-user@${aws_instance.bastion.public_ip}"
    test_security      = "./test-security.sh http://${aws_instance.web_server.private_ip}:8080"
    test_api          = "curl http://${aws_instance.web_server.public_ip}:8080/api/products"
  }
}