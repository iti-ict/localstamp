io = require 'socket.io-client'
fs = require 'fs'
child = require 'child_process'


class NginxConfGenerator

  constructor: (@config)->

    @nginx = @config.filename #'/tmp/nginx.conf'
    @PORT = @config.nginxPort
    @serverUrl = "http://localhost:#{@config.admissionPort}"
    conn = io.connect @serverUrl

    # conn.emit = function(){
    #   console.log(JSON.stringify(arguments));
    # };

    # conn.on 'ecloud-event', (evt)->
    #   console.log '==================================='
    #   console.log JSON.stringify(evt, null, 2)

    @config.dashboard = '/etc/nginx/sites-enabled/dashboard.conf'
    if @config.dashboard
      db = fs.createWriteStream @config.dashboard
      db.once 'open', (fd)=>
        db.write "server { \n
         server_name  dashboard.local-stamp.slap53.iti.es;\n
         listen #{@PORT};\n
         location / {\n
            root   /eslap/dashboard;\n
            index  index.html index.htm;\n
          }\n
        }\n"
        db.write "upstream admission {\n
          server 127.0.0.1:#{@config.admissionPort};\n
        }\n"
        db.write "server { \n
          server_name  admission.local-stamp.slap53.iti.es localhost \
                       127.0.0.1 172.17.0.1;\n
          listen #{@PORT};\n
          location / {\n
              proxy_connect_timeout       600s;\n
              proxy_send_timeout          600s;\n
              proxy_read_timeout          600s;\n
              send_timeout                600s;\n
              client_max_body_size 5000M; \n
              proxy_pass         http://admission;\n
              proxy_redirect     off;\n
              proxy_set_header   Host $host;\n
              proxy_set_header   X-Real-IP $remote_addr;\n
              proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;\n
              proxy_set_header   X-Forwarded-Host $server_name;\n
              proxy_http_version 1.1; \n
              proxy_set_header Upgrade $http_upgrade; \n
              proxy_set_header Connection \"Upgrade\";  \n
            } \n
        }\n"
        db.end ->
          child.execSync 'pkill -HUP nginx'


    conn.on 'upstream-event', (evt)=>
      # console.log '============ NGINX ======================'
      # console.log JSON.stringify(evt.data, null, 2)
      # console.log '============ NGINX ======================'
      tmp = "/tmp/nginx-ls.tmp"
      stream = fs.createWriteStream tmp
      counter = 0
      upstreams = {}
      stream.once 'open', (fd)=>
        for domain, servers of evt.data
          counter++
          upstream = "app_servers#{counter}"
          upstreams[upstream] =
            domain: domain
            workers: servers
          stream.write "upstream #{upstream} {\n"
          for s in servers
            stream.write "             server 127.0.0.1:#{s.port};\n"
          stream.write '      }\n'
          stream.write '\n'

        for us, usinfo of upstreams
          stream.write "server {\n
              listen #{@PORT};\n
              server_name #{usinfo.domain} #{usinfo.domain.replace '.','.c-'};\n
              location / {\n
              proxy_pass         http://#{us};\n
              proxy_redirect     off;\n
              proxy_set_header   Host $host;\n
              proxy_set_header   X-Real-IP $remote_addr;\n
              proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;\n
              proxy_set_header   X-Forwarded-Host $server_name;\n
              client_max_body_size 15000M; \n
              proxy_connect_timeout       600s;\n
              proxy_send_timeout          600s;\n
              proxy_read_timeout          600s;\n
              send_timeout                600s;\n
              proxy_http_version 1.1; \n
              proxy_set_header Upgrade $http_upgrade; \n
              proxy_set_header Connection \"Upgrade\";  \n
            }\n
          }\n"
          stream.write '\n'
        stream.end =>
          child.execSync "cp #{tmp} #{@nginx}"
          child.execSync 'pkill -HUP nginx'

module.exports = NginxConfGenerator


###
upstream main1{
  server 172.17.0.4:8000;
}

server {
  listen 8844;
  server_name sumador1.local-stamp.slap53.iti.es;
  location / {
    proxy_pass       http://main1;
    proxy_set_header Host            $host;
    proxy_set_header X-Forwarded-For $remote_addr;
  }
}

upstream main2{
  server 172.17.0.6:8000;
}

server {
  listen 8844;
  server_name sumador2.local-stamp.slap53.iti.es;
  location / {
    proxy_pass       http://main2;
    proxy_set_header Host            $host;
    proxy_set_header X-Forwarded-For $remote_addr;
  }
}

###