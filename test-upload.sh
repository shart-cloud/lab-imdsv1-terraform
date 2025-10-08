#!/bin/bash
# Test script for file upload vulnerability

echo "=== File Upload Vulnerability Test ==="
echo ""

# Create a test file
echo '#!/bin/bash' > test-payload.sh
echo 'echo "Payload executed!"' >> test-payload.sh
echo 'whoami' >> test-payload.sh
echo 'id' >> test-payload.sh
chmod +x test-payload.sh

# Test upload endpoint
echo "Testing file upload to localhost:8080..."
curl -X POST -F "file=@test-payload.sh" http://localhost:8080/upload

echo ""
echo "Upload test complete. Check /var/www/uploads/ for uploaded file."

# Clean up
rm test-payload.sh