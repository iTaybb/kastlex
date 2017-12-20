#!/bin/bash -e

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"

BROD_VSN="$(cat $THIS_DIR/mix.lock | grep -oE ":brod,\s*\"[0-9]\.[0-9]+\.[0-9]+\"" | awk '{print $2}' | tr -d '"')"
BROD_DOWNLOAD_DIR="$THIS_DIR/brod-$BROD_VSN"

if ! [ -d BROD_DOWNLOAD_DIR ]; then
  wget -O brod.zip https://github.com/klarna/brod/archive/$BROD_VSN.zip -o brod.zip
  unzip -qo brod.zip || true
fi
pushd .
cd "$BROD_DOWNLOAD_DIR/docker"

## maybe rebuild
sudo docker-compose -f docker-compose-basic.yml build

## stop everything first
sudo docker-compose -f docker-compose-kafka-1.yml down || true

## start the cluster
sudo docker-compose -f docker-compose-kafka-1.yml up -d

## wait 4 secons for kafka to be ready
n=0
while [ "$(sudo docker exec kafka_1 bash -c '/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --list')" != '' ]; do
  if [ $n -gt 4 ]; then
    echo "timedout waiting for kafka"
    exit 1
  fi
  n=$(( n + 1 ))
  sleep 1
done

## loop
sudo docker exec kafka_1 bash -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --create --partitions 1 --replication-factor 1 --topic kastlex"
sudo docker exec kafka_1 bash -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --create --partitions 1 --replication-factor 1 --topic _kastlex_tokens --config cleanup.policy=compact"
sudo docker exec kafka_1 bash -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper --create --partitions 3 --replication-factor 1 --topic test-topic"
popd

