# Ambiente descartavel para testar os scripts Linux sem tocar em Docker, systemd
# ou apt de verdade: os comandos perigosos sao os de mentira em tests/fake/bin.
FROM ubuntu:22.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash curl python3 unzip zip iproute2 openssl ca-certificates util-linux procps git psmisc \
 && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash loja \
 && mkdir -p /run/systemd/system /env /data/nfce /app/ncommerce_api /fake /var/lib/docker /opt \
      /etc/ssh/sshd_config.d /etc/udev/rules.d /etc/systemd/system /etc/nginx/sites-enabled /etc/apt/trusted.gpg.d \
 && touch /etc/ssh/sshd_config \
 && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=localhost \
      -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" -keyout /fake/key.pem -out /fake/cert.pem 2>/dev/null \
 && cp /fake/cert.pem /usr/local/share/ca-certificates/fake.crt && update-ca-certificates \
 && chown -R loja /env /data /app /fake /opt /etc/ssh /etc/udev/rules.d /etc/systemd/system /etc/nginx /etc/apt
USER loja
ENV LANG=C.UTF-8
WORKDIR /home/loja
