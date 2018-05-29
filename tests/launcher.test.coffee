should            = require 'should'
q                 = require 'q'
Component         = require 'component'
srequest          = require 'supertest'
LocalStamp = require '..'

REQUEST_CHANNEL =
  id:'req'
  type:'Request'

REQUEST2_CHANNEL =
  id:'req2'
  type:'Request'

REPLY_CHANNEL =
  id:'reply'
  type:'Reply'

SEND_CHANNEL =
  id:'send'
  type:'Send'

RECEIVE_CHANNEL =
  id:'rcv'
  type:'Receive'

DUPLEX_CHANNEL =
  id: 'dup'
  type: 'Duplex'


TESTED_COMPONENT_CONFIG =
  iid: 'tested'
  incnum: 1
  localData: '/tmp'
  parameters: {}
  role: 'TESTED'
  offerings: [REPLY_CHANNEL, RECEIVE_CHANNEL]
  dependencies: [DUPLEX_CHANNEL]

TESTER_COMPONENT_CONFIG =
  iid: 'tester'
  incnum: 1
  localData: '/tmp'
  parameters: {}
  role: 'TESTER'
  offerings: []
  dependencies: [REQUEST_CHANNEL,
                 SEND_CHANNEL, DUPLEX_CHANNEL]

class ComponentTested extends Component
  constructor: (@runtime, @role, @iid, @incnum, @localData, @resources
  , @parameters, @dependencies, @offerings) ->
    @state = ''

  run: ->
    @running = true
    @offerings.reply.handleRequest = (m)->
      q [['This is my answer',m[0]]]

    @offerings.rcv.on 'message', (m)=>
      @state = m.toString()

    @dependencies.dup.on 'message', (m)=>
      @state = m.toString()
      if @state is 'dynamic'
        if not @dyn?
          @dyn = @runtime.createChannel()
          @dyn.handleRequest = (m)=>
            m = m.toString()
            @state = "Dynamically #{m}"
            q [['Dynamically',m]]
        @dependencies.dup.getMembership()
        .then (mship)=>
          try
            @dependencies.dup.send [' '], mship[0],[@dyn]
          catch e
            console.error e.stack ? e
          console.log "Canal enviado"

  shutdown: ->
    @running = false


class ComponentTester extends Component
  constructor: (@runtime, @role, @iid, @incnum, @localData, @resources
  , @parameters, @dependencies, @offerings) ->
    @dup = @dependencies.dup
  run: ->
    @running = true

  case0: (s)->
    @dependencies.req.sendRequest s
    .then (message)->
      message[0]

  case1: (num1, num2) ->
    @dependencies.req.sendRequest [JSON.stringify {num1:num1,num2:num2}]
    .then (message)->
      message[0]

  case2: (s)->
    @dependencies.send.send [s]

  case3: (s)->
    @dup.getMembership()
    .then (membership)=>
      membership[0].iid.should.be.eql 'tested'
      @dup.send [s], membership[0]

  case4: ()->
    deferred = q.defer()
    @dup.on 'message', (message, channels)->
      # Receive a dynamic channel and use it
      @dyn = channels[0]
      @dyn.sendRequest ['Dynamic']
      .then (m)->
        deferred.resolve m.message.toString()
      .fail (e)->
        console.error e.stack ? e
        deferred.reject e

    @dup.send ['dynamic'], @dup.membership[0]
    deferred.promise

  shutdown: ->
    @running = false

stamp =

setupService = ->

  stamp = new LocalStamp('test')

  stamp.init()
  .then ->
    stamp.launch ComponentTester, TESTER_COMPONENT_CONFIG
  .then ->
    stamp.launch ComponentTested, TESTED_COMPONENT_CONFIG
  .then ->
    stamp.connect 'loadbalancer',
      [{role:'TESTED', endpoint:'reply'}],
      [{role:'TESTER', endpoint:'req'}]

    stamp.connect 'pubsub',
      [{role:'TESTER', endpoint: 'send'}],
      [{role:'TESTED', endpoint: 'rcv'}]

    stamp.connect 'complete',
      [{role:'TESTED', endpoint: 'dup'}],
      [{role:'TESTER', endpoint: 'dup'}]


describe 'Local Stamp - Runtime Launcher', ->

  before (done)->
    @timeout 15 * 1000
    uncaughtL = process.listeners 'uncaughtException'
    setupService()
    .then (result)->
      result.should.be.ok
      process.removeAllListeners 'uncaughtException'
      for l in uncaughtL
        # Este es el listener de mocha
        if l.toString().indexOf('function uncaught(err)') is 0
          process.on 'uncaughtException', l
      setTimeout done, 500
    .fail (e)->
      console.log e.stack
    .done()

  after (done)->
    @timeout 5 * 1000
    stamp.shutdown()
    .then ->
      done()

  it 'Request Hello', (done)->
    stamp.instances['tester'].instance.case0(['Dolly'])
    .then (answer)->
      result = answer[1].toString()
      result.should.be.eql 'This is my answer'
      result = answer[2].toString()
      result.should.be.eql 'Dolly'
      done()
    .done()

  it 'Send Receive', (done)->
    stamp.instances['tester'].instance.case2('Send Modified')
    setTimeout ->
      stamp.instances['tested'].instance.state.should.be.eql 'Send Modified'
      done()
    ,50

  it 'Duplex', (done)->
    stamp.instances['tester'].instance.case3('Duplex Modified')
    .then ->
      setTimeout ->
        stamp.instances['tested'].instance.state.should.be.eql 'Duplex Modified'
        done()
      ,50

  it 'Dynamic', (done)->
    stamp.instances['tester'].instance.case4()
    .then ->
      setTimeout ->
        stamp.instances['tested'].instance.state.should.be.eql \
          'Dynamically Dynamic'
        done()
      ,50