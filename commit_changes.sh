#!/bin/bash
cd /home/anuttinck/workspace/github/imio/helm-odoo

# Add all changes
git add -A

# Commit with message
git commit -m "refactor: remove nginx proxy container and use Ingress directly

- Remove nginx proxy sidecar container from deployment
- Update service to expose Odoo port (8069) directly
- Configure Ingress with proper Odoo annotations for proxy settings
- Remove nginx configmap (keep only maintenance page configs)
- Bump chart version to 0.3.0

This change simplifies the architecture by leveraging Kubernetes Ingress
controller capabilities instead of an additional nginx proxy layer.

Breaking change: Service port changed from 80 to 8069"

# Push to origin
git push origin feat/refactor-ingress

echo "Changes committed and pushed successfully!"
