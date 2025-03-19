FROM registry.fedoraproject.org/fedora

ARG QUARTZ_REF=eccad3da5d7b84b0f78a85b357efedef8c0127fc

USER root

RUN dnf install -y git make nodejs && \
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

WORKDIR /opt/quartz
