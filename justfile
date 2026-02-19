# This help
default:
  @just --list

# Deploy patched extensions and restart openclaw service
deploy:
  ./deploy.sh --restart
