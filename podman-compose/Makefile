up:
		podman-compose up -d
logs:
		podman logs podman-compose_trocco-self-hosted-runner-normal_1 && podman logs podman-compose_trocco-self-hosted-runner-enhanced_1
up-normal:
		podman-compose up -d trocco-self-hosted-runner-normal
logs-normal:
		podman logs podman-compose_trocco-self-hosted-runner-normal_1
down:
		podman-compose down -v
destroy:
		podman stop -a && podman rm -f -a && podman pod rm -f -a && podman network prune -f
