#!/bin/bash

set -e

echo "📦 Checking Go environment..."
go version

echo "✅ Running go vet..."
go vet ./...

echo "🧹 Checking formatting (gofmt)..."
fmt_issues=$(gofmt -l .)
if [ -n "$fmt_issues" ]; then
  echo "⚠️ The following files need formatting:"
  echo "$fmt_issues"
  go fmt ./...
else
  echo "✅ Code is properly formatted"
fi

echo "🔍 Running staticcheck..."
staticcheck ./...

echo "📊 Checking function complexity (gocyclo)..."
gocyclo -over 10 $(find . -name '*.go' ! -name '*_test.go')


echo "🧪 Running tests with coverage..."
go test -cover ./...


echo "Checking vulnerabilities"
govulncheck ./...


echo "✅ All checks passed!"
