#!/bin/bash
TARGET=$1
REPO=$2
BRANCH = "master"
[ ! -d "$TARGET" ] && mkdir -p "$TARGET"
cd $TARGET

COUNTER=0
while true; do
  [ -f "./node_modules/.bin/coffee" ] && break
  rm -rf *
  git clone -b $BRANCH $REPO .
  COUNTER=$[COUNTER+1]
  echo "npm install... Attempt $COUNTER"
  docker run --rm -v "$TARGET:/eslap/component" --entrypoint bash "eslap.cloud/runtime/native:1_0_1" -c "cd /eslap/component;npm install --production"
done


