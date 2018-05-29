class Segments
  constructor: (args)->
    @b = Array.prototype.slice.call(args)
    @length = @b.length
  str: (idx)->
    @b[idx].toString()

  obj: (idx)->
    JSON.parse(@b[idx])

  log: (verbose)->
    return if not verbose
    message = {}
    headerPrefix='header'
    for i in [0..@length-1]
      try
        message["#{headerPrefix}-#{i}"] = @obj(i)
      catch e
        headerPrefix = 'bodyObject'
        message["body-#{i}"] = @str(i)
    console.log "Node Component says: #{JSON.stringify message, null,2}"

module.exports.Segments = Segments