#!/bin/bash
# Serves PMTiles + the web app on a single port with CORS headers
# Open http://localhost:8080 in browser after running

PORT=8080
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Starting PMTiles + app server on http://localhost:$PORT"
echo "Open http://localhost:$PORT in your browser."
echo ""

# http-server supports range requests and CORS out of the box
"$PROJECT_DIR/node_modules/.bin/http-server" \
  "$PROJECT_DIR/public" \
  -p $PORT \
  --cors \
  -a localhost \
  -c-1 \
  --gzip
