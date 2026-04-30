export USERNAME=$(whoami)
export UID=$(id -u)
export GID=$(id -g)
export LIBVIRT_GID=$(getent group libvirt | cut -d: -f3)
docker compose exec -u root awkernel_refinement zsh
