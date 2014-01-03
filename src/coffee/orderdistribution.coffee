_ = require('underscore')._
Rest = require('sphere-node-connect').Rest
InventoryUpdater = require('sphere-node-sync').InventoryUpdater
ProgressBar = require 'progress'
logentries = require 'node-logentries'
Q = require 'q'

class OrderDistribution
  constructor: (@options = {}) ->
    throw new Error 'No master configuration in options!' if not @options.master
    throw new Error 'No master configuration in options!' if not @options.retailer
    @masterRest = new Rest config: @options.master
    @retailerRest = new Rest config: @options.retailer
    @log = logentries.logger token: @options.logentries.token if @options.logentries
    @inventoryUpdater = new InventoryUpdater config: @options.master

  elasticio: (msg, cfg, cb, snapshot) ->
    if msg.body
      masterOrders = msg.body.results
      @run(masterOrders, cb)
    else
      @returnResult false, 'No data found in elastic.io msg!', cb

  getUnexportedOrders: (rest, offsetInDays) ->
    deferred = Q.defer()
    date = new Date()
    offsetInDays = 7 if offsetInDays is undefined
    date.setDate(date.getDate() - offsetInDays)
    d = "#{date.toISOString().substring(0,10)}T00:00:00.000Z"
    query = encodeURIComponent "createdAt > \"#{d}\""
    rest.GET "/orders?limit=0&where=#{query}", (error, response, body) ->
      if error
        deferred.reject "Error on fetching orders: " + error
      else if response.statusCode != 200
        deferred.reject "Problem on fetching orders (status: #{response.statusCode}): " + body
      else
        orders = JSON.parse(body).results
        unexportedOrders = _.filter orders, (o) ->
          _.size(o.exportInfo) == 0
        deferred.resolve unexportedOrders
    deferred.promise

  getRetailerProductByMasterSKU: (sku) ->
    deferred = Q.defer()
    query = encodeURIComponent "variant.attributes.mastersku:\"#{sku}\""
    @retailerRest.GET "/product-projections/search?lang=de&filter=#{query}", (error, response, body) ->
      if error
        deferred.reject "Error on fetching products: " + error
      else if response.statusCode != 200
        deferred.reject "Problem on fetching products (status: #{response.statusCode}): " + body
      else
        orders = JSON.parse(body).results
        deferred.resolve orders
    deferred.promise

  run: (masterOrders, callback) ->
    throw new Error 'Callback must be a function!' unless _.isFunction callback
    if _.size(masterOrders) is 0
      @returnResult true, 'Nothing to do.', callback
      return
    if @options.showProgress
      @bar = new ProgressBar 'Distributing orders [:bar] :current/:total (:percent) done', { width: 80, total: _.size(masterOrders) }

    for order in masterOrders
      unless @validateSameChannel order
        msg = "The order '#{order.id}' has different channels set!"
        @log.alert(msg) if @log
        @returnResult false, msg, callback
        return

    distributions = []
    for order in masterOrders
      distributions.push @distribute (order)

    Q.all(distributions).then (msg) =>
      if _.size(msg) is 1
        msg = msg[0]
      @returnResult true, msg, callback
    .fail (msg) =>
      @returnResult false, msg, callback

  distribute: (masterOrder) ->
    deferred = Q.defer()
    masterSKUs = @extractSKUs masterOrder
    gets = []
    for s in masterSKUs
      gets.push @getRetailerProductByMasterSKU(s)
    Q.all(gets).then (retailerProducts) =>
      masterSKU2retailerSKU = @matchSKUs(_.flatten(retailerProducts), masterSKUs)
      unless @ensureAllSKUs(masterSKUs, masterSKU2retailerSKU)
        msg = 'Some of the SKUs in the master order can not be translated to retailer SKUs!'
        @log.alert(msg)
        deferred.reject msg
        return deferred.promise

      retailerOrder = @replaceSKUs(masterOrder, masterSKU2retailerSKU)
      retailerOrder = @removeChannels(retailerOrder)
      @importOrder(retailerOrder).then (newOrder) =>
        @inventoryUpdater.ensureChannelByKey(@masterRest, @retailerRest._options.config.project_key).then (channel) =>
          @addExportInfo(masterOrder.id, masterOrder.version, channel.id, newOrder.id).then (msg) ->
            deferred.resolve msg
          .fail (msg) ->
            deferred.reject msg
        .fail (msg) ->
          deferred.reject msg
      .fail (msg) ->
        deferred.reject msg
    .fail (msg) ->
      deferred.reject msg

    deferred.promise

  matchSKUs: (products) ->
    masterSKU2retailerSKU = {}
    for product in products
      _.extend masterSKU2retailerSKU, @matchVariantSKU(product.masterVariant)
      continue unless product.variants
      for v in product.variants
        _.extend masterSKU2retailerSKU, @matchVariantSKU(v)
    masterSKU2retailerSKU

  matchVariantSKU: (variant) ->
    ret = {}
    for a in variant.attributes
      continue unless a.name is 'mastersku'
      ret[a.value] = variant.sku
      break
    return ret

  ensureAllSKUs: (masterSKUs, masterSKU2retailerSKU) ->
    difference = _.filter masterSKUs, (sku) ->
      sku unless masterSKU2retailerSKU[sku]

  addExportInfo: (orderId, orderVersion, retailerId, retailerOrderId) ->
    deferred = Q.defer()
    data =
      version: orderVersion
      actions: [
        action: 'updateExportInfo'
        channel:
          typeId: 'channel'
          id: retailerId
        externalId: retailerOrderId
      ]
    @masterRest.POST "/orders/#{orderId}", JSON.stringify(data), (error, response, body) ->
      if error
        deferred.reject "Error on setting export info: " + error
      else if response.statusCode != 200
        deferred.reject "Problem on setting export info (status: #{response.statusCode}): " + body
      else
        deferred.resolve "Order exportInfo successfully stored."
    deferred.promise

  importOrder: (order) ->
    deferred = Q.defer()
    @retailerRest.POST "/orders/import", JSON.stringify(order), (error, response, body) ->
      if error
        deferred.reject "Error on importing order: " + error
      else if response.statusCode != 201
        deferred.reject "Problem on importing order (status: #{response.statusCode}): " + body
      else
        res = JSON.parse(body)
        deferred.resolve res
    deferred.promise

  returnResult: (positiveFeedback, msg, callback) ->
    if @options.showProgress and @bar
      @bar.terminate()
    d =
      component: this.constructor.name
      status: positiveFeedback
      msg: msg
    if @log
      logLevel = if positiveFeedback then 'info' else 'err'
      @log.log logLevel, d
    callback d

  validateSameChannel: (order) ->
    channelID = null
    checkChannelId = (channel) ->
      if channelID is null
        channelID = channel.id
        return true
      return channelID is channel.id
    if order.lineItems
      for li in order.lineItems
        if li.channel
          return false unless checkChannelId li.channel
        continue unless li.variant
        continue unless li.variant.prices
        for p in li.variant.prices
          if p.channel
            return false unless checkChannelId p.channel
    true

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