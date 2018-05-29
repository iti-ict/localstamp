q                 = require 'q'

ra = require('runtime-agent')
RuntimeAgent      = ra.RuntimeAgent
DynamicRequest    = ra.DynamicRequest
DynamicReply      = ra.DynamicReply
Request           = ra.Request
Reply             = ra.Reply
klogger         = require 'k-logger'
Component         = require 'component'

parser = klogger.getDefaultParser()

WAIT_TIME = 2000

class ComponentLauncher

  constructor: (@ls)->
    @socketCounter = 0
    @router = @ls.routerAgent
    @logger = @ls.logger
    @rtlogger = klogger.getLogger RuntimeAgent

  launch: (ComponentClass, componentConfig, deployment)->
    deferred = q.defer()
    [promiseSocket, promiseStarted] = \
      @router.setupInstance componentConfig, deployment, @ls.configLogger
    promiseSocket.then (data)=>
      [control, dealer, instanceFolder, socketFolder, tmpFolder] = data
      runtime = new RuntimeAgent(@rtlogger)
      setTimeout ->
        runtime.run \
          control.socket.uri,
          dealer.uri,
          -> ComponentClass,
          tmpFolder
      , 200

      promiseStarted.then ->
        setTimeout ->
          deferred.resolve
            runtime: runtime
            instance: runtime.instance
            dealer: dealer
            control: control
        , 1000

    deferred.promise


module.exports = ComponentLauncher
