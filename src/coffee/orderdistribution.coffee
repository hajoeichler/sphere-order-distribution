Q = require 'q'
_ = require 'underscore'
SphereClient = require 'sphere-node-client'
{Qutils} = require 'sphere-node-utils'

CHANNEL_ROLES = ['InventorySupply', 'OrderExport', 'OrderImport']

class OrderDistribution

  constructor: (@logger, options = {}) ->
    throw new Error 'No base configuration in options!' unless options.baseConfig
    throw new Error 'No master configuration in options!' unless options.master
    throw new Error 'No retailer configuration in options!' unless options.retailer

    masterOpts = _.clone options.baseConfig
    masterOpts.config = options.master
    retailerOpts = _.clone options.baseConfig
    retailerOpts.config = options.retailer

    @masterClient = new SphereClient masterOpts
    @retailerClient = new SphereClient retailerOpts

    @retailerProjectKey = options.retailer.project_key
    @fetchHours = options.baseConfig.fetchHours or 24
    @_resetSummary()

  _resetSummary: ->
    @summary =
      unsynced: 0
      bad: 0
      synced: 0
      failed: 0

  run: ->
    @_resetSummary()
    Q.all [
      @masterClient.channels.ensure(@retailerProjectKey, CHANNEL_ROLES)
      @retailerClient.channels.ensure('master', CHANNEL_ROLES)
    ].spread (masterChannelResult, retailerChannelResult) =>
      channelInMaster = masterChannelResult.body
      channelInRetailer = retailerChannelResult.body

      @masterClient.orders.sort('id').last("#{@fetchHours}h").process (payload) =>
        unsyncedOrders = _.filter payload.body.results, (o) ->
          (not o.syncInfo? or _.isEmpty(o.syncInfo)) and
          (not _.isEmpty(o.lineItems) and o.lineItems[0].supplyChannel? and o.lineItems[0].supplyChannel.id is channelInMaster.Id)
        @distributeOrders unsyncedOrders, channelInMaster, channelInRetailer
    .then =>
      Q "Summary: #{@summary.unsynced} unsynced orders (#{@summary.bad} were bad), #{@summary.synced} were synced and #{@summary.failed} failed."

  distributeOrders: (masterOrders, channelInMaster, channelInRetailer) ->
    if _.size(masterOrders) is 0
      Q()
    else
      @summary.unsynced += _.size(masterOrders)
      [validOrders, badOrders] = _.partition masterOrders, (order) =>
        @_validateSameChannel order

      @summary.bad += _.size(badOrders)
      @logger.error _.map(badOrders, (o) -> o.id), "There are orders with different channels set!"

      # process orders sequentially
      Qutils.processList validOrders, (orders) =>
        throw new Error 'Orders should be processed once at a time' if orders.length isnt 1
        order = orders[0]
        @logger.debug "Processing order #{order.id} from master"
        @_distributeOrder order, channelInMaster, channelInRetailer

  _distributeOrder: (masterOrder, channelInMaster, channelInRetailer) ->
    masterSKUs = @_extractSKUs masterOrder

    @_getRetailerTaxCategory()
    .then (taxCategory) =>

      Qutils.processList masterSKUs, (skus) =>
        pp = @retailerClient.productProjections.whereOperator('or')
        _.each skus, (sku) ->
          pp.where("masterVariant(sku = \"#{sku.toLowerCase()}\")")
          pp.where("variants(sku = \"#{sku.toLowerCase()}\")")
        pp.fetch()
        .then (results) =>
          retailerProducts = results.body.results
          masterSKU2retailerSKU = @_matchSKUs retailerProducts
          retailerOrder = @_replaceSKUs masterOrder, masterSKU2retailerSKU
          retailerOrder = @_replaceTaxCategories retailerOrder, taxCategory
          retailerOrder = @_removeIdsAndVariantData retailerOrder

          @retailerClient.orders.import(retailerOrder)
        .then (result) =>
          newOrder = result.body
          Q.allSettled [
            @_updateSyncInfo(@masterClient, masterOrder.id, masterOrder.version, channelInMaster.id, newOrder.id)
            @_updateSyncInfo(@retailerClient, newOrder.id, newOrder.version, channelInRetailer.id, masterOrder.id)
          ]
        .then (results) =>
          _.each results, (result) =>
            if result.state is 'fulfilled'
              @summary.synced++
            else
              @logger.error result, 'Failed to sync order'
              @summary.failed++
          Q()
      , {maxParallel: 20}

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