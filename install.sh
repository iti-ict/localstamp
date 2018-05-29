#!/bin/bash
SUPPORTED_DOCKER="1.10.3"
IMAGE_REPO="http://ecloud.iti.upv.es:8080"
declare -a IMAGES=(
  "eslap.cloud/runtime/native/1_0_1"
  "eslap.cloud/runtime/native/1_1_1"
  "eslap.cloud/runtime/java/1_0_1"
  "eslap.cloud/runtime/java/dev/1_0_1"
  "eslap.cloud/elk/1_0_0"
)
BASE=$PWD
LOGFILE=$BASE/localstamp-installation.log
TOOL_DIR=$(dirname $(readlink -f $0))
TOOL_IMAGE_DOCKER=$(echo $TOOL_IMAGE|sed 's/\(.*\)\//\1:/')

echo "Creating installation log file in $LOGFILE"
[ -f $LOGFILE ] && rm $LOGFILE
touch $LOGFILE

echo "#### misc apt-get install"  >> $LOGFILE
sudo apt-get install -y curl jq  >> $LOGFILE

## Installing Docker
DOCKER_FRESH="false"
if docker --version >/dev/null 2>&1; then
  DOCKER_VERSION=$(docker --version|cut -f1 -d","|cut -f3 -d" ")
  if [ "$DOCKER_VERSION" == "$SUPPORTED_DOCKER" ]; then
    echo "Docker installed with recommended version"
  else
    echo "Docker installed with version $DOCKER_VERSION. The recommended version is $SUPPORTED_DOCKER. Your version is not officially supported."
  fi
else
  echo "Installing docker..."
  echo "#### docker" >> $LOGFILE
  sudo apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D >> $LOGFILE
  sudo mkdir -p /etc/apt/sources.list.d
  sudo sh -c 'echo "deb https://apt.dockerproject.org/repo ubuntu-trusty main" > /etc/apt/sources.list.d/docker.list'
  sudo apt-get update >> $LOGFILE
  sudo apt-get install -y docker-engine=1.10.3-0~trusty >> $LOGFILE
  sudo usermod -a -G docker $USER
  DOCKER_FRESH="true"
fi


# Finding latest local-stamp version
latestLS=$(wget -q -O- http://ecloud.iti.upv.es:8080/eslap.cloud/local-stamp/latest)
latestPath=$(echo $latestLS|sed 's/\(.*\):/\1\//')
IMAGES=($latestPath "${IMAGES[@]}")

# Installing docker-images

echo "Installing docker images..."
echo "#### docker images"  >> $LOGFILE

for i in "${IMAGES[@]}"; do
  d=$(echo $i|sed 's/\(.*\)\//\1:/')
  if [ $(sudo su $USER -c "docker images $d" | wc -l) == "2" ]; then
    echo "Image $d already installed"
    continue
  fi
  echo -n "Downloading image $d..."
  [ -f image.tgz ] && rm image.tgz
  wget -q $IMAGE_REPO/$i/image.tgz
  echo done
  echo -n "Installing - this can take several minutes... "

  echo "## image eslap://$i"  >> $LOGFILE
  sudo su $USER -c "docker load -i image.tgz"
  [ -f image.tgz ] && rm image.tgz

  if [ $(sudo su $USER -c "docker images $d" | wc -l) != "2" ]; then
    echo "Error: Image $d not installed"
    exit 1
  fi
   echo "done"
done
echo  "All images installed"

echo "All dependencies installed"

echo "Installing local-stamp launcher script"

sudo mkdir -p /usr/local/bin
sudo tee /usr/local/bin/local-stamp.sh > /dev/null << 'EOT'
#!/bin/bash
version=$(docker images|grep local-stamp| awk '{gsub("_"," ",$2);print $2" "$3}'|sort -k 1rn -k 2rn -k 3rn|head -n 1|cut -d\  -f4)
LS_DOCKER_NAME=eslap.cloud/local-stamp:$(docker images|grep $version|awk '{print $2}')
export LS_DOCKER_NAME

echo "Using image $LS_DOCKER_NAME"
docker run --rm --entrypoint bash -v /tmp:/tmp $LS_DOCKER_NAME -c "cp /eslap/component/server/scripts/_local-stamp-start.sh /tmp"
/tmp/_local-stamp-start.sh $@
EOT
sudo chmod +x /usr/local/bin/local-stamp.sh

[ "$DOCKER_FRESH" == "true" ] && echo  "You must relog into the system"

echo "local-stamp.sh command is now available"
