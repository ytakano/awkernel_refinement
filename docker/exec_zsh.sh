export USERNAME=$(whoami)
export UID=$(id -u)
export GID=$(id -g)
export LIBVIRT_GID=$(getent group libvirt | cut -d: -f3)
docker compose exec awkernel_refinement zsh
