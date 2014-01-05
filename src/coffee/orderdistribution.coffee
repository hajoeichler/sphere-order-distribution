_ = require('underscore')._
Rest = require('sphere-node-connect').Rest
CommonUpdater = require('sphere-node-sync').CommonUpdater
InventoryUpdater = require('sphere-node-sync').InventoryUpdater
Q = require 'q'

class OrderDistribution extends CommonUpdater
  constructor: (options = {}) ->
    super(options)
    throw new Error 'No master configuration in options!' unless options.master
    throw new Error 'No master configuration in options!' unless options.retailer
    @masterRest = new Rest config: options.master
    @retailerRest = new Rest config: options.retailer
    @inventoryUpdater = new InventoryUpdater config: options.master

  elasticio: (msg, cfg, cb, snapshot) ->
    if msg.body
      masterOrders = msg.body.results
      @run masterOrders, cb
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
      else if response.statusCode isnt 200
        deferred.reject "Problem on fetching orders (status: #{response.statusCode}): " + body
      else
        orders = JSON.parse(body).results
        unexportedOrders = _.filter orders, (o) ->
          _.size(o.exportInfo) is 0
        deferred.resolve unexportedOrders
    deferred.promise

  getRetailerProductByMasterSKU: (sku) ->
    deferred = Q.defer()
    query = encodeURIComponent "variants.attributes.mastersku:\"#{sku.toLowerCase()}\""
    @retailerRest.GET "/product-projections/search?lang=de&filter=#{query}", (error, response, body) ->
      if error
        deferred.reject "Error on fetching products: " + error
      else if response.statusCode isnt 200
        deferred.reject "Problem on fetching products (status: #{response.statusCode}): " + body
      else
        products = JSON.parse(body).results
        deferred.resolve products
    deferred.promise

  run: (masterOrders, callback) ->
    throw new Error 'Callback must be a function!' unless _.isFunction callback
    if _.size(masterOrders) is 0
      @returnResult true, 'Nothing to do.', callback
      return

    for order in masterOrders
      unless @validateSameChannel order
        msg = "The order '#{order.id}' has different channels set!"
        @returnResult false, msg, callback
        return

    @initProgressBar 'Distributing orders', _.size(masterOrders)

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
        deferred.reject msg
        return deferred.promise

      retailerOrder = @replaceSKUs(masterOrder, masterSKU2retailerSKU)
      retailerOrder = @removeChannelsAndIds(retailerOrder)
      @importOrder(retailerOrder).then (newOrder) =>
        @inventoryUpdater.ensureChannelByKey(@masterRest, @retailerRest._options.config.project_key).then (channel) =>
          @addExportInfo(masterOrder.id, masterOrder.version, channel.id, newOrder.id).then (msg) ->
            @tickProgress()
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
      else if response.statusCode isnt 200
        deferred.reject "Problem on setting export info (status: #{response.statusCode}): " + body
      else
        deferred.resolve "Order exportInfo successfully stored."
    deferred.promise

  importOrder: (order) ->
    deferred = Q.defer()
    @retailerRest.POST "/orders/import", JSON.stringify(order), (error, response, body) ->
      if error
        deferred.reject "Error on importing order: " + error
      else if response.statusCode isnt 201
        deferred.reject "Problem on importing order (status: #{response.statusCode}): " + body
      else
        res = JSON.parse(body)
        deferred.resolve res
    deferred.promise

  validateSameChannel: (order) ->
    channelID = null
    checkChannelId = (channel) ->
      if channelID is null
        channelID = channel.id
        return true
      return channelID is channel.id
    if order.lineItems
      for li in order.lineItems
        if li.supplyChannel
          return false unless checkChannelId li.supplyChannel
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
        li.sku = retailerSKU # Set sku also directly on line item
        li.variant.attributes = [] unless li.variant.attributes
        a =
          name: 'mastersku'
          value: masterSKU
        li.variant.attributes.push a
    order

  removeChannelsAndIds: (order) ->
    if order.lineItems
      for li in order.lineItems
        delete li.supplyChannel if li.supplyChannel
        delete li.productId if li.productId
        continue unless li.variant
        delete li.variant.id if li.variant.id
        continue unless li.variant.prices
        for p in li.variant.prices
          delete p.channel if p.channel
    order

module.exports = OrderDistribution