package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
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

// VULNERABLE: This endpoint is vulnerable to SSRF
func fetchURL(w http.ResponseWriter, r *http.Request) {
	url := r.URL.Query().Get("url")
	if url == "" {
		http.Error(w, "URL parameter is required", http.StatusBadRequest)
		return
	}

	log.Printf("Fetching URL: %s", url)

	// VULNERABILITY: No validation on the URL - allows IMDS access
	client := &http.Client{
		Timeout: 10 * time.Second,
	}

	resp, err := client.Get(url)
	if err != nil {
		http.Error(w, fmt.Sprintf("Error fetching URL: %v", err), http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, fmt.Sprintf("Error reading response: %v", err), http.StatusInternalServerError)
		return
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
	log.Println("Listing all products")

	result, err := dynamoClient.Scan(&dynamodb.ScanInput{
		TableName: aws.String(tableName),
	})

	if err != nil {
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

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	router := mux.NewRouter()

	// Routes
	router.HandleFunc("/health", healthCheck).Methods("GET")
	router.HandleFunc("/fetch", fetchURL).Methods("GET") // VULNERABLE ENDPOINT
	router.HandleFunc("/api/products", listProducts).Methods("GET")
	router.HandleFunc("/api/products/{id}", getProduct).Methods("GET")

	log.Printf("Starting server on port %s", port)
	log.Printf("SSRF vulnerable endpoint: /fetch?url=<target>")
	log.Fatal(http.ListenAndServe(":"+port, router))
}
