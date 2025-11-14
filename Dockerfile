FROM alpine:3.22

ADD https://github.com/desertwitch/nwipe-pc.git /tmp/nwipe

WORKDIR /tmp/nwipe

RUN apk update && \
    apk upgrade && \
    apk add \
        automake \
        make \
        curl \
        ncurses-dev \
        libevent \
        parted-dev \
        libconfig-dev \
        hdparm \
        dmidecode \
        smartmontools \
        autoconf \
        gcc \
        g++ \
        linux-headers && \
    ash autogen.sh && \
    ash configure && \
    make && \
    make install && \
    cd /tmp && \
    apk del automake make autoconf gcc g++ && \
    rm -rf nwipe

WORKDIR /app

ENV TERM=xterm

CMD ["/usr/local/bin/nwipe"]
