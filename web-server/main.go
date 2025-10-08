package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
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
	// Blocked IP ranges for SSRF protection
	blockedCIDRs = []string{
		"169.254.0.0/16", // AWS metadata service
		"10.0.0.0/8",     // Private network
		"172.16.0.0/12",  // Private network
		"192.168.0.0/16", // Private network
		"127.0.0.0/8",    // Localhost
		"::1/128",        // IPv6 localhost
		"fe80::/10",      // IPv6 link-local
		"fc00::/7",       // IPv6 private
	}
)

func init() {
	sess := session.Must(session.NewSessionWithOptions(session.Options{
		SharedConfigState: session.SharedConfigEnable,
		Config: aws.Config{
			Region: aws.String(os.Getenv("AWS_REGION")),
		},
	}))
	dynamoClient = dynamodb.New(sess)
}

// isBlockedIP checks if an IP is in blocked ranges
func isBlockedIP(ip string) bool {
	parsedIP := net.ParseIP(ip)
	if parsedIP == nil {
		return true // Block invalid IPs
	}

	for _, cidr := range blockedCIDRs {
		_, network, err := net.ParseCIDR(cidr)
		if err != nil {
			continue
		}
		if network.Contains(parsedIP) {
			return true
		}
	}
	return false
}

// SECURE: This endpoint now has SSRF protection
func fetchURL(w http.ResponseWriter, r *http.Request) {
	targetURL := r.URL.Query().Get("url")
	if targetURL == "" {
		http.Error(w, "URL parameter is required", http.StatusBadRequest)
		return
	}

	// Parse and validate URL
	parsedURL, err := url.Parse(targetURL)
	if err != nil {
		http.Error(w, "Invalid URL format", http.StatusBadRequest)
		return
	}

	// Only allow HTTP/HTTPS
	if parsedURL.Scheme != "http" && parsedURL.Scheme != "https" {
		http.Error(w, "Only HTTP/HTTPS URLs are allowed", http.StatusBadRequest)
		return
	}

	// Resolve hostname to IP
	host := parsedURL.Hostname()
	ips, err := net.LookupIP(host)
	if err != nil {
		http.Error(w, "Failed to resolve hostname", http.StatusBadRequest)
		return
	}

	// Check all resolved IPs
	for _, ip := range ips {
		if isBlockedIP(ip.String()) {
			log.Printf("Blocked SSRF attempt to %s (resolved to %s)", targetURL, ip.String())
			http.Error(w, "Access to internal/metadata endpoints is not allowed", http.StatusForbidden)
			return
		}
	}

	log.Printf("Fetching allowed URL: %s", targetURL)

	// Use custom transport with additional security
	client := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			DisableKeepAlives: true,
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				// Double-check during connection
				host, _, _ := net.SplitHostPort(addr)
				if isBlockedIP(host) {
					return nil, fmt.Errorf("connection to blocked IP not allowed")
				}
				dialer := &net.Dialer{
					Timeout:   5 * time.Second,
					KeepAlive: -1,
				}
				return dialer.DialContext(ctx, network, addr)
			},
		},
	}

	resp, err := client.Get(targetURL)
	if err != nil {
		// Don't expose internal error details
		if strings.Contains(err.Error(), "blocked") {
			http.Error(w, "Access denied", http.StatusForbidden)
		} else {
			http.Error(w, "Error fetching URL", http.StatusInternalServerError)
		}
		return
	}
	defer resp.Body.Close()

	// Limit response size to prevent memory exhaustion
	limitedReader := io.LimitReader(resp.Body, 1024*1024) // 1MB max
	body, err := io.ReadAll(limitedReader)
	if err != nil {
		http.Error(w, "Error reading response", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain")
	w.Write(body)
}

func healthCheck(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status":   "healthy",
		"time":     time.Now().Format(time.RFC3339),
		"security": "hardened",
	})
}

func getProduct(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	productID := vars["id"]

	log.Printf("Getting product: %s", productID)

	result, err := dynamoClient.GetItem(&dynamodb.GetItemInput{
		TableName: aws.String(tableName),
		Key: map[string]*dynamodb.AttributeValue{
			"ID": {
				S: aws.String(productID),
			},
		},
	})

	if err != nil {
		log.Printf("DynamoDB error: %v", err)
		http.Error(w, "Error getting product", http.StatusInternalServerError)
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
	log.Println("Listing all products")

	result, err := dynamoClient.Scan(&dynamodb.ScanInput{
		TableName: aws.String(tableName),
	})

	if err != nil {
		log.Printf("DynamoDB error: %v", err)
		http.Error(w, "Error scanning products", http.StatusInternalServerError)
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

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	router := mux.NewRouter()

	// Routes
	router.HandleFunc("/health", healthCheck).Methods("GET")
	router.HandleFunc("/fetch", fetchURL).Methods("GET") // NOW SECURE with SSRF protection
	router.HandleFunc("/api/products", listProducts).Methods("GET")
	router.HandleFunc("/api/products/{id}", getProduct).Methods("GET")

	// Security headers middleware
	router.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("X-Content-Type-Options", "nosniff")
			w.Header().Set("X-Frame-Options", "DENY")
			w.Header().Set("X-XSS-Protection", "1; mode=block")
			next.ServeHTTP(w, r)
		})
	})

	log.Printf("Starting SECURE server on port %s", port)
	log.Printf("SSRF protection enabled - metadata endpoints blocked")
	log.Fatal(http.ListenAndServe(":"+port, router))
}
