FROM registry.fedoraproject.org/fedora

ARG QUARTZ_REF=adf442036b244dfafea6287bf69c22f4eb133b79

USER root

RUN dnf install -y git make nodejs awk && \
    npm install -g n && \
    n lts && \
    npm install -g npm@latest && \
    dnf remove -y nodejs

RUN git config --global --add safe.directory /repo
RUN cd /opt && git clone https://github.com/jackyzha0/quartz.git && \
    cd quartz && git checkout ${QUARTZ_REF} && \
    npm ci

COPY quartz.config.ts /opt/quartz/
COPY quartz.layout.ts /opt/quartz/

COPY icon.png /opt/quartz/quartz/static/icon.png

WORKDIR /opt/quartz
