FROM eslap.cloud/runtime/native:2_0_0

# Install required software and libraries (node.js & ZMQ)

#RUN apt-get update -qq && \
#    apt-get install -y docker.io && \
#    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D && \
  mkdir -p /etc/apt/sources.list.d && \
  sh -c 'echo "deb http://apt.dockerproject.org/repo ubuntu-xenial main" > /etc/apt/sources.list.d/docker.list' && \
  apt-get update -qq && \
  apt-get install -y docker-engine=1.11.0-0~xenial netcat nginx jq vim && \
  usermod -a -G docker root && \
  rm /etc/nginx/sites-available/default && \
  rm /etc/nginx/sites-enabled/default && \
  mkdir -p eslap/manifest-storage/local && \
  mkdir -p eslap/image-storage/local && \
  apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY build/local-stamp /eslap/component
COPY build/provision/scripts /eslap/component/scripts
COPY build/dashboard/dist /eslap/dashboard
COPY build/provision/config /eslap/component/config
COPY build/manifest-storage /eslap/manifest-storage/remote
COPY build/image-storage /eslap/image-storage/remote
ENTRYPOINT ["/eslap/component/scripts/start-local-stamp.sh"]

