FROM archlinux@sha256:4e77cf2ea5f410e6f8be5abf93ccf17ce2436e87a138c167208356711a405dbd

RUN pacman -Sy --noconfirm krb5 openssl \
    && pacman -Scc --noconfirm

USER nobody
