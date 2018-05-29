sio = require 'socket.io'
klogger = require 'k-logger'
moment = require 'moment'
events = sys = require 'events'

EMITTED_EVENTS_NAME = 'ecloud-event'
AUTHENTICATION_ERROR = 'Authentication error'


class WebsocketPublisher

  constructor: (@httpServer, @httpAuthenticator) ->
    @logger = klogger.getLogger 'Websocket'
    # @logger.debug = console.log
    # @logger.info = console.log
    # @logger.error = console.log
    # @logger.warn = console.log
    @logger.info 'WebsocketPublisher.constructor'

    # Setup a Socket.io websocket to listen on the server
    @socketIO = sio.listen @httpServer

    # Configure Websocket handshake for authentication
    @socketIO.use (socket, next) =>
      @sioHandshaker socket, next

    @socketIO.on 'connection', (socket) =>
      @sioConnectionHandler socket

    @evtInstanceBuffer = {}
    @deployed = {}
    @instanceCreated = {}
    @socketsByUserId = {}
    @local = new events.EventEmitter()


  sioHandshaker: (socket, next) ->
    meth = 'WSPublisher.handshake'
    # authHeader = socket?.request?.headers?.authorization
    # if not authHeader?
    #   @logger.info "#{meth} - Access denied for anonymous request."
    #   return next new Error AUTHENTICATION_ERROR
    # [protocol, basic] = authHeader.split ' '
    # if protocol isnt 'Basic'
    #   @logger.info "#{meth} - Access denied for incorrect protocol \
    #     #{protocol} request."
    #   return next new Error AUTHENTICATION_ERROR
    # buf = new Buffer(basic, 'base64')
    # plain_auth = buf.toString()
    # creds = plain_auth.split(':')
    # authToken = "Bearer #{creds[0]}"
    authToken = socket?.handshake?.query?.token
    @logger.info "#{meth}"
    socket.user = {id:'local-stamp'}
    next()
    # if (not authToken?) or (authToken is '')
    #   @logger.info "#{meth} - Access denied for anonymous request."
    # @httpAuthenticator.authenticate "Bearer #{authToken}"
    # .then (userData) =>
    #   socket.user = userData
    #   @logger.info "#{meth} - User authenticated: #{JSON.stringify userData}"
    #   next()
    # .fail (err) =>
    #   @logger.info "#{meth} - Access denied for token #{authToken}."
    #   next new Error AUTHENTICATION_ERROR


  sioConnectionHandler: (socket) ->
    meth = 'WSPublisher.onConnection'
    if not socket.user?
      @logger.error "#{meth} - Socket not authenticated correctly."
      socket.emit 'error'
      ,'Connection not authenticated correctly. Disconnecting.'
      socket.disconnect()
    else
      @logger.info "#{meth} - Socket #{socket.id} connected. User: " +
        "#{JSON.stringify socket.user}"
      @addUserSocket socket
      @configureSocketHandlers socket


  configureSocketHandlers: (socket) ->

    socket.on 'disconnect', (reason) =>
      @socketDisconnectionHandler socket, reason

    socket.on 'error', (error) =>
      @socketErrorHandler socket, error


  socketDisconnectionHandler: (socket, reason) ->
    meth = 'WSPublisher.onSocketDisconnection'
    @logger.info "#{meth} - Socket #{socket.id} - Reason: #{reason}"
    @removeUserSocket socket


  socketErrorHandler: (socket, error) ->
    @logger.info "WSPublisher.onSocketError - User: #{socket.user.id} - " +
      "Error: #{error.message}"


  # Add a socket to the user socket list if it's not already there.
  #
  # The user socket list is a two-level dictionary, by user ID and socket ID:
  # {
  #   "user1": {
  #     "sock1" : socketObj1,
  #     "sock2" : socketObj2,
  #     "sock3" : socketObj3
  #   },
  #   "user2": {
  #     "sock5" : socketObj5,
  #     "sock23" : socketObj23,
  #     "sock12" : socketObj12
  #   }
  # }
  addUserSocket: (socket) ->
    meth = 'WebsocketPublisher.addUserSocket'
    userId = socket.user.id
    if userId not of @socketsByUserId
      @socketsByUserId[userId] = {}
    if socket.id not of @socketsByUserId[userId]
      @socketsByUserId[userId][socket.id] = socket
      @logger.debug "#{meth} - Socket #{socket.id} added to #{userId} list."
    else
      @logger.debug "#{meth} - Socket #{socket.id} already in #{userId} list."


  # Removes a socket from the user socket list.
  removeUserSocket: (socket) ->
    meth = 'WebsocketPublisher.removeUserSocket'
    userId = socket.user.id
    if userId of @socketsByUserId
      if socket.id of @socketsByUserId[userId]
        delete @socketsByUserId[userId][socket.id]
        @logger.debug "#{meth} - Removed #{socket.id} from #{userId} list."
        if Object.keys(@socketsByUserId[userId]).length is 0
          delete @socketsByUserId[userId]
          @logger.debug "#{meth} - Removed #{userId} from list."
      else
        @logger.debug "#{meth} - Socket #{socket.id} not in #{userId} list."
    else
      @logger.debug "#{meth} - User #{userId} not in socket list."


  publish: (evt) ->
    meth = 'WebsocketPublisher.publish'
    evtStr = JSON.stringify evt
    if not evt.owner?
      @logger.debug "#{meth} - Event data has no owner: #{evtStr}"
    else if evt.owner not of @socketsByUserId
      @logger.debug "#{meth} - Event owner has no active sockets: #{evtStr}"
    else
      @logger.debug "#{meth} - Emitting event to client sockets: #{evtStr}"
      for sid, s of @socketsByUserId[evt.owner]
        @logger.debug "#{meth} - Emitting event to socket #{sid}: #{evtStr}"
        try
          s.emit EMITTED_EVENTS_NAME, evt
        catch err
          @logger.warn "#{meth} - Error emitting: #{err.message} - #{evtStr}"
      @local.emit 'event', evt

  directPublish: (type, evt) ->
    for sid, s of @socketsByUserId['local-stamp']
      s.emit type, evt

  publishEvt: (type, name, data) ->
    meth = 'WebsocketPublisher.publishEvt'
    publish = true
    evt =
      timestamp: _getTimeStamp()
      type: type
      name: name
      owner: 'local-stamp'
    if type is 'instance'
      publish = false
      if name is 'status'
        evt.data = {status: data.status}
        evt.entity =
          serviceApp: data.service
          service: data.deployment
          role: data.role
          instance: data.instance
        @evtInstanceBuffer[data.instance] = evt
      else if name is 'created'
        @instanceCreated[data.instance] = true
      else if name is 'removed'
        if @instanceCreated[data.instance]?
          delete @instanceCreated[data.instance]
    else if type is 'service'
      if name is 'deploying' or name is 'undeploying'
        evt.entity =
          serviceApp: data.service
          service: data.deployment
      else if name is 'deployed' or name is 'undeployed'
        deployment = data.deployment
        evt.entity =
          serviceApp: deployment.service
          service: data.deploymentURN
        evt.data =
          instances: {}
        for r, rinfo of deployment.roles
          for i, iinfo of rinfo.instances
            instance = {}
            instance.component = rinfo.component
            instance.role = r
            instance.cnid = iinfo.id
            evt.data.instances[i] = instance
        if name is 'deployed'
          @deployed[evt.entity.service] = true
        else if name is 'undeployed'
          delete @deployed[evt.entity.service]
      else if name is 'link' or name is 'unlink'
        deployment = data.deployment
        evt.entity =
          serviceApp: deployment.service
          service: data.deploymentURN
        evt.data = data.linkData
      else if name is 'scale'
        deployment = data.manifest
        evt.entity =
          serviceApp: deployment.service.name
          service: deployment.name
        evt.data = data.event

    if publish
      @publish evt
    else
      if name isnt 'status'
        @local.emit 'event', evt

    for iid, evt of @evtInstanceBuffer
      if (@instanceCreated[iid] and @deployed[evt.entity.service]) or
      (evt.entity.serviceApp is
      'eslap://eslap.cloud/services/http/inbound/1_0_0')
        @publish evt
        delete @evtInstanceBuffer[iid]

  reconfigure: ->
    @logger.info 'WebsocketPublisher.reconfigure'
    # TODO

  disconnect: ->
    @logger.info 'WebsocketPublisher.disconnect'

  terminate: ->
    @logger.info 'WebsocketPublisher.terminate'

_getTimeStamp = () ->
  now = new Date().getTime()
  return moment.utc(now).format('YYYYMMDDTHHmmssZ')


module.exports = WebsocketPublisher
