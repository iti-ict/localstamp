#!/bin/bash
version=$(docker images|grep local-stamp| awk '{gsub("_"," ",$2);print $2" "$3}'|sort -k 1rn -k 2rn -k 3rn|head -n 1|cut -d\  -f4)
LS_DOCKER_NAME=eslap.cloud/local-stamp:$(docker images|grep $version|awk '{print $2}')
export LS_DOCKER_NAME

echo "Using image $LS_DOCKER_NAME"
docker run --rm --entrypoint bash -v /tmp:/tmp $LS_DOCKER_NAME -c "cp /eslap/component/server/scripts/_local-stamp-start.sh /tmp"
/tmp/_local-stamp-start.sh $@