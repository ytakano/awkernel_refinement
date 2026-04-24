export USERNAME=$(whoami)
export UID=$(id -u)
export GID=$(id -g)
docker compose exec awkernel_refinement zsh
