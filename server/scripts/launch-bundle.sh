#!/bin/bash

ROUTE=$1
[ -z "$ROUTE" ] && echo "Usage: launch-bundle.sh <bundle-file>" && exit
[ ! -f "$ROUTE" ] && echo "Error: File $ROUTE does not exist" && exit
FILENAME=$(basename $ROUTE)
DEVEL_OPTIONS=""

if docker inspect local-stamp &> /dev/null; then
  LS_IP=$(docker inspect local-stamp|grep -i '"ipaddress"'|sort -r|head -n 1|cut -d\" -f4)
  docker run --rm  -it -v $ROUTE:/tmp/$FILENAME $DEVEL_OPTIONS --entrypoint sh eslap.cloud/local-stamp:1_0_0 -c "cd /eslap/component;./node_modules/.bin/coffee server/scripts/launch-bundle.coffee /tmp/$FILENAME $LS_IP"
else
  echo "Error:local-stamp is not running"
fi