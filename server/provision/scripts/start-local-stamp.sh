#!/bin/bash

FOLDER=/eslap/component/
cd $FOLDER
export DOCKER_API_VERSION=1.22

/etc/init.d/nginx start > /dev/null

node_modules/.bin/coffee $FOLDER/scripts/local-stamp-launcher.coffee

