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

  getUnexportedOrders: (rest) ->
    deferred = Q.defer()
    query = encode "exportInfo.size = 0"
    rest.GET "/orders?limit=0?where=#{query}", (error, response, body) ->
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
    # workflow:
    # filter orders that do not fit the retailer channel key
    # each order
    #   get all SKUs from lineitems
    #   get all products for the SKUs (in attribute masterSKU) from retailer project
    #   exchange all SKUs in oder
    #   remove channel information in order
    #   import order into retailer and get order id
    #   add export info to corresponding order in master
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

  extractSKUs: (order) ->
    skus = []
    if order.lineItems
      for li in order.lineItems
        continue unless li.variant
        continue unless li.variant.sku
        skus.push li.variant.sku
    skus

  replaceSKUs: (order, masterSKU2retailerSKU) ->
    if order.lineItems
      for li in order.lineItems
        continue unless li.variant
        continue unless li.variant.sku
        masterSKU = li.variant.sku
        retailerSKU = masterSKU2retailerSKU[masterSKU]
        continue unless retailerSKU
        li.variant.sku = retailerSKU
        li.variant.attributes = [] unless li.variant.attributes
        a =
          name: 'mastersku'
          value: masterSKU
        li.variant.attributes.push a
    order

  removeChannels: (order) ->
    if order.lineItems
      for li in order.lineItems
        if li.channel
          delete li.channel
        continue unless li.variant
        continue unless li.variant.prices
        for p in li.variant.prices
          if p.channel
            delete p.channel
    order

module.exports = OrderDistribution