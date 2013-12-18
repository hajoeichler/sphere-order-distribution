_ = require('underscore')._
Rest = require('sphere-node-connect').Rest
ProgressBar = require 'progress'
logentries = require 'node-logentries'
Q = require 'q'

class OrderDistribution
  constructor: (@options) ->
    throw new Error 'No configuration in options!' if not @options or not @options.config
    @log = logentries.logger token: @options.logentries.token if @options.logentries

  elasticio: (msg, cfg, cb, snapshot) ->
    if msg.body
      masterOrders = msg.body.results
      @run(masterOrders, cb)
    else
      @returnResult false, 'No data found in elastic.io msg!', cb

  getOrders: (rest) ->
    deferred = Q.defer()
    rest.GET "/orders?limit=0", (error, response, body) ->
      if error
        deferred.reject "Error on fetching orders: " + error
      else if response.statusCode != 200
        deferred.reject "Problem on fetching orders (status: #{response.statusCode}): " + body
      else
        orders = JSON.parse(body).results
        deferred.resolve orders
    deferred.promise

  run: (masterOrders, callback) ->
    throw new Error 'Callback must be a function!' unless _.isFunction callback
    @returnResult true, 'Nothing to do.', callback

  returnResult: (positiveFeedback, msg, callback) ->
    if @options.showProgress
      @bar.terminate()
    d =
      component: this.constructor.name
      status: positiveFeedback
      msg: msg
    if @log
      logLevel = if positiveFeedback then 'info' else 'err'
      @log.log logLevel, d
    callback d

module.exports = OrderDistribution