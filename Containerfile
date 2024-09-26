FROM registry.fedoraproject.org/fedora

ARG QUARTZ_REF=v4.2.3

USER root

RUN dnf install -y git make nodejs && \
    npm install -g n && \
    n lts && \
    npm install -g npm@latest && \
    dnf remove -y nodejs

RUN cd /opt && git clone https://github.com/jackyzha0/quartz.git && \
    cd quartz && git checkout ${QUARTZ_REF} && \
    npm ci

COPY quartz.config.ts /opt/quartz/
COPY quartz.layout.ts /opt/quartz/

WORKDIR /opt/quartz
