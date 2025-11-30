FROM docker.io/library/ruby:3.4.7-slim

RUN apt-get update \
    && apt-get -y upgrade \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && echo "have made a change called owls"
