#!/bin/bash
set -e

# Log all output
exec > >(tee -a /var/log/user-data.log)
exec 2>&1

echo "Starting Backend API setup..."

# Update system
yum update -y
yum install -y golang git postgresql15 amazon-cloudwatch-agent jq

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
            "log_group_name": "/aws/ec2/imdsv1-lab/backend-api",
            "log_stream_name": "{instance_id}/system",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/backend-api.log",
            "log_group_name": "/aws/ec2/imdsv1-lab/backend-api",
            "log_stream_name": "{instance_id}/application",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/backend-api-access.log",
            "log_group_name": "/aws/ec2/imdsv1-lab/backend-api",
            "log_stream_name": "{instance_id}/access",
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

# Create backend API directory
mkdir -p /opt/backend-api
cd /opt/backend-api

# Create the backend API application
cat > main.go <<'APICODE'
package main

import (
    "database/sql"
    "encoding/json"
    "fmt"
    "log"
    "net/http"
    "os"
    "time"

    "github.com/aws/aws-sdk-go/aws"
    "github.com/aws/aws-sdk-go/aws/session"
    "github.com/aws/aws-sdk-go/service/secretsmanager"
    "github.com/gorilla/mux"
    _ "github.com/lib/pq"
)

type Customer struct {
    ID        int    `json:"id"`
    Name      string `json:"name"`
    Email     string `json:"email"`
    CreditCard string `json:"credit_card"`
    SSN       string `json:"ssn"`
    Balance   float64 `json:"balance"`
}

type DBConfig struct {
    Username string `json:"username"`
    Password string `json:"password"`
    Host     string `json:"host"`
    Port     int    `json:"port"`
    Database string `json:"database"`
}

var (
    db *sql.DB
    appLog *log.Logger
    accessLog *log.Logger
)

func init() {
    // Set up loggers
    appFile, err := os.OpenFile("/var/log/backend-api.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
    if err != nil {
        log.Printf("Failed to open app log file: %v", err)
        appLog = log.New(os.Stdout, "APP: ", log.LstdFlags)
    } else {
        appLog = log.New(appFile, "", log.LstdFlags)
    }

    accessFile, err := os.OpenFile("/var/log/backend-api-access.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
    if err != nil {
        log.Printf("Failed to open access log file: %v", err)
        accessLog = log.New(os.Stdout, "ACCESS: ", log.LstdFlags)
    } else {
        accessLog = log.New(accessFile, "", log.LstdFlags)
    }
}

func getDBCredentials() (*DBConfig, error) {
    sess := session.Must(session.NewSession())
    svc := secretsmanager.New(sess)

    secretArn := os.Getenv("DB_SECRET_ARN")
    if secretArn == "" {
        return nil, fmt.Errorf("DB_SECRET_ARN not set")
    }

    result, err := svc.GetSecretValue(&secretsmanager.GetSecretValueInput{
        SecretId: aws.String(secretArn),
    })
    if err != nil {
        return nil, fmt.Errorf("failed to get secret: %v", err)
    }

    var config DBConfig
    if err := json.Unmarshal([]byte(*result.SecretString), &config); err != nil {
        return nil, fmt.Errorf("failed to unmarshal secret: %v", err)
    }

    return &config, nil
}

func initDB() error {
    config, err := getDBCredentials()
    if err != nil {
        // Fallback to environment variables for local testing
        appLog.Printf("Failed to get DB credentials from Secrets Manager: %v", err)
        
        // Use hardcoded values for demo (INSECURE!)
        config = &DBConfig{
            Username: "dbadmin",
            Password: "${db_password}",
            Host:     os.Getenv("DB_HOST"),
            Port:     5432,
            Database: "customerdb",
        }
    }

    psqlInfo := fmt.Sprintf("host=%s port=%d user=%s password=%s dbname=%s sslmode=require",
        config.Host, config.Port, config.Username, config.Password, config.Database)

    var dbErr error
    db, dbErr = sql.Open("postgres", psqlInfo)
    if dbErr != nil {
        return dbErr
    }

    if err := db.Ping(); err != nil {
        return err
    }

    // Create tables if they don't exist
    createTableSQL := `
    CREATE TABLE IF NOT EXISTS customers (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        email VARCHAR(100) UNIQUE NOT NULL,
        credit_card VARCHAR(20),
        ssn VARCHAR(11),
        balance DECIMAL(10,2)
    );`

    if _, err := db.Exec(createTableSQL); err != nil {
        return err
    }

    // Insert sample data if table is empty
    var count int
    db.QueryRow("SELECT COUNT(*) FROM customers").Scan(&count)
    if count == 0 {
        insertSQL := `
        INSERT INTO customers (name, email, credit_card, ssn, balance) VALUES
        ('John Doe', 'john@example.com', '4111-1111-1111-1111', '123-45-6789', 10000.50),
        ('Jane Smith', 'jane@example.com', '5500-0000-0000-0004', '987-65-4321', 25000.75),
        ('Bob Johnson', 'bob@example.com', '3400-0000-0000-009', '456-78-9012', 5000.00);`
        
        if _, err := db.Exec(insertSQL); err != nil {
            appLog.Printf("Failed to insert sample data: %v", err)
        }
    }

    appLog.Println("Database initialized successfully")
    return nil
}

func getCustomers(w http.ResponseWriter, r *http.Request) {
    rows, err := db.Query("SELECT id, name, email, credit_card, ssn, balance FROM customers")
    if err != nil {
        appLog.Printf("Database error: %v", err)
        http.Error(w, "Database error", http.StatusInternalServerError)
        return
    }
    defer rows.Close()

    var customers []Customer
    for rows.Next() {
        var c Customer
        if err := rows.Scan(&c.ID, &c.Name, &c.Email, &c.CreditCard, &c.SSN, &c.Balance); err != nil {
            appLog.Printf("Scan error: %v", err)
            continue
        }
        customers = append(customers, c)
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(customers)
}

func getCustomer(w http.ResponseWriter, r *http.Request) {
    vars := mux.Vars(r)
    id := vars["id"]

    var c Customer
    err := db.QueryRow("SELECT id, name, email, credit_card, ssn, balance FROM customers WHERE id = $1", id).Scan(
        &c.ID, &c.Name, &c.Email, &c.CreditCard, &c.SSN, &c.Balance,
    )

    if err == sql.ErrNoRows {
        http.Error(w, "Customer not found", http.StatusNotFound)
        return
    } else if err != nil {
        appLog.Printf("Database error: %v", err)
        http.Error(w, "Database error", http.StatusInternalServerError)
        return
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(c)
}

func healthCheck(w http.ResponseWriter, r *http.Request) {
    if err := db.Ping(); err != nil {
        http.Error(w, "Database connection failed", http.StatusServiceUnavailable)
        return
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(map[string]string{
        "status": "healthy",
        "service": "backend-api",
        "time": time.Now().Format(time.RFC3339),
    })
}

func main() {
    // Get DB connection details from environment or instance metadata
    if dbHost := os.Getenv("DB_HOST"); dbHost == "" {
        // Try to get from parameter store or secrets manager
        // For now, we'll wait for Terraform to provide it
        appLog.Println("Waiting for database configuration...")
        time.Sleep(30 * time.Second)
    }

    // Initialize database
    if err := initDB(); err != nil {
        appLog.Fatalf("Failed to initialize database: %v", err)
    }
    defer db.Close()

    // Set up routes
    router := mux.NewRouter()
    router.HandleFunc("/health", healthCheck).Methods("GET")
    router.HandleFunc("/api/customers", getCustomers).Methods("GET")
    router.HandleFunc("/api/customers/{id}", getCustomer).Methods("GET")

    // Logging middleware
    router.Use(func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            start := time.Now()
            accessLog.Printf("Method=%s Path=%s RemoteAddr=%s UserAgent=%s",
                r.Method, r.URL.Path, r.RemoteAddr, r.UserAgent())
            next.ServeHTTP(w, r)
            accessLog.Printf("Path=%s Duration=%v", r.URL.Path, time.Since(start))
        })
    })

    port := "8081"
    appLog.Printf("Backend API starting on port %s", port)
    appLog.Printf("Database connected, serving customer data")
    
    if err := http.ListenAndServe(":"+port, router); err != nil {
        appLog.Fatalf("Server failed to start: %v", err)
    }
}
APICODE

# Create go.mod
cat > go.mod <<'GOMOD'
module backend-api

go 1.19

require (
    github.com/aws/aws-sdk-go v1.45.0
    github.com/gorilla/mux v1.8.0
    github.com/lib/pq v1.10.9
)
GOMOD

# Get dependencies and build
export GOPROXY=https://proxy.golang.org
go mod tidy
go build -o backend-api main.go

# Set environment variables
export DB_SECRET_ARN="${db_secret_arn}"
export DB_HOST=$(aws secretsmanager get-secret-value --region ${region} --secret-id ${db_secret_arn} --query SecretString --output text | jq -r .host)
export AWS_REGION="${region}"

# Create systemd service
cat > /etc/systemd/system/backend-api.service <<'SERVICE'
[Unit]
Description=Backend API Service
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/backend-api
Environment="DB_SECRET_ARN=${db_secret_arn}"
Environment="AWS_REGION=${region}"
ExecStart=/opt/backend-api/backend-api
Restart=always
StandardOutput=append:/var/log/backend-api-stdout.log
StandardError=append:/var/log/backend-api-stderr.log

[Install]
WantedBy=multi-user.target
SERVICE

# Start the service
systemctl daemon-reload
systemctl enable backend-api
systemctl start backend-api

echo "Backend API setup complete!"