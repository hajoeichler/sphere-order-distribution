Q = require 'q'
_ = require 'underscore'
SphereClient = require 'sphere-node-client'
{Qutils} = require 'sphere-node-utils'

CHANNEL_ROLES = ['InventorySupply', 'OrderExport', 'OrderImport']

class OrderDistribution

  constructor: (options = {}) ->
    throw new Error 'No base configuration in options!' unless options.baseConfig
    throw new Error 'No master configuration in options!' unless options.master
    throw new Error 'No retailer configuration in options!' unless options.retailer

    masterOpts = _.clone options.baseConfig
    masterOpts.config = options.master
    retailerOpts = _.clone options.baseConfig
    retailerOpts.config = options.retailer

    @masterClient = new SphereClient masterOpts
    @retailerClient = new SphereClient retailerOpts

    @logger = options.baseConfig.logConfig.logger
    @retailerProjectKey = options.retailer.project_key

    @fetchHours = options.baseConfig.fetchHours or 24

  run: ->
    @masterClient.channels.ensure(@retailerProjectKey, CHANNEL_ROLES)
    .then (result) =>
      channelInMaster = result.body
      @getUnSyncedOrders channelInMaster.id
      .then (masterOrders) =>
        @distributeOrders masterOrders, channelInMaster

  getUnSyncedOrders: (channelId) ->
    @masterClient.orders.perPage(0).sort('id').last("#{@fetchHours}h").fetch()
    .then (result) ->
      unsyncedOrders = _.filter result.body.results, (o) ->
        (not o.syncInfo? or _.isEmpty(o.syncInfo)) and
        (not _.isEmpty(o.lineItems) and o.lineItems[0].supplyChannel? and o.lineItems[0].supplyChannel.id is channelId)
      Q unsyncedOrders
    .fail (err) =>
      @logger.debug 'Problem on fetching orders'
      Q.reject err

  distributeOrders: (masterOrders, channelInMaster) ->
    if _.size(masterOrders) is 0
      Q 'There are no orders to sync.'
    else
      [validOrders, badOrders] = _.partition masterOrders, (order) =>
        @_validateSameChannel order

      _.each badOrders, (bad) =>
        @logger.error "The order '#{bad.id}' has different channels set!"

      # process orders sequentially
      Qutils.processList validOrders, (order) =>
        @logger.debug "Processing order #{order.id}"
        @_distributeOrder order, channelInMaster
      .then (results) =>
        Q "Summary: #{_.size validOrders} were synced, #{_.size badOrders} were bad orders"

  _distributeOrder: (masterOrder, channelInMaster) ->
    masterSKUs = @_extractSKUs masterOrder

    Q.all([
      @_getRetailerTaxCategory()
      @retailerClient.channels.ensure('master', CHANNEL_ROLES)
    ])
    .spread (taxCategory, channelInRetailer) =>
      Q.all _.map masterSKUs, (sku) => @_getRetailerProductByMasterSKU(sku)
      .then (retailerProducts) =>
        masterSKU2retailerSKU = @_matchSKUs retailerProducts

        retailerOrder = @_replaceSKUs masterOrder, masterSKU2retailerSKU
        retailerOder = @_replaceTaxCategories retailerOrder, taxCategory
        retailerOrder = @_removeIdsAndVariantData retailerOrder

        @retailerClient.orders.import(retailerOrder)
      .then (newOrder) =>
        Q.all([
          @_updateSyncInfo(@masterClient, masterOrder.id, masterOrder.version, channelInMaster.id, newOrder.id)
          @_updateSyncInfo(@retailerClient, newOrder.id, newOrder.version, channelInRetailer.id, masterOrder.id)
        ])

  _getRetailerTaxCategory: ->
    @retailerClient.taxCategories.perPage(1).fetch()
    .then (result) ->
      if _.size(result.body.results) is 1
        Q result.body.results[0]
      else
        Q.reject 'Can\'t find a retailer taxCategory'
    .fail (err) =>
      @logger.debug 'Problem on fetching retailer taxCategory'
      Q.reject err

  _getRetailerProductByMasterSKU: (sku) ->
    # TODO: use search function of node-client, once implemented
    deferred = Q.defer()
    query = encodeURIComponent "variants.attributes.mastersku:\"#{sku.toLowerCase()}\""
    @retailerClient._rest.GET "/product-projections/search?staged=true&lang=de&filter=#{query}" , (error, response, body) =>
      if error?
        @logger.info "Problem on fetching retailer products for sku '#{sku}'"
        deferred.reject error
      else if response.statusCode isnt 200
        @logger.info "Problem on fetching retailer products for sku '#{sku}'"
        deferred.reject body
      else
        if _.size(body.results) is 1
          deferred.resolve body.results[0]
        else
          deferred.reject "Can't find retailer product for sku '#{sku}'"
    deferred.promise

  _updateSyncInfo: (client, orderId, orderVersion, channelId, externalId) ->
    data =
      version: orderVersion
      actions: [
        action: 'updateSyncInfo'
        channel:
          typeId: 'channel'
          id: channelId
        externalId: externalId
      ]
    client.orders.byId(orderId).save(data)
    .then =>
      @logger.debug "Sync info successfully saved for order #{orderId}"
      Q()
    .fail (err) =>
      @logger.debug 'Problem on syncing order info for order #{orderId}'
      Q.reject err

  _matchSKUs: (retailerProducts) ->
    allVariants = _.flatten _.map(retailerProducts, (p) -> [p.masterVariant].concat(p.variants or []))
    reducefn = (acc, v) ->
      a = _.find v.attributes, (a) -> a.name is 'mastersku'
      if a?
        acc[a.value] = v.sku
      acc
    _.reduce allVariants, reducefn, {}

  _validateSameChannel: (order) ->
    channelID = null
    checkChannelId = (channel) ->
      if channelID is null
        channelID = channel.id
        return true
      return channelID is channel.id
    if order.lineItems?
      for li in order.lineItems
        if li.supplyChannel?
          return false unless checkChannelId li.supplyChannel
        continue unless li.variant
        continue unless li.variant.prices
        for p in li.variant.prices
          if p.channel?
            return false unless checkChannelId p.channel
    true

  _extractSKUs: (order) ->
    _.map _.filter(order.lineItems or [], (li) -> li.variant? and li.variant.sku? ), (li) -> li.variant.sku

  _replaceSKUs: (order, masterSKU2retailerSKU) ->
    if order.lineItems?
      for li in order.lineItems
        continue unless li.variant
        continue unless li.variant.sku
        masterSKU = li.variant.sku
        li.variant.sku = masterSKU2retailerSKU[masterSKU]

    order

  _replaceTaxCategories: (order, taxCategory) ->
    if order.shippingInfo? and order.shippingInfo.taxCategory?
      order.shippingInfo.taxCategory['id'] = taxCategory.id

    order

  _removeIdsAndVariantData: (order) ->
    delete order.createdAt if order.createdAt?
    delete order.lastModifiedAt if order.lastModifiedAt?
    delete order.lastMessageSequenceNumber if order.lastMessageSequenceNumber?
    delete order.syncInfo if order.syncInfo?

    _.each order.lineItems or [], (li) ->
      delete li.supplyChannel if li.supplyChannel?
      delete li.id if li.id?
      delete li.productId if li.productId?
      delete li.state if li.state?
      if li.variant?
        delete li.variant.id if li.variant.id?
        delete li.variant.attributes if li.variant.attributes?
        delete li.variant.images if li.variant.images?
        _.each li.variant.prices or [], (price) ->
          delete price.channel if price.channel?

    order

module.exports = OrderDistribution