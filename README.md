# Obzorarr Docker Image

<p align="center">
  <img src="https://engels74.net/img/image-logos/obzorarr.svg" alt="obzorarr" style="width: 30%;"/>
</p>

<p align="center">
  <a href="https://github.com/engels74/obzorarr-docker/blob/master/LICENSE"><img src="https://img.shields.io/badge/License%20(Image)-GPL--3.0-orange" alt="License (Image)"></a>
  <a href="https://github.com/engels74/obzorarr"><img src="https://img.shields.io/badge/License%20(App)-AGPL--3.0-blue" alt="License (App)"></a>
  <a href="https://github.com/engels74/obzorarr/stargazers"><img src="https://img.shields.io/github/stars/engels74/obzorarr.svg" alt="GitHub Stars"></a>
</p>

## 📖 Documentation

This repository contains Docker and Docker Compose configuration for running obzorarr in containerized environments.

For more information about the obzorarr application, visit [github.com/engels74/obzorarr](https://github.com/engels74/obzorarr).

## 🐋 Docker Image

### Docker Compose

To get started with obzorarr using Docker, follow these steps:

1. **Create a Docker Compose file** (e.g., `docker-compose.yml`):
    ```yaml
    services:
      obzorarr:
        container_name: obzorarr
        image: ghcr.io/engels74/obzorarr:latest
        ports:
          - 3000:3000
        environment:
          - PUID=1000
          - PGID=1000
          - UMASK=002
          - TZ=Etc/UTC
        volumes:
          - ./config:/config
        restart: unless-stopped
    ```

2. **Run the Docker container:**
    ```sh
    docker compose up -d
    ```

3. **Access obzorarr** at `http://localhost:3000`

## 📜 License

- **Docker Image**: Licensed under the GPL-3.0 License. See the [LICENSE](https://github.com/engels74/obzorarr-docker/blob/master/LICENSE) file for details.
- **Obzorarr Application**: Licensed under the AGPL-3.0 License. See the [obzorarr repository](https://github.com/engels74/obzorarr) for details.
