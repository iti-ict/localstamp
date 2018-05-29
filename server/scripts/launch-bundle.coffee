q = require 'q'
supertest = require 'supertest'
fs = require 'fs'
admissionPort=8090

path=process.argv[2]
ip=process.argv[3]

if not path?
  console.log 'You must provide a file as second parameter'
  process.exit 0

if not ip?
  console.log 'You must provide a ip as third parameter'
  process.exit 0

admRest = supertest "http://#{ip}:#{admissionPort}/admission"

fileExists =(filePath)->
  try
    fs.statSync(filePath).isFile()
  catch err
    false

if not fileExists path
  console.log "File #{path} does not exist"
  process.exit 1


admRest.post '/bundles'
.attach 'bundlesZip', path
.end (err, res)->
  if err?
    console.log err.message ? err
    process.exit 1
  if res.status != 200
    console.error JSON.stringify res, null, 2
    process.exit 1

  if res.text?
    res = JSON.parse res.text
    res = res.data
    console.log JSON.stringify res, null, 2
  else
    console.log JSON.stringify res


