FROM alpine:3.22

COPY materials/ssh_client.pub /tmp/ssh_client.pub

RUN apk add --no-cache openssh-server \
    && adduser -D -s /bin/sh tunnel \
    && echo 'tunnel:fixture-only' | chpasswd \
    && mkdir -p /home/tunnel/.ssh /run/sshd \
    && chown -R tunnel:tunnel /home/tunnel/.ssh \
    && chmod 700 /home/tunnel/.ssh \
    && printf '%s\n' \
      'PermitRootLogin no' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PubkeyAuthentication yes' \
      'AllowTcpForwarding local' \
      'AllowStreamLocalForwarding yes' \
      'PermitOpen mysql-ssh.tablepro.test:3306 mysql-mtls-ssh.tablepro.test:3306 mssql-ssh.tablepro.test:1433' \
      'X11Forwarding no' \
      'AllowAgentForwarding no' \
      > /etc/ssh/sshd_config

CMD ["sh", "-c", "ssh-keygen -A && install -o tunnel -g tunnel -m 600 /tmp/ssh_client.pub /home/tunnel/.ssh/authorized_keys && exec /usr/sbin/sshd -D -e -p 2222"]
