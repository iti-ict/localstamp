#/bin/sh
[ -z "$SLAP_GIT_BRANCH" ] && SLAP_GIT_BRANCH="master"
[ -z "$SLAP_GIT_REPOSITORY" ] && SLAP_GIT_REPOSITORY="ECloud"
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
[ -z "$H" ] && H=$PWD/../..
[ -z "$GIT" ] && GIT=$H/functional-tests/egit-clone
[ -z "$SAVE_IMAGES" ] && SAVE_IMAGES=true

export TTY=""
if tty -s; then
   export TTY="-it"
fi
cd $DIR
# check requirements
REQS=( jq git docker wget )

for REQ in ${REQS[@]}
do
  which ${REQ} >/dev/null
  if [ ! $? -eq 0 ]; then
    echo "requirement ${REQ} is missing"
    exit 1
  fi
done

[ -d build ] && docker run --rm --entrypoint="bash" -v $PWD:/tmp/folder eslap.cloud/runtime/native/dev/privileged:2_0_0 -c "rm -rf /tmp/folder/build"
mkdir build
[ -f image.tgz ] && rm image.tgz
if [ -z "$tag" ]; then
  tag=`jq -r .tag < tag2LayerIdMapping.json`
fi
echo "Tag: $tag"
NPMINSTALL="cd /build; while [ ! -f node_modules/.bin/coffee ]; do ([ -d node_modules ] && rm -rf node_modules); npm install --production; done"

[ -d provision ] && rm -rf provision
cp -R ../provision build

cd build


[ -d local-stamp ] && rm -rf local-stamp
$GIT local-stamp ${SLAP_GIT_BRANCH} ${SLAP_GIT_REPOSITORY}
cd local-stamp
docker run $TTY --rm -v `pwd`:/build --entrypoint /bin/sh eslap.cloud/runtime/native/dev/privileged:2_0_0  -c "$NPMINSTALL"
rm -rf tests funcional-tests server/image server/provision server/scripts/launch*
cd ..

[ -d runtime-agent ] && rm -rf runtime-agent
[ -d runtime-agent1 ] && rm -rf runtime-agent1
$GIT runtime-agent ${SLAP_GIT_BRANCH} ${SLAP_GIT_REPOSITORY}
cd runtime-agent
docker run $TTY --rm -v `pwd`:/build --entrypoint /bin/sh eslap.cloud/runtime/native/dev/privileged:1_0_1  -c "$NPMINSTALL"
tar --exclude-vcs -czf ../runtime-agent-1_0_0.tgz .
cd ..
mv runtime-agent runtime-agent1

[ -d runtime-agent ] && rm -rf runtime-agent
$GIT runtime-agent ${SLAP_GIT_BRANCH} ${SLAP_GIT_REPOSITORY}
cd runtime-agent
docker run $TTY --rm -v `pwd`:/build --entrypoint /bin/sh eslap.cloud/runtime/native/dev/privileged:2_0_0  -c "$NPMINSTALL"
tar --exclude-vcs -czf ../runtime-agent-2_0_0.tgz .
cd ..

[ -d gateway-component ] && rm -rf gateway-component
$GIT gateway-component ${SLAP_GIT_BRANCH} ${SLAP_GIT_REPOSITORY}
cd gateway-component
docker run $TTY --rm -v `pwd`:/build --entrypoint /bin/sh eslap.cloud/runtime/native/dev/privileged:1_0_1  -c "$NPMINSTALL"
tar --exclude-vcs -czf ../gateway-agent-1_0_0.tgz .
cd ..

[ -d dashboard ] && rm -rf dashboard
$GIT dashboard ticket1174 ${SLAP_GIT_REPOSITORY}
cd dashboard
echo 'export let ACS_URI = "http://localhost:8090/acs";' > src/api/config.js
echo 'export let ADMISSION_URI = "http://localhost:8090/admission";' >> src/api/config.js
echo 'export let PORT = 8090;' >> src/api/config.js
docker run $TTY --rm -v `pwd`:/dashboard --entrypoint /bin/sh eslap.cloud/runtime/native/dev/privileged:2_0_0 -c "\
  cd /dashboard;\
  npm install;\
  npm run build"
cd ..


[ -d slap-images ] && rm -rf slap-images
$GIT slap-images ${SLAP_GIT_BRANCH} ${SLAP_GIT_REPOSITORY}
ECLOUD_KEY=slap-images/ubuntu-cluster-controller/provision/deploymentKey/ecloud_deployment_key
chmod 400 $ECLOUD_KEY

[ -d http-sep ] && rm -rf http-sep
$GIT http-sep ${SLAP_GIT_BRANCH} ${SLAP_GIT_REPOSITORY}

[ -d manifest-storage ] && rm -rf manifest-storage
[ -d image-storage ] && rm -rf image-storage
mkdir manifest-storage
mkdir image-storage

cd manifest-storage
TARGET=$PWD/eslap.cloud
rsync -a  --exclude '*tgz' --exclude '*.tgz.*' -e " ssh -i ../$ECLOUD_KEY" ubuntu@ecloud.iti.upv.es:repo/eslap.cloud/runtime $TARGET
for i in privileged ecloudPublicKey mariadb; do
  find $TARGET|grep $i|xargs rm -rf
done
find $TARGET -type f|grep -v Manifest.json$|xargs rm
for i in $(find $TARGET -type f); do
  t=$(echo $i |sed 's/Manifest/manifest/g')
  mv $i $t
done
mkdir -p $TARGET/services/http/inbound/1_0_0
cp ../http-sep/manifests/http_inbound_service_manifest.json $TARGET/services/http/inbound/1_0_0/manifest.json
mkdir -p $PWD/slapdomain/components/httpsep/0_0_1
cp ../http-sep/manifests/manifest.json $PWD/slapdomain/components/httpsep/0_0_1/manifest.json
mkdir -p $PWD/slapdomain/runtimes/managed/nodejs/0_0_1
echo '{"spec": "http://eslap.cloud/manifest/runtime/1_0_0", "name": "slap://slapdomain/runtimes/managed/nodejs/0_0_1"}' > $PWD/slapdomain/runtimes/managed/nodejs/0_0_1/manifest.json
mkdir -p $PWD/slapdomain/runtimes/managed/privileged/nodejs/0_0_1
echo '{"spec": "http://eslap.cloud/manifest/runtime/1_0_0", "name": "slap://slapdomain/runtimes/managed/privileged/nodejs/0_0_1"}' > $PWD/slapdomain/runtimes/managed/privileged/nodejs/0_0_1/manifest.json

cd ../image-storage
TARGET=$PWD/eslap.cloud
mkdir -p $TARGET/runtime-agent/1_0_0
cp ../runtime-agent-1_0_0.tgz $TARGET/runtime-agent/1_0_0/image.tgz
mkdir -p $TARGET/runtime-agent/2_0_0
cp ../runtime-agent-2_0_0.tgz $TARGET/runtime-agent/2_0_0/image.tgz
mkdir -p $TARGET/gateway-agent/1_0_0
cp ../gateway-agent-1_0_0.tgz $TARGET/gateway-agent/1_0_0/image.tgz
cd ..

cd ..
docker build -t $tag .

if [ "$SAVE_IMAGES" == "true" ]; then
  echo "Generating image.tgz..."
  docker save $tag | xz -8 -T 0 > image.tgz
fi
# rm -rf build
