# The 10.3 server with a TOTP second factor. Built by scripts/ssh-test-servers.sh, which passes the
# pinned image from scripts/lib/openssh-fixture.sh. The package version is pinned too, so the build
# fails rather than changing when Alpine moves it.
ARG OPENSSH_IMAGE
FROM ${OPENSSH_IMAGE}
RUN apk add --no-cache google-authenticator=1.11-r0
COPY pam-sshd-totp /etc/pam.d/sshd
