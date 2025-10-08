package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/dynamodb"
	"github.com/gorilla/mux"
)

type Product struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Price       string `json:"price"`
}

var (
	dynamoClient *dynamodb.DynamoDB
	tableName    = "Products"
	accessLog    *log.Logger
	ssrfLog      *log.Logger
	appLog       *log.Logger
)

func init() {
	// Set up different loggers for different purposes
	accessFile, err := os.OpenFile("/var/log/web-server-access.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
	if err != nil {
		log.Printf("Failed to open access log file: %v", err)
		accessLog = log.New(os.Stdout, "ACCESS: ", log.LstdFlags)
	} else {
		accessLog = log.New(accessFile, "", log.LstdFlags)
	}

	ssrfFile, err := os.OpenFile("/var/log/web-server-ssrf.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
	if err != nil {
		log.Printf("Failed to open SSRF log file: %v", err)
		ssrfLog = log.New(os.Stdout, "SSRF: ", log.LstdFlags)
	} else {
		ssrfLog = log.New(ssrfFile, "", log.LstdFlags)
	}

	appFile, err := os.OpenFile("/var/log/web-server.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
	if err != nil {
		log.Printf("Failed to open app log file: %v", err)
		appLog = log.New(os.Stdout, "APP: ", log.LstdFlags)
	} else {
		appLog = log.New(appFile, "", log.LstdFlags)
	}

	sess := session.Must(session.NewSessionWithOptions(session.Options{
		SharedConfigState: session.SharedConfigEnable,
		Config: aws.Config{
			Region: aws.String(os.Getenv("AWS_REGION")),
		},
	}))
	dynamoClient = dynamodb.New(sess)

	appLog.Println("Web server initialized")
}

// VULNERABLE: This endpoint is vulnerable to SSRF
func fetchURL(w http.ResponseWriter, r *http.Request) {
	url := r.URL.Query().Get("url")
	if url == "" {
		http.Error(w, "URL parameter is required", http.StatusBadRequest)
		return
	}

	clientIP := r.RemoteAddr
	userAgent := r.UserAgent()

	// Log potential SSRF attempt - especially if targeting metadata
	if strings.Contains(url, "169.254.169.254") {
		ssrfLog.Printf("CRITICAL: IMDS access attempt! ClientIP=%s UserAgent=%s TargetURL=%s",
			clientIP, userAgent, url)
		appLog.Printf("ALERT: Metadata service accessed via SSRF from %s", clientIP)
	} else if strings.Contains(url, "127.0.0.1") || strings.Contains(url, "localhost") {
		ssrfLog.Printf("WARNING: Localhost access attempt! ClientIP=%s UserAgent=%s TargetURL=%s",
			clientIP, userAgent, url)
	} else if strings.Contains(url, "10.") || strings.Contains(url, "172.") || strings.Contains(url, "192.168.") {
		ssrfLog.Printf("WARNING: Private network access attempt! ClientIP=%s UserAgent=%s TargetURL=%s",
			clientIP, userAgent, url)
	} else {
		ssrfLog.Printf("INFO: External URL fetch ClientIP=%s UserAgent=%s TargetURL=%s",
			clientIP, userAgent, url)
	}

	appLog.Printf("Fetching URL: %s from client %s", url, clientIP)

	// VULNERABILITY: No validation on the URL - allows IMDS access
	client := &http.Client{
		Timeout: 10 * time.Second,
	}

	resp, err := client.Get(url)
	if err != nil {
		appLog.Printf("Error fetching URL %s: %v", url, err)
		http.Error(w, fmt.Sprintf("Error fetching URL: %v", err), http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		appLog.Printf("Error reading response from %s: %v", url, err)
		http.Error(w, fmt.Sprintf("Error reading response: %v", err), http.StatusInternalServerError)
		return
	}

	// Log if credentials were likely stolen
	responseStr := string(body)
	if strings.Contains(responseStr, "AccessKeyId") && strings.Contains(responseStr, "SecretAccessKey") {
		ssrfLog.Printf("CRITICAL: AWS credentials exposed! ClientIP=%s TargetURL=%s",
			clientIP, url)
		appLog.Printf("SECURITY BREACH: AWS credentials were accessed via SSRF from %s", clientIP)
	}

	w.Header().Set("Content-Type", "text/plain")
	w.Write(body)
}

func healthCheck(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status": "healthy",
		"time":   time.Now().Format(time.RFC3339),
	})
}

func getProduct(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	productID := vars["id"]

	appLog.Printf("Getting product: %s", productID)

	result, err := dynamoClient.GetItem(&dynamodb.GetItemInput{
		TableName: aws.String(tableName),
		Key: map[string]*dynamodb.AttributeValue{
			"ID": {
				S: aws.String(productID),
			},
		},
	})

	if err != nil {
		appLog.Printf("Error getting product %s: %v", productID, err)
		http.Error(w, fmt.Sprintf("Error getting product: %v", err), http.StatusInternalServerError)
		return
	}

	if result.Item == nil {
		http.Error(w, "Product not found", http.StatusNotFound)
		return
	}

	product := Product{
		ID:          *result.Item["ID"].S,
		Name:        *result.Item["Name"].S,
		Description: *result.Item["Description"].S,
		Price:       *result.Item["Price"].S,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(product)
}

func listProducts(w http.ResponseWriter, r *http.Request) {
	appLog.Println("Listing all products")

	result, err := dynamoClient.Scan(&dynamodb.ScanInput{
		TableName: aws.String(tableName),
	})

	if err != nil {
		appLog.Printf("Error scanning products: %v", err)
		http.Error(w, fmt.Sprintf("Error scanning products: %v", err), http.StatusInternalServerError)
		return
	}

	var products []Product
	for _, item := range result.Items {
		products = append(products, Product{
			ID:          *item["ID"].S,
			Name:        *item["Name"].S,
			Description: *item["Description"].S,
			Price:       *item["Price"].S,
		})
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(products)
}

// Logging middleware
func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		// Log the request
		accessLog.Printf("Method=%s Path=%s RemoteAddr=%s UserAgent=%s",
			r.Method,
			r.URL.Path,
			r.RemoteAddr,
			r.UserAgent(),
		)

		// Call the next handler
		next.ServeHTTP(w, r)

		// Log the duration
		duration := time.Since(start)
		accessLog.Printf("Path=%s Duration=%v", r.URL.Path, duration)
	})
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	router := mux.NewRouter()

	// Apply logging middleware
	router.Use(loggingMiddleware)

	// Routes
	router.HandleFunc("/health", healthCheck).Methods("GET")
	router.HandleFunc("/fetch", fetchURL).Methods("GET") // VULNERABLE ENDPOINT
	router.HandleFunc("/api/products", listProducts).Methods("GET")
	router.HandleFunc("/api/products/{id}", getProduct).Methods("GET")

	appLog.Printf("Starting server on port %s", port)
	appLog.Printf("SSRF vulnerable endpoint active: /fetch?url=<target>")
	appLog.Printf("All access and SSRF attempts will be logged to CloudWatch")

	if err := http.ListenAndServe(":"+port, router); err != nil {
		appLog.Fatalf("Server failed to start: %v", err)
	}
}
