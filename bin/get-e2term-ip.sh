#!/bin/bash

# Get E2Term IP address from the O-RAN RIC deployment
# This script retrieves the cluster IP of the E2Term service

set -e

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed or not in PATH"
    exit 1
fi

# Check if the RIC namespace exists
if ! kubectl get namespace ricplt &> /dev/null; then
    echo "Error: O-RAN RIC namespace 'ricplt' not found. Is the RIC deployed?"
    exit 1
fi

# Get the E2Term service IP
E2TERM_IP=$(kubectl get service e2term-sctp-alpha -n ricplt -o jsonpath='{.spec.clusterIP}' 2>/dev/null)

if [ -z "$E2TERM_IP" ]; then
    echo "Error: E2Term service not found or not ready"
    echo "Available services in ricplt namespace:"
    kubectl get services -n ricplt
    exit 1
fi

echo "$E2TERM_IP"