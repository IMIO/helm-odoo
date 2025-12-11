#!/usr/bin/env python3
import subprocess
import os

os.chdir('/home/anuttinck/workspace/github/imio/helm-odoo')

# Check current status
print("=== Git Status ===")
result = subprocess.run(['git', 'status', '--short'], capture_output=True, text=True)
print(result.stdout)
print(result.stderr)

# Add all changes
print("\n=== Adding changes ===")
result = subprocess.run(['git', 'add', '-A'], capture_output=True, text=True)
print(result.stdout)
print(result.stderr)

# Commit
print("\n=== Committing ===")
commit_message = """refactor: remove nginx proxy container and use Ingress directly

- Remove nginx proxy sidecar container from deployment
- Update service to expose Odoo port (8069) directly
- Configure Ingress with proper Odoo annotations for proxy settings
- Remove nginx configmap (keep only maintenance page configs)
- Bump chart version to 0.3.0

This change simplifies the architecture by leveraging Kubernetes Ingress
controller capabilities instead of an additional nginx proxy layer.

Breaking change: Service port changed from 80 to 8069"""

result = subprocess.run(['git', 'commit', '-m', commit_message], capture_output=True, text=True)
print(result.stdout)
print(result.stderr)

# Push
print("\n=== Pushing to origin ===")
result = subprocess.run(['git', 'push', 'origin', 'feat/refactor-ingress'], capture_output=True, text=True)
print(result.stdout)
print(result.stderr)

print("\n=== Done ===")
