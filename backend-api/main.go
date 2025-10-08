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
	ID         int     `json:"id"`
	Name       string  `json:"name"`
	Email      string  `json:"email"`
	CreditCard string  `json:"credit_card"`
	SSN        string  `json:"ssn"`
	Balance    float64 `json:"balance"`
}

type DBConfig struct {
	Username string `json:"username"`
	Password string `json:"password"`
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Database string `json:"database"`
}

var (
	db        *sql.DB
	appLog    *log.Logger
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

		// Use environment variables as fallback
		config = &DBConfig{
			Username: os.Getenv("DB_USERNAME"),
			Password: os.Getenv("DB_PASSWORD"),
			Host:     os.Getenv("DB_HOST"),
			Port:     5432,
			Database: os.Getenv("DB_NAME"),
		}

		if config.Host == "" {
			return fmt.Errorf("database host not configured")
		}
	}

	psqlInfo := fmt.Sprintf("host=%s port=%d user=%s password=%s dbname=%s sslmode=require",
		config.Host, config.Port, config.Username, config.Password, config.Database)

	var dbErr error
	db, dbErr = sql.Open("postgres", psqlInfo)
	if dbErr != nil {
		return dbErr
	}

	// Test connection
	if err := db.Ping(); err != nil {
		return fmt.Errorf("failed to ping database: %v", err)
	}

	// Create tables if they don't exist
	createTableSQL := `
	CREATE TABLE IF NOT EXISTS customers (
		id SERIAL PRIMARY KEY,
		name VARCHAR(100) NOT NULL,
		email VARCHAR(100) UNIQUE NOT NULL,
		credit_card VARCHAR(20),
		ssn VARCHAR(11),
		balance DECIMAL(10,2),
		created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
	);`

	if _, err := db.Exec(createTableSQL); err != nil {
		return fmt.Errorf("failed to create table: %v", err)
	}

	// Insert sample sensitive data if table is empty
	var count int
	db.QueryRow("SELECT COUNT(*) FROM customers").Scan(&count)
	if count == 0 {
		insertSQL := `
		INSERT INTO customers (name, email, credit_card, ssn, balance) VALUES
		('John Doe', 'john@example.com', '4111-1111-1111-1111', '123-45-6789', 10000.50),
		('Jane Smith', 'jane@example.com', '5500-0000-0000-0004', '987-65-4321', 25000.75),
		('Bob Johnson', 'bob@example.com', '3400-0000-0000-009', '456-78-9012', 5000.00),
		('Alice Brown', 'alice@example.com', '6011-0000-0000-0004', '234-56-7890', 15000.00),
		('Charlie Wilson', 'charlie@example.com', '3566-0020-2036-0505', '345-67-8901', 7500.25);`

		if _, err := db.Exec(insertSQL); err != nil {
			appLog.Printf("Failed to insert sample data: %v", err)
		} else {
			appLog.Println("Sample customer data inserted")
		}
	}

	appLog.Println("Database initialized successfully")
	return nil
}

func getCustomers(w http.ResponseWriter, r *http.Request) {
	appLog.Println("Fetching all customers")

	rows, err := db.Query("SELECT id, name, email, credit_card, ssn, balance FROM customers ORDER BY id")
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

	appLog.Printf("Returning %d customers", len(customers))
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(customers)
}

func getCustomer(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	id := vars["id"]

	appLog.Printf("Fetching customer with ID: %s", id)

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

// VULNERABLE: SQL Injection endpoint for CTF purposes
func searchCustomers(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("q")
	if query == "" {
		http.Error(w, "Query parameter 'q' is required", http.StatusBadRequest)
		return
	}

	// VULNERABLE: Direct string concatenation allows SQL injection
	sqlQuery := fmt.Sprintf("SELECT id, name, email, credit_card, ssn, balance FROM customers WHERE name LIKE '%%%s%%' OR email LIKE '%%%s%%'", query, query)
	appLog.Printf("Executing search query: %s", sqlQuery)

	rows, err := db.Query(sqlQuery)
	if err != nil {
		appLog.Printf("Database error: %v", err)
		// Return the error for debugging (INSECURE)
		http.Error(w, fmt.Sprintf("Database error: %v", err), http.StatusInternalServerError)
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

func healthCheck(w http.ResponseWriter, r *http.Request) {
	if err := db.Ping(); err != nil {
		http.Error(w, "Database connection failed", http.StatusServiceUnavailable)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status":  "healthy",
		"service": "backend-api",
		"time":    time.Now().Format(time.RFC3339),
	})
}

func main() {
	appLog.Println("Starting Backend API...")

	// Wait a bit for database to be ready
	time.Sleep(10 * time.Second)

	// Initialize database connection
	maxRetries := 5
	for i := 0; i < maxRetries; i++ {
		if err := initDB(); err != nil {
			appLog.Printf("Failed to initialize database (attempt %d/%d): %v", i+1, maxRetries, err)
			if i < maxRetries-1 {
				time.Sleep(10 * time.Second)
				continue
			}
			appLog.Fatalf("Failed to initialize database after %d attempts", maxRetries)
		}
		break
	}
	defer db.Close()

	// Set up routes
	router := mux.NewRouter()
	router.HandleFunc("/health", healthCheck).Methods("GET")
	router.HandleFunc("/api/customers", getCustomers).Methods("GET")
	router.HandleFunc("/api/customers/search", searchCustomers).Methods("GET") // VULNERABLE endpoint
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
	appLog.Printf("Backend API listening on port %s", port)
	appLog.Printf("Serving sensitive customer data from PostgreSQL")

	if err := http.ListenAndServe(":"+port, router); err != nil {
		appLog.Fatalf("Server failed to start: %v", err)
	}
}
