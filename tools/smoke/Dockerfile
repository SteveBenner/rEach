FROM ruby:2.6.10-slim
RUN printf "deb http://archive.debian.org/debian bullseye main\n" > /etc/apt/sources.list && apt-get -o Acquire::Check-Valid-Until=false update && apt-get install -y --no-install-recommends git ca-certificates
