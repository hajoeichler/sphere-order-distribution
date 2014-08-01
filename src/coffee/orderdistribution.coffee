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
      master:
        unsynced: 0
        synced: 0
        bad: 0
        failed: 0
      retailer:
        synced: 0
        notFound: 0
        failed: 0

  run: ->
    @_resetSummary()
    Q.all([
      @masterClient.channels.ensure(@retailerProjectKey, CHANNEL_ROLES)
      @retailerClient.channels.ensure('master', CHANNEL_ROLES)
    ]).spread (masterChannelResult, retailerChannelResult) =>
      channelInMaster = masterChannelResult.body
      channelInRetailer = retailerChannelResult.body
      @logger.debug 'Channels ensured. About to process unsynced orders'

      @masterClient.orders.sort('id').last("#{@fetchHours}h").process (payload) =>
        unsyncedOrders = @_filterUnsyncedOrders payload.body.results, channelInMaster.id
        @logger.debug "About to distribute #{_.size unsyncedOrders} unsynced orders"
        @distributeOrders unsyncedOrders, channelInMaster, channelInRetailer
    .then =>
      if @summary.master.unsynced > 0
        message = "Summary: there were #{@summary.master.unsynced} unsynced orders in master " +
          "and #{@summary.master.synced} were successfully synced back to master " +
          "(#{@summary.master.bad} were bad and #{@summary.master.failed} failed to sync), " +
          "#{@summary.retailer.synced} were synced to retailers (#{@summary.retailer.notFound} were not matched by SKUs and " +
          "#{@summary.retailer.failed} failed to sync)."
      else
        message = 'Summary: 0 unsynced orders, everything is fine.'
      Q message

  distributeOrders: (masterOrders, channelInMaster, channelInRetailer) ->
    if _.size(masterOrders) is 0
      Q()
    else
      @summary.master.unsynced += _.size(masterOrders)
      [validOrders, badOrders] = _.partition masterOrders, (order) =>
        @_validateSameChannel order

      if _.size(badOrders) > 0
        @summary.master.bad += _.size(badOrders)
        @logger.error _.map(badOrders, (o) -> o.id), 'There are orders with different channels set!'

      # process orders sequentially
      @logger.debug "About to process #{_.size validOrders} valid orders"
      Qutils.processList validOrders, (orders) =>
        throw new Error 'Orders should be processed once at a time' if orders.length isnt 1
        order = orders[0]
        @logger.debug order, "Processing order from master"
        @_distributeOrder order, channelInMaster, channelInRetailer

  _distributeOrder: (masterOrder, channelInMaster, channelInRetailer) ->
    masterSKUs = @_extractSKUs masterOrder

    @_getRetailerTaxCategory()
    .then (taxCategory) =>
      @logger.debug masterSKUs, "About to process SKUs from retailer products"
      Qutils.processList masterSKUs, (skus) =>
        pp = @retailerClient.productProjections.staged(true).whereOperator('or')
        _.each skus, (sku) ->
          pp.where("masterVariant(attributes(name = \"mastersku\" and value = \"#{sku}\"))")
          pp.where("variants(attributes(name = \"mastersku\" and value = \"#{sku}\"))")
        pp.fetch()
      .then (allMatchedProductsResults) => # array of responses
        retailerProducts = _.flatten(_.reduce allMatchedProductsResults, (memo, result) ->
          memo.push result.body.results
          memo
        , [])
        if _.size(retailerProducts) is 0
          @logger.error masterSKUs, "No products found in retailer for matching SKUs when processing master order '#{masterOrder.id}'"
          @summary.retailer.notFound++
          Q()
        else
          @logger.debug {SKUs: masterSKUs, results: retailerProducts}, 'Found products in retailer matching SKUs'
          masterSKU2retailerSKU = @_matchSKUs retailerProducts
          retailerOrder = @_replaceSKUs masterOrder, masterSKU2retailerSKU
          retailerOrder = @_replaceTaxCategories retailerOrder, taxCategory
          retailerOrder = @_removeIdsAndVariantData retailerOrder

          @logger.debug retailerOrder, 'About to import retailer order'
          @retailerClient.orders.import(retailerOrder)
          .then (result) =>
            newOrder = result.body
            @logger.debug 'About to sync orders in master and retailer'

            @_updateSyncInfo(@masterClient, masterOrder.id, masterOrder.version, channelInMaster.id, newOrder.id)
            .then =>
              @summary.master.synced++
              @_updateSyncInfo(@retailerClient, newOrder.id, newOrder.version, channelInRetailer.id, masterOrder.id)
              .then =>
                @summary.retailer.synced++
                Q()
              .fail (error) =>
                @summary.retailer.failed++
                @logger.error {order: retailerOrder, error: error}, 'Failed to sync retailer order, skipping...'
                Q()
            .fail (error) =>
              @summary.master.failed++
              @logger.error {order: masterOrder, error: error}, 'Failed to sync master order, skipping...'
              Q()
      , {maxParallel: 10}

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
    client.orders.byId(orderId).update(data)
    .then =>
      @logger.debug "Sync info successfully saved for order #{orderId}"
      Q()
    .fail (err) =>
      @logger.debug "Problem on syncing order info for order #{orderId}"
      Q.reject err

  _filterUnsyncedOrders: (orders, masterChannelId) ->
    _.filter orders, (o) ->
      (not o.syncInfo? or _.isEmpty(o.syncInfo)) and
      (not _.isEmpty(o.lineItems) and o.lineItems[0].supplyChannel? and o.lineItems[0].supplyChannel.id is masterChannelId)

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