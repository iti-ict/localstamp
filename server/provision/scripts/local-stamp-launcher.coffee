q = require 'q'

LocalStamp = require('../src')

configPath = "#{__dirname}/local-stamp.json"
admissionPort = 27119
nginxPort = 8090
config = null
try
  config = require configPath
  console.log "Using config: #{JSON.stringify config, null, 2}"
catch e
  console.error 'There were errors processing local stamp configuration file'
  process.exit 1
config.admissionPort = admissionPort
# Load the instance component class
stamp = new LocalStamp('local-stamp', config)

stamp.init()
.then ->
  console.log 'Local Stamp Started'
  console.log "Listening on port #{nginxPort}"
  console.log "Dashboard available on http://dashboard.local-stamp.slap53.iti.es:#{nginxPort}"
  console.log "(No authentication needed. Simply click on Continue button)"
  console.log "Admission available on http://localhost:#{nginxPort}/admission"
  console.log ''
.fail (e) ->
  console.log "Error launching Local Stamp #{e.message ? e.stack ? e}"


# Launching nginx connector
NginxC = require '../src/nginx-conf-generator'
nginxc = new NginxC {
  filename:'/etc/nginx/sites-enabled/local-stamp.conf',
  serverUrl: "http://localhost:#{nginxPort}"
  admissionPort: admissionPort
  nginxPort: nginxPort
}

process.on 'SIGINT', ->
  console.log ''
  console.log 'Shutting down Local Stamp'
  stamp.shutdown()
  .then ->
    process.exit 0