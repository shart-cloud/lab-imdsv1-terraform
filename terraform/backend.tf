# Backend API Server and Database Resources

# Security Group for Backend API
resource "aws_security_group" "backend_api" {
  name_prefix = "backend-api-sg-"
  vpc_id      = aws_vpc.main.id

  # Only allow traffic from web server
  ingress {
    from_port       = 8081
    to_port         = 8081
    protocol        = "tcp"
    security_groups = [aws_security_group.web_server.id]
    description     = "API access from web server"
  }

  # SSH only from bastion for debugging (optional)
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
    description     = "SSH from bastion"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = {
    Name = "imdsv1-lab-backend-api-sg"
  }
}

# Security Group for RDS PostgreSQL
resource "aws_security_group" "rds" {
  name_prefix = "rds-sg-"
  vpc_id      = aws_vpc.main.id

  # Only allow PostgreSQL from backend API
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.backend_api.id]
    description     = "PostgreSQL from backend API"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = {
    Name = "imdsv1-lab-rds-sg"
  }
}

# RDS Subnet Group
resource "aws_db_subnet_group" "main" {
  name       = "imdsv1-lab-db-subnet-group"
  subnet_ids = [aws_subnet.database_a.id, aws_subnet.database_b.id]

  tags = {
    Name = "imdsv1-lab-db-subnet-group"
  }
}

# RDS PostgreSQL Instance (small dev DB)
resource "aws_db_instance" "postgres" {
  identifier     = "imdsv1-lab-postgres"
  engine         = "postgres"
  engine_version = "14.9"
  instance_class = "db.t3.micro"
  
  allocated_storage     = 20
  storage_type          = "gp3"
  storage_encrypted     = true
  
  db_name  = "customerdb"
  username = "dbadmin"
  password = var.db_password  # Should be provided via terraform.tfvars
  
  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name
  
  skip_final_snapshot = true
  deletion_protection = false
  
  # Enable backups for production-like setup
  backup_retention_period = 7
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:00-sun:05:00"
  
  # Enable logging
  enabled_cloudwatch_logs_exports = ["postgresql"]
  
  tags = {
    Name        = "imdsv1-lab-postgres"
    Environment = "dev"
    Sensitive   = "true"
  }
}

# IAM Role for Backend API
resource "aws_iam_role" "backend_api" {
  name = "imdsv1-lab-backend-api-role"

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
    Name = "imdsv1-lab-backend-api-role"
  }
}

# IAM policy for Backend API (access to secrets for DB credentials)
resource "aws_iam_role_policy" "backend_api_secrets" {
  name = "backend-api-secrets-policy"
  role = aws_iam_role.backend_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = aws_secretsmanager_secret.db_credentials.arn
      }
    ]
  })
}

# CloudWatch Logs policy for Backend API
resource "aws_iam_role_policy" "backend_api_cloudwatch" {
  name = "backend-api-cloudwatch-policy"
  role = aws_iam_role.backend_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          aws_cloudwatch_log_group.backend_api.arn,
          "${aws_cloudwatch_log_group.backend_api.arn}:*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "backend_api" {
  name = "imdsv1-lab-backend-api-profile"
  role = aws_iam_role.backend_api.name
}

# CloudWatch Log Group for Backend API
resource "aws_cloudwatch_log_group" "backend_api" {
  name              = "/aws/ec2/imdsv1-lab/backend-api"
  retention_in_days = 7

  tags = {
    Name = "imdsv1-lab-backend-api-logs"
  }
}

# Secrets Manager for DB Credentials
resource "aws_secretsmanager_secret" "db_credentials" {
  name = "imdsv1-lab-db-credentials"
  
  tags = {
    Name = "imdsv1-lab-db-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = aws_db_instance.postgres.username
    password = var.db_password
    host     = aws_db_instance.postgres.address
    port     = aws_db_instance.postgres.port
    database = aws_db_instance.postgres.db_name
  })
}

# Backend API EC2 Instance
resource "aws_instance" "backend_api" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = "t3.micro"
  key_name              = var.key_name
  subnet_id             = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.backend_api.id]
  iam_instance_profile   = aws_iam_instance_profile.backend_api.name

  # IMDSv1 vulnerable (for exploitation)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"  # VULNERABLE: IMDSv1 enabled
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  user_data = base64encode(templatefile("${path.module}/user_data/backend_api.sh", {
    db_secret_arn = aws_secretsmanager_secret.db_credentials.arn
    region        = var.region
    db_password   = var.db_password
  }))

  tags = {
    Name = "imdsv1-lab-backend-api"
    Type = "backend"
  }
  
  depends_on = [aws_db_instance.postgres]
}