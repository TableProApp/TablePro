FROM alpine:3.21

RUN apk add --no-cache openssh-server \
    && adduser -D -s /bin/sh tunnel \
    && sed -i 's/^tunnel:!:/tunnel:*:/' /etc/shadow \
    && mkdir -p /home/tunnel/.ssh

COPY materials/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key
COPY materials/client_ed25519_key.pub /home/tunnel/.ssh/authorized_keys

RUN chmod 600 /etc/ssh/ssh_host_ed25519_key \
    && chown -R tunnel:tunnel /home/tunnel/.ssh \
    && chmod 700 /home/tunnel/.ssh \
    && chmod 600 /home/tunnel/.ssh/authorized_keys \
    && printf '%s\n' \
        'Port 22' \
        'HostKey /etc/ssh/ssh_host_ed25519_key' \
        'PermitRootLogin no' \
        'PasswordAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'PubkeyAuthentication yes' \
        'AllowTcpForwarding yes' \
        'AllowUsers tunnel' \
        'PermitOpen any' \
        'X11Forwarding no' \
        'AllowAgentForwarding no' \
        > /etc/ssh/sshd_config

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
